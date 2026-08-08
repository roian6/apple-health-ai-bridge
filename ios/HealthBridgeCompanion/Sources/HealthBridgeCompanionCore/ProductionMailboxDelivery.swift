import CryptoKit
import Foundation

public enum ProductionMailboxDeliveryError: Error, Equatable, Sendable {
    case inactive
    case invalidIdentity
    case itemUnavailable
}

public enum ProductionMailboxDeliveryPhaseError: Error, Equatable, Sendable {
    case makeComponents
    case loadPending
    case initialAdvance
    case locateAckLane
    case hydrateAck
    case scanAck
    case mapAckItem
    case consumeAck
    case remainingCount

    public var diagnosticCode: String {
        switch self {
        case .makeComponents: "make_components"
        case .loadPending: "load_pending"
        case .initialAdvance: "initial_advance"
        case .locateAckLane: "locate_ack_lane"
        case .hydrateAck: "hydrate_ack"
        case .scanAck: "scan_ack"
        case .mapAckItem: "map_ack_item"
        case .consumeAck: "consume_ack"
        case .remainingCount: "remaining_count"
        }
    }
}

public struct ProductionMailboxDeliverySummary: Equatable, Sendable {
    public let attemptedCount: Int
    public let finalizedCount: Int
    public let waitingCount: Int
    public let terminalCount: Int
    public let hydration: MailboxAckHydrationReport
    public let scannedFinalCount: Int
    public let scannedByteCount: Int64
    public let ignoredTemporaryCount: Int
    public let quarantine: MailboxAckQuarantineSummary

    public var ackDiagnosticLine: String {
        let counts = Dictionary(grouping: quarantine.records, by: { $0 })
            .mapValues(\.count)
        return "Mailbox ACK diagnostics: hydration eligible=\(hydration.eligibleCandidateCount), "
            + "downloadRequests=\(hydration.requestedDownloadCount), "
            + "remainingUnavailable=\(hydration.remainingUnavailableCount), "
            + "skippedUnverifiableIdentity=\(hydration.skippedUnverifiableIdentityCount); "
            + "scan finalCount=\(scannedFinalCount), byteCount=\(scannedByteCount), "
            + "ignoredTemporaryCount=\(ignoredTemporaryCount); quarantine "
            + "invalidName=\(counts[.invalidName, default: 0]), "
            + "unsafeEntry=\(counts[.unsafeEntry, default: 0]), "
            + "oversize=\(counts[.oversize, default: 0]), "
            + "authenticationFailed=\(counts[.authenticationFailed, default: 0]), "
            + "unknownEnvelope=\(counts[.unknownEnvelope, default: 0]), "
            + "stale=\(counts[.stale, default: 0]), "
            + "bindingConflict=\(counts[.bindingConflict, default: 0]), "
            + "suppressed=\(quarantine.suppressedCount)."
    }
}

public final class ProductionMailboxDelivery {
    private let settingsStore: ReceiverSettingsStore
    private let outbox: FileOutbox
    private let cursorStore: any SyncCursorStoring
    private let proofStore: CoreLaneUploadProofStore?
    private let sleepStore: (any SleepSyncManifestStoring)?
    private let keyStore: MailboxKeyStore

    public init(
        settingsStore: ReceiverSettingsStore,
        outbox: FileOutbox,
        cursorStore: any SyncCursorStoring,
        proofStore: CoreLaneUploadProofStore? = nil,
        sleepStore: (any SleepSyncManifestStoring)? = nil,
        keyStore: MailboxKeyStore = MailboxKeyStore(
            service: HealthBridgeAppIdentity.mailboxKeychainServiceName
        )
    ) {
        self.settingsStore = settingsStore
        self.outbox = outbox
        self.cursorStore = cursorStore
        self.proofStore = proofStore
        self.sleepStore = sleepStore
        self.keyStore = keyStore
    }

    public func validateAvailability() throws {
        let components = try makeComponents()
        _ = try components.locate()
    }

    @MainActor
    public func deliverPending() async throws -> ProductionMailboxDeliverySummary {
        let components: ProductionMailboxComponents
        do {
            components = try makeComponents()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.makeComponents
        }
        let items: [FileOutboxItem]
        do {
            items = try outbox.pendingItems().filter {
                $0.receiverIdentity == components.identity.opaqueBinding
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.loadPending
        }
        var terminalCount = 0
        do {
            for item in items {
                let coordinator = try coordinator(
                    components: components,
                    itemID: item.id
                )
                for _ in 0 ..< 4 {
                    let state = try coordinator.advance(itemID: item.id)
                    switch state.phase {
                    case .collected, .encrypted, .published:
                        continue
                    case .providerObserved, .ackVerified, .committedFinalized,
                         .retryableFailure:
                        break
                    case .terminalFailure:
                        terminalCount += 1
                        break
                    }
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.initialAdvance
        }
        let ackLane: URL
        do {
            let locator = try components.locate()
            guard let locatedAckLane = locator.lanes[.acks] else {
                throw MailboxAckScannerError.unsafeMailbox
            }
            ackLane = locatedAckLane
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.locateAckLane
        }
        let hydration: MailboxAckHydrationReport
        do {
            hydration = try await ProductionMailboxAckHydration.make(lane: ackLane).hydrate()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.hydrateAck
        }
        let report: MailboxAckScanReport
        do {
            report = try components.scanner.scan()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.scanAck
        }
        var finalizedCount = 0
        for event in report.events {
            let mappedItemID: String?
            do {
                mappedItemID = try itemID(
                    for: event.envelopeID,
                    signingPublicKey: components.deviceSigningPublicKey
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProductionMailboxDeliveryPhaseError.mapAckItem
            }
            guard let itemID = mappedItemID else { continue }
            do {
                let coordinator = try coordinator(
                    components: components,
                    itemID: itemID
                )
                switch event.classification {
                case .committed, .duplicateIdentical:
                    let disposition = try coordinator.consume(event, itemID: itemID)
                    if disposition == .ackVerified {
                        _ = try coordinator.finalizeCommitted(itemID: itemID)
                        finalizedCount += 1
                    }
                    if try coordinator.state(itemID: itemID)?.phase == .committedFinalized {
                        try coordinator.deleteAcknowledgment(for: event, itemID: itemID)
                    }
                case .retryableNack:
                    _ = try coordinator.consume(event, itemID: itemID)
                case .terminalNack:
                    if try coordinator.consume(event, itemID: itemID) == .terminalHold {
                        terminalCount += 1
                    }
                case .conflict:
                    continue
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProductionMailboxDeliveryPhaseError.consumeAck
            }
        }
        let remaining: Int
        do {
            remaining = try outbox.pendingItems().filter {
                $0.receiverIdentity == components.identity.opaqueBinding
            }.count
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.remainingCount
        }
        return ProductionMailboxDeliverySummary(
            attemptedCount: items.count,
            finalizedCount: finalizedCount,
            waitingCount: remaining,
            terminalCount: terminalCount,
            hydration: hydration,
            scannedFinalCount: report.scannedFinalCount,
            scannedByteCount: report.scannedByteCount,
            ignoredTemporaryCount: report.ignoredTemporaryCount,
            quarantine: report.quarantine
        )
    }

    private func coordinator(
        components: ProductionMailboxComponents,
        itemID: String
    ) throws -> OutboxDeliveryCoordinator {
        let transition = try sleepStore?.loadPendingTransition()
        let resetEpoch = transition?.outboxItemID == itemID
            ? transition?.manifest.baselineResetEpoch
            : nil
        let finalizer: any OutboxDeliveryCommitFinalizing
        if let sleepStore, let transition, transition.outboxItemID == itemID {
            finalizer = OutboxDeliverySleepFinalizer(
                store: sleepStore,
                pendingTransition: transition
            )
        } else {
            finalizer = OutboxDeliveryCursorFinalizer(
                outbox: outbox,
                cursorStore: cursorStore,
                proofStore: proofStore
            )
        }
        return OutboxDeliveryCoordinator(
            outbox: outbox,
            transport: components.transport,
            scanner: components.scanner,
            ownership: OutboxDeliveryOwnershipV1(
                receiverGeneration: settingsStore.receiverSettingsGenerationToken,
                resetEpoch: resetEpoch,
                ackContext: components.ackContext
            ),
            finalizer: finalizer
        )
    }

    private func itemID(
        for envelopeID: Data,
        signingPublicKey: Curve25519.Signing.PublicKey
    ) throws -> String? {
        for item in try outbox.mailboxBoundItemsForAckScanning() {
            if item.deliveryState?.committedReceipt?.envelopeID == envelopeID {
                return item.id
            }
            guard let binding = item.mailboxBinding else { continue }
            let claims: DeliveryEnvelopeClaimsV1
            do {
                let envelope = try MailboxRegularFileReader.read(
                    outbox.directoryURL.appendingPathComponent(binding.envelopeFilename),
                    maximumBytes: MailboxLayoutV1.maximumDeliveryBytes
                )
                claims = try DeliveryProtocolV1.inspectDelivery(
                    envelope,
                    senderSigningPublicKey: signingPublicKey
                )
            } catch {
                // A conflicting local envelope must not block unrelated authenticated ACKs.
                // It remains pending because no item mapping or finalization occurs for it.
                continue
            }
            if claims.envelopeID == envelopeID { return item.id }
        }
        return nil
    }

    private func makeComponents() throws -> ProductionMailboxComponents {
        try ProductionMailboxComponents.make(
            settingsStore: settingsStore,
            outbox: outbox,
            keyStore: keyStore
        )
    }
}

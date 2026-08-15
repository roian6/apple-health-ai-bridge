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
    public let ackCleanupFailureCount: Int
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
            + "ignoredTemporaryCount=\(ignoredTemporaryCount); "
            + "cleanupFailures=\(ackCleanupFailureCount); quarantine "
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

public enum ProductionMailboxBackgroundPhase: String, Equatable, Sendable {
    case none
    case publishFIFOHead = "publish_fifo_head"
    case reconcileFIFOHeadAcknowledgment = "reconcile_fifo_head_ack"

    var lane: String {
        switch self {
        case .none: "none"
        case .publishFIFOHead: "outbox"
        case .reconcileFIFOHeadAcknowledgment: "acknowledgment"
        }
    }
}

public struct ProductionMailboxBackgroundDeliverySummary: Equatable, Sendable {
    public let phase: ProductionMailboxBackgroundPhase
    public let attemptedCount: Int
    public let finalizedCount: Int
    public let waitingCount: Int
    public let terminalCount: Int
    public let ackCleanupFailureCount: Int
    public let hydration: MailboxAckHydrationReport
    public let inspectedAcknowledgmentEntryCount: Int
    public let scannedFinalCount: Int
    public let scannedByteCount: Int64
    public let ignoredTemporaryCount: Int
    public let quarantine: MailboxAckQuarantineSummary
    public let nextAcknowledgmentCheckpoint: String?

    public var diagnosticLine: String {
        "Mailbox background delivery: phase=\(phase.rawValue), lane=\(phase.lane), "
            + "attempted=\(attemptedCount), finalized=\(finalizedCount), "
            + "waiting=\(waitingCount), terminal=\(terminalCount), "
            + "hydrated=\(hydration.requestedDownloadCount), "
            + "inspected=\(inspectedAcknowledgmentEntryCount), "
            + "scanned=\(scannedFinalCount), cleanupFailures=\(ackCleanupFailureCount)."
    }
}

public final class ProductionMailboxDelivery {
    public static let backgroundAcknowledgmentFileLimit = 8

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

    public func pendingFIFOHeadBackgroundPhase() throws -> ProductionMailboxBackgroundPhase {
        let components = try backgroundComponents()
        guard let item = try backgroundPendingItems(components: components).first else {
            return .none
        }
        return Self.backgroundPhase(for: item.deliveryState?.phase)
    }

    static func backgroundPhase(
        for phase: OutboxDeliveryPhase?
    ) -> ProductionMailboxBackgroundPhase {
        guard let phase else { return .publishFIFOHead }
        switch phase {
        case .collected, .encrypted, .retryableFailure:
            return .publishFIFOHead
        case .published, .providerObserved, .ackVerified:
            return .reconcileFIFOHeadAcknowledgment
        case .committedFinalized, .terminalFailure:
            return .none
        }
    }

    @MainActor
    public func publishPendingFIFOHead() async throws
        -> ProductionMailboxBackgroundDeliverySummary
    {
        try Task.checkCancellation()
        let components = try backgroundComponents()
        let items = try backgroundPendingItems(components: components)
        guard let item = items.first else {
            return backgroundSummary(
                phase: .publishFIFOHead,
                attemptedCount: 0,
                waitingCount: 0
            )
        }
        let deliveryCoordinator: OutboxDeliveryCoordinator
        do {
            deliveryCoordinator = try coordinator(components: components, itemID: item.id)
            var terminalCount = 0
            for _ in 0 ..< 4 {
                try Task.checkCancellation()
                let state = try deliveryCoordinator.advance(itemID: item.id)
                switch state.phase {
                case .collected, .encrypted, .published:
                    continue
                case .terminalFailure:
                    terminalCount = 1
                case .providerObserved, .ackVerified, .committedFinalized,
                     .retryableFailure:
                    break
                }
                break
            }
            return backgroundSummary(
                phase: .publishFIFOHead,
                attemptedCount: 1,
                waitingCount: items.count,
                terminalCount: terminalCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.initialAdvance
        }
    }

    @MainActor
    public func reconcilePendingFIFOHeadAcknowledgment(
        afterAcknowledgmentCheckpoint: String?,
        maximumAcknowledgmentFiles: Int = ProductionMailboxDelivery
            .backgroundAcknowledgmentFileLimit
    ) async throws -> ProductionMailboxBackgroundDeliverySummary {
        try Task.checkCancellation()
        let components = try backgroundComponents()
        let items = try backgroundPendingItems(components: components)
        guard let item = items.first else {
            return backgroundSummary(
                phase: .reconcileFIFOHeadAcknowledgment,
                attemptedCount: 0,
                waitingCount: 0
            )
        }
        let coordinator = try coordinator(components: components, itemID: item.id)
        if try coordinator.state(itemID: item.id)?.phase == .published {
            do {
                try Task.checkCancellation()
                _ = try coordinator.advance(itemID: item.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProductionMailboxDeliveryPhaseError.initialAdvance
            }
        }
        if try coordinator.state(itemID: item.id)?.phase == .ackVerified {
            do {
                try Task.checkCancellation()
                _ = try coordinator.finalizeCommitted(itemID: item.id)
                return backgroundSummary(
                    phase: .reconcileFIFOHeadAcknowledgment,
                    attemptedCount: 1,
                    finalizedCount: 1,
                    waitingCount: max(0, items.count - 1)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProductionMailboxDeliveryPhaseError.consumeAck
            }
        }
        guard try coordinator.state(itemID: item.id)?.phase == .providerObserved else {
            return backgroundSummary(
                phase: .reconcileFIFOHeadAcknowledgment,
                attemptedCount: 1,
                waitingCount: items.count
            )
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
        let pendingFIFOHeadRecord: MailboxAckOutboxRecord?
        do {
            pendingFIFOHeadRecord = try components.ackLookup.record(for: item)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.mapAckItem
        }
        let acknowledgment: (
            hydration: MailboxAckHydrationReport,
            report: MailboxAckScanReport,
            inspectedEntryCount: Int,
            nextCheckpoint: String?,
            usedExactCandidate: Bool
        ) = try await Self.preferDirectAcknowledgment(
            direct: {
                guard let pendingFIFOHeadRecord else { return nil }
                let pendingFIFOHeadEnvelopeID = pendingFIFOHeadRecord.envelopeID
                let hydration: MailboxAckHydrationReport
                do {
                    hydration = try await ProductionMailboxAckHydration.make(
                        lane: ackLane,
                        candidateFileNames: [pendingFIFOHeadEnvelopeID.hexV1 + ".hba"],
                        maximumWaits: 1
                    ).hydrate()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ProductionMailboxDeliveryPhaseError.hydrateAck
                }
                try Task.checkCancellation()
                let report: MailboxAckScanReport
                do {
                    report = try components.scanner.scanExact(record: pendingFIFOHeadRecord)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ProductionMailboxDeliveryPhaseError.scanAck
                }
                guard Self.acknowledgmentIndexForPendingFIFOHead(
                    eventEnvelopeIDs: report.events.map(\.envelopeID),
                    pendingFIFOHeadEnvelopeID: pendingFIFOHeadEnvelopeID
                ) != nil else {
                    return nil
                }
                return (
                    hydration: hydration,
                    report: report,
                    inspectedEntryCount: 0,
                    nextCheckpoint: nil as String?,
                    usedExactCandidate: true
                )
            },
            boundedFallback: {
                let window: MailboxAckCandidateWindow
                do {
                    window = try components.scanner.candidateWindow(
                        maximumEntries: maximumAcknowledgmentFiles,
                        afterCheckpoint: afterAcknowledgmentCheckpoint
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ProductionMailboxDeliveryPhaseError.scanAck
                }
                let hydration: MailboxAckHydrationReport
                do {
                    hydration = try await ProductionMailboxAckHydration.make(
                        lane: ackLane,
                        candidateFileNames: window.fileNames,
                        maximumWaits: 1
                    ).hydrate()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ProductionMailboxDeliveryPhaseError.hydrateAck
                }
                try Task.checkCancellation()
                let report: MailboxAckScanReport
                do {
                    report = try components.scanner.scan(window: window)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ProductionMailboxDeliveryPhaseError.scanAck
                }
                return (
                    hydration: hydration,
                    report: report,
                    inspectedEntryCount: window.inspectedEntryCount,
                    nextCheckpoint: window.nextCheckpoint,
                    usedExactCandidate: false
                )
            }
        )
        let hydration = acknowledgment.hydration
        let report = acknowledgment.report
        var finalizedCount = 0
        var terminalCount = 0
        var ackCleanupFailureCount = 0
        if let pendingFIFOHeadEnvelopeID = pendingFIFOHeadRecord?.envelopeID,
           let index = Self.acknowledgmentIndexForPendingFIFOHead(
            eventEnvelopeIDs: report.events.map(\.envelopeID),
            pendingFIFOHeadEnvelopeID: pendingFIFOHeadEnvelopeID
        ) {
            let event = report.events[index]
            do {
                try Task.checkCancellation()
                switch event.classification {
                case .committed, .duplicateIdentical:
                    let disposition = try coordinator.consume(event, itemID: item.id)
                    if disposition == .ackVerified {
                        try Task.checkCancellation()
                        _ = try coordinator.finalizeCommitted(itemID: item.id)
                        finalizedCount = 1
                    }
                    if try coordinator.state(itemID: item.id)?.phase == .committedFinalized,
                       !acknowledgment.usedExactCandidate,
                       !Self.deleteAcknowledgmentAfterDurableCommit({
                           try coordinator.deleteAcknowledgment(for: event, itemID: item.id)
                       }) {
                        ackCleanupFailureCount = 1
                    }
                case .retryableNack:
                    _ = try coordinator.consume(event, itemID: item.id)
                case .terminalNack:
                    if try coordinator.consume(event, itemID: item.id) == .terminalHold {
                        terminalCount = 1
                    }
                case .conflict:
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProductionMailboxDeliveryPhaseError.consumeAck
            }
        }
        return backgroundSummary(
            phase: .reconcileFIFOHeadAcknowledgment,
            attemptedCount: 1,
            finalizedCount: finalizedCount,
            waitingCount: max(0, items.count - finalizedCount),
            terminalCount: terminalCount,
            ackCleanupFailureCount: ackCleanupFailureCount,
            hydration: hydration,
            inspectedAcknowledgmentEntryCount: acknowledgment.inspectedEntryCount,
            report: report,
            nextAcknowledgmentCheckpoint: acknowledgment.nextCheckpoint
        )
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
        var ackCleanupFailureCount = 0
        var mappedEvents: [(event: MailboxAckEvent, itemID: String)] = []
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
            mappedEvents.append((event, itemID))
        }
        let pendingItemIDs = items.map(\.id)
        let pendingItemIDSet = Set(pendingItemIDs)
        let orderedIndices = Self.orderedAcknowledgmentIndices(
            itemIDs: mappedEvents.map(\.itemID),
            pendingItemIDs: pendingItemIDs
        )
        for index in orderedIndices {
            let (event, itemID) = mappedEvents[index]
            do {
                let coordinator = try coordinator(
                    components: components,
                    itemID: itemID
                )
                guard pendingItemIDSet.contains(itemID) else {
                    if try coordinator.state(itemID: itemID)?.phase == .committedFinalized {
                        let deleted = Self.deleteAcknowledgmentAfterDurableCommit {
                            try coordinator.deleteAcknowledgment(for: event, itemID: itemID)
                        }
                        if !deleted {
                            ackCleanupFailureCount += 1
                        }
                    }
                    continue
                }
                switch event.classification {
                case .committed, .duplicateIdentical:
                    let disposition = try coordinator.consume(event, itemID: itemID)
                    if disposition == .ackVerified {
                        _ = try coordinator.finalizeCommitted(itemID: itemID)
                        finalizedCount += 1
                    }
                    if try coordinator.state(itemID: itemID)?.phase == .committedFinalized {
                        let deleted = Self.deleteAcknowledgmentAfterDurableCommit {
                            try coordinator.deleteAcknowledgment(for: event, itemID: itemID)
                        }
                        if !deleted {
                            ackCleanupFailureCount += 1
                        }
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
            ackCleanupFailureCount: ackCleanupFailureCount,
            hydration: hydration,
            scannedFinalCount: report.scannedFinalCount,
            scannedByteCount: report.scannedByteCount,
            ignoredTemporaryCount: report.ignoredTemporaryCount,
            quarantine: report.quarantine
        )
    }

    static func orderedAcknowledgmentIndices(
        itemIDs: [String],
        pendingItemIDs: [String]
    ) -> [Int] {
        let pendingRanks = Dictionary(
            uniqueKeysWithValues: pendingItemIDs.enumerated().map { ($0.element, $0.offset) }
        )
        return itemIDs.indices.sorted { left, right in
            let leftRank = pendingRanks[itemIDs[left]] ?? Int.max
            let rightRank = pendingRanks[itemIDs[right]] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return left < right
        }
    }

    static func acknowledgmentIndexForPendingFIFOHead(
        eventEnvelopeIDs: [Data],
        pendingFIFOHeadEnvelopeID: Data
    ) -> Int? {
        eventEnvelopeIDs.firstIndex(of: pendingFIFOHeadEnvelopeID)
    }

    @MainActor
    static func preferDirectAcknowledgment<Value>(
        direct: () async throws -> Value?,
        boundedFallback: () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        if let direct = try await direct() {
            return direct
        }
        try Task.checkCancellation()
        return try await boundedFallback()
    }

    static func deleteAcknowledgmentAfterDurableCommit(
        _ cleanup: () throws -> Void
    ) -> Bool {
        do {
            try cleanup()
            return true
        } catch {
            return false
        }
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

    private func backgroundComponents() throws -> ProductionMailboxComponents {
        do {
            return try makeComponents()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.makeComponents
        }
    }

    private func backgroundPendingItems(
        components: ProductionMailboxComponents
    ) throws -> [FileOutboxItem] {
        do {
            return try outbox.pendingItems().filter {
                $0.receiverIdentity == components.identity.opaqueBinding
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductionMailboxDeliveryPhaseError.loadPending
        }
    }

    private func backgroundSummary(
        phase: ProductionMailboxBackgroundPhase,
        attemptedCount: Int,
        finalizedCount: Int = 0,
        waitingCount: Int,
        terminalCount: Int = 0,
        ackCleanupFailureCount: Int = 0,
        hydration: MailboxAckHydrationReport = MailboxAckHydrationReport(
            eligibleCandidateCount: 0,
            requestedDownloadCount: 0,
            remainingUnavailableCount: 0,
            skippedUnverifiableIdentityCount: 0
        ),
        inspectedAcknowledgmentEntryCount: Int = 0,
        report: MailboxAckScanReport = MailboxAckScanReport(
            events: [],
            quarantine: MailboxAckQuarantineSummary(),
            scannedFinalCount: 0,
            scannedByteCount: 0,
            ignoredTemporaryCount: 0
        ),
        nextAcknowledgmentCheckpoint: String? = nil
    ) -> ProductionMailboxBackgroundDeliverySummary {
        ProductionMailboxBackgroundDeliverySummary(
            phase: phase,
            attemptedCount: attemptedCount,
            finalizedCount: finalizedCount,
            waitingCount: waitingCount,
            terminalCount: terminalCount,
            ackCleanupFailureCount: ackCleanupFailureCount,
            hydration: hydration,
            inspectedAcknowledgmentEntryCount: inspectedAcknowledgmentEntryCount,
            scannedFinalCount: report.scannedFinalCount,
            scannedByteCount: report.scannedByteCount,
            ignoredTemporaryCount: report.ignoredTemporaryCount,
            quarantine: report.quarantine,
            nextAcknowledgmentCheckpoint: nextAcknowledgmentCheckpoint
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

    private func envelopeID(
        for item: FileOutboxItem,
        signingPublicKey: Curve25519.Signing.PublicKey
    ) throws -> Data? {
        if let committedEnvelopeID = item.deliveryState?.committedReceipt?.envelopeID {
            return committedEnvelopeID
        }
        guard let binding = item.mailboxBinding else { return nil }
        do {
            let envelope = try MailboxRegularFileReader.read(
                outbox.directoryURL.appendingPathComponent(binding.envelopeFilename),
                maximumBytes: MailboxLayoutV1.maximumDeliveryBytes
            )
            return try DeliveryProtocolV1.inspectDelivery(
                envelope,
                senderSigningPublicKey: signingPublicKey
            ).envelopeID
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func makeComponents() throws -> ProductionMailboxComponents {
        try ProductionMailboxComponents.make(
            settingsStore: settingsStore,
            outbox: outbox,
            keyStore: keyStore
        )
    }
}

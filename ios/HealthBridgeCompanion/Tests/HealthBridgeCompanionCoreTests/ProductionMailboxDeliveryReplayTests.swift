import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

// macOS Core tests use the inert production hydrator, without provider metadata queries.
#if os(macOS)
@MainActor
final class ProductionMailboxDeliveryReplayTests: XCTestCase {
    func testInOrderCommittedAcknowledgmentsFinalizeFIFOAndDuplicateReplayIsIdempotent() async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        try await fixture.publishPending()

        let firstAck = try fixture.publishAck(for: fixture.first)
        let firstSummary = try await fixture.delivery().deliverPending()
        XCTAssertEqual(firstSummary.finalizedCount, 1)
        XCTAssertEqual(firstSummary.waitingCount, 1)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [fixture.second.id])
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.first.id)?.phase, .committedFinalized)
        XCTAssertEqual(fixture.cursors.writes, [fixture.firstCheckpoint.cursorValue])
        XCTAssertEqual(try fixture.currentCursor(), fixture.firstCheckpoint.cursorValue)
        XCTAssertTrue(fixture.proofs.hasUploadedRecords(lane: .steps, receiverBindingID: fixture.binding))
        XCTAssertFalse(fixture.proofs.hasUploadedRecords(lane: .workouts, receiverBindingID: fixture.binding))
        XCTAssertEqual(try Data(contentsOf: fixture.second.fileURL), fixture.payload)

        let secondAck = try fixture.publishAck(for: fixture.second)
        let secondSummary = try await fixture.delivery().deliverPending()
        XCTAssertEqual(secondSummary.finalizedCount, 1)
        try fixture.assertCompleted()

        try firstAck.bytes.write(to: firstAck.url, options: [.withoutOverwriting])
        try secondAck.bytes.write(to: secondAck.url, options: [.withoutOverwriting])
        let before = try fixture.states()
        let duplicate = try await fixture.delivery().deliverPending()
        XCTAssertEqual(duplicate.scannedFinalCount, 2)
        XCTAssertEqual(duplicate.attemptedCount, 0)
        XCTAssertEqual(duplicate.finalizedCount, 0)
        XCTAssertEqual(duplicate.waitingCount, 0)
        XCTAssertEqual(duplicate.ackCleanupFailureCount, 0)
        XCTAssertEqual(try fixture.states(), before)
        try fixture.assertCompleted()
    }

    func testLaterAcknowledgmentWaitsWithoutOutOfOrderFinalizationThenCompletesFIFO() async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        try await fixture.publishPending()
        let laterAck = try fixture.publishAck(for: fixture.second)

        do {
            let waiting = try await fixture.delivery().deliverPending()
            XCTAssertEqual(waiting.finalizedCount, 0)
            XCTAssertEqual(waiting.waitingCount, 2)
        } catch {
            XCTFail("A later authenticated ACK must wait without attempting FIFO finalization: \(error)")
        }
        try fixture.assertWaitingForFirst()
        XCTAssertEqual(try Data(contentsOf: laterAck.url), laterAck.bytes)

        _ = try fixture.publishAck(for: fixture.first)
        let completed = try await fixture.delivery().deliverPending()
        XCTAssertEqual(completed.finalizedCount, 2)
        XCTAssertEqual(completed.waitingCount, 0)
        try fixture.assertCompleted()
    }

    func testDurablyVerifiedLaterAcknowledgmentReplaysAfterReopenWithProviderCopy() async throws {
        try await assertDurableReplay(removeProviderAck: false)
    }

    func testDurablyVerifiedLaterAcknowledgmentReplaysAfterReopenWithoutProviderCopy() async throws {
        try await assertDurableReplay(removeProviderAck: true)
    }

    private func assertDurableReplay(removeProviderAck: Bool) async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        try await fixture.publishPending()
        let laterAck = try fixture.publishAck(for: fixture.second)
        let components = try fixture.components()
        let report = try components.scanner.scan()
        XCTAssertEqual(report.events.count, 1)
        let event = try XCTUnwrap(report.events.first)
        XCTAssertEqual(event.classification, .committed)
        XCTAssertEqual(event.envelopeID, try components.transport.finalizedEnvelopeID(itemID: fixture.second.id))
        let coordinator = OutboxDeliveryCoordinator(
            outbox: fixture.outbox,
            transport: components.transport,
            scanner: components.scanner,
            ownership: OutboxDeliveryOwnershipV1(
                receiverGeneration: fixture.settings.receiverSettingsGenerationToken,
                resetEpoch: nil,
                ackContext: components.ackContext
            ),
            finalizer: OutboxDeliveryCursorFinalizer(
                outbox: fixture.outbox,
                cursorStore: fixture.cursors,
                proofStore: fixture.proofs
            )
        )
        XCTAssertEqual(try coordinator.consume(event, itemID: fixture.second.id), .ackVerified)
        let verified = try XCTUnwrap(fixture.outbox.deliveryState(for: fixture.second.id))
        XCTAssertEqual(verified.phase, .ackVerified)
        XCTAssertNotNil(verified.committedReceipt)
        try fixture.assertWaitingForFirst()
        if removeProviderAck {
            try FileManager.default.removeItem(at: laterAck.url)
        }

        try fixture.reopenOutbox()
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.second.id), verified)
        XCTAssertEqual(FileManager.default.fileExists(atPath: laterAck.url.path), !removeProviderAck)
        try fixture.assertWaitingForFirst()
        let stillWaiting = try await fixture.delivery().deliverPending()
        XCTAssertEqual(stillWaiting.finalizedCount, 0)
        XCTAssertEqual(stillWaiting.waitingCount, 2)
        try fixture.assertWaitingForFirst()

        _ = try fixture.publishAck(for: fixture.first)
        let completed = try await fixture.delivery().deliverPending()
        XCTAssertEqual(completed.finalizedCount, 2)
        XCTAssertEqual(completed.waitingCount, 0)
        try fixture.assertCompleted()
        let repeated = try await fixture.delivery().deliverPending()
        XCTAssertEqual(repeated.finalizedCount, 0)
        XCTAssertEqual(repeated.waitingCount, 0)
        try fixture.assertCompleted()
    }
}

@MainActor
final class ProductionMailboxDeliveryAckSelectionTests: XCTestCase {
    func testSmallCanonicalPrefixAllowsSignedAcknowledgmentsToCompleteFIFO() async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        try await fixture.publishPending()
        let noise = try fixture.publishEarlierCanonicalNoise(count: 4)
        _ = try fixture.publishAck(for: fixture.first)
        _ = try fixture.publishAck(for: fixture.second)
        try fixture.assertAuthenticAcknowledgment(for: fixture.first)
        try fixture.assertAuthenticAcknowledgment(for: fixture.second)

        try await fixture.deliverForegroundOpportunities(count: 4)

        try fixture.assertCompleted()
        try fixture.assertNoiseRemains(noise)
    }

    func testSignedHeadBeyondCanonicalScanCapCompletesFIFOAcrossForegroundOpportunities() async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        try await fixture.publishPending()
        XCTAssertEqual(MailboxAckScanner.maximumScanFiles, 10_000)
        let noise = try fixture.publishEarlierCanonicalNoise(count: MailboxAckScanner.maximumScanFiles)
        _ = try fixture.publishAck(for: fixture.first)
        _ = try fixture.publishAck(for: fixture.second)
        try fixture.assertAuthenticAcknowledgment(for: fixture.first)
        try fixture.assertAuthenticAcknowledgment(for: fixture.second)

        try await fixture.deliverForegroundOpportunities(count: 4)

        try fixture.assertCompleted()
        try fixture.assertNoiseRemains(noise)
    }

    func testSignedHeadBeyondCapCompletesAfterSameLaneRetriesAndOutboxReopen() async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        try await fixture.publishPending()
        let noise = try fixture.publishEarlierCanonicalNoise(count: MailboxAckScanner.maximumScanFiles)
        let laterAck = try fixture.publishAck(for: fixture.second)
        try fixture.assertAuthenticAcknowledgment(for: fixture.second)
        let encrypted = try fixture.encryptedLocalFiles()

        for _ in 0 ..< 2 {
            _ = try await fixture.delivery().deliverPending()
            try fixture.assertWaitingForFirst()
            XCTAssertEqual(try fixture.encryptedLocalFiles(), encrypted)
            XCTAssertEqual(try Data(contentsOf: laterAck.url), laterAck.bytes)
        }
        let waitingStates = try fixture.states()
        try fixture.reopenOutbox()
        XCTAssertEqual(try fixture.states(), waitingStates)
        try fixture.assertWaitingForFirst()
        XCTAssertEqual(try fixture.encryptedLocalFiles(), encrypted)

        _ = try fixture.publishAck(for: fixture.first)
        try fixture.assertAuthenticAcknowledgment(for: fixture.first)
        try await fixture.deliverForegroundOpportunities(count: 2)
        let statesBeforeReopen = try fixture.states()
        let pendingBeforeReopen = try fixture.outbox.pendingItems().map(\.id)
        let checkpointBeforeReopen = try fixture.outbox.pendingCursorCheckpoint()
        let cursorBeforeReopen = try fixture.currentCursor()
        let writesBeforeReopen = fixture.cursors.writes
        try fixture.reopenOutbox()
        XCTAssertEqual(try fixture.states(), statesBeforeReopen)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), pendingBeforeReopen)
        XCTAssertEqual(try fixture.outbox.pendingCursorCheckpoint(), checkpointBeforeReopen)
        XCTAssertEqual(try fixture.currentCursor(), cursorBeforeReopen)
        XCTAssertEqual(fixture.cursors.writes, writesBeforeReopen)
        try await fixture.deliverForegroundOpportunities(count: 2)

        try fixture.assertCompleted()
        try fixture.assertNoiseRemains(noise)
    }

    func testInvalidSignatureForExactHeadBeyondCapPreservesPendingStateAndArtifacts() async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        try await fixture.publishPending()
        let noise = try fixture.publishEarlierCanonicalNoise(count: MailboxAckScanner.maximumScanFiles)
        let validHead = try fixture.publishAck(for: fixture.first)
        try fixture.assertAuthenticAcknowledgment(for: fixture.first)
        let invalidBytes = try fixture.invalidateAcknowledgmentSignature(at: validHead.url)
        XCTAssertNotEqual(invalidBytes, validHead.bytes)
        let components = try fixture.components()
        let envelopeID = try components.transport.finalizedEnvelopeID(itemID: fixture.first.id)
        let rejected = try components.scanner.scanExact(envelopeID: envelopeID)
        XCTAssertEqual(rejected.scannedFinalCount, 1)
        XCTAssertTrue(rejected.events.isEmpty)
        XCTAssertEqual(rejected.quarantine.records, [.authenticationFailed])
        let states = try fixture.states()
        let encrypted = try fixture.encryptedLocalFiles()

        for _ in 0 ..< 2 {
            _ = try await fixture.delivery().deliverPending()
            XCTAssertEqual(try fixture.states(), states)
            try fixture.assertWaitingForFirst()
            XCTAssertEqual(try fixture.encryptedLocalFiles(), encrypted)
            XCTAssertEqual(try Data(contentsOf: validHead.url), invalidBytes)
        }
        try fixture.reopenOutbox()
        XCTAssertEqual(try fixture.states(), states)
        try fixture.assertWaitingForFirst()
        XCTAssertEqual(try fixture.encryptedLocalFiles(), encrypted)
        try fixture.assertNoiseRemains(noise)
    }
}

@MainActor
private final class ForegroundReplayFixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let settings: ReceiverSettingsStore
    let proofs: CoreLaneUploadProofStore
    let cursors = ReplayCursorStore()
    let keyStore: MailboxKeyStore
    let identity: MailboxConnectionIdentityV1
    let ackContext: MailboxAckContext
    let receiverSigning: Curve25519.Signing.PrivateKey
    let receiverAgreement: Curve25519.KeyAgreement.PrivateKey
    let locator: MailboxResolvedLocatorV1
    let payload: Data
    let firstCheckpoint: FileOutboxCursorCheckpoint
    let secondCheckpoint: FileOutboxCursorCheckpoint
    let first: FileOutboxItem
    let second: FileOutboxItem
    private(set) var outbox: FileOutbox
    private let envelopeIDs = ReplayEnvelopeIDs()

    var binding: String { identity.opaqueBinding }

    init() throws {
        let runID = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductionMailboxDeliveryReplayTests-\(runID)")
        let suiteName = "ProductionMailboxDeliveryReplayTests.\(runID)"
        self.suiteName = suiteName
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: ReplayTokenStore(),
            preCutoverBackupStore: ReplayTokenStore()
        )
        proofs = CoreLaneUploadProofStore(userDefaults: defaults)
        keyStore = MailboxKeyStore(
            service: "synthetic.foreground-replay.\(runID)",
            keychain: RepairSyntheticMailboxKeychain()
        )
        let device = try keyStore.loadOrCreate()
        receiverSigning = try DeliveryProtocolV1TestSupport.signingKey("synthetic-replay-receiver-signing")
        receiverAgreement = try DeliveryProtocolV1TestSupport.agreementKey("synthetic-replay-receiver-agreement")
        let receiverID = Data(repeating: 0x71, count: 16)
        let deviceID = Data(repeating: 0x72, count: 16)
        identity = MailboxConnectionIdentityV1(
            receiverID: receiverID.hexV1,
            deviceID: deviceID.hexV1,
            devicePrincipal: "synthetic-replay-device",
            deviceSigningKeyID: device.signingKeyID,
            deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "ed25519", publicKey: receiverSigning.publicKey.rawRepresentation
            ),
            receiverAgreementKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "x25519", publicKey: receiverAgreement.publicKey.rawRepresentation
            ),
            receiverSigningPublicKey: receiverSigning.publicKey.rawRepresentation.base64URLEncodedString(),
            receiverAgreementPublicKey: receiverAgreement.publicKey.rawRepresentation.base64URLEncodedString(),
            opaqueBinding: Data(repeating: 0x73, count: 32).base64URLEncodedString(),
            connectionGeneration: 1
        )
        try settings.saveMailboxPairing(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-unused-replay-token",
            mailboxIdentity: identity,
            expectedGeneration: settings.receiverSettingsGenerationToken
        )
        ackContext = MailboxAckContext(
            receiverID: receiverID,
            deviceID: deviceID,
            receiverBindingID: identity.opaqueBinding,
            connectionGeneration: 1,
            deviceAgreementPrivateKey: try keyStore.agreementPrivateKey(),
            deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningPublicKey: receiverSigning.publicKey,
            receiverSigningKeyID: identity.receiverSigningKeyID,
            receiverAgreementPublicKey: receiverAgreement.publicKey,
            receiverAgreementKeyID: identity.receiverAgreementKeyID,
            deviceSigningPublicKey: try Curve25519.Signing.PublicKey(rawRepresentation: device.signingPublicKey),
            deviceSigningKeyID: device.signingKeyID
        )
        let provider = root.appendingPathComponent("provider")
        try FileManager.default.createDirectory(
            at: provider, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        locator = try MailboxLocatorV1.resolveIsolated(
            providerRoot: provider,
            containerIdentifier: "synthetic.foreground-replay",
            receiverComponent: identity.receiverID,
            deviceComponent: identity.deviceID,
            localRecordURL: root.appendingPathComponent("local/locator.json")
        )
        payload = try DeliveryProtocolV1TestSupport.data(
            DeliveryProtocolV1TestSupport.fixture("python").plaintext
        )
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        outbox.automaticSyncDiagnosticStore = AutomaticSyncDiagnosticStore(
            fileURL: root.appendingPathComponent("diagnostics.json")
        )
        firstCheckpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: identity.opaqueBinding,
            sourceKey: "synthetic-replay-source",
            cursorKind: "synthetic-anchor",
            cursorValue: "synthetic-first-cursor",
            coreLaneUploadProof: .steps
        )
        secondCheckpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: identity.opaqueBinding,
            sourceKey: firstCheckpoint.sourceKey,
            cursorKind: firstCheckpoint.cursorKind,
            cursorValue: "synthetic-second-cursor",
            coreLaneUploadProof: .workouts
        )
        let firstItems = try outbox.enqueueSequence(
            [payload], receiverIdentity: identity.opaqueBinding, cursorCheckpoint: firstCheckpoint
        )
        first = try XCTUnwrap(firstItems.first)
        let secondItems = try outbox.enqueueSequence(
            [payload], receiverIdentity: identity.opaqueBinding, cursorCheckpoint: secondCheckpoint
        )
        second = try XCTUnwrap(secondItems.first)
    }

    func removeTemporaryStores() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func reopenOutbox() throws {
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        outbox.automaticSyncDiagnosticStore = AutomaticSyncDiagnosticStore(
            fileURL: root.appendingPathComponent("diagnostics.json")
        )
    }

    func components() throws -> ProductionMailboxComponents {
        let locator = locator
        let envelopeIDs = envelopeIDs
        let lookup = FileOutboxMailboxAckLookup(
            outbox: outbox, deviceSigningPublicKey: ackContext.deviceSigningPublicKey
        )
        let transport = MailboxTransport(
            outbox: outbox,
            context: MailboxTransportContext(
                receiverID: ackContext.receiverID,
                deviceID: ackContext.deviceID,
                receiverBindingID: binding,
                connectionGeneration: ackContext.connectionGeneration,
                receiverAgreementPublicKey: ackContext.receiverAgreementPublicKey,
                receiverAgreementKeyID: ackContext.receiverAgreementKeyID,
                deviceSigningPublicKey: ackContext.deviceSigningPublicKey,
                deviceSigningKeyID: ackContext.deviceSigningKeyID
            ),
            sealer: DeliveryProtocolMailboxEnvelopeSealer(keyStore: keyStore),
            locate: { locator },
            publisher: POSIXMailboxEnvelopePublisher(),
            envelopeID: { envelopeIDs.next() },
            nowMilliseconds: { 1_782_000_000_123 },
            isCancelled: { false },
            observe: { url, digest in
                mailboxSHA256(try Data(contentsOf: url)) == digest
            }
        )
        return ProductionMailboxComponents(
            identity: identity,
            deviceSigningPublicKey: ackContext.deviceSigningPublicKey,
            ackContext: ackContext,
            transport: transport,
            ackLookup: lookup,
            scanner: MailboxAckScanner(context: ackContext, lookup: lookup, locate: { locator }),
            locate: { locator }
        )
    }

    func delivery() throws -> ProductionMailboxDelivery {
        let components = try components()
        return ProductionMailboxDelivery(
            settingsStore: settings,
            outbox: outbox,
            cursorStore: cursors,
            proofStore: proofs,
            keyStore: keyStore,
            componentsFactory: { components }
        )
    }

    func publishPending() async throws {
        let summary = try await delivery().deliverPending()
        XCTAssertEqual(summary.attemptedCount, 2)
        XCTAssertEqual(summary.finalizedCount, 0)
        XCTAssertEqual(summary.waitingCount, 2)
        XCTAssertEqual(try states().map(\.phase), [.providerObserved, .providerObserved])
        let components = try components()
        XCTAssertNotEqual(
            try components.transport.finalizedEnvelopeID(itemID: first.id),
            try components.transport.finalizedEnvelopeID(itemID: second.id)
        )
        try assertWaitingForFirst()
    }

    func publishAck(for item: FileOutboxItem) throws -> (url: URL, bytes: Data) {
        let envelopeID = try components().transport.finalizedEnvelopeID(itemID: item.id)
        let bytes = try DeliveryProtocolV1.sealAck(
            committedReceipt(payload: payload),
            context: DeliveryAckSealContext(
                envelopeID: envelopeID,
                receiverID: ackContext.receiverID,
                deviceID: ackContext.deviceID,
                connectionGeneration: ackContext.connectionGeneration,
                deviceAgreementPublicKey: ackContext.deviceAgreementPrivateKey.publicKey,
                receiverSigningPrivateKey: receiverSigning,
                receiverAgreementPrivateKey: receiverAgreement
            )
        )
        let lane = try XCTUnwrap(locator.lanes[.acks])
        let name = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .acknowledgment)
        let url = lane.appendingPathComponent(name)
        try bytes.write(to: url, options: [.withoutOverwriting])
        return (url, bytes)
    }

    func publishEarlierCanonicalNoise(count: Int) throws -> [String] {
        let lane = try XCTUnwrap(locator.lanes[.acks])
        let components = try components()
        let targetIDs = try [first, second].map {
            try components.transport.finalizedEnvelopeID(itemID: $0.id).hexV1
        }
        XCTAssertEqual(targetIDs, [Data(repeating: 0x01, count: 16).hexV1, Data(repeating: 0x02, count: 16).hexV1])
        let targetNames = try targetIDs.map {
            try MailboxLayoutV1.finalFileName(identifier: $0, kind: .acknowledgment)
        }
        var names: [String] = []
        for index in 0 ..< count {
            let suffix = String(index, radix: 16)
            let identifier = String(repeating: "0", count: 32 - suffix.count) + suffix
            let name = try MailboxLayoutV1.finalFileName(identifier: identifier, kind: .acknowledgment)
            XCTAssertFalse(targetIDs.contains(identifier))
            for target in targetNames {
                XCTAssertLessThan(name, target)
            }
            XCTAssertEqual(
                try MailboxLayoutV1.classify(fileName: name, in: .acks, byteCount: 0),
                .final(kind: .acknowledgment, identifier: identifier)
            )
            let url = lane.appendingPathComponent(name)
            try Data().write(to: url, options: [.withoutOverwriting])
            XCTAssertEqual(try Data(contentsOf: url).count, 0)
            names.append(name)
        }
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(Set(names).count, count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lane.path).sorted(), names)
        return names
    }

    func assertNoiseRemains(_ names: [String]) throws {
        let lane = try XCTUnwrap(locator.lanes[.acks])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: lane.path)
        XCTAssertTrue(Set(names).isSubset(of: Set(remaining)))
    }

    func assertAuthenticAcknowledgment(for item: FileOutboxItem) throws {
        let components = try components()
        let envelopeID = try components.transport.finalizedEnvelopeID(itemID: item.id)
        let before = try states()
        let report = try components.scanner.scanExact(envelopeID: envelopeID)
        XCTAssertEqual(report.scannedFinalCount, 1)
        XCTAssertEqual(report.events.map(\.envelopeID), [envelopeID])
        XCTAssertEqual(report.events.map(\.classification), [.committed])
        XCTAssertTrue(report.quarantine.records.isEmpty)
        XCTAssertEqual(try states(), before)
    }

    func invalidateAcknowledgmentSignature(at url: URL) throws -> Data {
        let validBytes = try Data(contentsOf: url)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: validBytes) as? [String: Any])
        let signature = try XCTUnwrap(fields["signature"] as? String)
        XCTAssertEqual(signature.count, 86)
        let replacement = (signature.first == "A" ? "B" : "A") + String(signature.dropFirst())
        let invalidBytes = Data(String(decoding: validBytes, as: UTF8.self).replacingOccurrences(
            of: "\"signature\":\"\(signature)\"",
            with: "\"signature\":\"\(replacement)\""
        ).utf8)
        XCTAssertNotEqual(invalidBytes, validBytes)
        try invalidBytes.write(to: url)
        return invalidBytes
    }

    func encryptedLocalFiles() throws -> [URL: Data] {
        var files: [URL: Data] = [:]
        for item in [first, second] {
            let envelope = try XCTUnwrap(outbox.mailboxBinding(for: item.id))
            let url = outbox.directoryURL.appendingPathComponent(envelope.envelopeFilename)
            files[url] = try Data(contentsOf: url)
        }
        return files
    }

    func deliverForegroundOpportunities(count: Int) async throws {
        let generation = settings.receiverSettingsGenerationToken
        let ownership = try states().map(\.ownership)
        let expectedCursors = [firstCheckpoint.cursorValue, secondCheckpoint.cursorValue]
        for _ in 0 ..< count {
            if try outbox.pendingItems().isEmpty { break }
            _ = try await delivery().deliverPending()
            XCTAssertEqual(cursors.writes, Array(expectedCursors.prefix(cursors.writes.count)))
            XCTAssertEqual(settings.receiverSettingsGenerationToken, generation)
            XCTAssertEqual(try states().map(\.ownership), ownership)
            XCTAssertNil(try currentCursor(receiverBindingID: "synthetic-other-binding"))
            for lane in CoreLaneUploadProofStore.Lane.allCases {
                XCTAssertFalse(proofs.hasUploadedRecords(lane: lane, receiverBindingID: "synthetic-other-binding"))
            }
        }
    }

    func currentCursor(receiverBindingID: String? = nil) throws -> String? {
        try cursors.cursorValue(
            receiverBindingID: receiverBindingID ?? binding,
            sourceKey: firstCheckpoint.sourceKey,
            cursorKind: firstCheckpoint.cursorKind
        )
    }

    func states() throws -> [FileOutboxDeliveryStateV1] {
        try [first, second].map { try XCTUnwrap(outbox.deliveryState(for: $0.id)) }
    }

    func assertWaitingForFirst() throws {
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [first.id, second.id])
        XCTAssertEqual(try outbox.pendingCursorCheckpoint(), firstCheckpoint)
        XCTAssertNil(try currentCursor())
        XCTAssertTrue(cursors.writes.isEmpty)
        XCTAssertEqual(try outbox.deliveryState(for: first.id)?.phase, .providerObserved)
        XCTAssertNotEqual(try outbox.deliveryState(for: second.id)?.phase, .committedFinalized)
        for item in [first, second] {
            XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
            let envelope = try XCTUnwrap(outbox.mailboxBinding(for: item.id))
            XCTAssertEqual(
                mailboxSHA256(try Data(contentsOf: outbox.directoryURL.appendingPathComponent(envelope.envelopeFilename))),
                envelope.envelopeSHA256
            )
        }
        for lane in CoreLaneUploadProofStore.Lane.allCases {
            XCTAssertFalse(proofs.hasUploadedRecords(lane: lane, receiverBindingID: binding))
        }
    }

    func assertCompleted() throws {
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertNil(try outbox.pendingCursorCheckpoint())
        XCTAssertEqual(try states().map(\.phase), [.committedFinalized, .committedFinalized])
        XCTAssertEqual(cursors.writes, [firstCheckpoint.cursorValue, secondCheckpoint.cursorValue])
        XCTAssertEqual(try currentCursor(), secondCheckpoint.cursorValue)
        XCTAssertNil(try currentCursor(receiverBindingID: "synthetic-other-binding"))
        for item in [first, second] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: outbox.directoryURL.appendingPathComponent("\(item.id).hbe").path
            ))
        }
        for lane in CoreLaneUploadProofStore.Lane.allCases {
            XCTAssertTrue(proofs.hasUploadedRecords(lane: lane, receiverBindingID: binding))
            XCTAssertFalse(proofs.hasUploadedRecords(lane: lane, receiverBindingID: "synthetic-other-binding"))
        }
    }
}

private final class ReplayCursorStore: SyncCursorStoring {
    private let storage = CountingSyncCursorStore()
    private(set) var writes: [String] = []

    func cursorValue(receiverBindingID: String, sourceKey: String, cursorKind: String) throws -> String? {
        try storage.cursorValue(receiverBindingID: receiverBindingID, sourceKey: sourceKey, cursorKind: cursorKind)
    }

    func saveCursorValue(_ value: String, receiverBindingID: String, sourceKey: String, cursorKind: String) throws {
        try storage.saveCursorValue(value, receiverBindingID: receiverBindingID, sourceKey: sourceKey, cursorKind: cursorKind)
        writes.append(value)
    }
}

private final class ReplayTokenStore: ReceiverTokenStoring {
    private var token = ""

    func loadToken() throws -> String { token }

    func saveToken(_ token: String) throws { self.token = token }
}

private final class ReplayEnvelopeIDs {
    private var value: UInt8 = 0

    func next() -> Data {
        value += 1
        return Data(repeating: value, count: 16)
    }
}
#endif

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
final class ProductionMailboxPublicationSafetyTests: XCTestCase {
    func testForegroundCancellationJoinsPublicationAndRetriesWithoutRetirement() async throws {
        try await assertPublicationInterruption(background: false)
    }

    func testBackgroundCancellationJoinsPublicationAndRetriesWithoutRetirement() async throws {
        try await assertPublicationInterruption(background: true)
    }

    func testBackgroundCancellationJoinsThrowingPublicationBeforeReportingCancellation() async throws {
        try await assertPublicationInterruption(background: true, genericError: true)
    }

    func testCurrentGenericPublicationErrorPreservesPhaseErrorAndRetryableArtifacts() async throws {
        try await assertPublicationInterruption(background: true, genericError: true, cancel: false)
    }

    func testForegroundRejectsStaleGenerationAfterSuccessfulPublication() async throws {
        try await assertStalePublication(background: false, mutation: .generation, genericError: false)
    }

    func testBackgroundRejectsStaleGenerationAfterGenericPublicationError() async throws {
        try await assertStalePublication(background: true, mutation: .generation, genericError: true)
    }

    func testForegroundRejectsChangedOwnershipAfterSuccessfulPublication() async throws {
        try await assertStalePublication(background: false, mutation: .ownership, genericError: false)
    }

    func testBackgroundRejectsChangedOwnershipAfterGenericPublicationError() async throws {
        try await assertStalePublication(background: true, mutation: .ownership, genericError: true)
    }

    func testBackgroundRejectsRevokedAdmissionAfterSuccessfulPublication() async throws {
        try await assertStalePublication(background: true, mutation: .admission, genericError: false)
    }

    private func assertPublicationInterruption(
        background: Bool,
        genericError: Bool = false,
        cancel: Bool = true
    ) async throws {
        let barrier = PublicationSafetyBarrier(genericError: genericError)
        let fixture = try ForegroundReplayFixture(
            publisher: PublicationSafetyPublisher(barrier: barrier),
            isCancelled: { withUnsafeCurrentTask { $0?.isCancelled ?? false } }
        )
        defer { fixture.removeTemporaryStores() }
        let delivery = try fixture.delivery()
        let diagnostics = try Self.diagnosticBytes(fixture)
        let operation = Task { @MainActor in
            defer { barrier.recordCompletion() }
            if background {
                _ = try await delivery.publishPendingFIFOHead()
            } else {
                _ = try await delivery.deliverPending()
            }
        }
        barrier.startDriver(cancel: cancel ? operation : nil)
        let result = await operation.result
        try await barrier.joinDriver()
        if cancel {
            assertCancelled(result)
        } else {
            XCTAssertThrowsError(try result.get()) { error in
                XCTAssertEqual(error as? ProductionMailboxDeliveryPhaseError, .initialAdvance)
            }
        }
        XCTAssertTrue(barrier.observation().entered)
        XCTAssertFalse(barrier.observation().completedBeforeRelease)
        XCTAssertEqual(try Self.diagnosticBytes(fixture), diagnostics)
        try assertRetained(fixture)
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.first.id)?.phase, .encrypted)
        XCTAssertNil(try fixture.outbox.mailboxBinding(for: fixture.second.id))
        let envelope = try firstPublishedEnvelope(fixture)

        try fixture.reopenOutbox()
        try assertRetained(fixture)
        XCTAssertEqual(try firstPublishedEnvelope(fixture), envelope)
        if background {
            let retry = try await fixture.delivery().publishPendingFIFOHead()
            XCTAssertEqual(retry.attemptedCount, 1)
            XCTAssertEqual(retry.finalizedCount, 0)
            XCTAssertEqual(retry.waitingCount, 2)
            XCTAssertNil(try fixture.outbox.mailboxBinding(for: fixture.second.id))
        } else {
            let retry = try await fixture.delivery().deliverPending()
            XCTAssertEqual(retry.attemptedCount, 2)
            XCTAssertEqual(retry.finalizedCount, 0)
            XCTAssertEqual(retry.waitingCount, 2)
            try fixture.assertWaitingForFirst()
        }
        try assertRetained(fixture)
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.first.id)?.phase, .providerObserved)
        XCTAssertEqual(try firstPublishedEnvelope(fixture), envelope)
    }

    private enum Mutation: Sendable {
        case generation, ownership, admission
    }

    private func assertStalePublication(background: Bool, mutation: Mutation, genericError: Bool) async throws {
        let barrier = PublicationSafetyBarrier(genericError: genericError)
        let fixture = try ForegroundReplayFixture(publisher: PublicationSafetyPublisher(barrier: barrier))
        defer { fixture.removeTemporaryStores() }
        let capture = PublicationSafetyCapture()
        let delivery = try fixture.delivery()
        let operation = Task { @MainActor in
            defer { barrier.recordCompletion() }
            if background {
                _ = try await delivery.publishPendingFIFOHead()
            } else {
                _ = try await delivery.deliverPending()
            }
        }
        barrier.startDriver(action: {
            let state = try XCTUnwrap(fixture.outbox.deliveryState(for: fixture.first.id))
            XCTAssertEqual(state.phase, .encrypted)
            switch mutation {
            case .generation:
                let previous = fixture.settings.receiverSettingsGenerationToken
                try fixture.settings.invalidateReceiverSettingsGeneration()
                XCTAssertNotEqual(fixture.settings.receiverSettingsGenerationToken, previous)
            case .ownership:
                _ = try fixture.outbox.compareAndSetDeliveryState(
                    itemID: fixture.first.id,
                    expected: state,
                    updated: state.assigning(OutboxDeliveryOwnershipV1(
                        receiverGeneration: "synthetic-replacement-generation",
                        resetEpoch: nil,
                        ackContext: fixture.ackContext
                    ))
                )
            case .admission:
                try self.assertRetained(fixture)
                capture.pending = try fixture.outbox.pendingItems()
                let first = try XCTUnwrap(capture.pending?.first)
                let binding = try XCTUnwrap(first.mailboxBinding)
                XCTAssertNil(try fixture.outbox.mailboxBinding(for: fixture.second.id))
                let before = try Self.localFiles(fixture)
                let envelopeURL = fixture.outbox.directoryURL.appendingPathComponent(binding.envelopeFilename)
                let matches = before.filter { $0.key.standardizedFileURL.path == envelopeURL.standardizedFileURL.path }
                XCTAssertEqual(matches.count, 1)
                let bytes = try XCTUnwrap(matches.first?.value)
                XCTAssertEqual(mailboxSHA256(bytes), binding.envelopeSHA256)
                let claims = try DeliveryProtocolV1.inspectDelivery(
                    bytes, senderSigningPublicKey: fixture.ackContext.deviceSigningPublicKey
                )
                XCTAssertEqual(claims.receiverID, fixture.ackContext.receiverID)
                XCTAssertEqual(claims.deviceID, fixture.ackContext.deviceID)
                XCTAssertEqual(claims.connectionGeneration, fixture.ackContext.connectionGeneration)
                XCTAssertEqual(claims.receiverAgreementKeyID, fixture.ackContext.receiverAgreementKeyID)
                XCTAssertEqual(claims.senderSigningKeyID, fixture.ackContext.deviceSigningKeyID)
                XCTAssertEqual(claims.payloadSHA256, binding.payloadSHA256)
                let lane = try XCTUnwrap(fixture.locator.lanes[.deliveries])
                let name = try MailboxLayoutV1.finalFileName(identifier: claims.envelopeID.hexV1, kind: .delivery)
                capture.publication = (lane.appendingPathComponent(name), bytes)
                try FileOutbox.beginDestructiveRecovery(directory: fixture.outbox.directoryURL)
                let after = try Self.localFiles(fixture)
                XCTAssertEqual(after.filter { $0.key.lastPathComponent != ".clear-intent" }, before)
                capture.files = after
                return
            }
            capture.pending = try fixture.outbox.pendingItems()
            capture.files = try Self.localFiles(fixture)
        })
        let result = await operation.result
        try await barrier.joinDriver()
        assertCancelled(result)
        XCTAssertTrue(barrier.observation().entered)
        XCTAssertTrue(barrier.observation().actionBeforeRelease)
        XCTAssertFalse(barrier.observation().completedBeforeRelease)
        if case .admission = mutation {
            XCTAssertEqual(try Self.localFiles(fixture), try XCTUnwrap(capture.files))
            XCTAssertTrue(fixture.outbox.clearIntentIsActive)
            XCTAssertNil(try fixture.currentCursor())
            XCTAssertTrue(fixture.cursors.writes.isEmpty)
            for item in [fixture.first, fixture.second] {
                XCTAssertEqual(try Data(contentsOf: item.fileURL), fixture.payload)
            }
            for lane in CoreLaneUploadProofStore.Lane.allCases {
                XCTAssertFalse(fixture.proofs.hasUploadedRecords(lane: lane, receiverBindingID: fixture.binding))
            }
            let acks = try XCTUnwrap(fixture.locator.lanes[.acks])
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: acks.path).isEmpty)
            let publication = try XCTUnwrap(capture.publication)
            XCTAssertEqual(try Data(contentsOf: publication.url), publication.bytes)
            return
        }
        XCTAssertEqual(try fixture.outbox.pendingItems(), try XCTUnwrap(capture.pending))
        XCTAssertEqual(try Self.localFiles(fixture), try XCTUnwrap(capture.files))
        try assertRetained(fixture)
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.first.id)?.phase, .encrypted)
        XCTAssertNil(try fixture.outbox.mailboxBinding(for: fixture.second.id))
        _ = try firstPublishedEnvelope(fixture)
    }

    private func assertCancelled(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            XCTFail("Cancelled or stale publication must not report progress")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Expected cancellation, received \(error)")
        }
    }

    private func assertRetained(_ fixture: ForegroundReplayFixture) throws {
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [fixture.first.id, fixture.second.id])
        XCTAssertEqual(try fixture.outbox.pendingCursorCheckpoint(), fixture.firstCheckpoint)
        XCTAssertNil(try fixture.currentCursor())
        XCTAssertTrue(fixture.cursors.writes.isEmpty)
        for item in [fixture.first, fixture.second] {
            XCTAssertEqual(try Data(contentsOf: item.fileURL), fixture.payload)
        }
        for lane in CoreLaneUploadProofStore.Lane.allCases {
            XCTAssertFalse(fixture.proofs.hasUploadedRecords(lane: lane, receiverBindingID: fixture.binding))
        }
        let acks = try XCTUnwrap(fixture.locator.lanes[.acks])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: acks.path).isEmpty)
    }

    private func firstPublishedEnvelope(_ fixture: ForegroundReplayFixture) throws -> Data {
        let binding = try XCTUnwrap(fixture.outbox.mailboxBinding(for: fixture.first.id))
        let bytes = try Data(contentsOf: fixture.outbox.directoryURL.appendingPathComponent(binding.envelopeFilename))
        XCTAssertEqual(mailboxSHA256(bytes), binding.envelopeSHA256)
        let envelopeID = try fixture.components().transport.finalizedEnvelopeID(itemID: fixture.first.id)
        let name = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .delivery)
        let lane = try XCTUnwrap(fixture.locator.lanes[.deliveries])
        XCTAssertEqual(try Data(contentsOf: lane.appendingPathComponent(name)), bytes)
        return bytes
    }

    private static func localFiles(_ fixture: ForegroundReplayFixture) throws -> [URL: Data] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: fixture.outbox.directoryURL, includingPropertiesForKeys: nil
        )
        var files = try Dictionary(uniqueKeysWithValues: urls.map { ($0, try Data(contentsOf: $0)) })
        if let diagnostics = try diagnosticBytes(fixture) {
            files[fixture.root.appendingPathComponent("diagnostics.json")] = diagnostics
        }
        return files
    }

    private static func diagnosticBytes(_ fixture: ForegroundReplayFixture) throws -> Data? {
        let url = fixture.root.appendingPathComponent("diagnostics.json")
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
}

@MainActor
private final class PublicationSafetyCapture {
    var pending: [FileOutboxItem]?
    var files: [URL: Data]?
    var publication: (url: URL, bytes: Data)?
}

private struct PublicationSafetyPublisher: MailboxEnvelopePublishing {
    let barrier: PublicationSafetyBarrier

    func publish(_ envelope: Data, finalName: String, locator: MailboxResolvedLocatorV1) throws -> URL {
        let barrier = barrier
        barrier.beginPublication()
        defer { barrier.endPublication() }
        let publisher = POSIXMailboxEnvelopePublisher { boundary in
            if boundary == .renameTemporary { barrier.blockFirstPublication() }
        }
        let url = try publisher.publish(envelope, finalName: finalName, locator: locator)
        if barrier.takeGenericError() { throw Failure.afterAtomicPublication }
        return url
    }

    private enum Failure: Error {
        case afterAtomicPublication
    }
}

// NSLock protects every mutable field; only synchronization and Sendable task handles
// cross threads. The optional fixture mutation runs and is joined on MainActor.
private final class PublicationSafetyBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let actionDone = DispatchSemaphore(value: 0)
    private let completed = DispatchSemaphore(value: 0)
    private let driver = DispatchGroup()
    private let publication = DispatchGroup()
    private var didEnter = false
    private var observedEntry = false
    private var released = false
    private var completedBeforeRelease = false
    private var actionBeforeRelease = false
    private var genericError: Bool
    private var actionTask: Task<Void, any Error>?

    init(genericError: Bool) { self.genericError = genericError }

    func beginPublication() { publication.enter() }

    func endPublication() { publication.leave() }

    func blockFirstPublication() {
        let first = lock.withLock {
            guard !didEnter else { return false }
            didEnter = true
            return true
        }
        guard first else { return }
        entered.signal()
        release.wait()
    }

    func takeGenericError() -> Bool {
        lock.withLock {
            let result = genericError
            genericError = false
            return result
        }
    }

    func recordCompletion() {
        lock.withLock { completedBeforeRelease = !released }
        completed.signal()
    }

    func startDriver(
        cancel operation: Task<Void, any Error>? = nil,
        action: (@MainActor @Sendable () throws -> Void)? = nil
    ) {
        driver.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { driver.leave() }
            let observed = entered.wait(timeout: .now() + 10) == .success
            lock.withLock { observedEntry = observed }
            if observed {
                operation?.cancel()
                if let action {
                    let task = Task { @MainActor [self] in
                        defer { actionDone.signal() }
                        try action()
                        lock.withLock { actionBeforeRelease = !released }
                    }
                    lock.withLock { actionTask = task }
                    _ = actionDone.wait(timeout: .now() + 5)
                }
                _ = completed.wait(timeout: .now() + 1)
            }
            lock.withLock { released = true }
            release.signal()
        }
    }

    func joinDriver() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            driver.notify(queue: .global()) { continuation.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            publication.notify(queue: .global()) { continuation.resume() }
        }
        let task = lock.withLock { actionTask }
        try await task?.value
    }

    func observation() -> (entered: Bool, actionBeforeRelease: Bool, completedBeforeRelease: Bool) {
        lock.withLock { (observedEntry, actionBeforeRelease, completedBeforeRelease) }
    }
}

@MainActor
final class ProductionMailboxPublicationResponsivenessTests: XCTestCase {
    func testForegroundPublicationKeepsMainActorResponsiveBeforeIORelease() async throws {
        let barrier = PublicationResponsivenessBarrier()
        let fixture = try ForegroundReplayFixture(publisher: POSIXMailboxEnvelopePublisher { boundary in
            if boundary == .renameTemporary { barrier.blockFirstPublication() }
        })
        defer { fixture.removeTemporaryStores() }
        let delivery = try fixture.delivery()
        barrier.startDriver()

        do {
            let summary = try await delivery.deliverPending()
            XCTAssertEqual(summary.attemptedCount, 2)
            XCTAssertEqual(summary.finalizedCount, 0)
            XCTAssertEqual(summary.waitingCount, 2)
            XCTAssertEqual(summary.terminalCount, 0)
        } catch {
            XCTFail("Publication must finish normally after the barrier releases: \(error)")
        }

        await barrier.joinDriver()
        let observation = barrier.observation()
        XCTAssertTrue(observation.entered, "The driver must observe the real atomic publisher boundary")
        XCTAssertTrue(observation.heartbeatRan, "Join the MainActor heartbeat even when it runs after release")
        XCTAssertTrue(observation.heartbeatBeforeRelease, "MainActor must run while publication is still blocked")
        try assertUnacknowledgedPublication(fixture, published: [fixture.first, fixture.second])
    }

    func testBackgroundFIFOHeadPublicationKeepsMainActorResponsiveBeforeIORelease() async throws {
        let barrier = PublicationResponsivenessBarrier()
        let fixture = try ForegroundReplayFixture(publisher: POSIXMailboxEnvelopePublisher { boundary in
            if boundary == .renameTemporary { barrier.blockFirstPublication() }
        })
        defer { fixture.removeTemporaryStores() }
        let delivery = try fixture.delivery()
        barrier.startDriver()

        do {
            let summary = try await delivery.publishPendingFIFOHead()
            XCTAssertEqual(summary.phase, .publishFIFOHead)
            XCTAssertEqual(summary.attemptedCount, 1)
            XCTAssertEqual(summary.finalizedCount, 0)
            XCTAssertEqual(summary.waitingCount, 2)
            XCTAssertEqual(summary.terminalCount, 0)
        } catch {
            XCTFail("Publication must finish normally after the barrier releases: \(error)")
        }

        await barrier.joinDriver()
        let observation = barrier.observation()
        XCTAssertTrue(observation.entered, "The driver must observe the real atomic publisher boundary")
        XCTAssertTrue(observation.heartbeatRan, "Join the MainActor heartbeat even when it runs after release")
        XCTAssertTrue(observation.heartbeatBeforeRelease, "MainActor must run while publication is still blocked")
        try assertUnacknowledgedPublication(fixture, published: [fixture.first])
    }

    func testNonblockingForegroundPublicationPreservesPendingUntilAcknowledgment() async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        let summary = try await fixture.delivery().deliverPending()
        XCTAssertEqual(summary.attemptedCount, 2)
        XCTAssertEqual(summary.finalizedCount, 0)
        XCTAssertEqual(summary.waitingCount, 2)
        XCTAssertEqual(summary.terminalCount, 0)
        try assertUnacknowledgedPublication(fixture, published: [fixture.first, fixture.second])
        let encrypted = try fixture.encryptedLocalFiles()
        let states = try fixture.states()

        try fixture.reopenOutbox()
        XCTAssertEqual(try fixture.states(), states)
        try assertUnacknowledgedPublication(fixture, published: [fixture.first, fixture.second])
        let repeated = try await fixture.delivery().deliverPending()
        XCTAssertEqual(repeated.finalizedCount, 0)
        XCTAssertEqual(repeated.waitingCount, 2)
        XCTAssertEqual(try fixture.encryptedLocalFiles(), encrypted)
        try assertUnacknowledgedPublication(fixture, published: [fixture.first, fixture.second])

        _ = try fixture.publishAck(for: fixture.first)
        _ = try fixture.publishAck(for: fixture.second)
        let acknowledged = try await fixture.delivery().deliverPending()
        XCTAssertEqual(acknowledged.finalizedCount, 2)
        XCTAssertEqual(acknowledged.waitingCount, 0)
        try fixture.assertCompleted()
    }

    func testNonblockingBackgroundPublicationPreservesFIFOHeadBoundary() async throws {
        let fixture = try ForegroundReplayFixture()
        defer { fixture.removeTemporaryStores() }
        let summary = try await fixture.delivery().publishPendingFIFOHead()
        XCTAssertEqual(summary.phase, .publishFIFOHead)
        XCTAssertEqual(summary.attemptedCount, 1)
        XCTAssertEqual(summary.finalizedCount, 0)
        XCTAssertEqual(summary.waitingCount, 2)
        XCTAssertEqual(summary.terminalCount, 0)
        try assertUnacknowledgedPublication(fixture, published: [fixture.first])
        let firstState = try fixture.outbox.deliveryState(for: fixture.first.id)
        let firstEnvelope = try publishedEnvelope(fixture, item: fixture.first)

        try fixture.reopenOutbox()
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.first.id), firstState)
        try assertUnacknowledgedPublication(fixture, published: [fixture.first])
        let repeated = try await fixture.delivery().publishPendingFIFOHead()
        XCTAssertEqual(repeated.finalizedCount, 0)
        XCTAssertEqual(repeated.waitingCount, 2)
        XCTAssertEqual(try publishedEnvelope(fixture, item: fixture.first), firstEnvelope)
        try assertUnacknowledgedPublication(fixture, published: [fixture.first])
        let noAck = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(
            afterAcknowledgmentCheckpoint: nil
        )
        XCTAssertEqual(noAck.finalizedCount, 0)
        try assertUnacknowledgedPublication(fixture, published: [fixture.first])

        _ = try fixture.publishAck(for: fixture.first)
        let firstAck = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(
            afterAcknowledgmentCheckpoint: nil
        )
        XCTAssertEqual(firstAck.finalizedCount, 1)
        XCTAssertEqual(firstAck.waitingCount, 1)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [fixture.second.id])
        XCTAssertEqual(try fixture.outbox.pendingCursorCheckpoint(), fixture.secondCheckpoint)
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.first.id)?.phase, .committedFinalized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.first.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.outbox.directoryURL.appendingPathComponent("\(fixture.first.id).hbe").path
        ))
        XCTAssertEqual(
            try fixture.outbox.deliveryState(for: fixture.second.id),
            FileOutboxDeliveryStateV1.stable(.collected, ownership: nil)
        )
        XCTAssertNil(try fixture.outbox.mailboxBinding(for: fixture.second.id))
        XCTAssertEqual(try Data(contentsOf: fixture.second.fileURL), fixture.payload)
        XCTAssertEqual(fixture.cursors.writes, [fixture.firstCheckpoint.cursorValue])
        XCTAssertEqual(try fixture.currentCursor(), fixture.firstCheckpoint.cursorValue)

        let second = try await fixture.delivery().publishPendingFIFOHead()
        XCTAssertEqual(second.attemptedCount, 1)
        XCTAssertEqual(second.finalizedCount, 0)
        XCTAssertEqual(second.waitingCount, 1)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [fixture.second.id])
        XCTAssertEqual(try fixture.outbox.pendingCursorCheckpoint(), fixture.secondCheckpoint)
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.second.id)?.phase, .providerObserved)
        XCTAssertEqual(try Data(contentsOf: fixture.second.fileURL), fixture.payload)
        _ = try publishedEnvelope(fixture, item: fixture.second)
        XCTAssertEqual(fixture.cursors.writes, [fixture.firstCheckpoint.cursorValue])
        XCTAssertEqual(try fixture.currentCursor(), fixture.firstCheckpoint.cursorValue)
        XCTAssertTrue(fixture.proofs.hasUploadedRecords(lane: .steps, receiverBindingID: fixture.binding))
        XCTAssertFalse(fixture.proofs.hasUploadedRecords(lane: .workouts, receiverBindingID: fixture.binding))

        _ = try fixture.publishAck(for: fixture.second)
        let secondAck = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(
            afterAcknowledgmentCheckpoint: nil
        )
        XCTAssertEqual(secondAck.finalizedCount, 1)
        XCTAssertEqual(secondAck.waitingCount, 0)
        try fixture.assertCompleted()
    }

    private func assertUnacknowledgedPublication(
        _ fixture: ForegroundReplayFixture,
        published: [FileOutboxItem]
    ) throws {
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [fixture.first.id, fixture.second.id])
        XCTAssertEqual(try fixture.outbox.pendingCursorCheckpoint(), fixture.firstCheckpoint)
        XCTAssertNil(try fixture.currentCursor())
        XCTAssertTrue(fixture.cursors.writes.isEmpty)
        var finalNames: [String] = []
        for item in [fixture.first, fixture.second] {
            XCTAssertEqual(try Data(contentsOf: item.fileURL), fixture.payload)
            if published.contains(where: { $0.id == item.id }) {
                XCTAssertEqual(try fixture.outbox.deliveryState(for: item.id)?.phase, .providerObserved)
                _ = try publishedEnvelope(fixture, item: item)
                let envelopeID = try fixture.components().transport.finalizedEnvelopeID(itemID: item.id)
                finalNames.append(try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .delivery))
            } else {
                XCTAssertEqual(
                    try fixture.outbox.deliveryState(for: item.id),
                    FileOutboxDeliveryStateV1.stable(.collected, ownership: nil)
                )
                XCTAssertNil(try fixture.outbox.mailboxBinding(for: item.id))
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.outbox.directoryURL.appendingPathComponent("\(item.id).hbe").path
                ))
            }
        }
        let lane = try XCTUnwrap(fixture.locator.lanes[.deliveries])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lane.path).sorted(), finalNames.sorted())
        for lane in CoreLaneUploadProofStore.Lane.allCases {
            XCTAssertFalse(fixture.proofs.hasUploadedRecords(lane: lane, receiverBindingID: fixture.binding))
        }
    }

    private func publishedEnvelope(_ fixture: ForegroundReplayFixture, item: FileOutboxItem) throws -> Data {
        let binding = try XCTUnwrap(fixture.outbox.mailboxBinding(for: item.id))
        let bytes = try Data(contentsOf: fixture.outbox.directoryURL.appendingPathComponent(binding.envelopeFilename))
        XCTAssertEqual(mailboxSHA256(bytes), binding.envelopeSHA256)
        let envelopeID = try fixture.components().transport.finalizedEnvelopeID(itemID: item.id)
        let name = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .delivery)
        let lane = try XCTUnwrap(fixture.locator.lanes[.deliveries])
        XCTAssertEqual(try Data(contentsOf: lane.appendingPathComponent(name)), bytes)
        return bytes
    }
}

// Only lock-protected observations and thread-safe synchronization objects cross threads;
// the driver and heartbeat never capture the MainActor fixture or production dependencies.
private final class PublicationResponsivenessBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let heartbeat = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let driver = DispatchGroup()
    private var didEnter = false
    private var driverObservedEntry = false
    private var released = false
    private var heartbeatRan = false
    private var heartbeatBeforeRelease = false
    private var heartbeatTask: Task<Void, Never>?

    func blockFirstPublication() {
        let shouldBlock = lock.withLock {
            guard !didEnter else { return false }
            didEnter = true
            return true
        }
        guard shouldBlock else { return }
        entered.signal()
        release.wait()
    }

    func startDriver() {
        driver.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { driver.leave() }
            let observedEntry = entered.wait(timeout: .now() + 10) == .success
            lock.withLock { driverObservedEntry = observedEntry }
            if observedEntry {
                let task = Task { @MainActor [self] in
                    lock.withLock {
                        heartbeatRan = true
                        heartbeatBeforeRelease = !released
                    }
                    heartbeat.signal()
                }
                lock.withLock { heartbeatTask = task }
                // This deadline only bounds a blocked test; success requires the heartbeat
                // to record execution before the driver releases the actual publisher.
                _ = heartbeat.wait(timeout: .now() + 5)
            }
            lock.withLock { released = true }
            release.signal()
        }
    }

    func joinDriver() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            driver.notify(queue: .global()) { continuation.resume() }
        }
        let task = lock.withLock { heartbeatTask }
        await task?.value
    }

    func observation() -> (entered: Bool, heartbeatRan: Bool, heartbeatBeforeRelease: Bool) {
        lock.withLock { (driverObservedEntry, heartbeatRan, heartbeatBeforeRelease) }
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
    private let publisher: any MailboxEnvelopePublishing
    private let isCancelled: () -> Bool

    var binding: String { identity.opaqueBinding }

    init(
        publisher: any MailboxEnvelopePublishing = POSIXMailboxEnvelopePublisher(),
        isCancelled: @escaping () -> Bool = { false }
    ) throws {
        self.publisher = publisher
        self.isCancelled = isCancelled
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
            publisher: publisher,
            envelopeID: { envelopeIDs.next() },
            nowMilliseconds: { 1_782_000_000_123 },
            isCancelled: isCancelled,
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

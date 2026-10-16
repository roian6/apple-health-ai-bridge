import Dispatch
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxPublicationSuspensionTests: XCTestCase {
    @MainActor
    func testCancellationJoinsNativePublicationBeforeReturningAndRetainsEncryptedState() async throws {
        let harness = try OutboxDeliveryHarness()
        let publisher = HeldNativePublisher(failAfterRelease: false)
        defer { publisher.release.signal() }
        let finalizer = CountingOutboxDeliveryFinalizer()
        let coordinator = harness.coordinator(
            sealer: try CountingMailboxEnvelopeSealer(harness.fixture),
            publisher: publisher,
            finalizer: finalizer
        )
        let itemID = harness.fixture.item.id
        _ = try coordinator.advance(itemID: itemID)
        _ = try coordinator.advance(itemID: itemID)
        let encrypted = try coordinator.state(itemID: itemID)
        var returned = false
        let publication = Task { @MainActor in
            defer { returned = true }
            do {
                _ = try await coordinator.advanceAwaitingPublication(itemID: itemID)
                XCTFail("Cancelled publication must not commit delivery state")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected publication error: \(error)")
            }
        }
        let entered = await XCTWaiter.fulfillment(of: [publisher.entered], timeout: 2)
        XCTAssertEqual(entered, .completed)
        publication.cancel()
        await Task.yield()
        XCTAssertFalse(returned)
        XCTAssertEqual(try coordinator.state(itemID: itemID), encrypted)
        publisher.release.signal()
        await publication.value
        XCTAssertTrue(returned)
        XCTAssertEqual(try harness.fixture.deliveries().count, 1)
        XCTAssertEqual(try coordinator.state(itemID: itemID), encrypted)
        XCTAssertNotNil(try harness.fixture.outbox.pendingItem(id: itemID))
        XCTAssertEqual(finalizer.finalizeCount, 0)

        let restarted = harness.coordinator(
            sealer: NeverMailboxEnvelopeSealer(),
            publisher: FileProviderMailboxEnvelopePublisher(),
            finalizer: finalizer
        )
        let resumed = try await restarted.advanceAwaitingPublication(itemID: itemID)
        XCTAssertEqual(resumed.phase, .published)
        XCTAssertEqual(try harness.fixture.deliveries().count, 1)
    }

    @MainActor
    func testInvalidatedOwnerSuppressesBothPublicationSuccessAndGenericFailure() async throws {
        for failAfterRelease in [false, true] {
            let harness = try OutboxDeliveryHarness()
            let publisher = HeldNativePublisher(failAfterRelease: failAfterRelease)
            defer { publisher.release.signal() }
            var ownerIsCurrent = true
            let coordinator = harness.coordinator(
                sealer: try CountingMailboxEnvelopeSealer(harness.fixture),
                publisher: publisher,
                isCancelled: { !ownerIsCurrent },
                finalizer: CountingOutboxDeliveryFinalizer()
            )
            let itemID = harness.fixture.item.id
            _ = try coordinator.advance(itemID: itemID)
            _ = try coordinator.advance(itemID: itemID)
            let encrypted = try coordinator.state(itemID: itemID)
            let publication = Task { @MainActor in
                do {
                    _ = try await coordinator.advanceAwaitingPublication(itemID: itemID)
                    XCTFail("An invalidated owner must not commit a publication result")
                } catch is CancellationError {
                } catch {
                    XCTFail("Owner invalidation must supersede a generic I/O error: \(error)")
                }
            }
            let entered = await XCTWaiter.fulfillment(of: [publisher.entered], timeout: 2)
            XCTAssertEqual(entered, .completed)
            ownerIsCurrent = false
            publisher.release.signal()
            await publication.value
            XCTAssertEqual(try coordinator.state(itemID: itemID), encrypted)
            XCTAssertNotNil(try harness.fixture.outbox.pendingItem(id: itemID))
            XCTAssertEqual(try harness.fixture.deliveries().count, failAfterRelease ? 0 : 1)
        }
    }
}

private struct HeldNativePublisher: MailboxEnvelopePublishing, Sendable {
    enum Failure: Error { case syntheticIO, watchdog }

    let entered = XCTestExpectation(description: "native publication entered")
    let release = DispatchSemaphore(value: 0)
    let failAfterRelease: Bool

    func publish(_ envelope: Data, finalName: String, locator: MailboxResolvedLocatorV1) throws -> URL {
        throw MailboxPublicationExecutionError.asynchronousPublicationRequired
    }

    @MainActor
    func publishAwaitingCompletion(
        _ envelope: Data, finalName: String, locator: MailboxResolvedLocatorV1
    ) async throws -> URL {
        try await MailboxFileProviderPublicationExecutor().run {
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw Failure.watchdog }
            if failAfterRelease { throw Failure.syntheticIO }
            return try POSIXMailboxEnvelopePublisher().publish(
                envelope, finalName: finalName, locator: locator
            )
        }
    }
}

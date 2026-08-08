import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class OutboxDeliveryCoordinatorTests: XCTestCase {
    func testOrderedHappyPathRestartsAtEveryStateAndFinalizesOnce() throws {
        let harness = try OutboxDeliveryHarness()
        let sealer = try CountingMailboxEnvelopeSealer(harness.fixture)
        let finalizer = CountingOutboxDeliveryFinalizer()
        var outbox = harness.fixture.outbox

        var coordinator = harness.coordinator(
            outbox: outbox,
            sealer: sealer,
            finalizer: finalizer
        )
        XCTAssertEqual(
            try coordinator.advance(itemID: harness.fixture.item.id).phase,
            .collected
        )
        outbox = try harness.restart()
        coordinator = harness.coordinator(
            outbox: outbox,
            sealer: sealer,
            finalizer: finalizer
        )
        XCTAssertEqual(
            try coordinator.advance(itemID: harness.fixture.item.id).phase,
            .encrypted
        )
        XCTAssertEqual(sealer.sealCallCount, 1)
        outbox = try harness.restart()
        coordinator = harness.coordinator(
            outbox: outbox,
            sealer: NeverMailboxEnvelopeSealer(),
            finalizer: finalizer
        )
        XCTAssertEqual(
            try coordinator.advance(itemID: harness.fixture.item.id).phase,
            .published
        )
        outbox = try harness.restart()
        coordinator = harness.coordinator(
            outbox: outbox,
            sealer: NeverMailboxEnvelopeSealer(),
            observed: true,
            finalizer: finalizer
        )
        XCTAssertEqual(
            try coordinator.advance(itemID: harness.fixture.item.id).phase,
            .providerObserved
        )

        let event = try harness.publishCommittedAck()
        XCTAssertEqual(
            try coordinator.consume(event, itemID: harness.fixture.item.id),
            .ackVerified
        )
        outbox = try harness.restart()
        coordinator = harness.coordinator(
            outbox: outbox,
            sealer: NeverMailboxEnvelopeSealer(),
            observed: true,
            finalizer: finalizer
        )
        XCTAssertEqual(
            try coordinator.finalizeCommitted(itemID: harness.fixture.item.id).phase,
            .committedFinalized
        )
        XCTAssertEqual(
            try coordinator.finalizeCommitted(itemID: harness.fixture.item.id).phase,
            .committedFinalized
        )
        XCTAssertEqual(finalizer.finalizeCount, 1)
        XCTAssertNil(try outbox.pendingItem(id: harness.fixture.item.id))
        XCTAssertEqual(sealer.aeadCallCount, 1)
        XCTAssertEqual(sealer.nonceCallCount, 1)
        XCTAssertEqual(sealer.signerCallCount, 1)
    }

    func testFaultsAroundEnvelopeAndStateWritesRecoverWithoutCryptoReentry() throws {
        let harness = try OutboxDeliveryHarness()
        let sealer = try CountingMailboxEnvelopeSealer(harness.fixture)
        let finalizer = CountingOutboxDeliveryFinalizer()
        var injected = false
        let coordinator = harness.coordinator(
            sealer: sealer,
            finalizer: finalizer,
            fault: { boundary in
                guard boundary == .afterEnvelopeFinalization, !injected else { return }
                injected = true
                throw MailboxSyntheticFailure.injected
            }
        )
        _ = try coordinator.advance(itemID: harness.fixture.item.id)
        XCTAssertThrowsError(
            try coordinator.advance(itemID: harness.fixture.item.id)
        )

        let restarted = try harness.restart()
        let state = try harness.coordinator(
            outbox: restarted,
            sealer: NeverMailboxEnvelopeSealer(),
            finalizer: finalizer
        ).state(itemID: harness.fixture.item.id)
        XCTAssertEqual(state?.phase, .encrypted)
        XCTAssertEqual(sealer.sealCallCount, 1)
        XCTAssertEqual(sealer.aeadCallCount, 1)
        XCTAssertEqual(sealer.nonceCallCount, 1)
        XCTAssertEqual(sealer.signerCallCount, 1)
    }

    func testAckNackConflictGenerationAndStaleHTTPBoundariesDoNotRetire() throws {
        let harness = try OutboxDeliveryHarness()
        let finalizer = CountingOutboxDeliveryFinalizer()
        let coordinator = try advanceToProviderObserved(
            harness,
            sealer: CountingMailboxEnvelopeSealer(harness.fixture),
            finalizer: finalizer
        )
        let committed = try harness.publishCommittedAck()
        let retryable = MailboxAckEvent(
            classification: .retryableNack,
            receipt: retryableReceipt(payload: harness.fixture.payload),
            handle: committed.handle
        )
        XCTAssertEqual(
            try coordinator.consume(retryable, itemID: harness.fixture.item.id),
            .retryableFailure
        )
        XCTAssertNotNil(try harness.fixture.outbox.pendingItem(id: harness.fixture.item.id))
        _ = try coordinator.advance(itemID: harness.fixture.item.id)

        let conflict = MailboxAckEvent(
            classification: .conflict,
            receipt: committed.receipt,
            handle: committed.handle
        )
        XCTAssertEqual(
            try coordinator.consume(conflict, itemID: harness.fixture.item.id),
            .rejected
        )
        let before = try coordinator.state(itemID: harness.fixture.item.id)
        for staleOwnership in [
            harness.alternateOwnership(receiverGeneration: "stale-generation"),
            harness.alternateOwnership(receiverBindingID: "stale-binding"),
            harness.alternateOwnership(resetEpoch: 42),
        ] {
            let stale = harness.coordinator(
                sealer: NeverMailboxEnvelopeSealer(),
                observed: true,
                ownership: staleOwnership,
                finalizer: finalizer
            )
            XCTAssertThrowsError(
                try stale.consume(committed, itemID: harness.fixture.item.id)
            )
        }
        XCTAssertEqual(
            try coordinator.handleDirectHTTPSuccess(
                DirectUploadCompletionDescriptor(
                    itemID: harness.fixture.item.id,
                    receiverGeneration: harness.ownership.receiverGeneration,
                    receiverBindingID: harness.ownership.receiverBindingID
                )
            ),
            .ignoredMailboxOwned
        )
        XCTAssertEqual(try coordinator.state(itemID: harness.fixture.item.id), before)
        XCTAssertEqual(
            try coordinator.consume(committed, itemID: harness.fixture.item.id),
            .ackVerified
        )
        XCTAssertEqual(
            try coordinator.consume(committed, itemID: harness.fixture.item.id),
            .duplicateIdentical
        )
        XCTAssertNotNil(try harness.fixture.outbox.pendingItem(id: harness.fixture.item.id))
        XCTAssertEqual(finalizer.finalizeCount, 0)

        let terminalHarness = try OutboxDeliveryHarness()
        let terminalCoordinator = try advanceToProviderObserved(
            terminalHarness,
            sealer: CountingMailboxEnvelopeSealer(terminalHarness.fixture),
            finalizer: CountingOutboxDeliveryFinalizer()
        )
        let terminalSource = try terminalHarness.publishCommittedAck()
        let terminal = MailboxAckEvent(
            classification: .terminalNack,
            receipt: terminalReceipt(payload: terminalHarness.fixture.payload),
            handle: terminalSource.handle
        )
        XCTAssertEqual(
            try terminalCoordinator.consume(
                terminal,
                itemID: terminalHarness.fixture.item.id
            ),
            .terminalHold
        )
        XCTAssertThrowsError(
            try terminalCoordinator.finalizeCommitted(
                itemID: terminalHarness.fixture.item.id
            )
        )
        XCTAssertNotNil(
            try terminalHarness.fixture.outbox.pendingItem(
                id: terminalHarness.fixture.item.id
            )
        )
    }
}

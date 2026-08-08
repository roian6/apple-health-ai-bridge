import Darwin
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

extension OutboxDeliveryCoordinatorTests {
    func testPublicationAndProviderObservationRetriesReuseFinalizedEnvelope() throws {
        let harness = try OutboxDeliveryHarness()
        let sealer = try CountingMailboxEnvelopeSealer(harness.fixture)
        let finalizer = CountingOutboxDeliveryFinalizer()
        var coordinator = harness.coordinator(
            sealer: sealer,
            finalizer: finalizer
        )
        _ = try coordinator.advance(itemID: harness.fixture.item.id)
        _ = try coordinator.advance(itemID: harness.fixture.item.id)
        let finalized = try harness.fixture.finalizedEnvelope()

        let retryingPublisher = POSIXMailboxEnvelopePublisher { boundary in
            if boundary == .createTemporary { throw POSIXError(.ENOSPC) }
        }
        coordinator = harness.coordinator(
            sealer: NeverMailboxEnvelopeSealer(),
            publisher: retryingPublisher,
            finalizer: finalizer
        )
        let publicationRetry = try coordinator.advance(
            itemID: harness.fixture.item.id
        )
        XCTAssertEqual(publicationRetry.phase, .retryableFailure)
        XCTAssertEqual(publicationRetry.retryFrom, .encrypted)

        coordinator = harness.coordinator(
            sealer: NeverMailboxEnvelopeSealer(),
            finalizer: finalizer
        )
        XCTAssertEqual(
            try coordinator.advance(itemID: harness.fixture.item.id).phase,
            .published
        )
        coordinator = harness.coordinator(
            sealer: NeverMailboxEnvelopeSealer(),
            observe: { _, _ in throw MailboxSyntheticFailure.injected },
            finalizer: finalizer
        )
        let observationRetry = try coordinator.advance(
            itemID: harness.fixture.item.id
        )
        XCTAssertEqual(observationRetry.phase, .retryableFailure)
        XCTAssertEqual(observationRetry.retryFrom, .published)

        coordinator = harness.coordinator(
            sealer: NeverMailboxEnvelopeSealer(),
            observed: true,
            finalizer: finalizer
        )
        XCTAssertEqual(
            try coordinator.advance(itemID: harness.fixture.item.id).phase,
            .providerObserved
        )
        XCTAssertEqual(try Data(contentsOf: finalized.2), finalized.1)
        XCTAssertEqual(sealer.sealCallCount, 1)
        XCTAssertEqual(sealer.aeadCallCount, 1)
        XCTAssertEqual(sealer.nonceCallCount, 1)
        XCTAssertEqual(sealer.signerCallCount, 1)
    }

    func testEnvelopeFinalizationBoundaryRestartsPreserveBytesAndCryptoCounts() throws {
        for boundary in FileOutboxEnvelopeFinalizationBoundary.allCases {
            let harness = try OutboxDeliveryHarness()
            let sealer = try CountingMailboxEnvelopeSealer(harness.fixture)
            let envelope = try sealer.seal(
                harness.fixture.payload,
                envelopeID: harness.fixture.sealContext.envelopeID,
                context: harness.fixture.context,
                createdAtMS: harness.fixture.sealContext.createdAtMS
            )
            let envelopeHash = mailboxSHA256(envelope)
            let payloadHash = mailboxSHA256(harness.fixture.payload)
            _ = try harness.fixture.outbox.finalizeMailboxEnvelopeForTesting(
                itemID: harness.fixture.item.id,
                envelope: envelope,
                expectedPayloadSHA256: payloadHash,
                through: boundary
            )

            let restarted = try harness.restart()
            let finalizer = CountingOutboxDeliveryFinalizer()
            if boundary == .intentPersisted {
                let rebuilding = harness.coordinator(
                    outbox: restarted,
                    sealer: sealer,
                    finalizer: finalizer
                )
                XCTAssertEqual(
                    try rebuilding.advance(itemID: harness.fixture.item.id).phase,
                    .collected
                )
                XCTAssertEqual(
                    try rebuilding.advance(itemID: harness.fixture.item.id).phase,
                    .encrypted
                )
            } else {
                XCTAssertEqual(
                    try restarted.deliveryState(for: harness.fixture.item.id)?.phase,
                    .encrypted
                )
            }
            let finalized = try XCTUnwrap(
                try restarted.mailboxBinding(for: harness.fixture.item.id)
            )
            let finalizedURL = harness.fixture.outboxDirectory
                .appendingPathComponent(finalized.envelopeFilename)
            let expectedEnvelopeHash = boundary == .intentPersisted
                ? finalized.envelopeSHA256
                : envelopeHash
            XCTAssertEqual(
                mailboxSHA256(try Data(contentsOf: finalizedURL)),
                expectedEnvelopeHash
            )
            XCTAssertEqual(
                mailboxSHA256(try Data(contentsOf: harness.fixture.item.fileURL)),
                payloadHash
            )

            let publishing = harness.coordinator(
                outbox: restarted,
                sealer: NeverMailboxEnvelopeSealer(),
                finalizer: finalizer
            )
            XCTAssertEqual(
                try publishing.advance(itemID: harness.fixture.item.id).phase,
                .published
            )
            let expectedCryptoCount = boundary == .intentPersisted ? 2 : 1
            XCTAssertEqual(sealer.sealCallCount, expectedCryptoCount)
            XCTAssertEqual(sealer.aeadCallCount, expectedCryptoCount)
            XCTAssertEqual(sealer.nonceCallCount, expectedCryptoCount)
            XCTAssertEqual(sealer.signerCallCount, expectedCryptoCount)
        }
    }

    func testBeforeAndAfterStateWriteFaultsRecoverOneOrderedState() throws {
        for faultAfterWrite in [false, true] {
            let harness = try OutboxDeliveryHarness()
            let finalizer = CountingOutboxDeliveryFinalizer()
            var injected = false
            let coordinator = harness.coordinator(
                sealer: try CountingMailboxEnvelopeSealer(harness.fixture),
                finalizer: finalizer,
                fault: { boundary in
                    let target: OutboxDeliveryCoordinator.Boundary = faultAfterWrite
                        ? .afterStateWrite(.collected)
                        : .beforeStateWrite(.collected)
                    guard boundary == target, !injected else { return }
                    injected = true
                    throw MailboxSyntheticFailure.injected
                }
            )
            XCTAssertThrowsError(
                try coordinator.advance(itemID: harness.fixture.item.id)
            )

            let restarted = try harness.restart()
            let state = try harness.coordinator(
                outbox: restarted,
                sealer: try CountingMailboxEnvelopeSealer(harness.fixture),
                finalizer: finalizer
            ).advance(itemID: harness.fixture.item.id)
            XCTAssertEqual(
                state.phase,
                faultAfterWrite ? .encrypted : .collected
            )
        }
    }

    func testEveryCommittedRetirementFaultRecoversOneFinalization() throws {
        let boundaries: [OutboxDeliveryCoordinator.Boundary] = [
            .beforeProgressFinalization,
            .afterProgressFinalization,
            .beforeStateWrite(.committedFinalized),
            .afterStateWrite(.committedFinalized),
            .payloadRetired,
            .envelopeRetired,
        ]
        for target in boundaries {
            let harness = try OutboxDeliveryHarness()
            let finalizer = CountingOutboxDeliveryFinalizer()
            var coordinator = try advanceToProviderObserved(
                harness,
                sealer: CountingMailboxEnvelopeSealer(harness.fixture),
                finalizer: finalizer
            )
            _ = try coordinator.consume(
                harness.publishCommittedAck(),
                itemID: harness.fixture.item.id
            )
            var injected = false
            coordinator = harness.coordinator(
                sealer: NeverMailboxEnvelopeSealer(),
                observed: true,
                finalizer: finalizer,
                fault: { boundary in
                    guard boundary == target, !injected else { return }
                    injected = true
                    throw MailboxSyntheticFailure.injected
                }
            )
            XCTAssertThrowsError(
                try coordinator.finalizeCommitted(itemID: harness.fixture.item.id),
                "target=\(target)"
            )

            let restarted = try harness.restart()
            coordinator = harness.coordinator(
                outbox: restarted,
                sealer: NeverMailboxEnvelopeSealer(),
                observed: true,
                finalizer: finalizer
            )
            XCTAssertEqual(
                try coordinator.finalizeCommitted(
                    itemID: harness.fixture.item.id
                ).phase,
                .committedFinalized,
                "target=\(target)"
            )
            XCTAssertEqual(finalizer.finalizeCount, 1, "target=\(target)")
            XCTAssertNil(
                try restarted.pendingItem(id: harness.fixture.item.id),
                "target=\(target)"
            )
            let envelope = harness.fixture.outboxDirectory
                .appendingPathComponent(harness.fixture.item.id)
                .appendingPathExtension("hbe")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: envelope.path),
                "target=\(target)"
            )
        }
    }
}

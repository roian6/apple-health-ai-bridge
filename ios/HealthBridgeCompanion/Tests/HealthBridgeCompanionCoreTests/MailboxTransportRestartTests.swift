import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxTransportTestsRestart: XCTestCase {
    func testRestartAtEveryLocalFinalizationBoundaryReusesOrRebuildsCorrectly() throws {
        for boundary in FileOutboxEnvelopeFinalizationBoundary.allCases {
            let fixture = try MailboxTransportFixture()
            let initialSealer = try CountingMailboxEnvelopeSealer(fixture)
            let envelope = try initialSealer.seal(
                fixture.payload,
                envelopeID: fixture.sealContext.envelopeID,
                context: fixture.context,
                createdAtMS: fixture.sealContext.createdAtMS
            )
            _ = try fixture.outbox.finalizeMailboxEnvelopeForTesting(
                itemID: fixture.item.id,
                envelope: envelope,
                expectedPayloadSHA256: mailboxSHA256(fixture.payload),
                through: boundary
            )

            let restarted = try FileOutbox(directory: fixture.outboxDirectory)
            let item = try XCTUnwrap(try restarted.pendingItem(id: fixture.item.id))
            let fallback = try CountingMailboxEnvelopeSealer(fixture)
            let sealer: any MailboxEnvelopeSealing = boundary == .intentPersisted
                ? fallback
                : NeverMailboxEnvelopeSealer()
            let result = try fixture.transport(
                outbox: restarted,
                sealer: sealer
            ).deliver(try DeliveryTransportInput(item: item))

            XCTAssertEqual(result, .published, "boundary=\(boundary)")
            XCTAssertEqual(
                fallback.sealCallCount,
                boundary == .intentPersisted ? 1 : 0,
                "boundary=\(boundary)"
            )
            XCTAssertNotNil(try restarted.pendingItem(id: fixture.item.id))
            XCTAssertEqual(try fixture.deliveries().count, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.item.fileURL), fixture.payload)
        }
    }

    func testPayloadReadFailureAndCancellationBeforeFinalizationLeaveOnlyPayload() throws {
        let fixture = try MailboxTransportFixture()
        var readAttempts = 0
        XCTAssertThrowsError(
            try DeliveryTransportInput(
                item: fixture.item,
                readPersistedBytes: { _ in
                    readAttempts += 1
                    throw MailboxSyntheticFailure.injected
                }
            )
        )
        XCTAssertEqual(readAttempts, 1)
        XCTAssertNil(try fixture.outbox.mailboxBinding(for: fixture.item.id))

        let cancellation = CancellationSequence(cancellationCall: 1)
        XCTAssertThrowsError(
            try fixture.transport(
                sealer: try CountingMailboxEnvelopeSealer(fixture),
                isCancelled: cancellation.check
            ).deliver(try DeliveryTransportInput(item: fixture.item))
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(try fixture.outbox.mailboxBinding(for: fixture.item.id))
        XCTAssertEqual(try Data(contentsOf: fixture.item.fileURL), fixture.payload)
        XCTAssertTrue(try fixture.deliveries().isEmpty)
    }

    func testCancellationAfterFinalizationOrPublicationRetainsEveryDurableArtifact() throws {
        for cancellationCall in [4, 6] {
            let fixture = try MailboxTransportFixture()
            let cancellation = CancellationSequence(cancellationCall: cancellationCall)
            XCTAssertThrowsError(
                try fixture.transport(
                    sealer: try CountingMailboxEnvelopeSealer(fixture),
                    isCancelled: cancellation.check
                ).deliver(try DeliveryTransportInput(item: fixture.item))
            ) { error in
                XCTAssertTrue(error is CancellationError)
            }

            let finalized = try fixture.finalizedEnvelope()
            XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
            XCTAssertEqual(try Data(contentsOf: fixture.item.fileURL), fixture.payload)
            XCTAssertEqual(try Data(contentsOf: finalized.2), finalized.1)
            if cancellationCall == 4 {
                XCTAssertTrue(try fixture.deliveries().isEmpty)
            } else {
                XCTAssertEqual(try fixture.deliveries().count, 1)
            }
        }
    }

    func testProviderObservationFailureAfterPublicationIsRetryableAndNonterminal() throws {
        let fixture = try MailboxTransportFixture()
        let result = try fixture.transport(
            sealer: try CountingMailboxEnvelopeSealer(fixture),
            observe: { _, _ in throw MailboxSyntheticFailure.injected }
        ).deliver(try DeliveryTransportInput(item: fixture.item))

        XCTAssertEqual(result, .retryable)
        XCTAssertEqual(try fixture.deliveries().count, 1)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
        _ = try fixture.finalizedEnvelope()
    }
}

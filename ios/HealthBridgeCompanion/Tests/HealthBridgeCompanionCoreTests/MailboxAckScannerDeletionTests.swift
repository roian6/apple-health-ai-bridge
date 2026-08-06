import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

extension MailboxAckScannerTests {
    func testDeletionRequiresDurableCommittedFinalizationProof() throws {
        let fixture = try MailboxAckScannerFixture()
        let ack = try fixture.publish(fixture.pythonAck())
        let event = try XCTUnwrap(fixture.scanner().scan().events.first)

        XCTAssertThrowsError(
            try fixture.scanner().deleteAcknowledgment(
                for: event,
                durableFinalization: DurableMailboxAckProof(false)
            )
        ) { error in
            XCTAssertEqual(error as? MailboxAckScannerError, .durableFinalizationRequired)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ack.path))
    }

    func testDeletionAfterDurableFinalizationRevalidatesAndUnlinksExactAck() throws {
        let fixture = try MailboxAckScannerFixture()
        let ack = try fixture.publish(fixture.pythonAck())
        let scanner = fixture.scanner()
        let event = try XCTUnwrap(scanner.scan().events.first)

        try scanner.deleteAcknowledgment(
            for: event,
            durableFinalization: DurableMailboxAckProof(true)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: ack.path))
        XCTAssertNotNil(try fixture.transport.outbox.pendingItem(id: fixture.transport.item.id))
    }

    func testDeletionAfterReplacementIsRejectedAndPreservesEntry() throws {
        let fixture = try MailboxAckScannerFixture()
        let ack = try fixture.publish(fixture.pythonAck())
        let scanner = fixture.scanner()
        let event = try XCTUnwrap(scanner.scan().events.first)
        try FileManager.default.removeItem(at: ack)
        let replacement = try fixture.sealAck(
            retryableReceipt(payload: fixture.transport.payload)
        )
        try replacement.write(to: ack)

        XCTAssertThrowsError(
            try scanner.deleteAcknowledgment(
                for: event,
                durableFinalization: DurableMailboxAckProof(true)
            )
        ) { error in
            XCTAssertEqual(error as? MailboxAckScannerError, .acknowledgmentChanged)
        }
        XCTAssertEqual(try Data(contentsOf: ack), replacement)
    }

    func testDeletionAfterValidConflictIsRejectedAndPreservesBothEntries() throws {
        let fixture = try MailboxAckScannerFixture()
        let first = try fixture.publish(
            fixture.pythonAck(),
            identifier: String(repeating: "1", count: 32)
        )
        let scanner = fixture.scanner()
        let event = try XCTUnwrap(scanner.scan().events.first)
        let second = try fixture.publish(
            fixture.sealAck(retryableReceipt(payload: fixture.transport.payload)),
            identifier: String(repeating: "2", count: 32)
        )

        XCTAssertThrowsError(
            try scanner.deleteAcknowledgment(
                for: event,
                durableFinalization: DurableMailboxAckProof(true)
            )
        ) { error in
            XCTAssertEqual(error as? MailboxAckScannerError, .acknowledgmentConflict)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}

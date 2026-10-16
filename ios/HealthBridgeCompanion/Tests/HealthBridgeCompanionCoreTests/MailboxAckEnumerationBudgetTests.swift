import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxAckEnumerationBudgetTests: XCTestCase {
    func testExhaustionIsDistinctAndExactAckAndCheckpointWindowsStillProgress() throws {
        let fixture = try MailboxAckScannerFixture()
        let ack = try fixture.pythonAck()
        let ackURL = try fixture.publish(
            ack,
            identifier: fixture.transport.sealContext.envelopeID.hexV1
        )
        for index in 0 ..< MailboxAckScanner.maximumEnumerationEntries {
            try Data().write(
                to: fixture.ackLane.appendingPathComponent("invalid-synthetic-\(index)"),
                options: [.withoutOverwriting]
            )
        }
        let before = try fixture.snapshotLocalState()
        let scanner = fixture.scanner(transientUnsafeRetryLimit: 1)
        XCTAssertThrowsError(try scanner.scan()) { error in
            XCTAssertEqual(error as? MailboxAckEnumerationError, .budgetExhausted)
        }
        let exact = try scanner.scanExact(envelopeID: fixture.transport.sealContext.envelopeID)
        XCTAssertEqual(exact.events.map(\.classification), [.committed])
        let first = try scanner.candidateWindow(maximumEntries: 8, afterCheckpoint: nil)
        let next = try scanner.candidateWindow(
            maximumEntries: 8, afterCheckpoint: try XCTUnwrap(first.nextCheckpoint)
        )
        XCTAssertGreaterThan(first.inspectedEntryCount, 0)
        XCTAssertLessThanOrEqual(first.inspectedEntryCount, 8)
        XCTAssertGreaterThan(next.inspectedEntryCount, 0)
        XCTAssertLessThanOrEqual(next.inspectedEntryCount, 8)
        XCTAssertNotEqual(first.nextCheckpoint, next.nextCheckpoint)
        XCTAssertEqual(try fixture.snapshotLocalState(), before)
        XCTAssertEqual(try Data(contentsOf: ackURL), ack)
    }
}

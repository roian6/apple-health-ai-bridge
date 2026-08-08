import Darwin
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

extension MailboxAckScannerTests {
    func testFinalNameOnlyScanIsDeterministicAndBounded() throws {
        let fixture = try MailboxAckScannerFixture()
        let ack = try fixture.pythonAck()
        try fixture.publish(ack, identifier: String(repeating: "0", count: 32))
        for index in 1 ... 10_005 {
            let name = String(format: "%032x.hba", index)
            try Data("{".utf8).write(to: fixture.ackLane.appendingPathComponent(name))
        }
        for index in 1 ... 2 {
            let name = String(format: "%032x.hba.%032x.tmp", index, index)
            try Data("partial".utf8).write(
                to: fixture.ackLane.appendingPathComponent(name)
            )
        }

        let report = try fixture.scanner().scan()

        XCTAssertEqual(report.events.map(\.classification), [.committed])
        XCTAssertEqual(report.scannedFinalCount, MailboxAckScanner.maximumScanFiles)
        XCTAssertEqual(report.ignoredTemporaryCount, 2)
        XCTAssertEqual(report.quarantine.records.count, 1_000)
        XCTAssertGreaterThan(report.quarantine.suppressedCount, 0)
        XCTAssertLessThanOrEqual(report.scannedFinalCount, MailboxAckScanner.maximumScanFiles)
        XCTAssertLessThanOrEqual(report.scannedByteCount, MailboxAckScanner.maximumScanBytes)
    }

    func testOnlyExactTemporaryGrammarIsIgnoredAndPartialFakeFinalsAreRejected() throws {
        let fixture = try MailboxAckScannerFixture()
        let exact = String(repeating: "1", count: 32)
            + ".hba." + String(repeating: "2", count: 32) + ".tmp"
        for name in [
            exact,
            String(repeating: "1", count: 32) + ".hba.tmp",
            String(repeating: "1", count: 32) + ".hba.partial",
            String(repeating: "1", count: 31) + ".hba",
            String(repeating: "1", count: 32) + ".hbd",
        ] {
            try Data("synthetic".utf8).write(to: fixture.ackLane.appendingPathComponent(name))
        }

        let report = try fixture.scanner().scan()

        XCTAssertEqual(report.ignoredTemporaryCount, 1)
        XCTAssertEqual(report.quarantine.records, Array(repeating: .invalidName, count: 4))
    }

    func testSymlinkHardlinkAndNonregularFinalsFailClosed() throws {
        let fixture = try MailboxAckScannerFixture()
        let ack = try fixture.pythonAck()
        let source = fixture.transport.root.appendingPathComponent("ack-source")
        try ack.write(to: source)
        let symlink = fixture.ackLane.appendingPathComponent(
            String(repeating: "1", count: 32) + ".hba"
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        let hardlink = fixture.ackLane.appendingPathComponent(
            String(repeating: "2", count: 32) + ".hba"
        )
        XCTAssertEqual(link(source.path, hardlink.path), 0)
        let fifo = fixture.ackLane.appendingPathComponent(
            String(repeating: "3", count: 32) + ".hba"
        )
        try installFIFO(at: fifo)

        let report = try fixture.scanner().scan()

        XCTAssertTrue(report.events.isEmpty)
        XCTAssertEqual(report.quarantine.records, Array(repeating: .unsafeEntry, count: 3))
    }

    func testPathReplacementAfterOpenFailsClosed() throws {
        let fixture = try MailboxAckScannerFixture()
        let original = try fixture.publish(fixture.pythonAck())
        let replacement = original.deletingLastPathComponent().appendingPathComponent("replacement")
        try fixture.pythonAck().write(to: replacement)
        var replaced = false
        let scanner = fixture.scanner { boundary in
            guard boundary == .afterCandidateOpen, !replaced else { return }
            replaced = true
            try FileManager.default.removeItem(at: original)
            try FileManager.default.moveItem(at: replacement, to: original)
        }

        XCTAssertThrowsError(try scanner.scan()) { error in
            XCTAssertEqual(error as? MailboxAckScannerError, .unsafeMailbox)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testSingleProviderPathReplacementRetriesWhenOptedIn() throws {
        let fixture = try MailboxAckScannerFixture()
        let original = try fixture.publish(fixture.pythonAck())
        let replacement = original.deletingLastPathComponent().appendingPathComponent("replacement")
        try fixture.pythonAck().write(to: replacement)
        var replaced = false
        let scanner = fixture.scanner(transientUnsafeRetryLimit: 1) { boundary in
            guard boundary == .afterCandidateOpen, !replaced else { return }
            replaced = true
            try FileManager.default.removeItem(at: original)
            try FileManager.default.moveItem(at: replacement, to: original)
        }

        let report = try scanner.scan()

        XCTAssertTrue(replaced)
        XCTAssertEqual(report.events.count, 1)
        XCTAssertTrue(report.quarantine.records.isEmpty)
        XCTAssertEqual(report.quarantine.suppressedCount, 0)
    }

    func testProviderLaneAndContainerLossFailClosed() throws {
        for target in [0, 1] {
            let fixture = try MailboxAckScannerFixture()
            try fixture.publish(fixture.pythonAck())
            var removed = false
            let scanner = fixture.scanner { boundary in
                guard boundary == .laneOpened, !removed else { return }
                removed = true
                let url = target == 0
                    ? fixture.ackLane
                    : fixture.transport.providerRoot
                try FileManager.default.removeItem(at: url)
            }

            XCTAssertThrowsError(try scanner.scan()) { error in
                XCTAssertEqual(error as? MailboxAckScannerError, .unsafeMailbox)
            }
        }
    }

    func testCandidateSizeMetadataCannotBypassExactAckCap() throws {
        let fixture = try MailboxAckScannerFixture()
        let final = fixture.ackLane.appendingPathComponent(
            String(repeating: "a", count: 32) + ".hba"
        )
        let descriptor = open(final.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, off_t(MailboxLayoutV1.maximumMetadataBytes + 1)), 0)
        XCTAssertEqual(close(descriptor), 0)

        let report = try fixture.scanner().scan()

        XCTAssertTrue(report.events.isEmpty)
        XCTAssertEqual(report.quarantine.records, [.oversize])
    }
}

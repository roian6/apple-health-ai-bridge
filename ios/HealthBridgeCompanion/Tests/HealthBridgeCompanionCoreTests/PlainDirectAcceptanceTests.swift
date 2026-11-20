import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class PlainDirectAcceptanceTests: XCTestCase {
    func testReportsPlainAcceptanceDespiteCleanupFailureAndNeverRepeatsItOnReplay() throws {
        let fixture = try makePlainQueue()
        let manager = AcceptanceFaultFileManager(payload: fixture.first.fileURL, fault: .cleanup)
        let outbox = try FileOutbox(directory: fixture.directory, fileManager: manager)
        var reports = 0

        XCTAssertThrowsError(try outbox.recordDirectUploadAcceptance(
            itemID: fixture.first.id, receiverIdentity: binding,
            onNewAcceptance: {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.first.fileURL.path))
                reports += 1
            }
        )) { error in
            XCTAssertEqual(error as? AcceptanceFault, .cleanup)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.first.fileURL.path))
        XCTAssertEqual(reports, 1, "The completed unlink earns an ACK even if manifest cleanup throws.")

        let reopened = try FileOutbox(directory: fixture.directory)
        XCTAssertNil(try reopened.recordDirectUploadAcceptance(
            itemID: fixture.first.id, receiverIdentity: binding,
            onNewAcceptance: { reports += 1 }
        ))
        XCTAssertEqual(reports, 1, "Replay of an already retired plain item must not report another ACK.")
        XCTAssertEqual(try reopened.pendingItems().map(\.id), [fixture.next.id])
    }

    func testFailedPlainUnlinkRetainsPayloadAndOnlySuccessfulReplayReportsAcceptance() throws {
        let fixture = try makePlainQueue()
        let bytes = try Data(contentsOf: fixture.first.fileURL)
        let manager = AcceptanceFaultFileManager(payload: fixture.first.fileURL, fault: .unlink)
        let outbox = try FileOutbox(directory: fixture.directory, fileManager: manager)
        var reports = 0

        XCTAssertThrowsError(try outbox.recordDirectUploadAcceptance(
            itemID: fixture.first.id, receiverIdentity: binding,
            onNewAcceptance: { reports += 1 }
        )) { error in
            XCTAssertEqual(error as? AcceptanceFault, .unlink)
        }
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.first.fileURL), bytes)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [fixture.first.id, fixture.next.id])

        let reopened = try FileOutbox(directory: fixture.directory)
        XCTAssertNil(try reopened.recordDirectUploadAcceptance(
            itemID: fixture.first.id, receiverIdentity: binding,
            onNewAcceptance: { reports += 1 }
        ))
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(try reopened.pendingItems().map(\.id), [fixture.next.id])
    }

    private let binding = "synthetic-direct-binding"

    private func makePlainQueue() throws -> (directory: URL, first: FileOutboxItem, next: FileOutboxItem) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try fileManager.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        let first = try outbox.enqueue(Data("synthetic-first".utf8), receiverIdentity: binding)
        let next = try outbox.enqueue(Data("synthetic-next".utf8), receiverIdentity: binding)
        return (directory, first, next)
    }
}

private enum AcceptanceFault: Error, Equatable {
    case cleanup
    case unlink
}

private final class AcceptanceFaultFileManager: FileManager, @unchecked Sendable {
    private let payload: URL
    private let fault: AcceptanceFault
    private var payloadWasUnlinked = false

    init(payload: URL, fault: AcceptanceFault) {
        self.payload = payload
        self.fault = fault
        super.init()
    }

    override func removeItem(at url: URL) throws {
        guard url == payload else { return try super.removeItem(at: url) }
        if fault == .unlink { throw fault }
        try super.removeItem(at: url)
        payloadWasUnlinked = true
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions
    ) throws -> [URL] {
        if payloadWasUnlinked, url.path == payload.deletingLastPathComponent().path {
            payloadWasUnlinked = false
            throw fault
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

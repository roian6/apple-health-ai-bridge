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

    #if os(iOS)
    @MainActor
    func testTransactionACKReportsExactlyOnceDespitePostWriteAttributeFailure() async throws {
        for lane in TransactionLane.allCases {
            try await checkTransactionACK(lane, fault: .afterPublication)
        }
    }
    #endif

    @MainActor
    func testTransactionACKDoesNotReportWhenAtomicWriteCannotPublish() async throws {
        for lane in TransactionLane.allCases {
            try await checkTransactionACK(lane, fault: .beforePublication)
        }
    }

    private enum TransactionLane: CaseIterable {
        case plain, sleep
    }

    @MainActor
    private func checkTransactionACK(
        _ lane: TransactionLane, fault: TransactionACKFileManager.Fault
    ) async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("outbox")
        let journal = directory.appendingPathComponent(".enqueue-transaction")
        addTeardownBlock { try files.removeItem(at: root) }
        let manager = TransactionACKFileManager(journal: journal, fault: fault)
        let outbox = try FileOutbox(directory: directory, fileManager: manager)
        let payload = try makeTransactionPayload(for: lane)
        let item = try outbox.enqueue(payload, receiverIdentity: binding)
        let next = try outbox.enqueue(makeTransactionPayload(for: .plain), receiverIdentity: binding)
        let generation = "synthetic-generation"
        let descriptor = DirectUploadCompletionDescriptor(
            itemID: item.id, receiverGeneration: generation, receiverBindingID: binding
        )
        let sleep = try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json"))
        let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        if lane == .sleep {
            try sleep.savePendingTransition(.init(
                payload: payload,
                manifest: SleepSyncBatchFactory.makeManifestReservation(
                    receiverSettingsGeneration: generation, historyDepth: .allAvailable, historyStartDate: nil
                ),
                receiverBindingID: binding, connectionGeneration: generation, outboxItemID: item.id
            ))
        }

        func hasScopedACK(in queue: FileOutbox) throws -> Bool {
            switch lane {
            case .plain:
                return try queue.hasDirectAcknowledgmentWithSleepChecked(itemID: item.id, receiverIdentity: binding)
            case .sleep:
                return try queue.hasDirectSleepCleanupIntent(
                    itemID: item.id, receiverBindingID: binding, receiverGeneration: generation
                )
            }
        }

        var reports = 0
        @MainActor func accept(in queue: FileOutbox) async throws -> Bool {
            try await OutboxDeliveryCursorFinalizer(outbox: queue, cursorStore: cursors)
                .recordDirectReceiverAcceptanceForSync(
                    descriptor: descriptor, sleepStore: sleep, validate: {},
                    onNewAcceptance: {
                        do {
                            let scopedACK = try hasScopedACK(in: queue)
                            XCTAssertTrue(scopedACK, "\(lane): reported before the scoped ACK was visible")
                        } catch {
                            XCTFail("\(lane): reported before the scoped ACK was readable: \(error)")
                        }
                        reports += 1
                    }
                )
        }

        XCTAssertFalse(try hasScopedACK(in: outbox))
        if fault == .beforePublication {
            // Hide only this empty obstruction from journal readers, not from the real atomic write.
            try files.createDirectory(at: journal, withIntermediateDirectories: false)
        }
        manager.armed = true
        do {
            _ = try await accept(in: outbox)
            XCTFail("\(lane): the \(fault) error must propagate")
        } catch {
            switch fault {
            case .afterPublication:
                XCTAssertEqual(error as? TransactionACKFileManager.Fault, .afterPublication, "\(lane)")
            case .beforePublication:
                let cocoa = error as NSError
                XCTAssertEqual(cocoa.domain, NSCocoaErrorDomain, "\(lane)")
                XCTAssertEqual(cocoa.userInfo[NSFilePathErrorKey] as? String, journal.path, "\(lane)")
            }
        }

        let published = fault == .afterPublication
        XCTAssertEqual(try hasScopedACK(in: outbox), published, "\(lane): journal visibility at the failure boundary")
        XCTAssertEqual(reports, published ? 1 : 0, "\(lane): callback count at the ACK publication boundary")
        let reportsBeforeRetry = reports
        if !published {
            XCTAssertEqual(try Data(contentsOf: item.fileURL), payload, "\(lane): failed write must retain payload")
            try files.removeItem(at: journal)
        }

        let reopened = try FileOutbox(directory: directory)
        let finalized = try await accept(in: reopened)
        XCTAssertTrue(finalized, "\(lane): retry should finish the accepted item")
        XCTAssertEqual(reports, published ? reportsBeforeRetry : 1, "\(lane): retry must not duplicate the ACK")
        let replayed = try await accept(in: reopened)
        XCTAssertFalse(replayed, "\(lane): the retired item should not finalize again")
        XCTAssertEqual(reports, published ? reportsBeforeRetry : 1, "\(lane): replay must not report another ACK")
        XCTAssertEqual(try reopened.pendingItems().map(\.id), [next.id], "\(lane): only the scoped item may retire")
        XCTAssertNil(try sleep.loadPendingTransition())
    }

    private func makeTransactionPayload(for lane: TransactionLane) throws -> Data {
        let start = "2026-01-01T00:00:00Z"
        let end = "2026-01-02T00:00:00Z"
        let window = HealthBridgeTimeWindow(startTime: start, endTime: end)
        return try HealthBridgeBatchEncoder().encode(.init(
            generatedAt: end, exportWindow: window, sources: [],
            healthTypes: lane == .sleep ? [.sleepAnalysis] : [.steps],
            samples: [], workouts: [], sleepSessions: [], deletedRecords: [],
            sync: .init(syncWindow: window, cursors: [])
        ))
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

private final class TransactionACKFileManager: FileManager {
    enum Fault: Error {
        case beforePublication, afterPublication
    }

    private let journal: URL
    private let fault: Fault
    var armed = false

    init(journal: URL, fault: Fault) {
        self.journal = journal
        self.fault = fault
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        if armed, fault == .beforePublication, path == journal.path { return false }
        return super.fileExists(atPath: path)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        if armed, fault == .afterPublication, path == journal.path {
            armed = false
            throw fault
        }
        return attributes
    }
}

import XCTest
@testable import HealthBridgeCompanionCore

final class AutomaticSyncOutboxDiagnosticTests: XCTestCase {
    func testRealFIFOEnqueueAndFlushCorrelateAfterRestartWithoutChangingPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomaticSyncDiagnosticStore(fileURL: directory.appendingPathComponent("diagnostics.json"))
        let outbox = try FileOutbox(directory: directory.appendingPathComponent("outbox"))
        let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
        draft.notePlan([.sleep])
        draft.noteAttempt(.sleep)
        draft.noteQuery(.records, newestSampleAge: 60)
        outbox.automaticSyncDiagnosticStore = store
        outbox.automaticSyncDiagnosticDraft = draft
        let payload = Data("synthetic-payload-must-not-enter-diagnostics".utf8)
        let items = try outbox.enqueueSequence([payload, payload], receiverIdentity: "synthetic-local-binding")
        XCTAssertEqual(store.latestRecord?.causalChain?.lanes.first?.outbox, .queued)
        XCTAssertEqual(store.latestRecord?.causalChain?.lanes.first?.pendingItems.count, 2)
        XCTAssertEqual(try Data(contentsOf: items[0].fileURL), payload)
        let restarted = try FileOutbox(directory: outbox.directoryURL)
        restarted.automaticSyncDiagnosticStore = AutomaticSyncDiagnosticStore(fileURL: store.fileURL)
        let result = try await restarted.flushPending(receiverIdentity: "synthetic-local-binding") { _, bytes in
            XCTAssertEqual(bytes, payload)
        }
        XCTAssertEqual(result.uploadedCount, 2)
        XCTAssertEqual(store.latestRecord?.runID, draft.runID)
        XCTAssertEqual(store.latestRecord?.causalChain?.lanes.first?.delivery, .accepted)
        let json = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        XCTAssertFalse(json.contains("synthetic-payload"))
        XCTAssertFalse(json.contains("synthetic-local-binding"))
    }

    func testObserverACKOrderingAndDiagnosticFailureDoNotBlockRealFIFO() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory.appendingPathComponent("outbox"))
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let store = AutomaticSyncDiagnosticStore(fileURL: blocker.appendingPathComponent("diagnostics.json"))
        let draft = AutomaticSyncDiagnosticDraft(reason: .observer(typeCode: "sleep_analysis"))
        draft.notePlan([.sleep])
        draft.noteAttempt(.sleep)
        draft.noteQuery(.records, newestSampleAge: nil)
        outbox.automaticSyncDiagnosticStore = store
        outbox.automaticSyncDiagnosticDraft = draft
        _ = try outbox.enqueue(Data("synthetic".utf8), receiverIdentity: "synthetic-binding")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let result = try await outbox.flushPending(receiverIdentity: "synthetic-binding") { _, _ in }
        XCTAssertEqual(result.uploadedCount, 1)
        XCTAssertEqual(draft.record.causalChain?.lanes.first?.delivery, .accepted)
        XCTAssertFalse(store.recordFinal(draft.record))
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
    }
}

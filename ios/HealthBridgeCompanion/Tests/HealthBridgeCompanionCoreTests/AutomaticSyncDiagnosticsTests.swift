import XCTest
@testable import HealthBridgeCompanionCore

final class AutomaticSyncDiagnosticsTests: XCTestCase {
    func testHistoryEvictsOldestRecordsAtBound() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = AutomaticSyncDiagnosticStore(
            fileURL: fileURL,
            maximumRecordCount: 3
        )

        for remaining in 0..<5 {
            store.record(makeRecord(remainingPendingLaneCount: remaining))
        }

        XCTAssertEqual(
            store.history.map(\.remainingPendingLaneCount),
            [2, 3, 4]
        )
    }

    func testMissingAndCorruptFilesRecoverWithoutThrowing() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let missingStore = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        XCTAssertTrue(missingStore.history.isEmpty)

        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        let corruptStore = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        XCTAssertTrue(corruptStore.history.isEmpty)

        corruptStore.record(makeRecord(remainingPendingLaneCount: 1))
        XCTAssertEqual(corruptStore.history.count, 1)
    }

    func testPendingLaneAgeUsesCoarseBuckets() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let firstSeen = Date(timeIntervalSince1970: 1_788_000_000)

        let initial = store.pendingSnapshot(
            pendingTypeCodes: [HealthBridgeHealthType.sleepAnalysis.typeCode],
            now: firstSeen
        )
        let aged = store.pendingSnapshot(
            pendingTypeCodes: [HealthBridgeHealthType.sleepAnalysis.typeCode],
            now: firstSeen.addingTimeInterval(25 * 60 * 60)
        )

        XCTAssertEqual(initial.oldestPendingLaneAgeBucket, .unknown)
        XCTAssertEqual(aged.pendingLaneCount, 1)
        XCTAssertEqual(aged.oldestPendingLane, .sleep)
        XCTAssertEqual(aged.oldestPendingLaneAgeBucket, .oneToThreeDays)
    }

    func testLatestLaneRenderingOmitsPrivateValuesAndIdentifiers() {
        let record = makeRecord(remainingPendingLaneCount: 1)

        XCTAssertEqual(
            record.latestLaneSummary,
            "trigger=observer/sleep; admission=accepted; selected=quantity; pending=2; oldest=sleep (1–6h); outcome=completed; remaining=1; observer completion=5–30s"
        )
    }

    private func makeRecord(
        remainingPendingLaneCount: Int
    ) -> AutomaticSyncDiagnosticRecord {
        AutomaticSyncDiagnosticRecord(
            wakeSource: .healthKitObserver,
            triggerReason: .observer,
            triggerLane: .sleep,
            admissionResult: .accepted,
            selectedLane: .quantity,
            pendingLaneCount: 2,
            oldestPendingLane: .sleep,
            oldestPendingLaneAgeBucket: .oneToSixHours,
            runOutcome: .completed,
            observerCompletionLatencyBucket: .fiveToThirtySeconds,
            remainingPendingLaneCount: remainingPendingLaneCount
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("automatic-sync-diagnostics-\(UUID().uuidString).json")
    }
}

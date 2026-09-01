import XCTest
@testable import HealthBridgeCompanionCore

final class AutomaticSyncDiagnosticsTests: XCTestCase {
    @MainActor
    func testObserverDiagnosticPersistenceBeginsOnlyAfterAcknowledgement() async {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let draft = AutomaticSyncDiagnosticDraft(
            reason: .observer(typeCode: HealthBridgeHealthType.sleepAnalysis.typeCode)
        )
        draft.noteRunAccepted()
        draft.noteCompletion(.completed)
        var events: [String] = []
        let startedAt = Date(timeIntervalSince1970: 1_788_000_000)

        await AutomaticSyncObserverEventLifecycle.process(
            startedAt: startedAt,
            now: { startedAt.addingTimeInterval(7) },
            eventHandler: {
                events.append("event")
                return draft
            },
            acknowledge: {
                events.append("acknowledge")
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: fileURL.path),
                    "Diagnostic persistence must not begin before HealthKit is acknowledged."
                )
            },
            persistDiagnostic: { completedDraft, latency in
                events.append("persist")
                completedDraft.noteObserverCompletionLatency(latency)
                XCTAssertTrue(store.recordFinal(completedDraft.record))
            }
        )

        XCTAssertEqual(events, ["event", "acknowledge", "persist"])
        XCTAssertEqual(
            store.latestRecord?.observerCompletionLatencyBucket,
            .fiveToThirtySeconds
        )
    }

    func testHistoryEvictsOldestRecordsAtBound() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(
            fileURL: fileURL,
            maximumRecordCount: 3
        )

        for remaining in 0..<5 {
            XCTAssertTrue(
                store.record(makeRecord(remainingPendingLaneCount: remaining))
            )
        }

        XCTAssertEqual(
            store.history.map(\.remainingPendingLaneCount),
            [2, 3, 4]
        )
    }

    func testMissingAndCorruptFilesRecoverWithoutThrowing() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let missingStore = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        XCTAssertTrue(missingStore.history.isEmpty)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        let corruptStore = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        XCTAssertTrue(corruptStore.history.isEmpty)

        XCTAssertTrue(
            corruptStore.record(makeRecord(remainingPendingLaneCount: 1))
        )
        XCTAssertEqual(corruptStore.history.count, 1)
    }

    func testPendingLaneAgeUsesCoarseObservedDurationBuckets() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
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

    func testQuantityPendingAgeTracksOnlyTheCoarseLane() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let firstSeen = Date(timeIntervalSince1970: 1_788_000_000)

        _ = store.pendingSnapshot(
            pendingTypeCodes: ["heart_rate"],
            now: firstSeen
        )
        let replacement = store.pendingSnapshot(
            pendingTypeCodes: ["respiratory_rate"],
            now: firstSeen.addingTimeInterval(25 * 60 * 60)
        )

        XCTAssertEqual(replacement.pendingLaneCount, 1)
        XCTAssertEqual(replacement.oldestPendingLane, .quantity)
        XCTAssertEqual(replacement.oldestPendingLaneAgeBucket, .oneToThreeDays)
    }

    func testRecoveryScrubsLegacyNonLanePendingKeysFromDisk() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fixture = """
        {
          "pendingSinceBucketByLane": {
            "quantity": 1986666,
            "quantity:legacy-deterministic-hash": 1986665
          },
          "records": [],
          "version": 1
        }
        """
        try Data(fixture.utf8).write(to: fileURL, options: .atomic)

        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        XCTAssertTrue(store.history.isEmpty)

        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        let pendingKeys = try XCTUnwrap(
            persisted["pendingSinceBucketByLane"] as? [String: Int]
        )
        XCTAssertEqual(Set(pendingKeys.keys), ["quantity"])
    }

    func testLatestLaneRenderingOmitsPrivateValuesAndIdentifiers() {
        let record = makeRecord(remainingPendingLaneCount: 1)

        XCTAssertEqual(
            record.latestLaneSummary,
            "trigger=observer/sleep; admission=accepted; selected=quantity; pending=2; oldest=sleep (observed pending 1–6h); outcome=completed; remaining=1; observer completion=5–30s"
        )
        XCTAssertFalse(record.latestLaneSummary.contains(record.runID.uuidString))
    }

    func testObserverCompletionLatencyUpdatesOnlyTheMatchingRun() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let sleepRunID = UUID()
        let stepsRunID = UUID()
        XCTAssertTrue(
            store.record(
                makeRecord(
                    runID: sleepRunID,
                    triggerLane: .sleep,
                    observerCompletionLatencyBucket: .pending,
                    remainingPendingLaneCount: 2
                )
            )
        )
        XCTAssertTrue(
            store.record(
                makeRecord(
                    runID: stepsRunID,
                    triggerLane: .steps,
                    observerCompletionLatencyBucket: .pending,
                    remainingPendingLaneCount: 1
                )
            )
        )

        XCTAssertTrue(
            store.noteObserverCompletionLatency(7, runID: sleepRunID)
        )

        XCTAssertEqual(
            store.history.map(\.observerCompletionLatencyBucket),
            [.fiveToThirtySeconds, .pending]
        )
    }

    func testAcceptedDeferredAndFailedOutcomesRemainDistinct() {
        let draft = AutomaticSyncDiagnosticDraft(
            reason: .observer(typeCode: HealthBridgeHealthType.sleepAnalysis.typeCode)
        )
        draft.noteRunAccepted()
        XCTAssertEqual(draft.record.runOutcome, .accepted)

        draft.noteCompletion(.deferred)
        XCTAssertEqual(draft.record.runOutcome, .deferred)

        draft.noteCompletion(.failed)
        XCTAssertEqual(draft.record.runOutcome, .failed)
    }

    func testFinalRecordReplacesOnlyItsDurableAcceptedCheckpoint() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let acceptedRunID = UUID()
        XCTAssertTrue(
            store.recordAccepted(
                makeRecord(
                    runID: acceptedRunID,
                    runOutcome: .accepted,
                    remainingPendingLaneCount: 2
                )
            )
        )

        XCTAssertTrue(
            store.recordFinal(
                makeRecord(
                    runID: acceptedRunID,
                    runOutcome: .completed,
                    remainingPendingLaneCount: 1
                )
            )
        )

        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history.first?.runOutcome, .completed)
    }

    func testSkippedAttemptCannotReplaceAnotherRunsAcceptedCheckpoint() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let acceptedRunID = UUID()
        let skippedRunID = UUID()
        XCTAssertTrue(
            store.recordAccepted(
                makeRecord(
                    runID: acceptedRunID,
                    runOutcome: .accepted,
                    remainingPendingLaneCount: 2
                )
            )
        )

        XCTAssertTrue(
            store.recordFinal(
                makeRecord(
                    runID: skippedRunID,
                    runOutcome: .skipped,
                    remainingPendingLaneCount: 2
                )
            )
        )

        XCTAssertEqual(store.history.count, 2)
        XCTAssertEqual(store.history[0].runID, acceptedRunID)
        XCTAssertEqual(store.history[0].runOutcome, .accepted)
        XCTAssertEqual(store.history[1].runID, skippedRunID)
        XCTAssertEqual(store.history[1].runOutcome, .skipped)
    }

    func testBoundedHistoryPreservesTheActiveAcceptedCheckpoint() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(
            fileURL: fileURL,
            maximumRecordCount: 3
        )
        let acceptedRunID = UUID()
        XCTAssertTrue(
            store.recordAccepted(
                makeRecord(
                    runID: acceptedRunID,
                    runOutcome: .accepted,
                    remainingPendingLaneCount: 2
                )
            )
        )

        for _ in 0..<5 {
            XCTAssertTrue(
                store.record(
                    makeRecord(
                        runOutcome: .skipped,
                        remainingPendingLaneCount: 2
                    )
                )
            )
        }

        XCTAssertEqual(store.history.count, 3)
        XCTAssertTrue(store.history.contains(where: { $0.runID == acceptedRunID }))
    }

    private func makeRecord(
        runID: UUID = UUID(),
        triggerLane: AutomaticSyncDiagnosticLane = .sleep,
        runOutcome: AutomaticSyncDiagnosticRunOutcome = .completed,
        observerCompletionLatencyBucket: AutomaticSyncObserverCompletionLatencyBucket = .fiveToThirtySeconds,
        remainingPendingLaneCount: Int
    ) -> AutomaticSyncDiagnosticRecord {
        AutomaticSyncDiagnosticRecord(
            runID: runID,
            wakeSource: .healthKitObserver,
            triggerReason: .observer,
            triggerLane: triggerLane,
            admissionResult: .accepted,
            selectedLane: .quantity,
            pendingLaneCount: 2,
            oldestPendingLane: .sleep,
            oldestPendingLaneAgeBucket: .oneToSixHours,
            runOutcome: runOutcome,
            observerCompletionLatencyBucket: observerCompletionLatencyBucket,
            remainingPendingLaneCount: remainingPendingLaneCount
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "automatic-sync-diagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
            .appendingPathComponent("state.json")
    }
}

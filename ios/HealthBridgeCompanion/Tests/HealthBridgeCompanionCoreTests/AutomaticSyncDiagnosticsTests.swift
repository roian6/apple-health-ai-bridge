import XCTest
@testable import HealthBridgeCompanionCore

final class AutomaticSyncDiagnosticsTests: XCTestCase {
    @MainActor
    func testObserverAcknowledgesBeforeContinuationAndDiagnosticPersistence() async {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let draft = AutomaticSyncDiagnosticDraft(
            reason: .observer(typeCode: HealthBridgeHealthType.sleepAnalysis.typeCode)
        )
        draft.noteRunAccepted()
        draft.noteCompletion(.completed)
        var events: [String] = []
        var resumeContinuation: CheckedContinuation<Void, Never>?
        let startedAt = Date(timeIntervalSince1970: 1_788_000_000)

        let processing = Task { @MainActor in
            await AutomaticSyncObserverEventLifecycle.process(
                startedAt: startedAt,
                now: { startedAt.addingTimeInterval(0.25) },
                admissionHandler: {
                    events.append("admission")
                    return .continueProcessing
                },
                eventHandler: {
                    events.append("continuation started")
                    await withCheckedContinuation { continuation in
                        resumeContinuation = continuation
                    }
                    events.append("continuation finished")
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
        }

        while resumeContinuation == nil { await Task.yield() }
        XCTAssertEqual(events, ["admission", "acknowledge", "continuation started"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        resumeContinuation?.resume()
        await processing.value

        XCTAssertEqual(events, [
            "admission", "acknowledge", "continuation started", "continuation finished", "persist",
        ])
        XCTAssertEqual(store.latestRecord?.observerCompletionLatencyBucket, .underOneSecond)
    }

    @MainActor
    func testObserverAdmissionCanFinishWithoutStartingContinuation() async {
        let draft = AutomaticSyncDiagnosticDraft(
            reason: .observer(typeCode: HealthBridgeHealthType.sleepAnalysis.typeCode)
        )
        var events: [String] = []
        await AutomaticSyncObserverEventLifecycle.process(
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            admissionHandler: {
                events.append("admission")
                return .complete(draft)
            },
            eventHandler: {
                events.append("continuation")
                return nil
            },
            acknowledge: { events.append("acknowledge") },
            persistDiagnostic: { _, _ in events.append("persist") }
        )
        XCTAssertEqual(events, ["admission", "acknowledge", "persist"])
    }

    @MainActor
    func testObserverDurableAdmissionFailureAcknowledgesWithoutStartingContinuation() async {
        let draft = AutomaticSyncDiagnosticDraft(
            reason: .observer(typeCode: HealthBridgeHealthType.sleepAnalysis.typeCode)
        )
        var events: [String] = []
        await AutomaticSyncObserverEventLifecycle.process(
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            admissionHandler: {
                events.append("admission")
                return .complete(draft)
            },
            eventHandler: {
                events.append("continuation")
                return nil
            },
            acknowledge: { events.append("acknowledge") },
            persistDiagnostic: { _, _ in events.append("persist") }
        )
        XCTAssertEqual(events, ["admission", "acknowledge", "persist"])
    }

    @MainActor
    func testObserverContinuationAcknowledgesBeforeAcquisition() async {
        let draft = AutomaticSyncDiagnosticDraft(
            reason: .observer(typeCode: HealthBridgeHealthType.steps.typeCode)
        )
        var events: [String] = []
        await AutomaticSyncObserverEventLifecycle.process(
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            admissionHandler: {
                events.append("admission")
                return .continueProcessing
            },
            eventHandler: {
                events.append("acquisition")
                return draft
            },
            acknowledge: { events.append("acknowledge") },
            persistDiagnostic: { _, _ in events.append("persist") }
        )

        XCTAssertEqual(
            events,
            ["admission", "acknowledge", "acquisition", "persist"]
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

    func testFailureRecoveryKeepsPendingAgeWhenDurableReloadIsUnavailable() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let firstSeen = Date(timeIntervalSince1970: 1_788_000_000)
        _ = store.pendingSnapshot(
            pendingTypeCodes: ["sleep_analysis"],
            now: firstSeen
        )
        let remaining = store.pendingSnapshot(
            pendingTypeCodes: ["sleep_analysis"],
            now: firstSeen.addingTimeInterval(25 * 60 * 60)
        )

        XCTAssertEqual(remaining.pendingLaneCount, 1)
        XCTAssertEqual(remaining.oldestPendingLane, .sleep)
        XCTAssertEqual(remaining.oldestPendingLaneAgeBucket, .oneToThreeDays)
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
        XCTAssertEqual(draft.record.failure, .unknown)
    }

    func testFailureClassificationSeparatesStageCategoryAndCancellation() {
        for stage in [
            AutomaticSyncDiagnosticFailureStage.read,
            .store,
            .encoding,
            .transport,
        ] {
            XCTAssertEqual(
                AutomaticSyncDiagnosticFailure.classified(
                    stage: stage,
                    isCancellation: false
                ),
                AutomaticSyncDiagnosticFailure(
                    stage: stage,
                    category: .operationFailed
                )
            )
        }
        XCTAssertEqual(
            AutomaticSyncDiagnosticFailure.classified(
                stage: .transport,
                isCancellation: true
            ),
            AutomaticSyncDiagnosticFailure(
                stage: .transport,
                category: .cancellation
            )
        )
        XCTAssertEqual(
            AutomaticSyncDiagnosticFailure.classified(
                stage: .unknown,
                isCancellation: false
            ),
            .unknown
        )
    }

    func testTypedFailureRoundTripsWithoutAnArbitraryErrorStringField() throws {
        let rawPrivateError = "https://private.invalid/path Bearer synthetic-secret"
        let record = makeRecord(
            failure: AutomaticSyncDiagnosticFailure(
                stage: .encoding,
                category: .operationFailed
            ),
            remainingPendingLaneCount: 1
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(
            AutomaticSyncDiagnosticRecord.self,
            from: data
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let failure = try XCTUnwrap(object["failure"] as? [String: String])

        XCTAssertEqual(decoded.failure, record.failure)
        XCTAssertEqual(failure, ["category": "operation_failed", "stage": "encoding"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(rawPrivateError))
    }

    func testLatestLaneRenderingIncludesOnlyBoundedFailureMetadata() {
        let record = makeRecord(
            failure: AutomaticSyncDiagnosticFailure(
                stage: .read,
                category: .operationFailed
            ),
            remainingPendingLaneCount: 1
        )

        XCTAssertTrue(record.latestLaneSummary.contains("failure=read/operation_failed"))
        XCTAssertFalse(record.latestLaneSummary.contains("NSError"))
        XCTAssertFalse(record.latestLaneSummary.contains("http"))
    }

    func testUnknownFutureFailureEnumsDecodeAsUnknownWithoutDroppingRecord() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let baseData = try JSONEncoder().encode(
            makeRecord(remainingPendingLaneCount: 1)
        )
        var record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: baseData) as? [String: Any]
        )
        record["failure"] = [
            "category": "future_failure_category",
            "stage": "future_failure_stage",
        ]
        let snapshot: [String: Any] = [
            "pendingSinceBucketByLane": [:],
            "records": [record],
            "version": 1,
        ]
        try JSONSerialization.data(withJSONObject: snapshot)
            .write(to: fileURL, options: .atomic)

        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)

        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.latestRecord?.failure, .unknown)
    }

    func testLegacyJSONWithoutFailureMetadataRetainsItsRecord() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyRecordData = try JSONEncoder().encode(
            makeRecord(remainingPendingLaneCount: 1)
        )
        var legacyRecord = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyRecordData) as? [String: Any]
        )
        legacyRecord.removeValue(forKey: "failure")
        let snapshot: [String: Any] = [
            "pendingSinceBucketByLane": [:],
            "records": [legacyRecord],
            "version": 1,
        ]
        try JSONSerialization.data(withJSONObject: snapshot)
            .write(to: fileURL, options: .atomic)

        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)

        XCTAssertEqual(store.history.count, 1)
        XCTAssertNil(store.latestRecord?.failure)
    }

    func testFinalRecordPreservesTypedFailureOnAcceptedCheckpointReplacement() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AutomaticSyncDiagnosticStore(fileURL: fileURL)
        let runID = UUID()
        XCTAssertTrue(
            store.recordAccepted(
                makeRecord(
                    runID: runID,
                    runOutcome: .accepted,
                    remainingPendingLaneCount: 1
                )
            )
        )

        XCTAssertTrue(
            store.recordFinal(
                makeRecord(
                    runID: runID,
                    runOutcome: .failed,
                    failure: AutomaticSyncDiagnosticFailure(
                        stage: .store,
                        category: .operationFailed
                    ),
                    remainingPendingLaneCount: 1
                )
            )
        )
        XCTAssertEqual(
            store.latestRecord?.failure,
            AutomaticSyncDiagnosticFailure(
                stage: .store,
                category: .operationFailed
            )
        )
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
        failure: AutomaticSyncDiagnosticFailure? = nil,
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
            failure: failure,
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

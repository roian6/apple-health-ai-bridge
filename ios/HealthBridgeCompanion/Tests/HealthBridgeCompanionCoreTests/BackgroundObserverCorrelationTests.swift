import XCTest
@testable import HealthBridgeCompanionCore

// This adapter uses the production callback handoff, gate, planner, executor and files.
// Only the HealthKit query is substituted; no timers or polling drive completion.
final class BackgroundObserverCorrelationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_100)

    @MainActor
    func testErrorRetentionACKAdmissionQueryAndFinalShareOneLocalRun() async throws {
        for outcome in [AutomaticSyncDiagnosticRunOutcome.completed, .failed, .interrupted] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let manager = ACKCheckingFileManager()
            let diagnostics = AutomaticSyncDiagnosticStore(fileURL: directory.appendingPathComponent("diagnostics.json"), fileManager: manager)
            let disk = CorrelationRecoveryStore(fileURL: directory.appendingPathComponent("recovery.json"))
            let recovery = BackgroundDeliveryFailureRecovery(store: disk)
            recovery.activate(generation: 1)
            var events: [String] = []
            disk.beforeIO = { XCTAssertFalse(manager.acknowledged); events.append("retention") }
            let runID = UUID()
            let ack = BackgroundObserverAcknowledgement { manager.acknowledged = true; events.append("ack") }
            let transfer = try XCTUnwrap(recovery.observerFailureHandoff(
                typeCode: "heart_rate", generation: 1,
                runID: runID, completionLatency: 0.25, acknowledge: ack.call
            ))
            XCTAssertTrue(transfer.localRecoveryEligible)
            XCTAssertEqual(events.first, "retention")
            XCTAssertEqual(events.last, "ack")
            XCTAssertEqual(events.filter { $0 == "ack" }.count, 1)
            disk.beforeIO = { XCTAssertTrue(manager.acknowledged) }
            let draft = transfer.diagnostic
            recovery.noteDiagnosticPending(draft, settingsTypeCodes: [], using: diagnostics, initial: true, now: now)
            draft.checkpoint(using: diagnostics)
            XCTAssertEqual(draft.record.pendingLaneCount, 1)
            XCTAssertEqual(draft.record.remainingPendingLaneCount, 1)
            XCTAssertEqual(diagnostics.history.map(\.runID), [runID])

            let gate = BackgroundSyncRunGate()
            let admission = await gate.beginRun(reason: .launchCatchUp, now: now)
            draft.noteAdmission(admission)
            XCTAssertTrue(admission.shouldRun)
            // A real settings-store accepted marker, as in the ViewModel.
            let suite = "ObserverCorrelation.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = BackgroundSyncSettingsStore(userDefaults: defaults)
            try settings.recordRunLifecycle(startedAt: now, finishedAt: nil, outcome: .accepted,
                succeeded: false, summary: "Synthetic admission")
            draft.noteRunAccepted()
            let available = ["heart_rate", "oxygen_saturation"]
            let pending = try recovery.pendingObserverTypeCodes(availableTypeCodes: available)
            let snapshot = try recovery.observerGenerationSnapshot()
            let plan = HealthBridgeBackgroundSync.workPlan(reason: .launchCatchUp,
                availableQuantityTypeCodes: available, pendingObserverTypeCodes: pending,
                continuationLaneID: nil,
                coreLaneLastSuccess: Dictionary(uniqueKeysWithValues: HealthBridgeBackgroundSync.coreWorkLanes.map { ($0.id, now) }), now: now)
            draft.noteSelection(plan.lane)
            draft.notePlan(plan.attempts.map(\.lane))
            XCTAssertLessThanOrEqual(plan.attempts.count, BackgroundSyncWorkPlan.maximumLaneAttempts)
            XCTAssertTrue(diagnostics.recordAccepted(draft.record))
            var queries = 0
            do {
                _ = try await BackgroundSyncWorkExecutor.execute(plan: plan, prepare: { _ in }, runLane: { lane in
                    XCTAssertTrue(manager.acknowledged)
                    queries += 1
                    draft.noteAttempt(lane)
                    draft.noteQueryStarted()
                    if outcome == .interrupted { throw CancellationError() }
                    if outcome == .failed {
                        draft.noteFailure(.classified(stage: .read, isCancellation: false))
                        return false
                    }
                    draft.noteQuery(.noRecords, newestSampleAge: nil, now: self.now)
                    draft.noteDelivery(.accepted, now: self.now)
                    return true
                }, didComplete: { attempt in
                    try recovery.completeObserverWork(typeCodes: attempt.coveredObserverTypeCodes,
                        matching: snapshot, availableTypeCodes: available)
                })
            } catch is CancellationError {
                draft.noteFailure(.classified(stage: .read, isCancellation: true))
            }
            XCTAssertGreaterThan(queries, 0)
            draft.noteCompletion(outcome)
            recovery.noteDiagnosticPending(draft, settingsTypeCodes: [], using: diagnostics, initial: false, now: now)
            XCTAssertTrue(diagnostics.recordFinal(draft.record))
            let history = AutomaticSyncDiagnosticStore(fileURL: diagnostics.fileURL).history
            // Retention, acceptance and finalization must upsert, never duplicate the run.
            XCTAssertEqual(history.count, 1)
            let final = try XCTUnwrap(history.last)
            XCTAssertEqual(final.runID, runID)
            XCTAssertEqual(final.wakeSource, .healthKitObserver)
            XCTAssertEqual(final.triggerReason.rawValue, "observer_error")
            XCTAssertEqual(final.triggerLane, .quantity)
            XCTAssertEqual(final.observerCompletionLatencyBucket, .underOneSecond)
            XCTAssertEqual(final.admissionResult, .accepted)
            XCTAssertEqual(final.runOutcome, outcome)
            XCTAssertEqual(final.pendingLaneCount, 1)
            XCTAssertEqual(final.remainingPendingLaneCount, outcome == .completed ? 0 : 1)
            XCTAssertEqual(final.causalChain?.lanes.first?.query,
                outcome == .completed ? .noRecords : outcome == .failed ? .failed : .cancelled)
            try assertRecovery(final, initialLanes: ["quantity"], remainingLanes: outcome == .completed ? [] : ["quantity"], state: "available")
            for url in [diagnostics.fileURL, disk.file.fileURL] {
                let data = try Data(contentsOf: url)
                let text = String(decoding: data, as: UTF8.self)
                XCTAssertFalse(text.contains("heart_rate"))
                XCTAssertFalse(text.contains("oxygen_saturation"))
                XCTAssertLessThan(data.count, url == disk.file.fileURL ? 4_096 : AutomaticSyncDiagnosticStore.maximumStorageBytes)
            }
        }
    }

    @MainActor
    func testUnavailableRetentionKeepsErrorIdentityAndNonzeroUnknownBacklog() async throws {
        for failsLoad in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let manager = ACKCheckingFileManager()
            let diagnostics = AutomaticSyncDiagnosticStore(fileURL: directory.appendingPathComponent("diagnostics.json"), fileManager: manager)
            let disk = CorrelationRecoveryStore(fileURL: directory.appendingPathComponent("recovery.json"))
            disk.failLoad = failsLoad
            disk.failSave = !failsLoad
            let recovery = BackgroundDeliveryFailureRecovery(store: disk)
            recovery.activate(generation: 1)
            disk.beforeIO = { XCTAssertFalse(manager.acknowledged) }
            let id = UUID()
            let transfer = try XCTUnwrap(recovery.observerFailureHandoff(typeCode: "oxygen_saturation", generation: 1,
                runID: id, completionLatency: 0.25, acknowledge: { manager.acknowledged = true }))
            XCTAssertFalse(transfer.localRecoveryEligible)
            recovery.noteDiagnosticPending(transfer.diagnostic, settingsTypeCodes: [], using: diagnostics, initial: true, now: now)
            recovery.noteDiagnosticPending(transfer.diagnostic, settingsTypeCodes: [], using: diagnostics, initial: false, now: now)
            transfer.diagnostic.checkpoint(using: diagnostics)
            let record = try XCTUnwrap(diagnostics.latestRecord)
            XCTAssertEqual(record.runID, id)
            XCTAssertEqual(record.triggerReason.rawValue, "observer_error")
            XCTAssertEqual(record.triggerLane, .quantity)
            XCTAssertEqual(record.admissionResult, .durableStateUnavailable)
            XCTAssertEqual(record.runOutcome, .skipped)
            XCTAssertGreaterThan(record.pendingLaneCount, 0)
            XCTAssertGreaterThan(record.remainingPendingLaneCount, 0)
            XCTAssertTrue(record.causalChain?.lanes.isEmpty == true)
            try assertRecovery(record, initialLanes: ["quantity"], remainingLanes: ["quantity"], state: "unavailable")
        }
    }

    @MainActor
    func testRecoveryOnlyBacklogAfterRestartAndUnavailableBeforeCallbackAreNotEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = CorrelationRecoveryStore(fileURL: directory.appendingPathComponent("recovery.json"))
        var recovery = BackgroundDeliveryFailureRecovery(store: disk)
        recovery.activate(generation: 1)
        _ = recovery.processObserverFailure(typeCode: "heart_rate", generation: 1, acknowledge: {})
        recovery = BackgroundDeliveryFailureRecovery(store: disk)
        recovery.activate(generation: 2)
        let diagnostics = AutomaticSyncDiagnosticStore(fileURL: directory.appendingPathComponent("diagnostics.json"))
        let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
        recovery.noteDiagnosticPending(draft, settingsTypeCodes: ["oxygen_saturation"], using: diagnostics, initial: true, now: now)
        recovery.noteDiagnosticPending(draft, settingsTypeCodes: [], using: diagnostics, initial: false, now: now)
        XCTAssertEqual(draft.record.pendingLaneCount, 1) // union, not double counted
        XCTAssertEqual(draft.record.remainingPendingLaneCount, 1)
        try assertRecovery(draft.record, initialLanes: ["quantity"], remainingLanes: ["quantity"], state: "available")
        disk.failLoad = true
        recovery = BackgroundDeliveryFailureRecovery(store: disk)
        recovery.activate(generation: 3)
        let unavailable = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
        recovery.noteDiagnosticPending(unavailable, settingsTypeCodes: [], using: diagnostics, initial: true, now: now)
        recovery.noteDiagnosticPending(unavailable, settingsTypeCodes: [], using: diagnostics, initial: false, now: now)
        XCTAssertGreaterThan(unavailable.record.pendingLaneCount, 0)
        XCTAssertGreaterThan(unavailable.record.remainingPendingLaneCount, 0)
        XCTAssertEqual(unavailable.record.oldestPendingLaneAgeBucket, .unknown)
        try assertRecovery(unavailable.record, initialLanes: [], remainingLanes: [], state: "unavailable")
    }

    @MainActor
    func testDebouncedRecoveryRetainsSameErrorChainWithoutQuery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = CorrelationRecoveryStore(fileURL: directory.appendingPathComponent("recovery.json"))
        let recovery = BackgroundDeliveryFailureRecovery(store: disk)
        recovery.activate(generation: 1)
        let diagnostics = AutomaticSyncDiagnosticStore(fileURL: directory.appendingPathComponent("diagnostics.json"))
        let gate = BackgroundSyncRunGate()
        _ = await gate.beginRun(reason: .launchCatchUp, now: now)
        _ = await gate.finishBoundedRun(completedObserverTypeCodes: [])
        let id = UUID()
        let handoff = try XCTUnwrap(recovery.observerFailureHandoff(typeCode: "heart_rate", generation: 1,
            runID: id, completionLatency: 0, acknowledge: {}))
        let draft = handoff.diagnostic
        recovery.noteDiagnosticPending(draft, settingsTypeCodes: [], using: diagnostics, initial: true, now: now)
        draft.noteAdmission(await gate.beginRun(reason: .launchCatchUp, now: now))
        recovery.noteDiagnosticPending(draft, settingsTypeCodes: [], using: diagnostics, initial: false, now: now)
        draft.checkpoint(using: diagnostics)
        let record = try XCTUnwrap(diagnostics.latestRecord)
        XCTAssertEqual(record.runID, id)
        XCTAssertEqual(record.triggerReason.rawValue, "observer_error")
        XCTAssertEqual(record.admissionResult, .skippedDebounced)
        XCTAssertEqual(record.runOutcome, .skipped)
        XCTAssertEqual(record.pendingLaneCount, 1)
        XCTAssertEqual(record.remainingPendingLaneCount, 1)
        XCTAssertTrue(record.causalChain?.lanes.isEmpty == true)
    }

    @MainActor
    func testStormOffersOneRecoveryAndStaleCallbackOnlyACKs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = CorrelationRecoveryStore(fileURL: directory.appendingPathComponent("recovery.json"))
        let recovery = BackgroundDeliveryFailureRecovery(store: disk)
        recovery.activate(generation: 1)
        var offers = 0
        var acks = 0
        for _ in 0..<100 {
            let handoff = try XCTUnwrap(recovery.observerFailureHandoff(typeCode: "heart_rate", generation: 1,
                runID: UUID(), completionLatency: 0, acknowledge: { acks += 1 }))
            if handoff.localRecoveryEligible { offers += 1 }
        }
        XCTAssertEqual(offers, 1)
        XCTAssertEqual(acks, 100)
        XCTAssertEqual(try disk.file.load().observerGenerations.count, 1)
        recovery.stop()
        XCTAssertNil(recovery.observerFailureHandoff(typeCode: "heart_rate", generation: 1,
            runID: UUID(), completionLatency: 0, acknowledge: { acks += 1 }))
        XCTAssertEqual(acks, 101)
    }

    private func assertRecovery(_ record: AutomaticSyncDiagnosticRecord, initialLanes: [String], remainingLanes: [String], state: String) throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let chain = try XCTUnwrap(json["causalChain"] as? [String: Any])
        for (key, lanes) in [("initialRecoveryPending", initialLanes), ("remainingRecoveryPending", remainingLanes)] {
            let snapshot = chain[key] as? [String: Any]
            XCTAssertNotNil(snapshot, key)
            XCTAssertEqual(snapshot?["lanes"] as? [String], lanes)
            XCTAssertEqual(snapshot?["durableState"] as? String, state)
        }
    }
}

private final class ACKCheckingFileManager: FileManager, @unchecked Sendable {
    var acknowledged = false
    override func fileExists(atPath path: String) -> Bool {
        XCTAssertTrue(acknowledged, "Diagnostic I/O preceded ACK")
        return super.fileExists(atPath: path)
    }
}

private final class CorrelationRecoveryStore: BackgroundDeliveryRecoveryStoring {
    let file: FileBackgroundDeliveryRecoveryStore
    var failLoad = false
    var failSave = false
    var beforeIO: (() -> Void)?
    init(fileURL: URL) { file = FileBackgroundDeliveryRecoveryStore(fileURL: fileURL) }
    func load() throws -> BackgroundDeliveryRecoverySnapshot {
        beforeIO?()
        if failLoad { throw BackgroundSyncSettingsStoreError.persistenceFailed }
        return try file.load()
    }
    func save(_ snapshot: BackgroundDeliveryRecoverySnapshot) throws {
        beforeIO?()
        if failSave { throw BackgroundSyncSettingsStoreError.persistenceFailed }
        try file.save(snapshot)
    }
}

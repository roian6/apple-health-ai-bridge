import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class BackgroundSyncWorkPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let cores: [BackgroundSyncWorkLane] = [.sleep, .dailyActivity, .steps, .workouts]
    private var fresh: [String: Date] {
        Dictionary(uniqueKeysWithValues: cores.map { ($0.id, now) })
    }

    func testOverdueCoresOutrankOptionalContinuationAndDirectObserver() async {
        for reason: AutomaticSyncReason in [
            .scheduledRefresh, .launchCatchUp,
            .observerBatch(typeCodes: ["heart_rate"]), .observer(typeCode: "heart_rate"),
        ] {
            let plan = HealthBridgeBackgroundSync.workPlan(
                reason: reason,
                availableQuantityTypeCodes: ["heart_rate"],
                pendingObserverTypeCodes: ["heart_rate"],
                continuationLaneID: "quantity:heart_rate",
                now: now
            )
            XCTAssertEqual(plan.lane, .sleep, "reason=\(reason)")
            XCTAssertEqual(plan.attempts.map(\.lane), cores)
            XCTAssertEqual(plan.attempts.count, 4)
        }
    }

    func testDirectObserverAffinityNeverDisplacesOverdueCores() async {
        let coreTrigger = plan(reason: .observer(typeCode: "steps"))
        XCTAssertEqual(coreTrigger.attempts.map(\.lane), [.steps, .sleep, .dailyActivity, .workouts])
        let optionalTrigger = plan(
            reason: .observer(typeCode: "heart_rate"),
            successes: ["steps": now]
        )
        XCTAssertEqual(optionalTrigger.attempts.map(\.lane), [
            .sleep, .dailyActivity, .workouts, .quantity(typeCode: "heart_rate"),
        ])
    }

    func testHighFrequencyOptionalObserversCannotDelayCoreDeadline() async {
        var successes = fresh
        for offset in [0.0, 300, 600, 899, 900, 901] {
            let opportunity = now.addingTimeInterval(offset)
            let plan = HealthBridgeBackgroundSync.workPlan(
                reason: .observer(typeCode: "heart_rate"),
                availableQuantityTypeCodes: ["heart_rate"],
                pendingObserverTypeCodes: ["heart_rate"],
                continuationLaneID: "quantity:heart_rate",
                coreLaneLastSuccess: successes,
                now: opportunity
            )
            if offset == 900 {
                XCTAssertEqual(plan.attempts.map(\.lane), cores)
                for lane in cores { successes[lane.id] = opportunity }
            } else {
                XCTAssertEqual(plan.attempts.map(\.lane), [.quantity(typeCode: "heart_rate")])
            }
        }
    }

    func testAliasesMapOnceUnknownObserverDoesNotGenerateOptionalWork() async {
        let mapped = plan(
            reason: .observerBatch(typeCodes: ["active_energy", "energy", "body_mass", "unsupported"]),
            successes: fresh
        )
        XCTAssertEqual(mapped.attempts.map(\.lane), [.dailyActivity, .quantity(typeCode: "weight")])
        XCTAssertEqual(mapped.attempts.map(\.coveredObserverTypeCodes), [["energy"], ["weight"]])
        XCTAssertTrue(plan(reason: .observer(typeCode: "unsupported"), successes: fresh).attempts.isEmpty)
    }

    func testDirtyCorePrecedesOptionalEvenWhenRecentlySuccessful() async {
        let plan = plan(
            reason: .observerBatch(typeCodes: ["heart_rate", "sleep_analysis"]),
            successes: fresh,
            continuation: "quantity:heart_rate"
        )
        XCTAssertEqual(plan.attempts.map(\.lane), [.sleep, .quantity(typeCode: "heart_rate")])
    }

    func testBudgetExhaustionAndReloadResumeOptionalRotation() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for lane in cores { try store.recordCoreLaneSuccess(lane, at: now) }
        let quantities = ["heart_rate", "oxygen_saturation", "weight", "height", "body_mass_index", "body_fat_percentage"]
        let dirty = GenericQuantityCoveragePolicy.canonicalSupportedTypeCodes(quantities)
        XCTAssertEqual(dirty.count, 6)
        try store.markPendingObserverTypeCodes(dirty)
        var attempted: [BackgroundSyncWorkLane] = []
        for _ in 0..<2 {
            let reloaded = BackgroundSyncSettingsStore(userDefaults: defaults)
            let snapshot = try reloaded.loadPendingObserverTypeCodeGenerations()
            let plan = HealthBridgeBackgroundSync.workPlan(
                reason: .observerBatch(typeCodes: Array(snapshot.keys)),
                availableQuantityTypeCodes: quantities,
                pendingObserverTypeCodes: Array(snapshot.keys),
                continuationLaneID: reloaded.nextScheduledWorkLaneID,
                coreLaneLastSuccess: reloaded.coreLaneLastSuccess,
                now: now
            )
            XCTAssertLessThanOrEqual(plan.attempts.count, 4)
            let completed = try await BackgroundSyncWorkExecutor.execute(
                plan: plan,
                prepare: { try reloaded.persistNextScheduledWorkLaneID($0.nextScheduledLaneID) },
                runLane: { lane in attempted.append(lane); return true },
                didComplete: {
                    try reloaded.clearPendingObserverTypeCodes(matching: snapshot, typeCodes: $0.coveredObserverTypeCodes)
                }
            )
            XCTAssertEqual(completed.count, plan.attempts.count)
        }
        XCTAssertEqual(attempted, dirty.sorted().map { .quantity(typeCode: $0) })
        XCTAssertTrue(try store.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertEqual(BackgroundSyncSettingsStore(userDefaults: defaults).coreLaneLastSuccess, fresh)
    }

    func testContinuationIsDurableBeforeEveryAwaitAndTransfersAreSerial() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let plan = plan(reason: .scheduledRefresh)
        var events: [String] = []
        var inFlight = false
        let completed = try await BackgroundSyncWorkExecutor.execute(
            plan: plan,
            prepare: { attempt in
                XCTAssertFalse(inFlight)
                try store.persistNextScheduledWorkLaneID(attempt.nextScheduledLaneID)
                events.append("prepare:\(attempt.lane.id)")
            },
            runLane: { lane in
                XCTAssertFalse(inFlight)
                inFlight = true
                let attempt = try XCTUnwrap(plan.attempts.first { $0.lane == lane })
                XCTAssertEqual(
                    BackgroundSyncSettingsStore(userDefaults: defaults).nextScheduledWorkLaneID,
                    attempt.nextScheduledLaneID
                )
                events.append("run:\(lane.id)")
                inFlight = false
                return true
            },
            didComplete: { events.append("complete:\($0.lane.id)") }
        )
        XCTAssertEqual(completed, plan.attempts)
        XCTAssertEqual(events, cores.flatMap { ["prepare:\($0.id)", "run:\($0.id)", "complete:\($0.id)"] })
    }

    func testAdmissionSnapshotIsImmutableAndNewDirtinessSurvivesLaneAwait() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        try store.markPendingObserverTypeCodes(["sleep_analysis"])
        let snapshot = try store.loadPendingObserverTypeCodeGenerations()
        let admitted = plan(reason: .observer(typeCode: "sleep_analysis"))
        let entered = expectation(description: "lane entered")
        let finished = expectation(description: "executor finished")
        var resumeLane: CheckedContinuation<Void, Never>?
        var attempted: [BackgroundSyncWorkLane] = []
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            return try await BackgroundSyncWorkExecutor.execute(
                plan: admitted,
                prepare: { try store.persistNextScheduledWorkLaneID($0.nextScheduledLaneID) },
                runLane: { lane in
                    attempted.append(lane)
                    if lane == .sleep {
                        await withCheckedContinuation { continuation in
                            resumeLane = continuation
                            entered.fulfill()
                        }
                    }
                    return true
                },
                didComplete: { try store.clearPendingObserverTypeCodes(matching: snapshot, typeCodes: $0.coveredObserverTypeCodes) }
            )
        }
        let entryResult = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(entryResult, .completed)
        XCTAssertEqual(attempted, [.sleep], "no second cursor-bearing transfer during the lane await")
        try store.markPendingObserverTypeCodes(["sleep_analysis", "heart_rate"])
        resumeLane?.resume()
        let finishResult = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(finishResult, .completed)
        guard finishResult == .completed else { task.cancel(); return }
        _ = try await task.value
        XCTAssertEqual(attempted, cores)
        XCTAssertEqual(store.pendingObserverTypeCodes, ["heart_rate", "sleep_analysis"])
        XCTAssertEqual(admitted.attempts.map(\.lane), cores)
    }

    func testLaneFailureStopsAndRetainsFailedAndUnattemptedGenerations() async throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dirty = ["sleep_analysis", "energy", "steps", "workout", "heart_rate"]
        try store.markPendingObserverTypeCodes(dirty)
        let snapshot = try store.loadPendingObserverTypeCodeGenerations()
        let admitted = plan(reason: .observerBatch(typeCodes: dirty))
        var attempted: [BackgroundSyncWorkLane] = []
        let completed = try await BackgroundSyncWorkExecutor.execute(
            plan: admitted,
            prepare: { try store.persistNextScheduledWorkLaneID($0.nextScheduledLaneID) },
            runLane: { lane in attempted.append(lane); return lane != .dailyActivity },
            didComplete: {
                try store.clearPendingObserverTypeCodes(matching: snapshot, typeCodes: $0.coveredObserverTypeCodes)
                try store.recordCoreLaneSuccess($0.lane, at: self.now)
            }
        )
        XCTAssertEqual(attempted, [.sleep, .dailyActivity])
        XCTAssertEqual(completed.map(\.lane), [.sleep])
        XCTAssertEqual(store.pendingObserverTypeCodes, ["energy", "heart_rate", "steps", "workout"])
        XCTAssertEqual(store.coreLaneLastSuccess, ["sleep": now])
        let reloaded = BackgroundSyncSettingsStore(userDefaults: defaults)
        let retry = HealthBridgeBackgroundSync.workPlan(
            reason: .launchCatchUp,
            availableQuantityTypeCodes: ["heart_rate"],
            pendingObserverTypeCodes: reloaded.pendingObserverTypeCodes,
            continuationLaneID: reloaded.nextScheduledWorkLaneID,
            coreLaneLastSuccess: reloaded.coreLaneLastSuccess,
            now: now
        )
        XCTAssertEqual(Array(retry.attempts.map(\.lane).prefix(3)), [.dailyActivity, .steps, .workouts])
    }

    func testFIFOHeadOrUnreadableOutboxStopsWithoutClearingAttempt() async throws {
        for pendingCount: Int? in [1, nil] {
            var attempted: [BackgroundSyncWorkLane] = []
            var cleared: [BackgroundSyncWorkLane] = []
            let completed = try await BackgroundSyncWorkExecutor.execute(
                plan: plan(reason: .scheduledRefresh),
                prepare: { _ in },
                runLane: { lane in
                    attempted.append(lane)
                    return AutomaticSyncPayloadGenerationPolicy.shouldGenerateNewPayloads(trustedPendingOutboxCount: pendingCount)
                },
                didComplete: { cleared.append($0.lane) }
            )
            XCTAssertEqual(attempted, [.sleep])
            XCTAssertTrue(completed.isEmpty)
            XCTAssertTrue(cleared.isEmpty)
        }
    }

    func testContinuationPersistenceFailurePreventsLaneAwait() async {
        var attempted = false
        do {
            _ = try await BackgroundSyncWorkExecutor.execute(
                plan: plan(reason: .scheduledRefresh),
                prepare: { _ in throw BackgroundSyncSettingsStoreError.persistenceFailed },
                runLane: { _ in attempted = true; return true },
                didComplete: { _ in XCTFail("must not clear") }
            )
            XCTFail("must propagate persistence failure")
        } catch {
            XCTAssertEqual(error as? BackgroundSyncSettingsStoreError, .persistenceFailed)
        }
        XCTAssertFalse(attempted)
    }

    func testCancellationBeforeStartAndDuringAwaitNeverClearsOrStartsNextLane() async throws {
        for cancelBeforeStart in [true, false] {
            let admitted = plan(reason: .scheduledRefresh)
            let entered = expectation(description: "entered suspension")
            let finished = expectation(description: "cancelled execution finished")
            var resume: CheckedContinuation<Void, Never>?
            var attempts: [BackgroundSyncWorkLane] = []
            var prepared = 0
            let task = Task { @MainActor in
                defer { finished.fulfill() }
                if cancelBeforeStart {
                    await withCheckedContinuation { resume = $0; entered.fulfill() }
                }
                do {
                    _ = try await BackgroundSyncWorkExecutor.execute(
                        plan: admitted,
                        prepare: { _ in prepared += 1 },
                        runLane: { lane in
                            attempts.append(lane)
                            await withCheckedContinuation { resume = $0; entered.fulfill() }
                            return true
                        },
                        didComplete: { _ in XCTFail("cancelled lane must stay dirty") }
                    )
                    XCTFail("must throw cancellation")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
            let entryResult = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
            XCTAssertEqual(entryResult, .completed)
            task.cancel()
            resume?.resume()
            let finishResult = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(finishResult, .completed)
            guard finishResult == .completed else { task.cancel(); return }
            await task.value
            XCTAssertEqual(attempts, cancelBeforeStart ? [] : [.sleep])
            XCTAssertEqual(prepared, cancelBeforeStart ? 0 : 1)
        }
    }

    func testBoundedGateRetainsNewSameTypeAndUncompletedWork() async {
        let gate = BackgroundSyncRunGate(minimumSpacing: 0)
        let admission = await gate.beginRun(reason: .observerBatch(typeCodes: ["steps", "sleep_analysis"]), now: now)
        XCTAssertTrue(admission.shouldRun)
        let overlapping = await gate.beginRun(reason: .observer(typeCode: "steps"), now: now)
        XCTAssertEqual(overlapping.skipReason, .alreadyRunning)
        await gate.completeActiveObserverTypeCodes(["steps"])
        let pending = await gate.finishRun(.interrupted)
        XCTAssertEqual(pending, ["sleep_analysis", "steps"])
    }

    func testUnknownContinuationAndFutureFreshnessFailClosed() async {
        let plan = plan(reason: .launchCatchUp, successes: ["sleep": now.addingTimeInterval(1)], continuation: "removed")
        XCTAssertEqual(plan.attempts.map(\.lane), cores)
    }

    private func plan(
        reason: AutomaticSyncReason,
        successes: [String: Date] = [:],
        continuation: String? = nil
    ) -> BackgroundSyncWorkPlan {
        HealthBridgeBackgroundSync.workPlan(
            reason: reason,
            availableQuantityTypeCodes: ["heart_rate", "weight"],
            pendingObserverTypeCodes: reason.observerTypeCodes,
            continuationLaneID: continuation,
            coreLaneLastSuccess: successes,
            now: now
        )
    }

    private func makeStore() throws -> (BackgroundSyncSettingsStore, UserDefaults, String) {
        let suite = "BackgroundSyncWorkPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (BackgroundSyncSettingsStore(userDefaults: defaults), defaults, suite)
    }
}

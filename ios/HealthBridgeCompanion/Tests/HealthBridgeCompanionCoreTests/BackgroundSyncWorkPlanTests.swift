import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class BackgroundSyncWorkPlanTests: XCTestCase {
    func testObserverReasonsMapToOneCorrectLaneAndUnknownFailsClosed() {
        let availableQuantityTypeCodes = [
            "energy",
            "heart_rate",
            "oxygen_saturation",
            "weight",
        ]
        let cases: [(AutomaticSyncReason, BackgroundSyncWorkLane?, [String])] = [
            (.observer(typeCode: "steps"), .steps, ["steps"]),
            (.observer(typeCode: "energy"), .dailyActivity, ["energy"]),
            (.observer(typeCode: "workout"), .workouts, ["workout"]),
            (.observer(typeCode: "sleep_analysis"), .sleep, ["sleep_analysis"]),
            (
                .observer(typeCode: "oxygen_saturation"),
                .quantity(typeCode: "oxygen_saturation"),
                ["oxygen_saturation"]
            ),
            (
                .observer(typeCode: "body_mass"),
                .quantity(typeCode: "weight"),
                ["weight"]
            ),
            (.observer(typeCode: "unsupported_metric"), nil, []),
        ]

        for (reason, expectedLane, expectedCoveredCodes) in cases {
            let plan = HealthBridgeBackgroundSync.workPlan(
                reason: reason,
                availableQuantityTypeCodes: availableQuantityTypeCodes,
                pendingObserverTypeCodes: reason.observerTypeCodes,
                continuationLaneID: nil
            )

            XCTAssertEqual(plan.lane, expectedLane, "reason=\(reason)")
            XCTAssertEqual(plan.coveredObserverTypeCodes, expectedCoveredCodes)
            XCTAssertNil(plan.nextScheduledLaneID)
        }
    }

    func testObserverBatchSelectsOneBoundedLaneAndLeavesOtherCodesDirty() {
        let plan = HealthBridgeBackgroundSync.workPlan(
            reason: .observerBatch(
                typeCodes: [
                    "oxygen_saturation",
                    "sleep_analysis",
                    "steps",
                    "active_energy",
                    "unsupported_metric",
                ]
            ),
            availableQuantityTypeCodes: ["energy", "oxygen_saturation"],
            pendingObserverTypeCodes: [
                "oxygen_saturation",
                "sleep_analysis",
                "steps",
                "active_energy",
                "unsupported_metric",
            ],
            continuationLaneID: nil
        )

        XCTAssertEqual(plan.lane, .steps)
        XCTAssertEqual(
            plan.coveredObserverTypeCodes,
            ["steps"]
        )
        XCTAssertNil(plan.nextScheduledLaneID)
    }

    func testScheduledPlanMakesRoundRobinProgressAcrossEveryProcessReload() throws {
        let suiteName = "BackgroundSyncWorkPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let availableQuantityTypeCodes = ["oxygen_saturation", "heart_rate"]
        var attemptedLanes: [BackgroundSyncWorkLane] = []

        for _ in 0 ..< 6 {
            let reloadedStore = BackgroundSyncSettingsStore(userDefaults: defaults)
            let plan = HealthBridgeBackgroundSync.workPlan(
                reason: .scheduledRefresh,
                availableQuantityTypeCodes: availableQuantityTypeCodes,
                pendingObserverTypeCodes: [],
                continuationLaneID: reloadedStore.nextScheduledWorkLaneID
            )
            attemptedLanes.append(try XCTUnwrap(plan.lane))
            try reloadedStore.persistNextScheduledWorkLaneID(plan.nextScheduledLaneID)
        }

        XCTAssertEqual(
            attemptedLanes,
            [
                .steps,
                .dailyActivity,
                .workouts,
                .sleep,
                .quantity(typeCode: "heart_rate"),
                .quantity(typeCode: "oxygen_saturation"),
            ]
        )
        XCTAssertEqual(
            BackgroundSyncSettingsStore(userDefaults: defaults).nextScheduledWorkLaneID,
            BackgroundSyncWorkLane.steps.id
        )
    }

    func testScheduledPlanPrioritizesDurableObserverDirtinessWithoutAdvancingCatchUp() {
        let dirtyPlan = HealthBridgeBackgroundSync.workPlan(
            reason: .scheduledRefresh,
            availableQuantityTypeCodes: ["heart_rate"],
            pendingObserverTypeCodes: ["sleep_analysis"],
            continuationLaneID: BackgroundSyncWorkLane.steps.id
        )

        XCTAssertEqual(dirtyPlan.lane, .sleep)
        XCTAssertEqual(dirtyPlan.coveredObserverTypeCodes, ["sleep_analysis"])
        XCTAssertEqual(
            dirtyPlan.nextScheduledLaneID,
            BackgroundSyncWorkLane.steps.id
        )

        let unknownPlan = HealthBridgeBackgroundSync.workPlan(
            reason: .launchCatchUp,
            availableQuantityTypeCodes: ["heart_rate"],
            pendingObserverTypeCodes: ["unsupported_metric"],
            continuationLaneID: BackgroundSyncWorkLane.dailyActivity.id
        )

        XCTAssertEqual(unknownPlan.lane, .dailyActivity)
        XCTAssertEqual(unknownPlan.coveredObserverTypeCodes, [])
        XCTAssertEqual(
            unknownPlan.nextScheduledLaneID,
            BackgroundSyncWorkLane.workouts.id
        )
    }

    func testBoundedRunGateRetainsObserverTypesOutsideCompletedLane() {
        let completed = expectation(description: "bounded gate completion")

        Task {
            let gate = BackgroundSyncRunGate(minimumSpacing: 0)
            let admission = await gate.beginRun(
                reason: .observerBatch(
                    typeCodes: ["sleep_analysis", "steps"]
                )
            )
            XCTAssertTrue(admission.shouldRun)

            let pending = await gate.finishBoundedRun(
                completedObserverTypeCodes: ["steps"]
            )

            XCTAssertEqual(pending, ["sleep_analysis"])
            let pendingSnapshot = await gate.pendingObserverTypeCodesSnapshot()
            XCTAssertEqual(pendingSnapshot, ["sleep_analysis"])
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
    }

    func testBoundedRunGateClearsCanonicalAliasAfterItsLaneCompletes() {
        let completed = expectation(description: "alias gate completion")

        Task {
            let gate = BackgroundSyncRunGate(minimumSpacing: 0)
            let admission = await gate.beginRun(
                reason: .observer(typeCode: "body_mass")
            )
            XCTAssertTrue(admission.shouldRun)

            let pending = await gate.finishBoundedRun(
                completedObserverTypeCodes: ["weight"]
            )

            XCTAssertEqual(pending, [])
            let pendingSnapshot = await gate.pendingObserverTypeCodesSnapshot()
            XCTAssertEqual(pendingSnapshot, [])
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
    }

    func testUnknownPersistedContinuationResetsToFirstBoundedLane() throws {
        let suiteName = "BackgroundSyncWorkPlanUnknownCursorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        try store.persistNextScheduledWorkLaneID("removed_lane")

        let plan = HealthBridgeBackgroundSync.workPlan(
            reason: .launchCatchUp,
            availableQuantityTypeCodes: [],
            pendingObserverTypeCodes: [],
            continuationLaneID: BackgroundSyncSettingsStore(
                userDefaults: defaults
            ).nextScheduledWorkLaneID
        )

        XCTAssertEqual(plan.lane, .steps)
        XCTAssertEqual(plan.nextScheduledLaneID, BackgroundSyncWorkLane.dailyActivity.id)
    }

    func testViewModelPersistsAcceptedBeforeBacklogAwaitAndContinuationBeforeLaneAwait() throws {
        let source = try viewModelSource()
        let methodStart = try XCTUnwrap(
            source.range(of: "private func performBackgroundRefreshSync")
        )
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "private func finishBackgroundRunPreservingObserverDirtiness",
                range: methodStart.upperBound ..< source.endIndex
            )
        )
        let method = String(source[methodStart.lowerBound ..< methodEnd.lowerBound])
        let accepted = try XCTUnwrap(method.range(of: "outcome: .accepted"))
        let backlogAwait = try XCTUnwrap(
            method.range(of: "await deferAutomaticSyncForPendingOutboxIfNeeded")
        )
        let exclusiveGate = try XCTUnwrap(
            method.range(of: "try await runWithExclusiveDirectOutboxTransfer")
        )
        let continuation = try XCTUnwrap(
            method.range(
                of: "persistScheduledWorkContinuationIfNeeded",
                range: exclusiveGate.upperBound ..< method.endIndex
            )
        )
        let laneAwait = try XCTUnwrap(
            method.range(
                of: "await self.performAdmittedBackgroundRefreshSync",
                range: continuation.upperBound ..< method.endIndex
            )
        )

        XCTAssertLessThan(accepted.lowerBound, backlogAwait.lowerBound)
        XCTAssertLessThan(backlogAwait.lowerBound, continuation.lowerBound)
        XCTAssertLessThan(continuation.lowerBound, laneAwait.lowerBound)
    }

    func testViewModelExecutesOnePlannedLaneWithoutRecursiveSweep() throws {
        let source = try viewModelSource()
        let methodStart = try XCTUnwrap(
            source.range(of: "private func performAdmittedBackgroundRefreshSync")
        )
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "private func scheduleDebouncedObserverCatchUp",
                range: methodStart.upperBound ..< source.endIndex
            )
        )
        let method = String(source[methodStart.lowerBound ..< methodEnd.lowerBound])

        XCTAssertEqual(method.components(separatedBy: "switch lane").count - 1, 1)
        XCTAssertFalse(method.contains("await performAdmittedBackgroundRefreshSync("))
        XCTAssertTrue(method.contains("syncRecentStepCounts(executionMode: .automatic)"))
        XCTAssertTrue(method.contains("syncDailyActivityAggregates(executionMode: .automatic)"))
        XCTAssertTrue(method.contains("syncAnchoredWorkoutChanges(executionMode: .automatic)"))
        XCTAssertTrue(method.contains("syncRecentSleepSessions(executionMode: .automatic)"))
        XCTAssertTrue(method.contains("typeCodes: [typeCode]"))
    }

    private func viewModelSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("App")
                .appendingPathComponent("HealthBridgeCompanionViewModel.swift"),
            encoding: .utf8
        )
    }
}

#if HEALTH_BRIDGE_STANDALONE_TEST
extension BackgroundSyncWorkPlanTests {
    static let allTests = [
        ("testObserverReasonsMapToOneCorrectLaneAndUnknownFailsClosed", testObserverReasonsMapToOneCorrectLaneAndUnknownFailsClosed),
        ("testObserverBatchSelectsOneBoundedLaneAndLeavesOtherCodesDirty", testObserverBatchSelectsOneBoundedLaneAndLeavesOtherCodesDirty),
        ("testScheduledPlanMakesRoundRobinProgressAcrossEveryProcessReload", testScheduledPlanMakesRoundRobinProgressAcrossEveryProcessReload),
        ("testScheduledPlanPrioritizesDurableObserverDirtinessWithoutAdvancingCatchUp", testScheduledPlanPrioritizesDurableObserverDirtinessWithoutAdvancingCatchUp),
        ("testBoundedRunGateRetainsObserverTypesOutsideCompletedLane", testBoundedRunGateRetainsObserverTypesOutsideCompletedLane),
        ("testBoundedRunGateClearsCanonicalAliasAfterItsLaneCompletes", testBoundedRunGateClearsCanonicalAliasAfterItsLaneCompletes),
        ("testUnknownPersistedContinuationResetsToFirstBoundedLane", testUnknownPersistedContinuationResetsToFirstBoundedLane),
        ("testViewModelPersistsAcceptedBeforeBacklogAwaitAndContinuationBeforeLaneAwait", testViewModelPersistsAcceptedBeforeBacklogAwaitAndContinuationBeforeLaneAwait),
        ("testViewModelExecutesOnePlannedLaneWithoutRecursiveSweep", testViewModelExecutesOnePlannedLaneWithoutRecursiveSweep),
    ]
}

@main
enum BackgroundSyncStandaloneTestRunner {
    static func main() {
        XCTMain([
            testCase(BackgroundSyncWorkPlanTests.allTests),
        ])
    }
}
#endif

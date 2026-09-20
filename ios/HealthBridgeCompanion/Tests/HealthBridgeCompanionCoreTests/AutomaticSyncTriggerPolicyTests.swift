import XCTest
@testable import HealthBridgeCompanionCore

final class AutomaticSyncTriggerPolicyTests: XCTestCase {
    func testLaunchAndScheduledRefreshBroadenToNormalizedSelectedEligibleTypes() {
        XCTAssertEqual(
            AutomaticSyncTriggerPolicy.selectedTypeCodes(
                for: .launchCatchUp,
                selectedEligibleTypeCodes: [
                    "steps", "body_mass", "active_energy", "steps",
                ],
                pendingGenerations: ["heart_rate": 1]
            ),
            ["energy", "heart_rate", "steps", "weight"]
        )
        XCTAssertEqual(
            AutomaticSyncTriggerPolicy.selectedTypeCodes(
                for: .scheduledRefresh,
                selectedEligibleTypeCodes: ["sleep_analysis", "steps", "sleep_analysis"],
                pendingGenerations: [:]
            ),
            ["sleep_analysis", "steps"]
        )
    }

    func testObserverBatchAndManualRemainAffinedToDurablePendingTypes() {
        let selectedEligibleTypeCodes = ["steps", "sleep_analysis", "heart_rate"]

        XCTAssertEqual(
            AutomaticSyncTriggerPolicy.selectedTypeCodes(
                for: .observer(typeCode: "heart_rate"),
                selectedEligibleTypeCodes: selectedEligibleTypeCodes,
                pendingGenerations: ["heart_rate": 1]
            ),
            ["heart_rate"]
        )
        XCTAssertEqual(
            AutomaticSyncTriggerPolicy.selectedTypeCodes(
                for: .observerBatch(typeCodes: ["sleep_analysis", "heart_rate"]),
                selectedEligibleTypeCodes: selectedEligibleTypeCodes,
                pendingGenerations: ["sleep_analysis": 2, "heart_rate": 1]
            ),
            ["heart_rate", "sleep_analysis"]
        )
        XCTAssertEqual(
            AutomaticSyncTriggerPolicy.selectedTypeCodes(
                for: .manualSync,
                selectedEligibleTypeCodes: selectedEligibleTypeCodes,
                pendingGenerations: ["sleep_analysis": 2]
            ),
            ["sleep_analysis"]
        )
    }

    func testReadyForegroundAdmissionRequiresOnlyAnUnconsumedOpportunity() {
        XCTAssertTrue(
            AutomaticSyncTriggerPolicy.admitsForegroundLaunchReconciliation(
                prerequisitesAreReady: true,
                opportunityWasConsumed: false
            )
        )
        XCTAssertFalse(
            AutomaticSyncTriggerPolicy.admitsForegroundLaunchReconciliation(
                prerequisitesAreReady: false,
                opportunityWasConsumed: false
            )
        )
        XCTAssertFalse(
            AutomaticSyncTriggerPolicy.admitsForegroundLaunchReconciliation(
                prerequisitesAreReady: true,
                opportunityWasConsumed: true
            )
        )
    }
}

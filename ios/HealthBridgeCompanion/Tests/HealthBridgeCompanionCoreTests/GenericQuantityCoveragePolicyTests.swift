import XCTest
@testable import HealthBridgeCompanionCore

final class GenericQuantityCoveragePolicyTests: XCTestCase {
    func testSupportedQuantityEntriesExcludeCoreAndLegacyAliases() {
        let entries = GenericQuantityCoveragePolicy.supportedQuantityEntries()
        let typeCodes = entries.map(\.typeCode)

        XCTAssertFalse(typeCodes.contains("steps"))
        XCTAssertFalse(typeCodes.contains("workout"))
        XCTAssertFalse(typeCodes.contains("sleep_analysis"))
        XCTAssertTrue(typeCodes.contains("heart_rate"))
        XCTAssertFalse(typeCodes.contains("body_mass"))
        XCTAssertFalse(typeCodes.contains("active_energy"))
        XCTAssertTrue(typeCodes.contains("weight"))
        XCTAssertTrue(typeCodes.contains("energy"))
        XCTAssertTrue(typeCodes.contains("sleeping_breathing_disturbances"))
        XCTAssertTrue(typeCodes.contains("workout_effort_score"))
        XCTAssertTrue(typeCodes.contains("estimated_workout_effort_score"))
        XCTAssertEqual(typeCodes, typeCodes.sorted())
    }

    func testActivityBasicsEntriesAreBackgroundEligible() {
        let entries = GenericQuantityCoveragePolicy.activityBasicsEntries()

        XCTAssertEqual(entries.map(\.typeCode), [
            "basal_energy",
            "distance_walking_running",
            "energy",
            "flights_climbed",
        ])
        XCTAssertTrue(entries.allSatisfy { $0.objectKind == .quantity })
        XCTAssertTrue(entries.allSatisfy { $0.usesDedicatedSyncLane == false })
        XCTAssertTrue(entries.allSatisfy(\.backgroundEligible))
        XCTAssertFalse(entries.contains { $0.sensitivity == .high })
    }

    func testCoveragePlanCanonicalizesAvailableTypesAndReportsUnsupportedCodes() {
        let plan = GenericQuantityCoveragePolicy.coveragePlan(
            availableTypeCodes: [
                "heart_rate",
                "steps",
                "sleep_analysis",
                "unknown_metric",
                "body_mass",
                "heart_rate",
            ]
        )

        XCTAssertEqual(
            plan.availableEntries.map(\.typeCode),
            ["heart_rate", "weight"]
        )
        XCTAssertEqual(
            plan.unsupportedTypeCodes,
            ["sleep_analysis", "steps", "unknown_metric"]
        )
        XCTAssertTrue(plan.requiresReadPermission)
        XCTAssertTrue(plan.containsHighSensitivityMetrics)
        XCTAssertTrue(plan.containsHighVolumeMetrics)
        XCTAssertEqual(plan.maximumForegroundWindowDays, 1)
    }

    func testCoveragePlanUsesLongerWindowForLowerVolumeTypes() {
        let plan = GenericQuantityCoveragePolicy.coveragePlan(
            availableTypeCodes: [
                "active_energy",
                "distance_walking_running",
            ]
        )

        XCTAssertEqual(plan.availableEntries.map(\.typeCode), [
            "distance_walking_running",
            "energy",
        ])
        XCTAssertFalse(plan.containsHighSensitivityMetrics)
        XCTAssertFalse(plan.containsHighVolumeMetrics)
        XCTAssertEqual(plan.maximumForegroundWindowDays, 7)
    }

    func testPermissionSummaryIsReadOnlyLocalFirstAndNonClinical() {
        let plan = GenericQuantityCoveragePolicy.coveragePlan(
            availableTypeCodes: ["oxygen_saturation", "body_mass"]
        )

        XCTAssertTrue(plan.permissionSummary.contains("read-only"))
        XCTAssertTrue(plan.permissionSummary.contains("local bridge"))
        XCTAssertFalse(
            plan.permissionSummary.localizedCaseInsensitiveContains("diagnosis")
        )
        XCTAssertFalse(
            plan.permissionSummary.localizedCaseInsensitiveContains("risk")
        )
        XCTAssertFalse(
            plan.permissionSummary.localizedCaseInsensitiveContains("advice")
        )
    }
}

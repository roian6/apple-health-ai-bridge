import XCTest
@testable import HealthBridgeCompanionCore

final class HealthKitTypeCatalogTests: XCTestCase {
    func testCatalogMarksDedicatedSyncLanesByImplementationStrategy() {
        XCTAssertEqual(
            HealthKitTypeCatalog.dedicatedSyncTypeCodes,
            ["steps", "workout", "sleep_analysis"]
        )
    }

    func testBroadQuantityCandidatesIncludeVitalsBodyAndActivityMetricsWithAggregationPolicies() throws {
        let heartRate = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "heart_rate"))
        XCTAssertEqual(heartRate.objectKind, .quantity)
        XCTAssertEqual(heartRate.healthKitIdentifier, "HKQuantityTypeIdentifierHeartRate")
        XCTAssertEqual(heartRate.canonicalUnit, "bpm")
        XCTAssertEqual(heartRate.aggregation, .minMaxAverage)
        XCTAssertFalse(heartRate.usesDedicatedSyncLane)
        XCTAssertTrue(heartRate.backgroundEligible)

        let weight = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "weight"))
        XCTAssertEqual(weight.healthKitIdentifier, "HKQuantityTypeIdentifierBodyMass")
        XCTAssertEqual(weight.canonicalUnit, "kg")
        XCTAssertEqual(weight.aggregation, .latest)
        XCTAssertEqual(weight.sensitivity, .high)
        XCTAssertFalse(weight.usesDedicatedSyncLane)
        XCTAssertTrue(weight.backgroundEligible)

        let bodyMass = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "body_mass"))
        XCTAssertEqual(bodyMass.healthKitIdentifier, "HKQuantityTypeIdentifierBodyMass")
        XCTAssertEqual(bodyMass.canonicalUnit, "kg")
        XCTAssertEqual(bodyMass.aggregation, .latest)
        XCTAssertEqual(bodyMass.sensitivity, .high)

        let oxygen = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "oxygen_saturation"))
        XCTAssertEqual(oxygen.canonicalUnit, "%")
        XCTAssertEqual(oxygen.aggregation, .minMaxAverage)
        XCTAssertEqual(oxygen.sensitivity, .high)

        let activeEnergy = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "active_energy"))
        XCTAssertEqual(activeEnergy.canonicalUnit, "kcal")
        XCTAssertEqual(activeEnergy.aggregation, .sum)
        XCTAssertEqual(activeEnergy.sensitivity, .moderate)
    }

    func testBodyProfileEntriesUseSupportedTimeseriesCodesInUnifiedCoverage() throws {
        let expected: [(String, String, String)] = [
            ("height", "HKQuantityTypeIdentifierHeight", "cm"),
            ("weight", "HKQuantityTypeIdentifierBodyMass", "kg"),
            ("body_mass_index", "HKQuantityTypeIdentifierBodyMassIndex", "kg/m²"),
            ("lean_body_mass", "HKQuantityTypeIdentifierLeanBodyMass", "kg"),
            ("waist_circumference", "HKQuantityTypeIdentifierWaistCircumference", "cm"),
        ]

        for (typeCode, identifier, unit) in expected {
            let entry = try XCTUnwrap(HealthKitTypeCatalog.entry(for: typeCode))
            XCTAssertEqual(entry.healthKitIdentifier, identifier)
            XCTAssertEqual(entry.objectKind, .quantity)
            XCTAssertEqual(entry.canonicalUnit, unit)
            XCTAssertEqual(entry.aggregation, .latest)
            XCTAssertEqual(entry.sensitivity, .high)
            XCTAssertFalse(entry.usesDedicatedSyncLane)
            XCTAssertTrue(entry.backgroundEligible)
            XCTAssertEqual(HealthKitTypeCatalog.healthType(from: entry).category, .body)
        }
    }

    func testSupportedSensitiveQuantitiesParticipateInAutomaticSync() throws {
        let hrv = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "heart_rate_variability_sdnn"))
        XCTAssertEqual(hrv.sensitivity, .high)
        XCTAssertFalse(hrv.usesDedicatedSyncLane)
        XCTAssertTrue(hrv.backgroundEligible)

        let vo2Max = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "vo2_max"))
        XCTAssertEqual(vo2Max.sensitivity, .high)
        XCTAssertFalse(vo2Max.usesDedicatedSyncLane)
        XCTAssertTrue(vo2Max.backgroundEligible)
    }

    func testDedicatedSyncTypesMatchDedicatedCatalogEntries() {
        XCTAssertEqual(
            HealthBridgeHealthType.dedicatedSyncTypes.map(\.typeCode),
            HealthKitTypeCatalog.dedicatedSyncTypeCodes
        )
    }

    func testDirectSupportedTimeseriesQuantityExpansionEntriesAreAutomaticCapable() throws {
        let expected: Set<String> = [
            "heart_rate_recovery_one_minute",
            "walking_heart_rate_average",
            "blood_alcohol_content",
            "blood_glucose",
            "blood_pressure_systolic",
            "blood_pressure_diastolic",
            "sleeping_breathing_disturbances",
            "peripheral_perfusion_index",
            "forced_vital_capacity",
            "forced_expiratory_volume_1",
            "peak_expiratory_flow_rate",
            "body_temperature",
            "skin_temperature",
            "six_minute_walk_test_distance",
            "stand_time",
            "exercise_time",
            "physical_effort",
            "distance_cycling",
            "distance_swimming",
            "distance_downhill_snow_sports",
            "walking_step_length",
            "walking_speed",
            "walking_double_support_percentage",
            "walking_asymmetry_percentage",
            "walking_steadiness",
            "stair_descent_speed",
            "stair_ascent_speed",
            "running_power",
            "running_speed",
            "running_vertical_oscillation",
            "running_ground_contact_time",
            "running_stride_length",
            "swimming_stroke_count",
            "underwater_depth",
            "workout_effort_score",
            "estimated_workout_effort_score",
            "environmental_audio_exposure",
            "headphone_audio_exposure",
            "uv_exposure",
            "inhaler_usage",
            "electrodermal_activity",
            "push_count",
            "atrial_fibrillation_burden",
            "insulin_delivery",
            "number_of_times_fallen",
            "number_of_alcoholic_beverages",
            "nike_fuel",
            "hydration",
        ]

        for typeCode in expected {
            let entry = try XCTUnwrap(HealthKitTypeCatalog.entry(for: typeCode), typeCode)
            XCTAssertEqual(entry.objectKind, .quantity, typeCode)
            XCTAssertFalse(entry.usesDedicatedSyncLane, typeCode)
            XCTAssertTrue(entry.backgroundEligible, typeCode)
            XCTAssertFalse(entry.healthKitIdentifier.isEmpty, typeCode)
        }

        let canonicalEnergy = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "energy"))
        XCTAssertFalse(canonicalEnergy.usesDedicatedSyncLane)
        XCTAssertTrue(canonicalEnergy.backgroundEligible)

        XCTAssertTrue(
            GenericQuantityCoveragePolicy.supportedQuantityEntries().allSatisfy(\.backgroundEligible)
        )

        let bloodAlcohol = try XCTUnwrap(
            HealthKitTypeCatalog.entry(for: "blood_alcohol_content")
        )
        XCTAssertEqual(
            bloodAlcohol.healthKitIdentifier,
            "HKQuantityTypeIdentifierBloodAlcoholContent"
        )
        XCTAssertEqual(bloodAlcohol.canonicalUnit, "%")
    }

    func testCatalogEntryEncodesStableSnakeCaseMetadata() throws {
        let heartRate = try XCTUnwrap(HealthKitTypeCatalog.entry(for: "heart_rate"))
        let data = try JSONEncoder().encode(heartRate)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type_code"] as? String, "heart_rate")
        XCTAssertEqual(object["display_name"] as? String, "Heart Rate")
        XCTAssertEqual(object["healthkit_identifier"] as? String, "HKQuantityTypeIdentifierHeartRate")
        XCTAssertEqual(object["object_kind"] as? String, "quantity")
        XCTAssertEqual(object["canonical_unit"] as? String, "bpm")
        XCTAssertEqual(object["aggregation"] as? String, "min_max_average")
        XCTAssertEqual(object["uses_dedicated_sync_lane"] as? Bool, false)
        XCTAssertEqual(object["background_eligible"] as? Bool, true)
        XCTAssertNil(object["typeCode"])
        XCTAssertNil(object["healthKitIdentifier"])
        XCTAssertNil(object["default_enabled"])
    }

    func testPublicReviewDisclosureMatchesEveryRequestedHealthKitType() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryRoot.deleteLastPathComponent()
        }
        let disclosureURL = repositoryRoot
            .appendingPathComponent("docs")
            .appendingPathComponent("supported-health-data.md")
        let disclosure = try String(contentsOf: disclosureURL, encoding: .utf8)
        let disclosedTypeCodes = disclosure
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("- `"),
                      let closingBacktick = line.dropFirst(3).firstIndex(of: "`")
                else {
                    return nil
                }
                return String(line[line.index(line.startIndex, offsetBy: 3)..<closingBacktick])
            }
            .sorted()
        let requestedTypeCodes = Array(Set(
            HealthBridgeHealthType.dedicatedSyncTypes.map(\.typeCode)
                + GenericQuantityCoveragePolicy.supportedQuantityEntries().map(\.typeCode)
        )).sorted()

        XCTAssertEqual(disclosedTypeCodes, requestedTypeCodes)
    }
}

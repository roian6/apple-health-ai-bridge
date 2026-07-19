import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class HealthTypeRegistryTests: XCTestCase {
    func testCanonicalTypesContainStaticRegistryEntries() {
        let catalog = HealthBridgeHealthType.canonicalTypes

        XCTAssertTrue(catalog.contains(.steps))
        XCTAssertTrue(catalog.contains(.heartRate))
        XCTAssertTrue(catalog.contains(.weight))
        XCTAssertFalse(catalog.contains { $0.typeCode == "body_mass" })
        XCTAssertTrue(catalog.contains(.sleepAnalysis))
        XCTAssertEqual(HealthBridgeHealthType.steps.category, .activity)
        XCTAssertEqual(HealthBridgeHealthType.steps.defaultUnit, "count")
        XCTAssertEqual(HealthBridgeHealthType.heartRate.defaultUnit, "bpm")
        XCTAssertEqual(HealthBridgeHealthType.weight.sensitivity, .high)
        XCTAssertEqual(HealthBridgeHealthType.weight.aliases, [
            "HKQuantityTypeIdentifierBodyMass",
            "body_mass",
        ])
    }

    func testDedicatedSyncTypesRepresentStructurallyDistinctLanes() {
        XCTAssertEqual(
            HealthBridgeHealthType.dedicatedSyncTypes.map(\.typeCode),
            ["steps", "workout", "sleep_analysis"]
        )
    }

    func testCatalogCanResolveHealthKitAliases() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthBridgeHealthType.resolve(alias: "HKQuantityTypeIdentifierStepCount")),
            .steps
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthBridgeHealthType.resolve(alias: "HKCategoryTypeIdentifierSleepAnalysis")),
            .sleepAnalysis
        )
        XCTAssertNil(HealthBridgeHealthType.resolve(alias: "HKQuantityTypeIdentifierFlightsClimbed"))
    }

    func testConnectionTestBatchEmitsCanonicalWeightTypeOnly() {
        let batch = ConnectionTestBatchFactory.make(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let typeCodes = batch.healthTypes.map(\.typeCode)

        XCTAssertTrue(typeCodes.contains("weight"))
        XCTAssertFalse(typeCodes.contains("body_mass"))
    }
}

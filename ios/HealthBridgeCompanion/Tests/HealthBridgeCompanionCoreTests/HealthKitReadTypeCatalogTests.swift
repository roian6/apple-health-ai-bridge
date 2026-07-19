import XCTest
@testable import HealthBridgeCompanionCore

#if canImport(HealthKit)
import HealthKit

final class HealthKitReadTypeCatalogTests: XCTestCase {
    func testSampleTypesForTypeCodesMapsBroadCatalogEntries() throws {
        let sampleTypes = HealthKitReadTypeCatalog.sampleTypes(forTypeCodes: [
            "sleep_analysis",
            "heart_rate_variability_sdnn",
            "active_energy",
            "workout",
            "unknown_metric",
            "active_energy",
        ])
        let identifiers = Set(sampleTypes.map(\.identifier))

        XCTAssertEqual(identifiers, Set([
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!.identifier,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!.identifier,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!.identifier,
            HKObjectType.workoutType().identifier,
        ]))
    }

    func testObjectTypesForTypeCodesRejectsUnknownEntries() {
        let objectTypes = HealthKitReadTypeCatalog.objectTypes(forTypeCodes: [
            "unknown_metric",
            "heart_rate",
        ])

        XCTAssertEqual(objectTypes.map(\.identifier), [
            HKObjectType.quantityType(forIdentifier: .heartRate)!.identifier,
        ])
    }

    func testAvailableTypeCodesFiltersRuntimeUnavailableEntries() {
        let typeCodes = HealthKitReadTypeCatalog.availableTypeCodes(forTypeCodes: [
            "unknown_metric",
            "heart_rate",
            "blood_alcohol_content",
        ])

        XCTAssertTrue(typeCodes.contains("heart_rate"))
        XCTAssertTrue(typeCodes.contains("blood_alcohol_content"))
        XCTAssertFalse(typeCodes.contains("unknown_metric"))
    }
}
#endif

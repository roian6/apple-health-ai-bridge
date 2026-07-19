import XCTest
@testable import HealthBridgeCompanionCore

#if canImport(HealthKit)
import HealthKit

final class HealthKitGenericQuantityReaderTests: XCTestCase {
    func testMapperConvertsKnownQuantitySamplesToCanonicalUnits() throws {
        let start = try date("2026-06-15T07:00:00Z")
        let end = try date("2026-06-15T07:00:05Z")
        let heartRate = quantitySample(
            typeIdentifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            value: 68,
            start: start,
            end: end
        )
        let heartRateEntry = try catalogEntry("heart_rate")

        let heartRateSummary = try XCTUnwrap(
            HealthKitQuantitySampleMapper.summary(for: heartRate, entry: heartRateEntry)
        )

        XCTAssertEqual(heartRateSummary.uuid, heartRate.uuid)
        XCTAssertEqual(heartRateSummary.typeCode, "heart_rate")
        XCTAssertEqual(heartRateSummary.start, start)
        XCTAssertEqual(heartRateSummary.end, end)
        XCTAssertEqual(heartRateSummary.value, 68)

        let bodyMass = quantitySample(
            typeIdentifier: .bodyMass,
            unit: HKUnit.gramUnit(with: .kilo),
            value: 72.4,
            start: start,
            end: start
        )
        let weightSummary = try XCTUnwrap(
            HealthKitQuantitySampleMapper.summary(for: bodyMass, entry: try catalogEntry("weight"))
        )
        XCTAssertEqual(weightSummary.typeCode, "weight")
        XCTAssertEqual(weightSummary.value, 72.4, accuracy: 0.000_001)

        let bodyMassSummary = try XCTUnwrap(
            HealthKitQuantitySampleMapper.summary(for: bodyMass, entry: try catalogEntry("body_mass"))
        )
        XCTAssertEqual(bodyMassSummary.typeCode, "body_mass")
        XCTAssertEqual(bodyMassSummary.value, 72.4, accuracy: 0.000_001)

        let activeEnergy = quantitySample(
            typeIdentifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            value: 125.5,
            start: start,
            end: end
        )
        let energySummary = try XCTUnwrap(
            HealthKitQuantitySampleMapper.summary(for: activeEnergy, entry: try catalogEntry("active_energy"))
        )
        XCTAssertEqual(energySummary.typeCode, "active_energy")
        XCTAssertEqual(energySummary.value, 125.5, accuracy: 0.000_001)
    }

    func testMapperConvertsBodyProfileSamplesToCanonicalUnits() throws {
        let start = try date("2026-06-15T07:00:00Z")
        let examples: [(String, HKQuantityTypeIdentifier, HKUnit, Double, Double)] = [
            ("height", .height, HKUnit.meterUnit(with: .centi), 173.2, 173.2),
            ("body_mass_index", .bodyMassIndex, HKUnit.count(), 23.4, 23.4),
            ("lean_body_mass", .leanBodyMass, HKUnit.gramUnit(with: .kilo), 54.1, 54.1),
            ("waist_circumference", .waistCircumference, HKUnit.meterUnit(with: .centi), 82.0, 82.0),
        ]

        for (typeCode, identifier, unit, value, expectedValue) in examples {
            let sample = quantitySample(
                typeIdentifier: identifier,
                unit: unit,
                value: value,
                start: start,
                end: start
            )
            let summary = try XCTUnwrap(
                HealthKitQuantitySampleMapper.summary(for: sample, entry: try catalogEntry(typeCode))
            )

            XCTAssertEqual(summary.typeCode, typeCode)
            XCTAssertEqual(summary.value, expectedValue, accuracy: 0.000_001)
        }
    }

    func testMapperScalesFractionalHealthKitPercentQuantitiesToCanonicalPercentUnit() throws {
        let start = try date("2026-06-15T07:00:00Z")
        let oxygen = quantitySample(
            typeIdentifier: .oxygenSaturation,
            unit: .percent(),
            value: 0.97,
            start: start,
            end: start.addingTimeInterval(5)
        )
        let steadiness = quantitySample(
            typeIdentifier: .appleWalkingSteadiness,
            unit: .percent(),
            value: 82.5,
            start: start,
            end: start.addingTimeInterval(5)
        )
        let signedPercent = quantitySample(
            typeIdentifier: .appleWalkingSteadiness,
            unit: .percent(),
            value: -0.5,
            start: start,
            end: start.addingTimeInterval(5)
        )
        let bloodAlcohol = quantitySample(
            typeIdentifier: .bloodAlcoholContent,
            unit: .percent(),
            value: 0.000_8,
            start: start,
            end: start.addingTimeInterval(5)
        )

        let oxygenSummary = try XCTUnwrap(
            HealthKitQuantitySampleMapper.summary(
                for: oxygen,
                entry: try catalogEntry("oxygen_saturation")
            )
        )
        let steadinessSummary = try XCTUnwrap(
            HealthKitQuantitySampleMapper.summary(
                for: steadiness,
                entry: try catalogEntry("walking_steadiness")
            )
        )
        let signedPercentSummary = try XCTUnwrap(
            HealthKitQuantitySampleMapper.summary(
                for: signedPercent,
                entry: try catalogEntry("walking_steadiness")
            )
        )
        let bloodAlcoholSummary = try XCTUnwrap(
            HealthKitQuantitySampleMapper.summary(
                for: bloodAlcohol,
                entry: try catalogEntry("blood_alcohol_content")
            )
        )

        XCTAssertEqual(oxygenSummary.typeCode, "oxygen_saturation")
        XCTAssertEqual(oxygenSummary.value, 97.0, accuracy: 0.000_001)
        XCTAssertEqual(steadinessSummary.typeCode, "walking_steadiness")
        XCTAssertEqual(steadinessSummary.value, 82.5, accuracy: 0.000_001)
        XCTAssertEqual(signedPercentSummary.typeCode, "walking_steadiness")
        XCTAssertEqual(signedPercentSummary.value, -0.5, accuracy: 0.000_001)
        XCTAssertEqual(bloodAlcoholSummary.typeCode, "blood_alcohol_content")
        XCTAssertEqual(bloodAlcoholSummary.value, 0.08, accuracy: 0.000_001)
    }

    func testMapperRejectsMismatchedOrNonQuantityCatalogEntries() throws {
        let start = try date("2026-06-15T07:00:00Z")
        let heartRate = quantitySample(
            typeIdentifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            value: 68,
            start: start,
            end: start.addingTimeInterval(5)
        )

        XCTAssertNil(HealthKitQuantitySampleMapper.summary(
            for: heartRate,
            entry: try catalogEntry("body_mass")
        ))
        XCTAssertNil(HealthKitQuantitySampleMapper.summary(
            for: heartRate,
            entry: try catalogEntry("sleep_analysis")
        ))
    }

    func testReaderFiltersReadableQuantityEntriesDeterministically() {
        let entries = HealthKitGenericQuantityReader.readableQuantityEntries(
            for: ["sleep_analysis", "heart_rate", "unknown", "body_mass", "weight", "heart_rate"]
        )

        XCTAssertEqual(entries.map(\.typeCode), ["heart_rate", "weight"])
    }

    func testEveryAutomaticQuantityResolvesAHealthKitTypeAndCanonicalUnit() {
        for entry in GenericQuantityCoveragePolicy.supportedQuantityEntries() {
            XCTAssertNotNil(
                HealthKitQuantitySampleMapper.quantityType(for: entry),
                entry.typeCode
            )
            XCTAssertNotNil(
                HealthKitQuantitySampleMapper.unit(for: entry),
                entry.typeCode
            )
        }
    }

    func testRedactedQuantityProbeCanonicalizesLegacyBodyMassWithoutValues() throws {
        let first = try date("2021-11-10T09:50:04Z")
        let latest = try date("2026-05-01T11:49:35Z")
        let samples = [
            quantitySample(
                typeIdentifier: .bodyMass,
                unit: HKUnit.gramUnit(with: .kilo),
                value: 70.0,
                start: first,
                end: first
            ),
            quantitySample(
                typeIdentifier: .bodyMass,
                unit: HKUnit.gramUnit(with: .kilo),
                value: 71.0,
                start: latest,
                end: latest
            ),
        ]

        let result = try XCTUnwrap(HealthKitQuantityRedactedProbe.result(
            typeCode: "body_mass",
            samples: samples
        ))

        XCTAssertEqual(result.typeCode, "weight")
        XCTAssertEqual(result.sampleCount, 2)
        XCTAssertEqual(result.earliestSampleStart, first)
        XCTAssertEqual(result.latestSampleEnd, latest)
        XCTAssertGreaterThanOrEqual(result.distinctSourceCount, 1)
        XCTAssertFalse(result.summary.contains("70"))
        XCTAssertFalse(result.summary.contains("71"))
        XCTAssertTrue(result.summary.contains("2 sample(s)"))
        XCTAssertTrue(result.summary.contains("No sample values were read or exported."))
    }

    func testRedactedQuantityProbeRejectsMismatchedSamples() throws {
        let start = try date("2026-06-15T07:00:00Z")
        let heartRate = quantitySample(
            typeIdentifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            value: 68,
            start: start,
            end: start.addingTimeInterval(5)
        )

        XCTAssertNil(HealthKitQuantityRedactedProbe.result(
            typeCode: "weight",
            samples: [heartRate]
        ))
    }

    func testReaderRejectsInvalidWindowBeforeTouchingHealthStore() async throws {
        let reader = HealthKitGenericQuantityReader()
        let start = try date("2026-06-15T07:00:00Z")

        await XCTAssertThrowsErrorAsync(
            try await reader.readQuantitySamples(
                typeCodes: ["heart_rate"],
                start: start,
                end: start
            )
        ) { error in
            XCTAssertEqual(error as? HealthKitGenericQuantityReaderError, .invalidWindow)
        }
    }

    func testReaderRejectsEmptyReadableSelectionBeforeTouchingHealthStore() async throws {
        let reader = HealthKitGenericQuantityReader()

        await XCTAssertThrowsErrorAsync(
            try await reader.readQuantitySamples(
                typeCodes: ["sleep_analysis", "workout", "unknown"],
                start: try date("2026-06-15T00:00:00Z"),
                end: try date("2026-06-16T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? HealthKitGenericQuantityReaderError, .emptyReadableTypeSet)
        }
    }

    private func catalogEntry(_ typeCode: String) throws -> HealthKitTypeCatalogEntry {
        try XCTUnwrap(HealthKitTypeCatalog.entry(for: typeCode))
    }

    private func quantitySample(
        typeIdentifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        value: Double,
        start: Date,
        end: Date
    ) -> HKQuantitySample {
        let type = HKQuantityType.quantityType(forIdentifier: typeIdentifier)!
        return HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: start,
            end: end
        )
    }

    private func date(_ string: String) throws -> Date {
        try XCTUnwrap(HealthBridgeUTCFormatter.date(from: string))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
#endif

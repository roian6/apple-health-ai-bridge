#if canImport(HealthKit)
import Foundation
import HealthKit

extension HealthKitSampleProvenance {
    init(sample: HKSample) {
        let source = sample.sourceRevision.source
        let device = sample.device
        self.init(
            sourceName: source.name,
            sourceBundleIdentifier: source.bundleIdentifier,
            deviceName: device?.name,
            deviceModel: device?.model,
            deviceManufacturer: device?.manufacturer
        )
    }
}

public struct HealthKitQuantityRedactedProbeResult: Equatable, Sendable {
    public let typeCode: String
    public let sampleCount: Int
    public let earliestSampleStart: Date
    public let latestSampleEnd: Date
    public let distinctSourceCount: Int

    public init(
        typeCode: String,
        sampleCount: Int,
        earliestSampleStart: Date,
        latestSampleEnd: Date,
        distinctSourceCount: Int
    ) {
        self.typeCode = typeCode
        self.sampleCount = sampleCount
        self.earliestSampleStart = earliestSampleStart
        self.latestSampleEnd = latestSampleEnd
        self.distinctSourceCount = distinctSourceCount
    }

    public var summary: String {
        let first = HealthBridgeUTCFormatter.string(from: earliestSampleStart)
        let latest = HealthBridgeUTCFormatter.string(from: latestSampleEnd)
        return "HealthKit \(typeCode) probe found \(sampleCount) sample(s) from \(distinctSourceCount) source(s), first \(first), latest \(latest). No sample values were read or exported."
    }
}

public enum HealthKitQuantityRedactedProbe {
    public static func result(
        typeCode rawTypeCode: String,
        samples: [HKQuantitySample]
    ) -> HealthKitQuantityRedactedProbeResult? {
        let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: rawTypeCode)
        guard let entry = HealthKitTypeCatalog.entry(for: canonicalTypeCode),
              let expectedType = HealthKitQuantitySampleMapper.quantityType(for: entry)
        else {
            return nil
        }
        let matchingSamples = samples.filter { sample in
            sample.quantityType.identifier == expectedType.identifier
                && sample.startDate <= sample.endDate
        }
        guard !matchingSamples.isEmpty else { return nil }
        let sourceKeys = Set(matchingSamples.map(sourceKey(for:)))
        return HealthKitQuantityRedactedProbeResult(
            typeCode: canonicalTypeCode,
            sampleCount: matchingSamples.count,
            earliestSampleStart: matchingSamples.map(\.startDate).min() ?? matchingSamples[0].startDate,
            latestSampleEnd: matchingSamples.map(\.endDate).max() ?? matchingSamples[0].endDate,
            distinctSourceCount: sourceKeys.count
        )
    }

    private static func sourceKey(for sample: HKQuantitySample) -> String {
        let source = sample.sourceRevision.source
        return source.bundleIdentifier.isEmpty ? source.name : source.bundleIdentifier
    }
}

public enum HealthKitGenericQuantityReaderError: Error, Equatable {
    case healthDataUnavailable
    case invalidWindow
    case emptyReadableTypeSet
    case anchorUnavailable
}

public enum HealthKitQuantitySampleMapper {
    public static func summary(
        for sample: HKQuantitySample,
        entry: HealthKitTypeCatalogEntry
    ) -> HealthKitQuantitySampleSummary? {
        guard entry.objectKind == .quantity,
              let expectedType = quantityType(for: entry),
              sample.quantityType.identifier == expectedType.identifier,
              let unit = unit(for: entry),
              sample.startDate <= sample.endDate
        else {
            return nil
        }
        let rawValue = sample.quantity.doubleValue(for: unit)
        return HealthKitQuantitySampleSummary(
            uuid: sample.uuid,
            typeCode: entry.typeCode,
            start: sample.startDate,
            end: sample.endDate,
            value: canonicalValue(rawValue, for: entry),
            provenance: HealthKitSampleProvenance(sample: sample)
        )
    }

    public static func quantityType(for entry: HealthKitTypeCatalogEntry) -> HKQuantityType? {
        guard entry.objectKind == .quantity else {
            return nil
        }
        let identifier = HKQuantityTypeIdentifier(rawValue: entry.healthKitIdentifier)
        return HKQuantityType.quantityType(forIdentifier: identifier)
    }

    public static func unit(for entry: HealthKitTypeCatalogEntry) -> HKUnit? {
        switch entry.canonicalUnit {
        case "count", "score":
            return .count()
        case "count/min", "bpm", "brpm":
            return HKUnit.count().unitDivided(by: .minute())
        case "ms":
            return HKUnit.secondUnit(with: .milli)
        case "%":
            return .percent()
        case "cm":
            return HKUnit.meterUnit(with: .centi)
        case "kg":
            return HKUnit.gramUnit(with: .kilo)
        case "kg/m²":
            return .count()
        case "kcal":
            return .kilocalorie()
        case "m", "meters":
            return .meter()
        case "mL/kg/min":
            return HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo))
                .unitDivided(by: .minute())
        case "mg/dL":
            return HKUnit.gramUnit(with: .milli)
                .unitDivided(by: HKUnit.literUnit(with: .deci))
        case "mmHg":
            return .millimeterOfMercury()
        case "liters":
            return .liter()
        case "L/min":
            return HKUnit.liter().unitDivided(by: .minute())
        case "°C":
            return .degreeCelsius()
        case "minutes":
            return .minute()
        case "m/s":
            return HKUnit.meter().unitDivided(by: .second())
        case "watts":
            return .watt()
        case "dB", "dBASPL":
            return .decibelAWeightedSoundPressureLevel()
        case "mL":
            return .literUnit(with: .milli)
        case "IU":
            return .internationalUnit()
        case "S":
            return .siemen()
        case "apple_effort_score":
            if #available(iOS 18.0, macOS 15.0, *) {
                return .appleEffortScore()
            }
            return nil
        case "kcal/kg/hr":
            return HKUnit.kilocalorie()
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
        default:
            return nil
        }
    }

    public static func canonicalValue(
        _ rawValue: Double,
        for entry: HealthKitTypeCatalogEntry
    ) -> Double {
        switch entry.canonicalUnit {
        case "%":
            return rawValue >= 0 && rawValue <= 1 ? rawValue * 100 : rawValue
        default:
            return rawValue
        }
    }
}

public final class HealthKitGenericQuantityReader: @unchecked Sendable {
    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public static func readableQuantityEntries(
        for typeCodes: [String]
    ) -> [HealthKitTypeCatalogEntry] {
        GenericQuantityCoveragePolicy.canonicalTypeCodes(for: typeCodes)
            .compactMap { HealthKitTypeCatalog.entry(for: $0) }
            .filter { entry in
                entry.objectKind == .quantity
                    && HealthKitQuantitySampleMapper.quantityType(for: entry) != nil
                    && HealthKitQuantitySampleMapper.unit(for: entry) != nil
            }
            .sorted { $0.typeCode < $1.typeCode }
    }

    public func readQuantitySamples(
        typeCodes: [String],
        start: Date?,
        end: Date
    ) async throws -> [HealthKitQuantitySampleSummary] {
        if let start, start >= end {
            throw HealthKitGenericQuantityReaderError.invalidWindow
        }
        let entries = Self.readableQuantityEntries(for: typeCodes)
        guard !entries.isEmpty else {
            throw HealthKitGenericQuantityReaderError.emptyReadableTypeSet
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitGenericQuantityReaderError.healthDataUnavailable
        }

        var summaries: [HealthKitQuantitySampleSummary] = []
        for entry in entries {
            summaries.append(contentsOf: try await readQuantitySamples(
                entry: entry,
                start: start,
                end: end
            ))
        }
        return summaries.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.typeCode != rhs.typeCode { return lhs.typeCode < rhs.typeCode }
            return lhs.uuid.uuidString < rhs.uuid.uuidString
        }
    }

    public func readAnchoredQuantityChanges(
        typeCode: String,
        anchorCursorValue: String?,
        predicateStart: Date?,
        receivedAt: Date = Date()
    ) async throws -> HealthKitAnchoredQuantityChanges {
        guard let entry = Self.readableQuantityEntries(for: [typeCode]).first,
              let quantityType = HealthKitQuantitySampleMapper.quantityType(for: entry)
        else {
            throw HealthKitGenericQuantityReaderError.emptyReadableTypeSet
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitGenericQuantityReaderError.healthDataUnavailable
        }
        let anchor = try HealthKitAnchorCursorCodec.decodeOptional(anchorCursorValue)
        let predicate = predicateStart.map {
            HKQuery.predicateForSamples(withStart: $0, end: nil, options: [.strictStartDate])
        }

        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKAnchoredObjectQuery(
                type: quantityType,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let newAnchor else {
                    completion(.failure(HealthKitGenericQuantityReaderError.anchorUnavailable))
                    return
                }

                do {
                    let cursorValue = try HealthKitAnchorCursorCodec.encode(newAnchor)
                    let summaries = ((samples as? [HKQuantitySample]) ?? [])
                        .compactMap { HealthKitQuantitySampleMapper.summary(for: $0, entry: entry) }
                    let deletedSamples = (deletedObjects ?? []).map {
                        HealthKitDeletedQuantitySample(
                            uuid: $0.uuid,
                            typeCode: entry.typeCode,
                            deletedAt: receivedAt
                        )
                    }
                    let candidates = summaries.map(\.start)
                        + deletedSamples.map(\.deletedAt)
                        + [predicateStart ?? receivedAt]
                    completion(.success(HealthKitAnchoredQuantityChanges(
                        typeCode: entry.typeCode,
                        samples: summaries,
                        deletedSamples: deletedSamples,
                        anchorCursorValue: cursorValue,
                        windowStart: candidates.min() ?? receivedAt,
                        windowEnd: receivedAt
                    )))
                } catch {
                    completion(.failure(error))
                }
            }
            return query
        }
    }

    public func readRedactedQuantityProbe(
        typeCode: String,
        start: Date?,
        end: Date
    ) async throws -> HealthKitQuantityRedactedProbeResult? {
        if let start, start >= end {
            throw HealthKitGenericQuantityReaderError.invalidWindow
        }
        let entries = Self.readableQuantityEntries(for: [typeCode])
        guard let entry = entries.first else {
            throw HealthKitGenericQuantityReaderError.emptyReadableTypeSet
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitGenericQuantityReaderError.healthDataUnavailable
        }
        let samples = try await readRawQuantitySamples(entry: entry, start: start, end: end)
        return HealthKitQuantityRedactedProbe.result(typeCode: entry.typeCode, samples: samples)
    }

    public func readDailyActivityAggregates(
        typeCodes: [String] = DailyActivityAggregateSyncPolicy.defaultTypeCodes,
        start: Date,
        end: Date,
        calendar: Calendar
    ) async throws -> [HealthKitDailyActivityAggregate] {
        guard start < end else {
            throw HealthKitGenericQuantityReaderError.invalidWindow
        }
        let entries = Self.readableQuantityEntries(for: typeCodes)
            .filter { $0.aggregation == .sum }
        guard !entries.isEmpty else {
            throw HealthKitGenericQuantityReaderError.emptyReadableTypeSet
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitGenericQuantityReaderError.healthDataUnavailable
        }

        var aggregates: [HealthKitDailyActivityAggregate] = []
        for entry in entries {
            aggregates.append(contentsOf: try await readDailyActivityAggregates(
                entry: entry,
                start: start,
                end: end,
                calendar: calendar
            ))
        }
        return aggregates.sorted { lhs, rhs in
            if lhs.dayStart != rhs.dayStart { return lhs.dayStart < rhs.dayStart }
            return lhs.typeCode < rhs.typeCode
        }
    }

    private func readDailyActivityAggregates(
        entry: HealthKitTypeCatalogEntry,
        start: Date,
        end: Date,
        calendar: Calendar
    ) async throws -> [HealthKitDailyActivityAggregate] {
        guard let quantityType = HealthKitQuantitySampleMapper.quantityType(for: entry),
              let unit = HealthKitQuantitySampleMapper.unit(for: entry)
        else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let interval = DateComponents(day: 1)
        let anchorDate = calendar.startOfDay(for: start)
        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, results, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let results else {
                    completion(.success([]))
                    return
                }
                var aggregates: [HealthKitDailyActivityAggregate] = []
                results.enumerateStatistics(from: start, to: end) { statistics, _ in
                    guard let sumQuantity = statistics.sumQuantity() else { return }
                    let rawValue = sumQuantity.doubleValue(for: unit)
                    let value = HealthKitQuantitySampleMapper.canonicalValue(rawValue, for: entry)
                    guard value.isFinite, value > 0 else { return }
                    let calendarDay = Self.calendarDayString(for: statistics.startDate, calendar: calendar)
                    aggregates.append(HealthKitDailyActivityAggregate(
                        typeCode: entry.typeCode,
                        dayStart: statistics.startDate,
                        dayEnd: min(statistics.endDate, end),
                        value: value,
                        calendarDay: calendarDay,
                        timeZoneIdentifier: calendar.timeZone.identifier
                    ))
                }
                completion(.success(aggregates))
            }
            return query
        }
    }

    private static func calendarDayString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func readQuantitySamples(
        entry: HealthKitTypeCatalogEntry,
        start: Date?,
        end: Date
    ) async throws -> [HealthKitQuantitySampleSummary] {
        let samples = try await readRawQuantitySamples(entry: entry, start: start, end: end)
        return samples.compactMap { HealthKitQuantitySampleMapper.summary(for: $0, entry: entry) }
    }

    private func readRawQuantitySamples(
        entry: HealthKitTypeCatalogEntry,
        start: Date?,
        end: Date
    ) async throws -> [HKQuantitySample] {
        guard let quantityType = HealthKitQuantitySampleMapper.quantityType(for: entry) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictStartDate]
        )
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )
        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                completion(.success((samples as? [HKQuantitySample]) ?? []))
            }
            return query
        }
    }
}
#endif

import Foundation

public struct HealthKitSampleProvenance: Equatable, Sendable {
    public let sourceName: String?
    public let sourceBundleIdentifier: String?
    public let deviceName: String?
    public let deviceModel: String?
    public let deviceManufacturer: String?

    public init(
        sourceName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        deviceManufacturer: String? = nil
    ) {
        self.sourceName = sourceName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.deviceManufacturer = deviceManufacturer
    }

    public var metadata: [String: String] {
        var values: [String: String] = [:]
        if let sourceName, !sourceName.isEmpty {
            values["healthkit_source_name"] = sourceName
        }
        if let sourceBundleIdentifier, !sourceBundleIdentifier.isEmpty {
            values["healthkit_source_bundle_id"] = sourceBundleIdentifier
        }
        if let deviceName, !deviceName.isEmpty {
            values["healthkit_device_name"] = deviceName
        }
        if let deviceModel, !deviceModel.isEmpty {
            values["healthkit_device_model"] = deviceModel
        }
        if let deviceManufacturer, !deviceManufacturer.isEmpty {
            values["healthkit_device_manufacturer"] = deviceManufacturer
        }
        return values
    }
}

public struct HealthKitQuantitySampleSummary: Equatable, Sendable {
    public let uuid: UUID
    public let typeCode: String
    public let start: Date
    public let end: Date
    public let value: Double
    public let provenance: HealthKitSampleProvenance?

    public init(
        uuid: UUID,
        typeCode: String,
        start: Date,
        end: Date,
        value: Double,
        provenance: HealthKitSampleProvenance? = nil
    ) {
        self.uuid = uuid
        self.typeCode = typeCode
        self.start = start
        self.end = end
        self.value = value
        self.provenance = provenance
    }
}

public struct HealthKitDeletedQuantitySample: Equatable, Sendable {
    public let uuid: UUID
    public let typeCode: String
    public let deletedAt: Date

    public init(uuid: UUID, typeCode: String, deletedAt: Date) {
        self.uuid = uuid
        self.typeCode = typeCode
        self.deletedAt = deletedAt
    }
}

public struct HealthKitAnchoredQuantityChanges: Equatable, Sendable {
    public let typeCode: String
    public let samples: [HealthKitQuantitySampleSummary]
    public let deletedSamples: [HealthKitDeletedQuantitySample]
    public let anchorCursorValue: String
    public let windowStart: Date
    public let windowEnd: Date

    public init(
        typeCode: String,
        samples: [HealthKitQuantitySampleSummary],
        deletedSamples: [HealthKitDeletedQuantitySample],
        anchorCursorValue: String,
        windowStart: Date,
        windowEnd: Date
    ) {
        self.typeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: typeCode)
        self.samples = samples
        self.deletedSamples = deletedSamples
        self.anchorCursorValue = anchorCursorValue
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

public struct GenericQuantityAnchoredQueryPlan: Equatable, Sendable {
    public let canonicalTypeCode: String
    public let anchorCursorKind: String
    public let predicateStart: Date?

    public init(canonicalTypeCode: String, anchorCursorKind: String, predicateStart: Date?) {
        self.canonicalTypeCode = canonicalTypeCode
        self.anchorCursorKind = anchorCursorKind
        self.predicateStart = predicateStart
    }
}

public enum GenericQuantityAnchoredDeliveryDisposition: Equatable, Sendable {
    case uploaded
    case durablyQueued
    case failed
    case nonDurablyQueued
}

public enum GenericQuantityAnchoredProgressPolicy {
    public static func shouldIncludeAnchor(
        canPersistSharedProgress: Bool,
        hadUsableAnchor: Bool,
        activeSampleCount: Int,
        deletedSampleCount: Int
    ) -> Bool {
        guard canPersistSharedProgress else { return false }
        return hadUsableAnchor || activeSampleCount > 0 || deletedSampleCount > 0
    }

    public static func shouldPersistAnchor(
        readSucceeded: Bool,
        delivery: GenericQuantityAnchoredDeliveryDisposition
    ) -> Bool {
        guard readSucceeded else { return false }
        switch delivery {
        case .uploaded, .durablyQueued:
            return true
        case .failed, .nonDurablyQueued:
            return false
        }
    }
}

public enum GenericQuantityAnchoredSyncPolicy {
    public static func legacyTimestampCursorKinds(for rawTypeCode: String) -> [String] {
        let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: rawTypeCode)
        let legacyAliasTypeCodes = GenericQuantityCoveragePolicy.legacyCanonicalTypeCodeAliases
            .filter { $0.value == canonicalTypeCode }
            .map(\.key)
            .sorted()
        return ([canonicalTypeCode] + legacyAliasTypeCodes).map(
            GenericQuantityForegroundSyncPolicy.cursorKind(for:)
        )
    }

    public static func earliestUsableTimestampCursorValue(_ values: [String]) -> String? {
        values.compactMap { value -> (value: String, date: Date)? in
            guard let date = HealthBridgeUTCFormatter.date(from: value) else { return nil }
            return (value, date)
        }
        .min { $0.date < $1.date }?
        .value
    }

    public static func queryPlan(
        typeCode rawTypeCode: String,
        anchorCursorValue: String?,
        legacyTimestampCursorValue: String?,
        historyDepth: HealthHistoryDepth,
        now: Date = Date(),
        calendar: Calendar
    ) -> GenericQuantityAnchoredQueryPlan? {
        let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: rawTypeCode)
        guard GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: [canonicalTypeCode],
            cursorValuesByTypeCode: [:],
            historyDepth: historyDepth,
            now: now,
            calendar: calendar
        ) != nil else {
            return nil
        }
        let cursorKind = GenericQuantitySyncBatchFactory.anchoredCursorKind(for: canonicalTypeCode)
        guard !HealthKitAnchoredCursorPolicy.hasUsableCursorValue(anchorCursorValue) else {
            return GenericQuantityAnchoredQueryPlan(
                canonicalTypeCode: canonicalTypeCode,
                anchorCursorKind: cursorKind,
                predicateStart: nil
            )
        }

        let bootstrapPlan = GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: [canonicalTypeCode],
            cursorValuesByTypeCode: [:],
            historyDepth: historyDepth,
            now: now,
            calendar: calendar
        )
        let migrationPlan = GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: [canonicalTypeCode],
            cursorValuesByTypeCode: legacyTimestampCursorValue.map { [canonicalTypeCode: $0] } ?? [:],
            historyDepth: historyDepth,
            now: now,
            calendar: calendar
        )
        let bootstrapStart = bootstrapPlan?.windowStartsByTypeCode[canonicalTypeCode] ?? nil
        let migrationStart = migrationPlan?.windowStartsByTypeCode[canonicalTypeCode] ?? nil
        let predicateStart: Date?
        if let bootstrapStart, let migrationStart {
            predicateStart = min(bootstrapStart, migrationStart)
        } else {
            predicateStart = nil
        }
        return GenericQuantityAnchoredQueryPlan(
            canonicalTypeCode: canonicalTypeCode,
            anchorCursorKind: cursorKind,
            predicateStart: predicateStart
        )
    }
}

public struct HealthKitDailyActivityAggregate: Equatable, Sendable {
    public let typeCode: String
    public let dayStart: Date
    public let dayEnd: Date
    public let value: Double
    public let calendarDay: String?
    public let timeZoneIdentifier: String?

    public init(
        typeCode: String,
        dayStart: Date,
        dayEnd: Date,
        value: Double,
        calendarDay: String? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.typeCode = typeCode
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.value = value
        self.calendarDay = calendarDay
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public enum DailyActivityAggregateSyncPolicy {
    public static let cursorKind = "foreground_daily_activity_aggregate_sync"
    public static let defaultTypeCodes = [
        "basal_energy",
        "distance_walking_running",
        "energy",
        "exercise_time",
        "flights_climbed",
        "stand_time",
        "steps",
    ]
}

public struct GenericQuantityForegroundSyncPlan: Equatable, Sendable {
    public let selectedEntries: [HealthKitTypeCatalogEntry]
    public let selectedTypeCodes: [String]
    public let windowStart: Date
    public let windowEnd: Date
    public let maximumForegroundWindowDays: Int
    public let maximumForegroundWindowDaysByTypeCode: [String: Int?]
    public let windowStartsByTypeCode: [String: Date?]
    public let cursorKindsByTypeCode: [String: String]

    public init(
        selectedEntries: [HealthKitTypeCatalogEntry],
        selectedTypeCodes: [String],
        windowStart: Date,
        windowEnd: Date,
        maximumForegroundWindowDays: Int,
        maximumForegroundWindowDaysByTypeCode: [String: Int?],
        windowStartsByTypeCode: [String: Date?],
        cursorKindsByTypeCode: [String: String]
    ) {
        self.selectedEntries = selectedEntries
        self.selectedTypeCodes = selectedTypeCodes
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.maximumForegroundWindowDays = maximumForegroundWindowDays
        self.maximumForegroundWindowDaysByTypeCode = maximumForegroundWindowDaysByTypeCode
        self.windowStartsByTypeCode = windowStartsByTypeCode
        self.cursorKindsByTypeCode = cursorKindsByTypeCode
    }
}

public enum GenericQuantityForegroundSyncPolicy {
    public static let replayOverlapSeconds: TimeInterval = 15 * 60

    public static func cursorKind(for typeCode: String) -> String {
        "\(GenericQuantitySyncBatchFactory.foregroundCursorPrefix):\(typeCode)"
    }

    public static func cursorAdvanceTypeCodes(
        samples: [HealthKitQuantitySampleSummary],
        selectedTypeCodes: [String],
        cursorValuesByTypeCode: [String: String],
        successfulReadEnd: Date,
        allowNewCursorCreation: Bool = true
    ) -> [String] {
        let selectedSet = Set(GenericQuantityCoveragePolicy.coveragePlan(availableTypeCodes: selectedTypeCodes)
            .availableEntries
            .map(\.typeCode))
        let sampleTypeCodes = allowNewCursorCreation
            ? Set(samples.map { GenericQuantityCoveragePolicy.canonicalTypeCode(for: $0.typeCode) })
            : Set<String>()
        let existingCursorTypeCodes = Set(canonicalCursorValues(cursorValuesByTypeCode).compactMap { typeCode, cursorValue in
            guard let cursorDate = HealthBridgeUTCFormatter.date(from: cursorValue),
                  cursorDate < successfulReadEnd
            else {
                return nil as String?
            }
            return typeCode
        })
        return sampleTypeCodes
            .union(existingCursorTypeCodes)
            .filter { selectedSet.contains($0) }
            .sorted()
    }

    public static func queryPlan(
        selectedTypeCodes: [String],
        cursorValuesByTypeCode: [String: String],
        historyDepth: HealthHistoryDepth? = nil,
        now: Date = Date(),
        calendar: Calendar
    ) -> GenericQuantityForegroundSyncPlan? {
        let coveragePlan = GenericQuantityCoveragePolicy.coveragePlan(
            availableTypeCodes: selectedTypeCodes
        )
        let selectedTypeCodes = coveragePlan.availableEntries.map(\.typeCode)
        guard !selectedTypeCodes.isEmpty else { return nil }
        let cursorValuesByTypeCode = canonicalCursorValues(cursorValuesByTypeCode)

        let maximumDaysByTypeCode = Dictionary(uniqueKeysWithValues: selectedTypeCodes.map { typeCode in
            (typeCode, maximumForegroundWindowDays(for: typeCode, historyDepth: historyDepth))
        })
        let windowStartsByTypeCode = Dictionary(uniqueKeysWithValues: selectedTypeCodes.map { typeCode -> (String, Date?) in
            let fallbackStart = explicitHistoryStartDate(
                for: typeCode,
                historyDepth: historyDepth,
                now: now,
                calendar: calendar
            ) ?? fallbackStartDate(
                maximumForegroundWindowDays: maximumDaysByTypeCode[typeCode] ?? nil,
                now: now,
                calendar: calendar
            )
            let replayStart = if fallbackStart == nil {
                nil as Date?
            } else {
                replayWindowStart(
                    fallbackStart: fallbackStart,
                    end: now,
                    cursorValue: cursorValuesByTypeCode[typeCode]
                )
            }
            return (typeCode, replayStart)
        })
        let nonNilWindowStarts = windowStartsByTypeCode.values.compactMap { $0 }
        let boundedFallbackStart = calendar.date(
            byAdding: .day,
            value: -coveragePlan.maximumForegroundWindowDays,
            to: now
        ) ?? now.addingTimeInterval(TimeInterval(-coveragePlan.maximumForegroundWindowDays * 24 * 60 * 60))
        let cursorKindsByTypeCode = Dictionary(uniqueKeysWithValues: selectedTypeCodes.map { typeCode in
            (typeCode, cursorKind(for: typeCode))
        })
        return GenericQuantityForegroundSyncPlan(
            selectedEntries: coveragePlan.availableEntries,
            selectedTypeCodes: selectedTypeCodes,
            windowStart: nonNilWindowStarts.min() ?? boundedFallbackStart,
            windowEnd: now,
            maximumForegroundWindowDays: coveragePlan.maximumForegroundWindowDays,
            maximumForegroundWindowDaysByTypeCode: maximumDaysByTypeCode,
            windowStartsByTypeCode: windowStartsByTypeCode,
            cursorKindsByTypeCode: cursorKindsByTypeCode
        )
    }

    private static func maximumForegroundWindowDays(
        for typeCode: String,
        historyDepth: HealthHistoryDepth?
    ) -> Int? {
        if GenericQuantityCoveragePolicy.highVolumeTypeCodes.contains(typeCode) {
            return GenericQuantityCoveragePolicy.highVolumeMaximumForegroundWindowDays
        }
        guard let historyDepth else {
            return GenericQuantityCoveragePolicy.defaultMaximumForegroundWindowDays
        }
        switch historyDepth.sanitized {
        case .allAvailable:
            return GenericQuantityCoveragePolicy.sparseFullHistoryTypeCodes.contains(typeCode)
                ? nil
                : GenericQuantityCoveragePolicy.defaultMaximumForegroundWindowDays
        case let .lastDays(days):
            return days
        case .sinceDate:
            return nil
        }
    }

    private static func fallbackStartDate(
        maximumForegroundWindowDays: Int?,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let maximumForegroundWindowDays else { return nil }
        return calendar.date(
            byAdding: .day,
            value: -maximumForegroundWindowDays,
            to: now
        ) ?? now.addingTimeInterval(TimeInterval(-maximumForegroundWindowDays * 24 * 60 * 60))
    }

    private static func explicitHistoryStartDate(
        for typeCode: String,
        historyDepth: HealthHistoryDepth?,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let historyDepth,
              !GenericQuantityCoveragePolicy.highVolumeTypeCodes.contains(typeCode)
        else {
            return nil
        }
        switch historyDepth.sanitized {
        case .allAvailable:
            return nil
        case .lastDays, .sinceDate:
            return historyDepth.sanitized.lowerBoundDate(now: now, calendar: calendar)
        }
    }

    private static func replayWindowStart(
        fallbackStart: Date?,
        end: Date,
        cursorValue: String?
    ) -> Date? {
        guard
            let cursorValue,
            let cursorDate = HealthBridgeUTCFormatter.date(from: cursorValue),
            cursorDate < end
        else {
            return fallbackStart
        }
        let cursorReplayStart = cursorDate.addingTimeInterval(-replayOverlapSeconds)
        return cursorReplayStart
    }

    private static func canonicalCursorValues(_ cursorValuesByTypeCode: [String: String]) -> [String: String] {
        cursorValuesByTypeCode.reduce(into: [:]) { result, element in
            let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: element.key)
            result[canonicalTypeCode] = element.value
        }
    }
}

public enum GenericQuantitySyncBatchFactory {
    public static let foregroundCursorPrefix = "foreground_quantity_sync"
    public static let anchoredCursorPrefix = "healthkit_anchored_quantity"
    public static let defaultMaxSamplesPerBatch = 500

    public static func anchoredCursorKind(for typeCode: String) -> String {
        let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: typeCode)
        return "\(anchoredCursorPrefix):\(canonicalTypeCode)"
    }

    public static func makeAnchoredQuantityBatches(
        changes: HealthKitAnchoredQuantityChanges,
        generatedAt: Date = Date(),
        maxSamplesPerBatch: Int = defaultMaxSamplesPerBatch,
        includeAnchorCursor: Bool = true
    ) -> [HealthBridgeBatchV1] {
        let source = HealthBridgeAppleHealthSource.phone
        guard let entry = quantityEntries(for: [changes.typeCode]).first else { return [] }
        let entriesByTypeCode = [entry.typeCode: entry]
        let sampleRecords = quantitySampleRecords(
            from: changes.samples,
            entriesByTypeCode: entriesByTypeCode,
            source: source,
            healthKitQuery: "HKAnchoredObjectQuery"
        )
        let deletedRecords = changes.deletedSamples
            .filter {
                GenericQuantityCoveragePolicy.canonicalTypeCode(for: $0.typeCode) == entry.typeCode
            }
            .sorted { lhs, rhs in
                if lhs.deletedAt != rhs.deletedAt { return lhs.deletedAt < rhs.deletedAt }
                return lhs.uuid.uuidString < rhs.uuid.uuidString
            }
            .map { deletedSample in
                HealthBridgeDeletedRecord(
                    recordFamily: "sample",
                    sourceKey: source.sourceKey,
                    clientRecordID: clientRecordID(for: deletedSample.uuid, typeCode: entry.typeCode),
                    deletedAt: HealthBridgeUTCFormatter.string(from: deletedSample.deletedAt)
                )
            }
        guard includeAnchorCursor || !sampleRecords.isEmpty || !deletedRecords.isEmpty else { return [] }
        let effectiveWindowStart = min(
            changes.windowStart,
            earliestValidSampleStart(from: changes.samples, entriesByTypeCode: entriesByTypeCode)
                ?? changes.windowStart
        )
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: effectiveWindowStart),
            endTime: HealthBridgeUTCFormatter.string(from: changes.windowEnd)
        )
        let recordLimit = max(1, maxSamplesPerBatch)
        var recordChunks: [(
            samples: [HealthBridgeSample],
            deletions: [HealthBridgeDeletedRecord]
        )] = []
        var sampleIndex = 0
        var deletionIndex = 0
        while sampleIndex < sampleRecords.count || deletionIndex < deletedRecords.count {
            let sampleEnd = min(sampleRecords.count, sampleIndex + recordLimit)
            let chunkSamples = Array(sampleRecords[sampleIndex..<sampleEnd])
            sampleIndex = sampleEnd
            let remainingCapacity = recordLimit - chunkSamples.count
            let deletionEnd = min(
                deletedRecords.count,
                deletionIndex + remainingCapacity
            )
            let chunkDeletions = Array(deletedRecords[deletionIndex..<deletionEnd])
            deletionIndex = deletionEnd
            recordChunks.append((chunkSamples, chunkDeletions))
        }
        if recordChunks.isEmpty {
            recordChunks.append(([], []))
        }
        return recordChunks.enumerated().map { index, chunk in
            let isFinalChunk = index == recordChunks.index(before: recordChunks.endIndex)
            let cursors: [HealthBridgeSyncCursor] = if isFinalChunk && includeAnchorCursor {
                [
                    HealthBridgeSyncCursor(
                        sourceKey: source.sourceKey,
                        cursorKind: anchoredCursorKind(for: entry.typeCode),
                        cursorValue: changes.anchorCursorValue
                    ),
                ]
            } else {
                []
            }
            return HealthBridgeBatchV1(
                generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
                exportWindow: window,
                sources: [source],
                healthTypes: [healthType(from: entry)],
                samples: chunk.samples,
                workouts: [],
                sleepSessions: [],
                deletedRecords: chunk.deletions,
                sync: HealthBridgeSyncContext(syncWindow: window, cursors: cursors)
            )
        }
    }

    public static func makeQuantityBatch(
        samples: [HealthKitQuantitySampleSummary],
        selectedTypeCodes: [String],
        cursorTypeCodes: [String]? = nil,
        windowStart: Date,
        windowEnd: Date,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1? {
        makeQuantityBatches(
            samples: samples,
            selectedTypeCodes: selectedTypeCodes,
            cursorTypeCodes: cursorTypeCodes,
            windowStart: windowStart,
            windowEnd: windowEnd,
            generatedAt: generatedAt,
            maxSamplesPerBatch: Int.max
        ).first
    }

    public static func makeQuantityBatches(
        samples: [HealthKitQuantitySampleSummary],
        selectedTypeCodes: [String],
        cursorTypeCodes: [String]? = nil,
        windowStart: Date,
        windowEnd: Date,
        generatedAt: Date = Date(),
        maxSamplesPerBatch: Int = defaultMaxSamplesPerBatch
    ) -> [HealthBridgeBatchV1] {
        let source = HealthBridgeAppleHealthSource.phone
        let selectedEntries = quantityEntries(for: selectedTypeCodes)
        guard !selectedEntries.isEmpty else { return [] }
        let cursorTypeCodeSet = Set(
            GenericQuantityCoveragePolicy.canonicalTypeCodes(
                for: cursorTypeCodes ?? selectedTypeCodes
            )
        )
        let cursorEntries = selectedEntries.filter { cursorTypeCodeSet.contains($0.typeCode) }
        let entriesByTypeCode = Dictionary(uniqueKeysWithValues: selectedEntries.map { ($0.typeCode, $0) })
        let sampleRecords = quantitySampleRecords(
            from: samples,
            entriesByTypeCode: entriesByTypeCode,
            source: source
        )
        let effectiveWindowStart = min(windowStart, earliestValidSampleStart(
            from: samples,
            entriesByTypeCode: entriesByTypeCode
        ) ?? windowStart)
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: effectiveWindowStart),
            endTime: HealthBridgeUTCFormatter.string(from: windowEnd)
        )
        let chunks = chunked(sampleRecords, size: max(1, maxSamplesPerBatch))
        let sampleChunks = chunks.isEmpty ? [[]] : chunks
        return sampleChunks.enumerated().map { index, sampleRecords in
            let isFinalChunk = index == sampleChunks.index(before: sampleChunks.endIndex)
            return HealthBridgeBatchV1(
                generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
                exportWindow: window,
                sources: [source],
                healthTypes: selectedEntries.map(healthType(from:)),
                samples: sampleRecords,
                workouts: [],
                sleepSessions: [],
                deletedRecords: [],
                sync: HealthBridgeSyncContext(
                    syncWindow: window,
                    cursors: isFinalChunk ? syncCursors(for: cursorEntries, source: source, windowEnd: windowEnd) : []
                )
            )
        }
    }

    private static func earliestValidSampleStart(
        from samples: [HealthKitQuantitySampleSummary],
        entriesByTypeCode: [String: HealthKitTypeCatalogEntry]
    ) -> Date? {
        samples.compactMap { sample -> Date? in
            let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: sample.typeCode)
            guard entriesByTypeCode[canonicalTypeCode] != nil,
                  sample.start <= sample.end,
                  sample.value.isFinite
            else {
                return nil
            }
            return sample.start
        }.min()
    }

    private static func quantitySampleRecords(
        from samples: [HealthKitQuantitySampleSummary],
        entriesByTypeCode: [String: HealthKitTypeCatalogEntry],
        source: HealthBridgeSource,
        healthKitQuery: String? = nil
    ) -> [HealthBridgeSample] {
        samples
            .filter { sample in
                let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: sample.typeCode)
                guard entriesByTypeCode[canonicalTypeCode] != nil else { return false }
                return sample.start <= sample.end && sample.value.isFinite
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.typeCode != rhs.typeCode { return lhs.typeCode < rhs.typeCode }
                return lhs.uuid.uuidString < rhs.uuid.uuidString
            }
            .map { sample -> HealthBridgeSample in
                let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: sample.typeCode)
                let entry = entriesByTypeCode[canonicalTypeCode]!
                var metadata = [
                    "aggregation": entry.aggregation.rawValue,
                    "healthkit_identifier": entry.healthKitIdentifier,
                    "healthkit_object_kind": entry.objectKind.rawValue,
                    "sample_kind": "raw_quantity",
                ]
                if let healthKitQuery {
                    metadata["healthkit_query"] = healthKitQuery
                }
                if let provenance = sample.provenance {
                    metadata.merge(provenance.metadata) { current, _ in current }
                }
                return HealthBridgeSample(
                    clientRecordID: clientRecordID(for: sample, typeCode: entry.typeCode),
                    sourceKey: source.sourceKey,
                    typeCode: entry.typeCode,
                    startTime: HealthBridgeUTCFormatter.string(from: sample.start),
                    endTime: HealthBridgeUTCFormatter.string(from: sample.end),
                    value: sample.value,
                    unit: entry.canonicalUnit,
                    metadata: metadata
                )
            }
    }

    private static func syncCursors(
        for selectedEntries: [HealthKitTypeCatalogEntry],
        source: HealthBridgeSource,
        windowEnd: Date
    ) -> [HealthBridgeSyncCursor] {
        selectedEntries.map { entry in
            HealthBridgeSyncCursor(
                sourceKey: source.sourceKey,
                cursorKind: "\(foregroundCursorPrefix):\(entry.typeCode)",
                cursorValue: HealthBridgeUTCFormatter.string(from: windowEnd)
            )
        }
    }

    private static func chunked(_ records: [HealthBridgeSample], size: Int) -> [[HealthBridgeSample]] {
        stride(from: 0, to: records.count, by: size).map { start in
            let end = min(start + size, records.count)
            return Array(records[start..<end])
        }
    }

    private static func quantityEntries(for typeCodes: [String]) -> [HealthKitTypeCatalogEntry] {
        GenericQuantityCoveragePolicy.canonicalTypeCodes(for: typeCodes)
            .compactMap { HealthKitTypeCatalog.entry(for: $0) }
            .filter { $0.objectKind == .quantity }
            .sorted { $0.typeCode < $1.typeCode }
    }

    private static func healthType(from entry: HealthKitTypeCatalogEntry) -> HealthBridgeHealthType {
        HealthKitTypeCatalog.healthType(from: entry)
    }

    private static func clientRecordID(for sample: HealthKitQuantitySampleSummary, typeCode: String) -> String {
        clientRecordID(for: sample.uuid, typeCode: typeCode)
    }

    private static func clientRecordID(for uuid: UUID, typeCode: String) -> String {
        let slug = typeCode.replacingOccurrences(of: "_", with: "-")
        return "hk-quantity-\(slug)-\(uuid.uuidString.lowercased())"
    }
}


public enum DailyActivityAggregateSyncBatchFactory {
    public static func makeDailyActivityAggregateBatch(
        aggregates: [HealthKitDailyActivityAggregate],
        typeCodes: [String] = DailyActivityAggregateSyncPolicy.defaultTypeCodes,
        windowStart: Date,
        windowEnd: Date,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1? {
        let source = HealthBridgeAppleHealthSource.phone
        let selectedEntries = dailyActivityEntries(for: typeCodes)
        guard !selectedEntries.isEmpty else { return nil }
        let entriesByTypeCode = Dictionary(uniqueKeysWithValues: selectedEntries.map { ($0.typeCode, $0) })
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: windowStart),
            endTime: HealthBridgeUTCFormatter.string(from: windowEnd)
        )
        let sampleRecords = aggregates
            .compactMap { aggregate -> HealthBridgeSample? in
                let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(for: aggregate.typeCode)
                guard let entry = entriesByTypeCode[canonicalTypeCode],
                      aggregate.dayStart < aggregate.dayEnd,
                      aggregate.value > 0,
                      aggregate.value.isFinite
                else {
                    return nil
                }
                var metadata = [
                    "aggregation": "daily_sum",
                    "daily_activity_semantics": "healthkit_statistics_collection",
                    "healthkit_identifier": entry.healthKitIdentifier,
                    "healthkit_object_kind": entry.objectKind.rawValue,
                    "healthkit_query": "HKStatisticsCollectionQuery",
                    "sample_kind": "daily_aggregate",
                    "source_resolution": "healthkit_statistics_merged_sources",
                ]
                if let calendarDay = aggregate.calendarDay {
                    metadata["calendar_day"] = calendarDay
                }
                if let timeZoneIdentifier = aggregate.timeZoneIdentifier {
                    metadata["time_zone_identifier"] = timeZoneIdentifier
                }
                return HealthBridgeSample(
                    clientRecordID: clientRecordID(for: aggregate, typeCode: entry.typeCode),
                    sourceKey: source.sourceKey,
                    typeCode: entry.typeCode,
                    startTime: HealthBridgeUTCFormatter.string(from: aggregate.dayStart),
                    endTime: HealthBridgeUTCFormatter.string(from: aggregate.dayEnd),
                    value: aggregate.value,
                    unit: entry.canonicalUnit,
                    metadata: metadata
                )
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                if lhs.typeCode != rhs.typeCode { return lhs.typeCode < rhs.typeCode }
                return lhs.clientRecordID < rhs.clientRecordID
            }

        return HealthBridgeBatchV1(
            generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
            exportWindow: window,
            sources: [source],
            healthTypes: selectedEntries.map(HealthKitTypeCatalog.healthType(from:)),
            samples: sampleRecords,
            workouts: [],
            sleepSessions: [],
            deletedRecords: [],
            sync: HealthBridgeSyncContext(
                syncWindow: window,
                cursors: [
                    HealthBridgeSyncCursor(
                        sourceKey: source.sourceKey,
                        cursorKind: DailyActivityAggregateSyncPolicy.cursorKind,
                        cursorValue: HealthBridgeUTCFormatter.string(from: windowEnd)
                    )
                ]
            )
        )
    }

    private static func dailyActivityEntries(for typeCodes: [String]) -> [HealthKitTypeCatalogEntry] {
        GenericQuantityCoveragePolicy.canonicalTypeCodes(for: typeCodes)
            .compactMap { HealthKitTypeCatalog.entry(for: $0) }
            .filter { entry in
                entry.objectKind == .quantity
                    && entry.aggregation == .sum
                    && HealthKitTypeCatalog.healthType(from: entry).category == .activity
            }
            .sorted { $0.typeCode < $1.typeCode }
    }

    private static func clientRecordID(
        for aggregate: HealthKitDailyActivityAggregate,
        typeCode: String
    ) -> String {
        let slug = typeCode.replacingOccurrences(of: "_", with: "-")
        let day = aggregate.calendarDay.map(recordDateString(fromCalendarDay:))
            ?? recordDateString(from: aggregate.dayStart)
        return "hk-daily-activity-\(slug)-\(day)"
    }

    private static func recordDateString(fromCalendarDay calendarDay: String) -> String {
        calendarDay.replacingOccurrences(of: "-", with: "")
    }

    private static func recordDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

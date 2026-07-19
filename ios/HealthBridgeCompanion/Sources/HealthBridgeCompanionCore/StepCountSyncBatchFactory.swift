import Foundation

public struct DailyStepCount: Equatable, Sendable {
    public let dayStart: Date
    public let dayEnd: Date
    public let count: Double

    public init(dayStart: Date, dayEnd: Date, count: Double) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.count = count
    }
}

public struct HealthKitStepSampleSummary: Equatable, Sendable {
    public let uuid: UUID
    public let start: Date
    public let end: Date
    public let count: Double
    public let provenance: HealthKitSampleProvenance?

    public init(
        uuid: UUID,
        start: Date,
        end: Date,
        count: Double,
        provenance: HealthKitSampleProvenance? = nil
    ) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.count = count
        self.provenance = provenance
    }
}

public struct HealthKitDeletedStepSample: Equatable, Sendable {
    public let uuid: UUID
    public let deletedAt: Date

    public init(uuid: UUID, deletedAt: Date) {
        self.uuid = uuid
        self.deletedAt = deletedAt
    }
}

public struct HealthKitAnchoredStepChanges: Equatable, Sendable {
    public let stepSamples: [HealthKitStepSampleSummary]
    public let deletedStepSamples: [HealthKitDeletedStepSample]
    public let anchorCursorValue: String
    public let windowStart: Date
    public let windowEnd: Date

    public init(
        stepSamples: [HealthKitStepSampleSummary],
        deletedStepSamples: [HealthKitDeletedStepSample],
        anchorCursorValue: String,
        windowStart: Date,
        windowEnd: Date
    ) {
        self.stepSamples = stepSamples
        self.deletedStepSamples = deletedStepSamples
        self.anchorCursorValue = anchorCursorValue
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

public struct AnchoredStepQueryPlan: Equatable, Sendable {
    public let queryStart: Date?
    public let bootstrapStartToPersist: Date?

    public init(queryStart: Date?, bootstrapStartToPersist: Date?) {
        self.queryStart = queryStart
        self.bootstrapStartToPersist = bootstrapStartToPersist
    }
}

public enum HealthKitAnchoredCursorPolicy {
    public static func hasUsableCursorValue(_ cursorValue: String?) -> Bool {
        guard let cursorValue else { return false }
        return !cursorValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum AnchoredStepSyncPolicy {
    public static let bootstrapLookbackDays = 7
    public static let bootstrapStartCursorKind = "anchored_step_bootstrap_start"

    public static func queryPlan(
        anchorCursorValue: String?,
        storedBootstrapStartValue: String?,
        bootstrapLookbackDays: Int = AnchoredStepSyncPolicy.bootstrapLookbackDays,
        clampStoredBootstrapToLookback: Bool = false,
        now: Date,
        calendar: Calendar
    ) -> AnchoredStepQueryPlan {
        if HealthKitAnchoredCursorPolicy.hasUsableCursorValue(anchorCursorValue) {
            return AnchoredStepQueryPlan(queryStart: nil, bootstrapStartToPersist: nil)
        }

        let lookbackDays = max(1, bootstrapLookbackDays)
        let startOfToday = calendar.startOfDay(for: now)
        let boundedBootstrapStart = calendar.date(
            byAdding: .day,
            value: -lookbackDays,
            to: startOfToday
        ) ?? now.addingTimeInterval(TimeInterval(-lookbackDays * 24 * 60 * 60))

        if let storedBootstrapStart = storedBootstrapStartValue.flatMap(HealthBridgeUTCFormatter.date(from:)) {
            let queryStart = clampStoredBootstrapToLookback
                ? max(storedBootstrapStart, boundedBootstrapStart)
                : storedBootstrapStart
            return AnchoredStepQueryPlan(
                queryStart: queryStart,
                bootstrapStartToPersist: queryStart
            )
        }

        return AnchoredStepQueryPlan(
            queryStart: boundedBootstrapStart,
            bootstrapStartToPersist: boundedBootstrapStart
        )
    }
}

public enum ForegroundSyncWindowPolicy {
    public static func hasUsableCursorValue(_ cursorValue: String?, before end: Date) -> Bool {
        guard let cursorValue,
              let cursorDate = HealthBridgeUTCFormatter.date(from: cursorValue)
        else {
            return false
        }
        return cursorDate < end
    }

    public static func windowStart(
        fallbackStart: Date,
        end: Date,
        cursorValue: String?,
        replayOverlapDays: Int,
        alignToStartOfDay: Bool,
        calendar: Calendar
    ) -> Date {
        guard
            let cursorValue,
            let cursorDate = HealthBridgeUTCFormatter.date(from: cursorValue),
            cursorDate < end
        else {
            return fallbackStart
        }

        let overlapSeconds = TimeInterval(max(0, replayOverlapDays) * 24 * 60 * 60)
        let replayStart = cursorDate.addingTimeInterval(-overlapSeconds)
        let alignedReplayStart = alignToStartOfDay ? calendar.startOfDay(for: replayStart) : replayStart
        return alignedReplayStart
    }
}

public enum ForegroundSyncUploadPolicy {
    public static func shouldUpload(_ batch: HealthBridgeBatchV1) -> Bool {
        !batch.samples.isEmpty
            || !batch.workouts.isEmpty
            || !batch.sleepSessions.isEmpty
            || !batch.deletedRecords.isEmpty
            || !batch.sync.cursors.isEmpty
    }
}

public enum CoreLaneSyncCursorPolicy {
    public static func effectiveCursorValue(storedCursorValue: String?, hasUploadedRecords: Bool) -> String? {
        guard hasUploadedRecords else { return nil }
        return storedCursorValue
    }

    public static func shouldPersistCursor(uploadedRecords: Bool, hasUploadedRecords: Bool) -> Bool {
        uploadedRecords || hasUploadedRecords
    }
}

public enum StepCountSyncBatchFactory {
    public static let foregroundDailyCursorKind = "foreground_daily_steps_sync"
    public static let anchoredCursorKind = "anchored_step_sync"

    public static func makeDailyStepBatch(
        counts: [DailyStepCount],
        windowStart: Date,
        windowEnd: Date,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1 {
        let source = HealthBridgeAppleHealthSource.phone
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: windowStart),
            endTime: HealthBridgeUTCFormatter.string(from: windowEnd)
        )
        let samples = counts
            .filter { $0.count > 0 }
            .sorted { $0.dayStart < $1.dayStart }
            .map { count in
                HealthBridgeSample(
                    clientRecordID: "hk-steps-\(recordDateString(from: count.dayStart))",
                    sourceKey: source.sourceKey,
                    typeCode: HealthBridgeHealthType.steps.typeCode,
                    startTime: HealthBridgeUTCFormatter.string(from: count.dayStart),
                    endTime: HealthBridgeUTCFormatter.string(from: count.dayEnd),
                    value: count.count,
                    unit: HealthBridgeHealthType.steps.defaultUnit,
                    metadata: [
                        "aggregation": "daily_sum",
                        "healthkit_query": "HKStatisticsCollectionQuery",
                    ]
                )
            }

        return HealthBridgeBatchV1(
            generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
            exportWindow: window,
            sources: [source],
            healthTypes: [.steps],
            samples: samples,
            workouts: [],
            sleepSessions: [],
            deletedRecords: [],
            sync: HealthBridgeSyncContext(
                syncWindow: window,
                cursors: [
                    HealthBridgeSyncCursor(
                        sourceKey: source.sourceKey,
                        cursorKind: foregroundDailyCursorKind,
                        cursorValue: HealthBridgeUTCFormatter.string(from: windowEnd)
                    )
                ]
            )
        )
    }

    public static func makeAnchoredStepBatch(
        changes: HealthKitAnchoredStepChanges,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1 {
        makeAnchoredStepBatch(
            stepSamples: changes.stepSamples,
            deletedStepSamples: changes.deletedStepSamples,
            anchorCursorValue: changes.anchorCursorValue,
            windowStart: changes.windowStart,
            windowEnd: changes.windowEnd,
            generatedAt: generatedAt
        )
    }

    public static func makeAnchoredStepBatch(
        stepSamples: [HealthKitStepSampleSummary],
        deletedStepSamples: [HealthKitDeletedStepSample],
        anchorCursorValue: String,
        windowStart: Date,
        windowEnd: Date,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1 {
        let source = HealthBridgeAppleHealthSource.phone
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: windowStart),
            endTime: HealthBridgeUTCFormatter.string(from: windowEnd)
        )
        let validStepSamples = stepSamples
            .filter { $0.count > 0 && $0.start < $0.end }
        let sampleRecords = validStepSamples
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.uuid.uuidString < rhs.uuid.uuidString
                }
                return lhs.start < rhs.start
            }
            .map { sample in
                var metadata = [
                    "aggregation": "sum",
                    "healthkit_query": "HKAnchoredObjectQuery",
                    "sample_kind": "raw_quantity",
                ]
                if let provenance = sample.provenance {
                    metadata.merge(provenance.metadata) { current, _ in current }
                }
                return HealthBridgeSample(
                    clientRecordID: stepSampleClientRecordID(for: sample.uuid),
                    sourceKey: source.sourceKey,
                    typeCode: HealthBridgeHealthType.steps.typeCode,
                    startTime: HealthBridgeUTCFormatter.string(from: sample.start),
                    endTime: HealthBridgeUTCFormatter.string(from: sample.end),
                    value: sample.count,
                    unit: HealthBridgeHealthType.steps.defaultUnit,
                    metadata: metadata
                )
            }
        let deletedRawRecords = deletedStepSamples
            .sorted { lhs, rhs in
                if lhs.deletedAt == rhs.deletedAt {
                    return lhs.uuid.uuidString < rhs.uuid.uuidString
                }
                return lhs.deletedAt < rhs.deletedAt
            }
            .map { deletedSample in
                HealthBridgeDeletedRecord(
                    recordFamily: "sample",
                    sourceKey: source.sourceKey,
                    clientRecordID: stepSampleClientRecordID(for: deletedSample.uuid),
                    deletedAt: HealthBridgeUTCFormatter.string(from: deletedSample.deletedAt)
                )
            }
        let legacyAggregateTombstones = legacyDailyStepAggregateTombstones(
            for: validStepSamples,
            source: source,
            deletedAt: generatedAt
        )

        return HealthBridgeBatchV1(
            generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
            exportWindow: window,
            sources: [source],
            healthTypes: [.steps],
            samples: sampleRecords,
            workouts: [],
            sleepSessions: [],
            deletedRecords: deletedRawRecords + legacyAggregateTombstones,
            sync: HealthBridgeSyncContext(
                syncWindow: window,
                cursors: [
                    HealthBridgeSyncCursor(
                        sourceKey: source.sourceKey,
                        cursorKind: anchoredCursorKind,
                        cursorValue: anchorCursorValue
                    )
                ]
            )
        )
    }

    private static func recordDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func stepSampleClientRecordID(for uuid: UUID) -> String {
        "hk-step-sample-\(uuid.uuidString.lowercased())"
    }

    private static func legacyDailyStepAggregateTombstones(
        for samples: [HealthKitStepSampleSummary],
        source: HealthBridgeSource,
        deletedAt: Date
    ) -> [HealthBridgeDeletedRecord] {
        let touchedDayRecordIDs = Set(samples.map { "hk-steps-\(recordDateString(from: $0.start))" })
        return touchedDayRecordIDs
            .sorted()
            .map { clientRecordID in
                HealthBridgeDeletedRecord(
                    recordFamily: "sample",
                    sourceKey: source.sourceKey,
                    clientRecordID: clientRecordID,
                    deletedAt: HealthBridgeUTCFormatter.string(from: deletedAt)
                )
            }
    }
}

public enum HealthBridgeAppleHealthSource {
    public static let legacyPhoneSourceKey = "apple_health.phone"

    public static func phone(sourceKey: String) -> HealthBridgeSource {
        HealthBridgeSource(
            sourceKey: sourceKey,
            name: "Apple Health on iPhone",
            kind: .phone,
            bundleID: HealthBridgeAppIdentity.bundleIdentifier,
            deviceModel: "iPhone"
        )
    }

    public static let phone = phone(sourceKey: legacyPhoneSourceKey)
}

public struct HealthKitWorkoutSummary: Equatable, Sendable {
    public let uuid: UUID
    public let workoutType: String
    public let start: Date
    public let end: Date
    public let durationSeconds: Int
    public let activeEnergyKcal: Double?
    public let distanceMeters: Double?

    public init(
        uuid: UUID,
        workoutType: String,
        start: Date,
        end: Date,
        durationSeconds: Int,
        activeEnergyKcal: Double?,
        distanceMeters: Double?
    ) {
        self.uuid = uuid
        self.workoutType = workoutType
        self.start = start
        self.end = end
        self.durationSeconds = durationSeconds
        self.activeEnergyKcal = activeEnergyKcal
        self.distanceMeters = distanceMeters
    }
}

public struct HealthKitDeletedWorkout: Equatable, Sendable {
    public let uuid: UUID
    public let deletedAt: Date

    public init(uuid: UUID, deletedAt: Date) {
        self.uuid = uuid
        self.deletedAt = deletedAt
    }
}

public struct HealthKitSleepStageSummary: Equatable, Sendable {
    public let stage: String
    public let start: Date
    public let end: Date

    public init(stage: String, start: Date, end: Date) {
        self.stage = stage
        self.start = start
        self.end = end
    }
}

public struct HealthKitSleepSessionSummary: Equatable, Sendable {
    public let uuid: UUID
    public let start: Date
    public let end: Date
    public let stageIntervals: [HealthKitSleepStageSummary]

    public init(
        uuid: UUID,
        start: Date,
        end: Date,
        stageIntervals: [HealthKitSleepStageSummary]
    ) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.stageIntervals = stageIntervals
    }
}

public struct HealthKitSleepChildSample: Codable, Equatable, Sendable {
    public let uuid: UUID
    public let stage: String
    public let start: Date
    public let end: Date

    public init(uuid: UUID, stage: String, start: Date, end: Date) {
        self.uuid = uuid
        self.stage = stage
        self.start = start
        self.end = end
    }
}

public struct HealthKitDeletedSleepSample: Equatable, Sendable {
    public let uuid: UUID
    public let deletedAt: Date

    public init(uuid: UUID, deletedAt: Date) {
        self.uuid = uuid
        self.deletedAt = deletedAt
    }
}

public struct HealthKitAnchoredSleepChanges: Equatable, Sendable {
    public let addedSamples: [HealthKitSleepChildSample]
    public let deletedSamples: [HealthKitDeletedSleepSample]
    public let anchorCursorValue: String
    public let receivedAt: Date

    public init(
        addedSamples: [HealthKitSleepChildSample],
        deletedSamples: [HealthKitDeletedSleepSample],
        anchorCursorValue: String,
        receivedAt: Date
    ) {
        self.addedSamples = addedSamples
        self.deletedSamples = deletedSamples
        self.anchorCursorValue = anchorCursorValue
        self.receivedAt = receivedAt
    }
}

public struct SleepSyncManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receiverSettingsGeneration: String
    public let historyDepth: HealthHistoryDepth
    public let historyStartDate: Date?
    public let sourceKey: String?
    public let baselineResetEpoch: UInt64?
    public let identityNamespace: UUID
    public let nextRevisionSequence: UInt64
    public let anchorCursorValue: String?
    public let activeChildSamples: [HealthKitSleepChildSample]
    public let publishedSessions: [HealthBridgeSleepSession]
    public let baselineResetPending: Bool?

    public init(
        schemaVersion: Int = 6,
        receiverSettingsGeneration: String,
        historyDepth: HealthHistoryDepth,
        historyStartDate: Date?,
        sourceKey: String? = nil,
        baselineResetEpoch: UInt64? = nil,
        identityNamespace: UUID,
        nextRevisionSequence: UInt64,
        anchorCursorValue: String?,
        activeChildSamples: [HealthKitSleepChildSample],
        publishedSessions: [HealthBridgeSleepSession],
        baselineResetPending: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.receiverSettingsGeneration = receiverSettingsGeneration
        self.historyDepth = historyDepth.sanitized
        self.historyStartDate = historyStartDate
        self.sourceKey = sourceKey
        self.baselineResetEpoch = baselineResetEpoch
        self.identityNamespace = identityNamespace
        self.nextRevisionSequence = nextRevisionSequence
        self.anchorCursorValue = anchorCursorValue
        self.activeChildSamples = activeChildSamples
        self.publishedSessions = publishedSessions
        self.baselineResetPending = baselineResetPending
    }
}

public struct AnchoredSleepSyncTransition: Equatable, Sendable {
    public let batch: HealthBridgeBatchV1
    public let manifest: SleepSyncManifest

    public init(batch: HealthBridgeBatchV1, manifest: SleepSyncManifest) {
        self.batch = batch
        self.manifest = manifest
    }
}

public struct AnchoredSleepManifestPlan: Equatable, Sendable {
    public let previousManifest: SleepSyncManifest?
    public let anchorCursorValue: String?
    public let historyStartDate: Date?
    public let forceRepublishAll: Bool

    public init(
        previousManifest: SleepSyncManifest?,
        anchorCursorValue: String?,
        historyStartDate: Date?,
        forceRepublishAll: Bool
    ) {
        self.previousManifest = previousManifest
        self.anchorCursorValue = anchorCursorValue
        self.historyStartDate = historyStartDate
        self.forceRepublishAll = forceRepublishAll
    }
}

public enum SleepSyncBatchFactory {
    public static let foregroundCursorKind = "foreground_sleep_sync"
    public static let anchoredCursorKind = "anchored_sleep_sync"
    public static let baselineResetCursorKind = "anchored_sleep_baseline_reset"
    private static let validSleepStages = Set(["in_bed", "awake", "core", "deep", "rem"])

    public static func requiresInstallationSourceMigration(
        manifest: SleepSyncManifest,
        pendingBatch: HealthBridgeBatchV1?,
        expectedSourceKey: String
    ) -> Bool {
        guard manifest.sourceKey == expectedSourceKey else { return true }
        guard manifest.publishedSessions.allSatisfy({
            $0.sourceKey == expectedSourceKey
        }) else { return true }
        guard let pendingBatch else { return false }
        guard pendingBatch.sources.allSatisfy({
            $0.sourceKey == expectedSourceKey
        }) else { return true }
        guard pendingBatch.sleepSessions.allSatisfy({
            $0.sourceKey == expectedSourceKey
        }) else { return true }
        guard pendingBatch.deletedRecords
            .filter({ $0.recordFamily == "sleep_session" })
            .allSatisfy({ $0.sourceKey == expectedSourceKey }) else { return true }
        return !pendingBatch.sync.cursors
            .filter({
                $0.cursorKind == anchoredCursorKind
                    || $0.cursorKind == baselineResetCursorKind
            })
            .allSatisfy({ $0.sourceKey == expectedSourceKey })
    }

    public static func makeManifestReservation(
        receiverSettingsGeneration: String,
        historyDepth: HealthHistoryDepth,
        historyStartDate: Date?,
        sourceKey: String = HealthBridgeAppleHealthSource.legacyPhoneSourceKey,
        baselineResetEpoch: UInt64 = 1,
        identityNamespace: UUID = UUID(),
        nextRevisionSequence: UInt64 = 1
    ) -> SleepSyncManifest {
        SleepSyncManifest(
            receiverSettingsGeneration: receiverSettingsGeneration,
            historyDepth: historyDepth,
            historyStartDate: historyStartDate,
            sourceKey: sourceKey,
            baselineResetEpoch: baselineResetEpoch,
            identityNamespace: identityNamespace,
            nextRevisionSequence: nextRevisionSequence,
            anchorCursorValue: nil,
            activeChildSamples: [],
            publishedSessions: []
        )
    }

    public static func manifestPlan(
        _ manifest: SleepSyncManifest?,
        receiverSettingsGeneration: String,
        historyDepth: HealthHistoryDepth,
        requestedHistoryStartDate: Date?
    ) -> AnchoredSleepManifestPlan {
        let sanitizedHistoryDepth = historyDepth.sanitized
        if manifest?.receiverSettingsGeneration == receiverSettingsGeneration,
           manifest?.historyDepth == sanitizedHistoryDepth {
            let baselineResetPending = manifest?.baselineResetPending == true
            return AnchoredSleepManifestPlan(
                previousManifest: manifest,
                anchorCursorValue: baselineResetPending ? nil : manifest?.anchorCursorValue,
                historyStartDate: manifest?.historyStartDate,
                forceRepublishAll: baselineResetPending
            )
        }
        guard let manifest else {
            return AnchoredSleepManifestPlan(
                previousManifest: nil,
                anchorCursorValue: nil,
                historyStartDate: requestedHistoryStartDate,
                forceRepublishAll: false
            )
        }
        let resetManifest = SleepSyncManifest(
            receiverSettingsGeneration: receiverSettingsGeneration,
            historyDepth: sanitizedHistoryDepth,
            historyStartDate: requestedHistoryStartDate,
            sourceKey: manifest.sourceKey,
            baselineResetEpoch: manifest.baselineResetEpoch,
            identityNamespace: manifest.identityNamespace,
            nextRevisionSequence: manifest.nextRevisionSequence,
            anchorCursorValue: nil,
            activeChildSamples: [],
            publishedSessions: manifest.publishedSessions
        )
        return AnchoredSleepManifestPlan(
            previousManifest: resetManifest,
            anchorCursorValue: nil,
            historyStartDate: requestedHistoryStartDate,
            forceRepublishAll: true
        )
    }

    public static func makeAnchoredSleepTransition(
        previousManifest: SleepSyncManifest?,
        changes: HealthKitAnchoredSleepChanges,
        receiverSettingsGeneration: String,
        historyDepth: HealthHistoryDepth,
        historyStartDate: Date?,
        forceRepublishAll: Bool = false,
        generatedAt: Date = Date(),
        newManifestNamespace: UUID = UUID()
    ) -> AnchoredSleepSyncTransition? {
        let validAdditions = changes.addedSamples.filter {
            $0.start < $0.end && validSleepStages.contains($0.stage)
        }
        let manifestHasEstablishedState = previousManifest.map {
            $0.anchorCursorValue != nil
                || !$0.activeChildSamples.isEmpty
                || !$0.publishedSessions.isEmpty
        } ?? false
        let resolvedSourceKey = previousManifest?.sourceKey
            ?? HealthBridgeAppleHealthSource.legacyPhoneSourceKey
        let resolvedResetEpoch = previousManifest?.baselineResetEpoch ?? 1
        let resetCursorValue = "v2:\(resolvedResetEpoch)"
        let baselineResetRequired = forceRepublishAll || !manifestHasEstablishedState
        if baselineResetRequired && validAdditions.isEmpty {
            let identityNamespace = previousManifest?.identityNamespace ?? newManifestNamespace
            let resolvedHistoryDepth = previousManifest?.historyDepth ?? historyDepth.sanitized
            let resolvedHistoryStartDate = previousManifest?.historyStartDate ?? historyStartDate
            let source = HealthBridgeAppleHealthSource.phone(sourceKey: resolvedSourceKey)
            let windowStart = resolvedHistoryStartDate ?? changes.receivedAt
            let window = HealthBridgeTimeWindow(
                startTime: HealthBridgeUTCFormatter.string(from: windowStart),
                endTime: HealthBridgeUTCFormatter.string(from: changes.receivedAt)
            )
            let batch = HealthBridgeBatchV1(
                generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
                exportWindow: window,
                sources: [source],
                healthTypes: [.sleepAnalysis],
                samples: [],
                workouts: [],
                sleepSessions: [],
                deletedRecords: [],
                sync: HealthBridgeSyncContext(
                    syncWindow: window,
                    cursors: [
                        HealthBridgeSyncCursor(
                            sourceKey: source.sourceKey,
                            cursorKind: anchoredCursorKind,
                            cursorValue: changes.anchorCursorValue
                        ),
                        HealthBridgeSyncCursor(
                            sourceKey: source.sourceKey,
                            cursorKind: baselineResetCursorKind,
                            cursorValue: resetCursorValue
                        ),
                    ]
                )
            )
            let manifest = SleepSyncManifest(
                receiverSettingsGeneration: receiverSettingsGeneration,
                historyDepth: resolvedHistoryDepth,
                historyStartDate: resolvedHistoryStartDate,
                sourceKey: resolvedSourceKey,
                baselineResetEpoch: resolvedResetEpoch,
                identityNamespace: identityNamespace,
                nextRevisionSequence: previousManifest?.nextRevisionSequence ?? 1,
                anchorCursorValue: changes.anchorCursorValue,
                activeChildSamples: previousManifest?.activeChildSamples ?? [],
                publishedSessions: previousManifest?.publishedSessions ?? [],
                baselineResetPending: true
            )
            return AnchoredSleepSyncTransition(batch: batch, manifest: manifest)
        }

        var activeSamplesByID = Dictionary(
            uniqueKeysWithValues: (previousManifest?.activeChildSamples ?? []).map {
                ($0.uuid, $0)
            }
        )
        for sample in validAdditions {
            activeSamplesByID[sample.uuid] = sample
        }
        for deletedSample in changes.deletedSamples {
            activeSamplesByID.removeValue(forKey: deletedSample.uuid)
        }
        let activeSamples = activeSamplesByID.values.sorted(by: sleepChildSort)
        let groupedSessions = groupedSleepSessions(from: activeSamples)
        let previousPublished = previousManifest?.publishedSessions ?? []
        var unmatchedPrevious = previousPublished
        var nextSequence = previousManifest?.nextRevisionSequence ?? 1
        let identityNamespace = previousManifest?.identityNamespace ?? newManifestNamespace
        let resolvedHistoryDepth = previousManifest?.historyDepth ?? historyDepth.sanitized
        let resolvedHistoryStartDate = previousManifest?.historyStartDate ?? historyStartDate
        var currentPublished: [HealthBridgeSleepSession] = []
        var changedSessions: [HealthBridgeSleepSession] = []

        for groupedSession in groupedSessions {
            let shape = sleepSessionRecord(
                from: groupedSession,
                clientRecordID: "hk-sleep-shape",
                sourceKey: resolvedSourceKey
            )
            if let matchingIndex = unmatchedPrevious.firstIndex(where: {
                sameSleepSessionShape($0, shape)
            }) {
                let retained = unmatchedPrevious.remove(at: matchingIndex)
                currentPublished.append(retained)
                if forceRepublishAll {
                    changedSessions.append(retained)
                }
                continue
            }
            let revision = sleepSessionRecord(
                from: groupedSession,
                clientRecordID: sleepRevisionClientRecordID(
                    namespace: identityNamespace,
                    sequence: nextSequence
                ),
                sourceKey: resolvedSourceKey
            )
            nextSequence += 1
            currentPublished.append(revision)
            changedSessions.append(revision)
        }
        currentPublished.sort(by: sleepSessionRecordSort)
        changedSessions.sort(by: sleepSessionRecordSort)

        let source = HealthBridgeAppleHealthSource.phone(sourceKey: resolvedSourceKey)
        let deletedRecords = unmatchedPrevious
            .sorted { $0.clientRecordID < $1.clientRecordID }
            .map {
                HealthBridgeDeletedRecord(
                    recordFamily: "sleep_session",
                    sourceKey: source.sourceKey,
                    clientRecordID: $0.clientRecordID,
                    deletedAt: HealthBridgeUTCFormatter.string(from: changes.receivedAt)
                )
            }
        let windowStart = sleepChangeWindowStart(
            activeSamples: activeSamples,
            retiredSessions: unmatchedPrevious,
            receivedAt: changes.receivedAt
        )
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: windowStart),
            endTime: HealthBridgeUTCFormatter.string(from: changes.receivedAt)
        )
        var cursors = [
            HealthBridgeSyncCursor(
                sourceKey: source.sourceKey,
                cursorKind: anchoredCursorKind,
                cursorValue: changes.anchorCursorValue
            )
        ]
        if forceRepublishAll || !manifestHasEstablishedState {
            cursors.append(
                HealthBridgeSyncCursor(
                    sourceKey: source.sourceKey,
                    cursorKind: baselineResetCursorKind,
                    cursorValue: resetCursorValue
                )
            )
        }
        let batch = HealthBridgeBatchV1(
            generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
            exportWindow: window,
            sources: [source],
            healthTypes: [.sleepAnalysis],
            samples: [],
            workouts: [],
            sleepSessions: changedSessions,
            deletedRecords: deletedRecords,
            sync: HealthBridgeSyncContext(
                syncWindow: window,
                cursors: cursors
            )
        )
        let manifest = SleepSyncManifest(
            receiverSettingsGeneration: receiverSettingsGeneration,
            historyDepth: resolvedHistoryDepth,
            historyStartDate: resolvedHistoryStartDate,
            sourceKey: resolvedSourceKey,
            baselineResetEpoch: resolvedResetEpoch,
            identityNamespace: identityNamespace,
            nextRevisionSequence: nextSequence,
            anchorCursorValue: changes.anchorCursorValue,
            activeChildSamples: activeSamples,
            publishedSessions: currentPublished
        )
        return AnchoredSleepSyncTransition(batch: batch, manifest: manifest)
    }

    public static func makeSleepBatch(
        sleepSessions: [HealthKitSleepSessionSummary],
        windowStart: Date,
        windowEnd: Date,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1 {
        let source = HealthBridgeAppleHealthSource.phone
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: windowStart),
            endTime: HealthBridgeUTCFormatter.string(from: windowEnd)
        )

        return HealthBridgeBatchV1(
            generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
            exportWindow: window,
            sources: [source],
            healthTypes: [.sleepAnalysis],
            samples: [],
            workouts: [],
            sleepSessions: sleepSessionRecords(from: sleepSessions, source: source),
            deletedRecords: [],
            sync: HealthBridgeSyncContext(
                syncWindow: window,
                cursors: [
                    HealthBridgeSyncCursor(
                        sourceKey: source.sourceKey,
                        cursorKind: foregroundCursorKind,
                        cursorValue: HealthBridgeUTCFormatter.string(from: windowEnd)
                    )
                ]
            )
        )
    }

    private static func sleepSessionRecords(
        from sleepSessions: [HealthKitSleepSessionSummary],
        source: HealthBridgeSource
    ) -> [HealthBridgeSleepSession] {
        sleepSessions
            .filter { $0.start < $0.end }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.uuid.uuidString < rhs.uuid.uuidString
                }
                return lhs.start < rhs.start
            }
            .map { session in
                HealthBridgeSleepSession(
                    clientRecordID: sleepSessionClientRecordID(for: session),
                    sourceKey: source.sourceKey,
                    startTime: HealthBridgeUTCFormatter.string(from: session.start),
                    endTime: HealthBridgeUTCFormatter.string(from: session.end),
                    stageIntervals: sleepStageIntervals(from: session.stageIntervals)
                )
            }
    }

    private static func sleepStageIntervals(
        from stageIntervals: [HealthKitSleepStageSummary]
    ) -> [HealthBridgeSleepStageInterval] {
        stageIntervals
            .filter { $0.start < $0.end }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.stage < rhs.stage
                }
                return lhs.start < rhs.start
            }
            .map { interval in
                HealthBridgeSleepStageInterval(
                    stage: interval.stage,
                    startTime: HealthBridgeUTCFormatter.string(from: interval.start),
                    endTime: HealthBridgeUTCFormatter.string(from: interval.end)
                )
            }
    }

    private static func sleepSessionClientRecordID(for session: HealthKitSleepSessionSummary) -> String {
        "hk-sleep-\(sleepSessionTimestampSlug(session.start))-\(sleepSessionTimestampSlug(session.end))"
    }

    private static func sleepSessionTimestampSlug(_ date: Date) -> String {
        HealthBridgeUTCFormatter.string(from: date)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
    }

    public static func groupedSleepSessions(
        from childSamples: [HealthKitSleepChildSample]
    ) -> [HealthKitSleepSessionSummary] {
        let sorted = childSamples
            .filter { $0.start < $0.end && validSleepStages.contains($0.stage) }
            .sorted(by: sleepChildSort)
        var sessions: [HealthKitSleepSessionSummary] = []
        var current: [HealthKitSleepChildSample] = []
        var currentEnd: Date?
        let maxGapSeconds: TimeInterval = 30 * 60

        func flushCurrent() {
            guard let first = current.first else { return }
            let start = current.map(\.start).min() ?? first.start
            let end = current.map(\.end).max() ?? first.end
            sessions.append(
                HealthKitSleepSessionSummary(
                    uuid: first.uuid,
                    start: start,
                    end: end,
                    stageIntervals: current.map {
                        HealthKitSleepStageSummary(
                            stage: $0.stage,
                            start: $0.start,
                            end: $0.end
                        )
                    }
                )
            )
            current.removeAll()
            currentEnd = nil
        }

        for sample in sorted {
            if let end = currentEnd,
               sample.start.timeIntervalSince(end) > maxGapSeconds {
                flushCurrent()
            }
            current.append(sample)
            if currentEnd == nil || sample.end > currentEnd! {
                currentEnd = sample.end
            }
        }
        flushCurrent()
        return sessions
    }

    private static func sleepChildSort(
        _ lhs: HealthKitSleepChildSample,
        _ rhs: HealthKitSleepChildSample
    ) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if lhs.stage != rhs.stage { return lhs.stage < rhs.stage }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    private static func sleepSessionRecord(
        from session: HealthKitSleepSessionSummary,
        clientRecordID: String,
        sourceKey: String
    ) -> HealthBridgeSleepSession {
        HealthBridgeSleepSession(
            clientRecordID: clientRecordID,
            sourceKey: sourceKey,
            startTime: HealthBridgeUTCFormatter.string(from: session.start),
            endTime: HealthBridgeUTCFormatter.string(from: session.end),
            stageIntervals: sleepStageIntervals(from: session.stageIntervals)
        )
    }

    private static func sameSleepSessionShape(
        _ lhs: HealthBridgeSleepSession,
        _ rhs: HealthBridgeSleepSession
    ) -> Bool {
        lhs.sourceKey == rhs.sourceKey
            && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime
            && lhs.stageIntervals == rhs.stageIntervals
    }

    private static func sleepRevisionClientRecordID(
        namespace: UUID,
        sequence: UInt64
    ) -> String {
        let namespaceSlug = namespace.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return String(
            format: "hk-sleep-%@-%020llu",
            namespaceSlug,
            sequence
        )
    }

    private static func sleepSessionRecordSort(
        _ lhs: HealthBridgeSleepSession,
        _ rhs: HealthBridgeSleepSession
    ) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return lhs.clientRecordID < rhs.clientRecordID
    }

    private static func sleepChangeWindowStart(
        activeSamples: [HealthKitSleepChildSample],
        retiredSessions: [HealthBridgeSleepSession],
        receivedAt: Date
    ) -> Date {
        let activeStarts = activeSamples.map(\.start)
        let retiredStarts = retiredSessions.compactMap {
            HealthBridgeUTCFormatter.date(from: $0.startTime)
        }
        return (activeStarts + retiredStarts + [receivedAt]).min() ?? receivedAt
    }
}

public struct HealthKitAnchoredWorkoutChanges: Equatable, Sendable {
    public let workouts: [HealthKitWorkoutSummary]
    public let deletedWorkouts: [HealthKitDeletedWorkout]
    public let anchorCursorValue: String
    public let windowStart: Date
    public let windowEnd: Date

    public init(
        workouts: [HealthKitWorkoutSummary],
        deletedWorkouts: [HealthKitDeletedWorkout],
        anchorCursorValue: String,
        windowStart: Date,
        windowEnd: Date
    ) {
        self.workouts = workouts
        self.deletedWorkouts = deletedWorkouts
        self.anchorCursorValue = anchorCursorValue
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

public struct AnchoredWorkoutQueryPlan: Equatable, Sendable {
    public let queryStart: Date?
    public let bootstrapStartToPersist: Date?

    public init(queryStart: Date?, bootstrapStartToPersist: Date?) {
        self.queryStart = queryStart
        self.bootstrapStartToPersist = bootstrapStartToPersist
    }
}

public enum AnchoredWorkoutSyncPolicy {
    public static let bootstrapLookbackDays = 90
    public static let bootstrapStartCursorKind = "anchored_workout_bootstrap_start"

    public static func queryPlan(
        anchorCursorValue: String?,
        storedBootstrapStartValue: String?,
        bootstrapLookbackDays: Int = AnchoredWorkoutSyncPolicy.bootstrapLookbackDays,
        clampStoredBootstrapToLookback: Bool = false,
        now: Date,
        calendar: Calendar
    ) -> AnchoredWorkoutQueryPlan {
        if HealthKitAnchoredCursorPolicy.hasUsableCursorValue(anchorCursorValue) {
            return AnchoredWorkoutQueryPlan(queryStart: nil, bootstrapStartToPersist: nil)
        }

        let lookbackDays = max(1, bootstrapLookbackDays)
        let startOfToday = calendar.startOfDay(for: now)
        let boundedBootstrapStart = calendar.date(
            byAdding: .day,
            value: -lookbackDays,
            to: startOfToday
        ) ?? now.addingTimeInterval(TimeInterval(-lookbackDays * 24 * 60 * 60))

        if let storedBootstrapStart = storedBootstrapStartValue.flatMap(HealthBridgeUTCFormatter.date(from:)) {
            let queryStart = clampStoredBootstrapToLookback
                ? max(storedBootstrapStart, boundedBootstrapStart)
                : storedBootstrapStart
            return AnchoredWorkoutQueryPlan(
                queryStart: queryStart,
                bootstrapStartToPersist: queryStart
            )
        }

        return AnchoredWorkoutQueryPlan(
            queryStart: boundedBootstrapStart,
            bootstrapStartToPersist: boundedBootstrapStart
        )
    }
}

public enum WorkoutSyncBatchFactory {
    public static let foregroundCursorKind = "foreground_workout_sync"
    public static let anchoredCursorKind = "anchored_workout_sync"

    public static func makeWorkoutBatch(
        workouts: [HealthKitWorkoutSummary],
        windowStart: Date,
        windowEnd: Date,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1 {
        let source = HealthBridgeAppleHealthSource.phone
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: windowStart),
            endTime: HealthBridgeUTCFormatter.string(from: windowEnd)
        )

        return HealthBridgeBatchV1(
            generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
            exportWindow: window,
            sources: [source],
            healthTypes: [.workouts],
            samples: [],
            workouts: workoutRecords(from: workouts, source: source),
            sleepSessions: [],
            deletedRecords: [],
            sync: HealthBridgeSyncContext(
                syncWindow: window,
                cursors: [
                    HealthBridgeSyncCursor(
                        sourceKey: source.sourceKey,
                        cursorKind: foregroundCursorKind,
                        cursorValue: HealthBridgeUTCFormatter.string(from: windowEnd)
                    )
                ]
            )
        )
    }

    public static func makeAnchoredWorkoutBatch(
        changes: HealthKitAnchoredWorkoutChanges,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1 {
        makeAnchoredWorkoutBatch(
            workouts: changes.workouts,
            deletedWorkouts: changes.deletedWorkouts,
            anchorCursorValue: changes.anchorCursorValue,
            windowStart: changes.windowStart,
            windowEnd: changes.windowEnd,
            generatedAt: generatedAt
        )
    }

    public static func makeAnchoredWorkoutBatch(
        workouts: [HealthKitWorkoutSummary],
        deletedWorkouts: [HealthKitDeletedWorkout],
        anchorCursorValue: String,
        windowStart: Date,
        windowEnd: Date,
        generatedAt: Date = Date()
    ) -> HealthBridgeBatchV1 {
        let source = HealthBridgeAppleHealthSource.phone
        let window = HealthBridgeTimeWindow(
            startTime: HealthBridgeUTCFormatter.string(from: windowStart),
            endTime: HealthBridgeUTCFormatter.string(from: windowEnd)
        )
        let deletedRecords = deletedWorkouts
            .sorted { lhs, rhs in
                if lhs.deletedAt == rhs.deletedAt {
                    return lhs.uuid.uuidString < rhs.uuid.uuidString
                }
                return lhs.deletedAt < rhs.deletedAt
            }
            .map { deletedWorkout in
                HealthBridgeDeletedRecord(
                    recordFamily: "workout",
                    sourceKey: source.sourceKey,
                    clientRecordID: workoutClientRecordID(for: deletedWorkout.uuid),
                    deletedAt: HealthBridgeUTCFormatter.string(from: deletedWorkout.deletedAt)
                )
            }

        return HealthBridgeBatchV1(
            generatedAt: HealthBridgeUTCFormatter.string(from: generatedAt),
            exportWindow: window,
            sources: [source],
            healthTypes: [.workouts],
            samples: [],
            workouts: workoutRecords(from: workouts, source: source),
            sleepSessions: [],
            deletedRecords: deletedRecords,
            sync: HealthBridgeSyncContext(
                syncWindow: window,
                cursors: [
                    HealthBridgeSyncCursor(
                        sourceKey: source.sourceKey,
                        cursorKind: anchoredCursorKind,
                        cursorValue: anchorCursorValue
                    )
                ]
            )
        )
    }

    private static func workoutRecords(
        from workouts: [HealthKitWorkoutSummary],
        source: HealthBridgeSource
    ) -> [HealthBridgeWorkout] {
        workouts
            .filter { $0.durationSeconds > 0 && $0.start < $0.end }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.uuid.uuidString < rhs.uuid.uuidString
                }
                return lhs.start < rhs.start
            }
            .map { workout in
                let serializedIntervalSeconds = max(
                    0,
                    Int(floor(workout.end.timeIntervalSince1970)
                        - floor(workout.start.timeIntervalSince1970))
                )
                return HealthBridgeWorkout(
                    clientRecordID: workoutClientRecordID(for: workout.uuid),
                    sourceKey: source.sourceKey,
                    workoutType: workout.workoutType,
                    startTime: HealthBridgeUTCFormatter.string(from: workout.start),
                    endTime: HealthBridgeUTCFormatter.string(from: workout.end),
                    durationSeconds: min(workout.durationSeconds, serializedIntervalSeconds),
                    energyKcal: workout.activeEnergyKcal,
                    distanceMeters: workout.distanceMeters
                )
            }
    }

    private static func workoutClientRecordID(for uuid: UUID) -> String {
        "hk-workout-\(uuid.uuidString.lowercased())"
    }
}

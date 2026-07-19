import XCTest
@testable import HealthBridgeCompanionCore

final class StepCountSyncBatchFactoryTests: XCTestCase {
    func testFactoryBuildsStableDailyStepSamplesForReceiverContract() throws {
        let start = try date("2026-06-01T00:00:00Z")
        let end = try date("2026-06-03T00:00:00Z")
        let generatedAt = try date("2026-06-08T09:30:12Z")
        let counts = [
            DailyStepCount(
                dayStart: try date("2026-06-01T00:00:00Z"),
                dayEnd: try date("2026-06-02T00:00:00Z"),
                count: 4321
            ),
            DailyStepCount(
                dayStart: try date("2026-06-02T00:00:00Z"),
                dayEnd: try date("2026-06-03T00:00:00Z"),
                count: 0
            ),
        ]

        let batch = StepCountSyncBatchFactory.makeDailyStepBatch(
            counts: counts,
            windowStart: start,
            windowEnd: end,
            generatedAt: generatedAt
        )

        XCTAssertEqual(batch.generatedAt, "2026-06-08T09:30:12Z")
        XCTAssertEqual(batch.exportWindow.startTime, "2026-06-01T00:00:00Z")
        XCTAssertEqual(batch.exportWindow.endTime, "2026-06-03T00:00:00Z")
        XCTAssertEqual(batch.sources, [
            HealthBridgeSource(
                sourceKey: "apple_health.phone",
                name: "Apple Health on iPhone",
                kind: .phone,
                bundleID: HealthBridgeAppIdentity.bundleIdentifier,
                deviceModel: "iPhone"
            )
        ])
        XCTAssertEqual(batch.healthTypes, [.steps])
        XCTAssertEqual(batch.samples.count, 1)
        let sample = try XCTUnwrap(batch.samples.first)
        XCTAssertEqual(sample.clientRecordID, "hk-steps-20260601")
        XCTAssertEqual(sample.sourceKey, "apple_health.phone")
        XCTAssertEqual(sample.typeCode, "steps")
        XCTAssertEqual(sample.startTime, "2026-06-01T00:00:00Z")
        XCTAssertEqual(sample.endTime, "2026-06-02T00:00:00Z")
        XCTAssertEqual(sample.value, 4321)
        XCTAssertEqual(sample.unit, "count")
        XCTAssertEqual(sample.metadata["aggregation"], "daily_sum")
        XCTAssertEqual(sample.metadata["healthkit_query"], "HKStatisticsCollectionQuery")
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_daily_steps_sync",
                cursorValue: "2026-06-03T00:00:00Z"
            )
        ])
    }

    func testFactorySortsSamplesByDayAndUsesUtcRecordIDs() throws {
        let counts = [
            DailyStepCount(
                dayStart: try date("2026-06-03T00:00:00Z"),
                dayEnd: try date("2026-06-04T00:00:00Z"),
                count: 300
            ),
            DailyStepCount(
                dayStart: try date("2026-06-01T00:00:00Z"),
                dayEnd: try date("2026-06-02T00:00:00Z"),
                count: 100
            ),
        ]

        let batch = StepCountSyncBatchFactory.makeDailyStepBatch(
            counts: counts,
            windowStart: try date("2026-06-01T00:00:00Z"),
            windowEnd: try date("2026-06-04T00:00:00Z"),
            generatedAt: try date("2026-06-08T09:30:12Z")
        )

        XCTAssertEqual(batch.samples.map(\.clientRecordID), ["hk-steps-20260601", "hk-steps-20260603"])
        XCTAssertEqual(batch.samples.map(\.value), [100, 300])
    }

    func testFactoryPreservesLocalCalendarDayForDailyActivityAggregates() throws {
        let aggregate = HealthKitDailyActivityAggregate(
            typeCode: "steps",
            dayStart: try date("2026-06-24T15:00:00Z"),
            dayEnd: try date("2026-06-25T15:00:00Z"),
            value: 9684,
            calendarDay: "2026-06-25",
            timeZoneIdentifier: "Asia/Tokyo"
        )

        let batch = try XCTUnwrap(DailyActivityAggregateSyncBatchFactory.makeDailyActivityAggregateBatch(
            aggregates: [aggregate],
            typeCodes: ["steps"],
            windowStart: try date("2026-06-24T15:00:00Z"),
            windowEnd: try date("2026-06-25T15:00:00Z"),
            generatedAt: try date("2026-06-25T15:01:00Z")
        ))

        let sample = try XCTUnwrap(batch.samples.first)
        XCTAssertEqual(sample.clientRecordID, "hk-daily-activity-steps-20260625")
        XCTAssertEqual(sample.startTime, "2026-06-24T15:00:00Z")
        XCTAssertEqual(sample.endTime, "2026-06-25T15:00:00Z")
        XCTAssertEqual(sample.metadata["calendar_day"], "2026-06-25")
        XCTAssertEqual(sample.metadata["time_zone_identifier"], "Asia/Tokyo")
        XCTAssertEqual(sample.metadata["sample_kind"], "daily_aggregate")
    }

    func testAnchoredStepBatchEmitsRawSamplesAnchorCursorAndLegacyAggregateTombstones() throws {
        let rawSampleUUID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let deletedSampleUUID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let generatedAt = try date("2026-06-08T09:30:12Z")
        let changes = HealthKitAnchoredStepChanges(
            stepSamples: [
                HealthKitStepSampleSummary(
                    uuid: rawSampleUUID,
                    start: try date("2026-06-01T08:00:00Z"),
                    end: try date("2026-06-01T08:05:00Z"),
                    count: 120,
                    provenance: HealthKitSampleProvenance(
                        sourceName: "Fixture Owner Apple Watch",
                        sourceBundleIdentifier: "com.apple.Health",
                        deviceName: "Apple Watch",
                        deviceModel: "Watch7,1",
                        deviceManufacturer: "Apple Inc."
                    )
                )
            ],
            deletedStepSamples: [
                HealthKitDeletedStepSample(
                    uuid: deletedSampleUUID,
                    deletedAt: try date("2026-06-08T09:00:00Z")
                )
            ],
            anchorCursorValue: "opaque-anchor-v1",
            windowStart: try date("2026-06-01T00:00:00Z"),
            windowEnd: try date("2026-06-08T09:00:00Z")
        )

        let batch = StepCountSyncBatchFactory.makeAnchoredStepBatch(
            changes: changes,
            generatedAt: generatedAt
        )

        XCTAssertEqual(batch.generatedAt, "2026-06-08T09:30:12Z")
        XCTAssertEqual(batch.healthTypes, [.steps])
        XCTAssertEqual(batch.samples.count, 1)
        let sample = try XCTUnwrap(batch.samples.first)
        XCTAssertEqual(sample.clientRecordID, "hk-step-sample-11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(sample.sourceKey, "apple_health.phone")
        XCTAssertEqual(sample.typeCode, "steps")
        XCTAssertEqual(sample.startTime, "2026-06-01T08:00:00Z")
        XCTAssertEqual(sample.endTime, "2026-06-01T08:05:00Z")
        XCTAssertEqual(sample.value, 120)
        XCTAssertEqual(sample.unit, "count")
        XCTAssertEqual(sample.metadata["aggregation"], "sum")
        XCTAssertEqual(sample.metadata["healthkit_query"], "HKAnchoredObjectQuery")
        XCTAssertEqual(sample.metadata["sample_kind"], "raw_quantity")
        XCTAssertEqual(sample.metadata["healthkit_source_name"], "Fixture Owner Apple Watch")
        XCTAssertEqual(sample.metadata["healthkit_source_bundle_id"], "com.apple.Health")
        XCTAssertEqual(sample.metadata["healthkit_device_model"], "Watch7,1")
        XCTAssertEqual(batch.deletedRecords, [
            HealthBridgeDeletedRecord(
                recordFamily: "sample",
                sourceKey: "apple_health.phone",
                clientRecordID: "hk-step-sample-22222222-2222-2222-2222-222222222222",
                deletedAt: "2026-06-08T09:00:00Z"
            ),
            HealthBridgeDeletedRecord(
                recordFamily: "sample",
                sourceKey: "apple_health.phone",
                clientRecordID: "hk-steps-20260601",
                deletedAt: "2026-06-08T09:30:12Z"
            ),
        ])
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "anchored_step_sync",
                cursorValue: "opaque-anchor-v1"
            )
        ])
    }

    func testAnchoredCursorPolicyRejectsMissingAndWhitespaceValues() {
        XCTAssertFalse(HealthKitAnchoredCursorPolicy.hasUsableCursorValue(nil))
        XCTAssertFalse(HealthKitAnchoredCursorPolicy.hasUsableCursorValue(""))
        XCTAssertFalse(HealthKitAnchoredCursorPolicy.hasUsableCursorValue("  \n\t"))
        XCTAssertTrue(HealthKitAnchoredCursorPolicy.hasUsableCursorValue("opaque-anchor-v1"))
    }

    func testAnchoredStepPolicyUsesBoundedBootstrapUntilAnchorExists() throws {
        let calendar = utcCalendar()
        let now = try date("2026-06-15T12:00:00Z")

        let firstRunPlan = AnchoredStepSyncPolicy.queryPlan(
            anchorCursorValue: nil,
            storedBootstrapStartValue: nil,
            now: now,
            calendar: calendar
        )
        let anchoredPlan = AnchoredStepSyncPolicy.queryPlan(
            anchorCursorValue: "existing-anchor",
            storedBootstrapStartValue: "2026-06-01T00:00:00Z",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(firstRunPlan.queryStart, try date("2026-06-08T00:00:00Z"))
        XCTAssertEqual(firstRunPlan.bootstrapStartToPersist, try date("2026-06-08T00:00:00Z"))
        XCTAssertNil(anchoredPlan.queryStart)
        XCTAssertNil(anchoredPlan.bootstrapStartToPersist)
    }

    func testAnchoredStepPolicyAllowsOneDayAutomaticBootstrap() throws {
        let calendar = utcCalendar()
        let now = try date("2026-06-15T12:00:00Z")

        let plan = AnchoredStepSyncPolicy.queryPlan(
            anchorCursorValue: nil,
            storedBootstrapStartValue: "2026-05-01T00:00:00Z",
            bootstrapLookbackDays: 1,
            clampStoredBootstrapToLookback: true,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(plan.queryStart, try date("2026-06-14T00:00:00Z"))
        XCTAssertEqual(plan.bootstrapStartToPersist, try date("2026-06-14T00:00:00Z"))
    }

    func testForegroundWindowPolicyUsesCursorWithReplayOverlap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let fallbackStart = try date("2026-06-08T00:00:00Z")
        let end = try date("2026-06-15T03:30:00Z")

        let stepStart = ForegroundSyncWindowPolicy.windowStart(
            fallbackStart: fallbackStart,
            end: end,
            cursorValue: "2026-06-14T12:34:56Z",
            replayOverlapDays: 1,
            alignToStartOfDay: true,
            calendar: calendar
        )
        let workoutStart = ForegroundSyncWindowPolicy.windowStart(
            fallbackStart: fallbackStart,
            end: end,
            cursorValue: "2026-06-14T12:34:56Z",
            replayOverlapDays: 3,
            alignToStartOfDay: false,
            calendar: calendar
        )

        XCTAssertEqual(HealthBridgeUTCFormatter.string(from: stepStart), "2026-06-13T00:00:00Z")
        XCTAssertEqual(HealthBridgeUTCFormatter.string(from: workoutStart), "2026-06-11T12:34:56Z")
    }

    func testForegroundWindowPolicyDoesNotClampValidOldCursorToFallbackWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let fallbackStart = try date("2026-06-08T00:00:00Z")
        let end = try date("2026-06-15T03:30:00Z")

        let start = ForegroundSyncWindowPolicy.windowStart(
            fallbackStart: fallbackStart,
            end: end,
            cursorValue: "2026-05-01T12:34:56Z",
            replayOverlapDays: 1,
            alignToStartOfDay: true,
            calendar: calendar
        )

        XCTAssertEqual(HealthBridgeUTCFormatter.string(from: start), "2026-04-30T00:00:00Z")
    }

    func testForegroundWindowPolicyFallsBackForMissingMalformedOrFutureCursor() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let fallbackStart = try date("2026-06-08T00:00:00Z")
        let end = try date("2026-06-15T03:30:00Z")

        let missingCursorStart = ForegroundSyncWindowPolicy.windowStart(
            fallbackStart: fallbackStart,
            end: end,
            cursorValue: nil,
            replayOverlapDays: 1,
            alignToStartOfDay: true,
            calendar: calendar
        )
        let malformedCursorStart = ForegroundSyncWindowPolicy.windowStart(
            fallbackStart: fallbackStart,
            end: end,
            cursorValue: "not-a-date",
            replayOverlapDays: 1,
            alignToStartOfDay: true,
            calendar: calendar
        )
        let cursorEqualToEndStart = ForegroundSyncWindowPolicy.windowStart(
            fallbackStart: fallbackStart,
            end: end,
            cursorValue: "2026-06-15T03:30:00Z",
            replayOverlapDays: 1,
            alignToStartOfDay: true,
            calendar: calendar
        )
        let futureCursorStart = ForegroundSyncWindowPolicy.windowStart(
            fallbackStart: fallbackStart,
            end: end,
            cursorValue: "2026-06-16T00:00:00Z",
            replayOverlapDays: 1,
            alignToStartOfDay: true,
            calendar: calendar
        )

        XCTAssertEqual(missingCursorStart, fallbackStart)
        XCTAssertEqual(malformedCursorStart, fallbackStart)
        XCTAssertEqual(cursorEqualToEndStart, fallbackStart)
        XCTAssertEqual(futureCursorStart, fallbackStart)
    }

    func testForegroundWindowPolicyTreatsNegativeReplayOverlapAsZero() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let start = ForegroundSyncWindowPolicy.windowStart(
            fallbackStart: try date("2026-06-08T00:00:00Z"),
            end: try date("2026-06-15T03:30:00Z"),
            cursorValue: "2026-06-14T12:34:56Z",
            replayOverlapDays: -2,
            alignToStartOfDay: false,
            calendar: calendar
        )

        XCTAssertEqual(HealthBridgeUTCFormatter.string(from: start), "2026-06-14T12:34:56Z")
    }

    func testForegroundUploadPolicyAllowsCursorOnlyStepBatch() throws {
        let batch = StepCountSyncBatchFactory.makeDailyStepBatch(
            counts: [],
            windowStart: try date("2026-06-01T00:00:00Z"),
            windowEnd: try date("2026-06-02T00:00:00Z"),
            generatedAt: try date("2026-06-02T00:00:01Z")
        )

        XCTAssertTrue(batch.samples.isEmpty)
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_daily_steps_sync",
                cursorValue: "2026-06-02T00:00:00Z"
            )
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }

    func testCoreLaneCursorPolicyIgnoresStoredCursorUntilRecordsWereUploaded() {
        XCTAssertNil(
            CoreLaneSyncCursorPolicy.effectiveCursorValue(
                storedCursorValue: "stale-anchor-from-empty-first-run",
                hasUploadedRecords: false
            )
        )
        XCTAssertEqual(
            CoreLaneSyncCursorPolicy.effectiveCursorValue(
                storedCursorValue: "proven-anchor",
                hasUploadedRecords: true
            ),
            "proven-anchor"
        )
    }

    func testCoreLaneCursorPolicyDoesNotSaveEmptyFirstRunCursor() {
        XCTAssertFalse(
            CoreLaneSyncCursorPolicy.shouldPersistCursor(
                uploadedRecords: false,
                hasUploadedRecords: false
            )
        )
        XCTAssertTrue(
            CoreLaneSyncCursorPolicy.shouldPersistCursor(
                uploadedRecords: true,
                hasUploadedRecords: false
            )
        )
        XCTAssertTrue(
            CoreLaneSyncCursorPolicy.shouldPersistCursor(
                uploadedRecords: false,
                hasUploadedRecords: true
            )
        )
    }

    func testCoreLaneUploadProofStoreDefaultsFalseAndPersistsProof() throws {
        let suiteName = "CoreLaneUploadProofStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "coreLaneUploadedRecords.steps")
        let store = CoreLaneUploadProofStore(userDefaults: defaults)

        XCTAssertFalse(store.hasUploadedRecords(lane: .steps, receiverBindingID: "receiver-a"))
        XCTAssertNil(defaults.object(forKey: "coreLaneUploadedRecords.steps"))

        store.markUploadedRecords(lane: .steps, receiverBindingID: "receiver-a")

        let reloaded = CoreLaneUploadProofStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.hasUploadedRecords(lane: .steps, receiverBindingID: "receiver-a"))
        XCTAssertFalse(reloaded.hasUploadedRecords(lane: .steps, receiverBindingID: "receiver-b"))
        XCTAssertFalse(reloaded.hasUploadedRecords(lane: .workouts, receiverBindingID: "receiver-a"))
        reloaded.resetAll()
        XCTAssertFalse(reloaded.hasUploadedRecords(lane: .steps, receiverBindingID: "receiver-a"))
    }
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}

private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return try XCTUnwrap(formatter.date(from: string))
}

import XCTest
@testable import HealthBridgeCompanionCore

final class GenericQuantitySyncBatchFactoryTests: XCTestCase {
    func testFactoryBuildsGenericQuantitySamplesUsingCatalogMetadata() throws {
        let heartRateID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-1111-2222-3333-444455556666"))
        let bodyMassID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-1111-2222-3333-444455556666"))
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [
                HealthKitQuantitySampleSummary(
                    uuid: bodyMassID,
                    typeCode: "body_mass",
                    start: try date("2026-06-15T07:30:00Z"),
                    end: try date("2026-06-15T07:30:00Z"),
                    value: 72.4
                ),
                HealthKitQuantitySampleSummary(
                    uuid: heartRateID,
                    typeCode: "heart_rate",
                    start: try date("2026-06-15T07:00:00Z"),
                    end: try date("2026-06-15T07:00:05Z"),
                    value: 68,
                    provenance: HealthKitSampleProvenance(
                        sourceName: "Fixture Owner Apple Watch",
                        sourceBundleIdentifier: "com.apple.Health",
                        deviceName: "Apple Watch",
                        deviceModel: "Watch7,1",
                        deviceManufacturer: "Apple Inc."
                    )
                ),
            ],
            selectedTypeCodes: ["heart_rate", "body_mass"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z")
        ))

        XCTAssertEqual(batch.generatedAt, "2026-06-16T00:01:00Z")
        XCTAssertEqual(batch.healthTypes.first { $0.typeCode == "weight" }?.category, .body)
        XCTAssertEqual(batch.healthTypes.first { $0.typeCode == "heart_rate" }?.category, .heart)
        XCTAssertEqual(batch.samples.map(\.clientRecordID), [
            "hk-quantity-heart-rate-aaaaaaaa-1111-2222-3333-444455556666",
            "hk-quantity-weight-bbbbbbbb-1111-2222-3333-444455556666",
        ])
        XCTAssertEqual(batch.samples.map(\.typeCode), ["heart_rate", "weight"])
        XCTAssertEqual(batch.samples.map(\.unit), ["bpm", "kg"])
        XCTAssertEqual(batch.samples.first?.metadata["healthkit_identifier"], "HKQuantityTypeIdentifierHeartRate")
        XCTAssertEqual(batch.samples.first?.metadata["aggregation"], "min_max_average")
        XCTAssertEqual(batch.samples.first?.metadata["healthkit_object_kind"], "quantity")
        XCTAssertEqual(batch.samples.first?.metadata["sample_kind"], "raw_quantity")
        XCTAssertEqual(batch.samples.first?.metadata["healthkit_source_name"], "Fixture Owner Apple Watch")
        XCTAssertEqual(batch.samples.first?.metadata["healthkit_device_model"], "Watch7,1")
        XCTAssertEqual(batch.sync.cursors.map(\.cursorKind), [
            "foreground_quantity_sync:heart_rate",
            "foreground_quantity_sync:weight",
        ])
        XCTAssertEqual(batch.sync.cursors.map(\.cursorValue), [
            "2026-06-16T00:00:00Z",
            "2026-06-16T00:00:00Z",
        ])
    }

    func testFactoryCanonicalizesLegacyBodyMassSelectionToWeight() throws {
        let legacyBodyMassID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-1111-2222-3333-444455556666"))
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [
                HealthKitQuantitySampleSummary(
                    uuid: legacyBodyMassID,
                    typeCode: "body_mass",
                    start: try date("2026-06-15T07:30:00Z"),
                    end: try date("2026-06-15T07:30:00Z"),
                    value: 72.4
                ),
            ],
            selectedTypeCodes: ["weight", "body_mass"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z")
        ))

        XCTAssertEqual(batch.healthTypes.map(\.typeCode), ["weight"])
        XCTAssertEqual(batch.samples.map(\.typeCode), ["weight"])
        XCTAssertEqual(batch.samples.map(\.clientRecordID), [
            "hk-quantity-weight-bbbbbbbb-1111-2222-3333-444455556666",
        ])
        XCTAssertEqual(batch.sync.cursors.map(\.cursorKind), [
            "foreground_quantity_sync:weight",
        ])
    }

    func testFactoryCategorizesBodyProfileMetadataAsBody() throws {
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [],
            selectedTypeCodes: ["height", "weight", "body_mass_index", "lean_body_mass", "waist_circumference"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z")
        ))

        let categoriesByTypeCode = Dictionary(uniqueKeysWithValues: batch.healthTypes.map { ($0.typeCode, $0.category) })
        XCTAssertEqual(categoriesByTypeCode["height"], .body)
        XCTAssertEqual(categoriesByTypeCode["weight"], .body)
        XCTAssertEqual(categoriesByTypeCode["body_mass_index"], .body)
        XCTAssertEqual(categoriesByTypeCode["lean_body_mass"], .body)
        XCTAssertEqual(categoriesByTypeCode["waist_circumference"], .body)
    }

    func testFactoryPreservesCatalogCategoriesForExpandedQuantities() throws {
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [],
            selectedTypeCodes: ["blood_glucose", "body_temperature", "distance_cycling"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z")
        ))

        let categoriesByTypeCode = Dictionary(uniqueKeysWithValues: batch.healthTypes.map { ($0.typeCode, $0.category) })
        XCTAssertEqual(categoriesByTypeCode["blood_glucose"], .heart)
        XCTAssertEqual(categoriesByTypeCode["body_temperature"], .body)
        XCTAssertEqual(categoriesByTypeCode["distance_cycling"], .activity)
    }

    func testFactoryExtendsWindowToEarliestReturnedSampleForFullHistoryReads() throws {
        let historicalWeight = HealthKitQuantitySampleSummary(
            uuid: UUID(uuidString: "AAAAAAAA-1111-2222-3333-444455556666")!,
            typeCode: "weight",
            start: try date("2026-05-01T00:00:00Z"),
            end: try date("2026-05-01T00:00:00Z"),
            value: 72
        )
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [historicalWeight],
            selectedTypeCodes: ["weight"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-20T00:00:00Z"),
            generatedAt: try date("2026-06-20T00:01:00Z")
        ))

        XCTAssertEqual(batch.exportWindow.startTime, "2026-05-01T00:00:00Z")
        XCTAssertEqual(batch.sync.syncWindow.startTime, "2026-05-01T00:00:00Z")
        XCTAssertEqual(batch.samples.first?.startTime, "2026-05-01T00:00:00Z")
    }

    func testFactoryBuildsCursorOnlyBatchForSelectedQuantityTypes() throws {
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [],
            selectedTypeCodes: ["heart_rate"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z")
        ))

        XCTAssertTrue(batch.samples.isEmpty)
        XCTAssertEqual(batch.healthTypes.map(\.typeCode), ["heart_rate"])
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_quantity_sync:heart_rate",
                cursorValue: "2026-06-16T00:00:00Z"
            )
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }

    func testFactoryDropsUnknownNonQuantityAndInvalidSamples() throws {
        let validID = try XCTUnwrap(UUID(uuidString: "CCCCCCCC-1111-2222-3333-444455556666"))
        let unknownID = try XCTUnwrap(UUID(uuidString: "DDDDDDDD-1111-2222-3333-444455556666"))
        let sleepID = try XCTUnwrap(UUID(uuidString: "EEEEEEEE-1111-2222-3333-444455556666"))
        let invalidID = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-1111-2222-3333-444455556666"))

        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [
                HealthKitQuantitySampleSummary(
                    uuid: unknownID,
                    typeCode: "unknown_metric",
                    start: try date("2026-06-15T07:00:00Z"),
                    end: try date("2026-06-15T07:00:01Z"),
                    value: 1
                ),
                HealthKitQuantitySampleSummary(
                    uuid: sleepID,
                    typeCode: "sleep_analysis",
                    start: try date("2026-06-15T07:00:00Z"),
                    end: try date("2026-06-15T07:00:01Z"),
                    value: 1
                ),
                HealthKitQuantitySampleSummary(
                    uuid: invalidID,
                    typeCode: "heart_rate",
                    start: try date("2026-06-15T07:00:10Z"),
                    end: try date("2026-06-15T07:00:00Z"),
                    value: 70
                ),
                HealthKitQuantitySampleSummary(
                    uuid: validID,
                    typeCode: "heart_rate",
                    start: try date("2026-06-15T07:00:00Z"),
                    end: try date("2026-06-15T07:00:01Z"),
                    value: 70
                ),
            ],
            selectedTypeCodes: ["heart_rate", "sleep_analysis", "unknown_metric"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z")
        ))

        XCTAssertEqual(batch.healthTypes.map(\.typeCode), ["heart_rate"])
        XCTAssertEqual(batch.samples.map(\.clientRecordID), [
            "hk-quantity-heart-rate-cccccccc-1111-2222-3333-444455556666",
        ])
    }

    func testDailyActivityAggregatePolicyIncludesStandTime() {
        XCTAssertTrue(DailyActivityAggregateSyncPolicy.defaultTypeCodes.contains("stand_time"))
    }

    func testDailyActivityAggregateFactoryLabelsHealthKitStatisticsTotals() throws {
        let batch = try XCTUnwrap(DailyActivityAggregateSyncBatchFactory.makeDailyActivityAggregateBatch(
            aggregates: [
                HealthKitDailyActivityAggregate(
                    typeCode: "steps",
                    dayStart: try date("2026-06-28T00:00:00Z"),
                    dayEnd: try date("2026-06-29T00:00:00Z"),
                    value: 11824
                ),
                HealthKitDailyActivityAggregate(
                    typeCode: "active_energy",
                    dayStart: try date("2026-06-28T00:00:00Z"),
                    dayEnd: try date("2026-06-29T00:00:00Z"),
                    value: 533
                ),
                HealthKitDailyActivityAggregate(
                    typeCode: "heart_rate",
                    dayStart: try date("2026-06-28T00:00:00Z"),
                    dayEnd: try date("2026-06-29T00:00:00Z"),
                    value: 67
                ),
            ],
            windowStart: try date("2026-06-28T00:00:00Z"),
            windowEnd: try date("2026-06-29T00:00:00Z"),
            generatedAt: try date("2026-06-29T00:05:00Z")
        ))

        XCTAssertEqual(batch.generatedAt, "2026-06-29T00:05:00Z")
        XCTAssertEqual(batch.samples.map(\.clientRecordID), [
            "hk-daily-activity-energy-20260628",
            "hk-daily-activity-steps-20260628",
        ])
        XCTAssertEqual(batch.samples.map(\.typeCode), ["energy", "steps"])
        XCTAssertEqual(batch.samples.map(\.value), [533, 11824])
        let energySample = try XCTUnwrap(batch.samples.first)
        XCTAssertEqual(energySample.metadata["aggregation"], "daily_sum")
        XCTAssertEqual(energySample.metadata["sample_kind"], "daily_aggregate")
        XCTAssertEqual(energySample.metadata["source_resolution"], "healthkit_statistics_merged_sources")
        XCTAssertEqual(energySample.metadata["healthkit_query"], "HKStatisticsCollectionQuery")
        XCTAssertEqual(energySample.metadata["daily_activity_semantics"], "healthkit_statistics_collection")
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: DailyActivityAggregateSyncPolicy.cursorKind,
                cursorValue: "2026-06-29T00:00:00Z"
            )
        ])
    }

    func testDailyActivityAggregateFactoryReturnsNilWhenNoAggregateTypesAreValid() throws {
        XCTAssertNil(DailyActivityAggregateSyncBatchFactory.makeDailyActivityAggregateBatch(
            aggregates: [],
            typeCodes: ["heart_rate"],
            windowStart: try date("2026-06-28T00:00:00Z"),
            windowEnd: try date("2026-06-29T00:00:00Z"),
            generatedAt: try date("2026-06-29T00:05:00Z")
        ))
    }

    func testFactoryReturnsNilWhenNoSelectedQuantityTypesAreValid() throws {
        XCTAssertNil(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [],
            selectedTypeCodes: [],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z")
        ))
        XCTAssertNil(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [],
            selectedTypeCodes: ["sleep_analysis", "unknown_metric"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z")
        ))
    }

    func testFactorySplitsLargeQuantityUploadsAndCarriesCursorOnlyOnFinalChunk() throws {
        let samples: [HealthKitQuantitySampleSummary] = try (0..<5).map { index in
            HealthKitQuantitySampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-1111-2222-3333-44445555666\(index)")),
                typeCode: "heart_rate",
                start: try date("2026-06-15T07:0\(index):00Z"),
                end: try date("2026-06-15T07:0\(index):05Z"),
                value: Double(60 + index)
            )
        }

        let batches: [HealthBridgeBatchV1] = GenericQuantitySyncBatchFactory.makeQuantityBatches(
            samples: samples,
            selectedTypeCodes: ["heart_rate"],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:01:00Z"),
            maxSamplesPerBatch: 2
        )

        XCTAssertEqual(batches.map(\.samples.count), [2, 2, 1])
        XCTAssertEqual(batches.flatMap { $0.samples.map(\.value) }, [60, 61, 62, 63, 64])
        XCTAssertEqual(batches.map { $0.healthTypes.map(\.typeCode) }, [
            ["heart_rate"], ["heart_rate"], ["heart_rate"],
        ])
        XCTAssertEqual(batches[0].sync.cursors, [] as [HealthBridgeSyncCursor])
        XCTAssertEqual(batches[1].sync.cursors, [] as [HealthBridgeSyncCursor])
        XCTAssertEqual(batches[2].sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_quantity_sync:heart_rate",
                cursorValue: "2026-06-16T00:00:00Z"
            ),
        ])
    }

    func testForegroundPolicyExposesSelectedEntriesForAppDisplayNames() throws {
        let plan = try XCTUnwrap(GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: ["body_mass", "heart_rate", "unknown_metric"],
            cursorValuesByTypeCode: [:],
            now: try date("2026-06-16T12:00:00Z"),
            calendar: utcCalendar()
        ))

        XCTAssertEqual(plan.selectedEntries.map(\.typeCode), ["heart_rate", "weight"])
        XCTAssertEqual(plan.selectedEntries.map(\.displayName), ["Heart Rate", "Weight"])
    }

    func testForegroundPolicyResumesStaleHighVolumeCursorWithoutGap() throws {
        let now = try date("2026-06-16T12:00:00Z")
        let plan = try XCTUnwrap(GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: ["heart_rate", "steps", "weight", "unknown_metric"],
            cursorValuesByTypeCode: [
                "heart_rate": "2026-06-01T00:00:00Z",
            ],
            historyDepth: .allAvailable,
            now: now,
            calendar: utcCalendar()
        ))

        XCTAssertEqual(plan.selectedTypeCodes, ["heart_rate", "weight"])
        XCTAssertEqual(plan.maximumForegroundWindowDaysByTypeCode, [
            "heart_rate": 1,
            "weight": nil,
        ])
        XCTAssertEqual(plan.windowStart, try date("2026-05-31T23:45:00Z"))
        XCTAssertEqual(plan.windowEnd, now)
        XCTAssertEqual(plan.windowStartsByTypeCode["heart_rate"]!, try date("2026-05-31T23:45:00Z"))
        XCTAssertNil(plan.windowStartsByTypeCode["weight"]!)
        XCTAssertEqual(plan.cursorKindsByTypeCode, [
            "heart_rate": "foreground_quantity_sync:heart_rate",
            "weight": "foreground_quantity_sync:weight",
        ])
    }

    func testAutomaticOneDayFallbackDoesNotClampValidStaleCursor() throws {
        let now = try date("2026-06-16T12:00:00Z")
        let plan = try XCTUnwrap(GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: ["heart_rate", "energy"],
            cursorValuesByTypeCode: [
                "heart_rate": "2026-06-01T00:00:00Z",
                "energy": "2026-06-10T06:00:00Z",
            ],
            historyDepth: .lastDays(1),
            now: now,
            calendar: utcCalendar()
        ))

        XCTAssertEqual(plan.windowStart, try date("2026-05-31T23:45:00Z"))
        XCTAssertEqual(plan.windowStartsByTypeCode["heart_rate"]!, try date("2026-05-31T23:45:00Z"))
        XCTAssertEqual(plan.windowStartsByTypeCode["energy"]!, try date("2026-06-10T05:45:00Z"))
    }

    func testForegroundPolicyUsesEarliestClampedReplayStartAcrossLowVolumeSelections() throws {
        let now = try date("2026-06-16T12:00:00Z")
        let plan = try XCTUnwrap(GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: ["energy", "distance_walking_running"],
            cursorValuesByTypeCode: [
                "energy": "2026-06-15T10:00:00Z",
                "distance_walking_running": "2026-06-16T08:00:00Z",
            ],
            now: now,
            calendar: utcCalendar()
        ))

        XCTAssertEqual(plan.selectedTypeCodes, ["distance_walking_running", "energy"])
        XCTAssertEqual(plan.maximumForegroundWindowDays, 7)
        XCTAssertEqual(plan.windowStart, try date("2026-06-15T09:45:00Z"))
        XCTAssertEqual(plan.windowStartsByTypeCode, [
            "energy": try date("2026-06-15T09:45:00Z"),
            "distance_walking_running": try date("2026-06-16T07:45:00Z"),
        ])
    }

    func testForegroundPolicyBoundsNonSparseMetricsEvenWhenHistoryDepthIsAllAvailable() throws {
        let now = try date("2026-06-16T12:00:00Z")
        let plan = try XCTUnwrap(GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: ["energy", "weight"],
            cursorValuesByTypeCode: [:],
            historyDepth: .allAvailable,
            now: now,
            calendar: utcCalendar()
        ))

        XCTAssertEqual(plan.maximumForegroundWindowDaysByTypeCode, [
            "energy": 7,
            "weight": nil,
        ])
        XCTAssertEqual(plan.windowStart, try date("2026-06-09T12:00:00Z"))
        XCTAssertEqual(plan.windowStartsByTypeCode["energy"]!, try date("2026-06-09T12:00:00Z"))
        XCTAssertNil(plan.windowStartsByTypeCode["weight"]!)
    }

    func testForegroundPolicyIgnoresSparseAllAvailableCursorsForHistoricalBackfill() throws {
        let now = try date("2026-06-22T12:00:00Z")
        let plan = try XCTUnwrap(GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: ["weight"],
            cursorValuesByTypeCode: [
                "weight": "2026-06-20T06:10:00Z",
                "body_mass": "2026-06-20T06:10:00Z",
            ],
            historyDepth: .allAvailable,
            now: now,
            calendar: utcCalendar()
        ))

        XCTAssertEqual(plan.selectedTypeCodes, ["weight"])
        XCTAssertEqual(plan.maximumForegroundWindowDaysByTypeCode, ["weight": nil])
        XCTAssertNil(plan.windowStartsByTypeCode["weight"]!)
    }

    func testForegroundPolicyUsesHistoryDepthLowerBoundForLastDaysSelections() throws {
        let now = try date("2026-06-16T12:00:00Z")
        let plan = try XCTUnwrap(GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: ["energy", "weight"],
            cursorValuesByTypeCode: [:],
            historyDepth: .lastDays(30),
            now: now,
            calendar: utcCalendar()
        ))

        XCTAssertEqual(plan.maximumForegroundWindowDaysByTypeCode, [
            "energy": 30,
            "weight": 30,
        ])
        XCTAssertEqual(plan.windowStart, try date("2026-05-17T00:00:00Z"))
        XCTAssertEqual(plan.windowStartsByTypeCode["energy"]!, try date("2026-05-17T00:00:00Z"))
        XCTAssertEqual(plan.windowStartsByTypeCode["weight"]!, try date("2026-05-17T00:00:00Z"))
    }

    func testForegroundPolicyReturnsNilWithoutOptionalQuantitySelection() throws {
        XCTAssertNil(GenericQuantityForegroundSyncPolicy.queryPlan(
            selectedTypeCodes: ["steps", "sleep_analysis", "unknown_metric"],
            cursorValuesByTypeCode: [:],
            now: try date("2026-06-16T12:00:00Z"),
            calendar: utcCalendar()
        ))
    }

    func testForegroundPolicyAdvancesSampleTypesAndSuccessfulNoChangeTypesWithExistingCursor() throws {
        let heartRateID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-1111-2222-3333-444455556666"))
        let activeEnergyID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-1111-2222-3333-444455556666"))
        let readEnd = try date("2026-06-16T00:00:00Z")
        let typeCodes = GenericQuantityForegroundSyncPolicy.cursorAdvanceTypeCodes(
            samples: [
                HealthKitQuantitySampleSummary(
                    uuid: heartRateID,
                    typeCode: "heart_rate",
                    start: try date("2026-06-15T07:00:00Z"),
                    end: try date("2026-06-15T07:00:05Z"),
                    value: 68
                ),
                HealthKitQuantitySampleSummary(
                    uuid: activeEnergyID,
                    typeCode: "energy",
                    start: try date("2026-06-15T07:00:00Z"),
                    end: try date("2026-06-15T07:30:00Z"),
                    value: 120
                ),
            ],
            selectedTypeCodes: ["heart_rate", "body_mass", "energy"],
            cursorValuesByTypeCode: ["weight": "2026-06-15T07:00:00Z"],
            successfulReadEnd: readEnd
        )

        XCTAssertEqual(typeCodes, ["energy", "heart_rate", "weight"])
        XCTAssertEqual(
            GenericQuantityForegroundSyncPolicy.cursorAdvanceTypeCodes(
                samples: [],
                selectedTypeCodes: ["heart_rate"],
                cursorValuesByTypeCode: [:],
                successfulReadEnd: readEnd
            ),
            []
        )
        XCTAssertEqual(
            GenericQuantityForegroundSyncPolicy.cursorAdvanceTypeCodes(
                samples: [],
                selectedTypeCodes: ["heart_rate"],
                cursorValuesByTypeCode: ["heart_rate": "2026-06-15T07:00:00Z"],
                successfulReadEnd: readEnd
            ),
            ["heart_rate"]
        )
        XCTAssertEqual(
            GenericQuantityForegroundSyncPolicy.cursorAdvanceTypeCodes(
                samples: [],
                selectedTypeCodes: ["heart_rate", "weight"],
                cursorValuesByTypeCode: [
                    "heart_rate": "malformed",
                    "weight": "2026-06-17T00:00:00Z",
                ],
                successfulReadEnd: readEnd
            ),
            []
        )
    }

    func testAutomaticQuantityReadAdvancesOnlyTypesWithUsableExistingCursors() throws {
        let readEnd = try date("2026-06-16T00:00:00Z")
        let samples = [
            HealthKitQuantitySampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "CCCCCCCC-1111-2222-3333-444455556666")),
                typeCode: "heart_rate",
                start: try date("2026-06-15T07:00:00Z"),
                end: try date("2026-06-15T07:00:05Z"),
                value: 68
            ),
            HealthKitQuantitySampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "DDDDDDDD-1111-2222-3333-444455556666")),
                typeCode: "energy",
                start: try date("2026-06-15T07:00:00Z"),
                end: try date("2026-06-15T07:30:00Z"),
                value: 120
            ),
        ]

        XCTAssertEqual(
            GenericQuantityForegroundSyncPolicy.cursorAdvanceTypeCodes(
                samples: samples,
                selectedTypeCodes: ["heart_rate", "energy"],
                cursorValuesByTypeCode: ["energy": "2026-06-15T06:00:00Z"],
                successfulReadEnd: readEnd,
                allowNewCursorCreation: false
            ),
            ["energy"]
        )
        XCTAssertEqual(
            GenericQuantityForegroundSyncPolicy.cursorAdvanceTypeCodes(
                samples: samples,
                selectedTypeCodes: ["heart_rate", "energy"],
                cursorValuesByTypeCode: [:],
                successfulReadEnd: readEnd,
                allowNewCursorCreation: false
            ),
            []
        )
    }

    func testFactoryCanUploadCursorlessSamplesWithoutCommittingProgress() throws {
        let batches = GenericQuantitySyncBatchFactory.makeQuantityBatches(
            samples: [
                HealthKitQuantitySampleSummary(
                    uuid: try XCTUnwrap(UUID(uuidString: "EEEEEEEE-1111-2222-3333-444455556666")),
                    typeCode: "heart_rate",
                    start: try date("2026-06-15T07:00:00Z"),
                    end: try date("2026-06-15T07:00:05Z"),
                    value: 68
                ),
            ],
            selectedTypeCodes: ["heart_rate"],
            cursorTypeCodes: [],
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z")
        )

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].samples.count, 1)
        XCTAssertEqual(batches[0].sync.cursors, [])
    }

    func testAnchoredQuantityFactoryUsesCanonicalPerTypeAnchorAndStableClientIDs() throws {
        let activeID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-1111-2222-3333-444455556666"))
        let deletedID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-1111-2222-3333-444455556666"))
        let changes = HealthKitAnchoredQuantityChanges(
            typeCode: "body_mass",
            samples: [
                HealthKitQuantitySampleSummary(
                    uuid: activeID,
                    typeCode: "body_mass",
                    start: try date("2026-06-15T07:30:00Z"),
                    end: try date("2026-06-15T07:30:00Z"),
                    value: 72.4,
                    provenance: HealthKitSampleProvenance(
                        sourceName: "Synthetic Watch",
                        sourceBundleIdentifier: "com.example.synthetic",
                        deviceName: "Synthetic Watch",
                        deviceModel: "Synthetic1,1",
                        deviceManufacturer: "Example"
                    )
                ),
            ],
            deletedSamples: [
                HealthKitDeletedQuantitySample(
                    uuid: deletedID,
                    typeCode: "body_mass",
                    deletedAt: try date("2026-06-16T00:00:00Z")
                ),
            ],
            anchorCursorValue: "opaque-weight-anchor",
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z")
        )

        let batch = try XCTUnwrap(
            GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(changes: changes).first
        )

        XCTAssertEqual(batch.healthTypes.map(\.typeCode), ["weight"])
        XCTAssertEqual(batch.samples.map(\.clientRecordID), [
            "hk-quantity-weight-aaaaaaaa-1111-2222-3333-444455556666",
        ])
        XCTAssertEqual(batch.samples.first?.metadata["healthkit_query"], "HKAnchoredObjectQuery")
        XCTAssertEqual(batch.samples.first?.metadata["healthkit_source_name"], "Synthetic Watch")
        XCTAssertEqual(batch.deletedRecords, [
            HealthBridgeDeletedRecord(
                recordFamily: "sample",
                sourceKey: "apple_health.phone",
                clientRecordID: "hk-quantity-weight-bbbbbbbb-1111-2222-3333-444455556666",
                deletedAt: "2026-06-16T00:00:00Z"
            ),
        ])
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "healthkit_anchored_quantity:weight",
                cursorValue: "opaque-weight-anchor"
            ),
        ])
    }

    func testAnchoredQuantityFactoryPlacesAnchorOnlyOnFinalOrderedChunk() throws {
        let samples = try (0..<3).map { index in
            HealthKitQuantitySampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-1111-2222-3333-44445555666\(index)")),
                typeCode: "heart_rate",
                start: try date("2026-06-15T07:0\(index):00Z"),
                end: try date("2026-06-15T07:0\(index):05Z"),
                value: Double(60 + index)
            )
        }
        let changes = HealthKitAnchoredQuantityChanges(
            typeCode: "heart_rate",
            samples: samples,
            deletedSamples: [],
            anchorCursorValue: "opaque-heart-rate-anchor",
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z")
        )

        let batches = GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(
            changes: changes,
            maxSamplesPerBatch: 2
        )

        XCTAssertEqual(batches.map(\.samples.count), [2, 1])
        XCTAssertTrue(batches[0].sync.cursors.isEmpty)
        XCTAssertEqual(batches[1].sync.cursors.map(\.cursorKind), [
            "healthkit_anchored_quantity:heart_rate",
        ])
    }

    func testAnchoredQuantityFactoryBuildsAnchorOnlyUpload() throws {
        let changes = HealthKitAnchoredQuantityChanges(
            typeCode: "heart_rate",
            samples: [],
            deletedSamples: [],
            anchorCursorValue: "opaque-heart-rate-anchor",
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z")
        )

        let batch = try XCTUnwrap(
            GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(changes: changes).first
        )

        XCTAssertTrue(batch.samples.isEmpty)
        XCTAssertTrue(batch.deletedRecords.isEmpty)
        XCTAssertEqual(batch.sync.cursors.map(\.cursorKind), [
            "healthkit_anchored_quantity:heart_rate",
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }

    func testAnchoredQuantityBootstrapUsesHistoryPredicateAndLegacyTimestampOnlyToAvoidMigrationGap() throws {
        let now = try date("2026-06-16T12:00:00Z")
        let bounded = try XCTUnwrap(GenericQuantityAnchoredSyncPolicy.queryPlan(
            typeCode: "heart_rate",
            anchorCursorValue: nil,
            legacyTimestampCursorValue: "2026-06-15T18:00:00Z",
            historyDepth: .lastDays(1),
            now: now,
            calendar: utcCalendar()
        ))
        let anchored = try XCTUnwrap(GenericQuantityAnchoredSyncPolicy.queryPlan(
            typeCode: "body_mass",
            anchorCursorValue: "opaque-weight-anchor",
            legacyTimestampCursorValue: "2026-06-01T00:00:00Z",
            historyDepth: .lastDays(30),
            now: now,
            calendar: utcCalendar()
        ))

        XCTAssertEqual(bounded.canonicalTypeCode, "heart_rate")
        XCTAssertEqual(bounded.anchorCursorKind, "healthkit_anchored_quantity:heart_rate")
        XCTAssertEqual(bounded.predicateStart, try date("2026-06-15T12:00:00Z"))
        XCTAssertEqual(anchored.canonicalTypeCode, "weight")
        XCTAssertEqual(anchored.anchorCursorKind, "healthkit_anchored_quantity:weight")
        XCTAssertNil(anchored.predicateStart)
    }

    func testAnchoredQuantityBootstrapKeepsEarlierLegacyProgressWhenItAvoidsAGap() throws {
        let plan = try XCTUnwrap(GenericQuantityAnchoredSyncPolicy.queryPlan(
            typeCode: "energy",
            anchorCursorValue: nil,
            legacyTimestampCursorValue: "2026-06-10T06:00:00Z",
            historyDepth: .lastDays(1),
            now: try date("2026-06-16T12:00:00Z"),
            calendar: utcCalendar()
        ))

        XCTAssertEqual(plan.predicateStart, try date("2026-06-10T05:45:00Z"))
    }

    func testAnchoredQuantityProgressRequiresSuccessfulReadAndDurableDelivery() {
        XCTAssertTrue(GenericQuantityAnchoredProgressPolicy.shouldPersistAnchor(
            readSucceeded: true,
            delivery: .uploaded
        ))
        XCTAssertTrue(GenericQuantityAnchoredProgressPolicy.shouldPersistAnchor(
            readSucceeded: true,
            delivery: .durablyQueued
        ))
        XCTAssertFalse(GenericQuantityAnchoredProgressPolicy.shouldPersistAnchor(
            readSucceeded: false,
            delivery: .uploaded
        ))
        XCTAssertFalse(GenericQuantityAnchoredProgressPolicy.shouldPersistAnchor(
            readSucceeded: true,
            delivery: .failed
        ))
        XCTAssertFalse(GenericQuantityAnchoredProgressPolicy.shouldPersistAnchor(
            readSucceeded: true,
            delivery: .nonDurablyQueued
        ))
    }

    func testAnchoredQuantityProgressRequiresReadableProofBeforeCreatingFirstAnchor() {
        XCTAssertFalse(GenericQuantityAnchoredProgressPolicy.shouldIncludeAnchor(
            canPersistSharedProgress: true,
            hadUsableAnchor: false,
            activeSampleCount: 0,
            deletedSampleCount: 0
        ))
        XCTAssertTrue(GenericQuantityAnchoredProgressPolicy.shouldIncludeAnchor(
            canPersistSharedProgress: true,
            hadUsableAnchor: false,
            activeSampleCount: 1,
            deletedSampleCount: 0
        ))
        XCTAssertTrue(GenericQuantityAnchoredProgressPolicy.shouldIncludeAnchor(
            canPersistSharedProgress: true,
            hadUsableAnchor: true,
            activeSampleCount: 0,
            deletedSampleCount: 0
        ))
        XCTAssertFalse(GenericQuantityAnchoredProgressPolicy.shouldIncludeAnchor(
            canPersistSharedProgress: false,
            hadUsableAnchor: false,
            activeSampleCount: 1,
            deletedSampleCount: 0
        ))
    }

    func testAnchoredQuantityMigrationReadsCanonicalAndLegacyAliasCursors() {
        XCTAssertEqual(
            GenericQuantityAnchoredSyncPolicy.legacyTimestampCursorKinds(for: "energy"),
            [
                "foreground_quantity_sync:energy",
                "foreground_quantity_sync:active_energy",
            ]
        )
        XCTAssertEqual(
            GenericQuantityAnchoredSyncPolicy.legacyTimestampCursorKinds(for: "weight"),
            [
                "foreground_quantity_sync:weight",
                "foreground_quantity_sync:body_mass",
            ]
        )
        XCTAssertEqual(
            GenericQuantityAnchoredSyncPolicy.earliestUsableTimestampCursorValue([
                "invalid",
                "2026-06-15T18:00:00Z",
                "2026-06-10T06:00:00Z",
            ]),
            "2026-06-10T06:00:00Z"
        )
    }

    func testAnchoredQuantityFactoryChunksDeletionsWithinRecordLimit() throws {
        let deletedSamples = try (0..<3).map { index in
            HealthKitDeletedQuantitySample(
                uuid: try XCTUnwrap(UUID(uuidString: "BBBBBBBB-1111-2222-3333-44445555666\(index)")),
                typeCode: "heart_rate",
                deletedAt: try date("2026-06-16T00:0\(index):00Z")
            )
        }
        let changes = HealthKitAnchoredQuantityChanges(
            typeCode: "heart_rate",
            samples: [],
            deletedSamples: deletedSamples,
            anchorCursorValue: "opaque-heart-rate-anchor",
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T01:00:00Z")
        )

        let batches = GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(
            changes: changes,
            maxSamplesPerBatch: 2
        )

        XCTAssertEqual(batches.map(\.deletedRecords.count), [2, 1])
        XCTAssertEqual(batches.map { $0.samples.count + $0.deletedRecords.count }, [2, 1])
        XCTAssertTrue(batches[0].sync.cursors.isEmpty)
        XCTAssertEqual(batches[1].sync.cursors.map(\.cursorKind), [
            "healthkit_anchored_quantity:heart_rate",
        ])
    }

    func testAnchoredQuantityFactorySharesRecordLimitAcrossSamplesAndDeletions() throws {
        let samples = try (0..<2).map { index in
            HealthKitQuantitySampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-1111-2222-3333-44445555666\(index)")),
                typeCode: "heart_rate",
                start: try date("2026-06-15T07:0\(index):00Z"),
                end: try date("2026-06-15T07:0\(index):05Z"),
                value: Double(60 + index)
            )
        }
        let deletedSamples = try (0..<2).map { index in
            HealthKitDeletedQuantitySample(
                uuid: try XCTUnwrap(UUID(uuidString: "BBBBBBBB-1111-2222-3333-44445555666\(index)")),
                typeCode: "heart_rate",
                deletedAt: try date("2026-06-16T00:0\(index):00Z")
            )
        }
        let changes = HealthKitAnchoredQuantityChanges(
            typeCode: "heart_rate",
            samples: samples,
            deletedSamples: deletedSamples,
            anchorCursorValue: "opaque-heart-rate-anchor",
            windowStart: try date("2026-06-15T00:00:00Z"),
            windowEnd: try date("2026-06-16T01:00:00Z")
        )

        let batches = GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(
            changes: changes,
            maxSamplesPerBatch: 3
        )

        XCTAssertEqual(batches.map(\.samples.count), [2, 0])
        XCTAssertEqual(batches.map(\.deletedRecords.count), [1, 1])
        XCTAssertEqual(batches.map { $0.samples.count + $0.deletedRecords.count }, [3, 1])
        XCTAssertTrue(batches[0].sync.cursors.isEmpty)
        XCTAssertFalse(batches[1].sync.cursors.isEmpty)
    }

    private func date(_ string: String) throws -> Date {
        try XCTUnwrap(HealthBridgeUTCFormatter.date(from: string))
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

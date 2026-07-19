import XCTest
@testable import HealthBridgeCompanionCore

final class BackgroundSyncTests: XCTestCase {
    func testLastRunUserVisibleSummaryDoesNotIncludePersistedDetails() {
        let lastRun = BackgroundSyncLastRun(
            startedAt: "2026-07-15T00:00:00Z",
            finishedAt: "2026-07-15T00:01:00Z",
            succeeded: false,
            summary: "Receiver said Bearer synthetic-legacy-secret"
        )

        XCTAssertEqual(
            lastRun.userVisibleSummary,
            "Last background sync did not complete."
        )
        XCTAssertFalse(lastRun.userVisibleSummary.contains("synthetic-legacy-secret"))
    }

    func testExecutionModeKeepsAuthorizationForegroundOnlyAndAutomaticFallbackOneDay() {
        XCTAssertTrue(HealthBridgeSyncExecutionMode.foreground.shouldRequestReadAuthorization)
        XCTAssertNil(HealthBridgeSyncExecutionMode.foreground.cursorlessFallbackDays)
        XCTAssertFalse(HealthBridgeSyncExecutionMode.automatic.shouldRequestReadAuthorization)
        XCTAssertEqual(HealthBridgeSyncExecutionMode.automatic.cursorlessFallbackDays, 1)
    }

    func testBackgroundSyncDefaultsToDisabledAndPersistsEnabledState() throws {
        let suiteName = "HealthBridgeBackgroundSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)

        XCTAssertFalse(store.isEnabled)

        store.setEnabled(true)

        let reloaded = BackgroundSyncSettingsStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)
    }

    func testBackgroundSyncDurablyPersistsDisabledStateBeforeReload() throws {
        let suiteName = "HealthBridgeBackgroundSyncDurableTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        try store.setEnabledDurably(false)

        let reloaded = BackgroundSyncSettingsStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.isEnabled)
    }

    func testDurableDisableIntentMarkerOverridesStaleEnabledPreferenceAcrossReload() throws {
        let suiteName = "HealthBridgeBackgroundSyncDisableIntentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).disable-intent")
        let markerStore = FileBackgroundSyncDisableIntentStore(fileURL: markerURL)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: markerURL)
        }
        defaults.set(true, forKey: "healthBridge.backgroundSync.enabled")
        try markerStore.markDisableIntentPending()

        let reloaded = BackgroundSyncSettingsStore(
            userDefaults: defaults,
            disableIntentStore: markerStore
        )
        XCTAssertFalse(reloaded.isEnabled)

        try reloaded.setEnabledDurably(true)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertFalse(markerStore.isDisableIntentPending)

        try reloaded.setEnabledDurably(false)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertTrue(markerStore.isDisableIntentPending)
    }

    func testBackgroundSyncStoresLastRunMetadataAsISO8601() throws {
        let suiteName = "HealthBridgeBackgroundSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        let startedAt = Date(timeIntervalSince1970: 1_780_012_800)
        let finishedAt = Date(timeIntervalSince1970: 1_780_012_860)

        store.recordRun(
            startedAt: startedAt,
            finishedAt: finishedAt,
            succeeded: true,
            summary: "Background refresh completed: steps=ok"
        )

        let lastRun = try XCTUnwrap(store.lastRun)
        XCTAssertEqual(lastRun.startedAt, "2026-05-29T00:00:00Z")
        XCTAssertEqual(lastRun.finishedAt, "2026-05-29T00:01:00Z")
        XCTAssertTrue(lastRun.succeeded)
        XCTAssertEqual(lastRun.summary, "Background refresh completed: steps=ok")
    }

    func testBackgroundSyncStoresBackgroundDeliveryRegistrationDiagnostics() throws {
        let suiteName = "HealthBridgeBackgroundSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        let attemptedAt = Date(timeIntervalSince1970: 1_780_013_100)

        store.recordRegistration(
            at: attemptedAt,
            succeeded: false,
            summary: "HealthKit background delivery registration 0/3 enabled, 3 failed"
        )

        let registration = try XCTUnwrap(store.lastRegistration)
        XCTAssertEqual(registration.attemptedAt, "2026-05-29T00:05:00Z")
        XCTAssertFalse(registration.succeeded)
        XCTAssertEqual(
            registration.summary,
            "HealthKit background delivery registration 0/3 enabled, 3 failed"
        )
    }

    func testBackgroundSyncStoresTaskScheduleAndWakeDiagnostics() throws {
        let suiteName = "HealthBridgeBackgroundSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        let scheduledAt = Date(timeIntervalSince1970: 1_780_013_400)
        let enteredAt = Date(timeIntervalSince1970: 1_780_013_760)

        store.recordTaskSchedule(
            at: scheduledAt,
            status: "submitted",
            summary: "BGAppRefreshTask submitted, earliestBeginDate=2026-05-29T00:20:00Z"
        )
        store.recordWakeEvent(
            at: enteredAt,
            source: "healthkit_observer",
            summary: "Background handler entered from healthkit_observer"
        )

        let schedule = try XCTUnwrap(store.lastTaskSchedule)
        XCTAssertEqual(schedule.attemptedAt, "2026-05-29T00:10:00Z")
        XCTAssertEqual(schedule.status, "submitted")
        XCTAssertEqual(
            schedule.summary,
            "BGAppRefreshTask submitted, earliestBeginDate=2026-05-29T00:20:00Z"
        )
        let wake = try XCTUnwrap(store.lastWakeEvent)
        XCTAssertEqual(wake.enteredAt, "2026-05-29T00:16:00Z")
        XCTAssertEqual(wake.source, "healthkit_observer")
        XCTAssertEqual(wake.summary, "Background handler entered from healthkit_observer")
    }

    func testForegroundCatchUpRunsWhenAutomaticSyncIsStale() {

        let suiteName = "HealthBridgeForegroundCatchUpTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        let now = Date(timeIntervalSince1970: 1_780_020_000)

        XCTAssertFalse(store.shouldRunForegroundCatchUp(now: now, minimumInterval: 900))

        store.setEnabled(true)
        XCTAssertTrue(store.shouldRunForegroundCatchUp(now: now, minimumInterval: 900))

        store.recordRun(
            startedAt: now.addingTimeInterval(-120),
            finishedAt: now.addingTimeInterval(-60),
            succeeded: true,
            summary: "fresh"
        )
        XCTAssertFalse(store.shouldRunForegroundCatchUp(now: now, minimumInterval: 900))

        store.recordRun(
            startedAt: now.addingTimeInterval(-120),
            finishedAt: now.addingTimeInterval(-60),
            succeeded: false,
            summary: "recent failure"
        )
        XCTAssertTrue(store.shouldRunForegroundCatchUp(now: now, minimumInterval: 900))

        store.recordRun(
            startedAt: now.addingTimeInterval(-1_200),
            finishedAt: now.addingTimeInterval(-1_000),
            succeeded: true,
            summary: "stale"
        )
        XCTAssertTrue(store.shouldRunForegroundCatchUp(now: now, minimumInterval: 900))
    }

    func testObserverDirtinessPersistsAcrossReloadAndUsesGenerationSafeClear() throws {
        let suiteName = "HealthBridgeObserverDirtinessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_780_020_000)
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        store.setEnabled(true)
        store.recordRun(
            startedAt: now.addingTimeInterval(-120),
            finishedAt: now.addingTimeInterval(-60),
            succeeded: true,
            summary: "fresh"
        )
        XCTAssertFalse(store.shouldRunForegroundCatchUp(now: now, minimumInterval: 900))

        try store.markPendingObserverTypeCodes(["body_mass", "active_energy"])
        let reloaded = BackgroundSyncSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.pendingObserverTypeCodes, ["energy", "weight"])
        XCTAssertTrue(reloaded.shouldRunForegroundCatchUp(now: now, minimumInterval: 900))

        let firstGeneration = reloaded.pendingObserverTypeCodeGenerations
        try reloaded.markPendingObserverTypeCodes(["weight"])
        try reloaded.clearPendingObserverTypeCodes(
            matching: firstGeneration,
            typeCodes: ["energy", "weight"]
        )
        XCTAssertEqual(reloaded.pendingObserverTypeCodes, ["weight"])
        XCTAssertEqual(reloaded.pendingObserverTypeCodeGenerations["weight"], 2)

        try reloaded.clearPendingObserverTypeCodes(
            matching: reloaded.pendingObserverTypeCodeGenerations,
            typeCodes: ["weight"]
        )
        XCTAssertTrue(reloaded.pendingObserverTypeCodes.isEmpty)
        XCTAssertFalse(reloaded.shouldRunForegroundCatchUp(now: now, minimumInterval: 900))
    }

    func testObserverDirtinessFileSurvivesReloadAndClearsGenerationSafely() throws {
        let suiteName = "HealthBridgeObserverDirtinessFileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        let legacyKey = "healthBridge.backgroundSync.pendingObserverTypeCodeGenerations"
        defaults.set(["active_energy": 2], forKey: legacyKey)
        let fileStore = FileBackgroundObserverDirtinessStore(fileURL: fileURL)
        let store = BackgroundSyncSettingsStore(
            userDefaults: defaults,
            observerDirtinessStore: fileStore
        )

        try store.markPendingObserverTypeCodes(["body_mass", "active_energy"])
        let reloaded = BackgroundSyncSettingsStore(
            userDefaults: defaults,
            observerDirtinessStore: FileBackgroundObserverDirtinessStore(
                fileURL: fileURL
            )
        )
        let generations = try reloaded.loadPendingObserverTypeCodeGenerations()

        XCTAssertEqual(Set(generations.keys), ["energy", "weight"])
        XCTAssertEqual(generations["energy"], 3)
        XCTAssertNil(defaults.object(forKey: legacyKey))
        try reloaded.clearPendingObserverTypeCodes(
            matching: generations,
            typeCodes: ["energy", "weight"]
        )
        XCTAssertTrue(
            try reloaded.loadPendingObserverTypeCodeGenerations().isEmpty
        )
    }

    func testObserverDirtinessPersistenceFailuresAreObservableAndFailClosed() throws {
        let suiteName = "HealthBridgeObserverDirtinessFailureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writeFailingStore = FailingObserverDirtinessStore(failLoad: false)
        let writeFailingSettings = BackgroundSyncSettingsStore(
            userDefaults: defaults,
            observerDirtinessStore: writeFailingStore
        )

        XCTAssertThrowsError(
            try writeFailingSettings.markPendingObserverTypeCodes(["heart_rate"])
        )

        let readFailingSettings = BackgroundSyncSettingsStore(
            userDefaults: defaults,
            observerDirtinessStore: FailingObserverDirtinessStore(failLoad: true)
        )
        XCTAssertThrowsError(
            try readFailingSettings.loadPendingObserverTypeCodeGenerations()
        )
        XCTAssertEqual(
            Set(readFailingSettings.pendingObserverTypeCodes),
            Set(HealthBridgeBackgroundSync.supportedAutomaticQuantityTypeCodes)
        )
    }

    func testPolicyDoesNotScheduleWhenDisabled() {
        let now = Date(timeIntervalSince1970: 1_780_123_200)

        XCTAssertNil(HealthBridgeBackgroundSync.nextEarliestBeginDate(enabled: false, now: now))
    }

    func testPolicySchedulesAfterMinimumIntervalWhenEnabled() throws {
        let now = Date(timeIntervalSince1970: 1_780_123_200)

        let nextDate = try XCTUnwrap(
            HealthBridgeBackgroundSync.nextEarliestBeginDate(
                enabled: true,
                now: now,
                minimumInterval: 60 * 30
            )
        )

        XCTAssertEqual(nextDate, now.addingTimeInterval(60 * 30))
    }

    func testDefaultRefreshIntervalIsShortEnoughForDeviceValidation() throws {
        let now = Date(timeIntervalSince1970: 1_780_123_200)

        let nextDate = try XCTUnwrap(
            HealthBridgeBackgroundSync.nextEarliestBeginDate(enabled: true, now: now)
        )

        XCTAssertEqual(nextDate, now.addingTimeInterval(15 * 60))
    }

    func testAutomaticQuantityCoverageIncludesEverySupportedCanonicalCandidate() {
        XCTAssertEqual(
            HealthBridgeBackgroundSync.supportedAutomaticQuantityTypeCodes,
            GenericQuantityCoveragePolicy.supportedQuantityEntries().map(\.typeCode)
        )
        XCTAssertTrue(HealthBridgeBackgroundSync.supportedAutomaticQuantityTypeCodes.contains("oxygen_saturation"))
        XCTAssertTrue(HealthBridgeBackgroundSync.supportedAutomaticQuantityTypeCodes.contains("weight"))
    }

    func testUnifiedReadCoverageExactlyMatchesDedicatedAndAutomaticQuantities() {
        let expected = Array(Set(
            HealthBridgeHealthType.dedicatedSyncTypes.map(\.typeCode)
                + GenericQuantityCoveragePolicy.supportedQuantityEntries().map(\.typeCode)
        )).sorted()

        XCTAssertEqual(HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes, expected)
        XCTAssertEqual(
            Set(HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes).count,
            HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes.count
        )
    }

    func testObserverAutomaticQuantityPlanIncludesObservedTypesAndUnobservedTrigger() {
        let plan = HealthBridgeBackgroundSync.automaticQuantitySyncPlan(
            availableTypeCodes: ["heart_rate", "oxygen_saturation", "body_mass", "unknown_metric"],
            observedTypeCodes: ["heart_rate"],
            reason: .observer(typeCode: "oxygen_saturation")
        )

        XCTAssertEqual(plan.typeCodes, ["heart_rate", "oxygen_saturation"])
        XCTAssertEqual(plan.fallbackHistoryDepth, .lastDays(1))
    }

    func testObserverBatchPlanIncludesEveryCoalescedTrigger() {
        let plan = HealthBridgeBackgroundSync.automaticQuantitySyncPlan(
            availableTypeCodes: ["heart_rate", "oxygen_saturation", "body_mass"],
            observedTypeCodes: ["heart_rate"],
            reason: .observerBatch(typeCodes: ["body_mass", "oxygen_saturation", "body_mass"])
        )

        XCTAssertEqual(plan.typeCodes, ["heart_rate", "oxygen_saturation", "weight"])
        XCTAssertEqual(plan.fallbackHistoryDepth, .lastDays(1))
    }

    func testScheduledAutomaticQuantityPlanReconcilesEveryAvailableSupportedType() {
        let plan = HealthBridgeBackgroundSync.automaticQuantitySyncPlan(
            availableTypeCodes: ["body_mass", "heart_rate", "oxygen_saturation", "unknown_metric"],
            observedTypeCodes: [],
            reason: .scheduledRefresh
        )

        XCTAssertEqual(plan.typeCodes, ["heart_rate", "oxygen_saturation", "weight"])
        XCTAssertEqual(plan.fallbackHistoryDepth, .lastDays(1))
    }

    func testBackgroundDeliveryTracksValidatedForegroundLanesIncludingSleep() {
        XCTAssertEqual(
            HealthBridgeBackgroundSync.observedHealthTypes.map(\.typeCode),
            ["steps", "workout", "sleep_analysis"]
        )
    }

    func testObservedHealthTypesIncludeEveryAutomaticQuantityWithoutForegroundConfirmation() {
        XCTAssertEqual(
            HealthBridgeBackgroundSync.observedHealthTypes(
                automaticQuantityTypeCodes: [
                    "heart_rate",
                    "active_energy",
                    "oxygen_saturation",
                ]
            ).map(\.typeCode),
            ["steps", "workout", "sleep_analysis", "energy", "heart_rate", "oxygen_saturation"]
        )
    }

    func testAllKnownBackgroundDeliveryTypesIncludeEverySupportedAutomaticQuantityForDisable() {
        let knownTypeCodes = Set(
            HealthBridgeBackgroundSync.allKnownBackgroundDeliveryHealthTypes.map(\.typeCode)
        )

        XCTAssertTrue(knownTypeCodes.isSuperset(of: ["steps", "workout", "sleep_analysis"]))
        XCTAssertTrue(
            knownTypeCodes.isSuperset(
                of: HealthBridgeBackgroundSync.supportedAutomaticQuantityTypeCodes
            )
        )
    }

    func testBackgroundDeliveryRegistrationPlanObservesEveryAvailableAutomaticQuantity() {
        let plan = HealthBridgeBackgroundSync.backgroundDeliveryRegistrationPlan(
            automaticQuantityTypeCodes: [
                "heart_rate",
                "oxygen_saturation",
                "weight",
            ]
        )

        XCTAssertEqual(
            plan.observedHealthTypes.map(\.typeCode),
            ["steps", "workout", "sleep_analysis", "heart_rate", "oxygen_saturation", "weight"]
        )
    }

    func testQuantityObservationStorePersistsCanonicalObservedTypes() {
        let suiteName = "HealthBridgeQuantityObservationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QuantityObservationStore(userDefaults: defaults)

        store.markObserved(typeCodes: ["heart_rate", "active_energy"])
        store.markObserved(typeCodes: ["heart_rate", "flights_climbed"])

        XCTAssertEqual(store.observedTypeCodes, ["energy", "flights_climbed", "heart_rate"])
        XCTAssertEqual(
            QuantityObservationStore(userDefaults: defaults).observedTypeCodes,
            ["energy", "flights_climbed", "heart_rate"]
        )
    }

    func testBackgroundRefreshSummaryReportsSleepLaneOutcome() {
        let summary = HealthBridgeBackgroundSync.refreshSummary(
            succeeded: true,
            stepsSucceeded: true,
            dailyActivitySucceeded: true,
            workoutsSucceeded: true,
            sleepSucceeded: true,
            pendingOutboxCount: 2
        )

        XCTAssertEqual(
            summary,
            "Background refresh completed: steps=ok, daily_activity=ok, workouts=ok, sleep=ok, pending_outbox=2."
        )
    }

    func testBackgroundRefreshSummaryReportsUnifiedQuantityOutcome() {
        let summary = HealthBridgeBackgroundSync.refreshSummary(
            succeeded: true,
            stepsSucceeded: true,
            dailyActivitySucceeded: true,
            workoutsSucceeded: true,
            sleepSucceeded: true,
            pendingOutboxCount: 2,
            quantityStatus: .succeeded(typeCodes: ["heart_rate", "energy"])
        )

        XCTAssertEqual(
            summary,
            "Background refresh completed: steps=ok, daily_activity=ok, workouts=ok, sleep=ok, quantities=ok(energy,heart_rate), pending_outbox=2."
        )
    }

    func testAutomaticCursorlessSyncDoesNotCommitSharedForegroundProgress() {
        XCTAssertTrue(
            HealthBridgeSyncExecutionMode.foreground.shouldPersistSharedProgress(
                hadUsableCursor: false
            )
        )
        XCTAssertTrue(
            HealthBridgeSyncExecutionMode.foreground.shouldPersistSharedProgress(
                hadUsableCursor: true
            )
        )
        XCTAssertFalse(
            HealthBridgeSyncExecutionMode.automatic.shouldPersistSharedProgress(
                hadUsableCursor: false
            )
        )
        XCTAssertTrue(
            HealthBridgeSyncExecutionMode.automatic.shouldPersistSharedProgress(
                hadUsableCursor: true
            )
        )
    }

    func testRunGateRejectsConcurrentAndDebouncedBackgroundRuns() async throws {
        let gate = BackgroundSyncRunGate(minimumSpacing: 10 * 60)
        let firstStart = Date(timeIntervalSince1970: 1_780_123_200)

        let firstAdmission = await gate.beginRun(now: firstStart)
        XCTAssertTrue(firstAdmission.shouldRun)
        XCTAssertEqual(firstAdmission.startedAt, firstStart)

        let concurrentAdmission = await gate.beginRun(now: firstStart.addingTimeInterval(1))
        XCTAssertFalse(concurrentAdmission.shouldRun)
        XCTAssertEqual(concurrentAdmission.skipReason, .alreadyRunning)

        await gate.finishRun(.succeeded)

        let debouncedAdmission = await gate.beginRun(now: firstStart.addingTimeInterval(5 * 60))
        XCTAssertFalse(debouncedAdmission.shouldRun)
        XCTAssertEqual(debouncedAdmission.skipReason, .debounced)

        let laterAdmission = await gate.beginRun(now: firstStart.addingTimeInterval(11 * 60))
        XCTAssertTrue(laterAdmission.shouldRun)
        XCTAssertEqual(laterAdmission.startedAt, firstStart.addingTimeInterval(11 * 60))
    }

    func testRunGateAllowsOnlyOneAcceptedConcurrentAdmission() async {
        let gate = BackgroundSyncRunGate(minimumSpacing: 10 * 60)
        let now = Date(timeIntervalSince1970: 1_780_123_200)

        let admissions = await withTaskGroup(of: BackgroundSyncRunAdmission.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.beginRun(now: now)
                }
            }

            var results: [BackgroundSyncRunAdmission] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(admissions.filter(\.shouldRun).count, 1)
        XCTAssertEqual(admissions.filter { $0.skipReason == .alreadyRunning }.count, 19)
    }

    func testRunGateCoalescesObserverTriggersAndDebouncesFollowUp() async {
        let gate = BackgroundSyncRunGate(minimumSpacing: 10 * 60)
        let now = Date(timeIntervalSince1970: 1_780_123_200)

        let first = await gate.beginRun(reason: .observer(typeCode: "heart_rate"), now: now)
        let second = await gate.beginRun(reason: .observer(typeCode: "weight"), now: now.addingTimeInterval(1))
        _ = await gate.beginRun(reason: .observer(typeCode: "heart_rate"), now: now.addingTimeInterval(2))

        XCTAssertTrue(first.shouldRun)
        XCTAssertEqual(second.skipReason, .alreadyRunning)
        let pending = await gate.finishRun(.succeeded)
        XCTAssertEqual(pending, ["heart_rate", "weight"])

        let followUp = await gate.beginRun(
            reason: .observerBatch(typeCodes: pending),
            now: now.addingTimeInterval(3)
        )
        XCTAssertFalse(followUp.shouldRun)
        XCTAssertEqual(followUp.skipReason, .debounced)
        let retryTypeCodes = await gate.pendingObserverTypeCodesSnapshot()
        XCTAssertEqual(retryTypeCodes, ["heart_rate", "weight"])
        let retry = await gate.beginRun(
            reason: .observerBatch(typeCodes: retryTypeCodes),
            now: now.addingTimeInterval(10 * 60 + 1)
        )
        XCTAssertTrue(retry.shouldRun)
        let remaining = await gate.finishRun(.succeeded)
        XCTAssertEqual(remaining, [])
    }

    func testAcceptedObserverDirtinessIsRetainedWhenRunDefers() async {
        let gate = BackgroundSyncRunGate(minimumSpacing: 0)
        let now = Date(timeIntervalSince1970: 1_780_123_200)

        let admission = await gate.beginRun(
            reason: .observer(typeCode: "heart_rate"),
            now: now
        )
        XCTAssertTrue(admission.shouldRun)
        let retained = await gate.finishRun(.interrupted)
        XCTAssertEqual(retained, ["heart_rate"])
        let pendingSnapshot = await gate.pendingObserverTypeCodesSnapshot()
        XCTAssertEqual(pendingSnapshot, ["heart_rate"])
    }

    func testCancellationCertificationFailsClosedForEveryUncertainSignal() {
        func certify(
            barrier: Bool = true,
            eventCycle: Bool = true,
            finalTasksEmpty: Bool = true,
            coordinatorIdle: Bool = true,
            generationStable: Bool = true,
            introducedAfterWait: Bool = false
        ) -> Bool {
            BackgroundUploadCancellationCertificationPolicy.canCertifyFullyFinalized(
                barrierFinalized: barrier,
                eventCycleFinalized: eventCycle,
                finalTaskSetIsEmpty: finalTasksEmpty,
                finalCoordinatorIsIdle: coordinatorIdle,
                coordinatorGenerationIsStable: generationStable,
                introducedTaskAfterWait: introducedAfterWait
            )
        }

        XCTAssertTrue(certify())
        XCTAssertFalse(certify(barrier: false))
        XCTAssertFalse(certify(eventCycle: false))
        XCTAssertFalse(certify(finalTasksEmpty: false))
        XCTAssertFalse(certify(coordinatorIdle: false))
        XCTAssertFalse(certify(generationStable: false))
        XCTAssertFalse(certify(introducedAfterWait: true))
    }

    func testAutomaticPayloadGenerationRequiresTrustedEmptyOutbox() {
        XCTAssertTrue(
            AutomaticSyncPayloadGenerationPolicy.shouldGenerateNewPayloads(
                trustedPendingOutboxCount: 0
            )
        )
        XCTAssertFalse(
            AutomaticSyncPayloadGenerationPolicy.shouldGenerateNewPayloads(
                trustedPendingOutboxCount: 1
            )
        )
        XCTAssertFalse(
            AutomaticSyncPayloadGenerationPolicy.shouldGenerateNewPayloads(
                trustedPendingOutboxCount: nil
            )
        )
    }

    func testRunGateRetainsObserverDirtinessWhenRunDefersForOutbox() async {
        let gate = BackgroundSyncRunGate(minimumSpacing: 0)
        let now = Date(timeIntervalSince1970: 1_780_123_200)
        _ = await gate.beginRun(reason: .scheduledRefresh, now: now)
        _ = await gate.beginRun(
            reason: .observer(typeCode: "heart_rate"),
            now: now.addingTimeInterval(1)
        )

        let deferred = await gate.finishRun(.interrupted)
        XCTAssertEqual(deferred, ["heart_rate"])

        let reconciliation = await gate.beginRun(
            reason: .scheduledRefresh,
            now: now.addingTimeInterval(2)
        )
        XCTAssertTrue(reconciliation.shouldRun)
        let retained = await gate.finishRun(.succeeded)
        XCTAssertEqual(retained, ["heart_rate"])
        let cleared = await gate.beginRun(
            reason: .scheduledRefresh,
            now: now.addingTimeInterval(3)
        )
        XCTAssertTrue(cleared.shouldRun)
        let clearedPending = await gate.finishRun(.succeeded)
        XCTAssertEqual(clearedPending, [])
    }

    func testDirectTransferRequiresCancellationFinalizationAndNoBackgroundTasks() {
        XCTAssertTrue(
            BackgroundUploadCancellationPolicy.canBeginDirectTransfer(
                cancellationWasFullyFinalized: true,
                hasPendingUploadTasks: false
            )
        )
        XCTAssertFalse(
            BackgroundUploadCancellationPolicy.canBeginDirectTransfer(
                cancellationWasFullyFinalized: false,
                hasPendingUploadTasks: false
            )
        )
        XCTAssertFalse(
            BackgroundUploadCancellationPolicy.canBeginDirectTransfer(
                cancellationWasFullyFinalized: true,
                hasPendingUploadTasks: true
            )
        )
    }

    func testPayloadGenerationPolicyStopsAutomaticQuantityLoopAfterDurableQueue() {
        XCTAssertTrue(
            AutomaticSyncPayloadGenerationPolicy.shouldStopQuantityLoop(
                isAutomaticSync: true,
                hasDurablyQueuedPayload: true
            )
        )
        XCTAssertFalse(
            AutomaticSyncPayloadGenerationPolicy.shouldStopQuantityLoop(
                isAutomaticSync: false,
                hasDurablyQueuedPayload: true
            )
        )
        XCTAssertFalse(
            AutomaticSyncPayloadGenerationPolicy.shouldStopQuantityLoop(
                isAutomaticSync: true,
                hasDurablyQueuedPayload: false
            )
        )
    }

    @MainActor
    func testDisableCoordinatorPublishesAndPersistsBeforeCancellation() async throws {
        var steps: [String] = []

        try await AutomaticSyncDisableCoordinator.disable(
            publishDisabled: { steps.append("publish") },
            stopObserverDelivery: { steps.append("stop_observers") },
            persistDisabled: { steps.append("persist") },
            cancelForegroundPayloads: { steps.append("cancel_foreground") },
            cancelBackgroundPayloads: { steps.append("cancel_background") }
        )

        XCTAssertEqual(
            steps,
            ["publish", "stop_observers", "persist", "cancel_foreground", "cancel_background"]
        )
    }

    @MainActor
    func testDisableCoordinatorStillCancelsPayloadsWhenPersistenceFails() async {
        enum TestFailure: Error {
            case persistence
        }

        var steps: [String] = []

        do {
            try await AutomaticSyncDisableCoordinator.disable(
                publishDisabled: { steps.append("publish") },
                stopObserverDelivery: { steps.append("stop_observers") },
                persistDisabled: {
                    steps.append("persist")
                    throw TestFailure.persistence
                },
                cancelForegroundPayloads: { steps.append("cancel_foreground") },
                cancelBackgroundPayloads: { steps.append("cancel_background") }
            )
            XCTFail("Expected persistence failure")
        } catch TestFailure.persistence {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            steps,
            ["publish", "stop_observers", "persist", "cancel_foreground", "cancel_background"]
        )
    }

    #if canImport(HealthKit)
    func testBackgroundDeliveryObservedTypesMapToHealthKitSampleTypes() {
        XCTAssertEqual(
            HealthKitReadTypeCatalog.sampleTypes(for: HealthBridgeBackgroundSync.observedHealthTypes).count,
            3
        )
        XCTAssertEqual(
            HealthKitReadTypeCatalog.sampleTypes(
                for: HealthBridgeBackgroundSync.observedHealthTypes(
                    automaticQuantityTypeCodes: ["heart_rate"]
                )
            ).count,
            4
        )
    }
    #endif

    func testAppRefreshIdentifierIsStableAndNamespaced() {
        XCTAssertEqual(
            HealthBridgeBackgroundSync.appRefreshIdentifier,
            "\(HealthBridgeAppIdentity.bundleIdentifier).refresh"
        )
    }
}

private final class FailingObserverDirtinessStore: BackgroundObserverDirtinessStoring {
    private let failLoad: Bool

    init(failLoad: Bool) {
        self.failLoad = failLoad
    }

    func loadGenerations() throws -> [String: Int] {
        if failLoad {
            throw BackgroundSyncSettingsStoreError.persistenceFailed
        }
        return [:]
    }

    func saveGenerations(_ generations: [String: Int]) throws {
        _ = generations
        throw BackgroundSyncSettingsStoreError.persistenceFailed
    }
}

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
        XCTAssertTrue(HealthBridgeSyncExecutionMode.foreground.shouldAttemptInlineDirectDelivery)
        XCTAssertFalse(HealthBridgeSyncExecutionMode.automatic.shouldRequestReadAuthorization)
        XCTAssertEqual(HealthBridgeSyncExecutionMode.automatic.cursorlessFallbackDays, 1)
        XCTAssertTrue(HealthBridgeSyncExecutionMode.automatic.shouldAttemptInlineDirectDelivery)
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

    func testHealthKitObserverEntryHandlerPersistsCorrelatedRawEntry() throws {
        let suiteName = "HealthBridgeObserverEntryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        let runID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

        store.healthKitObserverEntryHandler()("heart_rate", runID)

        let wake = try XCTUnwrap(store.lastWakeEvent)
        XCTAssertEqual(wake.source, "healthkit_observer")
        XCTAssertEqual(
            wake.summary,
            "HealthKit observer closure entered; type=heart_rate; run_id=00112233-4455-6677-8899-aabbccddeeff."
        )
    }

    func testForegroundCatchUpRunsOnlyForDurablePendingGenerations() throws {
        let suiteName = "HealthBridgeForegroundCatchUpTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)

        XCTAssertFalse(store.shouldRunForegroundCatchUp())
        store.setEnabled(true)
        XCTAssertFalse(store.shouldRunForegroundCatchUp())
        try store.markPendingObserverTypeCodes(["heart_rate"])
        XCTAssertTrue(store.shouldRunForegroundCatchUp())
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
        XCTAssertFalse(store.shouldRunForegroundCatchUp())

        try store.markPendingObserverTypeCodes(["body_mass", "active_energy"])
        let reloaded = BackgroundSyncSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.pendingObserverTypeCodes, ["energy", "weight"])
        XCTAssertTrue(reloaded.shouldRunForegroundCatchUp())

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
        XCTAssertFalse(reloaded.shouldRunForegroundCatchUp())
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
        XCTAssertTrue(readFailingSettings.pendingObserverTypeCodes.isEmpty)
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
        let automaticFallback = GenericQuantityAnchoredCursorOwnershipPolicy.resolve(
            typeCode: "heart_rate",
            executionMode: .automatic,
            sharedCursorValue: nil,
            automaticCursorValue: "automatic-anchor"
        )
        XCTAssertEqual(
            automaticFallback.cursorKind,
            GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "heart_rate")
        )
        XCTAssertEqual(automaticFallback.cursorValue, "automatic-anchor")
        XCTAssertTrue(automaticFallback.isIndependentAutomaticFallback)

        let automaticWithShared = GenericQuantityAnchoredCursorOwnershipPolicy.resolve(
            typeCode: "heart_rate",
            executionMode: .automatic,
            sharedCursorValue: "shared-anchor",
            automaticCursorValue: "stale-automatic-anchor"
        )
        XCTAssertEqual(
            automaticWithShared.cursorKind,
            GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "heart_rate")
        )
        XCTAssertEqual(automaticWithShared.cursorValue, "shared-anchor")
        XCTAssertFalse(automaticWithShared.isIndependentAutomaticFallback)
        XCTAssertNotEqual(automaticFallback.cursorKind, automaticWithShared.cursorKind)

        let foreground = GenericQuantityAnchoredCursorOwnershipPolicy.resolve(
            typeCode: "heart_rate",
            executionMode: .foreground,
            sharedCursorValue: "foreground-anchor",
            automaticCursorValue: "ignored-automatic-anchor"
        )
        XCTAssertEqual(
            foreground.cursorKind,
            GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "heart_rate")
        )
        XCTAssertEqual(foreground.cursorValue, "foreground-anchor")
        XCTAssertFalse(foreground.isIndependentAutomaticFallback)

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

    func testMailboxBackgroundOpportunitySelectsOneBoundedDeliveryPhase() {
        XCTAssertEqual(
            AutomaticSyncBackgroundOpportunityPolicy.deliveryPhase(
                usesMailboxTransport: true,
                at: .beforePayloadGeneration
            ),
            .advanceOrReconcileFIFOHead
        )
        XCTAssertEqual(
            AutomaticSyncBackgroundOpportunityPolicy.deliveryPhase(
                usesMailboxTransport: true,
                at: .afterDurableEnqueue
            ),
            .publishFIFOHead
        )
        XCTAssertNil(
            AutomaticSyncBackgroundOpportunityPolicy.deliveryPhase(
                usesMailboxTransport: false,
                at: .beforePayloadGeneration
            )
        )
        XCTAssertNil(
            AutomaticSyncBackgroundOpportunityPolicy.deliveryPhase(
                usesMailboxTransport: false,
                at: .afterDurableEnqueue
            )
        )
    }

    func testSuccessfulBoundedMailboxPhaseIsCompletedEvenWhenBacklogRemains() {
        for result in [
            AutomaticSyncMailboxReconciliationResult.completed(pendingCount: 0),
            .completed(pendingCount: 3),
        ] {
            XCTAssertEqual(result.lifecycleOutcome, .completed)
            XCTAssertTrue(result.lifecycleSucceeded)
            XCTAssertFalse(result.isTerminalHold)
            XCTAssertTrue(result.shouldScheduleRetry)
        }
    }

    func testFailedTerminalAndCancelledMailboxPhasesRemainDistinct() {
        XCTAssertEqual(
            AutomaticSyncMailboxReconciliationResult.failed.lifecycleOutcome,
            .interrupted
        )
        XCTAssertFalse(AutomaticSyncMailboxReconciliationResult.failed.lifecycleSucceeded)
        XCTAssertTrue(AutomaticSyncMailboxReconciliationResult.failed.shouldScheduleRetry)
        XCTAssertTrue(
            AutomaticSyncMailboxReconciliationResult.terminalHold(pendingCount: 1)
                .isTerminalHold
        )
        XCTAssertEqual(
            AutomaticSyncMailboxReconciliationResult.cancelled.lifecycleOutcome,
            .interrupted
        )
        XCTAssertFalse(
            AutomaticSyncMailboxReconciliationResult.cancelled.shouldScheduleRetry
        )
    }

    func testMailboxAckScanCheckpointSurvivesRestartAndIsGenerationBound() throws {
        let suiteName = "BackgroundSyncMailboxAckCheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let checkpoint = String(repeating: "a", count: 32) + ".hba"
        let initial = BackgroundSyncSettingsStore(userDefaults: defaults)

        try initial.persistMailboxAckScanCheckpoint(
            checkpoint,
            receiverGeneration: "synthetic-generation-a"
        )
        let restarted = BackgroundSyncSettingsStore(userDefaults: defaults)

        XCTAssertEqual(
            restarted.mailboxAckScanCheckpoint(
                receiverGeneration: "synthetic-generation-a"
            ),
            checkpoint
        )
        XCTAssertNil(
            restarted.mailboxAckScanCheckpoint(
                receiverGeneration: "synthetic-generation-b"
            )
        )
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

private enum SyntheticBackgroundLaneFailure: Error {
    case injected
}

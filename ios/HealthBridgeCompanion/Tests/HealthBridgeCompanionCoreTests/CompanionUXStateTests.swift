import XCTest
@testable import HealthBridgeCompanionCore

final class CompanionUXStateTests: XCTestCase {
    func testSetupStateIsUnpairedWhenReceiverSettingsAreIncomplete() {
        let snapshot = CompanionSetupSnapshot(
            receiverURLString: "",
            hasBearerToken: false,
            healthPermissionsRequested: false,
            isSyncing: false,
            statusIsError: false,
            pendingOutboxCount: 0
        )

        XCTAssertEqual(CompanionSetupState.evaluate(snapshot), .unpaired)
    }

    func testSetupStateNeedsHealthPermissionAfterPairingBeforePermissionRequest() {
        let snapshot = CompanionSetupSnapshot(
            receiverURLString: "https://receiver.example/v1/batches",
            hasBearerToken: true,
            healthPermissionsRequested: false,
            isSyncing: false,
            statusIsError: false,
            pendingOutboxCount: 0
        )

        XCTAssertEqual(CompanionSetupState.evaluate(snapshot), .pairedNeedsHealthPermission)
    }

    func testSetupStateIsReadyAfterPairingAndPermissionRequest() {
        let snapshot = CompanionSetupSnapshot(
            receiverURLString: "https://receiver.example/v1/batches",
            hasBearerToken: true,
            healthPermissionsRequested: true,
            isSyncing: false,
            statusIsError: false,
            pendingOutboxCount: 0
        )

        XCTAssertEqual(CompanionSetupState.evaluate(snapshot), .ready)
    }

    func testSetupStateIsDegradedWhenStatusIsError() {
        let snapshot = CompanionSetupSnapshot(
            receiverURLString: "https://receiver.example/v1/batches",
            hasBearerToken: true,
            healthPermissionsRequested: true,
            isSyncing: false,
            statusIsError: true,
            pendingOutboxCount: 0
        )

        XCTAssertEqual(CompanionSetupState.evaluate(snapshot), .degraded)
    }

    func testSetupStateIsDegradedWhenOutboxHasPendingItems() {
        let snapshot = CompanionSetupSnapshot(
            receiverURLString: "https://receiver.example/v1/batches",
            hasBearerToken: true,
            healthPermissionsRequested: true,
            isSyncing: false,
            statusIsError: false,
            pendingOutboxCount: 2
        )

        XCTAssertEqual(CompanionSetupState.evaluate(snapshot), .degraded)
    }

    func testSetupStateSyncingTakesPriorityOverReadyAndDegraded() {
        let snapshot = CompanionSetupSnapshot(
            receiverURLString: "https://receiver.example/v1/batches",
            hasBearerToken: true,
            healthPermissionsRequested: true,
            isSyncing: true,
            statusIsError: true,
            pendingOutboxCount: 3
        )

        XCTAssertEqual(CompanionSetupState.evaluate(snapshot), .syncing)
    }

    func testSyncNowPlanFlushesOutboxOnlyBeforeGeneratingNewPayloads() {
        XCTAssertEqual(CompanionSyncNowPlan.defaultSteps, [
            .checkReceiverReachability,
            .flushPendingOutboxBeforeSync,
            .syncAnchoredSteps,
            .syncDailyActivityAggregates,
            .syncAnchoredWorkouts,
            .syncSleep,
            .syncSupportedQuantityMetrics,
        ])
    }

    func testNewPayloadSkipsNetworkAttemptWhenFIFOAlreadyHasPendingItems() {
        XCTAssertFalse(
            CompanionPayloadNetworkAttemptPolicy.shouldAttemptNetworkForNewPayload(
                hasPendingOutbox: true
            )
        )
        XCTAssertTrue(
            CompanionPayloadNetworkAttemptPolicy.shouldAttemptNetworkForNewPayload(
                hasPendingOutbox: false
            )
        )
    }

    func testQueuedPayloadAttemptsForegroundFlushOnlyWhenItIsFIFOHead() {
        XCTAssertTrue(
            CompanionPayloadNetworkAttemptPolicy.shouldAttemptNetworkForQueuedPayload(
                isFIFOHead: true
            )
        )
        XCTAssertFalse(
            CompanionPayloadNetworkAttemptPolicy.shouldAttemptNetworkForQueuedPayload(
                isFIFOHead: false
            )
        )
    }

    func testReadyPrimaryActionUsesSimpleEndUserCopy() {
        XCTAssertEqual(CompanionSetupState.ready.primaryActionTitle, "Sync Now")
        XCTAssertEqual(CompanionSetupState.degraded.primaryActionTitle, "Sync Now")
        XCTAssertEqual(CompanionSetupState.unpaired.primaryActionTitle, "Connect Health Bridge")
    }

    func testSyncNowCompletionAllowsNoNewRecordsWhenEveryLaneFinishedWithoutError() {
        let summary = CompanionSyncNowCompletion.summary(pendingOutboxCount: 0)

        XCTAssertFalse(summary.isError)
        XCTAssertEqual(summary.message, "Sync complete. Queued uploads: 0.")
    }

    func testSyncNowCompletionReportsDurableQueuedUploadCount() {
        let summary = CompanionSyncNowCompletion.summary(pendingOutboxCount: 2)

        XCTAssertFalse(summary.isError)
        XCTAssertEqual(summary.message, "Sync complete. Queued uploads: 2.")
    }

    func testPrimaryStatusMessageSanitizesTechnicalAndHealthDerivedDetails() {
        let rawMessages = [
            "Receiver accepted test batch with HTTP 200 via 192.0.2.10. Pending outbox: 0.",
            "Reading anchored Step Count changes from HealthKit...",
            "Recorded step anchor cursor with HTTP 200. Pending outbox: 0.",
            "Synced 2 workouts (45 min) with HTTP 200. Pending outbox: 0.",
            "Background refresh completed: steps=ok, daily_activity=ok, workouts=ok, sleep=ok, quantities=ok(active_energy,heart_rate), pending_outbox=0.",
        ]

        for rawMessage in rawMessages {
            let copy = CompanionPrimaryStatusMessage.sanitized(from: rawMessage, isError: false)
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("receiver"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("http"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("anchored"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("cursor"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("outbox"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("workout"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("45"))
        }

        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Recorded step anchor cursor with HTTP 200. Pending outbox: 0.", isError: false),
            "Sync progress saved"
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "HealthKit returned no anchored step-count payload. Nothing sent.", isError: false),
            "No new data to send"
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Opening Apple Health permissions...", isError: false),
            "Opening Apple Health permissions"
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Queued upload retry failed: Could not connect to the server. | domain=NSURLErrorDomain | code=-1004", isError: true),
            "Queued upload failed: Health Bridge is not reachable (NSURLErrorDomain -1004). Start the server, then retry."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Finishing the previous pairing attempt failed: The Internet connection appears to be offline. | domain=NSURLErrorDomain | code=-1009", isError: true),
            "Pairing could not reach Health Bridge (NSURLErrorDomain -1009). Allow Local Network access, check Wi-Fi or VPN routing, make sure the server is running, then retry."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Pairing failed: The request timed out. | domain=NSURLErrorDomain | code=-1001", isError: true),
            "Pairing could not reach Health Bridge (NSURLErrorDomain -1001). Allow Local Network access, check Wi-Fi or VPN routing, make sure the server is running, then retry."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Sync stopped: Step sync failed: Could not connect to the server. | domain=NSURLErrorDomain | code=-1004", isError: true),
            "Sync failed: Health Bridge is not reachable (NSURLErrorDomain -1004). Start the server, then retry."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Apple Health reports these permissions were already reviewed. To change them: Health app > profile picture > Privacy > Apps > Health Bridge.", isError: false),
            "Permissions already reviewed. Change them in Health > profile picture > Privacy > Apps > Health Bridge."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Sync stopped: HealthBridgeCompanion.ReceiverClientError 0", isError: true),
            "Connection key missing. Reconnect from setup link."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Receiver test failed: Connection key is missing. | domain=ReceiverClientError | code=missing_key", isError: true),
            "Connection key missing. Reconnect from setup link."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Connection verified. Queued uploads: 0.", isError: false),
            "Health Bridge connected"
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Cancelled. Any already queued uploads remain available for retry.", isError: false),
            "Sync cancelled. Already queued uploads are kept for retry."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Bridge URL is invalid.", isError: true),
            "Bridge URL is invalid. Reconnect from setup link or check manual URL."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Sync stopped: unsupported URL. | domain=NSURLErrorDomain | code=-1002", isError: true),
            "Bridge URL is invalid (NSURLErrorDomain -1002). Reconnect from setup link or check manual URL."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Disconnected and turned automatic sync off. Queued uploads: 2.", isError: false),
            "Disconnected from server. Queued uploads remain on this iPhone; reconnect from setup link to retry them."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Queued upload failed: Health Bridge returned an error. | domain=ReceiverClientError | code=http_502 | HTTP 502", isError: true),
            "Queued upload failed (HTTP 502). Reconnect from setup link or retry after the server is back."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Cleared 2 queued upload(s). This only removes unsent local retry data.", isError: false),
            "Cleared queued uploads. Only unsent local retry data was removed."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Queued uploads sent: 5. Remaining: 0.", isError: false),
            "Queued uploads sent: 5. Remaining: 0."
        )
        XCTAssertNotEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Queued uploads sent: 5. Remaining: 0.", isError: false),
            "Queued uploads updated"
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Sync stopped: Health Bridge returned an error. | domain=ReceiverClientError | code=http_401 | HTTP 401", isError: true),
            "Connection key was rejected (HTTP 401). Reconnect from a fresh setup link."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Sync stopped: Step sync failed: Apple Health Step Count data is not available on this device. | domain=HealthKitStepCountReaderError | code=health_data_unavailable", isError: true),
            "Apple Health data is not available on this device. Use a real iPhone with Health enabled."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Sync stopped: Sleep sync failed: protected data is unavailable while device_locked", isError: true),
            "Apple Health data is locked. Unlock this iPhone, then retry."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Sync stopped: Workout sync failed: HK query not authorized", isError: true),
            "Apple Health access was denied. Review permissions in the Health app, then retry."
        )
        XCTAssertEqual(
            CompanionPrimaryStatusMessage.sanitized(from: "Sync stopped: Sleep sync failed: HealthKit query failed unexpectedly", isError: true),
            "Apple Health Sleep sync failed. Review permissions or unlock this iPhone, then retry."
        )
    }

    func testStatusLaneBuilderSummarizesConnectionHealthQueuedUploadsAndAutomaticSync() {
        let snapshot = CompanionSetupSnapshot(
            receiverURLString: "https://receiver.example/v1/batches",
            hasBearerToken: true,
            healthPermissionsRequested: false,
            isSyncing: false,
            statusIsError: false,
            pendingOutboxCount: 2
        )

        let lanes = CompanionStatusLaneBuilder.lanes(
            snapshot: snapshot,
            backgroundSyncEnabled: true
        )

        XCTAssertEqual(lanes.map(\.id), ["receiver", "healthAccess", "outbox", "automaticSync"])
        XCTAssertEqual(lanes[0].state, "Connected")
        XCTAssertFalse(lanes[0].needsAttention)
        XCTAssertEqual(lanes[1].state, "Not requested")
        XCTAssertTrue(lanes[1].needsAttention)
        XCTAssertEqual(lanes[2].state, "Pending")
        XCTAssertTrue(lanes[2].needsAttention)
        XCTAssertEqual(lanes[3].state, "Best-effort on")
        XCTAssertEqual(
            lanes[3].detail,
            "Every supported Apple Health type currently available on this iPhone is included. iOS decides background timing; Sync Now performs an immediate catch-up."
        )
        XCTAssertFalse(lanes[3].needsAttention)
    }

    func testAutomaticSyncLaneNeverPromisesAlwaysFreshBackgroundSync() {
        let enabled = CompanionStatusLaneBuilder.lanes(
            snapshot: CompanionSetupSnapshot(
                receiverURLString: "https://receiver.example/v1/batches",
                hasBearerToken: true,
                healthPermissionsRequested: true,
                isSyncing: false,
                statusIsError: false,
                pendingOutboxCount: 0
            ),
            backgroundSyncEnabled: true
        ).last!

        XCTAssertEqual(enabled.title, "Automatic sync")
        XCTAssertEqual(enabled.state, "Best-effort on")
        XCTAssertTrue(enabled.detail.contains("iOS decides background timing"))
        XCTAssertTrue(enabled.detail.contains("Sync Now"))
        XCTAssertTrue(enabled.detail.contains("Every supported Apple Health type"))
        XCTAssertFalse(enabled.detail.contains("Sync Now only"))
        XCTAssertFalse(enabled.detail.localizedCaseInsensitiveContains("always"))
        XCTAssertFalse(enabled.detail.localizedCaseInsensitiveContains("fresh"))
    }

    func testAutomaticSyncCoveragePresentationSeparatesRuntimeQueryAndDeliveryStatus() {
        XCTAssertEqual(
            CompanionAutomaticSyncCoveragePresentation.primarySummary,
            "Supported Apple Health data. iOS decides background timing."
        )
        XCTAssertEqual(
            CompanionAutomaticSyncCoveragePresentation.detail(
                runtimeAvailableQuantityTypeCount: 48,
                activeObserverQueryCount: 51,
                backgroundDeliveryEnabledCount: 49,
                backgroundDeliveryFailureCount: 2
            ),
            "Steps, workouts, sleep, and 48 runtime-available supported quantity types are in scope. 51 observer queries are active; background delivery enabled for 49 type(s), 2 failed. Apple Health does not reveal read-permission status."
        )
    }

    func testHealthPermissionRequestStorePersistsRuntimeCoverageAndDetectsExpansion() throws {
        let suiteName = "CompanionUXStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CompanionHealthPermissionRequestStore(userDefaults: defaults)
        XCTAssertFalse(store.wasRequested)
        XCTAssertEqual(store.requestedRuntimeTypeCodes, [])
        store.recordCompletedRequest(runtimeTypeCodes: [])
        XCTAssertFalse(store.wasRequested)

        store.recordCompletedRequest(
            runtimeTypeCodes: ["weight", "steps", "weight"]
        )
        let reloaded = CompanionHealthPermissionRequestStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.wasRequested)
        XCTAssertEqual(reloaded.requestedRuntimeTypeCodes, ["steps", "weight"])
        XCTAssertFalse(
            reloaded.invalidateIfRuntimeCoverageChanged(
                currentRuntimeTypeCodes: ["weight", "steps"]
            )
        )

        XCTAssertTrue(
            reloaded.invalidateIfRuntimeCoverageChanged(
                currentRuntimeTypeCodes: ["heart_rate", "steps", "weight"]
            )
        )
        XCTAssertFalse(reloaded.wasRequested)
        XCTAssertEqual(reloaded.requestedRuntimeTypeCodes, [])

        reloaded.recordCompletedRequest(
            runtimeTypeCodes: ["heart_rate", "steps", "weight"]
        )
        XCTAssertTrue(reloaded.wasRequested)
        XCTAssertEqual(
            reloaded.requestedRuntimeTypeCodes,
            ["heart_rate", "steps", "weight"]
        )
    }

    func testLegacyPermissionMarkerWithoutRuntimeSignatureFailsClosed() throws {
        let suiteName = "CompanionUXStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            true,
            forKey: "healthBridge.companion.healthPermissionsRequested"
        )
        let store = CompanionHealthPermissionRequestStore(userDefaults: defaults)

        XCTAssertFalse(store.wasRequested)
        XCTAssertFalse(
            store.invalidateIfRuntimeCoverageChanged(
                currentRuntimeTypeCodes: ["steps", "weight"]
            )
        )
        XCTAssertEqual(store.requestedRuntimeTypeCodes, [])
    }
}

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BACKGROUND_SYNC = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "Sources"
    / "HealthBridgeCompanionCore"
    / "BackgroundSync.swift"
)
READ_TYPE_CATALOG = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "Sources"
    / "HealthBridgeCompanionCore"
    / "HealthKitReadTypeCatalog.swift"
)
VIEW_MODEL = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "App"
    / "HealthBridgeCompanionViewModel.swift"
)
APP = ROOT / "ios" / "HealthBridgeCompanion" / "App" / "HealthBridgeCompanionApp.swift"
CONTENT_VIEW = ROOT / "ios" / "HealthBridgeCompanion" / "App" / "ContentView.swift"
UX_STATE = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "Sources"
    / "HealthBridgeCompanionCore"
    / "CompanionUXState.swift"
)


def test_background_sync_defines_unified_supported_quantity_planner() -> None:
    source = BACKGROUND_SYNC.read_text()

    assert "supportedAutomaticQuantityTypeCodes" in source
    assert "automaticQuantitySyncPlan(" in source
    assert "AutomaticQuantitySyncPlan" in source
    assert "AutomaticSyncReason" in source


def test_background_delivery_plan_accepts_all_automatic_quantity_types() -> None:
    source = BACKGROUND_SYNC.read_text()

    assert "observedHealthTypes(\n        automaticQuantityTypeCodes:" in source
    assert (
        "backgroundDeliveryRegistrationPlan(\n        automaticQuantityTypeCodes:"
        in source
    )


def test_healthkit_observer_reports_the_triggering_type_code() -> None:
    source = READ_TYPE_CATALOG.read_text()

    assert (
        "eventHandler: @escaping @MainActor (_ typeCode: String) async -> Void"
        in source
    )
    assert "await eventHandler(healthType.typeCode)" in source


def test_healthkit_observer_restart_does_not_race_disable_against_enable() -> None:
    source = READ_TYPE_CATALOG.read_text()
    start_body = source.split("public func start(", 1)[1].split("public func stop(", 1)[
        0
    ]

    assert "stopActiveObserverQueries()" in start_body
    assert "disableBackgroundDelivery" not in start_body


def test_view_model_registers_and_syncs_unified_automatic_coverage() -> None:
    source = VIEW_MODEL.read_text()

    assert "optionalTypeCodes: []" not in source
    assert "automaticQuantityTypeCodes: availableAutomaticQuantityTypeCodes" in source
    assert "func runBackgroundRefreshSync(reason: AutomaticSyncReason" in source
    assert "automaticQuantitySyncPlan(" in source
    assert "historyDepth: quantityPlan.fallbackHistoryDepth" in source


def test_new_payload_queues_behind_existing_fifo_without_repeated_network_attempt() -> (
    None
):
    source = VIEW_MODEL.read_text()

    assert "uploadWithOutbox" not in source
    assert source.count("uploadPayloadsWithOutbox(") >= 6
    helper = source.split("private func uploadPayloadsWithOutbox", 1)[1].split(
        "private func enqueuePayloads", 1
    )[0]
    assert "uploadPendingOutbox" not in helper
    policy = helper.index(
        "CompanionPayloadNetworkAttemptPolicy.shouldAttemptNetworkForNewPayload"
    )
    enqueue = helper.index("try enqueuePayloads(", policy)
    upload = helper.index("receiverClient.upload(")
    assert policy < enqueue < upload


def test_failed_presync_fifo_flush_continues_lanes_without_repeating_network() -> None:
    source = VIEW_MODEL.read_text()
    sync_now = source.split("func performSyncAllNow() async", 1)[1].split(
        "private func flushPendingOutbox", 1
    )[0]
    flush_case = sync_now.split("case .flushPendingOutboxBeforeSync:", 1)[1].split(
        "case .syncAnchoredSteps:", 1
    )[0]
    flush_helper = source.split("private func flushPendingOutbox", 1)[1].split(
        "func clearPendingOutbox", 1
    )[0]

    assert "guard await flushPendingOutbox() else" in flush_case
    assert "continue" in flush_case
    assert "async -> Bool" in flush_helper
    summary_flow = flush_helper.split("let summary =", 1)[1].split(
        "} catch let conflict", 1
    )[0]
    assert summary_flow.index("if summary.failedCount > 0") < summary_flow.rindex(
        "return true"
    )


def test_connection_check_does_not_report_queued_test_payload_as_passed() -> None:
    source = VIEW_MODEL.read_text()
    check_connection = source.split("func checkConnection() async", 1)[1].split(
        "func performPrimaryAction() async", 1
    )[0]
    send_test = source.split("func sendConnectionTestBatch() async", 1)[1].split(
        "func syncRecentStepCounts", 1
    )[0]

    assert "Connection check passed. Queued uploads" not in check_connection
    assert (
        "case .queuedPendingRetry:\n                statusIsError = true" in send_test
    )


def test_background_entry_points_pass_explicit_sync_reasons() -> None:
    view_model = VIEW_MODEL.read_text()
    app = APP.read_text()

    assert (
        "runBackgroundRefreshSync(reason: .observer(typeCode: typeCode))" in view_model
    )
    assert "runBackgroundRefreshSync(reason: .launchCatchUp)" in view_model
    assert "runBackgroundRefreshSync(reason: .scheduledRefresh)" in app


def test_automatic_core_sync_uses_one_day_fallback_without_authorization() -> None:
    source = VIEW_MODEL.read_text()

    assert "syncRecentStepCounts(executionMode: .automatic)" in source
    assert "syncDailyActivityAggregates(executionMode: .automatic)" in source
    assert "syncAnchoredWorkoutChanges(executionMode: .automatic)" in source
    assert "syncRecentSleepSessions(executionMode: .automatic)" in source
    assert source.count("if executionMode.shouldRequestReadAuthorization") >= 4
    assert source.count("executionMode.cursorlessFallbackDays") >= 3
    assert (
        source.count("clampStoredBootstrapToLookback: executionMode == .automatic") == 2
    )


def test_cursorless_automatic_sync_cannot_commit_shared_foreground_progress() -> None:
    source = VIEW_MODEL.read_text()
    progress_prefix = "let shouldPersistSharedProgress = "
    progress_marker = f"{progress_prefix}executionMode.shouldPersistSharedProgress("
    generic_progress_prefix = "let canPersistSharedProgress = "
    generic_progress_marker = (
        f"{generic_progress_prefix}mode.executionMode.shouldPersistSharedProgress("
    )

    assert source.count(progress_marker) == 3
    assert (
        source.count(
            "hadUsableCursor: HealthKitAnchoredCursorPolicy.hasUsableCursorValue("
        )
        == 2
    )
    assert source.count(generic_progress_marker) == 1
    assert "hadUsableCursor: hadUsableAnchor" in source
    assert source.count("if shouldPersistSharedProgress,") >= 2
    assert "let cursor = shouldPersistSharedProgress" in source
    assert "? batch.sync.cursors.first(where:" in source
    assert source.count("if shouldIncludeAnchor,") == 1
    assert source.count("coreLaneUploadProof: uploadedRecords ?") == 2
    assert "var executionMode: HealthBridgeSyncExecutionMode" in source
    assert "includeAnchorCursor: shouldIncludeAnchor" in source
    assert "let shouldIncludeAnchor = GenericQuantityAnchoredProgressPolicy" in source
    assert ".shouldIncludeAnchor(" in source
    assert "GenericQuantityAnchoredProgressPolicy.shouldPersistAnchor(" in source
    assert "cursorKind: queryPlan.anchorCursorKind" in source
    assert "allowNewCursorCreation: mode.allowNewCursorCreation" not in source
    assert "let persistableQuantityTypeCodes = Set(" not in source
    assert "let persistableQuantityCursorKinds = Set(" not in source


def test_anchored_sleep_uses_receiver_bound_manifest_after_durable_delivery() -> None:
    source = VIEW_MODEL.read_text()
    start = source.index("func syncRecentSleepSessions(")
    end = source.index("func syncSupportedQuantityMetrics(", start)
    body = source[start:end]

    assert "SleepSyncBatchFactory.manifestPlan(" in body
    assert "receiverSettingsGeneration: currentReceiverGeneration" in body
    assert "historyDepth: currentHistoryDepth" in body
    assert (
        "guard executionMode == .foreground || manifestPlan.anchorCursorValue != nil"
        in body
    )
    assert "anchorCursorValue: manifestPlan.anchorCursorValue" in body
    assert "historyStartDate: manifestPlan.historyStartDate" in body
    assert "forceRepublishAll: manifestPlan.forceRepublishAll" in body
    reservation = body.index("sleepManifestStore.saveManifest(reservation)")
    journal = body.index("sleepManifestStore.savePendingTransition(pendingTransition)")
    delivery = body.index("deliverPendingSleepTransition(", journal)
    manifest_commit = body.index("try store.saveManifest(pendingTransition.manifest)")
    journal_clear = body.index(
        "try store.clearPendingTransition(id: pendingTransition.id)"
    )
    assert reservation < journal < delivery < manifest_commit < journal_clear


def test_ui_describes_one_supported_automatic_sync_scope() -> None:
    content = CONTENT_VIEW.read_text()
    ux_state = UX_STATE.read_text()

    assert "CompanionAutomaticSyncCoveragePresentation" in ux_state
    assert "viewModel.automaticSyncScopeSummary" in content
    assert "viewModel.automaticSyncCoverageDetail" in content
    assert "Best-effort only. iOS decides timing; use Sync Now" not in content
    assert "Sync Now only" not in content


def test_active_background_model_has_no_optional_eligibility_gate() -> None:
    source = BACKGROUND_SYNC.read_text()

    assert "BackgroundQuantitySyncStatus" in source
    assert "BackgroundOptionalQuantitySyncStatus" not in source
    assert "skippedNoEligibleSelection" not in source
    assert "optionalQuantityTypeCodesForBackground" not in source
    assert "optionalQuantityStatusForBackgroundSelection" not in source


def test_sync_now_names_the_unified_supported_quantity_lane() -> None:
    ux_state = UX_STATE.read_text()
    view_model = VIEW_MODEL.read_text()

    assert "syncSupportedQuantityMetrics" in ux_state
    assert "syncSelectedOptionalMetrics" not in ux_state
    assert "syncSupportedQuantityMetrics" in view_model
    assert "syncSelectedOptionalQuantityMetrics" not in view_model


def test_observed_quantity_state_is_not_an_eligibility_gate() -> None:
    background = BACKGROUND_SYNC.read_text()
    view_model = VIEW_MODEL.read_text()

    assert "QuantityObservationStore" in background
    assert "observedTypeCodes" in background
    assert "OptionalQuantityForegroundValidationStore" not in background
    assert "foregroundConfirmedTypeCodes:" not in background
    assert "optionalQuantitySelectionStore" not in view_model
    assert "optionalQuantitySelectedTypeCodes" not in view_model


def test_public_copy_does_not_claim_every_observer_registration_succeeds() -> None:
    readme = (ROOT / "README.md").read_text()
    architecture = (ROOT / "docs" / "architecture.md").read_text()
    testflight = (ROOT / ".github" / "release" / "testflight-checklist.md").read_text()
    review_notes = (
        ROOT / "docs" / "maintainers" / "app-review-notes-template.example.md"
    ).read_text()

    assert "Full observer registration" not in readme
    assert (
        "All runtime-available supported sample types are registered"
        not in architecture
    )
    assert (
        "Automatic Sync registers every runtime-available data type" not in testflight
    )
    assert "implemented sync lanes selected by the user" not in review_notes

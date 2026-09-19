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
AUTOMATIC_SYNC_RUNTIME = (
    ROOT / "ios" / "HealthBridgeCompanion" / "App" / "AutomaticSyncRuntime.swift"
)
CONTENT_VIEW = ROOT / "ios" / "HealthBridgeCompanion" / "App" / "ContentView.swift"
UX_STATE = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "Sources"
    / "HealthBridgeCompanionCore"
    / "CompanionUXState.swift"
)
GENERIC_QUANTITY_READER = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "Sources"
    / "HealthBridgeCompanionCore"
    / "HealthKitGenericQuantityReader.swift"
)
GENERIC_QUANTITY_BATCH_FACTORY = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "Sources"
    / "HealthBridgeCompanionCore"
    / "GenericQuantitySyncBatchFactory.swift"
)
GENERIC_QUANTITY_BATCH_FACTORY_TESTS = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "Tests"
    / "HealthBridgeCompanionCoreTests"
    / "GenericQuantitySyncBatchFactoryTests.swift"
)


def test_background_delivery_plan_accepts_all_automatic_quantity_types() -> None:
    source = BACKGROUND_SYNC.read_text()

    assert "observedHealthTypes(\n        automaticQuantityTypeCodes:" in source
    assert (
        "backgroundDeliveryRegistrationPlan(\n        automaticQuantityTypeCodes:"
        in source
    )


def test_healthkit_observer_reports_the_triggering_type_code() -> None:
    source = READ_TYPE_CATALOG.read_text()

    handler_arguments = (
        "(_ typeCode: String, _ runID: UUID) async -> AutomaticSyncDiagnosticDraft?"
    )
    event_handler_signature = f"eventHandler: @escaping @MainActor {handler_arguments}"
    assert event_handler_signature in source
    assert "await eventHandler(healthType.typeCode, runID)" in source


def test_healthkit_observer_restart_does_not_race_disable_against_enable() -> None:
    source = READ_TYPE_CATALOG.read_text()
    start_body = source.split("public func start(", 1)[1].split("public func stop(", 1)[
        0
    ]

    assert "stopActiveObserverQueries()" in start_body
    assert "disableBackgroundDelivery" not in start_body


def test_view_model_registers_and_syncs_unified_automatic_coverage() -> None:
    source = VIEW_MODEL.read_text()
    runtime = AUTOMATIC_SYNC_RUNTIME.read_text()

    assert "optionalTypeCodes: []" not in source
    assert "automaticQuantityTypeCodes: availableQuantityTypeCodes" in source
    assert "func runAutomaticSync(" in runtime
    assert "reason: AutomaticSyncReason" in runtime
    assert "diagnosticRunID: UUID = UUID()" in runtime
    assert "typeCodes: [typeCode]" in source
    assert "historyDepth: .lastDays(1)" in source


def test_connection_check_does_not_report_queued_test_payload_as_passed() -> None:
    source = VIEW_MODEL.read_text()
    check_connection = source.split("func checkConnection() async", 1)[1].split(
        "func performPrimaryAction() async", 1
    )[0]
    send_test = source.split("func sendConnectionTestBatch() async", 1)[1].split(
        "func syncRecentStepCounts", 1
    )[0]

    assert "Connection check passed. Queued uploads" not in check_connection
    assert "statusIsError = deliveryResult.directUpload == nil" in send_test


def test_background_entry_points_pass_explicit_sync_reasons() -> None:
    runtime = AUTOMATIC_SYNC_RUNTIME.read_text()
    app = APP.read_text()

    observer_entry = runtime.split("self?.engine.requestRunWithoutWaiting(", 1)[
        1
    ].split("return nil", 1)[0]
    assert "reason: .observer(typeCode: typeCode)" in observer_entry
    assert "diagnosticRunID: diagnosticRunID" in observer_entry
    assert "engine.requestRun(reason: .launchCatchUp)" in runtime
    assert "await applicationRuntime.handleBackgroundRefresh()" in app
    handler = runtime.split("func handleBackgroundRefresh() async", 1)[1].split(
        "func runAutomaticSync(", 1
    )[0]
    assert "reason: .scheduledRefresh" in handler


def test_automatic_core_sync_uses_one_day_fallback_without_authorization() -> None:
    source = VIEW_MODEL.read_text()

    assert source.count("if executionMode.shouldRequestReadAuthorization") >= 4
    assert source.count("executionMode.cursorlessFallbackDays") >= 3
    assert (
        source.count("clampStoredBootstrapToLookback: executionMode == .automatic") == 2
    )


def test_ios_daily_aggregate_finalization_contract() -> None:
    reader = GENERIC_QUANTITY_READER.read_text()
    factory = GENERIC_QUANTITY_BATCH_FACTORY.read_text()
    regression_tests = GENERIC_QUANTITY_BATCH_FACTORY_TESTS.read_text()

    assert "public let isComplete: Bool" in factory
    assert "isComplete: Bool = true" in factory
    assert "isComplete: statistics.endDate <= end" in reader
    assert "aggregate.isComplete," in factory
    assert '"aggregation_completeness": "complete"' in factory
    assert (
        "testDailyActivityAggregateFactoryPublishesOnlyCompletedLocalDays"
        in regression_tests
    )
    assert "isComplete: false" in regression_tests
    assert "isComplete: true" in regression_tests


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

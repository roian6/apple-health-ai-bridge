from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW_MODEL = ROOT / "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
CORE = (
    ROOT
    / "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore"
    / "StepCountSyncBatchFactory.swift"
)
FILE_OUTBOX = (
    ROOT
    / "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore"
    / "FileOutbox.swift"
)
APP = ROOT / "ios/HealthBridgeCompanion/App/HealthBridgeCompanionApp.swift"
BACKGROUND_UPLOADER = (
    ROOT / "ios/HealthBridgeCompanion/App/BackgroundURLSessionOutboxUploader.swift"
)
HEALTHKIT_STEPS = (
    ROOT
    / "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore"
    / "HealthKitStepCountReader.swift"
)
HEALTHKIT_QUANTITIES = (
    ROOT
    / "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore"
    / "HealthKitGenericQuantityReader.swift"
)


def test_sleep_transition_is_journaled_before_delivery() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    create_start = source.index("let pendingTransition = SleepSyncPendingTransition(")
    journal = source.index(
        "try sleepManifestStore.savePendingTransition(pendingTransition)",
        create_start,
    )
    delivery = source.index(
        "return try await deliverPendingSleepTransition(",
        journal,
    )
    assert create_start < journal < delivery


def test_sleep_manifest_commits_only_after_tracked_outbox_item_is_absent() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    helper_start = source.index("private func deliverPendingSleepTransition(")
    helper_end = source.index("\n    func syncSupportedQuantityMetrics()", helper_start)
    helper = source[helper_start:helper_end]

    enqueue = helper.index("let enqueueResult = try outbox.enqueueIfAbsent(")
    track = helper.index("try store.savePendingTransition(trackedTransition)")
    absence_gate = helper.index("if itemRemains {")
    manifest_commit = helper.rindex(
        "try store.saveManifest(pendingTransition.manifest)"
    )
    journal_clear = helper.rindex(
        "try store.clearPendingTransition(id: pendingTransition.id)"
    )
    assert enqueue < track < absence_gate < manifest_commit < journal_clear
    assert "if enqueueResult.wasInserted" in helper[track:absence_gate]


def test_clear_pending_uploads_uses_durable_intent_and_removes_it_last() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    start = source.index("func clearPendingOutbox()")
    end = source.index("\n    func bootstrap()", start)
    operation = source[start:end]
    expected_capture = "".join(  # noqa: FLY002
        (
            "let expectedConnectionGeneration = ",
            "settingsStore.receiverSettingsGenerationToken",
        )
    )
    expected_generation = operation.index(expected_capture)
    begin = operation.index("try outbox.beginClearIntent()")
    stop = operation.index("automaticSyncActivated = false")
    stop_healthkit = operation.index("stopHealthKitBackgroundDelivery()")
    cancel = operation.index("await self.cancelAndAwaitForegroundPayloadTasks()")
    exclusive = operation.index("runWithExclusiveDirectOutboxTransfer")
    generation = operation.index(
        "try self.requireUnchangedConnectionGenerationDuringRecovery("
    )
    assert "try self.requireCurrentConnectionGeneration(" not in operation[:begin]
    assert "expectedConnectionGeneration" in operation[generation:begin]
    assert "sleepManifestStore?.resetSynchronizationState()" not in operation
    assert (
        expected_generation
        < stop
        < stop_healthkit
        < cancel
        < exclusive
        < generation
        < begin
    )
    perform = operation[operation.index("private func performClearPendingOutbox(") :]
    perform_reset = perform.index("try resetPrivateSyncProgressForClear()")
    outbox_clear = perform.index("try outbox.clearPendingWhileIntentIsActive()")
    finish = perform.index("try outbox.finishClearIntent()")
    assert perform_reset < outbox_clear < finish
    assert "activateAutomaticSyncIfReady()" in operation

    pairing = (ROOT / "docs/pairing.md").read_text(encoding="utf-8")
    durability = (ROOT / "docs/architecture.md").read_text(encoding="utf-8")
    assert (
        pairing.index("stops HealthKit background delivery")
        < pairing.index("revalidates the connection generation")
        < pairing.index("persist the private clear intent")
    )
    assert "Deleting queued uploads first" not in durability
    assert durability.index("connection generation is revalidated") < durability.index(
        "durable clear intent is persisted"
    )

    recovery_start = source.index("private func recoverPendingOutboxClearIfNeeded()")
    recovery_end = source.index(
        "\n    func resumePendingPairingIfNeeded()", recovery_start
    )
    recovery = source[recovery_start:recovery_end]
    recovery_reset = recovery.index("try resetPrivateSyncProgressForClear()")
    recovery_finish = recovery.index("try outbox.finishClearIntent()")
    assert recovery_reset < recovery_finish
    assert "hasPendingPrivateStorageRecovery = false" in recovery
    assert "hasTransientPrivateStorageFailure = false" in recovery

    helper_start = source.index("private func resetPrivateSyncProgressForClear()")
    helper_end = source.index(
        "\n    private func performClearPendingOutbox(", helper_start
    )
    helper = source[helper_start:helper_end]
    for required_reset in (
        "try sleepManifestStore.resetSynchronizationState()",
        "try cursorStore.resetAll()",
        "coreLaneUploadProofStore.resetAll()",
        "historicalBackfillStateStore.reset()",
    ):
        assert required_reset in helper


def test_private_storage_preflight_precedes_bootstrap_activation_and_fifo_flush() -> (
    None
):
    source = VIEW_MODEL.read_text(encoding="utf-8")
    bootstrap_start = source.index("private func performBootstrap()")
    bootstrap_end = source.index(
        "\n    private func recoverPendingOutboxClearIfNeeded", bootstrap_start
    )
    bootstrap = source[bootstrap_start:bootstrap_end]
    assert bootstrap.index("runWithExclusiveDirectOutboxTransfer") < bootstrap.index(
        "preparePrivateStorageForUploadAdmission()"
    )
    assert bootstrap.index(
        "preparePrivateStorageForUploadAdmission()"
    ) < bootstrap.index("activateAutomaticSyncIfReady()")

    sync_start = source.index("private func performSyncAllNow()")
    sync_end = source.index("\n    private func flushPendingOutbox()", sync_start)
    sync = source[sync_start:sync_end]
    assert sync.index("preparePrivateStorageForUploadAdmission()") < sync.index(
        "CompanionSyncNowPlan.defaultSteps"
    )

    ready_start = source.index("private var automaticSyncEnablePrerequisitesReady")
    ready_end = source.index("\n    var canSaveReceiverSettings", ready_start)
    assert "privateStorageAdmissionReady" in source[ready_start:ready_end]


def test_rejected_sleep_epoch_recovery_is_durable_before_fifo_retirement() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    core = FILE_OUTBOX.read_text(encoding="utf-8")
    recovery_start = core.index("public enum SleepBaselineRejectionRecovery")
    recovery_end = core.index(
        "\npublic enum KeychainReceiverTokenStoreError", recovery_start
    )
    recovery = core[recovery_start:recovery_end]
    save = recovery.index("savePendingTransition(rejectedTransition)")
    reserve = recovery.index("epochStore.reserveEpoch")
    retire = recovery.index("outbox.markUploaded")
    reset = recovery.index("manifestStore.resetSynchronizationState()")
    assert save < reserve < retire < reset

    view_recovery_start = source.index("private func recoverRejectedSleepBaseline(")
    view_recovery_end = source.index(
        "\n    private func uploadPendingOutbox(", view_recovery_start
    )
    assert (
        "SleepBaselineRejectionRecovery.recover("
        in source[view_recovery_start:view_recovery_end]
    )

    flush_start = source.index("private func flushPendingOutbox()")
    flush_end = source.index("\n    func clearPendingOutbox()", flush_start)
    assert "RejectedSleepBaselineOutboxItem" in source[flush_start:flush_end]
    sync_start = source.index("private func performSyncAllNow() async")
    sync_end = source.index("\n    private func flushPendingOutbox()", sync_start)
    sync = source[sync_start:sync_end]
    assert sync.index("case .flushPendingOutboxBeforeSync") < sync.index(
        "case .syncSleep"
    )
    assert "await flushPendingOutbox()" in sync


def test_background_sleep_conflict_body_is_recovered_before_task_finalization() -> None:
    uploader = BACKGROUND_UPLOADER.read_text(encoding="utf-8")
    assert "URLSessionDataDelegate" in uploader
    assert "didReceive data: Data" in uploader
    completion_start = uploader.index("didCompleteWithError error: Error?")
    completion_end = uploader.index("urlSessionDidFinishEvents", completion_start)
    completion = uploader[completion_start:completion_end]
    take_body = completion.index("takeResponseBody(for: taskID)")
    current_task_start = completion.index("Task { @MainActor")
    current_task = completion[current_task_start:]
    finish = current_task.index("self.finishCompletedUpload(")
    barrier = current_task.index("await completionBarrier.complete(taskID)")
    parse = completion.index("sleepBaselineConflictMinimumResetEpoch(")
    persist = completion.index("taskOwnershipStore.recordCompletion(")
    helper_start = completion.index("private func finishCompletedUpload(")
    helper = completion[helper_start:]
    recover = helper.index("SleepBaselineRejectionRecovery.recover(")
    assert take_body < parse < persist < current_task_start
    assert finish < barrier
    assert recover >= 0


def test_automatic_runs_revalidate_private_storage_before_healthkit_lanes() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    start = source.index("private func performAdmittedBackgroundRefreshSync(")
    end = source.index("\n    private func stopBackgroundRunIfUnavailable", start)
    operation = source[start:end]
    assert operation.index(
        "preparePrivateStorageForUploadAdmission()"
    ) < operation.index("syncRecentStepCounts")


def test_transient_installation_identity_and_bootstrap_failures_are_retryable() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    assert "private let pairingStateStore: ReceiverPairingStateStore" in source
    assert "private var sleepSourceKey: String?" in source
    preflight_start = source.index(
        "private func preparePrivateStorageForUploadAdmission()"
    )
    preflight_end = source.index(
        "\n    private func recoverRejectedSleepBaseline", preflight_start
    )
    preflight = source[preflight_start:preflight_end]
    assert "pairingStateStore.loadOrCreateInstallationID()" in preflight

    app_source = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionApp.swift"
    ).read_text(encoding="utf-8")
    active_start = app_source.index("if newPhase == .active")
    active_end = app_source.index("} else if newPhase == .background", active_start)
    assert "await viewModel.bootstrap()" in app_source[active_start:active_end]


def test_nil_item_is_reconciled_by_exact_payload_before_migration() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    start = source.index("private func matchingPendingSleepOutboxItems(")
    end = source.index(
        "\n    private func preparePrivateStorageForUploadAdmission", start
    )
    reconcile = source[start:end]
    assert "Data(contentsOf: item.fileURL) == pendingTransition.payload" in reconcile
    assert "assigningOutboxItemID(item.id)" in reconcile


def test_private_store_retry_recovery_and_manifest_probe_are_explicit() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    assert "private var outbox: FileOutbox?" in source
    assert "private var sleepManifestStore: SleepSyncManifestStoring?" in source
    assert "retryPrivateStoreInitialization()" in source
    assert "FileOutbox.beginDestructiveRecovery" in source
    assert "FileOutbox.completeDestructiveRecovery" in source

    probe_start = source.index("private static func sleepStorageMayNeedRecovery(")
    probe_end = source.index(
        "\n    private func refreshPendingOutboxCount()", probe_start
    )
    probe = source[probe_start:probe_end]
    assert "loadManifest()" in probe
    assert "loadPendingTransition()" in probe

    refresh_start = source.index("private func refreshPendingOutboxCount()")
    refresh_end = source.index(
        "\n    private static func receiverSettingsAreComplete", refresh_start
    )
    refresh = source[refresh_start:refresh_end]
    assert "outbox = nil" in refresh
    assert "hasPendingOutboxDeletion = true" in refresh


def test_clear_intent_is_persisted_only_after_transfer_cancellation() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    start = source.index("func clearPendingOutbox()")
    end = source.index("\n    private func resetPrivateSyncProgressForClear", start)
    operation = source[start:end]
    exclusive = operation.index("runWithExclusiveDirectOutboxTransfer")
    cancel_foreground = operation.index("cancelAndAwaitForegroundPayloadTasks")
    begin_intent = min(
        index
        for marker in ("beginClearIntent()", "beginDestructiveRecovery")
        if (index := operation.find(marker)) >= 0
    )
    assert cancel_foreground < exclusive < begin_intent


def test_swift_sources_do_not_contain_compile_placeholder_tokens() -> None:
    background_sync = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/BackgroundSync.swift"
    ).read_text(encoding="utf-8")
    assert "Bool ***" not in background_sync


def test_bootstrap_single_flight_keeps_attempt_identity() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    assert "private var bootstrapAttemptID: UUID?" in source
    bootstrap_start = source.index("func bootstrap()")
    bootstrap_end = source.index(
        "\n    private func performBootstrap()", bootstrap_start
    )
    bootstrap = source[bootstrap_start:bootstrap_end]
    assert "guard bootstrapAttemptID == attemptID else { return }" in bootstrap
    assert "bootstrapWaiters[waiterID] = continuation" in bootstrap
    assert "cancelBootstrapWaiter(waiterID, attemptID: attemptID)" in bootstrap
    assert "let attemptTask: Task<Void, Never>" in bootstrap
    assert "if attemptTask.isCancelled, !Task.isCancelled" in bootstrap
    assert "await attemptTask.value" in bootstrap

    perform_start = source.index("private func performBootstrap()")
    perform_end = source.index(
        "\n    func resumePendingPairingIfNeeded()", perform_start
    )
    perform = source[perform_start:perform_end]
    preflight = perform.index("runWithExclusiveDirectOutboxTransfer")
    post_preflight_cancel = perform.index(
        "guard !Task.isCancelled else { return }", preflight
    )
    activate = perform.index("activateAutomaticSyncIfReady()")
    assert preflight < post_preflight_cancel < activate

    clear_start = source.index("func clearPendingOutbox()")
    clear_end = source.index(
        "\n    private func performClearPendingOutbox", clear_start
    )
    clear = source[clear_start:clear_end]
    assert "bootstrapTask = nil" not in clear
    assert "await retryBootstrapAfterRecoveryIfNeeded()" in clear


def test_missing_outbox_and_unreadable_sleep_journal_fail_closed_and_stay_visible() -> (
    None
):
    source = VIEW_MODEL.read_text(encoding="utf-8")
    upload_start = source.index("private func uploadPayloadsWithOutbox(")
    upload_end = source.index("\n    private func enqueuePayloads(", upload_start)
    upload = source[upload_start:upload_end]
    assert "guard let outbox else" in upload
    assert upload.count("var lastResult: ReceiverUploadResult?") == 1

    refresh_start = source.index("private func refreshPendingOutboxCount()")
    refresh_end = source.index(
        "\n    private static func receiverSettingsAreComplete", refresh_start
    )
    refresh = source[refresh_start:refresh_end]
    assert "sleepStorageMayNeedRecovery()" in refresh
    probe_start = source.index("private static func sleepStorageMayNeedRecovery(")
    assert "catch" in source[probe_start:refresh_start]


def test_core_anchored_lanes_bind_durable_payloads_to_cursor_checkpoints() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    method_ranges = (
        ("func syncRecentStepCounts(", "func syncDailyActivityAggregates("),
        ("func syncDailyActivityAggregates(", "func syncRecentWorkouts("),
        ("func syncRecentWorkouts(", "func syncAnchoredWorkoutChanges("),
        ("func syncAnchoredWorkoutChanges(", "func syncRecentSleepSessions("),
    )

    for start_marker, end_marker in method_ranges:
        start = source.index(start_marker)
        end = source.index(end_marker, start)
        body = source[start:end]
        checkpoint = body.index("FileOutboxCursorCheckpoint(")
        enqueue = body.index("cursorCheckpoint: cursorCheckpoint", checkpoint)
        save = body.index("try cursorStore.saveCursorValue(", enqueue)
        acknowledge = body.index(
            "try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)",
            save,
        )
        assert checkpoint < enqueue < save < acknowledge

    proof_lane_ranges = (
        (
            "func syncRecentStepCounts(",
            "func syncDailyActivityAggregates(",
            ".steps",
        ),
        (
            "func syncAnchoredWorkoutChanges(",
            "func syncRecentSleepSessions(",
            ".workouts",
        ),
    )
    for start_marker, end_marker, lane in proof_lane_ranges:
        start = source.index(start_marker)
        end = source.index(end_marker, start)
        body = source[start:end]
        checkpoint_proof = body.index(
            f"coreLaneUploadProof: uploadedRecords ? {lane} : nil"
        )
        save = body.index("try cursorStore.saveCursorValue(", checkpoint_proof)
        proof = body.index("coreLaneUploadProofStore.markUploadedRecords(", save)
        acknowledge = body.index(
            "try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)", proof
        )
        assert checkpoint_proof < save < proof < acknowledge

    recovery_start = source.index(
        "if let cursorCheckpoint = try outbox.pendingCursorCheckpoint()"
    )
    recovery_end = source.index(
        "_ = try sleepManifestStore.loadManifest()", recovery_start
    )
    recovery = source[recovery_start:recovery_end]
    save = recovery.index("try cursorStore.saveCursorValue(")
    proof = recovery.index("switch cursorCheckpoint.coreLaneUploadProof")
    acknowledge = recovery.index(
        "try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)"
    )
    assert save < proof < acknowledge


def test_failed_bootstrap_can_retry_after_clear_and_background_sync_reactivates() -> (
    None
):
    source = VIEW_MODEL.read_text(encoding="utf-8")
    bootstrap_start = source.index("func bootstrap()")
    bootstrap_end = source.index(
        "\n    private func performBootstrap()", bootstrap_start
    )
    bootstrap = source[bootstrap_start:bootstrap_end]
    assert "bootstrapTask = nil" in bootstrap

    clear_start = source.index("func clearPendingOutbox()")
    clear_end = source.index("\n    func bootstrap()", clear_start)
    clear = source[clear_start:clear_end]
    assert "activateAutomaticSyncIfReady()" in clear


def test_round_one_sleep_state_is_migrated_before_pending_replay() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    sync_start = source.index("func syncRecentSleepSessions(")
    replay = source.index("deliverPendingSleepTransition(", sync_start)
    migration = source.index("requiresInstallationSourceMigration(", sync_start)
    assert migration < replay


def test_sleep_journal_is_visible_and_generation_is_rechecked_after_healthkit() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    content = (ROOT / "ios/HealthBridgeCompanion/App/ContentView.swift").read_text(
        encoding="utf-8"
    )
    sync_start = source.index("func syncRecentSleepSessions(")
    read = source.index(
        "try await HealthKitSleepReader().readAnchoredSleepChanges(", sync_start
    )
    recheck = source.index(
        "try requireCurrentConnectionGeneration(currentReceiverGeneration)", read
    )
    journal = source.index(
        "try sleepManifestStore.savePendingTransition(pendingTransition)", recheck
    )
    assert read < recheck < journal
    assert "viewModel.hasPendingSleepTransition" in content
    assert "viewModel.hasPendingOutboxDeletion" in content


def test_sleep_epoch_conflict_reports_floor_and_reserves_above_it() -> None:
    receiver = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ReceiverClient.swift"
    ).read_text(encoding="utf-8")
    view_model = VIEW_MODEL.read_text(encoding="utf-8")
    server = Path("src/health_bridge/receiver/server.py").read_text(encoding="utf-8")

    assert '"sleep_baseline_reset_epoch_conflict"' in server
    assert '"minimum_reset_epoch"' in server
    assert "sleepBaselineResetEpochConflict" in receiver
    assert "catch let conflict as RejectedSleepBaselineOutboxItem" in view_model
    assert "sleepResetEpochStore.reserveEpoch(" in view_model


def test_sleep_baseline_uses_installation_source_and_ordered_epoch() -> None:
    view_model = VIEW_MODEL.read_text(encoding="utf-8")
    core = CORE.read_text(encoding="utf-8")
    assert '"apple_health.phone.\\($0.lowercased())"' in view_model
    assert "sleepResetEpochStore.reserveEpoch(" in view_model
    assert 'let resetCursorValue = "v2:\\(resolvedResetEpoch)"' in core
    assert "phone(sourceKey: resolvedSourceKey)" in core


def test_non_sleep_progress_is_receiver_scoped_and_fail_closed() -> None:
    view_model = VIEW_MODEL.read_text(encoding="utf-8")
    file_outbox = FILE_OUTBOX.read_text(encoding="utf-8")

    assert 'versionedKeyPrefix = "receiver_binding_v1#"' in file_outbox
    assert (
        "\\(versionedKeyPrefix)\\(receiverBindingID)#\\(sourceKey)#\\(cursorKind)"
        in file_outbox
    )
    assert (
        'versionedKeyPrefix = "coreLaneUploadedRecords.receiver_binding_v1"'
        in file_outbox
    )
    assert (
        "\\(versionedKeyPrefix).\\(receiverBindingID).\\(lane.rawValue)" in file_outbox
    )
    for call in ("cursorStore.cursorValue(", "cursorStore.saveCursorValue("):
        start = 0
        while (index := view_model.find(call, start)) >= 0:
            assert "receiverBindingID:" in view_model[index : index + 260]
            start = index + len(call)
    assert "hasUploadedRecords(lane: .steps)" not in view_model
    assert "hasUploadedRecords(lane: .workouts)" not in view_model
    assert "markUploadedRecords(lane: .steps)" not in view_model
    assert "markUploadedRecords(lane: .workouts)" not in view_model


def test_private_storage_preflight_retries_atomic_connection_and_cursor_store() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    start = source.index("private func retryPrivateStoreInitialization()")
    end = source.index("private func matchingPendingSleepOutboxItems", start)
    preflight = source[start:end]

    assert preflight.index("ensureAtomicConnectionRecord()") < preflight.index(
        "migrateLegacyHashedReceiverIdentities"
    )
    assert "cursorStore = try FileSyncCursorStore" in preflight
    assert "try cursorStore.validateReadableAndWritable()" in preflight
    assert "hasPendingPrivateStorageRecovery = true" in preflight
    assert (
        "ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(error)"
        in preflight
    )
    assert "ReceiverOutboxAdmissionPolicy.isReady(" in preflight
    assert "outboxIdentityMigrationReady = false" in preflight


def test_pairing_entry_points_stay_closed_until_private_recovery_completes() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    import_start = source.index("var canImportPairingText: Bool")
    import_end = source.index("var canRedeemManualPairing: Bool", import_start)
    redeem_end = source.index("var canSyncStepCounts: Bool", import_end)

    for block in (source[import_start:import_end], source[import_end:redeem_end]):
        assert "!hasPendingPrivateStorageRecovery" in block
        assert "privateStorageAdmissionReady" in block

    resume_start = source.index("private func performResumePendingPairingIfNeeded()")
    resume_end = source.index("func cancelPendingPairing() async", resume_start)
    resume = source[resume_start:resume_end]
    assert "!hasPendingPrivateStorageRecovery" in resume
    assert "outboxIdentityMigrationReady" in resume

    cold_url_start = source.index("func importPairingURL(_ url: URL) async")
    cold_url_end = source.index("private func performImportPairingURL", cold_url_start)
    cold_url = source[cold_url_start:cold_url_end]
    pending_match = cold_url.index("pairingCoordinator.pendingPairingMatches")
    decision = cold_url.index("ReceiverIncomingPairingPolicy.decision(")
    reject_different = cold_url.index("case .rejectDifferentPending:")
    resume_matching = cold_url.index("case .resumeMatchingPending:")
    bootstrap_wait = cold_url.index("await bootstrap()", resume_matching)
    tracked_operation = cold_url.index("await runTrackedPairingOperation {")
    assert (
        pending_match
        < decision
        < reject_different
        < resume_matching
        < bootstrap_wait
        < tracked_operation
    )

    for name, end_marker in (
        ("private func performImportPairingText()", "func importPairingURL("),
        ("private func performImportPairingURL(", "func redeemManualPairing()"),
        (
            "private func performRedeemManualPairing()",
            "private func applyPairingMaterial(",
        ),
    ):
        start = source.index(name)
        block = source[start : source.index(end_marker, start)]
        assert "privateStorageAdmissionReady" in block
        assert "!hasPendingPrivateStorageRecovery" in block


def test_destructive_recovery_resets_all_progress_and_unreadable_connection() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    helper_start = source.index("private func resetPrivateSyncProgressForClear()")
    helper_end = source.index(
        "\n    private func performClearPendingOutbox(", helper_start
    )
    reset = source[helper_start:helper_end]
    recovery_start = source.index("func clearPendingOutbox() async")
    recovery_end = source.index(
        "private func resetPrivateSyncProgressForClear", recovery_start
    )
    recovery = source[recovery_start:recovery_end]
    clear_start = helper_end
    clear_end = source.index("\n    func bootstrap()", clear_start)
    clear = source[clear_start:clear_end]

    assert "connectionTerminalBarrier.performRecovery(" in recovery
    assert "drainBackgroundPayloads:" in recovery
    assert "await self.drainBackgroundPayloadCancellation()" in recovery
    assert "try resetPrivateSyncProgressForClear()" in clear
    assert "try settingsStore.resolveTerminalCancellationForPrivateReset()" in reset
    assert "try pairingStateStore.resetPrivatePairingState()" in reset
    assert "hasPendingPairing = false" in reset
    assert "try cursorStore.resetAll()" in reset
    assert "coreLaneUploadProofStore.resetAll()" in reset
    assert "historicalBackfillStateStore.reset()" in reset
    assert "settingsStore.resetInvalidConnectionRecord()" in reset


def test_transient_private_storage_failure_is_retryable_not_destructive() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    file_outbox = FILE_OUTBOX.read_text(encoding="utf-8")
    content_view = (ROOT / "ios/HealthBridgeCompanion/App/ContentView.swift").read_text(
        encoding="utf-8"
    )

    assert (
        "ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(error)"
        in source
    )
    assert "catch FileSyncCursorStoreError.invalidData" in source
    assert "hasTransientPrivateStorageFailure = true" in source
    assert 'Label("Retry Private Storage"' in content_view
    reset_start = file_outbox.index("public func resetInvalidConnectionRecord()")
    reset_end = file_outbox.index(
        "public func beginTerminalCancellationIntent", reset_start
    )
    reset = file_outbox[reset_start:reset_end]
    assert "if try loadConnectionRecord() != nil" in reset
    assert "let legacyToken = try tokenStore.loadToken()" in reset
    assert "explicitLegacyURL == nil" in reset
    assert "destructiveResetNotRequired" in reset
    assert "UInt64.random(in: 1 ... UInt64(Int.max))" in reset


def test_bg_task_cancellation_propagates_to_bootstrap_and_sync_children() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")
    bootstrap_start = source.index("func bootstrap() async")
    bootstrap_end = source.index("private func performBootstrap()", bootstrap_start)
    bootstrap = source[bootstrap_start:bootstrap_end]
    sync_start = source.index("func runBackgroundRefreshSync(reason:")
    sync_end = source.index("private func performBackgroundRefreshSync", sync_start)
    sync = source[sync_start:sync_end]

    assert "withTaskCancellationHandler" in bootstrap
    assert "cancelBootstrapWaiter" in bootstrap
    assert "bootstrapTask?.cancel()" in bootstrap
    assert "withTaskCancellationHandler" in sync
    assert "task.cancel()" in sync
    background_task = app[app.index(".backgroundTask(") :]
    assert background_task.count("guard !Task.isCancelled else { return }") >= 2


def test_healthkit_queries_and_exclusive_gate_are_cancellation_aware() -> None:
    steps = HEALTHKIT_STEPS.read_text(encoding="utf-8")
    quantities = HEALTHKIT_QUANTITIES.read_text(encoding="utf-8")
    gate = FILE_OUTBOX.read_text(encoding="utf-8")

    assert "executeCancellableHealthKitQuery" in steps
    assert "healthStore.stop(query)" in steps
    assert steps.count("healthStore.execute(query)") == 1
    assert "withCheckedThrowingContinuation" not in quantities
    assert "public func acquire() async throws" in gate
    assert "cancelWaiter" in gate

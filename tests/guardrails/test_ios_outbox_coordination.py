from pathlib import Path

VIEW_MODEL = Path("ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift")
UPLOADER = Path(
    "ios/HealthBridgeCompanion/App/BackgroundURLSessionOutboxUploader.swift"
)


def test_direct_sync_takes_exclusive_outbox_handoff_before_uploading() -> None:
    text = VIEW_MODEL.read_text()

    for required in (
        "private let directOutboxTransferGate = AsyncExclusiveAccessGate()",
        "directOutboxTransferRequestCount += 1",
        "await directOutboxTransferGate.acquire()",
        "await cancelBackgroundOutboxSchedulingIfNeeded()",
        "await BackgroundURLSessionOutboxUploader.shared.cancelPendingUploads()",
        "await directOutboxTransferGate.release()",
        "directOutboxTransferRequestCount == 0",
        "await self.performClearPendingOutbox(outbox: self.outbox)",
        "await self.performSendConnectionTestBatch()",
    ):
        assert required in text


def test_connection_test_revalidates_receiver_after_exclusive_handoff() -> None:
    text = VIEW_MODEL.read_text()
    start = text.index("private func performSendConnectionTestBatch() async")
    end = text.index("func syncRecentStepCounts(", start)
    body = text[start:end]

    readiness = body.index("guard canSendConnectionTest, !Task.isCancelled")
    upload = body.index("await uploadPayloadsWithOutbox(")
    assert readiness < upload


def test_background_refresh_coalesces_observer_admission_before_transfer_handoff() -> (
    None
):
    text = VIEW_MODEL.read_text()
    start = text.index("private func performBackgroundRefreshSync(reason:")
    end = text.index("private func performAdmittedBackgroundRefreshSync(", start)
    admission_body = text[start:end]

    admission = admission_body.index("await backgroundRunGate.beginRun(reason: reason")
    transfer_handoff = admission_body.index(
        "await runWithExclusiveDirectOutboxTransfer"
    )
    assert admission < transfer_handoff


def test_background_refresh_revalidates_automatic_sync_after_transfer_handoff() -> None:
    text = VIEW_MODEL.read_text()
    start = text.index("private func performAdmittedBackgroundRefreshSync(")
    end = text.index("private func stopBackgroundRunIfUnavailable(", start)
    admitted_body = text[start:end]

    eligibility_check = admitted_body.index(
        "await stopBackgroundRunIfUnavailable(startedAt: startedAt)"
    )
    first_health_read = admitted_body.index("await self.syncRecentStepCounts(")
    assert eligibility_check < first_health_read

    stop_start = end
    stop_end = text.index("func requestHealthPermissions()", stop_start)
    stop_body = text[stop_start:stop_end]
    for required in (
        "automaticSyncReady",
        "backgroundSyncEnabled",
        "canSendConnectionTest",
        "await finishBackgroundRunPreservingObserverDirtiness(",
    ):
        assert required in stop_body


def test_background_event_completion_waits_for_persistent_finalization() -> None:
    text = UPLOADER.read_text()

    required_fragments = (
        "BackgroundEventFinalizationCoordinator<Int>()",
        "eventFinalizationCoordinator.begin(taskID)",
        "finalizationCoordinator.complete(taskID)",
        "eventFinalizationCoordinator.markEventsFinished()",
        "eventFinalizationCoordinator.setCompletionHandler(completionHandler)",
    )
    for fragment in required_fragments:
        assert fragment in text


def test_build3_background_tasks_cancel_before_bootstrap() -> None:
    uploader = UPLOADER.read_text()
    view_model = VIEW_MODEL.read_text()

    for fragment in (
        "HealthBridgeAppIdentity.legacyBackgroundUploadSessionIdentifiers",
        "legacyCancellationSession",
        "cancelInheritedLegacyUploads()",
        "legacyCancellationBarrier",
        "legacyEventFinalizationCoordinator",
    ):
        assert fragment in uploader

    bootstrap_start = view_model.index("private func performBootstrap() async")
    bootstrap_end = view_model.index(
        "private func recoverPendingOutboxClearIfNeeded()", bootstrap_start
    )
    bootstrap = view_model[bootstrap_start:bootstrap_end]
    cancel = bootstrap.index("cancelInheritedLegacyUploads()")
    resume = bootstrap.index("await resumePendingPairingIfNeeded()")
    assert cancel < resume


def test_background_completion_requires_exact_atomic_receiver_binding() -> None:
    uploader = UPLOADER.read_text()
    start = uploader.index("private func finishCompletedUpload(")
    end = uploader.index("private func appendResponseData", start)
    finish = uploader[start:end]

    generation_field = "descriptor.receiverGeneration"
    generation_comparison = "== settingsStore.receiverSettingsGenerationToken"
    generation_fragment = f"{generation_field} {generation_comparison}"
    for fragment in (
        generation_fragment,
        "descriptor.receiverBindingID == settingsStore.receiverBindingID",
        "item.receiverIdentity == descriptor.receiverBindingID",
    ):
        assert fragment in finish


def test_background_task_ownership_is_durable_from_resume_through_reconciliation() -> (
    None
):
    uploader = UPLOADER.read_text()

    schedule_start = uploader.index("func schedulePendingUploads(")
    schedule_end = uploader.index("func cancelPendingUploads()", schedule_start)
    schedule = uploader[schedule_start:schedule_end]
    ledger_begin = schedule.index("try taskOwnershipStore.begin(")
    coordinator_begin = schedule.index("eventFinalizationCoordinator.begin(")
    resume = schedule.index("task.resume()")
    assert ledger_begin < coordinator_begin < resume

    cancel_start = uploader.index("private func performPendingUploadCancellation()")
    cancel_end = uploader.index("func cancelInheritedLegacyUploads()", cancel_start)
    cancel = uploader[cancel_start:cancel_end]
    ledger_ids = cancel.index("currentOwnedTaskIDs()")
    enumerate_tasks = cancel.index("let sessionTasks = await tasks(")
    certify_empty = cancel.index("&& ownershipLedgerIsEmpty")
    assert ledger_ids < enumerate_tasks < certify_empty

    completion_start = uploader.index("didCompleteWithError error: Error?")
    completion_end = uploader.index("func urlSessionDidFinishEvents", completion_start)
    completion = uploader[completion_start:completion_end]
    persist = completion.index("taskOwnershipStore.recordCompletion(")
    current_task_start = completion.index("Task { @MainActor")
    current_task = completion[current_task_start:]
    reconcile = current_task.index("self.finishCompletedUpload(")
    remove = current_task.index("taskOwnershipStore.remove(taskID: taskID)")
    barrier = current_task.index("await completionBarrier.complete(taskID)")
    assert persist < current_task_start
    assert reconcile < barrier < remove

    recovery_start = uploader.index("private func recoverPersistedTaskCompletions()")
    recovery_end = uploader.index(
        "private static func dispatchCompletionHandler", recovery_start
    )
    recovery = uploader[recovery_start:recovery_end]
    reconcile = recovery.index("finishCompletedUpload(")
    barrier = recovery.index("await cancellationBarrier.complete(record.taskID)")
    remove = recovery.index("taskOwnershipStore.remove(taskID: record.taskID)")
    assert reconcile < barrier < remove

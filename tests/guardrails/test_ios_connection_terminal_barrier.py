from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW_MODEL = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "App"
    / "HealthBridgeCompanionViewModel.swift"
)
CONTENT_VIEW = ROOT / "ios" / "HealthBridgeCompanion" / "App" / "ContentView.swift"
PAIRING_DOC = ROOT / "docs" / "pairing.md"
RECEIVER_CLIENT = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "Sources"
    / "HealthBridgeCompanionCore"
    / "ReceiverClient.swift"
)
FILE_OUTBOX = RECEIVER_CLIENT.with_name("FileOutbox.swift")
HEALTHKIT_CATALOG = RECEIVER_CLIENT.with_name("HealthKitReadTypeCatalog.swift")
BACKGROUND_UPLOADER = VIEW_MODEL.with_name("BackgroundURLSessionOutboxUploader.swift")
BACKGROUND_SCHEDULER = VIEW_MODEL.with_name("BackgroundRefreshScheduler.swift")
TERMINAL_TRANSITION_HELPER = (
    "private func performTerminalConnectionTransitionWhileHoldingRequestGate<Result>("
)


def test_disconnect_is_async_and_uses_the_terminal_connection_barrier() -> None:
    source = VIEW_MODEL.read_text()
    start = source.index("func disconnectReceiver() async")
    end = source.index("private func checkReceiverHealth()", start)
    body = source[start:end]

    assert "performTerminalConnectionTransitionWhileHoldingRequestGate(" in body
    assert "cancelPairingOperation: true" in body
    assert "pairingCoordinator.cancelPendingPairing(" in body

    content = CONTENT_VIEW.read_text()
    assert "Task {" in content
    assert "await viewModel.disconnectReceiver()" in content


def test_legacy_v1_and_v2_replacement_call_the_same_barrier_helper() -> None:
    source = VIEW_MODEL.read_text()
    start = source.index("private func applyPairingMaterial(")
    end = source.index("private func applyCommittedPairingCredential(", start)
    body = source[start:end]

    legacy = body[body.index("case .legacy") : body.index("case .invitation")]
    invitation = body[body.index("case .invitation") :]
    assert "performTerminalConnectionTransitionWhileHoldingRequestGate(" in legacy
    assert "performTerminalConnectionTransitionWhileHoldingRequestGate(" in invitation


def test_pairing_ui_promotion_rechecks_the_committed_generation_after_the_barrier() -> (
    None
):
    source = VIEW_MODEL.read_text()
    start = source.index("private func applyPairingMaterial(")
    end = source.index("private func applyCommittedPairingCredential(", start)
    body = source[start:end]

    assert body.count("committedGeneration") >= 2
    assert (
        body.count(
            "requireCommittedConnectionGenerationWhileHoldingRequestGate(committedGeneration)"
        )
        >= 2
    )
    assert body.index(
        "requireCommittedConnectionGenerationWhileHoldingRequestGate(committedGeneration)"
    ) < body.index("applyCommittedPairingConnection(")


def test_foreground_uploads_capture_and_recheck_connection_generation() -> None:
    source = VIEW_MODEL.read_text()
    start = source.index("private func uploadPayloadsWithOutbox(")
    end = source.index("private func refreshPendingOutboxCount()", start)
    body = source[start:end]

    assert (
        "let expectedGeneration = settingsStore.receiverSettingsGenerationToken" in body
    )
    assert "allowsPostResponseMutation(" in source
    assert body.count("requireCurrentConnectionGeneration(expectedGeneration)") >= 4
    assert "try outbox.markUploaded(item)" in body


def test_terminal_request_reservation_precancels_pairing() -> None:
    source = VIEW_MODEL.read_text()
    gate_start = source.index("private func withTerminalTransitionRequestGate<Result>(")
    transition_start = source.index(
        TERMINAL_TRANSITION_HELPER,
        gate_start,
    )
    gate = source[gate_start:transition_start]
    coordinator_source = FILE_OUTBOX.read_text()
    coordinator_start = coordinator_source.index(
        "public final class TerminalRequestCoordinator"
    )
    coordinator_end = coordinator_source.index(
        "public actor AsyncCompletionBarrier", coordinator_start
    )
    coordinator = coordinator_source[coordinator_start:coordinator_end]
    assert (
        coordinator.index("guard !isActive")
        < coordinator.index("isActive = true")
        < coordinator.index("try await gate.acquire()")
        < coordinator.index("result = try await operation()")
    )
    assert coordinator.count("isActive = false") == 5
    assert coordinator.count("await gate.release()") == 3
    assert coordinator.rindex("await gate.release()") < coordinator.rindex(
        "isActive = false"
    )
    assert "allowDuringActiveBootstrap || bootstrapTask == nil" in gate

    transition_end = source.index(
        "private func restorePrivateStorageAdmissionAfterFailedConnectionTransition()",
        transition_start,
    )
    body = source[transition_start:transition_end]
    assert (
        body.index("await cancelPairingOperationIfNeeded()")
        < body.index(
            "let outboxIdentityAdmissionWasReady = outboxIdentityMigrationReady"
        )
        < body.index("connectionTerminalBarrier.perform(")
    )
    close = body[body.index("closeAdmission:") : body.index("invalidateGeneration:")]
    assert "privateStorageAdmissionReady = false" in close
    assert "outboxIdentityMigrationReady = false" in close
    commit = body[body.index("commit: { expectedGeneration in") :]
    assert commit.index(
        "try self.requireTrustedEmptyOutboxForConnectionTransition("
    ) < commit.index("let result = try await commit(expectedGeneration)")
    assert body.index("connectionTerminalBarrier.perform(") < body.index(
        "try preparePrivateStorageForUploadAdmission()"
    )
    assert "postCommitRecoveryRequired: true" in body
    assert "postCommitRecoveryRequired: false" in body

    barrier = RECEIVER_CLIENT.read_text()
    assert "transitionWaiters: [CheckedContinuation<Void, Never>]" in barrier
    assert "await acquireTransition()" in barrier
    assert "defer { releaseTransition() }" in barrier
    assert "guard admissionIsOpen else" not in barrier


def test_lifecycle_and_pairing_waiters_respect_terminal_requests() -> None:
    source = VIEW_MODEL.read_text()

    for action_entry in (
        "func schedulePendingBackgroundOutboxUploadsIfAllowed()",
        "func noteBackgroundRefreshScheduled(earliestBeginDate: Date)",
        "func noteBackgroundRefreshSchedulingSkipped()",
        "func noteBackgroundRefreshScheduleFailed(_ error: Error)",
        "func noteBackgroundRefreshHandlerStarted(source: String)",
    ):
        start = source.index(action_entry)
        body = source[start : source.index("\n    }", start) + 6]
        assert "terminalPayloadActionAdmissionIsOpen" in body

    scheduler = BACKGROUND_SCHEDULER.read_text()
    assert "viewModel.backgroundRefreshSchedulingAdmissionIsOpen" in scheduler

    save_start = source.index("func saveReceiverSettings() async")
    save_end = source.index("func disconnectReceiver() async", save_start)
    save_body = source[save_start:save_end]
    assert save_body.index("pairingRequestEpoch.invalidate()") < save_body.index(
        "performTerminalConnectionTransitionWhileHoldingRequestGate("
    )

    clear_start = source.index("func clearPendingOutbox() async")
    clear_end = source.index(
        "private func resetPrivateSyncProgressForClear()", clear_start
    )
    clear_body = source[clear_start:clear_end]
    assert clear_body.index("pairingRequestEpoch.invalidate()") < clear_body.index(
        "connectionTerminalBarrier.performRecovery("
    )

    terminal_coordinator_prefix = "private let terminalTransitionRequestCoordinator = "
    terminal_coordinator_declaration = (
        f"{terminal_coordinator_prefix}TerminalRequestCoordinator()"
    )
    assert terminal_coordinator_declaration in source
    assert "terminalTransitionRequestCoordinator.perform(" in source


def test_clear_and_disconnect_reactivate_automatic_sync_after_request_release() -> None:
    source = VIEW_MODEL.read_text()

    clear_start = source.index("func clearPendingOutbox() async")
    clear_end = source.index(
        "private func performClearPendingOutboxWhileHoldingRequestGate()", clear_start
    )
    clear_body = source[clear_start:clear_end]
    assert "defer { activateAutomaticSyncIfReady() }" in clear_body

    clear_worker_start = clear_end
    clear_worker_end = source.index(
        "private func resetPrivateSyncProgressForClear()", clear_worker_start
    )
    clear_worker = source[clear_worker_start:clear_worker_end]
    assert "activateAutomaticSyncIfReady()" not in clear_worker

    disconnect_start = source.index("func disconnectReceiver() async")
    disconnect_worker_start = source.index(
        "private func performDisconnectReceiverWhileHoldingRequestGate()",
        disconnect_start,
    )
    disconnect_body = source[disconnect_start:disconnect_worker_start]
    assert "defer { activateAutomaticSyncIfReady() }" in disconnect_body

    disconnect_worker_end = source.index(
        "private func checkReceiverHealth()", disconnect_worker_start
    )
    disconnect_worker = source[disconnect_worker_start:disconnect_worker_end]
    assert "activateAutomaticSyncIfReady()" not in disconnect_worker


def test_pairing_docs_describe_terminal_boundary_without_remote_retraction() -> None:
    pairing = PAIRING_DOC.read_text()

    assert "legacy v1 replacement" in pairing
    assert "Disconnect completes locally" in pairing
    assert "does not retract a network request that was already sent" in pairing
    assert "oldest mismatched or unknown item stays quarantined" in pairing


def test_stale_cancellation_is_rejected_before_durable_marker_write() -> None:
    source = RECEIVER_CLIENT.read_text()
    start = source.index("public func cancelPendingPairing(")
    end = source.index("public func finishPendingCancellationIfNeeded(", start)
    body = source[start:end]

    assert body.index(
        "receiverSettingsGenerationToken == expectedGeneration"
    ) < body.index("stateStore.beginPendingCancellation(")
    state_store = FILE_OUTBOX.read_text()
    assert 'cancellationGenerationPrefix = "generation:"' in state_store
    assert "pendingCancellationExpectedGeneration()" in source


def test_disconnect_failure_preserves_the_committed_connection_ui() -> None:
    source = VIEW_MODEL.read_text()
    start = source.index("func disconnectReceiver() async")
    end = source.index("private func checkReceiverHealth()", start)
    body = source[start:end]

    preflight = body.index("try requireTrustedEmptyOutboxForConnectionTransition(")
    barrier = body.index("performTerminalConnectionTransitionWhileHoldingRequestGate(")
    durable_disable = body.index("backgroundSyncStore.setEnabledDurably(false)")
    pairing_cancel = body.index("pairingCoordinator.cancelPendingPairing(")
    automatic_sync_commit = body.index("backgroundSyncPreferenceGeneration &+= 1")
    assert preflight < body.index("pairingRequestEpoch.invalidate()") < barrier
    assert barrier < durable_disable < pairing_cancel < automatic_sync_commit
    assert "hasPendingPairing = true" not in body[:barrier]
    assert "backgroundSyncRequestedEnabled = false" not in body[:barrier]
    assert "backgroundSyncEnabled = false" not in body[:barrier]
    assert "hasPendingCancellationRecovery()" in body
    assert "committedReceiverSettingsAreComplete" in body
    assert "receiverSettingsGenerationToken == expectedGeneration" in body
    assert "settingsStore.receiverBindingID == expectedBindingID" in body
    normalized_body = " ".join(body.split())
    preference_prefix = "self.backgroundSyncPreferenceGeneration "
    preference_comparison = (
        f"{preference_prefix}== expectedBackgroundSyncPreferenceGeneration"
    )
    assert preference_comparison in normalized_body
    assert "let backgroundSyncWasEnabled = self.backgroundSyncRequestedEnabled" in body
    assert body.count("backgroundSyncStore.setEnabledDurably(") >= 2
    assert body.count("backgroundSyncWasEnabled") >= 2
    assert "reloadCommittedReceiverSettings()" in body
    catch_body = body[body.rindex("} catch {") :]
    assert (
        "hasPendingPairing = (try? pairingCoordinator.hasPendingPairing()) ?? true"
        in catch_body
    )
    assert "activateAutomaticSyncIfReady()" not in catch_body
    disconnect_entry = body[
        : body.index("private func performDisconnectReceiverWhileHoldingRequestGate()")
    ]
    assert "defer { activateAutomaticSyncIfReady() }" in disconnect_entry
    assert "receiverSettingsSaved = false" not in catch_body
    assert (
        "requireCurrentConnectionGeneration(transition.committedGeneration)" not in body
    )
    assert body.index("withTerminalTransitionRequestGate") < preflight
    assert "let trustedPendingOutboxCount = self.trustedPendingOutboxCount()" in body
    assert "return .disconnected(pendingOutboxCount: trustedPendingOutboxCount)" in body
    assert "let cancellationOutcome: ReceiverPairingCancellationOutcome" in body
    assert "return cancellationOutcome == .committedCleanupPending" in body
    assert (
        "hasPendingPairing = ((try? pairingCoordinator.hasPendingPairing()) ?? false)"
        in body
    )
    assert "|| cancellationCleanupRecoveryRequired" in body
    assert "hasPendingPrivateStorageRecovery = true" in body


def test_terminal_transition_suppresses_transitive_task_ui_until_decision() -> None:  # noqa: PLR0915
    source = VIEW_MODEL.read_text()
    gate_start = source.index("private func withTerminalTransitionRequestGate<Result>(")
    transition_start = source.index(
        TERMINAL_TRANSITION_HELPER,
        gate_start,
    )
    gate = source[gate_start:transition_start]
    transition_end = source.index(
        "private func restorePrivateStorageAdmissionAfterFailedConnectionTransition()",
        transition_start,
    )
    transition = source[transition_start:transition_end]

    begin = transition.index("beginTerminalTaskUIPublicationSuppression()")
    first_cancel = transition.index("cancelPairingOperationIfNeeded()")
    decisive_check = transition.index(
        "requireTrustedEmptyOutboxForConnectionTransition("
    )
    assert begin < first_cancel < decisive_check
    coordinator_source = FILE_OUTBOX.read_text()
    coordinator_start = coordinator_source.index(
        "public final class TerminalRequestCoordinator"
    )
    coordinator_end = coordinator_source.index(
        "public actor AsyncCompletionBarrier", coordinator_start
    )
    coordinator = coordinator_source[coordinator_start:coordinator_end]
    assert "terminalTransitionRequestCoordinator.perform(" in gate
    assert (
        coordinator.index("guard !isActive")
        < coordinator.index("isActive = true")
        < coordinator.index("try await gate.acquire()")
        < coordinator.index("result = try await operation()")
        < coordinator.rindex("await gate.release()")
        < coordinator.rindex("isActive = false")
    )
    assert transition.count("endTerminalTaskUIPublicationSuppression()") == 2
    assert transition.index(
        "endTerminalTaskUIPublicationSuppression()"
    ) < transition.index(
        "restorePrivateStorageAdmissionAfterFailedConnectionTransition()"
    )
    assert transition.rindex(
        "endTerminalTaskUIPublicationSuppression()"
    ) < transition.index("try preparePrivateStorageForUploadAdmission()")

    clear_start = source.index("func clearPendingOutbox() async")
    clear_end = source.index(
        "private func resetPrivateSyncProgressForClear()", clear_start
    )
    clear_body = source[clear_start:clear_end]
    assert clear_body.index("withTerminalTransitionRequestGate") < clear_body.index(
        "connectionTerminalBarrier.performRecovery("
    )
    assert "await retryBootstrapAfterRecoveryIfNeeded()" in clear_body

    toggle_start = source.index("func requestBackgroundSyncEnabled(_ enabled: Bool)")
    toggle_end = source.index("private func receiverIdentityMatches(", toggle_start)
    toggle_body = source[toggle_start:toggle_end]
    assert "if enabled, !terminalUserActionAdmissionIsOpen" in toggle_body
    assert "beginAutomaticSyncDisable(preferenceGeneration:" in toggle_body
    assert "scheduleAutomaticSyncEnable(" in toggle_body
    enable_start = source.index("private func scheduleAutomaticSyncEnable(")
    enable_end = source.index(
        "private func recordBackgroundSyncRegistrationIfAllowed(", enable_start
    )
    assert "withTerminalTransitionRequestGate(" in source[enable_start:enable_end]

    for action_entry in (
        "func checkConnection() async",
        "func performPrimaryAction() async",
        "func syncAllNow() async",
        "func runBackgroundRefreshSync(reason: AutomaticSyncReason) async",
    ):
        action_start = source.index(action_entry)
        action_body = source[action_start : source.index("\n    }", action_start) + 6]
        assert "terminalPayloadActionAdmissionIsOpen" in action_body

    for action_entry in (
        "func setHealthHistoryDepthOption(_ optionID: String)",
        "func retryPrivateStorage() async",
        "func saveReceiverSettings() async",
        "func clearPendingOutbox() async",
        "func cancelPendingPairing() async",
        "func requestHealthPermissions() async",
    ):
        action_start = source.index(action_entry)
        action_body = source[action_start : source.index("\n    }", action_start) + 6]
        assert "terminalUserActionAdmissionIsOpen" in action_body

    permission_start = source.index(
        "private func performRequestHealthPermissionsWhileHoldingRequestGate() async"
    )
    permission_body = source[
        permission_start : source.index("\n    }", permission_start) + 6
    ]
    assert "!taskUIPublicationIsSuppressed" in permission_body
    assert "connectionTerminalBarrier.admissionIsOpen" in permission_body

    pairing_start = source.index("private func runTrackedPairingOperation(")
    pairing_end = source.index(
        "private func cancelPairingOperationIfNeeded()", pairing_start
    )
    pairing_body = source[pairing_start:pairing_end]
    assert pairing_body.count("terminalUserActionAdmissionIsOpen") == 2
    assert (
        "let capturedPairingRequestEpoch = pairingRequestEpoch.capture()"
        in pairing_body
    )
    assert (
        pairing_body.count("pairingRequestEpoch.isCurrent(capturedPairingRequestEpoch)")
        == 2
    )
    assert pairing_body.index("terminalUserActionAdmissionIsOpen") < pairing_body.index(
        "let task = Task"
    )

    lifecycle_start = source.index(
        "private var terminalRequestLifecycleSnapshot: TerminalRequestLifecycleSnapshot"
    )
    lifecycle_end = source.index(
        "@Published private(set) var backgroundSyncRequestedEnabled", lifecycle_start
    )
    lifecycle_body = source[lifecycle_start:lifecycle_end]
    assert "requestIsActive: terminalTransitionRequestIsActive" in lifecycle_body
    assert "publicationIsSuppressed: taskUIPublicationIsSuppressed" in lifecycle_body
    assert (
        "payloadAdmissionIsOpen: connectionTerminalBarrier.admissionIsOpen"
        in lifecycle_body
    )

    for readiness in (
        "private var automaticSyncReady: Bool",
        "var canSaveReceiverSettings: Bool",
        "var canImportPairingText: Bool",
        "var canRedeemManualPairing: Bool",
    ):
        readiness_start = source.index(readiness)
        readiness_body = source[
            readiness_start : source.index("\n    }", readiness_start) + 6
        ]
        assert "!taskUIPublicationIsSuppressed" in readiness_body

    for pairing_worker in (
        "private func performResumePendingPairingIfNeeded() async",
        "private func performImportPairingText() async",
        "private func performImportPairingURL(_ url: URL) async",
        "private func performRedeemManualPairing() async",
    ):
        pairing_start = source.index(pairing_worker)
        pairing_body = source[
            pairing_start : source.index("\n    }", pairing_start) + 6
        ]
        assert "!taskUIPublicationIsSuppressed" in pairing_body
        assert "connectionTerminalBarrier.admissionIsOpen" in pairing_body

    for property_name in (
        "statusMessage",
        "statusIsError",
        "backgroundSyncStatus",
        "pendingOutboxCount",
    ):
        setter = f"var {property_name}:"
        start = source.index(setter)
        body = source[start : source.index("\n    }", start) + 6]
        assert "taskUIPublicationIsSuppressed" in body

    end_start = source.index("private func endTerminalTaskUIPublicationSuppression()")
    end_body = source[end_start : source.index("\n    }", end_start) + 6]
    assert "refreshPendingOutboxCount()" in end_body
    assert "refreshPendingPairingState()" in end_body
    assert "isSyncing = false" in end_body
    assert "isCheckingConnection = false" in end_body

    background_start = source.index("private func performBackgroundRefreshSync(")
    background_end = source.index(
        "func requestHealthPermissions() async", background_start
    )
    background_body = source[background_start:background_end]
    assert "backgroundSyncStore.recordRun(" not in background_body
    assert "recordBackgroundSyncRunIfAllowed(" in background_body

    record_start = source.index("private func recordBackgroundSyncRunIfAllowed(")
    record_end = source.index(
        "private func performBackgroundRefreshSync(", record_start
    )
    record_body = source[record_start:record_end]
    assert "guard terminalPayloadActionAdmissionIsOpen else { return }" in record_body
    assert "backgroundSyncStore.recordRun(" in record_body

    for callback in (
        "private func noteHealthKitBackgroundDeliveryRegistration(",
        "func noteBackgroundRefreshScheduled(",
        "func noteBackgroundRefreshSchedulingSkipped()",
        "func noteBackgroundRefreshScheduleFailed(",
        "func noteBackgroundRefreshHandlerStarted(",
    ):
        callback_start = source.index(callback)
        callback_body = source[
            callback_start : source.index("\n    }", callback_start) + 6
        ]
        assert (
            "guard terminalPayloadActionAdmissionIsOpen else { return }"
            in callback_body
        )

    for guarded_refresh in (
        "private func reloadCommittedReceiverSettings()",
        "private func refreshPendingOutboxCount()",
    ):
        refresh_start = source.index(guarded_refresh)
        refresh_body = source[
            refresh_start : source.index("\n    }", refresh_start) + 6
        ]
        assert "guard !taskUIPublicationIsSuppressed else { return }" in refresh_body

    registration_start = source.index(
        "private func recordBackgroundSyncRegistrationIfAllowed("
    )
    registration_end = source.index(
        "private func startHealthKitBackgroundDeliveryIfNeeded()", registration_start
    )
    registration_body = source[registration_start:registration_end]
    assert (
        "guard terminalPayloadActionAdmissionIsOpen else { return }"
        in registration_body
    )
    assert "backgroundSyncStore.recordRegistration(" in registration_body

    historical_refresh_start = source.index(
        "private func refreshHistoricalBackfillPublishedStateIfAllowed()"
    )
    historical_refresh_end = source.index(
        "private func beginTerminalTaskUIPublicationSuppression()",
        historical_refresh_start,
    )
    historical_refresh_body = source[historical_refresh_start:historical_refresh_end]
    assert (
        "guard !taskUIPublicationIsSuppressed else { return }"
        in historical_refresh_body
    )
    assert "refreshHistoricalBackfillPublishedStateIfAllowed()" in end_body
    assert (
        source.count("historicalBackfillState = historicalBackfillStateStore.state")
        == 2
    )


def test_failed_terminal_transition_reopens_trusted_admission() -> None:
    source = VIEW_MODEL.read_text()
    start = source.index(TERMINAL_TRANSITION_HELPER)
    end = source.index("private func cancelAndAwaitForegroundPayloadTasks()", start)
    body = source[start:end]

    assert "restorePrivateStorageAdmissionAfterFailedConnectionTransition()" in body
    assert body.index("connectionTerminalBarrier.perform(") < body.index(
        "restorePrivateStorageAdmissionAfterFailedConnectionTransition()"
    )
    restore_start = source.index(
        "private func restorePrivateStorageAdmissionAfterFailedConnectionTransition()"
    )
    restore_end = source.index(
        "private func cancelAndAwaitForegroundPayloadTasks()", restore_start
    )
    restore = source[restore_start:restore_end]
    assert restore.index("hasPendingCancellationRecovery()") < restore.index(
        "preparePrivateStorageForUploadAdmission()"
    )
    assert "if let outboxError = error as? ReceiverOutboxIdentityError" in source
    assert "code=transition_requires_empty_outbox" in source

    drain_start = source.index(
        "private func drainBackgroundPayloadCancellation() async"
    )
    drain_end = source.index(
        "private func requireUnchangedConnectionGenerationDuringRecovery", drain_start
    )
    assert "backgroundSyncStatus =" not in source[drain_start:drain_end]


def test_automatic_sync_requires_complete_committed_receiver_settings() -> None:
    source = VIEW_MODEL.read_text()
    prerequisite_start = source.index(
        "private var automaticSyncEnablePrerequisitesReady: Bool"
    )
    ready_start = source.index("private var automaticSyncReady: Bool")
    ready_end = source.index("var canSaveReceiverSettings", ready_start)
    prerequisite = source[prerequisite_start:ready_start]
    ready = source[ready_start:ready_end]

    assert "committedReceiverSettingsAreComplete" in prerequisite
    assert "automaticSyncEnablePrerequisitesReady" in ready
    assert "!taskUIPublicationIsSuppressed" in ready
    assert "settingsStore.receiverBindingID" in source
    assert "settingsStore.loadBearerToken()" in source


def test_automatic_sync_backpressure_and_disable_ordering() -> None:
    source = VIEW_MODEL.read_text()

    refresh_start = source.index("private func performBackgroundRefreshSync(")
    refresh_end = source.index(
        "private func performAdmittedBackgroundRefreshSync(", refresh_start
    )
    refresh_body = source[refresh_start:refresh_end]
    first_backpressure = refresh_body.index(
        "deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt)"
    )
    direct_transfer = refresh_body.index("runWithExclusiveDirectOutboxTransfer")
    second_backpressure = refresh_body.index(
        "deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt)",
        first_backpressure + 1,
    )
    policy = refresh_body.index(
        "AutomaticSyncPayloadGenerationPolicy.shouldGenerateNewPayloads("
    )
    assert first_backpressure < direct_transfer < second_backpressure < policy
    assert "finishBackgroundRunPreservingObserverDirtiness(" in refresh_body
    finish_start = source.index(
        "private func finishBackgroundRunPreservingObserverDirtiness("
    )
    finish_end = source.index(
        "private func deferAutomaticSyncForPendingOutboxIfNeeded(", finish_start
    )
    assert (
        "await backgroundRunGate.finishRun(.interrupted)"
        in source[finish_start:finish_end]
    )
    defer_start = finish_end
    defer_end = source.index("private struct BackgroundCoreLaneResult", defer_start)
    assert (
        "schedulePendingBackgroundOutboxUploadsIfAllowed()"
        in source[defer_start:defer_end]
    )

    admitted_start = source.index("private func performAdmittedBackgroundRefreshSync(")
    admitted_end = source.index(
        "private func stopBackgroundRunIfUnavailable(", admitted_start
    )
    admitted_body = source[admitted_start:admitted_end]
    follow_up = admitted_body.index("if followUpAdmission.shouldRun")
    follow_up_backpressure = admitted_body.index(
        "deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: followUpStartedAt)",
        follow_up,
    )
    recursive_read = admitted_body.index(
        "await performAdmittedBackgroundRefreshSync(", follow_up
    )
    assert follow_up < follow_up_backpressure < recursive_read

    lane_markers = [
        "await self.syncRecentStepCounts(executionMode: .automatic)",
        "await self.syncDailyActivityAggregates(executionMode: .automatic)",
        "await self.syncAnchoredWorkoutChanges(executionMode: .automatic)",
        "await self.syncRecentSleepSessions(executionMode: .automatic)",
        "await syncBackgroundAutomaticQuantityMetrics(",
    ]
    for lane_marker in lane_markers:
        lane = admitted_body.index(lane_marker)
        checkpoint = admitted_body.index(
            "deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt)",
            lane,
        )
        assert lane < checkpoint < follow_up

    quantity_start = source.index("private func syncQuantityMetrics(")
    quantity_end = source.index("private enum PayloadDeliveryResult", quantity_start)
    quantity_body = source[quantity_start:quantity_end]
    queued_delivery = quantity_body.index("queuedAnyPayload = true")
    queued_stop_policy = quantity_body.index(
        "AutomaticSyncPayloadGenerationPolicy.shouldStopQuantityLoop(",
        queued_delivery,
    )
    queued_break = quantity_body.index("break", queued_stop_policy)
    assert queued_delivery < queued_stop_policy < queued_break


def test_automatic_sync_disable_is_durable_before_cancellation() -> None:
    source = VIEW_MODEL.read_text()

    request_start = source.index("func requestBackgroundSyncEnabled(_ enabled: Bool)")
    request_end = source.index("private func receiverIdentityMatches(", request_start)
    request_body = source[request_start:request_end]
    requested = request_body.index("backgroundSyncRequestedEnabled = enabled")
    disable_dispatch = request_body.index("beginAutomaticSyncDisable(")
    assert requested < disable_dispatch

    toggle_start = source.index("private func beginAutomaticSyncDisable(")
    toggle_end = source.index("private func scheduleAutomaticSyncEnable(", toggle_start)
    toggle_body = source[toggle_start:toggle_end]
    assert "backgroundSyncEnabled = false" in toggle_body
    assert "backgroundSyncStore.setEnabledDurably(false)" in toggle_body
    assert toggle_body.index("backgroundSyncEnabled = false") < toggle_body.index(
        "backgroundSyncStore.setEnabledDurably(false)"
    )
    assert toggle_body.index(
        "backgroundSyncStore.setEnabledDurably(false)"
    ) < toggle_body.index("let cleanupTask = Task")
    assert "await self.cancelAndAwaitForegroundPayloadTasks()" in toggle_body
    assert "await self.drainBackgroundPayloadCancellation()" in toggle_body

    success_status = toggle_body.index(
        'statusMessage = "Automatic sync is off. Sync Now still works."'
    )
    assert toggle_body.index("statusIsError = false") < success_status


def test_automatic_sync_controls_publish_terminal_request_lifecycle() -> None:
    source = VIEW_MODEL.read_text()

    assert (
        "@Published private(set) var terminalTransitionRequestIsActive = false"
        in source
    )
    gate_start = source.index("private func withTerminalTransitionRequestGate<Result>(")
    gate_end = source.index(
        "private func performTerminalConnectionTransitionWhileHoldingRequestGate<",
        gate_start,
    )
    gate_body = source[gate_start:gate_end]
    reserve = gate_body.index("terminalTransitionRequestIsActive = true")
    acquire = gate_body.index("terminalTransitionRequestCoordinator.perform(")
    release_publication = gate_body.index(
        "terminalTransitionRequestIsActive = false", acquire
    )
    assert reserve < acquire < release_publication
    assert gate_body.count("terminalTransitionRequestIsActive = false") == 2

    action_start = source.index("var canRunPrimaryAction: Bool")
    action_end = source.index("var statusLaneSummaries:", action_start)
    assert "terminalPayloadActionAdmissionIsOpen" in source[action_start:action_end]

    setting_start = source.index("var canChangeAutomaticSyncSetting: Bool")
    setting_end = source.index(
        "var backgroundRefreshSchedulingAdmissionIsOpen", setting_start
    )
    setting_body = source[setting_start:setting_end]
    assert "terminalUserActionAdmissionIsOpen" in setting_body
    assert "canSendConnectionTest" in setting_body

    content = CONTENT_VIEW.read_text()
    assert ".disabled(!viewModel.canChangeAutomaticSyncSetting)" in content


def test_terminal_request_prevents_post_opt_out_enqueue() -> None:
    source = VIEW_MODEL.read_text()

    enqueue_start = source.index("private func enqueuePayloads(")
    enqueue_end = source.index(
        "private func retryPrivateStoreInitialization()", enqueue_start
    )
    enqueue_body = source[enqueue_start:enqueue_end]
    enqueue_guard = enqueue_body.index(
        "guard terminalPayloadActionAdmissionIsOpen, !Task.isCancelled else"
    )
    outbox_write = enqueue_body.index("outbox.enqueueSequence(")
    assert enqueue_guard < outbox_write

    sleep_sync_start = source.index("func syncRecentSleepSessions(")
    sleep_sync_end = source.index(
        "private func deliverPendingSleepTransition(", sleep_sync_start
    )
    sleep_sync_body = source[sleep_sync_start:sleep_sync_end]
    sleep_journal_guard = sleep_sync_body.rindex(
        "guard terminalPayloadActionAdmissionIsOpen, !Task.isCancelled else"
    )
    sleep_journal_write = sleep_sync_body.index(
        "sleepManifestStore.savePendingTransition("
    )
    assert sleep_journal_guard < sleep_journal_write

    sleep_delivery_start = sleep_sync_end
    sleep_delivery_end = source.index(
        "func syncSupportedQuantityMetrics()", sleep_delivery_start
    )
    sleep_delivery_body = source[sleep_delivery_start:sleep_delivery_end]
    sleep_outbox_guard = sleep_delivery_body.index(
        "guard terminalPayloadActionAdmissionIsOpen, !Task.isCancelled else"
    )
    sleep_outbox_write = sleep_delivery_body.index("outbox.enqueueIfAbsent(")
    assert sleep_outbox_guard < sleep_outbox_write


def test_background_upload_cancellation_is_bounded() -> None:
    uploader = BACKGROUND_UPLOADER.read_text()
    assert "static let cancellationCompletionTimeout: TimeInterval" in uploader
    assert uploader.count("timeout: Self.cancellationCompletionTimeout") == 4
    assert "func hasPendingUploadTasks() async -> Bool" in uploader

    source = VIEW_MODEL.read_text()
    transfer_start = source.index(
        "private func runWithExclusiveDirectOutboxTransfer<Result>("
    )
    transfer_end = source.index("private func performSyncAllNow()", transfer_start)
    transfer_body = source[transfer_start:transfer_end]
    cancel = transfer_body.index("cancelPendingUploads()")
    verify_empty = transfer_body.index("hasPendingUploadTasks()", cancel)
    operation = transfer_body.index("let result = await operation()", verify_empty)
    assert cancel < verify_empty < operation
    assert "throw CancellationError()" in transfer_body[verify_empty:operation]


def test_disconnect_failure_is_presented_immediately_in_settings() -> None:
    content = CONTENT_VIEW.read_text()
    start = content.index("private struct ReceiverSettingsView: View")
    body = content[start:]

    assert "@State private var showDisconnectFailureAlert = false" in body
    view_model = VIEW_MODEL.read_text()
    assert "enum DisconnectReceiverOutcome: Equatable" in view_model
    assert "pendingOutboxCount: Int?" in view_model
    assert "private func trustedPendingOutboxCount() -> Int?" in view_model
    assert (
        "let trustedPendingOutboxCount = self.trustedPendingOutboxCount()" in view_model
    )
    assert "let outcome = await viewModel.disconnectReceiver()" in body
    assert "switch outcome" in body
    assert "case .rejected(let message, let pendingOutboxCount" in body
    assert "showDisconnectFailureAlert = true" in body
    assert '.alert("Can\u2019t Disconnect Yet"' in body
    assert (
        "if connectionPreserved, let pendingOutboxCount, pendingOutboxCount > 0" in body
    )
    task_start = body.index("let outcome = await viewModel.disconnectReceiver()")
    task_end = body.index("showDisconnectFailureAlert = true", task_start)
    task_body = body[task_start:task_end]
    assert "viewModel.statusIsError" not in task_body
    assert "viewModel.canSendConnectionTest" not in task_body
    assert "viewModel.pendingOutboxCount" not in task_body
    assert "viewModel.statusMessage" not in task_body
    assert (
        "Queued uploads are waiting on this iPhone. Bring the server back and tap "
        "Sync Now to send them, or use Reset Private Sync State in Settings to "
        "discard them and rebuild local sync history before disconnecting."
    ) in body
    assert (
        '"Reset Private Sync State (\\(viewModel.pendingOutboxCount) queued)"' in body
    )
    assert '"Delete Queued Uploads (' not in body
    assert '.confirmationDialog("Reset private sync state?"' in body
    assert 'Button("Reset Private Sync State", role: .destructive)' in body
    assert 'message.contains("disconnect")' in body
    assert 'message.contains("queued upload")' in body


def test_healthkit_callbacks_are_invalidated_when_observers_stop() -> None:
    source = HEALTHKIT_CATALOG.read_text()

    assert "private var callbackGeneration: UInt64 = 0" in source
    assert source.count("callbackGeneration &+= 1") >= 2
    assert source.count("callbackGeneration == expectedCallbackGeneration") >= 2


def test_outbox_payloads_are_receiver_bound_for_foreground_and_background() -> None:
    outbox = FILE_OUTBOX.read_text()
    view_model = VIEW_MODEL.read_text()
    background = BACKGROUND_UPLOADER.read_text()

    assert outbox.count("SHA256.hash(data: material)") == 1
    assert "migrateLegacyHashedReceiverIdentities" in outbox
    assert "outboxIdentityMigrationReady" in view_model
    assert "&& outboxIdentityMigrationReady" in view_model
    assert view_model.index("outboxIdentityMigrationReady = true") < view_model.index(
        "reloadCommittedReceiverSettings()",
        view_model.index("outboxIdentityMigrationReady = true"),
    )
    assert "health-bridge-connection-v1:" in outbox
    assert "case legacyRecordRequiresRepair" in outbox
    assert "throw ReceiverSettingsRecordError.legacyRecordRequiresRepair" in outbox
    assert "bindingID: settingsChanged || previous.bindingID.isEmpty" in outbox
    assert "beginTerminalCancellationIntent" in outbox
    assert "legacyCancellationRequiresRetry" in outbox
    assert "static let currentVersion = 3" in outbox
    assert "if manifest.version < SequenceManifest.currentVersion" in outbox
    assert "var receiverIdentity: String?" in outbox
    assert "_ payload: Data,\n        receiverIdentity: String\n" in outbox
    assert "public func flushPending(\n        receiverIdentity: String," in outbox
    assert "bindUnscopedItems(to receiverIdentity:" not in outbox
    assert "case unknownReceiverIdentity" in outbox
    assert "uploadablePendingItems(for receiverIdentity:" in outbox
    assert "oldestItemBelongsToDifferentReceiver" in outbox
    assert "successfulEnqueueCount = try outbox.enqueueSequence(" in view_model
    assert "receiverIdentity: receiverIdentity" in view_model
    assert "settingsStore.receiverBindingID" in view_model
    assert "ReceiverOutboxIdentity.make" not in view_model
    assert "rotateBindingID: true" in view_model
    assert "rotateBindingID: true" in RECEIVER_CLIENT.read_text()
    assert "outbox.uploadablePendingItems(for: receiverIdentity)" in view_model
    assert "outbox.uploadablePendingItems(for: receiverBindingID)" in background


def test_cancelled_pairing_and_mixed_receiver_queue_remain_fail_closed() -> None:
    source = VIEW_MODEL.read_text()

    assert "try Task.checkCancellation()" in source
    assert "guard !Task.isCancelled else" in source
    assert "let hasPendingOutbox = !(try outbox.pendingItems()).isEmpty" in source
    assert (
        "CompanionPayloadNetworkAttemptPolicy.shouldAttemptNetworkForNewPayload"
        in source
    )
    assert "without repeating a foreground network attempt" in source
    assert "func requestBackgroundSyncEnabled(_ enabled: Bool)" in source
    toggle_start = source.index("func requestBackgroundSyncEnabled(_ enabled: Bool)")
    toggle_end = source.index(
        "private func recordBackgroundSyncRegistrationIfAllowed(", toggle_start
    )
    toggle_body = source[toggle_start:toggle_end]
    requested = toggle_body.index("backgroundSyncRequestedEnabled = enabled")
    durable_disable = toggle_body.index("backgroundSyncStore.setEnabledDurably(false)")
    request_gate = toggle_body.index("withTerminalTransitionRequestGate")
    private_disable_start = toggle_body.index("private func beginAutomaticSyncDisable(")
    private_disable_body = toggle_body[private_disable_start:]
    disable = private_disable_body.index("backgroundSyncEnabled = false")
    assert "&& backgroundSyncRequestedEnabled" in source
    assert requested < private_disable_start < durable_disable < request_gate
    assert disable < private_disable_body.index(
        "await self.cancelAndAwaitForegroundPayloadTasks()"
    )
    assert "await self.drainBackgroundPayloadCancellation()" in private_disable_body
    assert "backgroundSyncStore.setEnabled(false)" not in toggle_body


def test_bootstrap_consumes_terminal_cancellation_before_generation_advance() -> None:
    source = VIEW_MODEL.read_text()
    start = source.index("private func performResumePendingPairingIfNeeded() async")
    end = source.index("func cancelPendingPairing() async", start)
    body = source[start:end]

    recovery = body.index("hasPendingCancellationRecovery()")
    no_advance = body.index("advanceGeneration: false")
    normal_pairing = body.index("let previousGeneration")
    assert recovery < no_advance < normal_pairing
    assert "advanceGeneration: Bool = true" in source
    assert "if advanceGeneration" in source

    disconnect_start = source.index("func disconnectReceiver() async")
    disconnect_end = source.index(
        "private func checkReceiverHealth()", disconnect_start
    )
    disconnect_body = source[disconnect_start:disconnect_end]
    assert (
        disconnect_body.index("backgroundSyncStore.setEnabledDurably(false)")
        < (disconnect_body.index("pairingCoordinator.cancelPendingPairing("))
        < disconnect_body.index("backgroundSyncRequestedEnabled = false")
    )

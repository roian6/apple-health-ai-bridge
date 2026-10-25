import re
from pathlib import Path

VIEW_MODEL = Path("ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift")
APP = Path("ios/HealthBridgeCompanion/App/HealthBridgeCompanionApp.swift")
AUTOMATIC_SYNC_RUNTIME = Path(
    "ios/HealthBridgeCompanion/App/AutomaticSyncRuntime.swift"
)
BACKGROUND_SYNC = Path(
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/BackgroundSync.swift"
)


def _region(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin : source.index(end, begin + len(start))]


def _assert_scene_launch_forwarding(app: str) -> None:
    startup = app[app.index(".task {") : app.index(".onChange(of: scenePhase)")]
    active_start = app.index("if newPhase == .active")
    foreground = app[active_start : app.index("} else {", active_start)]

    assert startup.index("await applicationRuntime.bootstrap()") < startup.index(
        "applicationRuntime.runForegroundCatchUpIfNeeded()"
    )
    assert foreground.index("await applicationRuntime.bootstrap()") < foreground.index(
        "applicationRuntime.runForegroundCatchUpIfNeeded()"
    )
    active_guard = "guard !Task.isCancelled, scenePhase == .active else { return }"
    assert all(active_guard in block for block in (startup, foreground))
    for block in (startup, foreground):
        assert (
            block.index("await applicationRuntime.bootstrap()")
            < block.index(active_guard)
            < block.index("applicationRuntime.runForegroundCatchUpIfNeeded()")
        )
    assert "await viewModel.bootstrap()" in _region(
        app, "func bootstrap() async", "func runForegroundCatchUpIfNeeded()"
    )
    assert "automaticSyncRuntime.runForegroundCatchUpIfNeeded()" in _region(
        app, "func runForegroundCatchUpIfNeeded()", "func noteSceneLeftActive()"
    )
    app_initializer = _region(app, "    init(", "func prepareForBackgroundLaunch()")
    assert (
        "viewModel.installAutomaticSyncRuntime(automaticSyncRuntime)" in app_initializer
    )


def _assert_foreground_runtime_admission(runtime: str) -> None:
    generic_start = runtime.index("func runForegroundCatchUpIfNeeded()")
    generic = runtime[
        generic_start : runtime.index("func noteSceneLeftActive()", generic_start)
    ]
    assert "usesMailboxTransport" not in generic
    assert "runForegroundMailboxReconciliationIfNeeded" not in generic
    assert "guard !opportunityWasConsumed else { return }" in generic
    admission = re.search(
        str.join(
            "",
            (
                r"guard viewModel\.automaticSyncShouldRunForegroundCatchUp\(\s*",
                r"opportunityWasConsumed: opportunityWasConsumed\s*\),\s*",
                r"foregroundCatchUpTask == nil else \{\s*return\s*\}",
            ),
        ),
        generic,
    )
    assert admission is not None
    assert re.fullmatch(
        str.join(
            "",
            (
                r"func runForegroundCatchUpIfNeeded\(\) \{\s*",
                r"let opportunityWasConsumed = foregroundOpportunityConsumed\s*",
                r"guard !opportunityWasConsumed else \{ return \}\s*",
                r"reconcileRegistrations\(\)\s*",
            ),
        ),
        generic[: admission.start()],
    )
    consume = generic.index("foregroundOpportunityConsumed = true")
    owner = generic.index("foregroundCatchUpTask = Task { @MainActor [weak self] in")
    assert admission.end() < consume < owner
    assert not generic[admission.end() : consume].strip()
    assert generic[consume:owner].strip() == "foregroundOpportunityConsumed = true"
    assert generic.count("foregroundOpportunityConsumed = true") == 1
    assert "engine.requestRun(reason: .launchCatchUp)" in generic
    assert re.fullmatch(
        str.join(
            "",
            (
                r"foregroundCatchUpTask = Task \{ @MainActor \[weak self\] in\s*",
                r"guard let self else \{ return \}\s*",
                r"self\.viewModel\.publishAutomaticSyncForegroundCatchUpStarted\(",
                r"\)\s*",
                r"try\? await self\.engine\.requestRun\(reason: \.launchCatchUp\)",
                r"\s*",
                r"self\.foregroundCatchUpTask = nil\s*\}\s*\}\s*",
            ),
        ),
        generic[owner:],
    )


def _assert_bootstrap_readiness(source: str, runtime: str) -> None:
    prerequisites = _region(
        source,
        "func automaticSyncShouldRunForegroundCatchUp(",
        "func installAutomaticSyncRuntime(",
    )
    assert re.fullmatch(
        str.join(
            "",
            (
                r"func automaticSyncShouldRunForegroundCatchUp\(\s*",
                r"opportunityWasConsumed: Bool\s*\) -> Bool \{\s*",
                r"let prerequisitesAreReady = !Task\.isCancelled\s*",
                r"&& terminalPayloadActionAdmissionIsOpen\s*&& automaticSyncReady",
                r"\s*",
                r"&& backgroundSyncEnabled\s*&& canSendConnectionTest\s*",
                r"guard prerequisitesAreReady else \{ return false \}\s*",
                r"return AutomaticSyncTriggerPolicy\.admitsForegroundLaunchReconci",
                r"liation\(\s*",
                r"prerequisitesAreReady: true,\s*",
                r"opportunityWasConsumed: opportunityWasConsumed\s*\)\s*\}\s*",
            ),
        ),
        prerequisites,
    )
    bootstrap = _region(
        source,
        "private func performBootstrap()",
        "private func recoverPendingOutboxClearIfNeeded()",
    )
    assert bootstrap.index("bootstrapCompleted = true") < bootstrap.index(
        "activateAutomaticSyncIfReady()"
    )
    activate_forwarding = _region(
        source, "private func activateAutomaticSyncIfReady(", "private func "
    )
    assert (
        "automaticSyncRuntime?.activateIfReady(scheduleOutbox: scheduleOutbox)"
        in activate_forwarding
    )
    activation = _region(runtime, "func activateIfReady(", "func stopAdmission()")
    ready_guard = "guard viewModel.automaticSyncRuntimeIsReady else { return }"
    assert activation.index(ready_guard) < activation.index(
        "runForegroundCatchUpIfNeeded()"
    )
    assert "guard !hasActivatedReadyWork else { return }" in activation


def _assert_shared_engine_ack_backpressure(
    source: str, runtime: str, background_sync: str
) -> None:
    engine = _region(
        runtime, "private lazy var engine = AutomaticSyncEngine(", "    init(viewModel:"
    )
    assert "return await viewModel.processAutomaticSyncType(" in engine
    assert "_ = await viewModel.performAutomaticSyncOpportunity(" in engine
    assert "self?.beginOwner(cancelOwner: cancelOwner)" in engine
    opportunity = _region(
        source,
        "func performAutomaticSyncOpportunity(",
        "private func ownBackgroundRefreshOpportunity(",
    )
    assert "return await ownBackgroundRefreshOpportunity(" in opportunity
    assert "reason: opportunity.reason" in opportunity
    work = _region(
        source,
        "private func performBackgroundRefreshWork(",
        "private func noteAutomaticSyncQueryStarted(",
    )
    before_payload = work.index(
        "await reconcileMailboxDeliveryIfNeeded(at: .beforePayloadGeneration)"
    )
    process_pending = work.index(
        "processedAllPending = try await processPendingTypes()"
    )
    after_enqueue = work.index(
        "await reconcileMailboxDeliveryIfNeeded(at: .afterDurableEnqueue)"
    )
    assert before_payload < process_pending < after_enqueue
    assert (
        "try requireCurrentConnectionGeneration(expectedGeneration)"
        in work[before_payload:process_pending]
    )
    steps = _region(
        source,
        "private func processAutomaticStepRepresentations(",
        "private func automaticStepReadFailureResult(",
    )
    raw_read = steps.index(
        "let raw = await performRecentStepCounts(executionMode: .automatic)"
    )
    assert steps.index("let flushed = await flushPendingOutbox()") < raw_read
    assert re.search(
        str.join(
            "",
            (
                r"guard flushed, !statusIsError, trustedPendingOutboxCount\(\) == ",
                r"0 else \{\s*",
                r"return \.blocked\s*\}",
            ),
        ),
        steps[:raw_read],
    )
    daily_read = steps.index("let daily = await performDailyActivityAggregates(")
    assert re.search(r"case \.queued:\s*return \.blocked", steps[raw_read:daily_read])
    pending_result = _region(
        background_sync, "switch result.disposition {", "if reason == .scheduledRefresh"
    )
    assert re.search(r"case \.payloadEnqueued:\s*break", pending_result)
    assert re.search(r"case \.blocked:\s*return false", pending_result)


def _assert_retained_mailbox_reconciliation(source: str) -> None:
    mailbox_entry_start = source.index(
        "func runForegroundMailboxReconciliationIfNeeded()"
    )
    mailbox_entry_end = source.index("func noteSceneLeftActive()", mailbox_entry_start)
    helper_start = source.index("private func reconcileForegroundMailboxDelivery(")
    helper_end = source.index(
        "private func reconcileMailboxDeliveryIfNeeded(", helper_start
    )

    mailbox_entry = source[mailbox_entry_start:mailbox_entry_end]
    helper = source[helper_start:helper_end]

    assert "!Task.isCancelled" in mailbox_entry
    assert "settingsStore.activeTransport == .mailbox" in mailbox_entry
    assert "!foregroundMailboxOpportunityConsumed" in mailbox_entry
    assert "foregroundMailboxOpportunityConsumed = true" in mailbox_entry
    assert "reconcileForegroundMailboxDelivery(" in mailbox_entry
    assert "runBackgroundRefreshSync" not in mailbox_entry
    assert "syncRecentStepCounts" not in mailbox_entry
    assert "requestHealthPermissions" not in mailbox_entry

    bounded_phase = helper.index("reconcileMailboxDeliveryIfNeeded(")
    point = helper.index("at: .beforePayloadGeneration", bounded_phase)
    post_await_generation_check = helper.index(
        "try requireCurrentConnectionGeneration(expectedGeneration)", point
    )

    assert bounded_phase < point < post_await_generation_check
    assert "deliverPending()" not in helper
    assert "runBackgroundRefreshSync" not in helper
    assert "syncRecentStepCounts" not in helper
    assert "requestHealthPermissions" not in helper
    assert "preparePrivateStorageForUploadAdmission" not in helper
    assert "publishPendingFIFOHead()" not in helper
    assert "reconcilePendingFIFOHeadAcknowledgment(" not in helper

    failure_catch = helper.index("} catch {", post_await_generation_check)
    failure_generation_check = helper.index(
        "try requireCurrentConnectionGeneration(expectedGeneration)", failure_catch
    )
    failure_publication = helper.index(
        "MailboxDeliveryDiagnosticLine.failure(for: error)", failure_catch
    )
    assert failure_catch < failure_generation_check < failure_publication

    cancellation_start = source.index(
        "private func cancelAndAwaitForegroundPayloadTasks()"
    )
    cancellation_end = source.index(
        "private func drainTerminalBackgroundPayloadCancellation()", cancellation_start
    )
    cancellation = source[cancellation_start:cancellation_end]
    assert cancellation.index("catchUpTask?.cancel()") < cancellation.index(
        "await catchUpTask?.value"
    )


def test_mailbox_startup_and_foreground_use_shared_launch_catch_up() -> None:
    app = APP.read_text(encoding="utf-8")
    source = VIEW_MODEL.read_text(encoding="utf-8")
    runtime = AUTOMATIC_SYNC_RUNTIME.read_text(encoding="utf-8")
    background_sync = BACKGROUND_SYNC.read_text(encoding="utf-8")
    _assert_scene_launch_forwarding(app)
    _assert_foreground_runtime_admission(runtime)
    _assert_bootstrap_readiness(source, runtime)
    _assert_shared_engine_ack_backpressure(source, runtime, background_sync)
    _assert_retained_mailbox_reconciliation(source)


def test_foreground_mailbox_phase_is_admitted_once_per_active_scene() -> None:
    app = APP.read_text(encoding="utf-8")
    nonactive_start = app.index("} else {", app.index("if newPhase == .active"))
    nonactive_scene = app[
        nonactive_start : app.index(".backgroundTask(", nonactive_start)
    ]
    assert "applicationRuntime.noteSceneLeftActive()" in nonactive_scene
    assert "if newPhase == .background" in nonactive_scene

    source = VIEW_MODEL.read_text(encoding="utf-8")
    entry_start = source.index("func runForegroundMailboxReconciliationIfNeeded()")
    entry_end = source.index("func noteSceneLeftActive()", entry_start)
    entry = source[entry_start:entry_end]
    reset_start = entry_end
    reset_end = source.index(
        "private func reconcileForegroundMailboxDelivery(", reset_start
    )
    reset = source[reset_start:reset_end]

    assert "foregroundMailboxSceneIsActive = true" in entry
    assert "automaticSyncEnablePrerequisitesReady" in entry
    assert "backgroundSyncRequestedEnabled" in entry
    assert "canSendConnectionTest" not in entry
    assert "!foregroundMailboxOpportunityConsumed" in entry
    assert entry.index("foregroundMailboxOpportunityConsumed = true") < entry.index(
        "foregroundCatchUpTask = Task"
    )
    assert "foregroundMailboxSceneIsActive = false" in reset
    assert "foregroundMailboxOpportunityConsumed = false" in reset


def test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    target_start = source.index("private func capturePayloadDeliveryTarget()")
    target_end = source.index("private struct PayloadDelivery {", target_start)
    target_helpers = source[target_start:target_end]
    capture = target_helpers[
        : target_helpers.index("private func requireCurrentPayloadDeliveryTarget(")
    ]
    validation = target_helpers[
        target_helpers.index("private func requireCurrentPayloadDeliveryTarget(") :
    ]
    assert "let generation = settingsStore.receiverSettingsGenerationToken" in capture
    assert "try requireCurrentConnectionGeneration(generation)" in capture
    assert (
        "record.localScope.generation == settingsStore.receiverSettingsGeneration"
        in capture
    )
    assert "record.localScope.bindingID == bindingID" in capture
    assert "identity.opaqueBinding == bindingID" in capture
    assert "try requireCurrentConnectionGeneration(target.generation)" in validation
    assert "try capturePayloadDeliveryTarget() == target" in validation

    helper_start = source.index("private func uploadPendingOutbox(")
    helper_end = source.index(
        "private func makeProductionMailboxDelivery()", helper_start
    )
    helper = source[helper_start:helper_end]
    mailbox_start = helper.index("if target.route == .mailbox")
    mailbox_end = helper.index(
        "guard case .directHTTP(let url) = target.route", mailbox_start
    )
    mailbox = helper[mailbox_start:mailbox_end]

    delivery = mailbox.index("deliverPending()")
    post_await_target_check = mailbox.index(
        "try requireCurrentPayloadDeliveryTarget(target)", delivery
    )
    summary_mapping = mailbox.index(
        "mailboxDeliveryDiagnosticLine: summary.ackDiagnosticLine"
    )
    publication = mailbox.index(
        "mailboxDeliveryDiagnosticLine = flushSummary.mailboxDeliveryDiagnosticLine"
    )

    assert delivery < post_await_target_check < summary_mapping < publication
    assert mailbox.index("catch let cancellation as CancellationError") < mailbox.index(
        "catch {"
    )
    failure_catch = mailbox.index("catch {")
    failure_target_check = mailbox.index(
        "try requireCurrentPayloadDeliveryTarget(target)", failure_catch
    )
    failure_publication = mailbox.index(
        (
            "mailboxDeliveryDiagnosticLine = "
            "MailboxDeliveryDiagnosticLine.failure(for: error)"
        ),
        failure_catch,
    )
    assert failure_catch < failure_target_check < failure_publication


def test_background_mailbox_failure_checks_generation_before_publication() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    helper_start = source.index(
        "private func schedulePendingBackgroundOutboxUploadsNow("
    )
    helper_end = source.index("#endif", helper_start)
    helper = source[helper_start:helper_end]
    mailbox_start = helper.index("if settingsStore.activeTransport == .mailbox")
    mailbox_end = helper.index("let committedReceiverURLString", mailbox_start)
    mailbox = helper[mailbox_start:mailbox_end]

    assert "publishPendingFIFOHead()" in mailbox
    assert "deliverPending()" not in mailbox
    success_publication = mailbox.index(
        "mailboxDeliveryDiagnosticLine = summary.diagnosticLine"
    )
    failure_catch = mailbox.index("} catch {", success_publication)
    failure_generation_check = mailbox.index(
        "try requireCurrentConnectionGeneration(expectedGeneration)", failure_catch
    )
    failure_publication = mailbox.index(
        "MailboxDeliveryDiagnosticLine.failure(for: error)",
        failure_catch,
    )
    failure_status_publication = mailbox.index(
        'backgroundSyncStatus = "Encrypted iCloud mailbox delivery failed:',
        failure_catch,
    )

    assert failure_catch < failure_generation_check < failure_publication
    assert failure_generation_check < failure_status_publication


def test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    assignments = [
        line.strip()
        for line in source.splitlines()
        if "mailboxDeliveryDiagnosticLine =" in line
    ]

    assert any(
        "MailboxDeliveryDiagnosticLine.failure(for: error)" in line
        for line in assignments
    )
    assert all("describe(" not in line for line in assignments)
    assert all("localizedDescription" not in line for line in assignments)


def test_delivery_phase_wrappers_preserve_ack_processing_order() -> None:
    source = (
        Path("ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore")
        / "ProductionMailboxDelivery.swift"
    ).read_text(encoding="utf-8")
    delivery_start = source.index("public func deliverPending()")
    delivery_end = source.index("private func coordinator(", delivery_start)
    delivery = source[delivery_start:delivery_end]

    # A retained verified head can finalize before provider ACK scanning.
    # Check fresh ACK processing separately from that replay path.
    provider_ack_start = delivery.index("let ackLane: URL")
    assert delivery.index(".initialAdvance") < provider_ack_start
    provider_ack_processing = delivery[provider_ack_start:]

    phases = [
        ".locateAckLane",
        ".hydrateAck",
        ".scanAck",
        ".mapAckItem",
        ".consumeAck",
        ".remainingCount",
    ]
    offsets = [provider_ack_processing.index(phase) for phase in phases]

    assert offsets == sorted(offsets)


def test_background_delivery_uses_separate_bounded_publish_and_ack_phases() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    helper_start = source.index("private func reconcileMailboxDeliveryIfNeeded(")
    helper_end = source.index("func performAutomaticSyncOpportunity(", helper_start)
    helper = source[helper_start:helper_end]

    assert "publishPendingFIFOHead()" in helper
    assert "reconcilePendingFIFOHeadAcknowledgment(" in helper
    assert "deliverPending()" not in helper
    assert "Task {" not in helper
    acknowledgment = helper.index("reconcilePendingFIFOHeadAcknowledgment(")
    generation_check = helper.index(
        "try requireCurrentConnectionGeneration(expectedGeneration)",
        acknowledgment,
    )
    checkpoint_write = helper.index(
        "persistMailboxAckScanCheckpoint(", generation_check
    )
    assert acknowledgment < generation_check < checkpoint_write

    delivery = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ProductionMailboxDelivery.swift"
    ).read_text(encoding="utf-8")
    publish_start = delivery.index("public func publishPendingFIFOHead()")
    publish_end = delivery.index(
        "public func reconcilePendingFIFOHeadAcknowledgment(", publish_start
    )
    publish = delivery[publish_start:publish_end]
    assert "items.first" in publish
    assert "hydrate" not in publish.lower()
    assert ".scan(" not in publish

    acknowledge_end = delivery.index("public func deliverPending()", publish_end)
    acknowledge = delivery[publish_end:acknowledge_end]
    assert "maximumAcknowledgmentFiles" in acknowledge
    assert "acknowledgmentIndexForPendingFIFOHead" in acknowledge
    assert "for item in items" not in acknowledge
    scanner = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/MailboxAckScanner.swift"
    ).read_text(encoding="utf-8")
    window_start = scanner.index("func candidateWindow(")
    window_end = scanner.index("func scan(window:", window_start)
    window = scanner[window_start:window_end]
    assert "MailboxAckFileReader.enumerateWindow(" in window
    assert "MailboxAckFileReader.enumerate(" not in window
    assert "maximumNames: Self.maximumScanFiles" not in window
    assert "nextCheckpoint: enumeration.nextCheckpoint" in window

    reader = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/MailboxAckWindowReader.swift"
    ).read_text(encoding="utf-8")
    bounded_start = reader.index("static func enumerateWindow(")
    bounded = reader[bounded_start:]
    assert "getdirentriesattr(" in bounded
    assert "getattrlistbulk(" in bounded
    assert "var count = UInt32(maximumEntries)" in bounded
    assert "case ENOTSUP, ENOSYS:" in bounded
    assert "checkpoint.state != state" in bounded
    assert "readdir(" not in bounded
    assert "telldir(" not in bounded


def test_background_ack_prefers_exact_head_before_bounded_fallback() -> None:
    delivery = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ProductionMailboxDelivery.swift"
    ).read_text(encoding="utf-8")
    start = delivery.index("public func reconcilePendingFIFOHeadAcknowledgment(")
    acknowledge = delivery[
        start : delivery.index("public func deliverPending()", start)
    ]

    preference = acknowledge.index("preferDirectAcknowledgment(")
    direct = acknowledge.index("direct:", preference)
    exact_scan = acknowledge.index("scanExact(", direct)
    bounded_fallback = acknowledge.index("boundedFallback:", exact_scan)
    candidate_window = acknowledge.index("candidateWindow(", bounded_fallback)
    assert preference < direct < exact_scan < bounded_fallback < candidate_window
    assert "candidateWindow(" not in acknowledge[direct:bounded_fallback]
    assert (
        "candidateFileNames: [pendingFIFOHeadEnvelopeID.hexV1"
        in acknowledge[direct:bounded_fallback]
    )
    exact_result = acknowledge.index("usedExactCandidate: true", exact_scan)
    exact_delete_barrier = acknowledge.index(
        "!acknowledgment.usedExactCandidate", bounded_fallback
    )
    delete = acknowledge.index("deleteAcknowledgment(", exact_delete_barrier)
    assert exact_result < bounded_fallback < exact_delete_barrier < delete

    hydration = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/MailboxAckHydration.swift"
    ).read_text(encoding="utf-8")
    candidates_start = hydration.index("private static func candidateURLs(")
    candidates = hydration[candidates_start:]
    provided = candidates.index("if let candidateFileNames")
    fallback = candidates.index("} else {", provided)
    enumeration = candidates.index("MailboxAckFileReader.enumerate(", fallback)
    assert "MailboxAckFileReader.enumerate(" not in candidates[provided:fallback]
    assert provided < fallback < enumeration
    assert "identityFailureDisposition(" in candidates
    assert "explicitCandidate: candidateFileNames != nil" in candidates
    assert "case (.unavailable, true):" in hydration
    assert "case (.replaced, _), (.unavailable, false):" in hydration

    hydration_tests = Path(
        "ios/HealthBridgeCompanion/Tests/HealthBridgeCompanionCoreTests/MailboxAckHydrationTests.swift"
    ).read_text(encoding="utf-8")
    assert "testDirectAcknowledgmentHitDoesNotInvokeBoundedFallback" in hydration_tests
    assert (
        "testAbsentOrUnusableDirectAcknowledgmentFallsBackInSameOpportunity"
        in hydration_tests
    )
    assert (
        "testExplicitMissingCandidateIsSkippedWithoutWeakeningReplacementSafety"
        in hydration_tests
    )


def test_background_phase_diagnostics_are_lane_specific_and_secret_free() -> None:
    delivery = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ProductionMailboxDelivery.swift"
    ).read_text(encoding="utf-8")
    start = delivery.index("public struct ProductionMailboxBackgroundDeliverySummary")
    end = delivery.index("public final class ProductionMailboxDelivery", start)
    summary = delivery[start:end]

    assert "phase=" in summary
    assert "lane=" in summary
    assert "inspected=" in summary
    for forbidden in (
        "envelopeID",
        "cursorValue",
        "receiverID",
        "deviceID",
        "bindingID",
        "fileName",
        "token",
        "payload",
    ):
        assert forbidden not in summary


def test_background_ack_checkpoint_is_restartable_and_generation_bound() -> None:
    source = BACKGROUND_SYNC.read_text(encoding="utf-8")
    load_start = source.index("public func mailboxAckScanCheckpoint(")
    persist_start = source.index("public func persistMailboxAckScanCheckpoint(")
    load = source[load_start:persist_start]
    persist_end = source.index(
        "public func markPendingObserverTypeCodes(", persist_start
    )
    persist = source[persist_start:persist_end]

    assert "mailboxAckScanCheckpointGeneration" in load
    assert "== receiverGeneration" in load
    checkpoint_write = persist.index(
        "userDefaults.set(checkpoint, forKey: Key.mailboxAckScanCheckpoint)"
    )
    generation_write = persist.index("forKey: Key.mailboxAckScanCheckpointGeneration")
    durable_write = persist.index("userDefaults.synchronize()")
    assert checkpoint_write < generation_write < durable_write

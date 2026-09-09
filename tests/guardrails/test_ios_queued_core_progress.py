"""Bind executable scheduler-progress tests to the automatic app queue exit."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios/HealthBridgeCompanion"


def test_queued_progress_is_fenced_and_persisted_before_reconciliation() -> None:
    source = (IOS / "App/HealthBridgeCompanionViewModel.swift").read_text()
    start = source.index("private func performAdmittedBackgroundRefreshSync(")
    end = source.index("private func scheduleDebouncedObserverCatchUp()", start)
    body = source[start:end]
    reset = body.index("backgroundAutomaticSyncQuerySucceeded = false")
    query = body.index("switch lane", reset)
    progress = body.index("BackgroundSyncWorkExecutor.recordQueuedCoreLaneProgress(")
    reconcile = body.index("if await deferAutomaticSyncForPendingOutboxIfNeeded(")
    assert reset < query < progress < reconcile
    assert "backgroundAutomaticSyncEnqueueFailed = false" in body[reset:query]
    seam = body[progress:reconcile]
    assert "querySucceeded: backgroundAutomaticSyncQuerySucceeded" in seam
    assert "laneSucceeded: laneResult.succeeded" in seam
    assert "enqueueFailed: backgroundAutomaticSyncEnqueueFailed" in seam
    assert "pendingAfter: trustedPendingOutboxCount()" in seam
    fence = seam.index("requireCurrentConnectionGeneration(expectedGeneration)")
    persist = seam.index("backgroundSyncStore.recordCoreLaneSuccess(")
    assert fence < persist
    assert "self.automaticSyncReady, self.backgroundSyncEnabled" in seam
    assert "self.terminalPayloadActionAdmissionIsOpen" in seam
    assert "await" not in seam
    assert "diagnostic" not in seam.lower()
    assert "clearPendingObserverTypeCodes" not in seam
    assert "completeObserverWork" not in seam
    assert "return laneResult.succeeded && !laneResult.durablyQueuedPayload" in body
    assert "matching: observerGenerationSnapshot" in body


def test_query_and_failed_enqueue_facts_do_not_depend_on_diagnostic_storage() -> None:
    source = (IOS / "App/HealthBridgeCompanionViewModel.swift").read_text()
    start = source.index("private func noteAutomaticSyncQueryResult(")
    end = source.index("private func noteBackgroundAutomaticSyncFailure(", start)
    query = source[start:end]
    assert (
        query.index("guard executionMode == .automatic")
        < query.index("backgroundAutomaticSyncQuerySucceeded = true")
        < query.index("guard let diagnostic")
    )
    start = source.index("private func enqueuePayloads(")
    end = source.index("private func retryPrivateStoreInitialization()", start)
    enqueue = source[start:end]
    assert (
        enqueue.index("} catch {")
        < enqueue.index("backgroundAutomaticSyncEnqueueFailed = true")
        < enqueue.index("let finalItems = try? outbox.pendingItems()")
    )


def test_rejected_sleep_retirement_cannot_fall_through_as_lane_success() -> None:
    source = (IOS / "App/HealthBridgeCompanionViewModel.swift").read_text()
    delivery = source.index("private func deliverPendingSleepTransition(")
    start = source.index(
        "} catch let conflict as RejectedSleepBaselineOutboxItem {", delivery
    )
    end = source.index("return false", start)
    assert "statusIsError = true" in source[start:end]


def test_queued_progress_is_separate_from_completion_and_release_policy() -> None:
    path = IOS / "Sources/HealthBridgeCompanionCore/BackgroundSync.swift"
    source = path.read_text()
    start = source.index("public static func recordQueuedCoreLaneProgress(")
    end = source.index("public static func execute(", start)
    seam = "\n".join(line.split("//", 1)[0] for line in source[start:end].splitlines())
    assert seam.index("Task.checkCancellation()") < seam.index("try validate()")
    assert seam.index("try validate()") < seam.index("try persist(lane)")
    assert "querySucceeded, laneSucceeded, !enqueueFailed" in seam
    assert "pendingBefore == 0, let pendingAfter, pendingAfter > 0" in seam
    assert "await" not in seam
    assert "didComplete" not in seam
    assert "Diagnostic" not in seam
    assert "CoreFreshnessReleasePolicy" not in seam

"""Keep local causal evidence wired to real query and delivery boundaries."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios/HealthBridgeCompanion"
CORE = IOS / "Sources/HealthBridgeCompanionCore"


def test_each_automatic_healthkit_query_has_typed_start_and_result_seams() -> None:
    source = (IOS / "App/HealthBridgeCompanionViewModel.swift").read_text()
    for query in (
        "let changes = try await HealthKitStepCountReader",
        "let aggregates = try await HealthKitGenericQuantityReader",
        "let changes = try await HealthKitWorkoutReader",
        "let changes = try await HealthKitSleepReader",
        "let changes = try await reader.readAnchoredQuantityChanges",
    ):
        start = source.index(query)
        assert "noteAutomaticSyncQueryStarted(" in source[start - 110 : start]
        assert "noteAutomaticSyncQueryResult(" in source[start : start + 500]
    assert "diagnostic.notePlan(workPlan.attempts.map(\\.lane))" in source
    assert "diagnostic.noteAttempt(lane)" in source
    assert "diagnosticOutbox?.automaticSyncDiagnosticDraft = diagnostic" in source
    assert "diagnosticOutbox?.automaticSyncDiagnosticDraft = nil" in source


def test_local_outbox_evidence_is_not_payload_or_receiver_proof() -> None:
    source = (CORE / "FileOutbox.swift").read_text()
    enqueue_start = source.index("public func enqueueSequence(")
    enqueue_end = source.index("func stageEnqueueSequenceForTesting", enqueue_start)
    enqueue = source[enqueue_start:enqueue_end]
    assert enqueue.index("commitEnqueueTransaction(") < enqueue.index(
        "noteDiagnosticEnqueue(items, complete: true)"
    )
    assert "case .published, .providerObserved:" in source
    assert "case .ackVerified, .committedFinalized:" in source
    assert "case .terminalFailure:" in source
    assert (
        "noteDiagnosticDelivery(itemID: itemID, outcome: .mailboxAckPending)" in source
    )
    assert "noteDiagnosticDelivery(itemID: itemID, outcome: .accepted)" in source
    assert "noteDiagnosticDelivery(itemID: itemID, outcome: .rejected)" in source
    for relative, item_id in (
        ("App/BackgroundURLSessionOutboxUploader.swift", "itemID"),
        ("App/HealthBridgeCompanionViewModel.swift", "item.id"),
    ):
        assert (
            f"noteDiagnosticDelivery(itemID: {item_id}, outcome: .accepted)"
            in (IOS / relative).read_text()
        )
    replay = (CORE / "OutboxDeliveryCoordinatorAck.swift").read_text()
    assert (
        replay.count("noteDiagnosticDelivery(itemID: itemID, outcome: .accepted)") == 2
    )
    for name in ("BatchV1.swift", "BatchEncoding.swift", "ReceiverClient.swift"):
        assert "AutomaticSyncCausal" not in (CORE / name).read_text()


def test_durable_admission_is_recorded_at_the_accepted_marker_write_seam() -> None:
    source = (IOS / "App/HealthBridgeCompanionViewModel.swift").read_text()
    start = source.index("diagnostic.notePlan(workPlan.attempts.map(\\.lane))")
    end = source.index("if workPlan.lane == nil", start)
    seam = source[start:end]
    assert seam.index("guard recordBackgroundSyncRunIfAllowed(") < seam.index(
        "outcome: .accepted,"
    )
    failure = seam[seam.index(") else {") : seam.index("diagnostic.noteRunAccepted()")]
    assert failure.index("diagnostic.noteDurableStateUnavailable()") < failure.index(
        "await finishBackgroundRunPreservingObserverDirtiness("
    )
    assert failure.index("return") < len(failure)
    assert seam.index("diagnostic.noteRunAccepted()") < seam.index(
        "persistAcceptedAutomaticSyncDiagnostic(diagnostic)"
    )


def test_gate_has_no_product_defaults_or_aggregate_success_shortcut() -> None:
    source = (CORE / "AutomaticSyncCausalChain.swift").read_text()
    policy = source[source.index("public enum CoreFreshnessReleasePolicy") :]
    assert "maximumQueryAge: TimeInterval," in policy
    assert "maximumDeliveryAge: TimeInterval," in policy
    assert "sourceFreshnessRequirements:" in policy
    assert "maximumQueryAge: TimeInterval =" not in policy
    assert "maximumDeliveryAge: TimeInterval =" not in policy
    for forbidden in ("uploadedCount", "pendingOutboxCount", "receiverSuccess"):
        assert forbidden not in policy
    assert "chain.durableAdmission == .persisted" in policy
    assert "chain.version == 2" in policy
    assert "!chain.truncated" in policy
    assert "lane.query == .records || lane.query == .noRecords" in policy
    assert "sourceIsFresh(lane, requirement: sourceRequirement)" in policy
    assert "lane.delivery == .accepted" in policy
    assert "lane.pendingItems.isEmpty" in policy
    assert "fresh == requiredLanes" in policy
    project = (IOS / "HealthBridgeCompanion.xcodeproj/project.pbxproj").read_text()
    assert project.count("AutomaticSyncCausalChain.swift in Sources") == 2
    assert project.count("path = AutomaticSyncCausalChain.swift;") == 1

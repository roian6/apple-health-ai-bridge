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
        "let changes: HealthKitAnchoredSleepChanges",
        "let changes = try await reader.readAnchoredQuantityChanges",
    ):
        start = source.index(query)
        assert "noteAutomaticSyncQueryStarted(" in source[start - 180 : start]
        assert "noteAutomaticSyncQueryResult(" in source[start : start + 900]


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

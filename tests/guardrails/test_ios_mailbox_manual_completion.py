"""Mutation controls for frozen manual Mailbox completion source contracts."""

from pathlib import Path
from typing import Final

import pytest

from tests.guardrails import test_ios_mailbox_ack_diagnostics as guards
from tests.guardrails.mailbox_manual_completion_contract import (
    assert_mailbox_journal_finalization_contract,
    assert_new_mailbox_finalization_contract,
)
from tests.guardrails.test_ios_mailbox_publication_order import mutated_view_model

_MANUAL: Final = "private func uploadPendingOutbox("
_INSERT: Final = "completedOperations.insert(.persistScanCheckpoint)"
_CAS: Final = "write.canRetry(from: backgroundSyncStore.mailboxAckScanCheckpoint("
_PERSIST: Final = """try backgroundSyncStore.persistMailboxAckScanCheckpoint(
                            write.checkpoint, receiverGeneration: expectedGeneration
                        )"""
_BOUNDED: Final = "private func reconcileMailboxDeliveryIfNeeded("
_MANUAL_CANCEL: Final = """} catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                try requireCurrentPayloadDeliveryTarget(target)"""
_CORE: Final = Path("ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore")
_MANUAL_GUARD = (
    guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check
)
_BOUNDED_GUARD = (
    guards.test_background_delivery_uses_separate_bounded_publish_and_ack_phases
)


@pytest.mark.parametrize(
    ("before", "after"),
    [
        pytest.param(
            f"{_PERSIST}\n                        {_INSERT}",
            f"{_INSERT}\n                        {_PERSIST}",
            id="credit-before-write",
        ),
        pytest.param(
            _PERSIST, f"try? {_PERSIST.removeprefix('try ')}", id="ignore-write-error"
        ),
        pytest.param(_CAS, f"true || {_CAS}", id="bypass-compare-and-set"),
        pytest.param(
            _PERSIST,
            _PERSIST.replace("expectedGeneration", "someOtherGeneration"),
            id="write-wrong-generation",
        ),
        pytest.param(
            "completedOperations: completedOperations\n                        )",
            """completedOperations: [.manualDelivery, .persistScanCheckpoint]
                        )""",
            id="credit-failed-write-at-sink",
        ),
    ],
)
def test_manual_checkpoint_completion_requires_exact_successful_write(
    monkeypatch: pytest.MonkeyPatch, before: str, after: str
) -> None:
    monkeypatch.setattr(
        guards, "VIEW_MODEL", mutated_view_model(_MANUAL, ((before, after),))
    )

    with pytest.raises(AssertionError, match="only after the exact"):
        guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check()


@pytest.mark.parametrize(
    ("scope", "before", "after", "reason"),
    [
        pytest.param(
            _MANUAL,
            _MANUAL_CANCEL,
            _MANUAL_CANCEL.replace(
                "throw cancellation",
                "finalizedOwner = nil\n                throw cancellation",
            ),
            "cancellation must preserve",
            id="manual-drop-commit-after-cancellation",
        ),
        pytest.param(
            _BOUNDED,
            "finalizedOwner = nil\n                return .cancelled",
            "return .cancelled",
            "unconditional authority check",
            id="bounded-credit-after-stale-generation",
        ),
        pytest.param(
            _BOUNDED,
            "} catch is CancellationError {\n            return .cancelled",
            """} catch is CancellationError {
            finalizedOwner = nil
            return .cancelled""",
            "cancellation must preserve",
            id="bounded-drop-commit-after-cancellation",
        ),
        pytest.param(
            _MANUAL,
            """} catch {
                try requireCurrentPayloadDeliveryTarget(target)""",
            """} catch {
                if finalizedOwner != nil {
                    try requireCurrentPayloadDeliveryTarget(target)
                }""",
            "unconditional authority check",
            id="manual-conditional-failure-fence",
        ),
        pytest.param(
            _MANUAL,
            "let flushSummary = FileOutboxFlushSummary(",
            """if summary.finalizedCount > 0 {
                    recordAcceptedTransfer(
                        bindingID: target.bindingID, generation: target.generation,
                        evidenceKind: .mailboxCommit
                    )
                }
                let flushSummary = FileOutboxFlushSummary(""",
            "must not separately credit acceptance",
            id="manual-double-credit-from-summary",
        ),
        pytest.param(
            _BOUNDED,
            "completedOperations.insert(operation)",
            """completedOperations.insert(operation)
            if summary.finalizedCount > 0, let acceptanceTarget {
                recordAcceptedTransfer(
                    bindingID: acceptanceTarget.bindingID,
                    generation: expectedGeneration, evidenceKind: .mailboxCommit
                )
            }""",
            "must not separately credit acceptance",
            id="bounded-double-credit-from-summary",
        ),
    ],
)
def test_mailbox_opportunity_does_not_overcredit_finalization(
    monkeypatch: pytest.MonkeyPatch, scope: str, before: str, after: str, reason: str
) -> None:
    monkeypatch.setattr(
        guards, "VIEW_MODEL", mutated_view_model(scope, ((before, after),))
    )

    guard = _MANUAL_GUARD if scope == _MANUAL else _BOUNDED_GUARD
    with pytest.raises(AssertionError, match=reason):
        guard()


def test_manual_checkpoint_guard_accepts_renamed_write(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mutant = mutated_view_model(
        _MANUAL,
        (
            (
                "let write = pendingMailboxCheckpointWrite",
                "let retry = pendingMailboxCheckpointWrite",
            ),
            ("write.canRetry(", "retry.canRetry("),
            ("write.checkpoint", "retry.checkpoint"),
            ("throw write", "throw retry"),
        ),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check()


@pytest.mark.parametrize(
    "check",
    [
        "outbox === deliveryOutbox",
        "ownership.receiverGeneration == target.generation",
        "ownership.receiverBindingID == target.bindingID",
        "(try? currentPayloadDeliveryTarget()) == target",
        "(try? deliveryOutbox.requireUploadAdmission()) != nil",
    ],
    ids=["outbox", "generation", "binding", "target", "admission"],
)
def test_mailbox_attribution_requires_current_owner_and_admitted_outbox(
    monkeypatch: pytest.MonkeyPatch, check: str
) -> None:
    mutant = mutated_view_model(
        "private func recordNewMailboxFinalization(", ((check, "true"),)
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="requires live target"):
        guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check()


@pytest.mark.parametrize(
    ("before", "after"),
    [
        pytest.param(
            "report = try components.scanner.scan()",
            """report = try components.scanner.scan()
            if let owner = items.first?.deliveryState?.ownership {
                onNewFinalization(owner)
            }""",
            id="add-scan-success-credit",
        ),
        pytest.param(
            """report = try components.scanner.scan()
        } catch is CancellationError {
            throw CancellationError()""",
            """report = try components.scanner.scan()
        } catch is CancellationError {
            if let owner = items.first?.deliveryState?.ownership {
                onNewFinalization(owner)
            }
            throw CancellationError()""",
            id="add-scan-cancellation-credit",
        ),
    ],
)
def test_core_does_not_signal_from_scan_outcomes(before: str, after: str) -> None:
    source = (_CORE / "ProductionMailboxDelivery.swift").read_text(encoding="utf-8")
    start = source.index("public func deliverPending()")
    end = source.index("private func coordinator(", start)
    delivery = source[start:end]
    assert delivery.count(before) == 1

    with pytest.raises(AssertionError, match="must not synthesize or duplicate"):
        assert_new_mailbox_finalization_contract(source.replace(before, after, 1))


@pytest.mark.parametrize(
    "before",
    [
        """try retireCommittedArtifacts(for: manifest.entries[index], fault: fault)
            return committed""",
        "throw FileOutboxMailboxError.deliveryTransitionConflict",
        "try persistManifest(manifest) { onNewFinalization() }",
    ],
    ids=["replay", "failed-cas", "before-durable-write"],
)
def test_journal_does_not_signal_replay_or_uncommitted_write(before: str) -> None:
    coordinator = (_CORE / "OutboxDeliveryCoordinatorAck.swift").read_text(
        encoding="utf-8"
    )
    source = (_CORE / "FileOutbox.swift").read_text(encoding="utf-8")
    start = source.index("func finalizeCommittedMailboxDelivery(")
    end = source.index("public func ", start)
    owner = source[start:end]
    assert owner.count(before) == 1
    mutant = owner.replace(before, f"onNewFinalization(); {before}", 1)

    with pytest.raises(AssertionError, match="Only a new durable finalization"):
        assert_mailbox_journal_finalization_contract(
            coordinator, source[:start] + mutant + source[end:]
        )


@pytest.mark.parametrize(
    "before",
    [
        pytest.param(
            "try bytes.write(to: sequenceURL, options: [.atomic])",
            id="signal-before-possible-write-failure",
        ),
        pytest.param(
            "decodedManifest = (bytes, manifest)",
            id="signal-after-throwing-hardening",
        ),
    ],
)
def test_journal_signals_between_atomic_write_and_hardening(before: str) -> None:
    coordinator = (_CORE / "OutboxDeliveryCoordinatorAck.swift").read_text(
        encoding="utf-8"
    )
    source = (_CORE / "FileOutbox.swift").read_text(encoding="utf-8")
    start = source.index("private func persistManifest(")
    end = source.index("private static func validate(", start)
    persist = source[start:end]
    callback = "        onAtomicWrite()\n"
    assert persist.count(before) == 1
    assert persist.count(callback) == 1
    mutant = persist.replace(callback, "", 1).replace(
        before, f"onAtomicWrite()\n        {before}", 1
    )

    with pytest.raises(AssertionError, match="after the atomic manifest write"):
        assert_mailbox_journal_finalization_contract(
            coordinator, source[:start] + mutant + source[end:]
        )

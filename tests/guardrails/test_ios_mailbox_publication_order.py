from collections.abc import Callable
from dataclasses import dataclass

import pytest

from tests.guardrails import test_ios_mailbox_ack_diagnostics as guards

_MANUAL = "private func uploadPendingOutbox("
_SCHEDULER = "private func schedulePendingBackgroundOutboxUploadsNow("
_FOREGROUND = "private func reconcileForegroundMailboxDelivery("
_BOUNDED = "private func reconcileMailboxDeliveryIfNeeded("
_TARGET_FENCE = "try requireCurrentPayloadDeliveryTarget(target)"
_GENERATION_FENCE = "try requireCurrentConnectionGeneration(expectedGeneration)"
_SUSPENSION = "Mailbox publication must not suspend again"
_EARLY_WRITE = "Mailbox publication must follow"
_BOUNDED_PROGRESS = "            completedOperations.insert(operation)"
_BOUNDED_SET = "var completedOperations: Set<MailboxDeliveryOperation> = "
_SCHEDULER_TERMINAL = "\n                if summary.terminalCount > 0 {"
_CHECKPOINT_FAILURE_ARGUMENT = (
    "completedOperations: completedOperations\n" + " " * 20 + ")"
)
_CHECKPOINT_CREDIT = (
    "                    completedOperations.insert(.persistScanCheckpoint)\n"
)
_CHECKPOINT_WRITE = (
    " " * 20 + "try backgroundSyncStore.persistMailboxAckScanCheckpoint("
)
_SCHEDULE = guards.test_background_mailbox_failure_checks_generation_before_publication
_FLUSH = guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check


@dataclass(frozen=True, slots=True)
class _InMemoryViewModel:
    source: str

    def read_text(self, **_: str) -> str:
        return self.source


@pytest.mark.parametrize(
    ("guard", "scope", "replacement", "reason"),
    [
        pytest.param(
            guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check,
            _MANUAL,
            (
                "completedOperations: completedOperations\n                )",
                """completedOperations: await MainActor.run { completedOperations }
                )""",
            ),
            _SUSPENSION,
            id="manual-summary-final-argument",
        ),
        pytest.param(
            guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check,
            _MANUAL,
            (
                "operation: .manualDelivery)",
                "operation: await MainActor.run { .manualDelivery })",
            ),
            _SUSPENSION,
            id="manual-failure-final-argument",
        ),
        pytest.param(
            guards.test_background_mailbox_failure_checks_generation_before_publication,
            _SCHEDULER,
            (
                "completedOperations: [.publishFIFOHead]",
                "completedOperations: await MainActor.run { [.publishFIFOHead] }",
            ),
            _SUSPENSION,
            id="scheduler-summary-final-argument",
        ),
        pytest.param(
            guards.test_background_mailbox_failure_checks_generation_before_publication,
            _SCHEDULER,
            (
                r"failed: \(description)",
                r"failed: \(await MainActor.run { description })",
            ),
            _SUSPENSION,
            id="scheduler-failure-status-expression",
        ),
        pytest.param(
            guards.test_mailbox_startup_and_foreground_use_shared_launch_catch_up,
            _FOREGROUND,
            (
                "generation: expectedGeneration)",
                "generation: String(await MainActor.run { expectedGeneration }))",
            ),
            _SUSPENSION,
            id="foreground-nested-failure-argument",
        ),
        pytest.param(
            guards.test_background_delivery_uses_separate_bounded_publish_and_ack_phases,
            _BOUNDED,
            (
                """completedOperations: completedOperations
            )
            if summary.terminalCount > 0""",
                """completedOperations: await MainActor.run { completedOperations }
            )
            if summary.terminalCount > 0""",
            ),
            _SUSPENSION,
            id="bounded-normal-final-argument",
        ),
        pytest.param(
            guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check,
            _MANUAL,
            (
                f"{_TARGET_FENCE}\n                let flushSummary",
                f"""{_TARGET_FENCE}
                await Task.yield()
                let flushSummary""",
            ),
            _SUSPENSION,
            id="manual-intervening-await-control",
        ),
        pytest.param(
            guards.test_background_mailbox_failure_checks_generation_before_publication,
            _SCHEDULER,
            (
                f"{_GENERATION_FENCE}\n                refreshPendingOutboxCount()",
                f"refreshPendingOutboxCount()\n                {_GENERATION_FENCE}",
            ),
            _EARLY_WRITE,
            id="scheduler-pending-refresh-before-fence",
        ),
        pytest.param(
            guards.test_background_delivery_uses_separate_bounded_publish_and_ack_phases,
            _BOUNDED,
            (
                f"{_GENERATION_FENCE}\n{_BOUNDED_PROGRESS}",
                f"""statusMessage = "Unvalidated reconciliation"
            {_GENERATION_FENCE}
{_BOUNDED_PROGRESS}""",
            ),
            _EARLY_WRITE,
            id="bounded-visible-status-before-fence",
        ),
        pytest.param(
            guards.test_background_delivery_uses_separate_bounded_publish_and_ack_phases,
            _BOUNDED,
            (
                f"{_BOUNDED_SET}[]",
                f"{_BOUNDED_SET}[.persistScanCheckpoint]",
            ),
            "Unsupported Swift before Mailbox authority",
            id="bounded-completion-set-must-start-empty",
        ),
    ],
)
def test_guard_rejects_out_of_order_mailbox_publication(
    monkeypatch: pytest.MonkeyPatch,
    guard: Callable[[], None],
    scope: str,
    replacement: tuple[str, str],
    reason: str,
) -> None:
    monkeypatch.setattr(guards, "VIEW_MODEL", mutated_view_model(scope, (replacement,)))

    with pytest.raises(AssertionError, match=reason):
        guard()


def mutated_view_model(
    scope: str, replacements: tuple[tuple[str, str], ...]
) -> _InMemoryViewModel:
    source = guards.VIEW_MODEL.read_text(encoding="utf-8")
    start = source.index(scope)
    end = source.index("\n    }", start)
    branch = source[start:end]
    for before, after in replacements:
        assert branch.count(before) == 1
        branch = branch.replace(before, after, 1)
    return _InMemoryViewModel(source[:start] + branch + source[end:])


@pytest.mark.parametrize(
    "mutation",
    [
        "mailboxDeliveryDiagnosticLines.reverse()",
        """if self.mailboxDeliveryDiagnosticLines.count == 2 {
                    self.mailboxDeliveryDiagnosticLines.swapAt(0, 1)
                }""",
    ],
    ids=["reverse", "swap-elements"],
)
def test_scheduler_rejects_reordering_retained_diagnostics(
    monkeypatch: pytest.MonkeyPatch, mutation: str
) -> None:
    mutant = mutated_view_model(
        _SCHEDULER,
        ((_SCHEDULER_TERMINAL, f"\n                {mutation}{_SCHEDULER_TERMINAL}"),),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="only through scoped Mailbox publishers"):
        _SCHEDULE()


@pytest.mark.parametrize(
    "replacements",
    [
        pytest.param(
            (
                (
                    _BOUNDED_PROGRESS,
                    "            operation = .persistScanCheckpoint\n"
                    + _BOUNDED_PROGRESS,
                ),
            ),
            id="overwrite-selected-operation-before-credit",
        ),
        pytest.param(
            (
                (
                    _CHECKPOINT_FAILURE_ARGUMENT,
                    _CHECKPOINT_FAILURE_ARGUMENT.replace(
                        "completedOperations\n",
                        "completedOperations.union([.persistScanCheckpoint])\n",
                    ),
                ),
            ),
            id="credit-in-failure-argument",
        ),
        pytest.param(
            (
                (_CHECKPOINT_CREDIT, ""),
                (_CHECKPOINT_WRITE, _CHECKPOINT_CREDIT + _CHECKPOINT_WRITE),
            ),
            id="credit-before-write",
        ),
        pytest.param(((_CHECKPOINT_CREDIT, ""),), id="no-credit-after-success"),
        pytest.param(
            (
                (
                    "throw write\n                }\n            }",
                    """throw write
                }
            } else {
                completedOperations.insert(.persistScanCheckpoint)
            }""",
                ),
            ),
            id="credit-when-no-write-is-admitted",
        ),
    ],
)
def test_bounded_checkpoint_credits_only_successful_persistence(
    monkeypatch: pytest.MonkeyPatch, replacements: tuple[tuple[str, str], ...]
) -> None:
    mutant = mutated_view_model(_BOUNDED, replacements)
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="only after the bounded checkpoint write"):
        guards.test_background_delivery_uses_separate_bounded_publish_and_ack_phases()


@pytest.mark.parametrize("wrapper", ["conditional", "error-suppressed"])
def test_scheduler_success_rejects_non_dominating_sibling_fence(
    monkeypatch: pytest.MonkeyPatch, wrapper: str
) -> None:
    admission = f"{_GENERATION_FENCE}\n                let summary"
    recheck = f"{_GENERATION_FENCE}\n                refreshPendingOutboxCount()"
    opening = "if summary.finalizedCount < 0 {" if wrapper == "conditional" else "do {"
    closing = "}" if wrapper == "conditional" else "} catch {}"
    wrapped = f"""{opening}
                    {_GENERATION_FENCE}
                {closing}"""
    nested_admission = f"""do {{
                    {_GENERATION_FENCE}
                }}
                let summary"""
    mutant = mutated_view_model(
        _SCHEDULER,
        (
            (admission, nested_admission),
            (recheck, f"{wrapped}\n                refreshPendingOutboxCount()"),
        ),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match=r"authority|unconditional"):
        _SCHEDULE()


@pytest.mark.parametrize("change", ["comment", "generation", "operation"])
def test_scheduler_failure_requires_active_scoped_publisher(
    monkeypatch: pytest.MonkeyPatch, change: str
) -> None:
    call = (
        "publishMailboxDeliveryFailure(error, generation: expectedGeneration, "
        "operation: .publishFIFOHead)"
    )
    replacement = {
        "comment": "// " + call,
        "generation": call.replace("expectedGeneration", "currentGeneration"),
        "operation": call.replace(".publishFIFOHead", ".manualDelivery"),
    }[change]
    monkeypatch.setattr(
        guards, "VIEW_MODEL", mutated_view_model(_SCHEDULER, ((call, replacement),))
    )
    with pytest.raises(AssertionError, match="scheduler failure"):
        _SCHEDULE()


@pytest.mark.parametrize("wrapper", ["conditional", "error-suppressed"])
def test_scheduler_failure_requires_an_exiting_fence(
    monkeypatch: pytest.MonkeyPatch, wrapper: str
) -> None:
    fence = f"""do {{
                    {_GENERATION_FENCE}
                }} catch {{
                    return
                }}"""
    wrapped = (
        f"if pendingOutboxCount > 0 {{ {fence} }}"
        if wrapper == "conditional"
        else f"do {{ {_GENERATION_FENCE} }} catch {{}}"
    )
    monkeypatch.setattr(
        guards, "VIEW_MODEL", mutated_view_model(_SCHEDULER, ((fence, wrapped),))
    )

    with pytest.raises(AssertionError, match=r"authority|Stale Mailbox"):
        _SCHEDULE()


@pytest.mark.parametrize(
    ("guard", "scope", "fence", "operation"),
    [
        (_FLUSH, _MANUAL, _TARGET_FENCE, "manualDelivery"),
        (_SCHEDULE, _SCHEDULER, _GENERATION_FENCE, "publishFIFOHead"),
    ],
    ids=["manual", "scheduler"],
)
def test_guard_accepts_hoisted_argument_before_revalidation(
    monkeypatch: pytest.MonkeyPatch,
    guard: Callable[[], None],
    scope: str,
    fence: str,
    operation: str,
) -> None:
    following = {
        _MANUAL: "let flushSummary",
        _SCHEDULER: "refreshPendingOutboxCount()",
    }[scope]
    anchor = f"{fence}\n                {following}"
    argument = f"[.{operation}]"
    name = "initialOperations" if scope == _MANUAL else "operations"
    hoist = f"""let {name}: Set<MailboxDeliveryOperation> = await MainActor.run {{
                    {argument}
                }}"""
    passing = (
        f"var completedOperations: Set<MailboxDeliveryOperation> = {argument}"
        if scope == _MANUAL
        else f"completedOperations: {argument}"
    )
    mutant = mutated_view_model(
        scope,
        (
            (anchor, f"{hoist}\n                {anchor}"),
            (passing, passing.replace(argument, name)),
        ),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    guard()


def test_guard_accepts_suspension_after_last_visible_write(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cancellation = "\n            } catch is CancellationError {"
    mutant = mutated_view_model(
        _SCHEDULER,
        ((cancellation, f"\n                await Task.yield(){cancellation}"),),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    _SCHEDULE()

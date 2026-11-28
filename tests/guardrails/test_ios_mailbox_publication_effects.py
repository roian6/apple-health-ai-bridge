from collections.abc import Callable

import pytest

from tests.guardrails import test_ios_mailbox_ack_diagnostics as guards
from tests.guardrails.test_ios_mailbox_publication_order import mutated_view_model

_SCHEDULER = "private func schedulePendingBackgroundOutboxUploadsNow("
_MANUAL = "private func uploadPendingOutbox("
_FOREGROUND = "private func reconcileForegroundMailboxDelivery("
_BOUNDED = "private func reconcileMailboxDeliveryIfNeeded("
_GENERATION_FENCE = "try requireCurrentConnectionGeneration(expectedGeneration)"
_TARGET_FENCE = "try requireCurrentPayloadDeliveryTarget(target)"
_MANUAL_GENERATION = "let expectedGeneration = target.generation"
_SCHEDULE = guards.test_background_mailbox_failure_checks_generation_before_publication
_FLUSH = guards.test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check
_FOREGROUND_RECONCILE = (
    guards.test_mailbox_startup_and_foreground_use_shared_launch_catch_up
)
_BOUNDED_RECONCILE = (
    guards.test_background_delivery_uses_separate_bounded_publish_and_ack_phases
)

_SCHEDULE_RECHECK = f"{_GENERATION_FENCE}\n                refreshPendingOutboxCount()"
_STATUS_WRITEBACK = 'statusMessage.append("Mailbox publication attempted.")'
_CAPTURED_REFRESH = (
    "let refresh = { [callback = self.refreshPendingOutboxCount] in callback() }"
)
_SCHEDULER_CANCEL = "\n            } catch is CancellationError {"
_TRAILING_WRITE = 'statusMessage.append("Mailbox update")'


@pytest.mark.parametrize(
    ("guard", "scope", "replacement"),
    [
        pytest.param(
            _SCHEDULE,
            _SCHEDULER,
            (
                _SCHEDULE_RECHECK,
                f"{_STATUS_WRITEBACK}\n                {_SCHEDULE_RECHECK}",
            ),
            id="scheduler-success-status-writeback",
        ),
        pytest.param(
            _SCHEDULE,
            _SCHEDULER,
            (
                _SCHEDULE_RECHECK,
                f"""let refresh = refreshPendingOutboxCount
                refresh()
                {_GENERATION_FENCE}""",
            ),
            id="scheduler-success-method-alias",
        ),
        pytest.param(
            _FLUSH,
            _MANUAL,
            (
                f"{_TARGET_FENCE}\n                let flushSummary",
                f"""{_CAPTURED_REFRESH}
                refresh()
                {_TARGET_FENCE}
                let flushSummary""",
            ),
            id="manual-success-captured-method",
        ),
        pytest.param(
            _FOREGROUND_RECONCILE,
            _FOREGROUND,
            (
                "} catch {\n            do {",
                """} catch {
            let callback = await MainActor.run { self.refreshPendingOutboxCount }
            callback()
            do {""",
            ),
            id="foreground-failure-effectful-hoist",
        ),
        pytest.param(
            _FLUSH,
            _MANUAL,
            (
                f"}} catch {{\n                {_TARGET_FENCE}",
                f"""}} catch {{
                withUnsafeMutablePointer(to: &statusMessage) {{
                    $0.pointee.removeAll()
                }}
                {_TARGET_FENCE}""",
            ),
            id="manual-failure-inout-writeback",
        ),
        pytest.param(
            _BOUNDED_RECONCILE,
            _BOUNDED,
            (
                """summary = try await delivery.publishPendingFIFOHeadWithOwnership()
            case""",
                """summary = try await delivery.publishPendingFIFOHeadWithOwnership()
                self.objectWillChange.send()
            case""",
            ),
            id="bounded-success-effect-inside-delivery-switch",
        ),
        pytest.param(
            _BOUNDED_RECONCILE,
            _BOUNDED,
            (
                "} catch {\n            do {",
                """} catch {
            self.statusMessage.removeAll(keepingCapacity: true)
            do {""",
            ),
            id="bounded-failure-mutating-member-call",
        ),
        pytest.param(
            _SCHEDULE,
            _SCHEDULER,
            (
                "if settingsStore.activeTransport == .mailbox {\n            do {",
                f"""if settingsStore.activeTransport == .mailbox {{
            {_STATUS_WRITEBACK}
            do {{""",
            ),
            id="scheduler-effect-outside-delivery-do",
        ),
    ],
)
def test_guard_rejects_uncertified_prefence_effects(
    monkeypatch: pytest.MonkeyPatch,
    guard: Callable[[], None],
    scope: str,
    replacement: tuple[str, str],
) -> None:
    monkeypatch.setattr(guards, "VIEW_MODEL", mutated_view_model(scope, (replacement,)))

    with pytest.raises(
        AssertionError, match="Unsupported Swift before Mailbox authority"
    ):
        guard()


@pytest.mark.parametrize(
    "effect",
    [_TRAILING_WRITE, f"{_CAPTURED_REFRESH}; refresh()"],
    ids=["status-writeback", "captured-method"],
)
def test_guard_rejects_unknown_effect_after_trailing_suspension(
    monkeypatch: pytest.MonkeyPatch, effect: str
) -> None:
    suspended_write = f"""
                await Task.yield(); {effect}{_SCHEDULER_CANCEL}"""
    mutant = mutated_view_model(
        _SCHEDULER,
        ((_SCHEDULER_CANCEL, suspended_write),),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(
        AssertionError, match="Unsupported Swift after Mailbox suspension"
    ):
        _SCHEDULE()


@pytest.mark.parametrize(
    ("guard", "scope", "replacement", "reason"),
    [
        (
            _FLUSH,
            _MANUAL,
            (
                _MANUAL_GENERATION,
                f'let expectedGeneration = "" // {_MANUAL_GENERATION}',
            ),
            "captured generation",
        ),
        (
            _SCHEDULE,
            _SCHEDULER,
            ("completedOperations: [.publishFIFOHead]", "completedOperations: []"),
            "completed operations",
        ),
        (
            _SCHEDULE,
            _SCHEDULER,
            (
                "completedOperations: [.publishFIFOHead]",
                "completedOperations: [.publishFIFOHead, .manualDelivery]",
            ),
            "completed operations",
        ),
    ],
)
def test_publication_requires_exact_scoped_inputs(
    monkeypatch: pytest.MonkeyPatch,
    guard: Callable[[], None],
    scope: str,
    replacement: tuple[str, str],
    reason: str,
) -> None:
    monkeypatch.setattr(guards, "VIEW_MODEL", mutated_view_model(scope, (replacement,)))
    with pytest.raises(AssertionError, match=reason):
        guard()


def test_guard_accepts_suspension_after_actual_last_write(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trailing = f"""
                {_TRAILING_WRITE}
                await Task.yield(){_SCHEDULER_CANCEL}"""
    mutant = mutated_view_model(_SCHEDULER, ((_SCHEDULER_CANCEL, trailing),))
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    _SCHEDULE()


def test_guard_does_not_treat_deferred_write_as_already_complete(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trailing = f"""
                defer {{ {_TRAILING_WRITE} }}
                await Task.yield(){_SCHEDULER_CANCEL}"""
    mutant = mutated_view_model(_SCHEDULER, ((_SCHEDULER_CANCEL, trailing),))
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="Unsupported deferred Swift"):
        _SCHEDULE()


def test_guard_does_not_treat_scheduled_closure_as_a_completed_write(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trailing = f"""
                Task {{ {_TRAILING_WRITE} }}
                await Task.yield(){_SCHEDULER_CANCEL}"""
    mutant = mutated_view_model(_SCHEDULER, ((_SCHEDULER_CANCEL, trailing),))
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="Unsupported deferred or closure-scoped"):
        _SCHEDULE()

import pytest

from tests.guardrails import test_ios_mailbox_ack_diagnostics as guards
from tests.guardrails.test_ios_mailbox_publication_order import mutated_view_model

_FOREGROUND = "private func reconcileForegroundMailboxDelivery("
_ARGUMENT = "generation: expectedGeneration)"
_RAW_AWAIT = r'#"\#(await MainActor.run { expectedGeneration })"#'
_NESTED_AWAIT = r'"\(expectedGeneration.isEmpty ? "unknown" : ARG)"'.replace(
    "ARG", "await MainActor.run { expectedGeneration }"
)
_CATCH_UP = guards.test_mailbox_startup_and_foreground_use_shared_launch_catch_up


def test_foreground_failure_rejects_conditional_fence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fence = """do {
                try requireCurrentConnectionGeneration(expectedGeneration)
            } catch {
                return
            }"""
    conditional = f"if !Task.isCancelled {{ {fence} }}"
    mutant = mutated_view_model(_FOREGROUND, ((fence, conditional),))
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match=r"authority|Stale Mailbox"):
        _CATCH_UP()


@pytest.mark.parametrize(
    "expression",
    [_RAW_AWAIT, _NESTED_AWAIT],
    ids=["raw", "nested"],
)
def test_foreground_failure_checks_await_in_interpolated_final_argument(
    monkeypatch: pytest.MonkeyPatch, expression: str
) -> None:
    mutant = mutated_view_model(
        _FOREGROUND, ((_ARGUMENT, f"generation: {expression})"),)
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(
        AssertionError, match="Mailbox publication must not suspend again"
    ):
        _CATCH_UP()


@pytest.mark.parametrize("hoisted", [False, True], ids=["synchronous", "hoisted-raw"])
def test_foreground_failure_accepts_safe_interpolation(
    monkeypatch: pytest.MonkeyPatch, hoisted: bool
) -> None:
    synchronous = r'"\(expectedGeneration.isEmpty ? "unknown" : expectedGeneration)"'
    hoist = f"""}} catch {{
            let gen = {_RAW_AWAIT}
            do {{"""
    replacements = (
        (("} catch {\n            do {", hoist), (_ARGUMENT, "generation: gen)"))
        if hoisted
        else ((_ARGUMENT, f"generation: {synchronous})"),)
    )
    mutant = mutated_view_model(_FOREGROUND, replacements)
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    _CATCH_UP()


@pytest.mark.parametrize("literal", ["/pattern/", "#/pattern/#", "#/ spaced /#"])
def test_foreground_failure_fails_closed_on_unsupported_interpolation(
    monkeypatch: pytest.MonkeyPatch,
    literal: str,
) -> None:
    expression = rf'"\(String(reflecting: {literal}))"'
    mutant = mutated_view_model(
        _FOREGROUND, ((_ARGUMENT, f"generation: {expression})"),)
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="Unsupported Swift slash syntax"):
        _CATCH_UP()


def test_foreground_failure_does_not_certify_deferred_publication(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    publication = (
        f"backgroundSyncStatus = publishMailboxDeliveryFailure(error, {_ARGUMENT}"
    )
    deferred = f"""defer {{ {publication} }}
            await Task.yield()"""
    mutant = mutated_view_model(_FOREGROUND, ((publication, deferred),))
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="Unsupported deferred"):
        _CATCH_UP()

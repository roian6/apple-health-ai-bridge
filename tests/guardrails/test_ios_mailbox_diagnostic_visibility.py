"""Mutation controls for the Mailbox Activity source guards (not Swift execution)."""

from typing import Final

import pytest

from tests.guardrails import test_ios_mailbox_ack_diagnostics as guards
from tests.guardrails.test_ios_mailbox_publication_order import mutated_view_model

_SUMMARY: Final = "func publishMailboxDeliverySummary("
_FORMATTER: Final = "static func failure("
_PROJECTION: Final = "var activityMailboxFailureMessage:"
_ASSIGNMENT: Final = "unresolved.isEmpty ? [.summary(message)] : unresolved"
_LITERAL: Final = r'"Mailbox ACK diagnostics failed: \(reason)."'
_SHADOW_PREFIX: Final = 'let reason = "phase=" + itemError.phase.diagnosticCode + ": "'


@pytest.mark.parametrize(
    "rhs",
    [
        "[.summary(message)]",
        "failures.isEmpty ? [.summary(message)] : failures",
        "unresolved.isEmpty ? [.summary(message)] : failures",
    ],
    ids=["hide-unresolved", "keep-resolved", "show-resolved-beside-unresolved"],
)
def test_summary_guard_rejects_discarded_filter(
    monkeypatch: pytest.MonkeyPatch, rhs: str
) -> None:
    mutant = mutated_view_model(_SUMMARY, ((_ASSIGNMENT, rhs),))
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="must publish retained failures"):
        guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


@pytest.mark.parametrize(
    "suffix",
    [
        "String(reflecting: error)",
        '"synthetic-private-sentinel"',
        '(itemError?.itemID ?? "")',
    ],
    ids=["reflected-error", "private-sentinel", "item-id"],
)
def test_formatter_guard_rejects_suffix_outside_safe_literal(
    monkeypatch: pytest.MonkeyPatch, suffix: str
) -> None:
    mutant = mutated_view_model(_FORMATTER, ((_LITERAL, f"{_LITERAL} + {suffix}"),))
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="complete sanitized literal"):
        guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


@pytest.mark.parametrize(
    ("opening", "closing"),
    [
        pytest.param("// ", "", id="reviewer-line-comment"),
        pytest.param("/* ", " */", id="block-comment"),
        pytest.param('let _ = #"', '"#', id="raw-string"),
    ],
)
def test_formatter_guard_rejects_active_leak_despite_safe_decoy(
    monkeypatch: pytest.MonkeyPatch, opening: str, closing: str
) -> None:
    constructor = f"return Self(message: {_LITERAL}"
    decoy = f"{opening}{constructor}, failureGeneration:{closing}"
    active = f"{constructor} + String(reflecting: error),"
    mutant = mutated_view_model(
        _FORMATTER, ((f"{constructor},", f"{decoy}\n        {active}"),)
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="complete sanitized literal"):
        guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


def test_formatter_guard_accepts_comments_between_active_argument_tokens(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mutant = mutated_view_model(
        _FORMATTER,
        (
            (_LITERAL, f"{_LITERAL} /* nested /* harmless */ comment */"),
            ("return Self(", "return /* diagnostic constructor */ Self("),
        ),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


def _formatter_with_item_return(
    message: str, *, item_setup: str = ""
) -> tuple[tuple[str, str], ...]:
    prelude = f"{item_setup}\n            " if item_setup else ""
    return (
        (
            f"return Self(message: {_LITERAL},",
            f"""if let itemError {{
            {prelude}return Self(message: {message}, failureGeneration: generation,
                        scope: scope, checkpointWrite: checkpointWrite,
                        itemOwnership: itemError.ownership)
        }}
        return Self(message: {_LITERAL},""",
        ),
    )


def test_formatter_guard_rejects_item_id_return_even_with_safe_fallback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mutant = mutated_view_model(
        _FORMATTER, _formatter_with_item_return(f"{_LITERAL} + itemError.itemID")
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="complete sanitized literal"):
        guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


def test_formatter_guard_accepts_safe_item_and_fallback_returns(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    item_message = r'"Mailbox item acknowledgment failed: \(reason)."'
    safe = mutated_view_model(_FORMATTER, _formatter_with_item_return(item_message))
    monkeypatch.setattr(guards, "VIEW_MODEL", safe)

    guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


@pytest.mark.parametrize(
    "item_setup",
    [
        pytest.param(
            f"{_SHADOW_PREFIX} + String(reflecting: error)",
            id="gate-exact-branch-local-shadow",
        ),
        pytest.param(
            """let originalReason = reason
            let reason = originalReason + String(reflecting: error)""",
            id="alias-then-shadow",
        ),
    ],
)
def test_formatter_guard_rejects_reason_rebinding_in_item_return(
    monkeypatch: pytest.MonkeyPatch, item_setup: str
) -> None:
    mutant = mutated_view_model(
        _FORMATTER, _formatter_with_item_return(_LITERAL, item_setup=item_setup)
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="one immutable, sanitized reason binding"):
        guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


def test_formatter_guard_rejects_reason_reassignment_before_item_return(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    item = _formatter_with_item_return(
        _LITERAL, item_setup="reason += String(reflecting: error)"
    )
    mutant = mutated_view_model(
        _FORMATTER, (("let reason = phase.map", "var reason = phase.map"), *item)
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="one immutable, sanitized reason binding"):
        guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


def test_formatter_guard_ignores_reason_rebinding_lookalikes_in_trivia(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    item_setup = r"""/* let reason = untrusted /* nested reason */ */
            let _ = #"let reason = untrusted; \(reason)"#
            // reason += untrusted"""
    item = _formatter_with_item_return(_LITERAL, item_setup=item_setup)
    mutant = mutated_view_model(
        _FORMATTER,
        (
            ("let reason = phase.map", "let /* approved reason */ reason = phase.map"),
            *item,
        ),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


def test_projection_guard_rejects_showing_failure_for_direct_transport(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mutant = mutated_view_model(_PROJECTION, (("usesMailboxTransport, ", ""),))
    monkeypatch.setattr(guards, "VIEW_MODEL", mutant)

    with pytest.raises(AssertionError, match="current-generation Mailbox failure"):
        guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()


def test_visibility_guard_accepts_renamed_filter_and_safe_copy_edits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    summary = mutated_view_model(
        _SUMMARY,
        (
            ("let unresolved =", "let remaining ="),
            (
                _ASSIGNMENT,
                """remaining.isEmpty
            ? [ .summary(message) ]
            : remaining""",
            ),
        ),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", summary)
    formatter = mutated_view_model(
        _FORMATTER,
        ((_LITERAL, r'"Mailbox acknowledgment unavailable (\(reason))"'),),
    )
    monkeypatch.setattr(guards, "VIEW_MODEL", formatter)

    guards.test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text()

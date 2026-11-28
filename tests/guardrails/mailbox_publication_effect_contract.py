"""Explicit effects permitted while Mailbox publication authority is unproven."""

import re
from collections.abc import Collection, Iterable
from enum import Enum, auto
from typing import Final


class MailboxLane(Enum):
    MANUAL = auto()
    SCHEDULER = auto()
    FOREGROUND = auto()
    BOUNDED = auto()


MAILBOX_DIAGNOSTIC_STORAGE: Final = re.compile(r"\bmailboxDeliveryDiagnosticLines\b")
PUBLICATION: Final = re.compile(
    rf"""
    {MAILBOX_DIAGNOSTIC_STORAGE.pattern}
    | \b(?:publishMailboxDelivery(?:Summary|Failure)|refreshPendingOutboxCount
          |recordAcceptedTransfer|recordNewMailboxFinalization
          |persistMailboxAckScanCheckpoint)\s*\(
    | \b(?:backgroundSyncStatus|statusMessage|statusIsError
          |pendingOutboxCount|hasPublishedMailboxItem)\s*\+?=(?!=)
    """,
    re.VERBOSE,
)
_ADMISSION: Final = "try requireCurrentConnectionGeneration(expectedGeneration)"
_DO_ADMISSION: Final = f"do {{ {_ADMISSION} }}"
_OUTER_PREFIX: Final = {
    MailboxLane.MANUAL: """
        if target.route == .mailbox {
            var finalizedOwner: OutboxDeliveryOwnershipV1?
            defer {
                recordNewMailboxFinalization(
                    finalizedOwner, for: target, outbox: outbox
                )
            }
            do
    """,
    MailboxLane.SCHEDULER: "if settingsStore.activeTransport == .mailbox { do ",
    MailboxLane.FOREGROUND: """
        private func reconcileForegroundMailboxDelivery(
            expectedGeneration: String
        ) async {
            do
    """,
    MailboxLane.BOUNDED: """
        private func reconcileMailboxDeliveryIfNeeded(
            at point: AutomaticSyncMailboxReconciliationPoint
        ) async -> AutomaticSyncMailboxReconciliationResult {
            guard let requestedPhase =
                AutomaticSyncBackgroundOpportunityPolicy.deliveryPhase(
                    usesMailboxTransport: settingsStore.activeTransport == .mailbox,
                    at: point
                ) else { return .completed(pendingCount: pendingOutboxCount) }
            let expectedGeneration = settingsStore.receiverSettingsGenerationToken
            let acceptanceTarget = try? capturePayloadDeliveryTarget()
            let deliveryOutbox = outbox
            var finalizedOwner: OutboxDeliveryOwnershipV1?
            defer {
                recordNewMailboxFinalization(
                    finalizedOwner, for: acceptanceTarget, outbox: deliveryOutbox
                )
            }
            var operation: MailboxDeliveryOperation = requestedPhase == .publishFIFOHead
                ? .publishFIFOHead : .selectFIFOHeadPhase
            var completedOperations: Set<MailboxDeliveryOperation> = []
            do
    """,
}
# These reviewed statements prepare transport results or mutate only local
# progress. Match the entire statement, including arguments and switch bodies.
_DELIVERY_PREFIX: Final = {
    MailboxLane.MANUAL: (
        """
        let summary = try await makeProductionMailboxDelivery().deliverPending {
            finalizedOwner = $0
        }
        """,
    ),
    MailboxLane.SCHEDULER: (
        _ADMISSION,
        """
        let summary = try await makeProductionMailboxDelivery()
            .publishPendingFIFOHeadWithOwnership()
        """,
    ),
    MailboxLane.FOREGROUND: (
        _ADMISSION,
        """
        let result = await reconcileMailboxDeliveryIfNeeded(
            at: .beforePayloadGeneration
        )
        """,
    ),
    MailboxLane.BOUNDED: (
        "try Task.checkCancellation()",
        _ADMISSION,
        "let delivery = try makeProductionMailboxDelivery()",
        """
        let startingCheckpoint = backgroundSyncStore.mailboxAckScanCheckpoint(
            receiverGeneration: expectedGeneration
        )
        """,
        "let summary: ProductionMailboxBackgroundDeliverySummary",
        """
        switch requestedPhase {
        case .publishFIFOHead:
            summary = try await delivery.publishPendingFIFOHeadWithOwnership()
        case .advanceOrReconcileFIFOHead:
            let pendingPhase = try await delivery.pendingFIFOHeadBackgroundPhase()
            completedOperations.insert(.selectFIFOHeadPhase)
            switch pendingPhase {
            case .reconcileFIFOHeadAcknowledgment:
                operation = .reconcileFIFOHeadAcknowledgment
                summary = try await delivery.reconcilePendingFIFOHeadAcknowledgment(
                    afterAcknowledgmentCheckpoint: startingCheckpoint
                ) { finalizedOwner = $0 }
            case .none, .publishFIFOHead:
                operation = .publishFIFOHead
                summary = try await delivery.publishPendingFIFOHeadWithOwnership()
            }
        }
        """,
    ),
}
BOUNDED_OPERATION_CREDIT_PREFIX: Final = "\n".join(
    (
        *_DELIVERY_PREFIX[MailboxLane.BOUNDED],
        _ADMISSION,
        "completedOperations.insert(operation)",
    )
)
_AFTER_YIELD: Final = (
    "await Task.yield()",
    "return",
    "return .cancelled",
    "return .failed",
    "throw error",
    """
    return (summary: flushSummary, lastDirectUploadResult: nil,
            acceptedDirectItemIDs: [])
    """,
    """
    return summary.terminalCount > 0
        ? .terminalHold(pendingCount: pendingOutboxCount)
        : .completed(pendingCount: pendingOutboxCount)
    """,
)
_TOKEN: Final = re.compile(r"\w+|[^\s]")
_LOCAL: Final = (
    r"let (?P<name>[A-Za-z_]\w*)(?: : (?:String|Set < MailboxDeliveryOperation >))? ="
)
_LOCAL_AWAIT: Final = (
    r"await MainActor \. run \{ (?:expectedGeneration|"
    r"\[ \. (?:manualDelivery|publishFIFOHead) \]) \}"
)
_PURE_LOCAL: Final = re.compile(rf"{_LOCAL} {_LOCAL_AWAIT}")
_STRING_LOCAL: Final = re.compile(rf'{_LOCAL} "')
AWAIT: Final = re.compile(r"\bawait\b")
_DEFERRED_EXECUTION: Final = re.compile(r"\b(?:defer|async\s+let)\b")


def swift_tokens(source: str) -> str:
    return " ".join(_TOKEN.findall(source))


def _is_pure_local(structure: str, executable: str) -> bool:
    shaped, evaluated = swift_tokens(structure), swift_tokens(executable)
    if shaped == evaluated:
        declaration = _PURE_LOCAL.fullmatch(shaped)
    else:
        declaration = _STRING_LOCAL.fullmatch(shaped)
        if not _PURE_LOCAL.fullmatch(evaluated):
            return False
    return declaration is not None and declaration["name"] not in {
        "expectedGeneration",
        "target",
    }


def assert_checked_outer_prefix(source: str, lane: MailboxLane) -> None:
    assert swift_tokens(source) == swift_tokens(_OUTER_PREFIX[lane]), (
        "Unsupported Swift before Mailbox authority: delivery branch admission"
    )


def _assert_checked_prefence_statements(
    statements: Iterable[tuple[str, str]], lane: MailboxLane | None
) -> None:
    reviewed = iter(_DELIVERY_PREFIX[lane] if lane is not None else ())
    expected = next(reviewed, None)
    unsupported = (
        "Unsupported Swift before Mailbox authority: "
        "Mailbox publication must follow the checked transport prefix"
    )
    for structure, executable in statements:
        actual = swift_tokens(structure)
        if expected == _ADMISSION and actual == swift_tokens(_DO_ADMISSION):
            actual = swift_tokens(_ADMISSION)
        if expected is not None and actual == swift_tokens(expected):
            expected = next(reviewed, None)
        else:
            assert expected is None, unsupported
            assert _is_pure_local(structure, executable), unsupported
    assert expected is None, "Expected reviewed Mailbox delivery before authority check"


def _accepts_after_suspension(structure: str, executable: str) -> bool:
    tokens = swift_tokens(structure)
    return _is_pure_local(structure, executable) or (
        tokens == swift_tokens(executable)
        and any(tokens == swift_tokens(statement) for statement in _AFTER_YIELD)
    )


def _assert_checked_suspensions(statements: Iterable[tuple[str, str, bool]]) -> None:
    """An unverified window may only contain explicitly inert statements."""
    suspended = False
    for structure, executable, is_fence in statements:
        assert not _DEFERRED_EXECUTION.search(executable), (
            "Unsupported deferred Swift in Mailbox publication"
        )
        if is_fence:
            suspended = False
        elif suspended or AWAIT.search(executable):
            assert _accepts_after_suspension(structure, executable), (
                "Unsupported Swift after Mailbox suspension without fresh authority"
            )
            suspended = True


def assert_effect_windows(
    structure: str,
    executable: str,
    statements: Iterable[tuple[int, int]],
    fences: Collection[int],
    lane: MailboxLane | None,
) -> None:
    first = min(fences)
    views = tuple(
        (start, structure[start:end], executable[start:end])
        for start, end in statements
    )
    _assert_checked_prefence_statements(
        ((shape, code) for start, shape, code in views if start < first), lane
    )
    _assert_checked_suspensions(
        (shape, code, start in fences) for start, shape, code in views if start > first
    )

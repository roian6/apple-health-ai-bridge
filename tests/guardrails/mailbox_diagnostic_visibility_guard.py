"""Source contracts for the reviewed Swift Mailbox Activity diagnostics."""

import re

from tests.guardrails.mailbox_publication_guard import SwiftLexer, swift_block_end


def assert_mailbox_summary_visibility(summary: str) -> None:
    """Tie each scope predicate to the value actually published to Activity."""
    structure = SwiftLexer(summary).views().structure
    opening = structure.index("{")
    body = structure[opening + 1 : swift_block_end(structure, opening)]
    assert re.fullmatch(
        r"""
        \s*let\s+failures\s*=\s*currentMailboxDeliveryFailures
        \s*let\s+recovered\s*=\s*recoveredMailboxFailureIDs\(\s*failures\s*\)
        \s*let\s+(?P<retained>\w+)\s*=\s*failures\.filter\s*\{\s*diagnostic\s+in
            \s*switch\s+diagnostic\.scope\s*\{
                \s*case\s+\.item\(let\s+itemID\)\s*:
                    \s*if\s+diagnostic\.itemOwnership\s*!=\s*nil\s*\{
                        \s*return\s+!recovered\.contains\(itemID\)\s*
                    \}
                    \s*return\s+!finalizedItemIDs\.contains\(itemID\)
                \s*case\s+\.operation\(let\s+operation\)\s*:
                    \s*return\s+!completedOperations\.contains\(operation\)
                \s*case\s+\.unattributed\s*,\s*nil\s*:
                    \s*return\s+true\s*
            \}\s*
        \}
        \s*mailboxDeliveryDiagnosticLines\s*=\s*(?P=retained)\.isEmpty\s*
        \?\s*\[\s*\.summary\(\s*message\s*\)\s*\]\s*:\s*(?P=retained)\s*
        """,
        body,
        re.VERBOSE,
    ), "Mailbox summary must publish retained failures, or a summary only when empty"


def assert_mailbox_failure_message(formatter: str) -> None:
    """Require a closed literal sourced only from a phase code or fixed fallback."""
    lexer = SwiftLexer(formatter)
    views = lexer.views()
    # The structural view blanks comments and string contents at stable offsets.
    # Recover only the literals used directly by the active expressions.
    literals = {start: formatter[start:end] for start, end in lexer.literals}
    literal_text = r'[^"\\\n]*'
    reason = re.match(
        r"""
        \s*static\s+func\s+failure\s*\([^{}]*\)\s*->\s*Self\s*\{
        \s*let\s+itemError\s*=\s*error\s+as\?\s*ProductionMailboxItemDeliveryError
        \s*let\s+checkpointWrite\s*=\s*error\s+as\?\s*MailboxAckCheckpointWrite
        \s*let\s+phase\s*=\s*itemError\s*\?\.\s*phase\s*\?\?\s*
        \(\s*error\s+as\?\s*ProductionMailboxDeliveryPhaseError\s*\)
        \s*let\s+(?P<binding>reason)\s*=\s*phase\s*\.\s*map\s*
        \{\s*(?P<phase>")\s*\}\s*\?\?\s*(?P<fallback>")\s*
        let\s+scope\s*:
        """,
        views.structure,
        re.VERBOSE,
    )
    bad_reason = "Mailbox failure needs one immutable, sanitized reason binding"
    assert reason is not None, bad_reason
    assert re.fullmatch(
        rf'"{literal_text}\\\(\$0\.diagnosticCode\){literal_text}"',
        literals[reason.start("phase")],
    ), bad_reason
    assert re.fullmatch(rf'"{literal_text}"', literals[reason.start("fallback")]), (
        bad_reason
    )

    # Item IDs are matching metadata. Match through the argument delimiter so
    # neither raw errors nor strings concatenated after the literal can reach UI.
    bad_message = "Mailbox failure message must be the complete sanitized literal"
    returns = list(re.finditer(r"\breturn\b", views.structure))
    assert returns, bad_message
    assert reason.end() < returns[0].start(), bad_reason
    constructor = re.compile(
        r"""
        \breturn\s+Self\s*\(\s*message\s*:\s*(?P<literal>")\s*,
        \s*failureGeneration\s*:
        """,
        re.VERBOSE,
    )
    approved_uses = {reason.start("binding")}
    for exit_match in returns:
        message = constructor.match(views.structure, exit_match.start())
        assert message is not None, bad_message
        start = message.start("literal")
        assert re.fullmatch(
            rf'"{literal_text}\\\(reason\){literal_text}"',
            literals[start],
        ), bad_message
        approved_uses.add(start + literals[start].index(r"\(reason)") + len(r"\("))

    # Only the outer declaration and verified return interpolations may use
    # this name. The executable view keeps interpolation code, but not trivia.
    assert {
        name.start() for name in re.finditer(r"\breason\b", views.executable)
    } == approved_uses, bad_reason


def assert_mailbox_failure_projection(projection: str) -> None:
    assert re.fullmatch(
        r"""
        var\s+activityMailboxFailureMessage:\s*String\?\s*\{
        \s*guard\s+usesMailboxTransport\s*,\s*
        let\s+diagnostic\s*=\s*mailboxDeliveryDiagnosticLines\.last\s*,\s*
        diagnostic\.failureGeneration\s*==\s*settingsStore\.receiverSettingsGenerationToken
        \s*else\s*\{\s*return\s+nil\s*\}
        \s*return\s+diagnostic\.message\s*
        \}\s*
        """,
        projection,
        re.VERBOSE,
    ), "Activity must expose only the current-generation Mailbox failure message"

"""Source guard for the companion's straight-line Mailbox authority fences."""

import re
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from typing import Final

from tests.guardrails.mailbox_publication_effect_contract import (
    AWAIT,
    MAILBOX_DIAGNOSTIC_STORAGE,
    PUBLICATION,
    MailboxLane,
    assert_checked_outer_prefix,
    assert_effect_windows,
)

_LEXEME: Final = re.compile(r'//[^\n]*|/\*|\#*"{3}|\#*"|[/()]')
_COMMENT_EDGE: Final = re.compile(r"/\*|\*/")
_DELIMITER: Final = re.compile(r"[][(){};\n]")
_OPEN: Final = {"(": ")", "[": "]", "{": "}"}
_CLOSE: Final = frozenset(_OPEN.values())
_CONTINUED_FROM: Final = re.compile(
    r"[=,?:.+*/%&|<>^~-]$|\b(?:try|await|throw|return)$"
)
_CONTINUED_TO: Final = re.compile(
    r"\s*(?:[.?+:*/%&|<>=!~^({\[-]|(?:catch|else|as|is)\b)"
)
_BRACE: Final = re.compile(r"[{}]")

CONNECTION_FENCE: Final = (
    r"try\s+requireCurrentConnectionGeneration\s*\(\s*expectedGeneration\s*\)"
)
TARGET_FENCE: Final = r"try\s+requireCurrentPayloadDeliveryTarget\s*\(\s*target\s*\)"


@dataclass(frozen=True, slots=True)
class _SwiftViews:
    structure: str
    executable: str


class SwiftLexer:
    """Mask trivia, retaining code in interpolation and preserving offsets."""

    def __init__(self, source: str) -> None:
        self.source: str = source
        self.executable: list[str] = list(source)
        self.literals: list[tuple[int, int]] = []

    def views(self) -> _SwiftViews:
        _ = self._walk(0)
        structure = self.executable.copy()
        for start, end in self.literals:
            structure[start:end] = '"' + " " * (end - start - 1)
        return _SwiftViews("".join(structure), "".join(self.executable))

    def _walk(self, start: int, *, interpolation: bool = False) -> int:
        depth = int(interpolation)
        offset = start
        while (token := _LEXEME.search(self.source, offset)) is not None:
            offset = token.end()
            lexeme = token[0]
            if lexeme.startswith("//"):
                self.executable[token.start() : offset] = " " * len(lexeme)
            elif lexeme == "/*":
                offset = _matching_edge(
                    _COMMENT_EDGE.finditer(self.source, offset), "/*"
                ).end()
                self.executable[token.start() : offset] = [
                    "\n" if char == "\n" else " "
                    for char in self.source[token.start() : offset]
                ]
            elif lexeme.endswith('"'):
                offset = self._string(token)
                self.literals.append((token.start(), offset))
            else:
                # Slash may open a regex literal; this guard does not parse it.
                assert lexeme != "/", "Unsupported Swift slash syntax in Mailbox branch"
                if interpolation:
                    depth += 1 if lexeme == "(" else -1
                    if depth == 0:
                        return offset
        assert not interpolation, "Unterminated Swift string interpolation"
        return len(self.source)

    def _string(self, opening: re.Match[str]) -> int:
        hashes = opening[0].rstrip('"')
        closer = opening[0].lstrip("#") + hashes
        escape = "\\" + hashes
        offset = opening.end()
        literal_start = opening.start()
        while offset < len(self.source):
            if self.source.startswith(closer, offset):
                end = offset + len(closer)
                self.executable[literal_start:end] = " " * (end - literal_start)
                return end
            if self.source.startswith(escape, offset):
                after_escape = offset + len(escape)
                if self.source.startswith("(", after_escape):
                    self.executable[literal_start : after_escape + 1] = " " * (
                        after_escape + 1 - literal_start
                    )
                    offset = self._walk(after_escape + 1, interpolation=True)
                    literal_start = offset - 1
                    continue
                offset = after_escape
            offset += 1
        msg = "Unterminated Swift string in Mailbox branch"
        raise AssertionError(msg)


def _statement_end(structure: str, start: int) -> int:
    """Bound the complete expression at this position, not just its first token."""
    expected: list[str] = []
    for token in _DELIMITER.finditer(structure, start):
        char = token[0]
        if char in _OPEN:
            expected.append(_OPEN[char])
        elif char in _CLOSE:
            if not expected:
                return token.start()
            assert expected.pop() == char, "Mismatched Swift delimiters"
        elif not expected:
            if char == ";":
                return token.start()
            before = structure[start : token.start()].rstrip()
            if not (
                _CONTINUED_FROM.search(before)
                or _CONTINUED_TO.match(structure, token.end())
            ):
                return token.start()
    assert not expected, "Unterminated Swift expression in Mailbox branch"
    return len(structure)


def _statements(structure: str) -> Iterator[tuple[int, int]]:
    cursor = 0
    nontrivia = re.compile(r"[^\s;]")
    while (start := nontrivia.search(structure, cursor)) is not None:
        end = _statement_end(structure, start.start())
        assert end > start.start(), "Unexpected delimiter in Mailbox branch"
        yield start.start(), end
        cursor = end + 1


def _assert_inline_effect(statement: str, effect: int) -> None:
    # Only ordinary immediate control-flow blocks can contain a known effect.
    # A closure or defer can run after the checked straight-line path has left.
    header_start = brace = 0
    expected: list[str] = []
    for token in _DELIMITER.finditer(statement, 0, effect):
        char = token[0]
        if char in _OPEN:
            if not expected:
                brace = token.start()
            expected.append(_OPEN[char])
        elif char in _CLOSE:
            assert expected, "Unexpected Swift closing delimiter"
            assert expected.pop() == char, "Unexpected Swift delimiter"
            if not expected and char == "}":
                header_start = token.end()
    if "}" in expected:
        assert expected[0] == "}", "Unsupported closure-scoped Mailbox publication"
        header = statement[header_start:brace]
        assert re.match(r"\s*(?:if|else|do|catch|switch)\b", header), (
            "Unsupported deferred or closure-scoped Mailbox publication"
        )
        nested = statement[brace + 1 :]
        inner_start, inner_end = next(
            (start, end)
            for start, end in _statements(nested)
            if start <= effect - brace - 1 < end
        )
        _assert_inline_effect(
            nested[inner_start:inner_end], effect - brace - 1 - inner_start
        )


def swift_block_end(structure: str, opening: int) -> int:
    assert structure[opening] == "{"
    return _matching_edge(_BRACE.finditer(structure, opening + 1), "{").start()


def _matching_edge(edges: Iterable[re.Match[str]], opener: str) -> re.Match[str]:
    depth = 1
    for edge in edges:
        depth += 1 if edge[0] == opener else -1
        if depth == 0:
            return edge
    msg = f"Unterminated Swift lexical scope: {opener}"
    raise AssertionError(msg)


def mailbox_branch_body(branch: _SwiftViews, lane: MailboxLane | None) -> _SwiftViews:
    structure = branch.structure
    if lane is None:
        opening = re.match(r"\s*\}\s*catch\s*(\{)", structure)
        assert opening is not None, "Expected the Mailbox failure catch"
        start = opening.start(1)
        end = swift_block_end(structure, start)
    else:
        end = len(structure.rstrip()) - 1
        assert structure[end] == "}", "Expected the Mailbox delivery do block"
        preceding_braces = reversed(list(_BRACE.finditer(structure, 0, end)))
        start = _matching_edge(preceding_braces, "}").start()
        assert_checked_outer_prefix(structure[:start], lane)
    assert re.fullmatch(r"\s*(?:return\s+)?\}?\s*", structure[end + 1 :]), (
        "Unsupported Swift outside the checked Mailbox branch"
    )
    return _SwiftViews(structure[start + 1 : end], branch.executable[start + 1 : end])


def _assert_publication_order(
    body: _SwiftViews,
    fence: str,
    after: int,
    *,
    lane: MailboxLane | None,
    publication_required: bool,
) -> None:
    assert not re.search(r"[#`]", body.executable), (
        "Unsupported Swift directive or escaped identifier in Mailbox branch"
    )
    effects = list(PUBLICATION.finditer(body.executable))
    if publication_required:
        assert effects, "Expected a Mailbox diagnostic or status publication"
    statements = tuple(_statements(body.structure))
    checks = {
        start: end
        for start, end in statements
        if after < start and re.fullmatch(fence, body.structure[start:end].strip())
    }
    missing_check = "Mailbox publication must follow an unconditional authority check"
    assert checks, missing_check
    for effect in effects:
        preceding_check = max(
            (end for end in checks.values() if end <= effect.start()), default=-1
        )
        assert preceding_check >= 0, missing_check
        assert not body.structure[effect.start() : effect.end()].isspace(), (
            "Unsupported Mailbox publication inside a string interpolation"
        )
        start, stop = next(
            (start, stop)
            for start, stop in statements
            if start <= effect.start() < stop
        )
        _assert_inline_effect(body.structure[start:stop], effect.start() - start)
        end = _statement_end(body.structure, effect.start())
        assert not AWAIT.search(body.executable, preceding_check, end), (
            "Mailbox publication must not suspend again after checking authority"
        )
    assert_effect_windows(body.structure, body.executable, statements, checks, lane)
    # The checked transport branches should not bypass the scoped publishers.
    # A read-only projection belongs outside these branches.
    assert not MAILBOX_DIAGNOSTIC_STORAGE.search(body.executable), (
        "Write diagnostics only through scoped Mailbox publishers"
    )
    for start, end in statements:
        if start > min(checks) and not AWAIT.search(body.executable, start, end):
            statement = body.structure[start:end]
            for block in re.finditer(r"\{\s*(?=[^}\s])", statement):
                _assert_inline_effect(statement, block.end())


def assert_successful_mailbox_publication(
    branch: str,
    fence: str,
    delivery: str,
    lane: MailboxLane,
    *,
    publication_required: bool = True,
) -> None:
    body = mailbox_branch_body(SwiftLexer(branch).views(), lane)
    _assert_publication_order(
        body,
        fence,
        body.structure.index(delivery),
        lane=lane,
        publication_required=publication_required,
    )


def assert_failed_mailbox_publication(
    branch: str, fence: str, *, stale_return: str | None = None
) -> None:
    if stale_return is not None:
        return_statement = re.escape(f"return {stale_return}".rstrip())
        fence = rf"do\s*\{{\s*{fence}\s*\}}\s*catch\s*\{{\s*{return_statement}\s*\}}"
    body = mailbox_branch_body(SwiftLexer(branch).views(), None)
    _assert_publication_order(body, fence, -1, lane=None, publication_required=True)

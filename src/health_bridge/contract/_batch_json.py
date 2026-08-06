from __future__ import annotations

import re
from typing import ClassVar, Final, final

_NUMBER_PATTERN: Final = re.compile(
    r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"
)
_HEX_PATTERN: Final = re.compile(r"^[0-9A-Fa-f]{4}$")
_WHITESPACE: Final = frozenset(" \t\r\n")
_ESCAPES: Final = {
    '"': '"',
    "\\": "\\",
    "/": "/",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
}
_CONTROL_LIMIT: Final = 0x20
_HIGH_SURROGATE_MIN: Final = 0xD800
_HIGH_SURROGATE_MAX: Final = 0xDBFF
_LOW_SURROGATE_MIN: Final = 0xDC00
_LOW_SURROGATE_MAX: Final = 0xDFFF
_SUPPLEMENTARY_OFFSET: Final = 0x10000
_SURROGATE_SHIFT: Final = 10
_UNICODE_ESCAPE_DIGITS: Final = 4


class BatchJsonError(Exception):
    pass


@final
class _Scanner:
    __slots__: ClassVar[tuple[str, str]] = ("index", "text")

    text: str
    index: int

    def __init__(self, text: str) -> None:
        self.text = text
        self.index = 0

    def scan(self) -> None:
        self._whitespace()
        self._value()
        self._whitespace()
        if self.index != len(self.text):
            raise BatchJsonError

    def _value(self) -> None:
        if self.index >= len(self.text):
            raise BatchJsonError
        character = self.text[self.index]
        if character == "{":
            self._object()
            return
        if character == "[":
            self._array()
            return
        if character == '"':
            _ = self._string()
            return
        for literal in ("true", "false", "null"):
            if self.text.startswith(literal, self.index):
                self.index += len(literal)
                return
        match = _NUMBER_PATTERN.match(self.text, self.index)
        if match is None:
            raise BatchJsonError
        self.index = match.end()

    def _object(self) -> None:
        self.index += 1
        self._whitespace()
        keys: set[str] = set()
        if self._consume("}"):
            return
        while True:
            if not self._at('"'):
                raise BatchJsonError
            key = self._string()
            if key in keys:
                raise BatchJsonError
            keys.add(key)
            self._whitespace()
            self._expect(":")
            self._whitespace()
            self._value()
            self._whitespace()
            if self._consume("}"):
                return
            self._expect(",")
            self._whitespace()

    def _array(self) -> None:
        self.index += 1
        self._whitespace()
        if self._consume("]"):
            return
        while True:
            self._value()
            self._whitespace()
            if self._consume("]"):
                return
            self._expect(",")
            self._whitespace()

    def _string(self) -> str:
        self.index += 1
        result: list[str] = []
        while self.index < len(self.text):
            character = self.text[self.index]
            self.index += 1
            if character == '"':
                return "".join(result)
            if ord(character) < _CONTROL_LIMIT:
                raise BatchJsonError
            if character != "\\":
                result.append(character)
                continue
            result.append(self._escape())
        raise BatchJsonError

    def _escape(self) -> str:
        if self.index >= len(self.text):
            raise BatchJsonError
        escape = self.text[self.index]
        self.index += 1
        if escape in _ESCAPES:
            return _ESCAPES[escape]
        if escape != "u":
            raise BatchJsonError
        codepoint = self._unicode_escape()
        if _HIGH_SURROGATE_MIN <= codepoint <= _HIGH_SURROGATE_MAX:
            if not self.text.startswith("\\u", self.index):
                raise BatchJsonError
            self.index += 2
            low = self._unicode_escape()
            if not _LOW_SURROGATE_MIN <= low <= _LOW_SURROGATE_MAX:
                raise BatchJsonError
            codepoint = (
                _SUPPLEMENTARY_OFFSET
                + ((codepoint - _HIGH_SURROGATE_MIN) << _SURROGATE_SHIFT)
                + (low - _LOW_SURROGATE_MIN)
            )
        elif _LOW_SURROGATE_MIN <= codepoint <= _LOW_SURROGATE_MAX:
            raise BatchJsonError
        return chr(codepoint)

    def _unicode_escape(self) -> int:
        digits = self.text[self.index : self.index + _UNICODE_ESCAPE_DIGITS]
        if (
            len(digits) != _UNICODE_ESCAPE_DIGITS
            or _HEX_PATTERN.fullmatch(digits) is None
        ):
            raise BatchJsonError
        self.index += _UNICODE_ESCAPE_DIGITS
        return int(digits, 16)

    def _whitespace(self) -> None:
        while self.index < len(self.text) and self.text[self.index] in _WHITESPACE:
            self.index += 1

    def _at(self, expected: str) -> bool:
        return self.index < len(self.text) and self.text[self.index] == expected

    def _consume(self, expected: str) -> bool:
        if self._at(expected):
            self.index += 1
            return True
        return False

    def _expect(self, expected: str) -> None:
        if not self._consume(expected):
            raise BatchJsonError


def validate_batch_json(text: str) -> None:
    _Scanner(text).scan()

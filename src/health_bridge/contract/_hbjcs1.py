from __future__ import annotations

import re
from typing import ClassVar, Final, TypeAlias, final

JsonValue: TypeAlias = (
    str | int | float | bool | bytes | None | list["JsonValue"] | dict[str, "JsonValue"]
)

_KEY_PATTERN: Final = re.compile(r"^[a-z][a-z0-9_]*$")
_INTEGER_PATTERN: Final = re.compile(r"-?(?:0|[1-9][0-9]*)")
_WHITESPACE: Final = frozenset(" \t\r\n")
_CONTROL_LIMIT: Final = 0x20
_SURROGATE_MIN: Final = 0xD800
_SURROGATE_MAX: Final = 0xDFFF


class HBJCS1Error(Exception):
    """A value or byte string is outside the HBJCS1 profile."""

    reason: str

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(reason)


def _encode_string(value: str) -> bytes:
    parts: list[str] = ['"']
    for character in value:
        codepoint = ord(character)
        if character == '"':
            parts.append('\\"')
        elif character == "\\":
            parts.append("\\\\")
        elif codepoint < _CONTROL_LIMIT:
            parts.append(f"\\u00{codepoint:02x}")
        elif _SURROGATE_MIN <= codepoint <= _SURROGATE_MAX:
            raise HBJCS1Error(reason="surrogate code points are not valid UTF-8")
        else:
            parts.append(character)
    parts.append('"')
    return "".join(parts).encode("utf-8")


def hbjcs1_encode(value: JsonValue) -> bytes:
    """Encode a typed value with the integer-only HBJCS1 profile."""
    if value is None:
        return b"null"
    if isinstance(value, bool):
        return b"true" if value else b"false"
    if isinstance(value, int):
        if not -(2**63) <= value <= 2**63 - 1:
            raise HBJCS1Error(reason="integer is outside the signed 64-bit range")
        return str(value).encode("ascii")
    if isinstance(value, float):
        raise HBJCS1Error(reason="floating-point values are forbidden")
    if isinstance(value, bytes):
        raise HBJCS1Error(reason="binary values must be base64url strings")
    if isinstance(value, str):
        return _encode_string(value)
    return _encode_container(value)


def _encode_container(value: list[JsonValue] | dict[str, JsonValue]) -> bytes:
    try:
        if isinstance(value, list):
            return b"[" + b",".join(hbjcs1_encode(item) for item in value) + b"]"
        for key in value:
            if _KEY_PATTERN.fullmatch(key) is None:
                raise HBJCS1Error(reason="object key is not lower ASCII snake_case")
        entries = (
            _encode_string(key) + b":" + hbjcs1_encode(value[key])
            for key in sorted(value, key=lambda item: item.encode("utf-8"))
        )
        return b"{" + b",".join(entries) + b"}"
    except RecursionError as exc:
        raise HBJCS1Error(reason="metadata nesting exceeds supported depth") from exc


@final
class _Parser:
    __slots__: ClassVar[tuple[str, str]] = ("index", "text")

    text: str
    index: int

    def __init__(self, text: str) -> None:
        self.text = text
        self.index = 0

    def parse(self) -> JsonValue:
        value = self._value()
        if self.index != len(self.text):
            raise HBJCS1Error(reason="trailing metadata bytes")
        return value

    def _value(self) -> JsonValue:
        if self.index >= len(self.text):
            raise HBJCS1Error(reason="unexpected end of metadata")
        character = self.text[self.index]
        if character in _WHITESPACE:
            raise HBJCS1Error(reason="metadata whitespace is forbidden")
        if character in {'"', "{", "["}:
            return self._structure(character)
        if character == "t" and self.text.startswith("true", self.index):
            self.index += 4
            return True
        if character == "f" and self.text.startswith("false", self.index):
            self.index += 5
            return False
        if character == "n" and self.text.startswith("null", self.index):
            self.index += 4
            return None
        match = _INTEGER_PATTERN.match(self.text, self.index)
        if match is None:
            raise HBJCS1Error(reason="unsupported metadata token")
        self.index = match.end()
        integer = int(match.group())
        if not -(2**63) <= integer <= 2**63 - 1:
            raise HBJCS1Error(reason="integer is outside the signed 64-bit range")
        return integer

    def _structure(self, character: str) -> JsonValue:
        if character == '"':
            return self._string()
        if character == "{":
            return self._object()
        return self._array()

    def _string(self) -> str:
        self.index += 1
        result: list[str] = []
        while self.index < len(self.text):
            character = self.text[self.index]
            self.index += 1
            if character == '"':
                return "".join(result)
            if character == "\\":
                result.append(self._escape())
            elif ord(character) < _CONTROL_LIMIT:
                raise HBJCS1Error(reason="unescaped control character")
            else:
                result.append(character)
        raise HBJCS1Error(reason="unterminated metadata string")

    def _escape(self) -> str:
        if self.index >= len(self.text):
            raise HBJCS1Error(reason="unterminated metadata escape")
        escape = self.text[self.index]
        self.index += 1
        if escape == '"':
            return '"'
        if escape == "\\":
            return "\\"
        if escape != "u" or self.index + 4 > len(self.text):
            raise HBJCS1Error(reason="alternate string escape is forbidden")
        digits = self.text[self.index : self.index + 4]
        self.index += 4
        if not digits.startswith("00") or digits != digits.lower():
            raise HBJCS1Error(reason="noncanonical unicode escape")
        try:
            codepoint = int(digits, 16)
        except ValueError as exc:
            raise HBJCS1Error(reason="invalid unicode escape") from exc
        if codepoint >= _CONTROL_LIMIT:
            raise HBJCS1Error(reason="unnecessary unicode escape")
        return chr(codepoint)

    def _object(self) -> dict[str, JsonValue]:
        self.index += 1
        result: dict[str, JsonValue] = {}
        if self._consume("}"):
            return result
        while True:
            key = self._string()
            if _KEY_PATTERN.fullmatch(key) is None or key in result:
                raise HBJCS1Error(reason="invalid or duplicate object key")
            self._expect(":")
            result[key] = self._value()
            if self._consume("}"):
                return result
            self._expect(",")

    def _array(self) -> list[JsonValue]:
        self.index += 1
        result: list[JsonValue] = []
        if self._consume("]"):
            return result
        while True:
            result.append(self._value())
            if self._consume("]"):
                return result
            self._expect(",")

    def _consume(self, expected: str) -> bool:
        if self.index < len(self.text) and self.text[self.index] == expected:
            self.index += 1
            return True
        return False

    def _expect(self, expected: str) -> None:
        if not self._consume(expected):
            raise HBJCS1Error(reason=f"expected {expected!r}")


def hbjcs1_decode(encoded: bytes) -> JsonValue:
    """Parse canonical HBJCS1 bytes, rejecting alternate encodings."""
    try:
        text = encoded.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise HBJCS1Error(reason="metadata is not UTF-8") from exc
    try:
        parsed = _Parser(text=text).parse()
        if hbjcs1_encode(parsed) != encoded:
            raise HBJCS1Error(reason="metadata bytes are not canonical")
    except RecursionError as exc:
        raise HBJCS1Error(reason="metadata nesting exceeds supported depth") from exc
    return parsed

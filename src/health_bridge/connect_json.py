import json
import re
from dataclasses import dataclass

from pydantic import JsonValue, TypeAdapter

_TOKENS = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|[^\s]', re.DOTALL)
_OBJECT = TypeAdapter(dict[str, JsonValue])


def unique_pairs(pairs: list[tuple[str, JsonValue]]) -> dict[str, JsonValue]:
    result: dict[str, JsonValue] = {}
    for key, value in pairs:
        if key in result:
            message = "Duplicate JSON key; configuration was retained."
            raise ValueError(message)
        result[key] = value
    return result


@dataclass(frozen=True, slots=True)
class Token:
    value: str
    start: int
    end: int


def tokens(text: str) -> list[Token]:
    return [
        Token(m.group(), m.start(), m.end())
        for m in _TOKENS.finditer(text)
        if not m.group().startswith(("//", "/*"))
    ]


def read_json(text: str) -> dict[str, JsonValue]:
    parts = tokens(text)
    clean = "".join(
        t.value
        for i, t in enumerate(parts)
        if not (
            t.value == "," and i + 1 < len(parts) and parts[i + 1].value in {"}", "]"}
        )
    )
    return _OBJECT.validate_python(json.loads(clean, object_pairs_hook=unique_pairs))


def insert_json(text: str, keys: tuple[str, ...], value: JsonValue) -> str:
    parts = tokens(text)
    start = 0
    for key in keys[:-1]:
        depth = 0
        found = None
        for i in range(start + 1, len(parts)):
            token = parts[i]
            if (
                depth == 0
                and token.value.startswith('"')
                and json.loads(token.value) == key
                and parts[i + 1].value == ":"
            ):
                found = i + 2
                break
            if token.value in {"{", "["}:
                depth += 1
            elif token.value in {"}", "]"}:
                if depth == 0:
                    break
                depth -= 1
        if found is None:
            nested: JsonValue = value
            for name in reversed(keys[keys.index(key) + 1 :]):
                nested = {name: nested}
            return insert_json(text, (*keys[: keys.index(key)], key), nested)
        if parts[found].value != "{":
            message = "MCP configuration container is not an object."
            raise ValueError(message)
        start = found
    position = parts[start].end
    suffix = "" if parts[start + 1].value == "}" else ","
    entry = json.dumps(keys[-1]) + ": " + json.dumps(value, ensure_ascii=False)
    return text[:position] + "\n" + entry + suffix + "\n" + text[position:]

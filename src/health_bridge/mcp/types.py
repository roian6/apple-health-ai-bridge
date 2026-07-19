from collections.abc import Mapping
from typing import TypeAlias, final

JsonValue: TypeAlias = (
    None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
)
JsonObject: TypeAlias = dict[str, JsonValue]
JsonMapping: TypeAlias = Mapping[str, JsonValue]


@final
class JsonShapeError(TypeError):
    expected: str

    def __init__(self, expected: str) -> None:
        self.expected = expected
        super().__init__(f"expected {expected}")


def required_object(value: JsonValue) -> JsonObject:
    if isinstance(value, dict):
        return value
    raise JsonShapeError(expected="JSON object")


def required_list(value: JsonValue) -> list[JsonValue]:
    if isinstance(value, list):
        return value
    raise JsonShapeError(expected="JSON array")


def required_string(value: JsonValue) -> str:
    if isinstance(value, str):
        return value
    raise JsonShapeError(expected="JSON string")


def optional_request_id(value: JsonValue) -> int | str | None:
    if value is None or isinstance(value, str) or type(value) is int:
        return value
    raise JsonShapeError(expected="JSON-RPC request id")

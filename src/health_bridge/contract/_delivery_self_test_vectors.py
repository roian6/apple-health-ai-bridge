from __future__ import annotations

from typing import Final, Literal

from health_bridge.contract._delivery_common import fail
from health_bridge.contract._delivery_envelope import ENVELOPE_FIELDS
from health_bridge.contract._hbjcs1 import hbjcs1_decode, hbjcs1_encode

FixtureMutation = Literal[
    "none",
    "outer_field",
    "outer_unknown",
    "outer_duplicate",
    "outer_noncanonical",
    "outer_float",
    "inner_invalid_utf8",
    "inner_malformed",
    "inner_trailing",
    "inner_duplicate_root",
    "inner_duplicate_nested",
    "inner_duplicate_array_object",
    "inner_nan",
    "inner_infinity",
    "inner_negative_infinity",
    "inner_strict_schema",
    "inner_oversize",
]

_STRUCTURAL_MUTATIONS: Final = frozenset(
    {
        "inner_invalid_utf8",
        "inner_malformed",
        "inner_trailing",
        "inner_duplicate_root",
        "inner_duplicate_nested",
        "inner_duplicate_array_object",
    }
)
_VALUE_MUTATIONS: Final = frozenset(
    {
        "inner_nan",
        "inner_infinity",
        "inner_negative_infinity",
        "inner_strict_schema",
        "inner_oversize",
    }
)


def _structural_mutation(payload: bytes, mutation: str) -> bytes:
    mutations = {
        "inner_invalid_utf8": b"\xff",
        "inner_malformed": b'{"schema_id":',
        "inner_trailing": payload + b" trailing",
        "inner_duplicate_root": payload.replace(
            b"{", b'{"schema_id":"health_bridge.batch.v1",', 1
        ),
        "inner_duplicate_nested": payload.replace(
            b'"export_window": {',
            b'"export_window": {"end_time":"2026-06-08T00:00:00Z",',
            1,
        ),
        "inner_duplicate_array_object": payload.replace(
            b'"source_key": "synthetic.phone.alpha"',
            b'"kind":"phone","source_key": "synthetic.phone.alpha"',
            1,
        ),
    }
    if mutation not in mutations:
        return fail("payload_invalid")
    return mutations[mutation]


def _value_mutation(payload: bytes, mutation: str) -> bytes:
    if mutation == "inner_nan":
        return payload.replace(b"70.4", b"NaN", 1)
    if mutation == "inner_infinity":
        return payload.replace(b"70.4", b"Infinity", 1)
    if mutation == "inner_negative_infinity":
        return payload.replace(b"70.4", b"-Infinity", 1)
    if mutation == "inner_strict_schema":
        return payload.replace(
            b'"schema_version": "1.0.0"', b'"schema_version": "2.0.0"'
        )
    if mutation == "inner_oversize":
        return b" " * 1_048_577
    return fail("payload_invalid")


def inner_mutation(payload: bytes, mutation: FixtureMutation) -> bytes:
    if mutation in _STRUCTURAL_MUTATIONS:
        return _structural_mutation(payload, mutation)
    if mutation in _VALUE_MUTATIONS:
        return _value_mutation(payload, mutation)
    return payload


def outer_mutation(
    encoded: bytes, mutation: FixtureMutation, field: str | None
) -> bytes:
    if mutation == "outer_duplicate":
        return encoded[:-1] + b',"v":1}'
    if mutation == "outer_noncanonical":
        return b" " + encoded
    if mutation == "outer_float":
        return encoded.replace(b'"created_at_ms":1782000000123', b'"created_at_ms":1.0')
    if mutation not in {"outer_unknown", "outer_field"}:
        return encoded
    raw_value = hbjcs1_decode(encoded)
    if not isinstance(raw_value, dict):
        fail("authentication_failed")
    if mutation == "outer_unknown":
        raw_value["unknown"] = 1
        return hbjcs1_encode(raw_value)
    if field not in ENVELOPE_FIELDS:
        fail("payload_invalid")
    raw_value[field] = (
        2 if field in {"v", "connection_generation", "created_at_ms"} else "A" * 43
    )
    return hbjcs1_encode(raw_value)

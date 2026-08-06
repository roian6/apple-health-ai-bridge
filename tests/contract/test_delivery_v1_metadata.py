from __future__ import annotations

import hashlib
from typing import TYPE_CHECKING

import pytest

from health_bridge.contract import delivery_v1 as delivery
from tests.contract.delivery_v1_support import DOMAINS

if TYPE_CHECKING:
    from health_bridge.contract._hbjcs1 import JsonValue

pytest_plugins = ("tests.contract.delivery_v1_fixtures",)


def test_protocol_constants_match_normative_domains() -> None:
    # Given / When
    actual = {name: getattr(delivery, name) for name in DOMAINS}
    # Then
    assert actual == DOMAINS


def test_hbjcs1_encodes_the_integer_only_profile() -> None:
    # Given / When
    encoded = delivery.hbjcs1_encode({"z": None, "a": "\n", "n": -(2**63), "ok": True})
    # Then
    assert encoded == b'{"a":"\\u000a","n":-9223372036854775808,"ok":true,"z":null}'


@pytest.mark.parametrize(
    "value", [1.0, 1.25, float("nan"), float("inf"), float("-inf")]
)
def test_hbjcs1_rejects_every_float(value: float) -> None:
    # Given / When / Then
    with pytest.raises(delivery.HBJCS1Error):
        _ = delivery.hbjcs1_encode({"value": value})


@pytest.mark.parametrize(
    "encoded",
    [
        b'{"b":1,"a":2}',
        b'{"a":1 }',
        b'{"a":"\\u0061"}',
        b'{"a":1,"a":1}',
        b'{"A":1}',
        b"\xff",
    ],
)
def test_hbjcs1_rejects_noncanonical_metadata(
    encoded: bytes,
) -> None:
    # Given / When / Then
    with pytest.raises(delivery.HBJCS1Error):
        _ = delivery.hbjcs1_decode(encoded)


def test_hbjcs1_rejects_excessive_nesting_with_profile_error() -> None:
    encoded = b"[" * 1_200 + b"0" + b"]" * 1_200

    with pytest.raises(delivery.HBJCS1Error):
        _ = delivery.hbjcs1_decode(encoded)


def test_hbjcs1_encode_rejects_excessive_nesting_with_profile_error() -> None:
    value: JsonValue = 0
    for _ in range(1_200):
        value = [value]

    with pytest.raises(delivery.HBJCS1Error):
        _ = delivery.hbjcs1_encode(value)


@pytest.mark.parametrize("value", [-(2**63) - 1, 2**63])
def test_hbjcs1_rejects_integers_outside_signed_64_bit(
    value: int,
) -> None:
    # Given / When / Then
    with pytest.raises(delivery.HBJCS1Error):
        _ = delivery.hbjcs1_encode({"value": value})


@pytest.mark.parametrize("algorithm", ["ed25519", "x25519"])
def test_key_id_binds_lowercase_algorithm_nul_and_raw_key(
    algorithm: str,
) -> None:
    # Given
    raw_key = bytes(range(32))
    expected = (
        hashlib.sha256(algorithm.encode("ascii") + b"\0" + raw_key).digest()[:16].hex()
    )
    # When
    actual = delivery.key_id(algorithm, raw_key)
    # Then
    assert actual == expected


@pytest.mark.parametrize("algorithm", ["Ed25519", "X25519", "ed25519\0", "p256"])
def test_key_id_rejects_wrong_algorithm_case_or_bytes(
    algorithm: str,
) -> None:
    # Given / When / Then
    with pytest.raises(delivery.DeliveryProtocolError):
        _ = delivery.key_id(algorithm, bytes(32))

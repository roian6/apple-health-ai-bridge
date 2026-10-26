from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING, cast

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from health_bridge.contract._delivery_common import (
    DeliveryProtocolError,
    b64encode,
    key_id,
)
from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_encode
from health_bridge.contract.mailbox_capabilities import (
    create_mailbox_capabilities,
    open_mailbox_capabilities,
)

if TYPE_CHECKING:
    from health_bridge.contract.receiver_capabilities import ReceiverCapabilitiesV1

KEY = Ed25519PrivateKey.from_private_bytes(bytes(range(32)))
RECEIVER = bytes.fromhex("02" * 16)
DEVICE = bytes.fromhex("03" * 16)
DOMAIN = b"health-bridge/mailbox/v1/receiver-capabilities/signature\0"
CAPABILITIES: dict[str, JsonValue] = {
    "schema_id": "health_bridge.receiver_capabilities.v1",
    "batch_schema_id": "health_bridge.batch.v1",
    "nutrition_supported": True,
    "future_synthetic": {"enabled": True},
}


def unsigned() -> dict[str, JsonValue]:
    return {
        "v": 1,
        "kind": "receiver_capabilities",
        "receiver_id": RECEIVER.hex(),
        "device_id": DEVICE.hex(),
        "connection_generation": 1,
        "receiver_signing_key_id": key_id(
            "ed25519", KEY.public_key().public_bytes_raw()
        ),
        "capabilities": dict(CAPABILITIES),
    }


def signed(raw: dict[str, JsonValue]) -> bytes:
    return hbjcs1_encode(
        {**raw, "signature": b64encode(KEY.sign(DOMAIN + hbjcs1_encode(raw)))}
    )


def opened(payload: bytes) -> ReceiverCapabilitiesV1:
    return open_mailbox_capabilities(
        payload,
        receiver_id=RECEIVER,
        device_id=DEVICE,
        connection_generation=1,
        receiver_signing_public_key=KEY.public_key(),
    )


def test_deterministic_full_object_signature_and_golden() -> None:
    payload = create_mailbox_capabilities(
        receiver_id=RECEIVER,
        device_id=DEVICE,
        connection_generation=1,
        receiver_signing_private_key=KEY,
        capabilities=CAPABILITIES,
    )
    assert payload == signed(unsigned())
    assert opened(payload).nutrition_supported is True
    fixture = cast(
        "dict[str, str]",
        json.loads(
            (
                Path(__file__).parents[1]
                / "fixtures/mailbox_receiver_capabilities_v1.synthetic.json"
            ).read_text()
        ),
    )
    assert fixture["document_utf8"].encode() == payload
    assert fixture["public_key_hex"] == KEY.public_key().public_bytes_raw().hex()


def test_unknown_nested_tampering_rejected_before_projection() -> None:
    payload = signed(unsigned())
    assert opened(payload).nutrition_supported is True
    with pytest.raises(DeliveryProtocolError):
        _ = opened(payload.replace(b'"enabled":true', b'"enabled":false'))


def test_explicit_false_is_valid() -> None:
    raw = unsigned()
    raw["capabilities"] = {**CAPABILITIES, "nutrition_supported": False}
    assert opened(signed(raw)).nutrition_supported is False


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("v", True),
        ("v", 2),
        ("kind", "ack"),
        ("receiver_id", "04" * 16),
        ("device_id", "04" * 16),
        ("connection_generation", True),
        ("connection_generation", -1),
        ("connection_generation", 2),
        ("receiver_signing_key_id", "00" * 16),
        ("extra", None),
    ],
)
def test_rejects_signed_wrong_wrapper(field: str, value: JsonValue) -> None:
    raw = unsigned()
    raw[field] = value
    with pytest.raises(DeliveryProtocolError):
        _ = opened(signed(raw))


@pytest.mark.parametrize(
    "capabilities",
    [
        {},
        {**CAPABILITIES, "nutrition_supported": 1},
        {**CAPABILITIES, "nutrition_supported": "true"},
        {**CAPABILITIES, "schema_id": "unknown"},
        {**CAPABILITIES, "batch_schema_id": "unknown"},
        None,
    ],
)
def test_rejects_signed_invalid_capabilities(capabilities: JsonValue) -> None:
    raw = unsigned()
    raw["capabilities"] = capabilities
    with pytest.raises(DeliveryProtocolError):
        _ = opened(signed(raw))


@pytest.mark.parametrize("payload", [b"x" * 8193, b"{}", b"[]", b"\xff"])
def test_rejects_malformed_or_oversize(payload: bytes) -> None:
    with pytest.raises(DeliveryProtocolError):
        _ = opened(payload)


def test_rejects_duplicate_key_and_wrong_trusted_key() -> None:
    payload = signed(unsigned())
    with pytest.raises(DeliveryProtocolError):
        _ = opened(payload.replace(b'"v":1', b'"v":1,"v":1'))
    with pytest.raises(DeliveryProtocolError):
        _ = open_mailbox_capabilities(
            payload,
            receiver_id=RECEIVER,
            device_id=DEVICE,
            connection_generation=1,
            receiver_signing_public_key=Ed25519PrivateKey.from_private_bytes(
                b"x" * 32
            ).public_key(),
        )


def test_signer_refuses_invalid_or_oversize_declaration() -> None:
    for fields in (
        {"nutrition_supported": True},
        {**CAPABILITIES, "large": "x" * 8192},
    ):
        with pytest.raises(DeliveryProtocolError):
            _ = create_mailbox_capabilities(
                receiver_id=RECEIVER,
                device_id=DEVICE,
                connection_generation=1,
                receiver_signing_private_key=KEY,
                capabilities=cast("dict[str, JsonValue]", fields),
            )

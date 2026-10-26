"""Bounded, connection-bound signed Receiver capability metadata."""

from __future__ import annotations

from typing import TYPE_CHECKING, Final

from cryptography.exceptions import InvalidSignature
from pydantic import ValidationError

from health_bridge.contract._delivery_common import (
    b64decode,
    b64encode,
    fail,
    key_id,
    raw_id,
    require_integer,
    require_nonnegative_i64,
    require_object,
    require_string,
)
from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    JsonValue,
    hbjcs1_decode,
    hbjcs1_encode,
)
from health_bridge.contract.receiver_capabilities import ReceiverCapabilitiesV1

if TYPE_CHECKING:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )

MAX_CAPABILITIES_BYTES: Final = 8_192
CAPABILITIES_FILENAME: Final = "receiver-capabilities.json"
CAPABILITIES_SIGNATURE_DOMAIN: Final = (
    b"health-bridge/mailbox/v1/receiver-capabilities/signature"
)
_FIELDS: Final = frozenset(
    {
        "v",
        "kind",
        "receiver_id",
        "device_id",
        "connection_generation",
        "receiver_signing_key_id",
        "capabilities",
        "signature",
    }
)


def create_mailbox_capabilities(
    *,
    receiver_id: bytes,
    device_id: bytes,
    connection_generation: int,
    receiver_signing_private_key: Ed25519PrivateKey,
    capabilities: dict[str, JsonValue],
) -> bytes:
    """Sign the entire declaration, including compatible unknown nested fields."""
    public_key = receiver_signing_private_key.public_key()
    unsigned: dict[str, JsonValue] = {
        "v": 1,
        "kind": "receiver_capabilities",
        "receiver_id": receiver_id.hex(),
        "device_id": device_id.hex(),
        "connection_generation": connection_generation,
        "receiver_signing_key_id": key_id("ed25519", public_key.public_bytes_raw()),
        "capabilities": capabilities,
    }
    try:
        signature = receiver_signing_private_key.sign(
            CAPABILITIES_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned)
        )
        encoded = hbjcs1_encode({**unsigned, "signature": b64encode(signature)})
    except HBJCS1Error:
        fail("authentication_failed")
    _ = open_mailbox_capabilities(
        encoded,
        receiver_id=receiver_id,
        device_id=device_id,
        connection_generation=connection_generation,
        receiver_signing_public_key=public_key,
    )
    return encoded


def open_mailbox_capabilities(
    encoded: bytes,
    *,
    receiver_id: bytes,
    device_id: bytes,
    connection_generation: int,
    receiver_signing_public_key: Ed25519PublicKey,
) -> ReceiverCapabilitiesV1:
    """Authenticate raw fields before projecting onto the existing typed contract."""
    if len(encoded) > MAX_CAPABILITIES_BYTES:
        fail("authentication_failed")
    require_nonnegative_i64(connection_generation)
    try:
        raw = require_object(hbjcs1_decode(encoded), _FIELDS)
        generation = require_integer(raw, "connection_generation")
        require_nonnegative_i64(generation)
        if (
            require_integer(raw, "v") != 1
            or require_string(raw, "kind") != "receiver_capabilities"
            or raw_id(require_string(raw, "receiver_id")) != receiver_id
            or raw_id(require_string(raw, "device_id")) != device_id
            or generation != connection_generation
            or require_string(raw, "receiver_signing_key_id")
            != key_id("ed25519", receiver_signing_public_key.public_bytes_raw())
        ):
            fail("authentication_failed")
        unsigned = {name: value for name, value in raw.items() if name != "signature"}
        receiver_signing_public_key.verify(
            b64decode(require_string(raw, "signature"), length=64),
            CAPABILITIES_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned),
        )
        return ReceiverCapabilitiesV1.model_validate(raw["capabilities"])
    except (HBJCS1Error, InvalidSignature, ValidationError):
        fail("authentication_failed")

from __future__ import annotations

import hashlib
from typing import Final

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from health_bridge.contract._delivery_common import (
    ACK_AAD_DOMAIN,
    ACK_ID_DOMAIN,
    ACK_KEY_DOMAIN,
    ACK_NONCE_DOMAIN,
    ACK_SALT_DOMAIN,
    ACK_SIGNATURE_DOMAIN,
    MAX_ACK_BYTES,
    b64decode,
    b64encode,
    derive_key,
    derive_nonce,
    fail,
    key_id,
    raw_id,
    require_integer,
    require_nonnegative_i64,
    require_object,
    require_string,
)
from health_bridge.contract._delivery_models import (
    AckOpenParams,
    AckSealParams,
    DeliveryAckV1,
    DeliveryReceiptV1,
)
from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    JsonValue,
    hbjcs1_decode,
    hbjcs1_encode,
)

ACK_FIELDS: Final = frozenset(
    {
        "v",
        "kind",
        "ack_id",
        "envelope_id",
        "receiver_id",
        "device_id",
        "connection_generation",
        "device_agreement_key_id",
        "receiver_signing_key_id",
        "nonce",
        "ciphertext",
        "signature",
    }
)
_AAD_FIELDS: Final = ACK_FIELDS - {"nonce", "ciphertext", "signature"}
_RECEIPT_FIELDS: Final = frozenset(
    {
        "result",
        "payload_sha256",
        "receipt_id",
        "dataset_generation",
        "committed_at_ms",
        "error_code",
    }
)
_OPAQUE_ID_BYTES: Final = 16


def _validate_ids(envelope_id: bytes, receiver_id: bytes, device_id: bytes) -> None:
    if any(
        len(value) != _OPAQUE_ID_BYTES
        for value in (envelope_id, receiver_id, device_id)
    ):
        fail("authentication_failed")


def _optional_integer(raw: dict[str, JsonValue], name: str) -> int | None:
    value = raw[name]
    if value is None:
        return None
    if isinstance(value, bool):
        fail("authentication_failed")
    if isinstance(value, int):
        return value
    return fail("authentication_failed")


def _optional_string(raw: dict[str, JsonValue], name: str) -> str | None:
    value = raw[name]
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return fail("authentication_failed")


def create_delivery_ack(
    receipt: DeliveryReceiptV1, params: AckSealParams
) -> DeliveryAckV1:
    _validate_ids(params.envelope_id, params.receiver_id, params.device_id)
    require_nonnegative_i64(params.connection_generation)
    receipt_bytes = receipt.to_bytes()
    ack_id_bytes = hashlib.sha256(
        ACK_ID_DOMAIN + b"\0" + params.envelope_id + receipt_bytes
    ).digest()[:16]
    device_public = params.device_agreement_public_key.public_bytes_raw()
    receiver_signing_public = (
        params.receiver_signing_private_key.public_key().public_bytes_raw()
    )
    aad_fields: dict[str, JsonValue] = {
        "v": 1,
        "kind": "ack",
        "ack_id": ack_id_bytes.hex(),
        "envelope_id": params.envelope_id.hex(),
        "receiver_id": params.receiver_id.hex(),
        "device_id": params.device_id.hex(),
        "connection_generation": params.connection_generation,
        "device_agreement_key_id": key_id("x25519", device_public),
        "receiver_signing_key_id": key_id("ed25519", receiver_signing_public),
    }
    salt = hashlib.sha256(
        ACK_SALT_DOMAIN + b"\0" + params.receiver_id + params.device_id
    ).digest()
    shared = params.receiver_agreement_private_key.exchange(
        params.device_agreement_public_key
    )
    key = derive_key(shared, salt, ACK_KEY_DOMAIN + b"\0" + ack_id_bytes)
    nonce = derive_nonce(shared, salt, ACK_NONCE_DOMAIN + b"\0" + ack_id_bytes)
    ciphertext = AESGCM(key).encrypt(
        nonce, receipt_bytes, ACK_AAD_DOMAIN + b"\0" + hbjcs1_encode(aad_fields)
    )
    unsigned = {
        **aad_fields,
        "nonce": b64encode(nonce),
        "ciphertext": b64encode(ciphertext),
    }
    signature = params.receiver_signing_private_key.sign(
        ACK_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned)
    )
    ack = DeliveryAckV1(
        ack_id=ack_id_bytes.hex(),
        envelope_id=params.envelope_id.hex(),
        receiver_id=params.receiver_id.hex(),
        device_id=params.device_id.hex(),
        connection_generation=params.connection_generation,
        device_agreement_key_id=key_id("x25519", device_public),
        receiver_signing_key_id=key_id("ed25519", receiver_signing_public),
        nonce=b64encode(nonce),
        ciphertext=b64encode(ciphertext),
        signature=b64encode(signature),
    )
    if len(ack.to_bytes()) > MAX_ACK_BYTES:
        fail("authentication_failed")
    return ack


def _parse_ack(encoded: bytes) -> dict[str, JsonValue]:
    if len(encoded) > MAX_ACK_BYTES:
        fail("authentication_failed")
    try:
        return require_object(hbjcs1_decode(encoded), ACK_FIELDS)
    except HBJCS1Error:
        fail("authentication_failed")


def _parse_receipt(plaintext: bytes) -> DeliveryReceiptV1:
    try:
        raw = require_object(hbjcs1_decode(plaintext), _RECEIPT_FIELDS)
        return DeliveryReceiptV1(
            result=require_string(raw, "result"),
            payload_sha256=require_string(raw, "payload_sha256"),
            receipt_id=_optional_integer(raw, "receipt_id"),
            dataset_generation=_optional_integer(raw, "dataset_generation"),
            committed_at_ms=_optional_integer(raw, "committed_at_ms"),
            error_code=_optional_string(raw, "error_code"),
        )
    except HBJCS1Error:
        fail("authentication_failed")


def open_delivery_ack(encoded: bytes, params: AckOpenParams) -> DeliveryReceiptV1:
    raw = _parse_ack(encoded)
    ack_id = raw_id(require_string(raw, "ack_id"))
    envelope_id = raw_id(require_string(raw, "envelope_id"))
    receiver_id = raw_id(require_string(raw, "receiver_id"))
    device_id = raw_id(require_string(raw, "device_id"))
    generation = require_integer(raw, "connection_generation")
    receiver_signing_public = params.receiver_signing_public_key.public_bytes_raw()
    device_public = params.device_agreement_private_key.public_key().public_bytes_raw()
    if (
        require_integer(raw, "v") != 1
        or require_string(raw, "kind") != "ack"
        or envelope_id != params.envelope_id
        or receiver_id != params.receiver_id
        or device_id != params.device_id
        or generation != params.connection_generation
        or require_string(raw, "device_agreement_key_id")
        != key_id("x25519", device_public)
        or require_string(raw, "receiver_signing_key_id")
        != key_id("ed25519", receiver_signing_public)
    ):
        fail("authentication_failed")
    require_nonnegative_i64(generation)
    signature = b64decode(require_string(raw, "signature"), length=64)
    unsigned = {name: value for name, value in raw.items() if name != "signature"}
    try:
        params.receiver_signing_public_key.verify(
            signature, ACK_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned)
        )
    except InvalidSignature:
        fail("authentication_failed")
    salt = hashlib.sha256(ACK_SALT_DOMAIN + b"\0" + receiver_id + device_id).digest()
    shared = params.device_agreement_private_key.exchange(
        params.receiver_agreement_public_key
    )
    key = derive_key(shared, salt, ACK_KEY_DOMAIN + b"\0" + ack_id)
    nonce = derive_nonce(shared, salt, ACK_NONCE_DOMAIN + b"\0" + ack_id)
    if b64decode(require_string(raw, "nonce"), length=12) != nonce:
        fail("authentication_failed")
    aad = {name: raw[name] for name in _AAD_FIELDS}
    try:
        plaintext = AESGCM(key).decrypt(
            nonce,
            b64decode(require_string(raw, "ciphertext")),
            ACK_AAD_DOMAIN + b"\0" + hbjcs1_encode(aad),
        )
    except InvalidTag:
        fail("authentication_failed")
    receipt = _parse_receipt(plaintext)
    recomputed = hashlib.sha256(
        ACK_ID_DOMAIN + b"\0" + envelope_id + plaintext
    ).digest()[:16]
    if recomputed != ack_id:
        fail("authentication_failed")
    return receipt

from __future__ import annotations

import hashlib
import secrets
from typing import Final

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from health_bridge.contract._batch_json import BatchJsonError, validate_batch_json
from health_bridge.contract._delivery_common import (
    CONTENT_TYPE,
    DELIVERY_AAD_DOMAIN,
    DELIVERY_KEY_DOMAIN,
    DELIVERY_SALT_DOMAIN,
    DELIVERY_SIGNATURE_DOMAIN,
    MAX_ENVELOPE_BYTES,
    MAX_PAYLOAD_BYTES,
    b64decode,
    b64encode,
    derive_key,
    fail,
    key_id,
    raw_id,
    require_i64,
    require_integer,
    require_nonnegative_i64,
    require_object,
    require_sha256,
    require_string,
)
from health_bridge.contract._delivery_models import (
    DeliveryCreateParams,
    DeliveryEnvelopeV1,
    DeliveryOpenParams,
    DeliverySealParams,
    OpenedDeliveryV1,
)
from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    JsonValue,
    hbjcs1_decode,
    hbjcs1_encode,
)
from health_bridge.contract.batch_v1 import HealthBridgeBatchV1

ENVELOPE_FIELDS: Final = frozenset(
    {
        "v",
        "kind",
        "envelope_id",
        "receiver_id",
        "device_id",
        "connection_generation",
        "receiver_agreement_key_id",
        "sender_signing_key_id",
        "ephemeral_public_key",
        "nonce",
        "created_at_ms",
        "payload_sha256",
        "content_type",
        "ciphertext",
        "signature",
    }
)
_AAD_FIELDS: Final = ENVELOPE_FIELDS - {"ciphertext", "signature"}
_OPAQUE_ID_BYTES: Final = 16
_GCM_NONCE_BYTES: Final = 12


def _validate_seal_params(params: DeliverySealParams) -> None:
    if any(
        len(value) != _OPAQUE_ID_BYTES
        for value in (params.envelope_id, params.receiver_id, params.device_id)
    ):
        fail("authentication_failed")
    if len(params.nonce) != _GCM_NONCE_BYTES:
        fail("authentication_failed")
    require_nonnegative_i64(params.connection_generation)
    require_i64(params.created_at_ms)


def create_delivery_envelope(
    plaintext: bytes, params: DeliveryCreateParams
) -> DeliveryEnvelopeV1:
    if len(plaintext) > MAX_PAYLOAD_BYTES:
        fail("payload_oversize")
    return seal_delivery_envelope_vector(
        plaintext,
        DeliverySealParams(
            envelope_id=params.envelope_id,
            receiver_id=params.receiver_id,
            device_id=params.device_id,
            connection_generation=params.connection_generation,
            created_at_ms=params.created_at_ms,
            receiver_agreement_public_key=params.receiver_agreement_public_key,
            sender_signing_private_key=params.sender_signing_private_key,
            ephemeral_private_key=X25519PrivateKey.generate(),
            nonce=secrets.token_bytes(_GCM_NONCE_BYTES),
        ),
    )


def seal_delivery_envelope_vector(
    plaintext: bytes, params: DeliverySealParams
) -> DeliveryEnvelopeV1:
    _validate_seal_params(params)
    receiver_public = params.receiver_agreement_public_key.public_bytes_raw()
    sender_public = params.sender_signing_private_key.public_key().public_bytes_raw()
    ephemeral_public = params.ephemeral_private_key.public_key().public_bytes_raw()
    base_fields: dict[str, JsonValue] = {
        "v": 1,
        "kind": "delivery",
        "envelope_id": params.envelope_id.hex(),
        "receiver_id": params.receiver_id.hex(),
        "device_id": params.device_id.hex(),
        "connection_generation": params.connection_generation,
        "receiver_agreement_key_id": key_id("x25519", receiver_public),
        "sender_signing_key_id": key_id("ed25519", sender_public),
        "ephemeral_public_key": b64encode(ephemeral_public),
        "nonce": b64encode(params.nonce),
        "created_at_ms": params.created_at_ms,
        "payload_sha256": hashlib.sha256(plaintext).hexdigest(),
        "content_type": CONTENT_TYPE,
    }
    salt = hashlib.sha256(
        DELIVERY_SALT_DOMAIN + b"\0" + params.receiver_id + params.device_id
    ).digest()
    shared = params.ephemeral_private_key.exchange(params.receiver_agreement_public_key)
    key = derive_key(shared, salt, DELIVERY_KEY_DOMAIN + b"\0" + params.envelope_id)
    aad = DELIVERY_AAD_DOMAIN + b"\0" + hbjcs1_encode(base_fields)
    ciphertext = AESGCM(key).encrypt(params.nonce, plaintext, aad)
    unsigned_fields = {**base_fields, "ciphertext": b64encode(ciphertext)}
    signature = params.sender_signing_private_key.sign(
        DELIVERY_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned_fields)
    )
    return DeliveryEnvelopeV1(
        envelope_id=params.envelope_id.hex(),
        receiver_id=params.receiver_id.hex(),
        device_id=params.device_id.hex(),
        connection_generation=params.connection_generation,
        receiver_agreement_key_id=key_id("x25519", receiver_public),
        sender_signing_key_id=key_id("ed25519", sender_public),
        ephemeral_public_key=b64encode(ephemeral_public),
        nonce=b64encode(params.nonce),
        created_at_ms=params.created_at_ms,
        payload_sha256=hashlib.sha256(plaintext).hexdigest(),
        ciphertext=b64encode(ciphertext),
        signature=b64encode(signature),
    )


def _metadata(encoded: bytes) -> dict[str, JsonValue]:
    if len(encoded) > MAX_ENVELOPE_BYTES:
        fail("authentication_failed")
    try:
        return require_object(hbjcs1_decode(encoded), ENVELOPE_FIELDS)
    except HBJCS1Error:
        fail("authentication_failed")


def _validate_payload(plaintext: bytes) -> None:
    if len(plaintext) > MAX_PAYLOAD_BYTES:
        fail("payload_oversize")
    try:
        text = plaintext.decode("utf-8")
        validate_batch_json(text)
        _ = HealthBridgeBatchV1.model_validate_json(plaintext)
    except (UnicodeDecodeError, BatchJsonError, RecursionError, ValidationError):
        fail("payload_invalid")


def open_delivery_envelope(
    encoded: bytes, params: DeliveryOpenParams
) -> OpenedDeliveryV1:
    raw = _metadata(encoded)
    receiver_id = raw_id(require_string(raw, "receiver_id"))
    device_id = raw_id(require_string(raw, "device_id"))
    envelope_id = raw_id(require_string(raw, "envelope_id"))
    generation = require_integer(raw, "connection_generation")
    receiver_public = (
        params.receiver_agreement_private_key.public_key().public_bytes_raw()
    )
    sender_public = params.sender_signing_public_key.public_bytes_raw()
    if (
        require_integer(raw, "v") != 1
        or require_string(raw, "kind") != "delivery"
        or require_string(raw, "content_type") != CONTENT_TYPE
        or receiver_id != params.receiver_id
        or device_id != params.device_id
        or generation != params.connection_generation
        or require_string(raw, "receiver_agreement_key_id")
        != key_id("x25519", receiver_public)
        or require_string(raw, "sender_signing_key_id")
        != key_id("ed25519", sender_public)
    ):
        fail("authentication_failed")
    require_nonnegative_i64(generation)
    require_i64(require_integer(raw, "created_at_ms"))
    payload_sha256 = require_string(raw, "payload_sha256")
    require_sha256(payload_sha256)
    signature = b64decode(require_string(raw, "signature"), length=64)
    unsigned = {name: value for name, value in raw.items() if name != "signature"}
    try:
        params.sender_signing_public_key.verify(
            signature,
            DELIVERY_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned),
        )
    except InvalidSignature:
        fail("authentication_failed")
    ephemeral_public = b64decode(require_string(raw, "ephemeral_public_key"), length=32)
    nonce = b64decode(require_string(raw, "nonce"), length=12)
    ciphertext = b64decode(require_string(raw, "ciphertext"))
    aad_fields = {name: raw[name] for name in _AAD_FIELDS}
    salt = hashlib.sha256(
        DELIVERY_SALT_DOMAIN + b"\0" + receiver_id + device_id
    ).digest()
    try:
        shared = params.receiver_agreement_private_key.exchange(
            X25519PublicKey.from_public_bytes(ephemeral_public)
        )
        key = derive_key(shared, salt, DELIVERY_KEY_DOMAIN + b"\0" + envelope_id)
        plaintext = AESGCM(key).decrypt(
            nonce,
            ciphertext,
            DELIVERY_AAD_DOMAIN + b"\0" + hbjcs1_encode(aad_fields),
        )
    except (InvalidTag, ValueError):
        fail("authentication_failed")
    if hashlib.sha256(plaintext).hexdigest() != payload_sha256:
        fail("authentication_failed")
    _validate_payload(plaintext)
    return OpenedDeliveryV1(plaintext=plaintext)

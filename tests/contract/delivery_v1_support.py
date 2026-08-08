import base64
import hashlib
from typing import Final

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.contract._delivery_common import DeliveryProtocolError
from health_bridge.contract._delivery_models import (
    AckOpenParams,
    AckSealParams,
    DeliveryCreateParams,
    DeliveryOpenParams,
    DeliveryReceiptV1,
)
from health_bridge.contract._hbjcs1 import JsonValue

BATCH: Final = (
    b'{"deleted_records":[],"export_window":{"end_time":"2026-06-09T00:00:00Z",'
    b'"start_time":"2026-06-08T00:00:00Z"},"generated_at":"2026-06-08T10:00:00Z",'
    b'"health_types":[{"aliases":[],"category":"activity","default_unit":"count",'
    b'"display_name":"Steps","sensitivity":"low","type_code":"step_count"}],'
    b'"samples":[{"client_record_id":"synthetic-sample-1","end_time":'
    b'"2026-06-08T09:05:00Z","metadata":{},"source_key":"synthetic.phone.alpha",'
    b'"start_time":"2026-06-08T09:00:00Z","type_code":"step_count","unit":"count",'
    b'"value":1.25}],"schema_id":"health_bridge.batch.v1","schema_version":"1.0.0",'
    b'"sleep_sessions":[],"sources":[{"kind":"phone","name":"Synthetic Phone",'
    b'"source_key":"synthetic.phone.alpha"}],"sync":{"cursors":[],"sync_window":'
    b'{"end_time":"2026-06-09T00:00:00Z","start_time":"2026-06-08T00:00:00Z"}},'
    b'"workouts":[]}'
)
ENVELOPE_FIELDS: Final = {
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
ACK_FIELDS: Final = {
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
DOMAINS: Final = {
    "DELIVERY_SALT_DOMAIN": b"health-bridge/mailbox/v1/delivery/salt",
    "DELIVERY_KEY_DOMAIN": b"health-bridge/mailbox/v1/delivery/key",
    "DELIVERY_AAD_DOMAIN": b"health-bridge/mailbox/v1/delivery/aad",
    "DELIVERY_SIGNATURE_DOMAIN": b"health-bridge/mailbox/v1/delivery/signature",
    "ACK_ID_DOMAIN": b"health-bridge/mailbox/v1/ack/id",
    "ACK_SALT_DOMAIN": b"health-bridge/mailbox/v1/ack/salt",
    "ACK_KEY_DOMAIN": b"health-bridge/mailbox/v1/ack/key",
    "ACK_NONCE_DOMAIN": b"health-bridge/mailbox/v1/ack/nonce",
    "ACK_AAD_DOMAIN": b"health-bridge/mailbox/v1/ack/aad",
    "ACK_SIGNATURE_DOMAIN": b"health-bridge/mailbox/v1/ack/signature",
}
RETRYABLE: Final = (
    "receiver_busy",
    "storage_unavailable",
    "quota_exceeded",
    "internal_retry",
)
TERMINAL: Final = (
    "payload_invalid",
    "payload_oversize",
    "duplicate_conflict",
    "principal_mismatch",
    "binding_mismatch",
    "generation_mismatch",
    "key_revoked",
)


Contexts = tuple[
    DeliveryCreateParams,
    DeliveryOpenParams,
    AckSealParams,
    AckOpenParams,
]


def error_code(exc: pytest.ExceptionInfo[DeliveryProtocolError]) -> str:
    return exc.value.code


def decode_binary(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def decode_object(encoded: bytes) -> dict[str, JsonValue]:
    value = delivery.hbjcs1_decode(encoded)
    assert isinstance(value, dict)
    return value


def string_field(mapping: dict[str, JsonValue], name: str) -> str:
    value = mapping[name]
    assert isinstance(value, str)
    return value


def authenticated_ack_id_mismatch(
    committed: DeliveryReceiptV1, params: AckSealParams
) -> bytes:
    plaintext = committed.to_bytes()
    ack_id = b"\xaa" * 16
    assert (
        ack_id
        != hashlib.sha256(
            DOMAINS["ACK_ID_DOMAIN"] + b"\0" + params.envelope_id + plaintext
        ).digest()[:16]
    )
    device_public = params.device_agreement_public_key.public_bytes_raw()
    receiver_public = (
        params.receiver_signing_private_key.public_key().public_bytes_raw()
    )
    aad_fields: dict[str, JsonValue] = {
        "v": 1,
        "kind": "ack",
        "ack_id": ack_id.hex(),
        "envelope_id": params.envelope_id.hex(),
        "receiver_id": params.receiver_id.hex(),
        "device_id": params.device_id.hex(),
        "connection_generation": params.connection_generation,
        "device_agreement_key_id": delivery.key_id("x25519", device_public),
        "receiver_signing_key_id": delivery.key_id("ed25519", receiver_public),
    }
    salt = hashlib.sha256(
        DOMAINS["ACK_SALT_DOMAIN"] + b"\0" + params.receiver_id + params.device_id
    ).digest()
    shared = params.receiver_agreement_private_key.exchange(
        params.device_agreement_public_key
    )
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        info=DOMAINS["ACK_KEY_DOMAIN"] + b"\0" + ack_id,
    ).derive(shared)
    nonce = HKDF(
        algorithm=hashes.SHA256(),
        length=12,
        salt=salt,
        info=DOMAINS["ACK_NONCE_DOMAIN"] + b"\0" + ack_id,
    ).derive(shared)
    aad = DOMAINS["ACK_AAD_DOMAIN"] + b"\0" + delivery.hbjcs1_encode(aad_fields)
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, aad)
    unsigned: dict[str, JsonValue] = {
        **aad_fields,
        "nonce": base64.urlsafe_b64encode(nonce).rstrip(b"=").decode(),
        "ciphertext": base64.urlsafe_b64encode(ciphertext).rstrip(b"=").decode(),
    }
    signature = params.receiver_signing_private_key.sign(
        DOMAINS["ACK_SIGNATURE_DOMAIN"] + b"\0" + delivery.hbjcs1_encode(unsigned)
    )
    params.receiver_signing_private_key.public_key().verify(
        signature,
        DOMAINS["ACK_SIGNATURE_DOMAIN"] + b"\0" + delivery.hbjcs1_encode(unsigned),
    )
    assert AESGCM(key).decrypt(nonce, ciphertext, aad) == plaintext
    return delivery.hbjcs1_encode(
        {
            **unsigned,
            "signature": base64.urlsafe_b64encode(signature).rstrip(b"=").decode(),
        }
    )


def authenticated_oversize_envelope(payload: bytes) -> bytes:
    receiver_public = X25519PrivateKey.from_private_bytes(b"\x33" * 32).public_key()
    ephemeral_private = X25519PrivateKey.from_private_bytes(b"\x55" * 32)
    sender_private = Ed25519PrivateKey.from_private_bytes(b"\x11" * 32)
    fields: dict[str, JsonValue] = {
        "v": 1,
        "kind": "delivery",
        "envelope_id": (b"\x01" * 16).hex(),
        "receiver_id": (b"\x02" * 16).hex(),
        "device_id": (b"\x03" * 16).hex(),
        "connection_generation": 7,
        "receiver_agreement_key_id": delivery.key_id(
            "x25519", receiver_public.public_bytes_raw()
        ),
        "sender_signing_key_id": delivery.key_id(
            "ed25519", sender_private.public_key().public_bytes_raw()
        ),
        "ephemeral_public_key": base64.urlsafe_b64encode(
            ephemeral_private.public_key().public_bytes_raw()
        )
        .rstrip(b"=")
        .decode(),
        "nonce": base64.urlsafe_b64encode(b"\x66" * 12).rstrip(b"=").decode(),
        "created_at_ms": 1_782_000_000_123,
        "payload_sha256": hashlib.sha256(payload).hexdigest(),
        "content_type": "application/vnd.health-bridge.batch-v1+json",
    }
    salt = hashlib.sha256(
        DOMAINS["DELIVERY_SALT_DOMAIN"] + b"\0" + b"\x02" * 16 + b"\x03" * 16
    ).digest()
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        info=DOMAINS["DELIVERY_KEY_DOMAIN"] + b"\0" + b"\x01" * 16,
    ).derive(ephemeral_private.exchange(receiver_public))
    aad = DOMAINS["DELIVERY_AAD_DOMAIN"] + b"\0" + delivery.hbjcs1_encode(fields)
    unsigned: dict[str, JsonValue] = {
        **fields,
        "ciphertext": base64.urlsafe_b64encode(
            AESGCM(key).encrypt(b"\x66" * 12, payload, aad)
        )
        .rstrip(b"=")
        .decode(),
    }
    signature = sender_private.sign(
        DOMAINS["DELIVERY_SIGNATURE_DOMAIN"] + b"\0" + delivery.hbjcs1_encode(unsigned)
    )
    return delivery.hbjcs1_encode(
        {
            **unsigned,
            "signature": base64.urlsafe_b64encode(signature).rstrip(b"=").decode(),
        }
    )


def receipt(
    result: str = "committed",
    error_code: str | None = None,
    receipt_id: int | None = 9,
) -> DeliveryReceiptV1:
    committed = result == "committed"
    return DeliveryReceiptV1(
        result=result,
        payload_sha256=hashlib.sha256(BATCH).hexdigest(),
        receipt_id=receipt_id if committed else None,
        dataset_generation=4 if committed else None,
        committed_at_ms=1_782_000_000_456 if committed else None,
        error_code=error_code,
    )

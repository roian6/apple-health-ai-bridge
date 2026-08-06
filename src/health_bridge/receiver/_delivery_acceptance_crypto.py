from __future__ import annotations

import hashlib

from health_bridge.contract._delivery_ack import (
    create_delivery_ack as protocol_create_delivery_ack,
)
from health_bridge.contract._delivery_common import (
    ACK_ID_DOMAIN,
    MAX_ENVELOPE_BYTES,
    fail,
    key_id,
    raw_id,
    require_integer,
    require_nonnegative_i64,
    require_object,
    require_sha256,
    require_string,
)
from health_bridge.contract._delivery_envelope import (
    open_delivery_envelope,
)
from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    JsonValue,
    hbjcs1_decode,
)
from health_bridge.contract.delivery_v1 import (
    AckSealParams,
    DeliveryAckV1,
    DeliveryOpenParams,
    DeliveryReceiptV1,
)
from health_bridge.receiver._delivery_acceptance_models import (
    DeliveryEnvelopeClaims,
    DeliveryTrustedConnection,
)
from health_bridge.storage.delivery_receipts import DeliveryReceiptRecord

ENVELOPE_FIELDS = frozenset(
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


def _outer_metadata(encoded: bytes) -> dict[str, JsonValue]:
    if len(encoded) > MAX_ENVELOPE_BYTES:
        fail("authentication_failed")
    try:
        return require_object(hbjcs1_decode(encoded), ENVELOPE_FIELDS)
    except HBJCS1Error:
        fail("authentication_failed")


def envelope_claims(
    encoded: bytes,
    connection: DeliveryTrustedConnection,
) -> DeliveryEnvelopeClaims:
    raw = _outer_metadata(encoded)
    receiver_id = raw_id(require_string(raw, "receiver_id"))
    device_id = raw_id(require_string(raw, "device_id"))
    if receiver_id != connection.receiver_id or device_id != connection.device_id:
        fail("authentication_failed")
    generation = require_integer(raw, "connection_generation")
    require_nonnegative_i64(generation)
    payload_sha256 = require_string(raw, "payload_sha256")
    require_sha256(payload_sha256)
    return DeliveryEnvelopeClaims(
        envelope_id=raw_id(require_string(raw, "envelope_id")),
        payload_sha256=bytes.fromhex(payload_sha256),
        connection_generation=generation,
    )


def open_exact_plaintext(
    encoded: bytes,
    claims: DeliveryEnvelopeClaims,
    connection: DeliveryTrustedConnection,
) -> bytes:
    return open_delivery_envelope(
        encoded,
        DeliveryOpenParams(
            receiver_id=connection.receiver_id,
            device_id=connection.device_id,
            connection_generation=claims.connection_generation,
            receiver_agreement_private_key=connection.receiver_agreement_private_key,
            sender_signing_public_key=connection.sender_signing_public_key,
        ),
    ).plaintext


def receipt_ack_id(receipt: DeliveryReceiptV1, envelope_id: bytes) -> bytes:
    return hashlib.sha256(
        ACK_ID_DOMAIN + b"\0" + envelope_id + receipt.to_bytes()
    ).digest()[:16]


def build_delivery_ack(
    receipt: DeliveryReceiptV1,
    params: AckSealParams,
) -> DeliveryAckV1:
    return protocol_create_delivery_ack(receipt, params)


def seal_receipt(
    receipt: DeliveryReceiptV1,
    claims: DeliveryEnvelopeClaims,
    connection: DeliveryTrustedConnection,
) -> bytes:
    return build_delivery_ack(
        receipt,
        AckSealParams(
            envelope_id=claims.envelope_id,
            receiver_id=connection.receiver_id,
            device_id=connection.device_id,
            connection_generation=claims.connection_generation,
            device_agreement_public_key=connection.device_agreement_public_key,
            receiver_signing_private_key=connection.receiver_signing_private_key,
            receiver_agreement_private_key=connection.receiver_agreement_private_key,
        ),
    ).to_bytes()


def stored_receipt(record: DeliveryReceiptRecord) -> DeliveryReceiptV1:
    return DeliveryReceiptV1(
        result=record.result,
        payload_sha256=record.payload_sha256.hex(),
        receipt_id=record.receipt_id,
        dataset_generation=record.dataset_generation,
        committed_at_ms=record.committed_at_ms,
        error_code=record.error_code,
    )


def trusted_key_ids(connection: DeliveryTrustedConnection) -> tuple[bytes, ...]:
    return (
        bytes.fromhex(
            key_id(
                "x25519",
                connection.receiver_agreement_private_key.public_key().public_bytes_raw(),
            )
        ),
        bytes.fromhex(
            key_id("ed25519", connection.sender_signing_public_key.public_bytes_raw())
        ),
        bytes.fromhex(
            key_id("x25519", connection.device_agreement_public_key.public_bytes_raw())
        ),
        bytes.fromhex(
            key_id(
                "ed25519",
                connection.receiver_signing_private_key.public_key().public_bytes_raw(),
            )
        ),
    )


def same_receipt_context(
    record: DeliveryReceiptRecord,
    claims: DeliveryEnvelopeClaims,
    connection: DeliveryTrustedConnection,
) -> bool:
    receiver_key, sender_key, device_key, signing_key = trusted_key_ids(connection)
    return (
        record.connection_generation == claims.connection_generation
        and record.opaque_binding == connection.opaque_binding.value
        and record.receiver_agreement_key_id == receiver_key
        and record.sender_signing_key_id == sender_key
        and record.device_agreement_key_id == device_key
        and record.receiver_signing_key_id == signing_key
    )


def committed_receipt_record(
    receipt: DeliveryReceiptV1,
    claims: DeliveryEnvelopeClaims,
    connection: DeliveryTrustedConnection,
) -> DeliveryReceiptRecord:
    receiver_key, sender_key, device_key, signing_key = trusted_key_ids(connection)
    return DeliveryReceiptRecord(
        receipt_id=receipt.receipt_id,
        envelope_id=claims.envelope_id,
        payload_sha256=claims.payload_sha256,
        receiver_id=connection.receiver_id,
        device_id=connection.device_id,
        receiver_agreement_key_id=receiver_key,
        sender_signing_key_id=sender_key,
        device_agreement_key_id=device_key,
        receiver_signing_key_id=signing_key,
        opaque_binding=connection.opaque_binding.value,
        connection_generation=claims.connection_generation,
        result="committed",
        committed_sync_run_id=receipt.receipt_id,
        ack_id=receipt_ack_id(receipt, claims.envelope_id),
        dataset_generation=receipt.dataset_generation,
        committed_at_ms=receipt.committed_at_ms,
        error_code=None,
    )

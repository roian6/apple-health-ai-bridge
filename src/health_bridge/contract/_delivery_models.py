from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey,
        X25519PublicKey,
    )

from health_bridge.contract._delivery_common import (
    RETRYABLE_CODES,
    TERMINAL_CODES,
    fail,
    require_nonnegative_i64,
    require_sha256,
)
from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_encode

_PRINCIPAL_PATTERN: Final = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_OPAQUE_BINDING_BYTES: Final = 32


@dataclass(frozen=True, slots=True)
class DevicePrincipal:
    value: str

    def __post_init__(self) -> None:
        if _PRINCIPAL_PATTERN.fullmatch(self.value) is None:
            fail("authentication_failed")


@dataclass(frozen=True, slots=True)
class OpaqueBinding:
    value: bytes

    def __post_init__(self) -> None:
        if len(self.value) != _OPAQUE_BINDING_BYTES:
            fail("authentication_failed")


@dataclass(frozen=True, slots=True)
class DeliveryCreateParams:
    envelope_id: bytes
    receiver_id: bytes
    device_id: bytes
    connection_generation: int
    created_at_ms: int
    receiver_agreement_public_key: X25519PublicKey
    sender_signing_private_key: Ed25519PrivateKey


@dataclass(frozen=True, slots=True)
class DeliverySealParams:
    envelope_id: bytes
    receiver_id: bytes
    device_id: bytes
    connection_generation: int
    created_at_ms: int
    receiver_agreement_public_key: X25519PublicKey
    sender_signing_private_key: Ed25519PrivateKey
    ephemeral_private_key: X25519PrivateKey
    nonce: bytes


@dataclass(frozen=True, slots=True)
class DeliveryOpenParams:
    receiver_id: bytes
    device_id: bytes
    connection_generation: int
    receiver_agreement_private_key: X25519PrivateKey
    sender_signing_public_key: Ed25519PublicKey


@dataclass(frozen=True, slots=True)
class AckSealParams:
    envelope_id: bytes
    receiver_id: bytes
    device_id: bytes
    connection_generation: int
    device_agreement_public_key: X25519PublicKey
    receiver_signing_private_key: Ed25519PrivateKey
    receiver_agreement_private_key: X25519PrivateKey


@dataclass(frozen=True, slots=True)
class AckOpenParams:
    envelope_id: bytes
    receiver_id: bytes
    device_id: bytes
    connection_generation: int
    device_agreement_private_key: X25519PrivateKey
    receiver_signing_public_key: Ed25519PublicKey
    receiver_agreement_public_key: X25519PublicKey


@dataclass(frozen=True, slots=True)
class DeliveryEnvelopeV1:
    envelope_id: str
    receiver_id: str
    device_id: str
    connection_generation: int
    receiver_agreement_key_id: str
    sender_signing_key_id: str
    ephemeral_public_key: str
    nonce: str
    created_at_ms: int
    payload_sha256: str
    ciphertext: str
    signature: str

    def unsigned_fields(self) -> dict[str, JsonValue]:
        return {
            "v": 1,
            "kind": "delivery",
            "envelope_id": self.envelope_id,
            "receiver_id": self.receiver_id,
            "device_id": self.device_id,
            "connection_generation": self.connection_generation,
            "receiver_agreement_key_id": self.receiver_agreement_key_id,
            "sender_signing_key_id": self.sender_signing_key_id,
            "ephemeral_public_key": self.ephemeral_public_key,
            "nonce": self.nonce,
            "created_at_ms": self.created_at_ms,
            "payload_sha256": self.payload_sha256,
            "content_type": "application/vnd.health-bridge.batch-v1+json",
            "ciphertext": self.ciphertext,
        }

    def to_bytes(self) -> bytes:
        fields = self.unsigned_fields()
        fields["signature"] = self.signature
        return hbjcs1_encode(fields)


@dataclass(frozen=True, slots=True)
class OpenedDeliveryV1:
    plaintext: bytes


@dataclass(frozen=True, slots=True)
class DeliveryReceiptV1:
    result: str
    payload_sha256: str
    receipt_id: int | None
    dataset_generation: int | None
    committed_at_ms: int | None
    error_code: str | None

    def __post_init__(self) -> None:
        require_sha256(self.payload_sha256)
        if self.result == "committed":
            if self.error_code is not None or None in {
                self.receipt_id,
                self.dataset_generation,
                self.committed_at_ms,
            }:
                fail("authentication_failed")
            if self.receipt_id is not None:
                require_nonnegative_i64(self.receipt_id)
            if self.dataset_generation is not None:
                require_nonnegative_i64(self.dataset_generation)
            if self.committed_at_ms is not None:
                require_nonnegative_i64(self.committed_at_ms)
            return
        if self.result == "retryable":
            self._require_failure_receipt(RETRYABLE_CODES)
            return
        if self.result == "terminal":
            self._require_failure_receipt(TERMINAL_CODES)
            return
        fail("authentication_failed")

    def _require_failure_receipt(self, allowed_codes: frozenset[str]) -> None:
        if (
            any(
                value is not None
                for value in (
                    self.receipt_id,
                    self.dataset_generation,
                    self.committed_at_ms,
                )
            )
            or self.error_code not in allowed_codes
        ):
            fail("authentication_failed")

    def to_bytes(self) -> bytes:
        return hbjcs1_encode(
            {
                "result": self.result,
                "payload_sha256": self.payload_sha256,
                "receipt_id": self.receipt_id,
                "dataset_generation": self.dataset_generation,
                "committed_at_ms": self.committed_at_ms,
                "error_code": self.error_code,
            }
        )


@dataclass(frozen=True, slots=True)
class DeliveryAckV1:
    ack_id: str
    envelope_id: str
    receiver_id: str
    device_id: str
    connection_generation: int
    device_agreement_key_id: str
    receiver_signing_key_id: str
    nonce: str
    ciphertext: str
    signature: str

    def unsigned_fields(self) -> dict[str, JsonValue]:
        return {
            "v": 1,
            "kind": "ack",
            "ack_id": self.ack_id,
            "envelope_id": self.envelope_id,
            "receiver_id": self.receiver_id,
            "device_id": self.device_id,
            "connection_generation": self.connection_generation,
            "device_agreement_key_id": self.device_agreement_key_id,
            "receiver_signing_key_id": self.receiver_signing_key_id,
            "nonce": self.nonce,
            "ciphertext": self.ciphertext,
        }

    def to_bytes(self) -> bytes:
        fields = self.unsigned_fields()
        fields["signature"] = self.signature
        return hbjcs1_encode(fields)

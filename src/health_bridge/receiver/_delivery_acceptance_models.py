from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, Protocol

from typing_extensions import override

if TYPE_CHECKING:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey,
        X25519PublicKey,
    )

    from health_bridge.contract._delivery_common import TerminalCode
    from health_bridge.contract.delivery_v1 import (
        DeliveryReceiptV1,
        DevicePrincipal,
        OpaqueBinding,
    )
    from health_bridge.receiver.tokens import ReceiverTokenPrincipal


class DeliveryAcceptanceFaultPoint(StrEnum):
    BEFORE_CLAIM = "before_claim"
    AFTER_CLAIM = "after_claim"
    DURING_INGEST = "during_ingest"
    BEFORE_COMMIT = "before_commit"
    AFTER_COMMIT = "after_commit"
    BEFORE_ACK_PUBLICATION = "before_ack_publication"


class DeliveryAcceptanceFaultHook(Protocol):
    def __call__(self, point: DeliveryAcceptanceFaultPoint) -> None: ...


@dataclass(frozen=True, slots=True)
class DeliveryTrustedConnection:
    receiver_id: bytes
    device_id: bytes
    connection_generation: int
    device_principal: DevicePrincipal
    opaque_binding: OpaqueBinding
    receiver_agreement_private_key: X25519PrivateKey
    sender_signing_public_key: Ed25519PublicKey
    device_agreement_public_key: X25519PublicKey
    receiver_signing_private_key: Ed25519PrivateKey
    source_principal: ReceiverTokenPrincipal
    sender_key_revoked: bool = False


@dataclass(frozen=True, slots=True)
class DeliveryAcceptanceRequest:
    envelope_bytes: bytes
    device_principal: DevicePrincipal
    opaque_binding: OpaqueBinding


@dataclass(frozen=True, slots=True)
class DeliveryAcceptanceResult:
    ack_bytes: bytes
    receipt: DeliveryReceiptV1
    replayed: bool


@dataclass(frozen=True, slots=True)
class DeliveryEnvelopeClaims:
    envelope_id: bytes
    payload_sha256: bytes
    connection_generation: int


@dataclass(frozen=True, slots=True)
class DeliveryTerminalError(Exception):
    code: TerminalCode

    @override
    def __str__(self) -> str:
        return self.code

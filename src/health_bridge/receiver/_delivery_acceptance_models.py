from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, Protocol

from typing_extensions import override

from health_bridge.contract._hbjcs1 import hbjcs1_encode

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

    def enrollment_digest(self) -> str:
        """Bind persisted consent to the exact peer, independent of cached trust."""
        keys = {
            "sender_signing": self.sender_signing_public_key,
            "device_agreement": self.device_agreement_public_key,
            "receiver_signing": self.receiver_signing_private_key.public_key(),
            "receiver_agreement": self.receiver_agreement_private_key.public_key(),
        }
        return hashlib.sha256(
            hbjcs1_encode(
                {
                    "receiver_id": self.receiver_id.hex(),
                    "device_id": self.device_id.hex(),
                    "generation": self.connection_generation,
                    "principal": self.device_principal.value,
                    "installation": self.source_principal.installation_id_hash,
                    "binding": self.opaque_binding.value.hex(),
                    **{
                        name: key.public_bytes_raw().hex() for name, key in keys.items()
                    },
                }
            )
        ).hexdigest()


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

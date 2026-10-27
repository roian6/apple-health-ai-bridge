from __future__ import annotations

import hashlib
import secrets
from typing import TYPE_CHECKING, ClassVar, Final, Literal, Self

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, model_validator

from health_bridge.contract._delivery_common import b64decode, b64encode, derive_key
from health_bridge.contract._hbjcs1 import hbjcs1_decode, hbjcs1_encode

if TYPE_CHECKING:
    from health_bridge.receiver.mailbox_keys import MailboxKeyStore

MAX_PAIRING_BYTES: Final = 65_536
PAIRING_DOMAIN: Final = b"health-bridge/mailbox-pairing/v1/"


class BootstrapDescriptor(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, extra="forbid", strict=True
    )

    version: Literal[1] = 1
    invitation_id: str = Field(pattern=r"^[0-9a-f]{32}$")
    receiver_signing_public_key: str
    receiver_agreement_public_key: str

    @model_validator(mode="after")
    def validate_keys(self) -> Self:
        _ = b64decode(self.receiver_signing_public_key, length=32)
        _ = b64decode(self.receiver_agreement_public_key, length=32)
        return self


class NativePairingRequest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, extra="forbid", strict=True
    )

    invitation_secret: str
    installation_id: str
    device_credential: str
    platform: Literal["ios"]
    device_signing_public_key: str
    device_agreement_public_key: str


class PairingRequestEnvelope(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, extra="forbid", strict=True
    )

    v: Literal[1] = 1
    kind: Literal["request"] = "request"
    invitation_id: str = Field(pattern=r"^[0-9a-f]{32}$")
    sender_signing_public_key: str
    ephemeral_public_key: str
    nonce: str
    ciphertext: str
    signature: str


class PairingCompletionEnvelope(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, extra="forbid", strict=True
    )

    v: Literal[1] = 1
    kind: Literal["completion"] = "completion"
    invitation_id: str = Field(pattern=r"^[0-9a-f]{32}$")
    sender_signing_public_key: str
    request_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    nonce: str
    ciphertext: str
    signature: str


class NativePairingError(ValueError):
    def __init__(self) -> None:
        super().__init__("native_pairing_invalid")


def canonical_model(value: BaseModel, *, exclude: set[str] | None = None) -> bytes:
    fields = TypeAdapter(dict[str, str | int | bool | None]).validate_json(
        value.model_dump_json(exclude=exclude)
    )
    return hbjcs1_encode(dict(fields))


def seal_pairing_request(
    request: NativePairingRequest,
    descriptor: BootstrapDescriptor,
    keys: MailboxKeyStore,
) -> bytes:
    ephemeral = X25519PrivateKey.generate()
    receiver = X25519PublicKey.from_public_bytes(
        b64decode(descriptor.receiver_agreement_public_key, length=32)
    )
    nonce = secrets.token_bytes(12)
    envelope = PairingRequestEnvelope(
        invitation_id=descriptor.invitation_id,
        sender_signing_public_key=b64encode(keys.load_or_create().signing_public_key),
        ephemeral_public_key=b64encode(ephemeral.public_key().public_bytes_raw()),
        nonce=b64encode(nonce),
        ciphertext="",
        signature="",
    )
    key = derive_key(
        ephemeral.exchange(receiver),
        bytes.fromhex(descriptor.invitation_id),
        PAIRING_DOMAIN + b"request/key",
    )
    encrypted = envelope.model_copy(
        update={
            "ciphertext": b64encode(
                AESGCM(key).encrypt(
                    nonce,
                    canonical_model(request),
                    PAIRING_DOMAIN
                    + b"request/aad\0"
                    + canonical_model(envelope, exclude={"ciphertext", "signature"}),
                )
            )
        }
    )
    return canonical_model(
        encrypted.model_copy(
            update={
                "signature": b64encode(
                    keys.sign(
                        PAIRING_DOMAIN
                        + b"request/signature\0"
                        + canonical_model(encrypted, exclude={"signature"})
                    )
                )
            }
        )
    )


def _exchange_peer_key(keys: MailboxKeyStore, encoded_peer: str) -> bytes:
    # Local identity loss/corruption/revocation must retain its fail-closed policy.
    private = keys.private_identity().agreement_private_key
    peer = b64decode(encoded_peer, length=32)
    try:
        return private.exchange(X25519PublicKey.from_public_bytes(peer))
    except ValueError as exc:
        raise NativePairingError from exc


def open_pairing_request(
    encoded: bytes, descriptor: BootstrapDescriptor, keys: MailboxKeyStore
) -> NativePairingRequest:
    if len(encoded) > MAX_PAIRING_BYTES:
        raise NativePairingError
    envelope = PairingRequestEnvelope.model_validate(hbjcs1_decode(encoded))
    identity = keys.load_or_create()
    if (
        envelope.invitation_id != descriptor.invitation_id
        or descriptor.receiver_signing_public_key
        != b64encode(identity.signing_public_key)
        or descriptor.receiver_agreement_public_key
        != b64encode(identity.agreement_public_key)
        or canonical_model(envelope) != encoded
    ):
        raise NativePairingError
    Ed25519PublicKey.from_public_bytes(
        b64decode(envelope.sender_signing_public_key, length=32)
    ).verify(
        b64decode(envelope.signature, length=64),
        PAIRING_DOMAIN
        + b"request/signature\0"
        + canonical_model(envelope, exclude={"signature"}),
    )
    key = derive_key(
        _exchange_peer_key(keys, envelope.ephemeral_public_key),
        bytes.fromhex(descriptor.invitation_id),
        PAIRING_DOMAIN + b"request/key",
    )
    plaintext = AESGCM(key).decrypt(
        b64decode(envelope.nonce, length=12),
        b64decode(envelope.ciphertext),
        PAIRING_DOMAIN
        + b"request/aad\0"
        + canonical_model(envelope, exclude={"ciphertext", "signature"}),
    )
    request = NativePairingRequest.model_validate(hbjcs1_decode(plaintext))
    if request.device_signing_public_key != envelope.sender_signing_public_key:
        raise NativePairingError
    _ = _exchange_peer_key(keys, request.device_agreement_public_key)
    return request


def seal_pairing_completion(
    plaintext: bytes, encoded_request: bytes, keys: MailboxKeyStore
) -> bytes:
    envelope = PairingRequestEnvelope.model_validate(hbjcs1_decode(encoded_request))
    identity = keys.load_or_create()
    descriptor = BootstrapDescriptor(
        invitation_id=envelope.invitation_id,
        receiver_signing_public_key=b64encode(identity.signing_public_key),
        receiver_agreement_public_key=b64encode(identity.agreement_public_key),
    )
    request = open_pairing_request(encoded_request, descriptor, keys)
    digest = hashlib.sha256(encoded_request).digest()
    shared = keys.exchange(b64decode(request.device_agreement_public_key, length=32))
    salt = bytes.fromhex(envelope.invitation_id) + digest
    key = derive_key(shared, salt, PAIRING_DOMAIN + b"completion/key")
    nonce = derive_key(shared, salt, PAIRING_DOMAIN + b"completion/nonce")[:12]
    response = PairingCompletionEnvelope(
        invitation_id=envelope.invitation_id,
        sender_signing_public_key=descriptor.receiver_signing_public_key,
        request_sha256=digest.hex(),
        nonce=b64encode(nonce),
        ciphertext="",
        signature="",
    )
    response = response.model_copy(
        update={
            "ciphertext": b64encode(
                AESGCM(key).encrypt(
                    nonce,
                    plaintext,
                    PAIRING_DOMAIN
                    + b"completion/aad\0"
                    + canonical_model(response, exclude={"ciphertext", "signature"}),
                )
            )
        }
    )
    result = canonical_model(
        response.model_copy(
            update={
                "signature": b64encode(
                    keys.sign(
                        PAIRING_DOMAIN
                        + b"completion/signature\0"
                        + canonical_model(response, exclude={"signature"})
                    )
                )
            }
        )
    )
    if len(result) > MAX_PAIRING_BYTES:
        raise NativePairingError
    return result


class PairingCancellation(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, extra="forbid", strict=True
    )

    v: Literal[1] = 1
    kind: Literal["cancel", "cancelled"]
    invitation_id: str = Field(pattern=r"^[0-9a-f]{32}$")
    request_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    sender_signing_public_key: str
    signature: str


def verify_pairing_cancellation(
    encoded: bytes,
    encoded_request: bytes,
    descriptor: BootstrapDescriptor,
    keys: MailboxKeyStore,
) -> NativePairingRequest:
    request = open_pairing_request(encoded_request, descriptor, keys)
    if len(encoded) > MAX_PAIRING_BYTES:
        raise NativePairingError
    cancel = PairingCancellation.model_validate(hbjcs1_decode(encoded))
    if (
        canonical_model(cancel) != encoded
        or cancel.kind != "cancel"
        or cancel.invitation_id != descriptor.invitation_id
        or cancel.request_sha256 != hashlib.sha256(encoded_request).hexdigest()
        or cancel.sender_signing_public_key != request.device_signing_public_key
    ):
        raise NativePairingError
    Ed25519PublicKey.from_public_bytes(
        b64decode(cancel.sender_signing_public_key, length=32)
    ).verify(
        b64decode(cancel.signature, length=64),
        PAIRING_DOMAIN
        + b"cancel/signature\0"
        + canonical_model(cancel, exclude={"signature"}),
    )
    return request


def seal_cancellation_receipt(
    encoded_request: bytes,
    descriptor: BootstrapDescriptor,
    keys: MailboxKeyStore,
) -> bytes:
    receipt = PairingCancellation(
        kind="cancelled",
        invitation_id=descriptor.invitation_id,
        request_sha256=hashlib.sha256(encoded_request).hexdigest(),
        sender_signing_public_key=b64encode(keys.load_or_create().signing_public_key),
        signature="",
    )
    return canonical_model(
        receipt.model_copy(
            update={
                "signature": b64encode(
                    keys.sign(
                        PAIRING_DOMAIN
                        + b"cancelled/signature\0"
                        + canonical_model(receipt, exclude={"signature"})
                    )
                )
            }
        )
    )

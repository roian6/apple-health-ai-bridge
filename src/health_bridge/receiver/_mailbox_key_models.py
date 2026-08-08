from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, ClassVar, Final, Literal, TypeAlias, final

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from pydantic import BaseModel, ConfigDict, StrictInt, StrictStr
from typing_extensions import override

if TYPE_CHECKING:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

_BASE64URL: Final = re.compile(r"[A-Za-z0-9_-]+")
_KEY_ID: Final = re.compile(r"[0-9a-f]{32}")
_PRIVATE_KEY_BYTES: Final = 32
_SIGNATURE_BYTES: Final = 64
_CONTINUITY_DOMAIN: Final = "health-bridge/mailbox/key-continuity/v1"
_ANCHOR_DOMAIN: Final = "health-bridge/mailbox/expected-identity/v1"
_PROVISIONING_DOMAIN: Final = "health-bridge/mailbox/provisioning-anchor/v1"


class MailboxKeyLifecycleState(StrEnum):
    ACTIVE = "active"
    LOST = "lost"
    REVOKED = "revoked"


MailboxKeyBackupPolicy: TypeAlias = Literal["local_explicit_backup_only"]


class MailboxKeyStoreErrorCode(StrEnum):
    KEY_MATERIAL_LOST = "key_material_lost"
    KEYS_REVOKED = "keys_revoked"
    STALE_IDENTITY = "stale_identity"
    UNSAFE_PERMISSIONS = "unsafe_permissions"
    PROHIBITED_STORAGE = "prohibited_storage"
    MALFORMED_STATE = "malformed_state"
    STORAGE_UNAVAILABLE = "storage_unavailable"
    ROLLBACK_DETECTED = "rollback_detected"


@final
class MailboxKeyStoreError(Exception):
    __slots__ = ("code",)

    def __init__(self, code: MailboxKeyStoreErrorCode) -> None:
        super().__init__(code)
        self.code = code

    @override
    def __str__(self) -> str:
        return f"mailbox key store error: {self.code.value}"


@dataclass(frozen=True, slots=True)
class MailboxIdentity:
    signing_public_key: bytes
    agreement_public_key: bytes
    signing_key_id: str
    agreement_key_id: str


@dataclass(frozen=True, slots=True)
class MailboxPrivateIdentity:
    signing_private_key: Ed25519PrivateKey
    agreement_private_key: X25519PrivateKey


class MailboxKeyLifecycleSummary(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    state: MailboxKeyLifecycleState
    signing_key_id: str | None = None
    agreement_key_id: str | None = None


class MailboxKeyContinuityRecord(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    agreement_new_public_key: StrictStr
    agreement_old_public_key: StrictStr
    domain: StrictStr
    new_agreement_key_id: StrictStr
    new_signing_key_id: StrictStr
    old_agreement_key_id: StrictStr
    old_signing_key_id: StrictStr
    rotated_at_ms: StrictInt
    signature: StrictStr
    signing_new_public_key: StrictStr
    signing_old_public_key: StrictStr
    v: StrictInt

    def canonical_bytes(self) -> bytes:
        return _canonical_json(self)

    def signature_bytes(self) -> bytes:
        return strict_base64url_decode(self.signature, _SIGNATURE_BYTES)

    def signature_preimage(self) -> bytes:
        unsigned = _UnsignedContinuity(
            agreement_new_public_key=self.agreement_new_public_key,
            agreement_old_public_key=self.agreement_old_public_key,
            domain=self.domain,
            new_agreement_key_id=self.new_agreement_key_id,
            new_signing_key_id=self.new_signing_key_id,
            old_agreement_key_id=self.old_agreement_key_id,
            old_signing_key_id=self.old_signing_key_id,
            rotated_at_ms=self.rotated_at_ms,
            signing_new_public_key=self.signing_new_public_key,
            signing_old_public_key=self.signing_old_public_key,
            v=self.v,
        )
        return _CONTINUITY_DOMAIN.encode("ascii") + b"\0" + _canonical_json(unsigned)


class _UnsignedContinuity(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    agreement_new_public_key: StrictStr
    agreement_old_public_key: StrictStr
    domain: StrictStr
    new_agreement_key_id: StrictStr
    new_signing_key_id: StrictStr
    old_agreement_key_id: StrictStr
    old_signing_key_id: StrictStr
    rotated_at_ms: StrictInt
    signing_new_public_key: StrictStr
    signing_old_public_key: StrictStr
    v: StrictInt


class StoredMailboxKeys(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    agreement_private_key: StrictStr
    continuity: MailboxKeyContinuityRecord | None
    generation: StrictInt
    signing_private_key: StrictStr
    state: MailboxKeyLifecycleState
    v: StrictInt


class ExpectedIdentityAnchor(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    agreement_key_id: StrictStr
    agreement_public_key: StrictStr
    continuity: MailboxKeyContinuityRecord | None
    domain: StrictStr
    generation: StrictInt
    signing_key_id: StrictStr
    signing_public_key: StrictStr
    state: MailboxKeyLifecycleState
    v: StrictInt


class ProvisioningAnchor(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    anchor_sha256: StrictStr
    domain: StrictStr
    expected: ExpectedIdentityAnchor
    generation: StrictInt
    v: StrictInt


@dataclass(frozen=True, slots=True)
class MailboxKeyRotation:
    identity: MailboxIdentity
    continuity: MailboxKeyContinuityRecord


def strict_base64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def strict_base64url_decode(value: str, expected_size: int) -> bytes:
    if _BASE64URL.fullmatch(value) is None:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    padding = "=" * (-len(value) % 4)
    try:
        decoded = base64.b64decode(value + padding, altchars=b"-_", validate=True)
    except (binascii.Error, ValueError) as exc:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE) from exc
    if len(decoded) != expected_size or strict_base64url_encode(decoded) != value:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    return decoded


def key_id(algorithm: bytes, public_key: bytes) -> str:
    return hashlib.sha256(algorithm + b"\0" + public_key).digest()[:16].hex()


def verify_mailbox_key_continuity(record: MailboxKeyContinuityRecord) -> None:
    if record.v != 1 or record.domain != _CONTINUITY_DOMAIN:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    if not 0 <= record.rotated_at_ms <= (2**63) - 1:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    old_signing = strict_base64url_decode(record.signing_old_public_key, 32)
    old_agreement = strict_base64url_decode(record.agreement_old_public_key, 32)
    new_signing = strict_base64url_decode(record.signing_new_public_key, 32)
    new_agreement = strict_base64url_decode(record.agreement_new_public_key, 32)
    identifiers = (
        (record.old_signing_key_id, key_id(b"ed25519", old_signing)),
        (record.old_agreement_key_id, key_id(b"x25519", old_agreement)),
        (record.new_signing_key_id, key_id(b"ed25519", new_signing)),
        (record.new_agreement_key_id, key_id(b"x25519", new_agreement)),
    )
    if any(
        _KEY_ID.fullmatch(actual) is None or actual != expected
        for actual, expected in identifiers
    ):
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    try:
        Ed25519PublicKey.from_public_bytes(old_signing).verify(
            record.signature_bytes(), record.signature_preimage()
        )
    except (InvalidSignature, ValueError) as exc:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE) from exc


def canonical_model_bytes(model: BaseModel) -> bytes:
    return _canonical_json(model)


def anchor_domain() -> str:
    return _ANCHOR_DOMAIN


def continuity_domain() -> str:
    return _CONTINUITY_DOMAIN


def provisioning_domain() -> str:
    return _PROVISIONING_DOMAIN


def _canonical_json(model: BaseModel) -> bytes:
    return json.dumps(
        model.model_dump(mode="json"),
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")

import hashlib
import time
from typing import Final, assert_never

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from pydantic import ValidationError

from health_bridge.receiver._mailbox_key_models import (
    ExpectedIdentityAnchor,
    MailboxIdentity,
    MailboxKeyContinuityRecord,
    MailboxKeyLifecycleState,
    MailboxKeyLifecycleSummary,
    MailboxKeyStoreError,
    MailboxKeyStoreErrorCode,
    ProvisioningAnchor,
    StoredMailboxKeys,
    anchor_domain,
    canonical_model_bytes,
    continuity_domain,
    key_id,
    provisioning_domain,
    strict_base64url_decode,
    strict_base64url_encode,
    verify_mailbox_key_continuity,
)

_PRIVATE_KEY_BYTES: Final = 32
_SHA256_HEX_LENGTH: Final = 64


def new_stored_keys(*, generation: int = 1) -> StoredMailboxKeys:
    signing = Ed25519PrivateKey.generate()
    agreement = X25519PrivateKey.generate()
    return StoredMailboxKeys(
        agreement_private_key=strict_base64url_encode(agreement.private_bytes_raw()),
        continuity=None,
        generation=generation,
        signing_private_key=strict_base64url_encode(signing.private_bytes_raw()),
        state=MailboxKeyLifecycleState.ACTIVE,
        v=1,
    )


def public_identity(stored: StoredMailboxKeys) -> MailboxIdentity:
    signing_private = strict_base64url_decode(
        stored.signing_private_key, _PRIVATE_KEY_BYTES
    )
    agreement_private = strict_base64url_decode(
        stored.agreement_private_key, _PRIVATE_KEY_BYTES
    )
    signing = (
        Ed25519PrivateKey.from_private_bytes(signing_private)
        .public_key()
        .public_bytes_raw()
    )
    agreement = (
        X25519PrivateKey.from_private_bytes(agreement_private)
        .public_key()
        .public_bytes_raw()
    )
    return MailboxIdentity(
        signing_public_key=signing,
        agreement_public_key=agreement,
        signing_key_id=key_id(b"ed25519", signing),
        agreement_key_id=key_id(b"x25519", agreement),
    )


def identity_from_anchor(anchor: ExpectedIdentityAnchor) -> MailboxIdentity:
    signing = strict_base64url_decode(anchor.signing_public_key, 32)
    agreement = strict_base64url_decode(anchor.agreement_public_key, 32)
    identity = MailboxIdentity(
        signing_public_key=signing,
        agreement_public_key=agreement,
        signing_key_id=key_id(b"ed25519", signing),
        agreement_key_id=key_id(b"x25519", agreement),
    )
    if (
        identity.signing_key_id != anchor.signing_key_id
        or identity.agreement_key_id != anchor.agreement_key_id
    ):
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    return identity


def anchor_for(stored: StoredMailboxKeys) -> ExpectedIdentityAnchor:
    identity = public_identity(stored)
    return ExpectedIdentityAnchor(
        agreement_key_id=identity.agreement_key_id,
        agreement_public_key=strict_base64url_encode(identity.agreement_public_key),
        continuity=stored.continuity,
        domain=anchor_domain(),
        generation=stored.generation,
        signing_key_id=identity.signing_key_id,
        signing_public_key=strict_base64url_encode(identity.signing_public_key),
        state=stored.state,
        v=1,
    )


def provisioning_for(anchor: ExpectedIdentityAnchor) -> ProvisioningAnchor:
    return ProvisioningAnchor(
        anchor_sha256=hashlib.sha256(canonical_model_bytes(anchor)).hexdigest(),
        domain=provisioning_domain(),
        expected=anchor,
        generation=anchor.generation,
        v=1,
    )


def signed_continuity(
    stored: StoredMailboxKeys,
    old: MailboxIdentity,
    new: MailboxIdentity,
) -> MailboxKeyContinuityRecord:
    unsigned = MailboxKeyContinuityRecord(
        agreement_new_public_key=strict_base64url_encode(new.agreement_public_key),
        agreement_old_public_key=strict_base64url_encode(old.agreement_public_key),
        domain=continuity_domain(),
        new_agreement_key_id=new.agreement_key_id,
        new_signing_key_id=new.signing_key_id,
        old_agreement_key_id=old.agreement_key_id,
        old_signing_key_id=old.signing_key_id,
        rotated_at_ms=time.time_ns() // 1_000_000,
        signature=strict_base64url_encode(bytes(64)),
        signing_new_public_key=strict_base64url_encode(new.signing_public_key),
        signing_old_public_key=strict_base64url_encode(old.signing_public_key),
        v=1,
    )
    private_key = strict_base64url_decode(stored.signing_private_key, 32)
    signature = Ed25519PrivateKey.from_private_bytes(private_key).sign(
        unsigned.signature_preimage()
    )
    record = unsigned.model_copy(
        update={"signature": strict_base64url_encode(signature)}
    )
    verify_mailbox_key_continuity(record)
    return record


def continuity_matches(
    record: MailboxKeyContinuityRecord,
    old: MailboxIdentity,
    new: MailboxIdentity,
) -> bool:
    return (
        record.old_signing_key_id == old.signing_key_id
        and record.old_agreement_key_id == old.agreement_key_id
        and record.new_signing_key_id == new.signing_key_id
        and record.new_agreement_key_id == new.agreement_key_id
        and strict_base64url_decode(record.signing_old_public_key, 32)
        == old.signing_public_key
        and strict_base64url_decode(record.agreement_old_public_key, 32)
        == old.agreement_public_key
        and strict_base64url_decode(record.signing_new_public_key, 32)
        == new.signing_public_key
        and strict_base64url_decode(record.agreement_new_public_key, 32)
        == new.agreement_public_key
    )


def public_summary(stored: StoredMailboxKeys) -> MailboxKeyLifecycleSummary:
    identity = public_identity(stored)
    return MailboxKeyLifecycleSummary(
        state=stored.state,
        signing_key_id=identity.signing_key_id,
        agreement_key_id=identity.agreement_key_id,
    )


def require_active_state(stored: StoredMailboxKeys) -> None:
    state = stored.state
    if state is MailboxKeyLifecycleState.ACTIVE:
        return
    if state is MailboxKeyLifecycleState.LOST:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    if state is MailboxKeyLifecycleState.REVOKED:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.KEYS_REVOKED)
    assert_never(state)


def parse_stored_keys(encoded: bytes) -> StoredMailboxKeys:
    try:
        parsed = StoredMailboxKeys.model_validate_json(encoded, strict=True)
    except (ValidationError, ValueError) as exc:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE) from exc
    if (
        canonical_model_bytes(parsed) != encoded
        or parsed.v != 1
        or parsed.generation < 1
    ):
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    _ = public_identity(parsed)
    if parsed.continuity is not None:
        verify_mailbox_key_continuity(parsed.continuity)
    return parsed


def parse_anchor(encoded: bytes) -> ExpectedIdentityAnchor:
    try:
        parsed = ExpectedIdentityAnchor.model_validate_json(encoded, strict=True)
    except (ValidationError, ValueError) as exc:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE) from exc
    if (
        canonical_model_bytes(parsed) != encoded
        or parsed.v != 1
        or parsed.domain != anchor_domain()
        or parsed.generation < 1
        or parsed.state is MailboxKeyLifecycleState.LOST
    ):
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    _ = identity_from_anchor(parsed)
    if parsed.continuity is not None:
        verify_mailbox_key_continuity(parsed.continuity)
    return parsed


def parse_provisioning(encoded: bytes) -> ProvisioningAnchor:
    try:
        parsed = ProvisioningAnchor.model_validate_json(encoded, strict=True)
    except (ValidationError, ValueError) as exc:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE) from exc
    if (
        canonical_model_bytes(parsed) != encoded
        or parsed.v != 1
        or parsed.domain != provisioning_domain()
        or parsed.generation < 1
        or parsed.expected.generation != parsed.generation
        or provisioning_for(parsed.expected) != parsed
        or len(parsed.anchor_sha256) != _SHA256_HEX_LENGTH
        or any(
            character not in "0123456789abcdef" for character in parsed.anchor_sha256
        )
    ):
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    return parsed

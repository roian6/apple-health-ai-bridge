from collections.abc import Callable
from pathlib import Path
from typing import Final, final

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)

from health_bridge.receiver._mailbox_key_crypto import (
    anchor_for,
    new_stored_keys,
    parse_anchor,
    parse_provisioning,
    parse_stored_keys,
    provisioning_for,
    public_identity,
    public_summary,
    require_active_state,
    signed_continuity,
)
from health_bridge.receiver._mailbox_key_files import (
    ANCHOR_FILE,
    IDENTITY_FILE,
    INITIALIZED_CONTENT,
    INITIALIZED_FILE,
    PROVISIONING_FILE,
    MailboxStorageLayout,
    read_private_bytes,
    state_presence,
    write_private_bytes,
)
from health_bridge.receiver._mailbox_key_models import (
    ExpectedIdentityAnchor,
    MailboxIdentity,
    MailboxKeyBackupPolicy,
    MailboxKeyContinuityRecord,
    MailboxKeyLifecycleState,
    MailboxKeyLifecycleSummary,
    MailboxKeyRotation,
    MailboxKeyStoreError,
    MailboxKeyStoreErrorCode,
    MailboxPrivateIdentity,
    ProvisioningAnchor,
    StoredMailboxKeys,
    canonical_model_bytes,
    strict_base64url_decode,
    verify_mailbox_key_continuity,
)
from health_bridge.receiver._mailbox_key_reconcile import required_reconciliation

_PRIVATE_KEY_BYTES: Final = 32
_LOSS_ERRORS: Final = frozenset({MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST})


@final
class MailboxKeyStore:
    backup_policy: Final[MailboxKeyBackupPolicy] = "local_explicit_backup_only"

    def __init__(self, *, layout: MailboxStorageLayout) -> None:
        self._layout = layout

    @classmethod
    def production(cls) -> "MailboxKeyStore":
        return cls(layout=MailboxStorageLayout.production())

    @classmethod
    def for_testing(
        cls,
        *,
        state_dir: Path,
        anchor_dir: Path,
        transaction_barrier: Callable[[], int] | None = None,
        filesystem_kind: str = "local",
    ) -> "MailboxKeyStore":
        return cls(
            layout=MailboxStorageLayout.for_testing(
                state_dir=state_dir,
                anchor_dir=anchor_dir,
                filesystem_kind=filesystem_kind,
                transaction_barrier=transaction_barrier,
            )
        )

    def load_or_create(self) -> MailboxIdentity:
        with self._layout.transaction():
            stored, anchor, provisioning = self._load_state()
            if stored is None:
                if anchor is not None or provisioning is not None:
                    raise MailboxKeyStoreError(
                        MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST
                    )
                created = new_stored_keys()
                self._write_marker()
                self._write_stored_keys(created)
                anchor = anchor_for(created)
                self._write_anchor(anchor)
                self._write_provisioning(provisioning_for(anchor))
                return public_identity(created)
            if anchor is None or provisioning is None:
                raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST)
            self._reconcile(stored, anchor, provisioning)
            require_active_state(stored)
            return public_identity(stored)

    def public_summary(self) -> MailboxKeyLifecycleSummary:
        with self._layout.transaction():
            try:
                stored, anchor, provisioning = self._load_state()
            except MailboxKeyStoreError as exc:
                if exc.code not in _LOSS_ERRORS:
                    raise
                return MailboxKeyLifecycleSummary(state=MailboxKeyLifecycleState.LOST)
            if stored is None:
                return MailboxKeyLifecycleSummary(state=MailboxKeyLifecycleState.LOST)
            if anchor is None or provisioning is None:
                return MailboxKeyLifecycleSummary(state=MailboxKeyLifecycleState.LOST)
            self._reconcile(stored, anchor, provisioning)
            return public_summary(stored)

    def sign(self, message: bytes) -> bytes:
        with self._layout.transaction():
            stored = self._active_stored_keys()
            return Ed25519PrivateKey.from_private_bytes(
                strict_base64url_decode(stored.signing_private_key, _PRIVATE_KEY_BYTES)
            ).sign(message)

    def exchange(self, peer_public_key: bytes) -> bytes:
        with self._layout.transaction():
            stored = self._active_stored_keys()
            try:
                peer = X25519PublicKey.from_public_bytes(peer_public_key)
                return X25519PrivateKey.from_private_bytes(
                    strict_base64url_decode(
                        stored.agreement_private_key, _PRIVATE_KEY_BYTES
                    )
                ).exchange(peer)
            except ValueError as exc:
                raise MailboxKeyStoreError(
                    MailboxKeyStoreErrorCode.MALFORMED_STATE
                ) from exc

    def private_identity(self) -> MailboxPrivateIdentity:
        with self._layout.transaction():
            stored = self._active_stored_keys()
            signing = strict_base64url_decode(
                stored.signing_private_key, _PRIVATE_KEY_BYTES
            )
            agreement = strict_base64url_decode(
                stored.agreement_private_key, _PRIVATE_KEY_BYTES
            )
            return MailboxPrivateIdentity(
                signing_private_key=Ed25519PrivateKey.from_private_bytes(signing),
                agreement_private_key=X25519PrivateKey.from_private_bytes(agreement),
            )

    def revoke(self) -> MailboxKeyLifecycleSummary:
        with self._layout.transaction():
            stored = self._active_stored_keys()
            revoked = stored.model_copy(
                update={
                    "generation": stored.generation + 1,
                    "state": MailboxKeyLifecycleState.REVOKED,
                }
            )
            self._write_transition(revoked)
            return public_summary(revoked)

    def rotate(self, *, expected_signing_key_id: str) -> MailboxKeyRotation:
        with self._layout.transaction():
            stored = self._active_stored_keys()
            old_identity = public_identity(stored)
            if old_identity.signing_key_id != expected_signing_key_id:
                raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.STALE_IDENTITY)
            replacement = new_stored_keys(generation=stored.generation + 1)
            new_identity = public_identity(replacement)
            continuity = signed_continuity(stored, old_identity, new_identity)
            replacement = replacement.model_copy(update={"continuity": continuity})
            self._write_transition(replacement)
            return MailboxKeyRotation(identity=new_identity, continuity=continuity)

    def _active_stored_keys(self) -> StoredMailboxKeys:
        stored, anchor, provisioning = self._load_state()
        if stored is None or anchor is None or provisioning is None:
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST)
        self._reconcile(stored, anchor, provisioning)
        require_active_state(stored)
        return stored

    def _load_state(
        self,
    ) -> tuple[
        StoredMailboxKeys | None,
        ExpectedIdentityAnchor | None,
        ProvisioningAnchor | None,
    ]:
        identity_exists, marker_exists, anchor_exists, provisioning_exists = (
            state_presence(self._layout)
        )
        if identity_exists != marker_exists:
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST)
        if len({identity_exists, anchor_exists, provisioning_exists}) != 1:
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST)
        stored = self._read_stored_keys() if identity_exists else None
        anchor = self._read_anchor() if anchor_exists else None
        provisioning = self._read_provisioning() if provisioning_exists else None
        return stored, anchor, provisioning

    def _read_stored_keys(self) -> StoredMailboxKeys:
        marker = read_private_bytes(self._layout.state_dir / INITIALIZED_FILE)
        if marker != INITIALIZED_CONTENT:
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
        encoded = read_private_bytes(self._layout.state_dir / IDENTITY_FILE)
        return parse_stored_keys(encoded)

    def _read_anchor(self) -> ExpectedIdentityAnchor:
        encoded = read_private_bytes(self._layout.anchor_dir / ANCHOR_FILE)
        return parse_anchor(encoded)

    def _read_provisioning(self) -> ProvisioningAnchor:
        encoded = read_private_bytes(self._layout.provisioning_dir / PROVISIONING_FILE)
        return parse_provisioning(encoded)

    def _reconcile(
        self,
        stored: StoredMailboxKeys,
        anchor: ExpectedIdentityAnchor,
        provisioning: ProvisioningAnchor,
    ) -> None:
        writes = required_reconciliation(stored, anchor, provisioning)
        if writes.anchor is not None:
            self._write_anchor(writes.anchor)
        if writes.provisioning is not None:
            self._write_provisioning(writes.provisioning)

    def _write_marker(self) -> None:
        write_private_bytes(
            self._layout.state_dir / INITIALIZED_FILE, INITIALIZED_CONTENT
        )

    def _write_stored_keys(self, stored: StoredMailboxKeys) -> None:
        write_private_bytes(
            self._layout.state_dir / IDENTITY_FILE,
            canonical_model_bytes(stored),
        )

    def _write_anchor(self, anchor: ExpectedIdentityAnchor) -> None:
        write_private_bytes(
            self._layout.anchor_dir / ANCHOR_FILE,
            canonical_model_bytes(anchor),
        )

    def _write_provisioning(self, provisioning: ProvisioningAnchor) -> None:
        write_private_bytes(
            self._layout.provisioning_dir / PROVISIONING_FILE,
            canonical_model_bytes(provisioning),
        )

    def _write_transition(self, stored: StoredMailboxKeys) -> None:
        anchor = anchor_for(stored)
        self._write_stored_keys(stored)
        self._write_anchor(anchor)
        self._write_provisioning(provisioning_for(anchor))


__all__ = [
    "MailboxIdentity",
    "MailboxKeyContinuityRecord",
    "MailboxKeyLifecycleState",
    "MailboxKeyLifecycleSummary",
    "MailboxKeyRotation",
    "MailboxKeyStore",
    "MailboxKeyStoreError",
    "MailboxKeyStoreErrorCode",
    "verify_mailbox_key_continuity",
]

from __future__ import annotations

import fcntl
import os
import re
import stat
from enum import StrEnum
from typing import TYPE_CHECKING, Annotated, ClassVar, Final, Literal, final

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StrictBool,
    StrictInt,
    StrictStr,
    ValidationError,
)
from typing_extensions import override

from health_bridge.contract._delivery_common import key_id
from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    JsonValue,
    hbjcs1_decode,
    hbjcs1_encode,
)
from health_bridge.contract.delivery_v1 import (
    DeliveryProtocolError,
    DevicePrincipal,
    OpaqueBinding,
)
from health_bridge.private_files import ensure_private_file, write_private_text_file
from health_bridge.receiver._mailbox_key_files import read_private_bytes
from health_bridge.receiver._mailbox_key_models import (
    MailboxKeyStoreError,
    strict_base64url_decode,
    strict_base64url_encode,
)
from health_bridge.receiver._mailbox_key_policy import (
    FilesystemKind,
    application_support_root,
    filesystem_kind,
    reject_prohibited_path,
)
from health_bridge.receiver.delivery_acceptance import DeliveryTrustedConnection
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.tokens import ReceiverTokenPrincipal

if TYPE_CHECKING:
    from pathlib import Path

_OPAQUE_COMPONENT: Final[re.Pattern[str]] = re.compile(r"^[0-9a-f]{32}$")
_BASE64URL_32: Final[re.Pattern[str]] = re.compile(r"^[A-Za-z0-9_-]{43}$")
_HASH: Final[re.Pattern[str]] = re.compile(r"^[0-9a-f]{64}$")


class MailboxConnectionErrorCode(StrEnum):
    UNAVAILABLE = "connection_unavailable"
    MALFORMED = "connection_malformed"
    UNSAFE_STORAGE = "connection_storage_unsafe"
    CONFLICT = "connection_conflict"


@final
class MailboxConnectionError(Exception):
    def __init__(self, code: MailboxConnectionErrorCode) -> None:
        super().__init__(code.value)
        self.code = code

    @override
    def __str__(self) -> str:
        return self.code.value


class MailboxTrustedConnectionRecord(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    v: Literal[1] = 1
    kind: Literal["mailbox_trusted_connection"] = "mailbox_trusted_connection"
    receiver_id: StrictStr
    device_id: StrictStr
    connection_generation: Annotated[StrictInt, Field(ge=0, le=(2**63) - 1)]
    device_principal: StrictStr
    opaque_binding: StrictStr
    device_signing_key_id: StrictStr
    device_agreement_key_id: StrictStr
    receiver_signing_key_id: StrictStr
    receiver_agreement_key_id: StrictStr
    sender_signing_public_key: StrictStr
    device_agreement_public_key: StrictStr
    installation_id_hash: StrictStr | None
    sender_key_revoked: StrictBool = False

    def to_bytes(self) -> bytes:
        document: dict[str, JsonValue] = {
            "v": self.v,
            "kind": self.kind,
            "receiver_id": self.receiver_id,
            "device_id": self.device_id,
            "connection_generation": self.connection_generation,
            "device_principal": self.device_principal,
            "opaque_binding": self.opaque_binding,
            "device_signing_key_id": self.device_signing_key_id,
            "device_agreement_key_id": self.device_agreement_key_id,
            "receiver_signing_key_id": self.receiver_signing_key_id,
            "receiver_agreement_key_id": self.receiver_agreement_key_id,
            "sender_signing_public_key": self.sender_signing_public_key,
            "device_agreement_public_key": self.device_agreement_public_key,
            "installation_id_hash": self.installation_id_hash,
            "sender_key_revoked": self.sender_key_revoked,
        }
        return hbjcs1_encode(document)


@final
class MailboxConnectionStore:
    def __init__(self, root: Path, key_store: MailboxKeyStore) -> None:
        self._root = root
        self._key_store = key_store

    @classmethod
    def production(cls) -> MailboxConnectionStore:
        return cls(
            application_support_root() / "Receiver" / "MailboxConnections",
            MailboxKeyStore.production(),
        )

    @classmethod
    def for_testing(
        cls,
        root: Path,
        key_store: MailboxKeyStore,
    ) -> MailboxConnectionStore:
        return cls(root, key_store)

    def save(self, record: MailboxTrustedConnectionRecord) -> None:
        self._validate_record(record)
        self._require_local_root()
        path = self._record_path(record.receiver_id, record.device_id)
        descriptor = -1
        try:
            encoded = record.to_bytes()
            descriptor = _acquire_connection_record_lock(
                self._root / ".connection-records.lock"
            )
            if path.exists():
                if read_private_bytes(path) == encoded:
                    return
                raise MailboxConnectionError(MailboxConnectionErrorCode.CONFLICT)
            write_private_text_file(path, encoded.decode("ascii"))
        except (OSError, UnicodeDecodeError) as exc:
            raise MailboxConnectionError(
                MailboxConnectionErrorCode.UNSAFE_STORAGE
            ) from exc
        finally:
            if descriptor >= 0:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)

    def load(self, mailbox_path: Path) -> DeliveryTrustedConnection:
        receiver_id = mailbox_path.parent.name
        device_id = mailbox_path.name
        self._require_components(receiver_id, device_id)
        self._require_local_root()
        try:
            encoded = read_private_bytes(self._record_path(receiver_id, device_id))
            decoded = hbjcs1_decode(encoded)
            record = MailboxTrustedConnectionRecord.model_validate(decoded)
            self._validate_record(record)
            private = self._key_store.private_identity()
            sender_public = Ed25519PublicKey.from_public_bytes(
                strict_base64url_decode(record.sender_signing_public_key, 32)
            )
            device_agreement = X25519PublicKey.from_public_bytes(
                strict_base64url_decode(record.device_agreement_public_key, 32)
            )
        except FileNotFoundError as exc:
            raise MailboxConnectionError(
                MailboxConnectionErrorCode.UNAVAILABLE
            ) from exc
        except (
            HBJCS1Error,
            MailboxKeyStoreError,
            OSError,
            ValidationError,
            ValueError,
        ) as exc:
            raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED) from exc
        if record.receiver_id != receiver_id or record.device_id != device_id:
            raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED)
        if (
            key_id(
                "ed25519",
                private.signing_private_key.public_key().public_bytes_raw(),
            )
            != record.receiver_signing_key_id
            or key_id(
                "x25519",
                private.agreement_private_key.public_key().public_bytes_raw(),
            )
            != record.receiver_agreement_key_id
        ):
            raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED)
        return DeliveryTrustedConnection(
            receiver_id=bytes.fromhex(record.receiver_id),
            device_id=bytes.fromhex(record.device_id),
            connection_generation=record.connection_generation,
            device_principal=DevicePrincipal(record.device_principal),
            opaque_binding=OpaqueBinding(
                strict_base64url_decode(record.opaque_binding, 32)
            ),
            receiver_agreement_private_key=private.agreement_private_key,
            sender_signing_public_key=sender_public,
            device_agreement_public_key=device_agreement,
            receiver_signing_private_key=private.signing_private_key,
            source_principal=ReceiverTokenPrincipal(
                installation_id_hash=record.installation_id_hash
            ),
            sender_key_revoked=record.sender_key_revoked,
        )

    def lock_path(self, mailbox_path: Path) -> Path:
        receiver_id = mailbox_path.parent.name
        device_id = mailbox_path.name
        self._require_components(receiver_id, device_id)
        return self._root / f"{receiver_id}.{device_id}.import.lock"

    def _validate_record(self, record: MailboxTrustedConnectionRecord) -> None:
        self._require_components(record.receiver_id, record.device_id)
        try:
            _ = DevicePrincipal(record.device_principal)
            _ = strict_base64url_decode(record.opaque_binding, 32)
            sender = strict_base64url_decode(record.sender_signing_public_key, 32)
            agreement = strict_base64url_decode(
                record.device_agreement_public_key,
                32,
            )
        except (DeliveryProtocolError, MailboxKeyStoreError, ValueError) as exc:
            raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED) from exc
        if (
            _BASE64URL_32.fullmatch(record.opaque_binding) is None
            or _BASE64URL_32.fullmatch(record.sender_signing_public_key) is None
            or _BASE64URL_32.fullmatch(record.device_agreement_public_key) is None
            or _OPAQUE_COMPONENT.fullmatch(record.device_signing_key_id) is None
            or _OPAQUE_COMPONENT.fullmatch(record.device_agreement_key_id) is None
            or _OPAQUE_COMPONENT.fullmatch(record.receiver_signing_key_id) is None
            or _OPAQUE_COMPONENT.fullmatch(record.receiver_agreement_key_id) is None
            or (
                record.installation_id_hash is not None
                and _HASH.fullmatch(record.installation_id_hash) is None
            )
            or key_id("ed25519", sender) != record.device_signing_key_id
            or key_id("x25519", agreement) != record.device_agreement_key_id
        ):
            raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED)

    def _require_local_root(self) -> None:
        try:
            reject_prohibited_path(self._root)
            if filesystem_kind(self._root) is not FilesystemKind.LOCAL:
                raise MailboxConnectionError(MailboxConnectionErrorCode.UNSAFE_STORAGE)
        except MailboxKeyStoreError as exc:
            raise MailboxConnectionError(
                MailboxConnectionErrorCode.UNSAFE_STORAGE
            ) from exc

    def _record_path(self, receiver_id: str, device_id: str) -> Path:
        return self._root / f"{receiver_id}.{device_id}.hbjcs1"

    @staticmethod
    def _require_components(receiver_id: str, device_id: str) -> None:
        if (
            _OPAQUE_COMPONENT.fullmatch(receiver_id) is None
            or _OPAQUE_COMPONENT.fullmatch(device_id) is None
        ):
            raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED)


def _acquire_connection_record_lock(path: Path) -> int:
    _ = ensure_private_file(path)
    descriptor = os.open(
        path,
        os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
    )
    opened = os.fstat(descriptor)
    current = path.lstat()
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
    ):
        os.close(descriptor)
        raise OSError
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
    except OSError:
        os.close(descriptor)
        raise
    return descriptor


__all__ = [
    "MailboxConnectionError",
    "MailboxConnectionErrorCode",
    "MailboxConnectionStore",
    "MailboxTrustedConnectionRecord",
    "strict_base64url_encode",
]

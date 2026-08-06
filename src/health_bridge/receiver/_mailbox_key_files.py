import fcntl
import os
import stat
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from types import TracebackType
from typing import Final, Literal, assert_never, final

from health_bridge.private_files import (
    PRIVATE_DIRECTORY_MODE,
    PRIVATE_FILE_MODE,
    ensure_private_directory,
    write_private_text_file,
)
from health_bridge.receiver._mailbox_key_models import (
    MailboxKeyStoreError,
    MailboxKeyStoreErrorCode,
)
from health_bridge.receiver._mailbox_key_policy import (
    FilesystemKind,
    application_support_root,
    filesystem_kind,
    reject_prohibited_path,
)

MAX_STATE_BYTES: Final = 4096
IDENTITY_FILE: Final = "mailbox-identity.json"
INITIALIZED_FILE: Final = "mailbox-store.initialized"
ANCHOR_FILE: Final = "mailbox-expected-identity.json"
PROVISIONING_FILE: Final = "mailbox-provisioning-anchor.json"
LOCK_FILE: Final = "mailbox-identity.lock"
INITIALIZED_CONTENT: Final = b"health-bridge-mailbox-keys-v1\n"


@dataclass(frozen=True, slots=True)
class MailboxStorageLayout:
    state_dir: Path
    anchor_dir: Path
    provisioning_dir: Path
    filesystem_kind: FilesystemKind
    transaction_barrier: Callable[[], int] | None = None

    @classmethod
    def production(cls) -> "MailboxStorageLayout":
        root = application_support_root()
        return cls(
            state_dir=root / "Receiver" / "MailboxKeys",
            anchor_dir=root.parent / "HealthBridgeIdentityAnchor",
            provisioning_dir=root.parent / "HealthBridgeIdentityGeneration",
            filesystem_kind=filesystem_kind(root),
        )

    @classmethod
    def for_testing(
        cls,
        *,
        state_dir: Path,
        anchor_dir: Path,
        filesystem_kind: str,
        transaction_barrier: Callable[[], int] | None,
    ) -> "MailboxStorageLayout":
        try:
            kind = FilesystemKind(filesystem_kind)
        except ValueError as exc:
            raise MailboxKeyStoreError(
                MailboxKeyStoreErrorCode.PROHIBITED_STORAGE
            ) from exc
        return cls(
            state_dir=state_dir,
            anchor_dir=anchor_dir,
            provisioning_dir=anchor_dir.parent / f"{anchor_dir.name}.provisioning",
            filesystem_kind=kind,
            transaction_barrier=transaction_barrier,
        )

    def validate_policy(self) -> None:
        for path in (self.state_dir, self.anchor_dir, self.provisioning_dir):
            reject_prohibited_path(path)
        kind = self.filesystem_kind
        if kind is FilesystemKind.LOCAL:
            return
        if kind is FilesystemKind.NETWORK or kind is FilesystemKind.UNKNOWN:
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.PROHIBITED_STORAGE)
        assert_never(kind)

    def prepare_directory(self, directory: Path) -> None:
        self.validate_policy()
        existed = directory.exists()
        try:
            ensure_private_directory(directory)
        except PermissionError as exc:
            raise MailboxKeyStoreError(
                MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS
            ) from exc
        except OSError as exc:
            if directory.is_dir() and not directory.is_symlink():
                reject_prohibited_path(directory)
            else:
                raise MailboxKeyStoreError(
                    MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
                ) from exc
        try:
            mode = stat.S_IMODE(directory.lstat().st_mode)
            has_entries = any(directory.iterdir())
        except OSError as exc:
            raise MailboxKeyStoreError(
                MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
            ) from exc
        if existed and has_entries and mode != PRIVATE_DIRECTORY_MODE:
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS)
        try:
            directory.chmod(PRIVATE_DIRECTORY_MODE)
        except OSError as exc:
            raise MailboxKeyStoreError(
                MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
            ) from exc

    def transaction(self) -> "MailboxStorageTransaction":
        return MailboxStorageTransaction(self)


@final
class MailboxStorageTransaction:
    def __init__(self, layout: MailboxStorageLayout) -> None:
        self._layout = layout
        self._fd = -1

    def __enter__(self) -> None:
        if self._layout.transaction_barrier is not None:
            _ = self._layout.transaction_barrier()
        self._layout.prepare_directory(self._layout.anchor_dir)
        lock_path = self._layout.anchor_dir / LOCK_FILE
        lock_existed = lock_path.exists()
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        try:
            self._fd = os.open(lock_path, flags, PRIVATE_FILE_MODE)
            opened = os.fstat(self._fd)
        except OSError as exc:
            self._close()
            raise MailboxKeyStoreError(
                MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
            ) from exc
        owner_matches = not hasattr(os, "geteuid") or opened.st_uid == os.geteuid()
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or not owner_matches
            or (lock_existed and stat.S_IMODE(opened.st_mode) != PRIVATE_FILE_MODE)
        ):
            self._close()
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS)
        try:
            os.fchmod(self._fd, PRIVATE_FILE_MODE)
            fcntl.flock(self._fd, fcntl.LOCK_EX)
            self._layout.prepare_directory(self._layout.state_dir)
            self._layout.prepare_directory(self._layout.provisioning_dir)
        except MailboxKeyStoreError:
            self._close()
            raise
        except OSError as exc:
            self._close()
            raise MailboxKeyStoreError(
                MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
            ) from exc

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> Literal[False]:
        self._close()
        return False

    def _close(self) -> None:
        if self._fd < 0:
            return
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)
            self._fd = -1


def state_presence(layout: MailboxStorageLayout) -> tuple[bool, bool, bool, bool]:
    identity = layout.state_dir / IDENTITY_FILE
    marker = layout.state_dir / INITIALIZED_FILE
    anchor = layout.anchor_dir / ANCHOR_FILE
    provisioning = layout.provisioning_dir / PROVISIONING_FILE
    for path in (identity, marker, anchor, provisioning):
        if path.is_symlink():
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS)
    return identity.exists(), marker.exists(), anchor.exists(), provisioning.exists()


def read_private_bytes(path: Path) -> bytes:
    try:
        entry = path.lstat()
    except OSError as exc:
        raise MailboxKeyStoreError(
            MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
        ) from exc
    owner_matches = not hasattr(os, "geteuid") or entry.st_uid == os.geteuid()
    if (
        not stat.S_ISREG(entry.st_mode)
        or stat.S_IMODE(entry.st_mode) != PRIVATE_FILE_MODE
        or entry.st_nlink != 1
        or not owner_matches
    ):
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS)
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino) != (entry.st_dev, entry.st_ino):
                raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS)
            data = os.read(fd, MAX_STATE_BYTES + 1)
        finally:
            os.close(fd)
    except MailboxKeyStoreError:
        raise
    except OSError as exc:
        raise MailboxKeyStoreError(
            MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
        ) from exc
    if len(data) > MAX_STATE_BYTES:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    return data


def write_private_bytes(path: Path, content: bytes) -> None:
    try:
        write_private_text_file(path, content.decode("ascii"))
    except (OSError, UnicodeDecodeError) as exc:
        raise MailboxKeyStoreError(
            MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
        ) from exc

from __future__ import annotations

import ctypes
import errno
import hashlib
import os
import secrets
import stat
import sys
from contextlib import suppress
from enum import StrEnum
from typing import TYPE_CHECKING, Final, cast

from health_bridge.contract._delivery_common import MAX_ACK_BYTES
from health_bridge.contract._hbjcs1 import hbjcs1_encode
from health_bridge.mailbox.filesystem import (
    FileIdentity,
    MailboxFileError,
    MailboxFileErrorCode,
    exact_temp_final,
    file_identity,
    open_directory,
    read_final,
    read_final_at,
    revalidate_final,
    revalidate_final_at,
    unlink_same,
    unlink_same_at,
)
from health_bridge.mailbox.models import (
    MailboxImportFaultHook,
    MailboxImportFaultPoint,
)

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

ACK_RETENTION_MS: Final = 30 * 86_400_000
DELIVERY_RETENTION_MS: Final = 7 * 86_400_000
TEMP_RETENTION_MS: Final = 86_400_000
QUARANTINE_RETENTION_MS: Final = 30 * 86_400_000
MAX_QUARANTINE_ENTRIES: Final = 1_000
MAX_QUARANTINE_BYTES: Final = 64 * 1024 * 1024
_FINAL_FILE_MODE: Final = 0o600
_PARTIAL_FINAL_LINK_COUNT: Final = 2


class PublicationState(StrEnum):
    CREATED = "created"
    IDENTICAL = "identical"
    CONFLICT = "conflict"


def publish_final(
    directory: Path,
    final_name: str,
    content: bytes,
    fault_hook: MailboxImportFaultHook | None = None,
) -> PublicationState:
    final_path = directory / final_name
    existing = _existing_bytes(final_path)
    if existing is not None:
        return (
            PublicationState.IDENTICAL
            if existing == content
            else PublicationState.CONFLICT
        )
    directory_fd = open_directory(directory)
    temp_name = f"{final_name}.{secrets.token_hex(16)}.tmp"
    descriptor = -1
    preserve_temp = False
    try:
        descriptor = os.open(
            temp_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            _FINAL_FILE_MODE,
            dir_fd=directory_fd,
        )
        os.fchmod(descriptor, _FINAL_FILE_MODE)
        offset = 0
        while offset < len(content):
            written = os.write(descriptor, content[offset:])
            if written <= 0:
                raise OSError(errno.ENOSPC, "mailbox publication failed")
            offset += written
        with suppress(OSError):
            os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        try:
            _fault(fault_hook, MailboxImportFaultPoint.BEFORE_ACK_RENAME)
        except RuntimeError:
            preserve_temp = True
            raise
        try:
            _exclusive_finalize(directory_fd, temp_name, final_name)
        except FileExistsError:
            existing = _existing_bytes(final_path)
            return (
                PublicationState.IDENTICAL
                if existing == content
                else PublicationState.CONFLICT
            )
        temp_name = ""
        _fault(fault_hook, MailboxImportFaultPoint.AFTER_ACK_RENAME)
        return PublicationState.CREATED
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temp_name and not preserve_temp:
            with suppress(FileNotFoundError):
                os.unlink(temp_name, dir_fd=directory_fd)
        os.close(directory_fd)


def publish_quarantine(
    directory: Path,
    source_name: str,
    reason: str,
) -> PublicationState:
    marker_id = hashlib.sha256(source_name.encode("utf-8")).digest()[:16].hex()
    content = hbjcs1_encode({"v": 1, "kind": "quarantine", "reason": reason})
    return publish_final(directory, f"{marker_id}.hbq", content)


def publish_final_at(
    directory_fd: int,
    final_name: str,
    content: bytes,
    fault_hook: MailboxImportFaultHook | None = None,
    before_mutation: Callable[[], None] | None = None,
) -> PublicationState:
    existing = _existing_bytes_at(
        directory_fd,
        final_name,
        before_mutation=before_mutation,
    )
    if existing is not None:
        return (
            PublicationState.IDENTICAL
            if existing == content
            else PublicationState.CONFLICT
        )
    temp_name = f"{final_name}.{secrets.token_hex(16)}.tmp"
    descriptor = -1
    preserve_temp = False
    try:
        _validate(before_mutation)
        descriptor = os.open(
            temp_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            _FINAL_FILE_MODE,
            dir_fd=directory_fd,
        )
        _validate(before_mutation)
        os.fchmod(descriptor, _FINAL_FILE_MODE)
        offset = 0
        while offset < len(content):
            _validate(before_mutation)
            written = os.write(descriptor, content[offset:])
            if written <= 0:
                raise OSError(errno.ENOSPC, "mailbox publication failed")
            offset += written
        with suppress(OSError):
            _validate(before_mutation)
            os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        try:
            _fault(fault_hook, MailboxImportFaultPoint.BEFORE_ACK_RENAME)
        except RuntimeError:
            preserve_temp = True
            raise
        try:
            _validate(before_mutation)
            _exclusive_finalize(
                directory_fd,
                temp_name,
                final_name,
                before_mutation=before_mutation,
            )
        except FileExistsError:
            existing = _existing_bytes_at(
                directory_fd,
                final_name,
                before_mutation=before_mutation,
            )
            return (
                PublicationState.IDENTICAL
                if existing == content
                else PublicationState.CONFLICT
            )
        temp_name = ""
        _fault(fault_hook, MailboxImportFaultPoint.AFTER_ACK_RENAME)
        return PublicationState.CREATED
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temp_name and not preserve_temp:
            try:
                temp_identity = file_identity(
                    os.stat(temp_name, dir_fd=directory_fd, follow_symlinks=False)
                )
            except FileNotFoundError:
                pass
            else:
                _ = unlink_same_at(
                    directory_fd,
                    temp_name,
                    temp_identity,
                    before_unlink=before_mutation,
                )


def publish_quarantine_at(
    directory_fd: int,
    source_name: str,
    reason: str,
    *,
    before_mutation: Callable[[], None] | None = None,
) -> PublicationState:
    marker_id = hashlib.sha256(source_name.encode("utf-8")).digest()[:16].hex()
    content = hbjcs1_encode({"v": 1, "kind": "quarantine", "reason": reason})
    return publish_final_at(
        directory_fd,
        f"{marker_id}.hbq",
        content,
        before_mutation=before_mutation,
    )


def cleanup_stale_temps_at(
    directory_fd: int,
    *,
    now_ms: int,
    fault_hook: MailboxImportFaultHook | None = None,
    before_mutation: Callable[[], None] | None = None,
) -> None:
    for name in sorted(entry.name for entry in os.scandir(directory_fd)):
        final_name = exact_temp_final(name)
        if final_name is None:
            continue
        try:
            metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError:
            continue
        identity = file_identity(metadata)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or now_ms - metadata.st_mtime_ns // 1_000_000 < TEMP_RETENTION_MS
            or _entry_exists(directory_fd, final_name)
        ):
            continue
        _fault(fault_hook, MailboxImportFaultPoint.BEFORE_CLEANUP_UNLINK)
        if revalidate_final_at(directory_fd, name, identity):
            _ = unlink_same_at(
                directory_fd,
                name,
                identity,
                before_unlink=before_mutation,
            )


def cleanup_expired_finals_at(
    directory_fd: int,
    *,
    extension: str,
    retention_ms: int,
    now_ms: int,
    before_mutation: Callable[[], None] | None = None,
) -> None:
    suffix = f".{extension}"
    for name in sorted(entry.name for entry in os.scandir(directory_fd)):
        if not name.endswith(suffix):
            continue
        _unlink_if_expired_at(
            directory_fd,
            name,
            now_ms=now_ms,
            retention_ms=retention_ms,
            before_mutation=before_mutation,
        )


def cleanup_quarantine_at(
    directory_fd: int,
    *,
    now_ms: int,
    before_mutation: Callable[[], None] | None = None,
) -> None:
    retained: list[tuple[int, str, FileIdentity]] = []
    total_bytes = 0
    for name in sorted(
        entry.name for entry in os.scandir(directory_fd) if entry.name.endswith(".hbq")
    ):
        try:
            metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError:
            continue
        identity = file_identity(metadata)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            continue
        age_ms = now_ms - metadata.st_mtime_ns // 1_000_000
        if age_ms >= QUARANTINE_RETENTION_MS:
            _ = unlink_same_at(
                directory_fd,
                name,
                identity,
                before_unlink=before_mutation,
            )
            continue
        retained.append((metadata.st_mtime_ns, name, identity))
        total_bytes += metadata.st_size
    retained.sort()
    while len(retained) > MAX_QUARANTINE_ENTRIES or total_bytes > MAX_QUARANTINE_BYTES:
        _, name, identity = retained.pop(0)
        if unlink_same_at(
            directory_fd,
            name,
            identity,
            before_unlink=before_mutation,
        ):
            total_bytes -= identity.size


def cleanup_stale_temps(
    directory: Path,
    *,
    now_ms: int,
    fault_hook: MailboxImportFaultHook | None = None,
) -> None:
    for path in sorted(directory.iterdir(), key=lambda item: item.name):
        final_name = exact_temp_final(path.name)
        if final_name is None:
            continue
        try:
            metadata = path.lstat()
        except OSError:
            continue
        identity = file_identity(metadata)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or now_ms - metadata.st_mtime_ns // 1_000_000 < TEMP_RETENTION_MS
            or (directory / final_name).exists()
            or (directory / final_name).is_symlink()
        ):
            continue
        _fault(fault_hook, MailboxImportFaultPoint.BEFORE_CLEANUP_UNLINK)
        if revalidate_final(path, identity):
            _ = unlink_same(path, identity)


def cleanup_expired_finals(
    directory: Path,
    *,
    extension: str,
    retention_ms: int,
    now_ms: int,
) -> None:
    suffix = f".{extension}"
    for path in sorted(directory.iterdir(), key=lambda item: item.name):
        if not path.name.endswith(suffix):
            continue
        _unlink_if_expired(path, now_ms=now_ms, retention_ms=retention_ms)


def cleanup_quarantine(directory: Path, *, now_ms: int) -> None:
    retained: list[tuple[int, str, Path, FileIdentity]] = []
    total_bytes = 0
    for path in sorted(directory.glob("*.hbq"), key=lambda item: item.name):
        try:
            metadata = path.lstat()
        except OSError:
            continue
        identity = file_identity(metadata)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            continue
        age_ms = now_ms - metadata.st_mtime_ns // 1_000_000
        if age_ms >= QUARANTINE_RETENTION_MS:
            _ = unlink_same(path, identity)
            continue
        retained.append((metadata.st_mtime_ns, path.name, path, identity))
        total_bytes += metadata.st_size
    retained.sort()
    while len(retained) > MAX_QUARANTINE_ENTRIES or total_bytes > MAX_QUARANTINE_BYTES:
        _, _, path, identity = retained.pop(0)
        if unlink_same(path, identity):
            total_bytes -= identity.size


def _existing_bytes_at(
    directory_fd: int,
    name: str,
    *,
    before_mutation: Callable[[], None] | None = None,
) -> bytes | None:
    try:
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if metadata.st_nlink == _PARTIAL_FINAL_LINK_COUNT:
        recovered = _recover_partial_finalize_at(
            directory_fd,
            name,
            before_mutation=before_mutation,
        )
        if not recovered:
            raise OSError(errno.EAGAIN, "mailbox publication recovery pending")
    try:
        return read_final_at(directory_fd, name, maximum_bytes=MAX_ACK_BYTES).content
    except MailboxFileError as exc:
        if exc.code is MailboxFileErrorCode.STORAGE_UNAVAILABLE:
            return None
        return b""


def _recover_partial_finalize_at(
    directory_fd: int,
    final_name: str,
    *,
    before_mutation: Callable[[], None] | None,
) -> bool:
    try:
        final_stat = os.stat(
            final_name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
    except OSError:
        return False
    if (
        not stat.S_ISREG(final_stat.st_mode)
        or final_stat.st_nlink != _PARTIAL_FINAL_LINK_COUNT
    ):
        return False
    matching_temps: list[tuple[str, FileIdentity]] = []
    with os.scandir(directory_fd) as entries:
        for entry in entries:
            if exact_temp_final(entry.name) != final_name:
                continue
            try:
                candidate = os.stat(
                    entry.name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
            except OSError:
                continue
            if (
                stat.S_ISREG(candidate.st_mode)
                and candidate.st_dev == final_stat.st_dev
                and candidate.st_ino == final_stat.st_ino
            ):
                matching_temps.append((entry.name, file_identity(candidate)))
    if len(matching_temps) != 1:
        return False
    temp_name, temp_identity = matching_temps[0]
    if not unlink_same_at(
        directory_fd,
        temp_name,
        temp_identity,
        before_unlink=before_mutation,
    ):
        return False
    try:
        recovered = os.stat(
            final_name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
    except OSError:
        return False
    return (
        stat.S_ISREG(recovered.st_mode)
        and recovered.st_dev == final_stat.st_dev
        and recovered.st_ino == final_stat.st_ino
        and recovered.st_nlink == 1
    )


def _entry_exists(directory_fd: int, name: str) -> bool:
    try:
        _ = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError:
        return False
    return True


def _unlink_if_expired_at(
    directory_fd: int,
    name: str,
    *,
    now_ms: int,
    retention_ms: int,
    before_mutation: Callable[[], None] | None = None,
) -> None:
    try:
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError:
        return
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or now_ms - metadata.st_mtime_ns // 1_000_000 < retention_ms
    ):
        return
    _ = unlink_same_at(
        directory_fd,
        name,
        file_identity(metadata),
        before_unlink=before_mutation,
    )


def _existing_bytes(path: Path) -> bytes | None:
    try:
        _ = path.lstat()
    except FileNotFoundError:
        return None
    try:
        return read_final(path, maximum_bytes=MAX_ACK_BYTES).content
    except MailboxFileError as exc:
        if exc.code is MailboxFileErrorCode.STORAGE_UNAVAILABLE:
            return None
        return b""


def _unlink_if_expired(path: Path, *, now_ms: int, retention_ms: int) -> None:
    try:
        metadata = path.lstat()
    except OSError:
        return
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or now_ms - metadata.st_mtime_ns // 1_000_000 < retention_ms
    ):
        return
    _ = unlink_same(path, file_identity(metadata))


def _exclusive_finalize(
    directory_fd: int,
    source: str,
    destination: str,
    *,
    before_mutation: Callable[[], None] | None = None,
) -> None:
    _validate(before_mutation)
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        rename = cast(
            "Callable[[int, bytes, int, bytes, int], int]",
            libc.renameatx_np,
        )
        result = rename(
            directory_fd,
            os.fsencode(source),
            directory_fd,
            os.fsencode(destination),
            0x00000004,
        )
        if result != 0:
            error = ctypes.get_errno()
            if error == errno.EEXIST:
                raise FileExistsError(error, "mailbox final exists")
            raise OSError(error, "mailbox finalization failed")
        return
    os.link(
        source,
        destination,
        src_dir_fd=directory_fd,
        dst_dir_fd=directory_fd,
        follow_symlinks=False,
    )
    _validate(before_mutation)
    os.unlink(source, dir_fd=directory_fd)


def _fault(
    hook: MailboxImportFaultHook | None,
    point: MailboxImportFaultPoint,
) -> None:
    if hook is not None:
        hook(point)


def _validate(callback: Callable[[], None] | None) -> None:
    if callback is not None:
        callback()

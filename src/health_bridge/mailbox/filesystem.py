from __future__ import annotations

import fcntl
import heapq
import os
import re
import stat
from contextlib import contextmanager
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, Final

from typing_extensions import override

from health_bridge.private_files import ensure_private_file

if TYPE_CHECKING:
    from collections.abc import Generator
    from pathlib import Path

MAX_SCAN_FILES: Final = 10_000
MAX_SCAN_BYTES: Final = 2 * 1024 * 1024 * 1024
_DELIVERY_PATTERN: Final = re.compile(r"^[0-9a-f]{32}\.hbd$")
_TEMP_PATTERN: Final = re.compile(
    r"^(?P<final>[0-9a-f]{32}\.(?:hbd|hba|hbq))\.[0-9a-f]{32}\.tmp$"
)
_DIRECTORY_FLAGS: Final = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_CLOEXEC", 0)
)
_FILE_FLAGS: Final = (
    os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
)


class MailboxFileErrorCode(StrEnum):
    UNSAFE_ENTRY = "unsafe_entry"
    PATH_REPLACED = "path_replaced"
    OVERSIZE = "oversize"
    STORAGE_UNAVAILABLE = "storage_unavailable"


@dataclass(frozen=True, slots=True)
class MailboxFileError(Exception):
    code: MailboxFileErrorCode

    @override
    def __str__(self) -> str:
        return self.code.value


@dataclass(frozen=True, slots=True)
class FileIdentity:
    device: int
    inode: int
    size: int
    modified_ns: int
    changed_ns: int


@dataclass(frozen=True, slots=True)
class FileSnapshot:
    content: bytes
    identity: FileIdentity


@dataclass(frozen=True, slots=True)
class ScannedDelivery:
    name: str
    size: int


@dataclass(frozen=True, slots=True)
class DeliveryScan:
    entries: tuple[ScannedDelivery, ...]
    skipped: int


@contextmanager
def mailbox_writer_lock(path: Path) -> Generator[None, None, None]:
    _ = ensure_private_file(path)
    descriptor = os.open(path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        current = path.lstat()
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or _identity_tuple(opened) != _identity_tuple(current)
        ):
            raise MailboxFileError(MailboxFileErrorCode.UNSAFE_ENTRY)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            current = path.lstat()
            if _identity_tuple(opened) != _identity_tuple(current):
                raise MailboxFileError(MailboxFileErrorCode.PATH_REPLACED)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def scan_delivery_lane(path: Path) -> DeliveryScan:
    heap: list[tuple[int, str, int]] = []
    final_count = 0
    skipped = 0
    with os.scandir(path) as entries:
        for entry in entries:
            name = entry.name
            if _TEMP_PATTERN.fullmatch(name) is not None:
                skipped += 1
                continue
            if _DELIVERY_PATTERN.fullmatch(name) is None:
                skipped += 1
                continue
            final_count += 1
            try:
                size = entry.stat(follow_symlinks=False).st_size
            except OSError:
                size = 0
            rank = int.from_bytes(name.encode("ascii"), byteorder="big")
            candidate = (-rank, name, size)
            if len(heap) < MAX_SCAN_FILES:
                heapq.heappush(heap, candidate)
            elif candidate > heap[0]:
                _ = heapq.heapreplace(heap, candidate)
    selected = sorted(
        (ScannedDelivery(name=name, size=size) for _, name, size in heap),
        key=lambda item: item.name,
    )
    bounded: list[ScannedDelivery] = []
    scanned_bytes = 0
    for entry in selected:
        if entry.size < 0 or scanned_bytes + entry.size > MAX_SCAN_BYTES:
            skipped += 1
            continue
        bounded.append(entry)
        scanned_bytes += entry.size
    skipped += final_count - len(selected)
    return DeliveryScan(entries=tuple(bounded), skipped=skipped)


def read_final(path: Path, *, maximum_bytes: int) -> FileSnapshot:
    parent_fd = open_directory(path.parent)
    try:
        try:
            initial = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
            _require_regular(initial, maximum_bytes)
            descriptor = os.open(path.name, _FILE_FLAGS, dir_fd=parent_fd)
        except (OSError, MailboxFileError) as exc:
            if isinstance(exc, MailboxFileError):
                raise
            raise MailboxFileError(MailboxFileErrorCode.STORAGE_UNAVAILABLE) from exc
        try:
            opened = os.fstat(descriptor)
            if _identity_tuple(initial) != _identity_tuple(opened):
                raise MailboxFileError(MailboxFileErrorCode.PATH_REPLACED)
            chunks: list[bytes] = []
            remaining = maximum_bytes + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(remaining, 64 * 1024))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            content = b"".join(chunks)
            if len(content) > maximum_bytes:
                raise MailboxFileError(MailboxFileErrorCode.OVERSIZE)
            final_stat = os.fstat(descriptor)
            current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
            identity = file_identity(opened)
            if identity != file_identity(final_stat) or identity != file_identity(
                current
            ):
                raise MailboxFileError(MailboxFileErrorCode.PATH_REPLACED)
            return FileSnapshot(content=content, identity=identity)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_fd)


def revalidate_final(path: Path, identity: FileIdentity) -> bool:
    try:
        current = path.lstat()
    except OSError:
        return False
    return file_identity(current) == identity


def unlink_same(path: Path, identity: FileIdentity) -> bool:
    parent_fd = open_directory(path.parent)
    try:
        try:
            current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        except OSError:
            return False
        if file_identity(current) != identity:
            return False
        os.unlink(path.name, dir_fd=parent_fd)
        return True
    finally:
        os.close(parent_fd)


def exact_temp_final(name: str) -> str | None:
    matched = _TEMP_PATTERN.fullmatch(name)
    return None if matched is None else matched.group("final")


def open_directory(path: Path) -> int:
    try:
        initial = path.lstat()
    except OSError as exc:
        raise MailboxFileError(MailboxFileErrorCode.STORAGE_UNAVAILABLE) from exc
    if not stat.S_ISDIR(initial.st_mode) or stat.S_ISLNK(initial.st_mode):
        raise MailboxFileError(MailboxFileErrorCode.UNSAFE_ENTRY)
    try:
        descriptor = os.open(path, _DIRECTORY_FLAGS)
    except OSError as exc:
        raise MailboxFileError(MailboxFileErrorCode.STORAGE_UNAVAILABLE) from exc
    opened = os.fstat(descriptor)
    if _identity_tuple(initial) != _identity_tuple(opened):
        os.close(descriptor)
        raise MailboxFileError(MailboxFileErrorCode.PATH_REPLACED)
    return descriptor


def _require_regular(value: os.stat_result, maximum_bytes: int) -> None:
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
        raise MailboxFileError(MailboxFileErrorCode.UNSAFE_ENTRY)
    if value.st_size < 0 or value.st_size > maximum_bytes:
        raise MailboxFileError(MailboxFileErrorCode.OVERSIZE)


def _identity_tuple(value: os.stat_result) -> tuple[int, int]:
    return value.st_dev, value.st_ino


def file_identity(value: os.stat_result) -> FileIdentity:
    return FileIdentity(
        device=value.st_dev,
        inode=value.st_ino,
        size=value.st_size,
        modified_ns=value.st_mtime_ns,
        changed_ns=value.st_ctime_ns,
    )

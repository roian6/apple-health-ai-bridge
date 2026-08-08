from __future__ import annotations

import fcntl
import heapq
import os
import re
import stat
from contextlib import contextmanager
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import TYPE_CHECKING, Final, Self, cast

from typing_extensions import override

from health_bridge.private_files import ensure_private_file

if TYPE_CHECKING:
    from collections.abc import Callable, Generator


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


@dataclass(slots=True)
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


@dataclass(slots=True)
class MailboxDirectoryHandle:
    path: Path
    root_parent_fd: int
    root_fd: int
    receiver_fd: int
    mailbox_fd: int
    deliveries_fd: int
    acks_fd: int
    quarantine_fd: int
    root_name: str
    receiver_name: str
    device_name: str
    root_identity: tuple[int, int]
    receiver_identity: tuple[int, int]
    device_identity: tuple[int, int]
    deliveries_identity: tuple[int, int]
    acks_identity: tuple[int, int]
    quarantine_identity: tuple[int, int]
    _closed: bool = False

    def validate_attached(self) -> None:
        attachments = (
            (self.root_parent_fd, self.root_name, self.root_fd, self.root_identity),
            (
                self.root_fd,
                self.receiver_name,
                self.receiver_fd,
                self.receiver_identity,
            ),
            (
                self.receiver_fd,
                self.device_name,
                self.mailbox_fd,
                self.device_identity,
            ),
            (
                self.mailbox_fd,
                "deliveries",
                self.deliveries_fd,
                self.deliveries_identity,
            ),
            (self.mailbox_fd, "acks", self.acks_fd, self.acks_identity),
            (
                self.mailbox_fd,
                "quarantine",
                self.quarantine_fd,
                self.quarantine_identity,
            ),
        )
        try:
            for parent_fd, name, opened_fd, expected in attachments:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                opened = os.fstat(opened_fd)
                if (
                    _identity_tuple(current) != expected
                    or _identity_tuple(opened) != expected
                    or not stat.S_ISDIR(current.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                ):
                    raise MailboxFileError(MailboxFileErrorCode.PATH_REPLACED)
        except OSError as exc:
            raise MailboxFileError(MailboxFileErrorCode.PATH_REPLACED) from exc

    def close(self) -> None:
        if self._closed:
            return
        first_error: OSError | None = None
        attributes = (
            "quarantine_fd",
            "acks_fd",
            "deliveries_fd",
            "mailbox_fd",
            "receiver_fd",
            "root_fd",
            "root_parent_fd",
        )
        for attribute in attributes:
            descriptor = cast("int", getattr(self, attribute))
            if descriptor < 0:
                continue
            try:
                os.close(descriptor)
            except OSError as exc:
                if first_error is None:
                    first_error = exc
            else:
                setattr(self, attribute, -1)
        self._closed = all(
            cast("int", getattr(self, attribute)) < 0 for attribute in attributes
        )
        if first_error is not None:
            raise first_error

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()


def open_mailbox_directory(path: Path) -> MailboxDirectoryHandle:
    absolute = path.absolute()
    minimum_mailbox_parts = 3
    if len(absolute.parts) < minimum_mailbox_parts:
        raise MailboxFileError(MailboxFileErrorCode.UNSAFE_ENTRY)
    root_parent_fd, root_fd, root_name = open_directory_with_parent(
        Path(*absolute.parts[:-2])
    )
    owned: list[int] = [root_parent_fd, root_fd]
    try:
        receiver_name, device_name = absolute.parts[-2:]
        return _open_mailbox_bound(
            path=path,
            root_parent_fd=root_parent_fd,
            root_fd=root_fd,
            root_name=root_name,
            receiver_name=receiver_name,
            device_name=device_name,
            owned=owned,
        )
    except MailboxFileError:
        for item in reversed(owned):
            os.close(item)
        raise
    except OSError as exc:
        for item in reversed(owned):
            os.close(item)
        raise MailboxFileError(MailboxFileErrorCode.STORAGE_UNAVAILABLE) from exc


def open_directory_with_parent(path: Path) -> tuple[int, int, str]:
    absolute = path.absolute()
    minimum_directory_parts = 2
    if len(absolute.parts) < minimum_directory_parts:
        raise MailboxFileError(MailboxFileErrorCode.UNSAFE_ENTRY)
    descriptor = open_directory(Path(absolute.anchor))
    opened: list[int] = [descriptor]
    try:
        for component in absolute.parts[1:-1]:
            descriptor = open_directory_at(descriptor, component)
            opened.append(descriptor)
        parent_fd = os.dup(descriptor)
        try:
            directory_fd = open_directory_at(parent_fd, absolute.name)
        except BaseException:
            os.close(parent_fd)
            raise
        return parent_fd, directory_fd, absolute.name
    finally:
        for item in reversed(opened):
            os.close(item)


def open_directory_at(parent_fd: int, name: str) -> int:
    try:
        descriptor = os.open(name, _DIRECTORY_FLAGS, dir_fd=parent_fd)
    except OSError as exc:
        raise MailboxFileError(MailboxFileErrorCode.STORAGE_UNAVAILABLE) from exc
    if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise MailboxFileError(MailboxFileErrorCode.UNSAFE_ENTRY)
    return descriptor


def open_mailbox_at(  # noqa: PLR0913 - namespace binding inputs stay explicit.
    root_fd: int,
    root_path: Path,
    receiver_name: str,
    device_name: str,
    *,
    root_parent_fd: int,
    root_name: str,
) -> MailboxDirectoryHandle:
    owned: list[int] = []
    try:
        bound_root_parent_fd = os.dup(root_parent_fd)
        owned.append(bound_root_parent_fd)
        bound_root_fd = os.dup(root_fd)
        owned.append(bound_root_fd)
        return _open_mailbox_bound(
            path=root_path / receiver_name / device_name,
            root_parent_fd=bound_root_parent_fd,
            root_fd=bound_root_fd,
            root_name=root_name,
            receiver_name=receiver_name,
            device_name=device_name,
            owned=owned,
        )
    except MailboxFileError:
        for item in reversed(owned):
            os.close(item)
        raise
    except OSError as exc:
        for item in reversed(owned):
            os.close(item)
        raise MailboxFileError(MailboxFileErrorCode.STORAGE_UNAVAILABLE) from exc


def _open_mailbox_bound(  # noqa: PLR0913 - owned namespace inputs stay explicit.
    *,
    path: Path,
    root_parent_fd: int,
    root_fd: int,
    root_name: str,
    receiver_name: str,
    device_name: str,
    owned: list[int],
) -> MailboxDirectoryHandle:
    receiver_fd = open_directory_at(root_fd, receiver_name)
    owned.append(receiver_fd)
    mailbox_fd = open_directory_at(receiver_fd, device_name)
    owned.append(mailbox_fd)
    deliveries_fd = open_directory_at(mailbox_fd, "deliveries")
    owned.append(deliveries_fd)
    acks_fd = open_directory_at(mailbox_fd, "acks")
    owned.append(acks_fd)
    quarantine_fd = open_directory_at(mailbox_fd, "quarantine")
    owned.append(quarantine_fd)
    handle = MailboxDirectoryHandle(
        path=path,
        root_parent_fd=root_parent_fd,
        root_fd=root_fd,
        receiver_fd=receiver_fd,
        mailbox_fd=mailbox_fd,
        deliveries_fd=deliveries_fd,
        acks_fd=acks_fd,
        quarantine_fd=quarantine_fd,
        root_name=root_name,
        receiver_name=receiver_name,
        device_name=device_name,
        root_identity=_identity_tuple(os.fstat(root_fd)),
        receiver_identity=_identity_tuple(os.fstat(receiver_fd)),
        device_identity=_identity_tuple(os.fstat(mailbox_fd)),
        deliveries_identity=_identity_tuple(os.fstat(deliveries_fd)),
        acks_identity=_identity_tuple(os.fstat(acks_fd)),
        quarantine_identity=_identity_tuple(os.fstat(quarantine_fd)),
    )
    handle.validate_attached()
    owned.clear()
    return handle


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


def scan_delivery_lane(path: Path | int) -> DeliveryScan:
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


def read_final_at(directory_fd: int, name: str, *, maximum_bytes: int) -> FileSnapshot:
    try:
        initial = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        _require_regular(initial, maximum_bytes)
        descriptor = os.open(name, _FILE_FLAGS, dir_fd=directory_fd)
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
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        identity = file_identity(opened)
        if identity != file_identity(final_stat) or identity != file_identity(current):
            raise MailboxFileError(MailboxFileErrorCode.PATH_REPLACED)
        return FileSnapshot(content=content, identity=identity)
    finally:
        os.close(descriptor)


def revalidate_final(path: Path, identity: FileIdentity) -> bool:
    try:
        current = path.lstat()
    except OSError:
        return False
    return file_identity(current) == identity


def revalidate_final_at(directory_fd: int, name: str, identity: FileIdentity) -> bool:
    try:
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
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


def unlink_same_at(
    directory_fd: int,
    name: str,
    identity: FileIdentity,
    *,
    before_unlink: Callable[[], None] | None = None,
) -> bool:
    if before_unlink is not None:
        before_unlink()
    try:
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError:
        return False
    if file_identity(current) != identity:
        return False
    os.unlink(name, dir_fd=directory_fd)
    return True


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

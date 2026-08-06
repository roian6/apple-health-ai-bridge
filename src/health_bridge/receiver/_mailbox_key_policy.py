import os
import signal
import stat
import sys
import time
from enum import StrEnum
from pathlib import Path
from typing import Final

from health_bridge.receiver._mailbox_key_models import (
    MailboxKeyStoreError,
    MailboxKeyStoreErrorCode,
)

_PROHIBITED_COMPONENTS: Final = frozenset(
    {"cloudstorage", "icloud drive", "mobile documents", "ubiquity"}
)
_LOCAL_LINUX_FILESYSTEMS: Final = frozenset(
    {
        "btrfs",
        "ext2",
        "ext3",
        "ext4",
        "f2fs",
        "jfs",
        "overlay",
        "ramfs",
        "tmpfs",
        "xfs",
        "zfs",
    }
)
_NETWORK_FILESYSTEMS: Final = frozenset(
    {
        "9p",
        "afpfs",
        "ceph",
        "cifs",
        "fuse.sshfs",
        "glusterfs",
        "nfs",
        "nfs4",
        "smbfs",
        "sshfs",
        "webdav",
    }
)
_MOUNTINFO_MIN_FIELDS: Final = 5
_DARWIN_MOUNT_TIMEOUT_SECONDS: Final = 5.0


class FilesystemKind(StrEnum):
    LOCAL = "local"
    NETWORK = "network"
    UNKNOWN = "unknown"


def application_support_root() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "HealthBridge"
    xdg_data = os.environ.get("XDG_DATA_HOME")
    if xdg_data is not None:
        candidate = Path(xdg_data)
        if not candidate.is_absolute():
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.PROHIBITED_STORAGE)
        return candidate / "health-bridge"
    return Path.home() / ".local" / "share" / "health-bridge"


def filesystem_kind(path: Path) -> FilesystemKind:
    existing = path
    while not existing.exists():
        if existing.parent == existing:
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE)
        existing = existing.parent
    if sys.platform.startswith("linux"):
        filesystem = _linux_filesystem_type(existing)
        normalized = filesystem.casefold()
        if normalized in _LOCAL_LINUX_FILESYSTEMS:
            return FilesystemKind.LOCAL
        if normalized in _NETWORK_FILESYSTEMS:
            return FilesystemKind.NETWORK
        return FilesystemKind.UNKNOWN
    if sys.platform == "darwin":
        return _darwin_filesystem_kind(existing)
    raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.PROHIBITED_STORAGE)


def reject_prohibited_path(path: Path) -> None:
    if any(part.casefold() in _PROHIBITED_COMPONENTS for part in path.parts):
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.PROHIBITED_STORAGE)
    absolute = path.absolute()
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            entry = current.lstat()
        except FileNotFoundError:
            return
        except OSError as exc:
            raise MailboxKeyStoreError(
                MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
            ) from exc
        if stat.S_ISLNK(entry.st_mode):
            raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS)


def _linux_filesystem_type(path: Path) -> str:
    resolved = path.resolve(strict=True)
    matches: list[tuple[int, str]] = []
    try:
        lines = Path("/proc/self/mountinfo").read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise MailboxKeyStoreError(
            MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
        ) from exc
    for line in lines:
        left, separator, right = line.partition(" - ")
        fields = left.split()
        if separator and len(fields) >= _MOUNTINFO_MIN_FIELDS:
            mountpoint = Path(fields[4].replace("\\040", " "))
            if resolved == mountpoint or mountpoint in resolved.parents:
                matches.append((len(mountpoint.parts), right.split()[0]))
    if not matches:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE)
    return max(matches)[1]


def _darwin_filesystem_kind(path: Path) -> FilesystemKind:
    resolved = path.resolve(strict=True)
    try:
        output = _darwin_mount_output()
    except OSError as exc:
        raise MailboxKeyStoreError(
            MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE
        ) from exc
    matches: list[tuple[int, str, frozenset[str]]] = []
    for line in output.splitlines():
        _, separator, mounted = line.partition(" on ")
        mountpoint, options_separator, options = mounted.rpartition(" (")
        if not separator or not options_separator or not options.endswith(")"):
            continue
        mountpoint_path = Path(mountpoint.replace("\\040", " "))
        if resolved != mountpoint_path and mountpoint_path not in resolved.parents:
            continue
        values = [value.strip().casefold() for value in options[:-1].split(",")]
        normalized = frozenset(values)
        filesystem = values[0] if values else ""
        matches.append((len(mountpoint_path.parts), filesystem, normalized))
    if not matches:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.STORAGE_UNAVAILABLE)
    _, filesystem, options = max(matches, key=lambda value: value[0])
    if "local" in options:
        return FilesystemKind.LOCAL
    if filesystem in _NETWORK_FILESYSTEMS:
        return FilesystemKind.NETWORK
    return FilesystemKind.UNKNOWN


def _darwin_mount_output() -> str:
    read_fd, write_fd = os.pipe()
    try:
        child_pid = os.posix_spawn(
            "/sbin/mount",
            ("/sbin/mount",),
            os.environ,
            file_actions=(
                (os.POSIX_SPAWN_DUP2, write_fd, 1),
                (os.POSIX_SPAWN_CLOSE, read_fd),
                (os.POSIX_SPAWN_CLOSE, write_fd),
            ),
        )
    except OSError:
        os.close(read_fd)
        os.close(write_fd)
        raise
    os.close(write_fd)
    os.set_blocking(read_fd, False)
    chunks: list[bytes] = []
    try:
        deadline = time.monotonic() + _DARWIN_MOUNT_TIMEOUT_SECONDS
        status: int | None = None
        while status is None:
            try:
                while chunk := os.read(read_fd, 8192):
                    chunks.append(chunk)
            except BlockingIOError:
                pass
            waited_pid, candidate_status = os.waitpid(child_pid, os.WNOHANG)
            if waited_pid == child_pid:
                status = candidate_status
                continue
            if time.monotonic() >= deadline:
                os.kill(child_pid, signal.SIGKILL)
                _ = os.waitpid(child_pid, 0)
                raise OSError
            time.sleep(0.01)
        os.set_blocking(read_fd, True)
        while chunk := os.read(read_fd, 8192):
            chunks.append(chunk)
    finally:
        os.close(read_fd)
    if os.waitstatus_to_exitcode(status) != 0:
        raise OSError
    return b"".join(chunks).decode("utf-8")

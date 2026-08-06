import os
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from health_bridge.private_files import (
    PRIVATE_DIRECTORY_MODE,
    ensure_private_directory,
    require_private_parent,
)

SQLITE_PRIVATE_SIDECAR_SUFFIXES: Final = ("-journal", "-wal", "-shm")


@dataclass(frozen=True, slots=True)
class DatabaseLockPlan:
    suffix: str
    exclusive: bool
    create: bool
    nonblocking: bool
    lock_database: bool
    optional_lock_file: bool


@dataclass(frozen=True, slots=True)
class DarwinStableDatabaseLock:
    path: Path
    fd: int
    parent_identity: os.stat_result
    database_identity: os.stat_result | None


def prepare_darwin_stable_lock(
    db_path: Path,
    plan: DatabaseLockPlan,
) -> DarwinStableDatabaseLock | None:
    if not plan.lock_database or sys.platform != "darwin":
        return None
    if plan.create:
        ensure_private_directory(db_path.parent)
    else:
        require_private_parent(db_path.parent)
    parent_identity = db_path.parent.stat(follow_symlinks=False)
    try:
        database_identity = db_path.stat(follow_symlinks=False)
    except FileNotFoundError:
        database_identity = None
    if database_identity is not None:
        validate_database_lock_stat(db_path, database_identity)
    lock_path, lock_fd = _open_stable_database_lock_fd(db_path)
    return DarwinStableDatabaseLock(
        path=lock_path,
        fd=lock_fd,
        parent_identity=parent_identity,
        database_identity=database_identity,
    )


def require_darwin_lock_identities(
    db_path: Path,
    stable_lock: DarwinStableDatabaseLock,
) -> None:
    require_path_identity(db_path.parent, stable_lock.parent_identity)
    if stable_lock.database_identity is not None:
        require_path_identity(db_path, stable_lock.database_identity)


def open_lock_file_fd(lock_path: Path, plan: DatabaseLockPlan) -> int | None:
    if plan.create:
        create_private_lock(lock_path)
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    try:
        fd = os.open(lock_path, flags)
    except FileNotFoundError:
        if plan.optional_lock_file:
            return None
        raise
    try:
        validate_lock_stat(lock_path, os.fstat(fd))
    except OSError:
        os.close(fd)
        raise
    return fd


def open_database_lock_fd(db_path: Path, *, create: bool) -> int:
    if create:
        ensure_private_directory(db_path.parent)
    require_private_parent(db_path.parent)
    access_mode = os.O_RDWR if create else os.O_RDONLY
    flags = access_mode | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    if create:
        try:
            fd = os.open(db_path, flags | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            try:
                fd = os.open(db_path, flags)
            except OSError as exc:
                if db_path.is_symlink():
                    message = f"refusing to use database through symlink: {db_path}"
                    raise OSError(message) from exc
                raise
    else:
        fd = os.open(db_path, flags)
    try:
        validate_database_lock_stat(db_path, os.fstat(fd))
    except OSError:
        os.close(fd)
        raise
    return fd


def _darwin_stable_lock_root() -> Path:
    return Path.home() / ".cache" / "apple-health-ai-bridge" / "database-locks"


def _stable_database_lock_path(_db_path: Path) -> Path:
    return _darwin_stable_lock_root() / "database-access.lock"


def _ensure_owned_private_lock_directory(directory: Path) -> None:
    ensure_private_directory(directory)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | os.O_NOFOLLOW
    )
    fd = os.open(directory, flags)
    try:
        opened_stat = os.fstat(fd)
        if not stat.S_ISDIR(opened_stat.st_mode):
            message = f"database lock root is not a directory: {directory}"
            raise OSError(message)
        if hasattr(os, "getuid") and opened_stat.st_uid != os.getuid():
            message = f"database lock root is not owned by this user: {directory}"
            raise OSError(message)
        os.fchmod(fd, PRIVATE_DIRECTORY_MODE)
        require_path_identity(directory, opened_stat)
        require_private_parent(directory)
        if stat.S_IMODE(os.fstat(fd).st_mode) != PRIVATE_DIRECTORY_MODE:
            message = f"database lock root permissions are not private: {directory}"
            raise OSError(message)
    finally:
        os.close(fd)


def _open_stable_database_lock_fd(db_path: Path) -> tuple[Path, int]:
    lock_path = _stable_database_lock_path(db_path)
    _ensure_owned_private_lock_directory(lock_path.parent)
    create_private_lock(lock_path)
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    fd = os.open(lock_path, flags)
    try:
        validate_lock_stat(lock_path, os.fstat(fd))
    except OSError:
        os.close(fd)
        raise
    return lock_path, fd


def validate_database_lock_stat(
    db_path: Path,
    database_stat: os.stat_result,
) -> None:
    if stat.S_ISLNK(database_stat.st_mode):
        message = f"database path must not be a symlink: {db_path}"
        raise OSError(message)
    if not stat.S_ISREG(database_stat.st_mode) or database_stat.st_nlink != 1:
        message = f"invalid database file: {db_path}"
        raise OSError(message)
    if hasattr(os, "getuid") and database_stat.st_uid != os.getuid():
        message = f"database is not owned by this user: {db_path}"
        raise OSError(message)


def require_path_identity(path: Path, opened_stat: os.stat_result) -> None:
    current_stat = path.stat(follow_symlinks=False)
    if (current_stat.st_dev, current_stat.st_ino) != (
        opened_stat.st_dev,
        opened_stat.st_ino,
    ):
        message = f"locked path changed during acquisition: {path}"
        raise OSError(message)


def create_private_lock(lock_path: Path) -> None:
    ensure_private_directory(lock_path.parent)
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    try:
        fd = os.open(lock_path, flags | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        fd = os.open(lock_path, flags)
    try:
        validate_lock_stat(lock_path, os.fstat(fd))
    finally:
        os.close(fd)


def require_quiescent_database(db_path: Path) -> None:
    if db_path.is_symlink() or not db_path.is_file():
        message = "read-only database path must be a regular file"
        raise OSError(message)
    for suffix in SQLITE_PRIVATE_SIDECAR_SUFFIXES:
        sidecar = Path(f"{db_path}{suffix}")
        if sidecar.exists() or sidecar.is_symlink():
            message = "read-only database snapshot is not quiescent"
            raise OSError(message)


def validate_lock_stat(lock_path: Path, lock_stat: os.stat_result) -> None:
    if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_nlink != 1:
        message = f"invalid database lock file: {lock_path}"
        raise OSError(message)
    if hasattr(os, "getuid") and lock_stat.st_uid != os.getuid():
        message = f"database lock is not owned by this user: {lock_path}"
        raise OSError(message)
    if stat.S_IMODE(lock_stat.st_mode) & 0o077:
        message = f"database lock permissions are not private: {lock_path}"
        raise OSError(message)


def flock(fd: int, *, exclusive: bool, nonblocking: bool) -> None:
    import fcntl  # noqa: PLC0415

    operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
    if nonblocking:
        operation |= fcntl.LOCK_NB
    fcntl.flock(fd, operation)


def flock_unlock(fd: int) -> None:
    import fcntl  # noqa: PLC0415

    fcntl.flock(fd, fcntl.LOCK_UN)

import os
import sqlite3
import stat
import sys
from collections.abc import Generator
from contextlib import contextmanager
from dataclasses import dataclass
from importlib.resources import files
from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.private_files import (
    PRIVATE_DIRECTORY_MODE,
    ensure_private_directory,
    ensure_private_file,
    repair_private_file_mode,
    require_private_parent,
)

MIGRATION_IDS: Final = (
    "001_initial",
    "002_sync_window",
    "003_receiver_tokens",
    "004_pairing_invitations",
    "005_pairing_devices",
    "006_sleep_session_revisions",
    "007_sleep_baseline_namespaces",
)
MIGRATIONS_PACKAGE: Final = "health_bridge.storage.migrations"
SQLITE_PRIVATE_SIDECAR_SUFFIXES: Final = ("-journal", "-wal", "-shm")
DATABASE_LIFECYCLE_LOCK_SUFFIX: Final = ".lifecycle.lock"
DATABASE_ACCESS_LOCK_SUFFIX: Final = ".access.lock"
INCOMPLETE_MIGRATION_SQL_ERROR: Final = (
    "migration SQL ended with an incomplete statement"
)
MigrationRow: TypeAlias = tuple[int]
MIGRATION_ROW_ADAPTER: Final[TypeAdapter[MigrationRow | None]] = TypeAdapter(
    MigrationRow | None,
)


@dataclass(frozen=True, slots=True)
class _DatabaseLockPlan:
    suffix: str
    exclusive: bool
    create: bool
    nonblocking: bool
    lock_database: bool
    optional_lock_file: bool


@dataclass(frozen=True, slots=True)
class _DarwinStableDatabaseLock:
    path: Path
    fd: int
    parent_identity: os.stat_result
    database_identity: os.stat_result | None


def _protect_database_files(db_path: Path) -> tuple[int, int]:
    identity = ensure_private_file(db_path)
    for suffix in SQLITE_PRIVATE_SIDECAR_SUFFIXES:
        sidecar = Path(f"{db_path}{suffix}")
        if not sidecar.exists() and not sidecar.is_symlink():
            continue
        try:
            repair_private_file_mode(sidecar)
        except FileNotFoundError:
            continue
    return identity


@contextmanager
def connect_database(db_path: Path) -> Generator[sqlite3.Connection, None, None]:
    with (
        database_lifecycle_lock(db_path, exclusive=False, create=True),
        database_access_lock(db_path, exclusive=False, create=True),
    ):
        protected_identity = _protect_database_files(db_path)
        try:
            with sqlite3.connect(db_path) as connection:
                opened_identity = _protect_database_files(db_path)
                if opened_identity != protected_identity:
                    msg = f"database path changed before SQLite open: {db_path}"
                    raise OSError(msg)
                _ = connection.execute("pragma foreign_keys = on")
                yield connection
        finally:
            _ = _protect_database_files(db_path)


@contextmanager
def connect_readonly_database(
    db_path: Path,
) -> Generator[sqlite3.Connection, None, None]:
    with database_access_lock(
        db_path,
        exclusive=True,
        create=False,
        nonblocking=True,
    ):
        _require_quiescent_readonly_database(db_path)
        resolved = db_path.resolve(strict=True)
        uri = f"{resolved.as_uri()}?mode=ro&immutable=1"
        with sqlite3.connect(uri, uri=True) as connection:
            _ = connection.execute("pragma query_only = on")
            _ = connection.execute("pragma foreign_keys = on")
            yield connection


@contextmanager
def database_lifecycle_lock(
    db_path: Path,
    *,
    exclusive: bool,
    create: bool,
    nonblocking: bool = False,
) -> Generator[None, None, None]:
    with _database_file_lock(
        db_path,
        _DatabaseLockPlan(
            suffix=DATABASE_LIFECYCLE_LOCK_SUFFIX,
            exclusive=exclusive,
            create=create,
            nonblocking=nonblocking,
            lock_database=False,
            optional_lock_file=False,
        ),
    ):
        yield


@contextmanager
def database_access_lock(
    db_path: Path,
    *,
    exclusive: bool,
    create: bool,
    nonblocking: bool = False,
) -> Generator[None, None, None]:
    with _database_file_lock(
        db_path,
        _DatabaseLockPlan(
            suffix=DATABASE_ACCESS_LOCK_SUFFIX,
            exclusive=exclusive,
            create=create,
            nonblocking=nonblocking,
            lock_database=True,
            optional_lock_file=not create,
        ),
    ):
        yield


@contextmanager
def _database_file_lock(
    db_path: Path,
    plan: _DatabaseLockPlan,
) -> Generator[None, None, None]:
    if os.name != "posix":
        message = "database file locking is unavailable on this platform"
        raise OSError(message)
    if not hasattr(os, "O_NOFOLLOW"):
        message = "database file locking requires O_NOFOLLOW"
        raise OSError(message)
    stable_lock = _prepare_darwin_stable_lock(db_path, plan)
    stable_lock_path = stable_lock.path if stable_lock is not None else db_path
    stable_lock_fd = stable_lock.fd if stable_lock is not None else None
    try:
        with _held_path_flock(
            stable_lock_fd,
            stable_lock_path,
            exclusive=plan.exclusive,
            nonblocking=plan.nonblocking,
        ):
            if stable_lock is not None:
                _require_darwin_lock_identities(db_path, stable_lock)
            lock_path = Path(f"{db_path}{plan.suffix}")
            lock_fd = _open_lock_file_fd(lock_path, plan)
            try:
                with _held_path_flock(
                    lock_fd,
                    lock_path,
                    exclusive=plan.exclusive,
                    nonblocking=plan.nonblocking,
                ):
                    # Darwin's flock collides with SQLite's locking bytes. The
                    # stable external lock above protects the path namespace
                    # before this replaceable access-lock file is opened.
                    database_fd = (
                        _open_database_lock_fd(db_path, create=plan.create)
                        if plan.lock_database and sys.platform != "darwin"
                        else None
                    )
                    try:
                        with _held_path_flock(
                            database_fd,
                            db_path,
                            exclusive=plan.exclusive,
                            nonblocking=plan.nonblocking,
                        ):
                            yield
                    finally:
                        if database_fd is not None:
                            os.close(database_fd)
            finally:
                if lock_fd is not None:
                    os.close(lock_fd)
    finally:
        if stable_lock is not None:
            os.close(stable_lock.fd)


def _prepare_darwin_stable_lock(
    db_path: Path,
    plan: _DatabaseLockPlan,
) -> _DarwinStableDatabaseLock | None:
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
        _validate_database_lock_stat(db_path, database_identity)
    lock_path, lock_fd = _open_stable_database_lock_fd(db_path)
    return _DarwinStableDatabaseLock(
        path=lock_path,
        fd=lock_fd,
        parent_identity=parent_identity,
        database_identity=database_identity,
    )


def _require_darwin_lock_identities(
    db_path: Path,
    stable_lock: _DarwinStableDatabaseLock,
) -> None:
    _require_path_identity(db_path.parent, stable_lock.parent_identity)
    if stable_lock.database_identity is not None:
        _require_path_identity(db_path, stable_lock.database_identity)


def _open_lock_file_fd(lock_path: Path, plan: _DatabaseLockPlan) -> int | None:
    if plan.create:
        _create_private_lock(lock_path)
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    try:
        fd = os.open(lock_path, flags)
    except FileNotFoundError:
        if plan.optional_lock_file:
            return None
        raise
    try:
        _validate_lock_stat(lock_path, os.fstat(fd))
    except Exception:
        os.close(fd)
        raise
    return fd


@contextmanager
def _held_path_flock(
    fd: int | None,
    path: Path,
    *,
    exclusive: bool,
    nonblocking: bool,
) -> Generator[None, None, None]:
    if fd is None:
        yield
        return
    opened_stat = os.fstat(fd)
    _require_path_identity(path, opened_stat)
    _flock(fd, exclusive=exclusive, nonblocking=nonblocking)
    try:
        _require_path_identity(path, opened_stat)
        yield
    finally:
        _flock_unlock(fd)


def _open_database_lock_fd(db_path: Path, *, create: bool) -> int:
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
        _validate_database_lock_stat(db_path, os.fstat(fd))
    except Exception:
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
        _require_path_identity(directory, opened_stat)
        require_private_parent(directory)
        if stat.S_IMODE(os.fstat(fd).st_mode) != PRIVATE_DIRECTORY_MODE:
            message = f"database lock root permissions are not private: {directory}"
            raise OSError(message)
    finally:
        os.close(fd)


def _open_stable_database_lock_fd(db_path: Path) -> tuple[Path, int]:
    lock_path = _stable_database_lock_path(db_path)
    _ensure_owned_private_lock_directory(lock_path.parent)
    _create_private_lock(lock_path)
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    fd = os.open(lock_path, flags)
    try:
        _validate_lock_stat(lock_path, os.fstat(fd))
    except Exception:
        os.close(fd)
        raise
    return lock_path, fd


def _validate_database_lock_stat(
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


def _require_path_identity(path: Path, opened_stat: os.stat_result) -> None:
    current_stat = path.stat(follow_symlinks=False)
    if (current_stat.st_dev, current_stat.st_ino) != (
        opened_stat.st_dev,
        opened_stat.st_ino,
    ):
        message = f"locked path changed during acquisition: {path}"
        raise OSError(message)


def _create_private_lock(lock_path: Path) -> None:
    ensure_private_directory(lock_path.parent)
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    try:
        fd = os.open(lock_path, flags | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        fd = os.open(lock_path, flags)
    try:
        _validate_lock_stat(lock_path, os.fstat(fd))
    finally:
        os.close(fd)


def _require_quiescent_readonly_database(db_path: Path) -> None:
    if db_path.is_symlink() or not db_path.is_file():
        message = "read-only database path must be a regular file"
        raise OSError(message)
    for suffix in SQLITE_PRIVATE_SIDECAR_SUFFIXES:
        sidecar = Path(f"{db_path}{suffix}")
        if sidecar.exists() or sidecar.is_symlink():
            message = "read-only database snapshot is not quiescent"
            raise OSError(message)


def _validate_lock_structure(lock_path: Path, lock_stat: os.stat_result) -> None:
    if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_nlink != 1:
        message = f"invalid database lock file: {lock_path}"
        raise OSError(message)
    if hasattr(os, "getuid") and lock_stat.st_uid != os.getuid():
        message = f"database lock is not owned by this user: {lock_path}"
        raise OSError(message)


def _validate_lock_stat(lock_path: Path, lock_stat: os.stat_result) -> None:
    _validate_lock_structure(lock_path, lock_stat)
    if stat.S_IMODE(lock_stat.st_mode) & 0o077:
        message = f"database lock permissions are not private: {lock_path}"
        raise OSError(message)


def _flock(fd: int, *, exclusive: bool, nonblocking: bool) -> None:
    import fcntl  # noqa: PLC0415

    operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
    if nonblocking:
        operation |= fcntl.LOCK_NB
    fcntl.flock(fd, operation)


def _flock_unlock(fd: int) -> None:
    import fcntl  # noqa: PLC0415

    fcntl.flock(fd, fcntl.LOCK_UN)


def initialize_database(db_path: Path) -> None:
    with connect_database(db_path) as connection:
        _apply_initial_migration(connection)
        for migration_id in MIGRATION_IDS[1:]:
            if _migration_was_applied(connection, migration_id):
                continue
            _apply_migration(connection, migration_id)


def _apply_initial_migration(connection: sqlite3.Connection) -> None:
    migration_id = MIGRATION_IDS[0]
    if _schema_migrations_table_exists(connection) and _migration_was_applied(
        connection,
        migration_id,
    ):
        return
    _apply_migration(connection, migration_id)


def _schema_migrations_table_exists(connection: sqlite3.Connection) -> bool:
    row = MIGRATION_ROW_ADAPTER.validate_python(
        connection.execute(
            "select 1 from sqlite_master where type = 'table' and name = ?",
            ("schema_migrations",),
        ).fetchone()
    )
    return row is not None


def _apply_migration(
    connection: sqlite3.Connection,
    migration_id: str,
) -> None:
    migration_sql = (
        files(MIGRATIONS_PACKAGE).joinpath(f"{migration_id}.sql").read_text()
    )
    _ = connection.execute("begin immediate")
    try:
        if _schema_migrations_table_exists(connection) and _migration_was_applied(
            connection,
            migration_id,
        ):
            connection.commit()
            return
        _execute_migration_statements(connection, migration_sql)
        _ = connection.execute(
            "insert into schema_migrations (migration_id) values (?)",
            (migration_id,),
        )
        connection.commit()
    except Exception:
        connection.rollback()
        raise


def _execute_migration_statements(
    connection: sqlite3.Connection,
    migration_sql: str,
) -> None:
    statement_buffer = ""
    for line in migration_sql.splitlines(keepends=True):
        statement_buffer += line
        if not sqlite3.complete_statement(statement_buffer):
            continue
        statement = statement_buffer.strip()
        statement_buffer = ""
        if statement:
            _ = connection.execute(statement)
    if statement_buffer.strip():
        raise ValueError(INCOMPLETE_MIGRATION_SQL_ERROR)


def _migration_was_applied(
    connection: sqlite3.Connection,
    migration_id: str,
) -> bool:
    row = MIGRATION_ROW_ADAPTER.validate_python(
        connection.execute(
            "select 1 from schema_migrations where migration_id = ?",
            (migration_id,),
        ).fetchone(),
    )
    return row is not None

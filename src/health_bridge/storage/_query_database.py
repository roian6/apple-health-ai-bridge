import os
import sqlite3
from collections.abc import Generator
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from typing import Final

from health_bridge.storage._database_descriptors import retire_database_descriptor
from health_bridge.storage._database_lock_files import (
    open_database_lock_fd,
    require_path_identity,
    validate_lock_stat,
)
from health_bridge.storage._database_locks import (
    database_access_lock,
    database_lifecycle_lock,
)
from health_bridge.storage.sqlite_rows import fetch_one_int

_ACTIVE: Final[ContextVar[tuple[Path, sqlite3.Connection] | None]] = ContextVar(
    "query_database",
    default=None,
)
_DATABASE_HEADER_SIZE: Final = 100
_JOURNAL_HEADER_SIZE: Final = 512
_MAX_PAGE_SIZE: Final = 65536


class DatabaseReadError(OSError):
    def __init__(self) -> None:
        super().__init__("Health Bridge database is unavailable.")


def _require_rollback_database(db_path: Path) -> os.stat_result:
    for suffix in ("-wal", "-shm"):
        sidecar = Path(f"{db_path}{suffix}")
        if sidecar.exists() or sidecar.is_symlink():
            raise DatabaseReadError
    fd = open_database_lock_fd(db_path, create=False)
    try:
        entry = os.fstat(fd)
        require_path_identity(db_path, entry)
        header = os.pread(fd, _DATABASE_HEADER_SIZE, 0)
        if (
            len(header) != _DATABASE_HEADER_SIZE
            or header[:16] != b"SQLite format 3\x00"
            or header[18:20] != b"\x01\x01"
        ):
            raise DatabaseReadError
    finally:
        retire_database_descriptor(fd)
    journal = Path(f"{db_path}-journal")
    try:
        journal_fd = open_database_lock_fd(journal, create=False)
    except FileNotFoundError:
        return entry
    try:
        journal_stat = os.fstat(journal_fd)
        validate_lock_stat(journal, journal_stat)
        require_path_identity(journal, journal_stat)
        header = os.pread(journal_fd, 28, 0)
        sector_size = int.from_bytes(header[20:24], "big")
        page_size = int.from_bytes(header[24:28], "big")
        if (
            journal_stat.st_size < max(_JOURNAL_HEADER_SIZE, sector_size)
            or header[:8] not in (b"\x00" * 8, b"\xd9\xd5\x05\xf9\x20\xa1\x63\xd7")
            or not all(
                _JOURNAL_HEADER_SIZE <= size <= _MAX_PAGE_SIZE
                and size & (size - 1) == 0
                for size in (sector_size, page_size)
            )
        ):
            raise DatabaseReadError
    finally:
        retire_database_descriptor(journal_fd)
    return entry


@contextmanager
def connect_query_database(db_path: Path) -> Generator[sqlite3.Connection, None, None]:
    try:
        active = _ACTIVE.get()
        if active is not None and active[0] == db_path.resolve():
            yield active[1]
            return
        with (
            database_lifecycle_lock(
                db_path,
                exclusive=False,
                create=False,
                nonblocking=True,
            ),
            database_access_lock(
                db_path,
                exclusive=False,
                create=False,
                nonblocking=True,
            ),
        ):
            identity = _require_rollback_database(db_path)
            connection = sqlite3.connect(
                f"{db_path.resolve(strict=True).as_uri()}?mode=ro",
                uri=True,
                timeout=0.25,
            )
            try:
                require_path_identity(db_path, identity)
                _ = connection.execute("pragma query_only = on")
                _ = connection.execute("pragma foreign_keys = on")
                _ = connection.execute("begin")
                _ = fetch_one_int(connection, "select count(*) from schema_migrations")
                token = _ACTIVE.set((db_path.resolve(), connection))
                try:
                    yield connection
                finally:
                    _ACTIVE.reset(token)
            finally:
                connection.close()
    except (OSError, sqlite3.Error, RuntimeError) as exc:
        raise DatabaseReadError from exc

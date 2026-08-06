import sqlite3
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from typing import Final

from health_bridge.private_files import (
    ensure_private_file,
    repair_private_file_mode,
)
from health_bridge.storage._database_lock_files import (
    SQLITE_PRIVATE_SIDECAR_SUFFIXES,
    require_quiescent_database,
)
from health_bridge.storage._database_locks import (
    database_access_lock,
    database_lifecycle_lock,
)
from health_bridge.storage._database_migrations import (
    apply_initial_migration as _apply_initial_migration,
)
from health_bridge.storage._database_migrations import (
    apply_migration as _apply_migration,
)
from health_bridge.storage._database_migrations import (
    delivery_receipt_migration_is_complete as _delivery_receipt_migration_is_complete,
)
from health_bridge.storage._database_migrations import (
    migration_was_applied as _migration_was_applied,
)
from health_bridge.storage._migration_backup_files import DELIVERY_RECEIPT_MIGRATION_ID

__all__ = [
    "connect_database",
    "connect_readonly_database",
    "database_access_lock",
    "database_lifecycle_lock",
    "exclusive_database_maintenance",
    "initialize_database",
]

MIGRATION_IDS: Final = (
    "001_initial",
    "002_sync_window",
    "003_receiver_tokens",
    "004_pairing_invitations",
    "005_pairing_devices",
    "006_sleep_session_revisions",
    "007_sleep_baseline_namespaces",
    DELIVERY_RECEIPT_MIGRATION_ID,
)


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
        _connect_database_under_lifecycle(db_path) as connection,
    ):
        yield connection


@contextmanager
def _connect_database_under_lifecycle(
    db_path: Path,
) -> Generator[sqlite3.Connection, None, None]:
    with database_access_lock(db_path, exclusive=False, create=True):
        protected_identity = _protect_database_files(db_path)
        try:
            with sqlite3.connect(db_path) as connection:
                opened_identity = _protect_database_files(db_path)
                if opened_identity != protected_identity:
                    message = f"database path changed before SQLite open: {db_path}"
                    raise OSError(message)
                _ = connection.execute("pragma foreign_keys = on")
                yield connection
        finally:
            _ = _protect_database_files(db_path)


@contextmanager
def exclusive_database_maintenance(db_path: Path) -> Generator[None, None, None]:
    with (
        database_lifecycle_lock(db_path, exclusive=True, create=False),
        database_access_lock(db_path, exclusive=True, create=False),
    ):
        require_quiescent_database(db_path)
        yield


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
        require_quiescent_database(db_path)
        resolved = db_path.resolve(strict=True)
        uri = f"{resolved.as_uri()}?mode=ro&immutable=1"
        with sqlite3.connect(uri, uri=True) as connection:
            _ = connection.execute("pragma query_only = on")
            _ = connection.execute("pragma foreign_keys = on")
            yield connection


def initialize_database(db_path: Path) -> None:
    pre_receipt_recheck_required = False
    with connect_database(db_path) as connection:
        try:
            _apply_pre_receipt_migrations(connection, db_path)
            if _delivery_receipt_migration_is_complete(connection, db_path):
                return
        except sqlite3.Error:
            connection.rollback()
            pre_receipt_recheck_required = True
    with (
        database_lifecycle_lock(db_path, exclusive=True, create=True),
        _connect_database_under_lifecycle(db_path) as connection,
    ):
        if pre_receipt_recheck_required:
            _apply_pre_receipt_migrations(connection, db_path)
        _apply_migration(connection, DELIVERY_RECEIPT_MIGRATION_ID, db_path)


def _apply_pre_receipt_migrations(
    connection: sqlite3.Connection,
    db_path: Path,
) -> None:
    _apply_initial_migration(connection, db_path, MIGRATION_IDS[0])
    for migration_id in MIGRATION_IDS[1:]:
        if migration_id == DELIVERY_RECEIPT_MIGRATION_ID:
            return
        if _migration_was_applied(connection, migration_id):
            continue
        _apply_migration(connection, migration_id, db_path)

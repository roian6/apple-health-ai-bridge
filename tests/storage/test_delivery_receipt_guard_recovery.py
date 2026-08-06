from __future__ import annotations

import hashlib
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

import health_bridge.storage._database_migrations as database_migrations
from health_bridge.storage import database
from health_bridge.storage.database import initialize_database
from health_bridge.storage.delivery_receipts import insert_delivery_receipt
from health_bridge.storage.migration_backup import (
    delivery_receipt_rollback_guard_path,
    restore_delivery_receipt_backup,
)
from tests.storage.delivery_receipt_migration_support import (
    create_legacy_database,
    run_concurrent_process_upgrades,
)
from tests.storage.delivery_receipt_reopened_support import committed_receipt

if TYPE_CHECKING:
    from collections.abc import Generator


def _pending_path(db_path: Path) -> Path:
    return Path(f"{db_path}.pre-008_delivery_receipts.pending")


def _trace_lifecycle_locks(
    monkeypatch: pytest.MonkeyPatch,
) -> list[bool]:
    lock_modes: list[bool] = []
    original = database.database_lifecycle_lock

    @contextmanager
    def traced_lock(
        db_path: Path,
        *,
        exclusive: bool,
        create: bool,
        nonblocking: bool = False,
    ) -> Generator[None, None, None]:
        lock_modes.append(exclusive)
        with original(
            db_path,
            exclusive=exclusive,
            create=create,
            nonblocking=nonblocking,
        ):
            yield

    monkeypatch.setattr(database, "database_lifecycle_lock", traced_lock)
    return lock_modes


def _interrupt_guard_once(
    db_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fail_after_commit(_db_path: Path) -> None:
        message = "synthetic guard boundary"
        raise OSError(message)

    monkeypatch.setattr(
        database_migrations,
        "finalize_delivery_receipt_rollback_guard",
        fail_after_commit,
    )
    with pytest.raises(OSError, match="synthetic guard boundary"):
        initialize_database(db_path)
    monkeypatch.undo()


def test_restart_repairs_guard_after_migration_commit_boundary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "guard-boundary.sqlite"
    create_legacy_database(db_path)
    original_sha256 = hashlib.sha256(db_path.read_bytes()).hexdigest()
    _interrupt_guard_once(db_path, monkeypatch)

    initialize_database(db_path)

    assert delivery_receipt_rollback_guard_path(db_path).is_file()
    assert not _pending_path(db_path).exists()
    assert restore_delivery_receipt_backup(db_path).value == "restored"
    assert hashlib.sha256(db_path.read_bytes()).hexdigest() == original_sha256


def test_restart_replaces_malformed_guard_when_pending_state_is_valid(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "malformed-guard-recovery.sqlite"
    create_legacy_database(db_path)
    _interrupt_guard_once(db_path, monkeypatch)
    _ = delivery_receipt_rollback_guard_path(db_path).write_text(
        "malformed\n",
        encoding="ascii",
    )

    initialize_database(db_path)

    assert restore_delivery_receipt_backup(db_path).value == "restored"


def test_restart_replaces_stale_guard_when_pending_state_is_valid(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "stale-guard-recovery.sqlite"
    create_legacy_database(db_path)
    _interrupt_guard_once(db_path, monkeypatch)
    before_line = _pending_path(db_path).read_text(encoding="ascii").splitlines()[0]
    stale_guard = f"{before_line}\npost_migration_sha256={'0' * 64}\n"
    _ = delivery_receipt_rollback_guard_path(db_path).write_text(
        stale_guard,
        encoding="ascii",
    )

    initialize_database(db_path)

    assert restore_delivery_receipt_backup(db_path).value == "restored"


def test_applied_migration_with_invalid_guard_cannot_take_fast_path(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "invalid-complete-state.sqlite"
    initialize_database(db_path)
    _ = delivery_receipt_rollback_guard_path(db_path).write_text(
        "malformed\n",
        encoding="ascii",
    )

    # When / Then
    with pytest.raises(OSError, match="invalid delivery receipt migration recovery"):
        initialize_database(db_path)


def test_wrong_receipt_schema_cannot_return_under_shared_lock(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "wrong-receipt-schema.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute("drop table delivery_receipts")
        _ = connection.execute("create table delivery_receipts(dummy text)")
    lock_modes = _trace_lifecycle_locks(monkeypatch)

    # When / Then
    with pytest.raises(OSError, match="invalid delivery receipt schema"):
        initialize_database(db_path)
    assert lock_modes == [False, True]


def test_missing_receipt_table_fails_closed_after_exclusive_recovery(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "missing-receipt-table.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute("drop table delivery_receipts")
    lock_modes = _trace_lifecycle_locks(monkeypatch)

    # When / Then
    with pytest.raises(OSError, match="invalid delivery receipt schema"):
        initialize_database(db_path)
    assert lock_modes == [False, True]
    with sqlite3.connect(db_path) as connection:
        assert (
            connection.execute(
                "select 1 from sqlite_master where type = 'table' and name = ?",
                ("delivery_receipts",),
            ).fetchone()
            is None
        )


def test_malformed_migration_table_reaches_exclusive_recheck_before_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "malformed-schema-migrations.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute("drop table schema_migrations")
        _ = connection.execute("create table schema_migrations(dummy text)")
    lock_modes = _trace_lifecycle_locks(monkeypatch)

    # When / Then
    with pytest.raises(sqlite3.OperationalError):
        initialize_database(db_path)
    assert lock_modes == [False, True]


def test_public_rollback_guard_cannot_take_fast_path(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "public-rollback-guard.sqlite"
    initialize_database(db_path)
    delivery_receipt_rollback_guard_path(db_path).chmod(0o644)
    lock_modes = _trace_lifecycle_locks(monkeypatch)

    # When / Then
    with pytest.raises(OSError, match="invalid delivery receipt migration recovery"):
        initialize_database(db_path)
    assert lock_modes == [False, True]


def test_mismatched_pending_state_fails_closed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "mismatched-pending.sqlite"
    create_legacy_database(db_path)
    _interrupt_guard_once(db_path, monkeypatch)
    _ = _pending_path(db_path).write_text("malformed\n", encoding="ascii")

    with pytest.raises(OSError, match="invalid delivery receipt migration recovery"):
        initialize_database(db_path)

    assert restore_delivery_receipt_backup(db_path).value != "restored"


def test_post_migration_receipt_commit_cannot_be_reclassified_as_safe(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receipt-after-boundary.sqlite"
    create_legacy_database(db_path)
    _interrupt_guard_once(db_path, monkeypatch)
    with sqlite3.connect(db_path) as connection:
        _ = insert_delivery_receipt(connection, committed_receipt())

    with pytest.raises(OSError, match="delivery receipt migration recovery mismatch"):
        initialize_database(db_path)

    assert (
        restore_delivery_receipt_backup(db_path).value == "hold_post_migration_commit"
    )


def test_concurrent_restarts_recover_one_guard(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "concurrent-recovery.sqlite"
    create_legacy_database(db_path)
    original_sha256 = hashlib.sha256(db_path.read_bytes()).hexdigest()
    _interrupt_guard_once(db_path, monkeypatch)

    run_concurrent_process_upgrades(db_path)

    assert delivery_receipt_rollback_guard_path(db_path).is_file()
    assert not _pending_path(db_path).exists()
    assert restore_delivery_receipt_backup(db_path).value == "restored"
    assert hashlib.sha256(db_path.read_bytes()).hexdigest() == original_sha256

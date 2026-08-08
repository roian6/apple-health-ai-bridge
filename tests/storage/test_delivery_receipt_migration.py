from __future__ import annotations

import hashlib
import sqlite3
import subprocess
import tarfile
import zipfile
from dataclasses import replace
from typing import TYPE_CHECKING, Final, TypeAlias

import pytest
from pydantic import TypeAdapter

from health_bridge.storage import database
from health_bridge.storage.database import initialize_database
from health_bridge.storage.delivery_receipts import (
    DeliveryReceiptConflictError,
    DeliveryReceiptRecord,
    fetch_delivery_receipt,
    insert_delivery_receipt,
)
from health_bridge.storage.migration_backup import (
    delivery_receipt_backup_path,
    delivery_receipt_rollback_guard_path,
    restore_delivery_receipt_backup,
)
from tests.storage.delivery_receipt_migration_support import (
    EXPECTED_RECEIPT_COLUMNS,
    PROHIBITED_RECEIPT_COLUMN_PARTS,
    create_legacy_database,
    run_concurrent_process_upgrades,
)

if TYPE_CHECKING:
    from pathlib import Path

MIGRATION_ID = "008_delivery_receipts"
SchemaRow: TypeAlias = tuple[str]
SCHEMA_ROW_ADAPTER: Final[TypeAdapter[SchemaRow | None]] = TypeAdapter(SchemaRow | None)


def _committed_receipt(*, digest_byte: int = 2) -> DeliveryReceiptRecord:
    return DeliveryReceiptRecord(
        receipt_id=11,
        envelope_id=bytes([1]) * 16,
        payload_sha256=bytes([digest_byte]) * 32,
        receiver_id=bytes([3]) * 16,
        device_id=bytes([4]) * 16,
        receiver_agreement_key_id=bytes([13]) * 16,
        sender_signing_key_id=bytes([14]) * 16,
        device_agreement_key_id=bytes([5]) * 16,
        receiver_signing_key_id=bytes([6]) * 16,
        opaque_binding=bytes([7]) * 32,
        connection_generation=8,
        result="committed",
        committed_sync_run_id=1,
        ack_id=bytes([9]) * 16,
        dataset_generation=10,
        committed_at_ms=1_782_000_000_000,
        error_code=None,
    )


def test_fresh_database_adds_receipt_schema_and_pre_migration_backup(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "fresh.sqlite"

    initialize_database(db_path)

    backup_path = delivery_receipt_backup_path(db_path)
    with sqlite3.connect(db_path) as connection:
        migrations = connection.execute(
            "select migration_id from schema_migrations order by migration_id"
        ).fetchall()
    with sqlite3.connect(backup_path) as backup:
        backup_tables = backup.execute(
            "select name from sqlite_master where type = 'table'"
        ).fetchall()
    assert migrations == [(value,) for value in database.MIGRATION_IDS]
    assert ("delivery_receipts",) not in backup_tables


def test_upgrade_preserves_legacy_rows_and_exact_backup_checksum(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "legacy.sqlite"
    create_legacy_database(db_path)
    original_sha256 = hashlib.sha256(db_path.read_bytes()).hexdigest()

    initialize_database(db_path)

    backup_path = delivery_receipt_backup_path(db_path)
    assert hashlib.sha256(backup_path.read_bytes()).hexdigest() == original_sha256
    with sqlite3.connect(db_path) as connection:
        assert connection.execute("select count(*) from sources").fetchone() == (1,)
        assert connection.execute("select count(*) from sync_runs").fetchone() == (1,)


def test_concurrent_process_upgrade_applies_once(tmp_path: Path) -> None:
    db_path = tmp_path / "concurrent.sqlite"
    create_legacy_database(db_path)

    run_concurrent_process_upgrades(db_path)

    with sqlite3.connect(db_path) as connection:
        count = TypeAdapter(tuple[int]).validate_python(
            connection.execute(
                "select count(*) from schema_migrations where migration_id = ?",
                (MIGRATION_ID,),
            ).fetchone()
        )
    assert count == (1,)


def test_failed_migration_keeps_original_and_backup_without_partial_table(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "failure.sqlite"
    create_legacy_database(db_path)
    original_sha256 = hashlib.sha256(db_path.read_bytes()).hexdigest()
    real_connect = sqlite3.connect

    def connect_with_denied_receipt_table(path: Path) -> sqlite3.Connection:
        connection = real_connect(path)

        def authorizer(
            action: int,
            arg1: str | None,
            _arg2: str | None,
            _database_name: str | None,
            _trigger_name: str | None,
        ) -> int:
            if action == sqlite3.SQLITE_CREATE_TABLE and arg1 == "delivery_receipts":
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        _ = connection.set_authorizer(authorizer)
        return connection

    monkeypatch.setattr(sqlite3, "connect", connect_with_denied_receipt_table)

    with pytest.raises(sqlite3.DatabaseError, match="not authorized"):
        initialize_database(db_path)

    backup_path = delivery_receipt_backup_path(db_path)
    assert hashlib.sha256(db_path.read_bytes()).hexdigest() == original_sha256
    assert hashlib.sha256(backup_path.read_bytes()).hexdigest() == original_sha256
    with sqlite3.connect(db_path) as connection:
        partial = connection.execute(
            "select name from sqlite_master where name like '%receipt%'"
        ).fetchall()
    assert partial == []


def test_old_binary_restore_succeeds_before_post_migration_commit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "restorable.sqlite"
    create_legacy_database(db_path)
    original_sha256 = hashlib.sha256(db_path.read_bytes()).hexdigest()
    receipt_index = database.MIGRATION_IDS.index(MIGRATION_ID)
    monkeypatch.setattr(
        database,
        "MIGRATION_IDS",
        database.MIGRATION_IDS[: receipt_index + 1],
    )
    initialize_database(db_path)

    decision = restore_delivery_receipt_backup(db_path)

    assert decision.value == "restored"
    assert hashlib.sha256(db_path.read_bytes()).hexdigest() == original_sha256


def test_old_binary_restore_holds_after_post_migration_commit(tmp_path: Path) -> None:
    db_path = tmp_path / "hold.sqlite"
    create_legacy_database(db_path)
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        _ = insert_delivery_receipt(connection, _committed_receipt())

    decision = restore_delivery_receipt_backup(db_path)

    assert decision.value == "hold_post_migration_commit"
    with sqlite3.connect(db_path) as connection:
        assert connection.execute(
            "select count(*) from delivery_receipts"
        ).fetchone() == (1,)


def test_malformed_rollback_guard_fails_closed(tmp_path: Path) -> None:
    db_path = tmp_path / "malformed-guard.sqlite"
    initialize_database(db_path)
    guard_path = delivery_receipt_rollback_guard_path(db_path)
    _ = guard_path.write_text("not-a-sha256\n", encoding="ascii")

    decision = restore_delivery_receipt_backup(db_path)

    assert decision.value == "hold_invalid_guard"


def test_typed_api_round_trips_committed_ack_regeneration_metadata(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "api.sqlite"
    initialize_database(db_path)
    expected = _committed_receipt()
    with sqlite3.connect(db_path) as connection:
        row_id = insert_delivery_receipt(connection, expected)
        actual = fetch_delivery_receipt(connection, row_id)

    assert actual == expected


def test_authenticated_scope_and_ack_id_collisions_are_rejected(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "collision.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        _ = insert_delivery_receipt(connection, _committed_receipt())
        with pytest.raises(DeliveryReceiptConflictError):
            _ = insert_delivery_receipt(
                connection,
                _committed_receipt(digest_byte=12),
            )


def test_receipt_id_collision_is_rejected_across_distinct_scope(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receipt-id-collision.sqlite"
    initialize_database(db_path)
    original = _committed_receipt()
    duplicate_receipt_id = replace(
        original,
        envelope_id=bytes([10]) * 16,
        ack_id=bytes([11]) * 16,
    )
    with sqlite3.connect(db_path) as connection:
        _ = insert_delivery_receipt(connection, original)
        with pytest.raises(DeliveryReceiptConflictError):
            _ = insert_delivery_receipt(connection, duplicate_receipt_id)


def test_schema_has_only_reviewed_metadata_columns_and_constraints(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "privacy.sqlite"
    initialize_database(db_path)

    with sqlite3.connect(db_path) as connection:
        column_rows = TypeAdapter(
            list[tuple[int, str, str, int, None, int]]
        ).validate_python(
            connection.execute("pragma table_info(delivery_receipts)").fetchall()
        )
        schema_row = SCHEMA_ROW_ADAPTER.validate_python(
            connection.execute(
                "select sql from sqlite_master where type = 'table' and name = ?",
                ("delivery_receipts",),
            ).fetchone()
        )

    assert schema_row is not None
    columns = {row[1] for row in column_rows}
    schema = schema_row[0]
    assert columns == EXPECTED_RECEIPT_COLUMNS
    assert all(part not in columns for part in PROHIBITED_RECEIPT_COLUMN_PARTS)
    assert "unique (receiver_id, device_id, envelope_id)" in schema.lower()
    assert "unique (receipt_id)" in schema.lower()
    assert "unique (ack_id)" in schema.lower()


def test_direct_only_open_leaves_receipt_ledger_dormant(tmp_path: Path) -> None:
    db_path = tmp_path / "direct.sqlite"
    create_legacy_database(db_path)

    initialize_database(db_path)
    initialize_database(db_path)

    with sqlite3.connect(db_path) as connection:
        assert connection.execute("select count(*) from sources").fetchone() == (1,)
        assert connection.execute("select count(*) from sync_runs").fetchone() == (1,)
        assert connection.execute(
            "select count(*) from delivery_receipts"
        ).fetchone() == (0,)


def test_wheel_and_sdist_include_receipt_migration(tmp_path: Path) -> None:
    dist = tmp_path / "dist"
    result = subprocess.run(
        ["uv", "build", "--out-dir", str(dist)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr[-2000:]
    wheel = next(dist.glob("*.whl"))
    sdist = next(dist.glob("*.tar.gz"))
    with zipfile.ZipFile(wheel) as archive:
        assert any(name.endswith(f"/{MIGRATION_ID}.sql") for name in archive.namelist())
    with tarfile.open(sdist) as archive:
        assert any(name.endswith(f"/{MIGRATION_ID}.sql") for name in archive.getnames())

import sqlite3
from datetime import UTC, datetime
from importlib.resources import files
from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter
from typing_extensions import override

from health_bridge.storage._migration_backup_files import (
    DELIVERY_RECEIPT_MIGRATION_ID,
    finalize_delivery_receipt_rollback_guard,
    prepare_delivery_receipt_backup,
)
from health_bridge.storage._migration_recovery import (
    complete_delivery_receipt_recovery,
    delivery_receipt_recovery_is_complete,
    prepare_delivery_receipt_recovery,
    reconcile_delivery_receipt_recovery,
)

MIGRATIONS_PACKAGE: Final = "health_bridge.storage.migrations"
INCOMPLETE_MIGRATION_SQL_ERROR: Final = (
    "migration SQL ended with an incomplete statement"
)
MigrationRow: TypeAlias = tuple[int]
MigrationRecord: TypeAlias = tuple[str, str]
SchemaRow: TypeAlias = tuple[str]
MIGRATION_ROW_ADAPTER: Final[TypeAdapter[MigrationRow | None]] = TypeAdapter(
    MigrationRow | None,
)
SCHEMA_ROW_ADAPTER: Final[TypeAdapter[SchemaRow | None]] = TypeAdapter(
    SchemaRow | None,
)
DELIVERY_RECEIPT_SCHEMA_SQL: Final = (
    files(MIGRATIONS_PACKAGE)
    .joinpath(f"{DELIVERY_RECEIPT_MIGRATION_ID}.sql")
    .read_text()
    .strip()
    .removesuffix(";")
    .replace("create table", "CREATE TABLE", 1)
)


class DeliveryReceiptSchemaStateError(OSError):
    @override
    def __str__(self) -> str:
        return "invalid delivery receipt schema"


def apply_initial_migration(
    connection: sqlite3.Connection,
    db_path: Path,
    initial_migration_id: str,
) -> None:
    if schema_migrations_table_exists(connection) and migration_was_applied(
        connection,
        initial_migration_id,
    ):
        return
    apply_migration(connection, initial_migration_id, db_path)


def schema_migrations_table_exists(connection: sqlite3.Connection) -> bool:
    row = MIGRATION_ROW_ADAPTER.validate_python(
        connection.execute(
            "select 1 from sqlite_master where type = 'table' and name = ?",
            ("schema_migrations",),
        ).fetchone()
    )
    return row is not None


def delivery_receipt_migration_is_complete(
    connection: sqlite3.Connection,
    db_path: Path,
) -> bool:
    if not schema_migrations_table_exists(connection) or not migration_was_applied(
        connection,
        DELIVERY_RECEIPT_MIGRATION_ID,
    ):
        return False
    return delivery_receipt_schema_is_valid(
        connection
    ) and delivery_receipt_recovery_is_complete(db_path)


def delivery_receipt_schema_is_valid(connection: sqlite3.Connection) -> bool:
    receipt_schema = SCHEMA_ROW_ADAPTER.validate_python(
        connection.execute(
            "select sql from sqlite_master where type = 'table' and name = ?",
            ("delivery_receipts",),
        ).fetchone()
    )
    return receipt_schema == (DELIVERY_RECEIPT_SCHEMA_SQL,)


def apply_migration(
    connection: sqlite3.Connection,
    migration_id: str,
    db_path: Path,
) -> None:
    migration_sql = (
        files(MIGRATIONS_PACKAGE).joinpath(f"{migration_id}.sql").read_text()
    )
    needs_backup = migration_id == DELIVERY_RECEIPT_MIGRATION_ID
    applied_at: str | None = None
    if needs_backup:
        _ = connection.execute("pragma wal_checkpoint(truncate)")
        already_applied = schema_migrations_table_exists(
            connection
        ) and migration_was_applied(connection, migration_id)
        _ = reconcile_delivery_receipt_recovery(
            db_path,
            migration_applied=already_applied,
        )
        if already_applied and not delivery_receipt_schema_is_valid(connection):
            raise DeliveryReceiptSchemaStateError
        if not already_applied:
            applied_at = datetime.now(tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
            prepare_delivery_receipt_backup(db_path)
            prepare_delivery_receipt_recovery(
                db_path,
                lambda staged: _stage_migration(
                    staged,
                    migration_sql,
                    (migration_id, applied_at),
                ),
            )
    _ = connection.execute("begin immediate")
    try:
        if schema_migrations_table_exists(connection) and migration_was_applied(
            connection,
            migration_id,
        ):
            connection.commit()
            return
        execute_migration_statements(connection, migration_sql)
        _record_migration(connection, migration_id, applied_at)
        connection.commit()
        if needs_backup:
            if not delivery_receipt_schema_is_valid(connection):
                raise DeliveryReceiptSchemaStateError
            finalize_delivery_receipt_rollback_guard(db_path)
            complete_delivery_receipt_recovery(db_path)
    except sqlite3.Error:
        connection.rollback()
        raise
    except (OSError, ValueError):
        connection.rollback()
        raise


def execute_migration_statements(
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


def _stage_migration(
    connection: sqlite3.Connection,
    migration_sql: str,
    migration_record: MigrationRecord,
) -> None:
    _ = connection.execute("begin immediate")
    try:
        execute_migration_statements(connection, migration_sql)
        _record_migration(connection, *migration_record)
        connection.commit()
    except sqlite3.Error:
        connection.rollback()
        raise
    except ValueError:
        connection.rollback()
        raise


def _record_migration(
    connection: sqlite3.Connection,
    migration_id: str,
    applied_at: str | None,
) -> None:
    if applied_at is None:
        _ = connection.execute(
            "insert into schema_migrations (migration_id) values (?)",
            (migration_id,),
        )
        return
    _ = connection.execute(
        "insert into schema_migrations (migration_id, applied_at) values (?, ?)",
        (migration_id, applied_at),
    )


def migration_was_applied(
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

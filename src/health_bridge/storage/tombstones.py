import sqlite3
from typing import Final, TypeAlias

from pydantic import TypeAdapter

UPSERT_DELETED_RECORD_SQL: Final = (
    "insert into deleted_records (source_id, record_family, client_record_id, "
    "deleted_at) values (?, ?, ?, ?) "
    "on conflict(source_id, record_family, client_record_id) do update set "
    "deleted_at = excluded.deleted_at"
)
DELETE_SAMPLE_SQL: Final = (
    "delete from samples where source_id = ? and client_record_id = ?"
)
DELETE_WORKOUT_SQL: Final = (
    "delete from workouts where source_id = ? and client_record_id = ?"
)
DELETE_SLEEP_SESSION_SQL: Final = (
    "delete from sleep_sessions where source_id = ? and client_record_id = ?"
)
SELECT_TOMBSTONE_SQL: Final = (
    "select 1 from deleted_records "
    "where source_id = ? and record_family = ? and client_record_id = ?"
)
TombstoneRow: TypeAlias = tuple[int]
TOMBSTONE_ROW_ADAPTER: Final[TypeAdapter[TombstoneRow | None]] = TypeAdapter(
    TombstoneRow | None,
)


def upsert_deleted_record(
    connection: sqlite3.Connection,
    *,
    source_id_value: int,
    record_family: str,
    client_record_id: str,
    deleted_at: str,
) -> None:
    _ = connection.execute(
        UPSERT_DELETED_RECORD_SQL,
        (source_id_value, record_family, client_record_id, deleted_at),
    )


def delete_active_record(
    connection: sqlite3.Connection,
    *,
    source_id_value: int,
    record_family: str,
    client_record_id: str,
) -> None:
    if record_family == "sample":
        delete_sql = DELETE_SAMPLE_SQL
    elif record_family == "workout":
        delete_sql = DELETE_WORKOUT_SQL
    elif record_family == "sleep_session":
        delete_sql = DELETE_SLEEP_SESSION_SQL
    else:
        msg = f"Unsupported deleted record family: {record_family}"
        raise ValueError(msg)
    _ = connection.execute(delete_sql, (source_id_value, client_record_id))


def record_is_tombstoned(
    connection: sqlite3.Connection,
    *,
    source_id_value: int,
    record_family: str,
    client_record_id: str,
) -> bool:
    row = TOMBSTONE_ROW_ADAPTER.validate_python(
        connection.execute(
            SELECT_TOMBSTONE_SQL,
            (source_id_value, record_family, client_record_id),
        ).fetchone(),
    )
    return row is not None

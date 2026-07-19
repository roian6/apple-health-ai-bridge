import sqlite3
from typing import Final, TypeAlias

from pydantic import TypeAdapter

SqlParameters: TypeAlias = tuple[()] | tuple[str] | tuple[int, str]
CountRow: TypeAlias = tuple[int]
TextRow: TypeAlias = tuple[str]
SyncStatusRow: TypeAlias = tuple[str, str | None]

COUNT_ROW_ADAPTER: Final = TypeAdapter(CountRow)
TEXT_ROWS_ADAPTER: Final = TypeAdapter(list[TextRow])
SYNC_STATUS_ROW_ADAPTER: Final[TypeAdapter[tuple[str, str | None] | None]] = (
    TypeAdapter(tuple[str, str | None] | None)
)


def fetch_one_int(
    connection: sqlite3.Connection,
    sql: str,
    parameters: SqlParameters = (),
) -> int:
    row = COUNT_ROW_ADAPTER.validate_python(
        connection.execute(sql, parameters).fetchone(),
    )
    return row[0]


def fetch_text_rows(connection: sqlite3.Connection, sql: str) -> list[TextRow]:
    return TEXT_ROWS_ADAPTER.validate_python(connection.execute(sql).fetchall())


def fetch_optional_sync_status(
    connection: sqlite3.Connection,
    sql: str,
) -> SyncStatusRow | None:
    return SYNC_STATUS_ROW_ADAPTER.validate_python(connection.execute(sql).fetchone())

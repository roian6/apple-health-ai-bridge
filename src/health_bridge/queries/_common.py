import sqlite3
from collections.abc import Generator, Iterable
from contextlib import contextmanager
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.queries.models import Period, SourceUsed
from health_bridge.storage.database import connect_readonly_database

DEFAULT_LIMIT: Final = 500
EMPTY_RESULT_NOTE: Final = (
    "No matching records were found; availability is unknown and may reflect "
    "no record, permission limits, source gaps, or sync gaps."
)
LIMITED_STORE_NOTE: Final = (
    "Returned observations reflect only records present in this local SQLite "
    "store for the requested period; absent records remain unknown."
)

SourceRow: TypeAlias = tuple[str, str, str]
PeriodRow: TypeAlias = tuple[str | None, str | None]
SOURCE_ROWS_ADAPTER: Final[TypeAdapter[list[SourceRow]]] = TypeAdapter(
    list[SourceRow],
)
PERIOD_ROW_ADAPTER: Final[TypeAdapter[PeriodRow | None]] = TypeAdapter(
    PeriodRow | None,
)
STORE_PERIOD_SQL: Final = """
select min(start_time), max(end_time) from (
    select start_time, end_time from samples
    union all select start_time, end_time from workouts
    union all select start_time, end_time from sleep_sessions
)
"""
LATEST_SYNC_PERIOD_SQL: Final = """
select sync_window_start, sync_window_end from sync_runs
where status = 'succeeded'
and sync_window_start is not null
and sync_window_end is not null
order by sync_run_id desc limit 1
"""


@contextmanager
def connect_readonly(db_path: Path) -> Generator[sqlite3.Connection, None, None]:
    with connect_readonly_database(db_path) as connection:
        yield connection


def date_bounds(start_date: str, end_date: str) -> tuple[str, str]:
    return (f"{start_date}T00:00:00Z", f"{end_date}T00:00:00Z")


def daily_dates(start_date: str, end_date: str) -> tuple[str, ...]:
    current = date.fromisoformat(start_date)
    end = date.fromisoformat(end_date)
    days: list[str] = []
    while current < end:
        days.append(current.isoformat())
        current += timedelta(days=1)
    return tuple(days)


def seconds_between(start_time: str, end_time: str) -> int:
    start = datetime.strptime(start_time, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=UTC,
    )
    end = datetime.strptime(end_time, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    return int((end - start).total_seconds())


def source_from_row(row: SourceRow) -> SourceUsed:
    source_key, name, kind = row
    return SourceUsed(source_key=source_key, name=name, kind=kind)


def unique_sources(sources: Iterable[SourceUsed]) -> tuple[SourceUsed, ...]:
    by_key: dict[str, SourceUsed] = {}
    for source in sources:
        if source.source_key not in by_key:
            by_key[source.source_key] = source
    return tuple(by_key[key] for key in sorted(by_key))


def fetch_all_sources(connection: sqlite3.Connection) -> tuple[SourceUsed, ...]:
    rows = SOURCE_ROWS_ADAPTER.validate_python(
        connection.execute(
            "select source_key, name, kind from sources order by source_key",
        ).fetchall(),
    )
    return tuple(source_from_row(row) for row in rows)


def fetch_store_period(connection: sqlite3.Connection) -> Period:
    sync_period = _fetch_latest_sync_period(connection)
    if sync_period is not None:
        return sync_period
    row = PERIOD_ROW_ADAPTER.validate_python(
        connection.execute(STORE_PERIOD_SQL).fetchone(),
    )
    if row is None or row[0] is None or row[1] is None:
        return Period(start="", end="")
    return Period(start=row[0], end=row[1])


def _fetch_latest_sync_period(connection: sqlite3.Connection) -> Period | None:
    try:
        row = PERIOD_ROW_ADAPTER.validate_python(
            connection.execute(LATEST_SYNC_PERIOD_SQL).fetchone(),
        )
    except sqlite3.OperationalError:
        return None
    if row is None or row[0] is None or row[1] is None:
        return None
    return Period(start=row[0], end=row[1])


def notes_for_count(row_count: int) -> tuple[str, ...]:
    if row_count == 0:
        return (EMPTY_RESULT_NOTE,)
    return (LIMITED_STORE_NOTE,)

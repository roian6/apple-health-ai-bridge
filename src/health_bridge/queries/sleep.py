from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.queries._common import (
    connect_readonly,
    date_bounds,
    notes_for_count,
    seconds_between,
    source_from_row,
    unique_sources,
)
from health_bridge.queries.models import Period, SleepSummaryResult, SourceUsed

SleepStageRow: TypeAlias = tuple[str, str, str]
SleepSourceRow: TypeAlias = tuple[str, str, str]
SLEEP_STAGE_ROWS_ADAPTER: Final[TypeAdapter[list[SleepStageRow]]] = TypeAdapter(
    list[SleepStageRow],
)
SLEEP_SOURCE_ROWS_ADAPTER: Final[TypeAdapter[list[SleepSourceRow]]] = TypeAdapter(
    list[SleepSourceRow],
)
COUNT_ADAPTER: Final[TypeAdapter[tuple[int]]] = TypeAdapter(tuple[int])

SLEEP_STAGE_SQL: Final = (
    "select intervals.stage, intervals.start_time, intervals.end_time "
    "from sleep_stage_intervals intervals "
    "join sleep_sessions sessions "
    "on sessions.sleep_session_id = intervals.sleep_session_id "
    "where sessions.start_time >= ? and sessions.start_time < ? "
    "order by intervals.start_time"
)
SLEEP_SOURCES_SQL: Final = (
    "select distinct sources.source_key, sources.name, sources.kind "
    "from sleep_sessions sessions "
    "join sources on sources.source_id = sessions.source_id "
    "where sessions.start_time >= ? and sessions.start_time < ? "
    "order by sources.source_key"
)
SLEEP_COUNT_SQL: Final = (
    "select count(*) from sleep_sessions where start_time >= ? and start_time < ?"
)


def get_sleep_summary(
    db_path: Path,
    start_date: str,
    end_date: str,
) -> SleepSummaryResult:
    start_time, end_time = date_bounds(start_date, end_date)
    with connect_readonly(db_path) as connection:
        stage_rows = SLEEP_STAGE_ROWS_ADAPTER.validate_python(
            connection.execute(SLEEP_STAGE_SQL, (start_time, end_time)).fetchall(),
        )
        source_rows = SLEEP_SOURCE_ROWS_ADAPTER.validate_python(
            connection.execute(SLEEP_SOURCES_SQL, (start_time, end_time)).fetchall(),
        )
        session_count = COUNT_ADAPTER.validate_python(
            connection.execute(SLEEP_COUNT_SQL, (start_time, end_time)).fetchone(),
        )[0]
    stage_seconds = _stage_seconds(stage_rows)
    sources = _sources(source_rows)
    return SleepSummaryResult(
        period=Period(start=start_date, end=end_date),
        session_count=session_count,
        stage_seconds=stage_seconds,
        sources_used=sources,
        missing_data_notes=notes_for_count(session_count),
        truncated=False,
    )


def _stage_seconds(rows: list[SleepStageRow]) -> dict[str, int]:
    totals: dict[str, int] = {}
    for stage, start_time, end_time in rows:
        totals[stage] = totals.get(stage, 0) + seconds_between(start_time, end_time)
    return dict(sorted(totals.items()))


def _sources(rows: list[SleepSourceRow]) -> tuple[SourceUsed, ...]:
    return unique_sources(source_from_row(row) for row in rows)

from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter, ValidationError

from health_bridge.queries._common import (
    connect_readonly,
    daily_dates,
    date_bounds,
    notes_for_count,
    source_from_row,
    unique_sources,
)
from health_bridge.queries.models import (
    DailyObservation,
    DailySampleStatistic,
    DailySummaryResult,
    Period,
    SourceUsed,
)
from health_bridge.timeseries_catalog import timeseries_aggregation_for

SampleDailyRow: TypeAlias = tuple[str, str, str, float, str, str]
WorkoutDailyRow: TypeAlias = tuple[str, int]
SleepDailyRow: TypeAlias = tuple[str, int]
DailySourceRow: TypeAlias = tuple[str, str, str]
SAMPLE_DAILY_ROWS_ADAPTER: Final[TypeAdapter[list[SampleDailyRow]]] = TypeAdapter(
    list[SampleDailyRow],
)
COUNT_DAILY_ROWS_ADAPTER: Final[TypeAdapter[list[WorkoutDailyRow]]] = TypeAdapter(
    list[WorkoutDailyRow],
)
DAILY_SOURCE_ROWS_ADAPTER: Final[TypeAdapter[list[DailySourceRow]]] = TypeAdapter(
    list[DailySourceRow],
)
METADATA_ADAPTER: Final[TypeAdapter[dict[str, object]]] = TypeAdapter(
    dict[str, object],
)


SAMPLE_DAILY_SQL: Final = (
    "select coalesce(cast(json_extract(metadata_json, '$.calendar_day') as text), "
    "substr(start_time, 1, 10)) as day, type_code, start_time, value, "
    "unit, metadata_json from samples where "
    "(start_time >= ? and start_time < ?) "
    "or (json_extract(metadata_json, '$.calendar_day') >= ? "
    "and json_extract(metadata_json, '$.calendar_day') < ?) "
    "order by day, type_code, start_time"
)
WORKOUT_DAILY_SQL: Final = (
    "select substr(start_time, 1, 10) as day, count(*) "
    "from workouts where start_time >= ? and start_time < ? "
    "group by day order by day"
)
SLEEP_DAILY_SQL: Final = (
    "select substr(start_time, 1, 10) as day, count(*) "
    "from sleep_sessions where start_time >= ? and start_time < ? "
    "group by day order by day"
)
DAILY_SOURCES_SQL: Final = (
    "select distinct sources.source_key, sources.name, sources.kind "
    "from sources join ("
    "select source_id from samples where "
    "(start_time >= ? and start_time < ?) "
    "or (json_extract(metadata_json, '$.calendar_day') >= ? "
    "and json_extract(metadata_json, '$.calendar_day') < ?) "
    "union select source_id from workouts where start_time >= ? and start_time < ? "
    "union select source_id from sleep_sessions where start_time >= ? "
    "and start_time < ?"
    ") used_sources on used_sources.source_id = sources.source_id "
    "order by sources.source_key"
)


def get_daily_summary(
    db_path: Path,
    start_date: str,
    end_date: str,
) -> DailySummaryResult:
    start_time, end_time = date_bounds(start_date, end_date)
    with connect_readonly(db_path) as connection:
        sample_rows = SAMPLE_DAILY_ROWS_ADAPTER.validate_python(
            connection.execute(
                SAMPLE_DAILY_SQL,
                (start_time, end_time, start_date, end_date),
            ).fetchall(),
        )
        workout_rows = COUNT_DAILY_ROWS_ADAPTER.validate_python(
            connection.execute(WORKOUT_DAILY_SQL, (start_time, end_time)).fetchall(),
        )
        sleep_rows = COUNT_DAILY_ROWS_ADAPTER.validate_python(
            connection.execute(SLEEP_DAILY_SQL, (start_time, end_time)).fetchall(),
        )
        source_rows = DAILY_SOURCE_ROWS_ADAPTER.validate_python(
            connection.execute(
                DAILY_SOURCES_SQL,
                (
                    start_time,
                    end_time,
                    start_date,
                    end_date,
                    start_time,
                    end_time,
                    start_time,
                    end_time,
                ),
            ).fetchall(),
        )
        sources = _sources(source_rows)
    days = _daily_observations(
        start_date,
        end_date,
        sample_rows,
        workout_rows,
        sleep_rows,
    )
    observed_count = sum(
        len(day.sample_counts) + day.workout_count + day.sleep_session_count
        for day in days
    )
    return DailySummaryResult(
        period=Period(start=start_date, end=end_date),
        days=days,
        sources_used=sources if observed_count > 0 else (),
        missing_data_notes=notes_for_count(observed_count),
        truncated=False,
    )


def _daily_observations(
    start_date: str,
    end_date: str,
    sample_rows: list[SampleDailyRow],
    workout_rows: list[WorkoutDailyRow],
    sleep_rows: list[SleepDailyRow],
) -> tuple[DailyObservation, ...]:
    sample_statistics = _sample_statistics_by_day(sample_rows)
    sample_totals: dict[str, dict[str, float]] = {}
    sample_total_semantics: dict[str, dict[str, str]] = {}
    daily_activity_totals: dict[str, dict[str, float]] = {}
    sample_counts: dict[str, dict[str, int]] = {}
    sample_rows_by_day_type: dict[str, dict[str, list[SampleDailyRow]]] = {}
    for row in sample_rows:
        day, type_code, *_ = row
        sample_rows_by_day_type.setdefault(day, {}).setdefault(type_code, []).append(
            row
        )
    for day, statistics_by_type in sample_statistics.items():
        for type_code, statistic in statistics_by_type.items():
            sample_counts.setdefault(day, {})[type_code] = statistic.count
            if statistic.aggregation == "sum" and statistic.total is not None:
                rows = sample_rows_by_day_type.get(day, {}).get(type_code, [])
                sample_totals.setdefault(day, {})[type_code] = statistic.total
                semantics = _sum_semantics_for(rows)
                sample_total_semantics.setdefault(day, {})[type_code] = semantics
                daily_total = _daily_aggregate_total(rows)
                if daily_total is not None:
                    daily_activity_totals.setdefault(day, {})[type_code] = daily_total
    workout_counts = dict(workout_rows)
    sleep_counts = dict(sleep_rows)
    return tuple(
        DailyObservation(
            date=day,
            sample_totals=sample_totals.get(day, {}),
            sample_total_semantics=sample_total_semantics.get(day, {}),
            daily_activity_totals=daily_activity_totals.get(day, {}),
            sample_counts=sample_counts.get(day, {}),
            sample_statistics=sample_statistics.get(day, {}),
            workout_count=workout_counts.get(day, 0),
            sleep_session_count=sleep_counts.get(day, 0),
        )
        for day in daily_dates(start_date, end_date)
    )


def _sample_statistics_by_day(
    sample_rows: list[SampleDailyRow],
) -> dict[str, dict[str, DailySampleStatistic]]:
    grouped: dict[str, dict[str, list[SampleDailyRow]]] = {}
    for row in sample_rows:
        day, type_code, *_ = row
        grouped.setdefault(day, {}).setdefault(type_code, []).append(row)
    return {
        day: {
            type_code: _sample_statistic(type_code, rows)
            for type_code, rows in sorted(rows_by_type.items())
        }
        for day, rows_by_type in sorted(grouped.items())
    }


def _sample_statistic(
    type_code: str,
    rows: list[SampleDailyRow],
) -> DailySampleStatistic:
    sorted_rows = sorted(rows, key=lambda row: (row[2], row[1]))
    values = [row[3] for row in sorted_rows]
    aggregation = _aggregation_for(type_code, sorted_rows)
    units = {row[4] for row in sorted_rows}
    latest_row = None
    if aggregation == "latest":
        latest_row = max(sorted_rows, key=lambda row: row[2])
    unit = latest_row[4] if latest_row is not None else sorted_rows[0][4]
    if aggregation != "latest" and len(units) > 1:
        return DailySampleStatistic(
            unit="mixed",
            aggregation="mixed_units",
            count=len(values),
            total=None,
            average=None,
            minimum=None,
            maximum=None,
            latest=None,
            latest_time=None,
        )
    total = sum(values) if aggregation == "sum" else None
    average = (sum(values) / len(values)) if aggregation == "min_max_average" else None
    minimum = min(values) if aggregation == "min_max_average" else None
    maximum = max(values) if aggregation == "min_max_average" else None
    return DailySampleStatistic(
        unit=unit,
        aggregation=aggregation,
        count=len(values),
        total=total,
        average=average,
        minimum=minimum,
        maximum=maximum,
        latest=latest_row[3] if latest_row is not None else None,
        latest_time=latest_row[2] if latest_row is not None else None,
    )


def _aggregation_for(type_code: str, rows: list[SampleDailyRow]) -> str:
    for row in rows:
        metadata_aggregation = _metadata_aggregation(row[5])
        if metadata_aggregation is not None:
            return metadata_aggregation
    timeseries_catalog_aggregation = timeseries_aggregation_for(type_code)
    if timeseries_catalog_aggregation is not None:
        return timeseries_catalog_aggregation
    return "min_max_average"


def _sum_semantics_for(rows: list[SampleDailyRow]) -> str:
    semantics: set[str] = set()
    for row in rows:
        metadata = _metadata(row[5])
        if _metadata_indicates_daily_aggregate(metadata):
            semantics.add("daily_aggregate")
        elif _metadata_indicates_raw_sample_sum(metadata):
            semantics.add("raw_sample_sum")
    if not semantics:
        return "unknown_sum"
    if len(semantics) == 1:
        return next(iter(semantics))
    return "mixed_sum_semantics"


def _daily_aggregate_total(rows: list[SampleDailyRow]) -> float | None:
    daily_rows = [
        row for row in rows if _metadata_indicates_daily_aggregate(_metadata(row[5]))
    ]
    if not daily_rows:
        return None
    units = {row[4] for row in daily_rows}
    if len(units) != 1:
        return None
    return sum(row[3] for row in daily_rows)


def _metadata(metadata_json: str) -> dict[str, object]:
    try:
        return METADATA_ADAPTER.validate_json(metadata_json)
    except ValidationError:
        return {}


def _metadata_indicates_daily_aggregate(metadata: dict[str, object]) -> bool:
    aggregation = metadata.get("aggregation")
    healthkit_query = metadata.get("healthkit_query")
    return (
        aggregation == "daily_sum" or healthkit_query == "HKStatisticsCollectionQuery"
    )


def _metadata_indicates_raw_sample_sum(metadata: dict[str, object]) -> bool:
    sample_kind = metadata.get("sample_kind")
    healthkit_query = metadata.get("healthkit_query")
    healthkit_object_kind = metadata.get("healthkit_object_kind")
    return (
        sample_kind == "raw_quantity"
        or healthkit_query == "HKAnchoredObjectQuery"
        or healthkit_object_kind == "quantity"
    )


def _metadata_aggregation(metadata_json: str) -> str | None:
    metadata = _metadata(metadata_json)
    aggregation = metadata.get("aggregation")
    if not isinstance(aggregation, str):
        return None
    return _normalize_aggregation(aggregation)


def _normalize_aggregation(aggregation: str) -> str | None:
    normalized = aggregation.strip().lower()
    if normalized in {"sum", "daily_sum"}:
        return "sum"
    if normalized in {"min_max_average", "average", "avg"}:
        return "min_max_average"
    if normalized == "latest":
        return "latest"
    return None


def _sources(rows: list[DailySourceRow]) -> tuple[SourceUsed, ...]:
    return unique_sources(source_from_row(row) for row in rows)

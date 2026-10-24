import sqlite3
from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.queries._common import (
    EMPTY_RESULT_NOTE,
    connect_readonly,
    fetch_all_sources,
    fetch_latest_sync_window,
)
from health_bridge.queries.models import Metric, Period, SyncedMetricsResult

CatalogueRow: TypeAlias = tuple[
    str | None, str, str, str, str, int, str | None, str | None
]
CATALOGUE_ROWS_ADAPTER: Final[TypeAdapter[list[CatalogueRow]]] = TypeAdapter(
    list[CatalogueRow],
)
CATALOGUE_COVERAGE_NOTES: Final = (
    (
        "Counts include all records currently retained in this local store. Stored "
        "bounds are record extents, not continuous coverage or proof of complete "
        "backfill, permissions, freshness, or current daily projections. Missing "
        "records remain unknown."
    ),
    (
        "latest_sync_window describes the most recently ingested successful batch "
        "with complete window metadata, not synchronization completeness for every "
        "metric. period is deprecated legacy metadata; use stored_coverage and "
        "latest_sync_window instead."
    ),
)

LIST_METRICS_SQL: Final = """
with sample_counts as (
    select type_code, count(*) as sample_count,
           min(start_time) as first_record_start,
           max(end_time) as latest_record_end
    from samples group by type_code
),
workout_counts as (
    select count(*) as workout_count,
           min(start_time) as first_record_start,
           max(end_time) as latest_record_end
    from workouts
),
sleep_counts as (
    select count(*) as sleep_count,
           min(start_time) as first_record_start,
           max(end_time) as latest_record_end
    from sleep_sessions
),
metric_catalog as (
    select type_code, display_name, category, default_unit, sensitivity
    from health_types
    union all
    select 'workout', 'Workouts', 'activity', 'session', 'moderate'
    where (select workout_count from workout_counts) > 0
      and not exists (select 1 from health_types where type_code = 'workout')
    union all
    select 'sleep_analysis', 'Sleep Analysis', 'sleep', 'stage', 'moderate'
    where (select sleep_count from sleep_counts) > 0
      and not exists (
          select 1 from health_types where type_code = 'sleep_analysis'
      )
)
select ht.type_code, ht.display_name, ht.category, ht.default_unit,
       ht.sensitivity,
       case
           when ht.type_code = 'workout'
           then coalesce(workout_counts.workout_count, 0)
           when ht.type_code = 'sleep_analysis'
           then coalesce(sleep_counts.sleep_count, 0)
           else coalesce(sample_counts.sample_count, 0)
       end as record_count,
       case
           when ht.type_code = 'workout'
           then workout_counts.first_record_start
           when ht.type_code = 'sleep_analysis'
           then sleep_counts.first_record_start
           else sample_counts.first_record_start
       end as first_record_start,
       case
           when ht.type_code = 'workout'
           then workout_counts.latest_record_end
           when ht.type_code = 'sleep_analysis'
           then sleep_counts.latest_record_end
           else sample_counts.latest_record_end
       end as latest_record_end
from metric_catalog ht
left join sample_counts on sample_counts.type_code = ht.type_code
left join workout_counts
left join sleep_counts
union all
select null, '', '', '', '', coalesce(sum(record_count), 0),
       min(first_record_start), max(latest_record_end)
from (
    select sample_count as record_count, first_record_start, latest_record_end
    from sample_counts
    union all select workout_count, first_record_start, latest_record_end
    from workout_counts
    union all select sleep_count, first_record_start, latest_record_end
    from sleep_counts
)
order by 1
"""


def list_synced_metrics(db_path: Path) -> SyncedMetricsResult:
    with connect_readonly(db_path) as connection:
        metrics, stored_coverage, record_count = _fetch_catalogue(connection)
        latest_sync_window = fetch_latest_sync_window(connection)

        empty_notes = (EMPTY_RESULT_NOTE,) if record_count == 0 else ()

        return SyncedMetricsResult(
            period=latest_sync_window or stored_coverage or Period(start="", end=""),
            stored_coverage=stored_coverage,
            latest_sync_window=latest_sync_window,
            metrics=metrics,
            sources_used=fetch_all_sources(connection),
            missing_data_notes=empty_notes + CATALOGUE_COVERAGE_NOTES,
            truncated=False,
        )


def _fetch_catalogue(
    connection: sqlite3.Connection,
) -> tuple[tuple[Metric, ...], Period | None, int]:
    rows = CATALOGUE_ROWS_ADAPTER.validate_python(
        connection.execute(LIST_METRICS_SQL).fetchall(),
    )

    metrics: list[Metric] = []
    stored_coverage = None
    stored_record_count = 0
    for (
        type_code,
        display_name,
        category,
        default_unit,
        sensitivity,
        record_count,
        first_record_start,
        latest_record_end,
    ) in rows:
        # The null type marks the raw-family summary, including samples
        # whose type codes also have dedicated session counts.
        if type_code is None:
            stored_record_count = record_count
            if first_record_start is not None and latest_record_end is not None:
                stored_coverage = Period(
                    start=first_record_start, end=latest_record_end
                )

            continue

        metrics.append(
            Metric(
                type_code=type_code,
                display_name=display_name,
                category=category,
                default_unit=default_unit,
                sensitivity=sensitivity,
                record_count=record_count,
                first_record_start=first_record_start,
                latest_record_end=latest_record_end,
            )
        )

    return tuple(metrics), stored_coverage, stored_record_count

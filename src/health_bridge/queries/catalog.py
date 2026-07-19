import sqlite3
from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.queries._common import (
    connect_readonly,
    fetch_all_sources,
    fetch_store_period,
    notes_for_count,
)
from health_bridge.queries.models import Metric, SyncedMetricsResult

MetricRow: TypeAlias = tuple[str, str, str, str, str, int]
METRIC_ROWS_ADAPTER: Final[TypeAdapter[list[MetricRow]]] = TypeAdapter(
    list[MetricRow],
)

LIST_METRICS_SQL: Final = """
with metric_catalog as (
    select type_code, display_name, category, default_unit, sensitivity
    from health_types
    union all
    select 'workout', 'Workouts', 'activity', 'session', 'moderate'
    where exists (select 1 from workouts)
      and not exists (select 1 from health_types where type_code = 'workout')
    union all
    select 'sleep_analysis', 'Sleep Analysis', 'sleep', 'stage', 'moderate'
    where exists (select 1 from sleep_sessions)
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
       end as record_count
from metric_catalog ht
left join (
    select type_code, count(*) as sample_count from samples group by type_code
) sample_counts on sample_counts.type_code = ht.type_code
left join (
    select count(*) as workout_count from workouts
) workout_counts
left join (
    select count(*) as sleep_count from sleep_sessions
) sleep_counts
order by ht.type_code
"""


def list_synced_metrics(db_path: Path) -> SyncedMetricsResult:
    with connect_readonly(db_path) as connection:
        metrics = _fetch_metrics(connection)
        return SyncedMetricsResult(
            period=fetch_store_period(connection),
            metrics=metrics,
            sources_used=fetch_all_sources(connection),
            missing_data_notes=notes_for_count(len(metrics)),
            truncated=False,
        )


def _fetch_metrics(connection: sqlite3.Connection) -> tuple[Metric, ...]:
    rows = METRIC_ROWS_ADAPTER.validate_python(
        connection.execute(LIST_METRICS_SQL).fetchall(),
    )
    return tuple(
        Metric(
            type_code=type_code,
            display_name=display_name,
            category=category,
            default_unit=default_unit,
            sensitivity=sensitivity,
            record_count=record_count,
        )
        for (
            type_code,
            display_name,
            category,
            default_unit,
            sensitivity,
            record_count,
        ) in rows
    )

from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.queries._common import (
    DEFAULT_LIMIT,
    connect_readonly,
    date_bounds,
    notes_for_count,
    source_from_row,
    unique_sources,
)
from health_bridge.queries.models import Period, WorkoutObservation, WorkoutsResult

WorkoutRow: TypeAlias = tuple[
    str,
    str,
    str,
    int,
    float | None,
    float | None,
    str,
    str,
    str,
]
WORKOUT_ROWS_ADAPTER: Final[TypeAdapter[list[WorkoutRow]]] = TypeAdapter(
    list[WorkoutRow],
)

WORKOUTS_SQL: Final = (
    "select workouts.workout_type, workouts.start_time, workouts.end_time, "
    "workouts.duration_seconds, workouts.energy_kcal, workouts.distance_meters, "
    "sources.source_key, sources.name, sources.kind "
    "from workouts join sources on sources.source_id = workouts.source_id "
    "where workouts.start_time >= ? and workouts.start_time < ? "
    "order by workouts.start_time, workouts.workout_type "
    "limit ?"
)


def get_workouts(
    db_path: Path,
    start_date: str,
    end_date: str,
    limit: int = DEFAULT_LIMIT,
) -> WorkoutsResult:
    start_time, end_time = date_bounds(start_date, end_date)
    with connect_readonly(db_path) as connection:
        rows = WORKOUT_ROWS_ADAPTER.validate_python(
            connection.execute(
                WORKOUTS_SQL,
                (start_time, end_time, limit + 1),
            ).fetchall(),
        )
    truncated = len(rows) > limit
    workouts = tuple(_workout_from_row(row) for row in rows[:limit])
    return WorkoutsResult(
        period=Period(start=start_date, end=end_date),
        workouts=workouts,
        sources_used=unique_sources(workout.source for workout in workouts),
        missing_data_notes=notes_for_count(len(workouts)),
        truncated=truncated,
    )


def _workout_from_row(row: WorkoutRow) -> WorkoutObservation:
    (
        workout_type,
        start_time,
        end_time,
        duration_seconds,
        energy_kcal,
        distance_meters,
        source_key,
        name,
        kind,
    ) = row
    return WorkoutObservation(
        workout_type=workout_type,
        start_time=start_time,
        end_time=end_time,
        duration_seconds=duration_seconds,
        energy_kcal=energy_kcal,
        distance_meters=distance_meters,
        source=source_from_row((source_key, name, kind)),
    )

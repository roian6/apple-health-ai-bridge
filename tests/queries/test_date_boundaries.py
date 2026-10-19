import math
from datetime import datetime, timedelta
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.ingest import ingest_fixture
from health_bridge.queries import (
    get_daily_summary,
    get_sleep_summary,
    get_timeseries,
    get_workouts,
)
from health_bridge.storage.database import connect_database
from tests.fixture_helpers import FIXTURE_PATH

if TYPE_CHECKING:
    from health_bridge.contract.batch_v1 import Sample, SleepSession, Workout

STARTS = (
    "2026-06-09T23:00:00Z",
    "2026-06-10T00:00:00Z",
    "2026-06-10T23:00:00Z",
    "2026-06-11T00:00:00Z",
)


@pytest.fixture
def boundary_db(tmp_path: Path) -> Path:
    fixture = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    samples: list[Sample] = []
    workouts: list[Workout] = []
    sessions: list[SleepSession] = []
    for index, start in enumerate(STARTS):
        end = (datetime.fromisoformat(start) + timedelta(hours=2)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        interval = {"start_time": start, "end_time": end}
        record = {**interval, "client_record_id": f"synthetic-boundary-{index}"}
        samples.append(
            fixture.samples[1].model_copy(update={**record, "value": float(index + 1)})
        )
        workouts.append(
            fixture.workouts[0].model_copy(update={**record, "duration_seconds": 7200})
        )
        stage = fixture.sleep_sessions[0].stage_intervals[1].model_copy(update=interval)
        sessions.append(
            fixture.sleep_sessions[0].model_copy(
                update={**record, "stage_intervals": (stage,)}
            )
        )
    batch = fixture.model_copy(
        update={
            "samples": tuple(samples),
            "workouts": tuple(workouts),
            "sleep_sessions": tuple(sessions),
            "deleted_records": (),
            "sync": fixture.sync.model_copy(update={"cursors": ()}),
        }
    )
    input_path = tmp_path / "boundaries.synthetic.json"
    _ = input_path.write_text(batch.model_dump_json(), encoding="utf-8")
    db_path = tmp_path / "boundaries.sqlite"
    _ = ingest_fixture(db_path, input_path)
    return db_path


def test_timeseries_selects_start_in_half_open_utc_interval(boundary_db: Path) -> None:
    # Given / When: samples before, at, within, and at the end boundary.
    result = get_timeseries(
        boundary_db,
        type_codes=("heart_rate",),
        start_time=STARTS[1],
        end_time=STARTS[3],
    )
    # Then: overlap alone is insufficient; selected records are not clipped.
    assert tuple(point.start_time for point in result.points) == STARTS[1:3]
    assert result.points[-1].end_time == "2026-06-11T01:00:00Z"


def test_workouts_select_start_not_overlap_and_keep_full_duration(
    boundary_db: Path,
) -> None:
    # Given / When
    result = get_workouts(boundary_db, start_date="2026-06-10", end_date="2026-06-11")
    # Then
    assert tuple(workout.start_time for workout in result.workouts) == STARTS[1:3]
    assert tuple(workout.duration_seconds for workout in result.workouts) == (
        7200,
        7200,
    )
    assert result.workouts[-1].end_time == "2026-06-11T01:00:00Z"


def test_sleep_selects_session_start_and_sums_unclipped_stages(
    boundary_db: Path,
) -> None:
    # Given / When
    result = get_sleep_summary(
        boundary_db, start_date="2026-06-10", end_date="2026-06-11"
    )
    # Then: excludes the earlier overlapping session and includes the late tail.
    assert result.session_count == 2
    assert result.stage_seconds == {"core": 14400}


def test_daily_summary_groups_by_utc_start_and_excludes_end_date(
    boundary_db: Path,
) -> None:
    # Given / When
    result = get_daily_summary(
        boundary_db, start_date="2026-06-10", end_date="2026-06-11"
    )
    # Then
    assert tuple(day.date for day in result.days) == ("2026-06-10",)
    day = result.days[0]
    assert day.sample_counts == {"heart_rate": 2}
    assert day.sample_statistics["heart_rate"].average == 2.5
    assert (day.workout_count, day.sleep_session_count) == (2, 2)


def test_daily_calendar_day_takes_precedence_over_utc_start(boundary_db: Path) -> None:
    # Given: local calendar days can differ from the sample's UTC date.
    with connect_database(boundary_db) as connection:
        _ = connection.executemany(
            "update samples set metadata_json = ? where start_time = ?",
            (
                ('{"calendar_day":"2026-06-10"}', STARTS[0]),
                ('{"calendar_day":"2026-06-11"}', STARTS[1]),
                ('{"calendar_day":"2026-06-10"}', STARTS[3]),
            ),
        )
    # When
    result = get_daily_summary(
        boundary_db, start_date="2026-06-10", end_date="2026-06-11"
    )
    # Then: calendar-day inclusion works on either side of the UTC bounds.
    assert result.days[0].sample_counts == {"heart_rate": 3}
    average = result.days[0].sample_statistics["heart_rate"].average
    assert average is not None
    assert math.isclose(average, 8 / 3)


def test_equal_date_bounds_return_no_sessions_or_days(boundary_db: Path) -> None:
    # Given / When: equal boundaries are accepted as an empty interval.
    workouts = get_workouts(boundary_db, start_date="2026-06-10", end_date="2026-06-10")
    sleep = get_sleep_summary(
        boundary_db, start_date="2026-06-10", end_date="2026-06-10"
    )
    daily = get_daily_summary(
        boundary_db, start_date="2026-06-10", end_date="2026-06-10"
    )
    # Then
    assert workouts.workouts == ()
    assert sleep.session_count == 0
    assert sleep.stage_seconds == {}
    assert daily.days == ()

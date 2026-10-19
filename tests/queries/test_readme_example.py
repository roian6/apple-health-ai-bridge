from pathlib import Path

import pytest

from health_bridge.ingest import ingest_fixture
from health_bridge.queries import get_sleep_summary, get_workouts


@pytest.mark.parametrize(
    ("period", "expected"),
    [
        (("2026-06-01", "2026-06-08"), (444, 4, 160)),
        (("2026-06-08", "2026-06-15"), (402, 2, 80)),
    ],
)
def test_readme_weekly_comparison_matches_the_query_results(
    tmp_path: Path,
    period: tuple[str, str],
    expected: tuple[int, int, int],
) -> None:
    start_date, end_date = period
    sleep_minutes, workout_count, workout_minutes = expected
    db = tmp_path / "sample.sqlite"
    _ = ingest_fixture(db, Path("fixtures/readme-weekly-review.synthetic.json"))

    sleep = get_sleep_summary(db, start_date=start_date, end_date=end_date)
    workouts = get_workouts(db, start_date=start_date, end_date=end_date)

    assert sleep.session_count == 7
    assert sum(sleep.stage_seconds.values()) / sleep.session_count == sleep_minutes * 60
    assert len(workouts.workouts) == workout_count
    assert (
        sum(workout.duration_seconds for workout in workouts.workouts) / 60
        == workout_minutes
    )
    if start_date == "2026-06-08":
        assert [workout.start_time[:10] for workout in workouts.workouts] == [
            "2026-06-13",
            "2026-06-14",
        ]

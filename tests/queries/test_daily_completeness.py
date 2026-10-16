import json
import sqlite3
from datetime import date, timedelta
from pathlib import Path
from typing import TypeAlias

import pytest

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import Sample
from health_bridge.ingest import ingest_fixture
from health_bridge.queries import get_daily_summary
from health_bridge.queries.models import DailyObservation
from tests.fixture_helpers import FIXTURE_PATH

SampleInput: TypeAlias = tuple[str, str, float, dict[str, str]]
DAY = "2026-06-09"
START = "2026-06-09T00:00:00Z"
END = "2026-06-10T00:00:00Z"
DAILY = {"aggregation": "daily_sum"}
COMPLETE = {**DAILY, "aggregation_completeness": "complete"}
PARTIAL = {**DAILY, "aggregation_completeness": "partial"}


def _ingest_samples(tmp_path: Path, rows: list[SampleInput]) -> Path:
    fixture = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    samples = tuple(
        Sample(
            client_record_id=f"synthetic-daily-{index}",
            source_key=fixture.sources[0].source_key,
            type_code="steps",
            start_time=start,
            end_time=end,
            value=value,
            unit="count",
            metadata=metadata,
        )
        for index, (start, end, value, metadata) in enumerate(rows)
    )
    batch = fixture.model_copy(
        update={
            "samples": samples,
            "workouts": (),
            "sleep_sessions": (),
            "deleted_records": (),
            "sync": fixture.sync.model_copy(update={"cursors": ()}),
        },
    )
    input_path = tmp_path / "daily.synthetic.json"
    _ = input_path.write_text(batch.model_dump_json())
    db_path = tmp_path / "daily.sqlite"
    assert ingest_fixture(db_path, input_path).sample_count == len(rows)
    return db_path


def _day(db_path: Path, day: str = DAY) -> DailyObservation:
    observation = get_daily_summary(
        db_path,
        start_date=day,
        end_date=(date.fromisoformat(day) + timedelta(days=1)).isoformat(),
    ).days[0]
    # These legacy inputs lack a causal statistics observation. Full-day eligibility
    # still controls last-known totals; freshness must not be inferred.
    assert observation.daily_activity_totals == {}
    return observation


def test_completed_total_excludes_partial_but_preserves_observations(
    tmp_path: Path,
) -> None:
    db_path = _ingest_samples(
        tmp_path,
        [(START, END, 6.0, COMPLETE), (START, END, 20.0, PARTIAL)],
    )
    day = _day(db_path)
    assert day.sample_statistics["steps"].total == 26.0
    assert day.sample_counts == {"steps": 2}
    assert day.sample_total_semantics == {"steps": "daily_aggregate"}
    assert day.last_known_daily_activity_totals == {"steps": 6.0}
    with sqlite3.connect(db_path) as connection:
        assert connection.execute("select count(*) from samples").fetchone() == (2,)


def test_partial_only_is_observed_without_completed_total(tmp_path: Path) -> None:
    day = _day(_ingest_samples(tmp_path, [(START, END, 20.0, PARTIAL)]))
    assert day.sample_statistics["steps"].total == 20.0
    assert day.sample_counts == {"steps": 1}
    assert day.sample_total_semantics == {"steps": "daily_aggregate"}
    assert day.daily_activity_totals == {}
    assert day.last_known_daily_activity_totals == {}


def test_complete_marker_cannot_certify_twelve_hour_coverage(tmp_path: Path) -> None:
    day = _day(
        _ingest_samples(tmp_path, [(START, "2026-06-09T12:00:00Z", 6.0, COMPLETE)]),
    )
    assert day.sample_statistics["steps"].total == 6.0
    assert day.sample_counts == {"steps": 1}
    assert day.daily_activity_totals == {}
    assert day.last_known_daily_activity_totals == {}


@pytest.mark.parametrize("value", [0.0, 6.0])
@pytest.mark.parametrize("metadata", [DAILY, COMPLETE])
def test_full_utc_day_supports_legacy_and_explicit_zero(
    tmp_path: Path,
    value: float,
    metadata: dict[str, str],
) -> None:
    day = _day(_ingest_samples(tmp_path, [(START, END, value, metadata)]))
    assert day.last_known_daily_activity_totals == {"steps": value}
    assert day.sample_statistics["steps"].total == value
    assert day.sample_counts == {"steps": 1}


@pytest.mark.parametrize("marker", ["partial", "", "COMPLETE", " complete ", "unknown"])
@pytest.mark.parametrize(
    "representation",
    [DAILY, {"healthkit_query": "HKStatisticsCollectionQuery"}],
)
def test_explicit_ineligible_marker_never_uses_legacy_lane(
    tmp_path: Path,
    marker: str,
    representation: dict[str, str],
) -> None:
    metadata = {**representation, "aggregation_completeness": marker}
    day = _day(_ingest_samples(tmp_path, [(START, END, 20.0, metadata)]))
    assert day.sample_total_semantics == {"steps": "daily_aggregate"}
    assert day.daily_activity_totals == {}
    assert day.last_known_daily_activity_totals == {}


@pytest.mark.parametrize("marker", [None, True, 1, [], {}])
def test_malformed_stored_marker_is_not_missing(
    tmp_path: Path,
    marker: object,
) -> None:
    db_path = _ingest_samples(tmp_path, [(START, END, 20.0, DAILY)])
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute(
            "update samples set metadata_json = ?",
            (json.dumps({**DAILY, "aggregation_completeness": marker}),),
        )
    day = _day(db_path)
    assert day.sample_statistics["steps"].total == 20.0
    assert day.daily_activity_totals == {}
    assert day.last_known_daily_activity_totals == {}


@pytest.mark.parametrize("marker", [None, "complete"])
@pytest.mark.parametrize(
    "local_day",
    [
        ("2026-06-25", "Asia/Tokyo", "2026-06-24T15:00:00Z", "2026-06-25T15:00:00Z"),
        (
            "2026-06-25",
            "Asia/Kathmandu",
            "2026-06-24T18:15:00Z",
            "2026-06-25T18:15:00Z",
        ),
        (
            "2026-03-08",
            "America/New_York",
            "2026-03-08T05:00:00Z",
            "2026-03-09T04:00:00Z",
        ),
        (
            "2026-11-01",
            "America/New_York",
            "2026-11-01T04:00:00Z",
            "2026-11-02T05:00:00Z",
        ),
        (
            "2018-11-04",
            "America/Sao_Paulo",
            "2018-11-04T03:00:00Z",
            "2018-11-05T02:00:00Z",
        ),
        (
            "2026-11-01",
            "America/Havana",
            "2026-11-01T04:00:00Z",
            "2026-11-02T05:00:00Z",
        ),
    ],
)
def test_full_local_day_uses_iana_boundaries_including_dst(
    tmp_path: Path,
    marker: str | None,
    local_day: tuple[str, str, str, str],
) -> None:
    day, zone, start, end = local_day
    metadata = {**DAILY, "calendar_day": day, "time_zone_identifier": zone}
    if marker is not None:
        metadata["aggregation_completeness"] = marker
    observation = _day(_ingest_samples(tmp_path, [(start, end, 6.0, metadata)]), day)
    assert observation.last_known_daily_activity_totals == {"steps": 6.0}
    assert observation.sample_counts == {"steps": 1}


@pytest.mark.parametrize("metadata", [DAILY, COMPLETE])
@pytest.mark.parametrize(
    ("start", "end"),
    [
        (START, "2026-06-09T12:00:00Z"),
        ("2026-06-09T01:00:00Z", "2026-06-10T01:00:00Z"),
        (START, START),
        (START, "2026-06-11T00:00:00Z"),
    ],
)
def test_full_day_requires_both_exact_boundaries(
    tmp_path: Path,
    metadata: dict[str, str],
    start: str,
    end: str,
) -> None:
    day = _day(_ingest_samples(tmp_path, [(start, end, 6.0, metadata)]))
    assert day.sample_counts == {"steps": 1}
    assert day.daily_activity_totals == {}
    assert day.last_known_daily_activity_totals == {}


@pytest.mark.parametrize(
    ("day", "start", "end"),
    [
        ("2026-03-08", "2026-03-08T05:00:00Z", "2026-03-09T05:00:00Z"),
        ("2026-11-01", "2026-11-01T04:00:00Z", "2026-11-02T04:00:00Z"),
    ],
)
def test_fixed_twenty_four_hours_is_not_a_dst_day(
    tmp_path: Path,
    day: str,
    start: str,
    end: str,
) -> None:
    metadata = {
        **COMPLETE,
        "calendar_day": day,
        "time_zone_identifier": "America/New_York",
    }
    observation = _day(_ingest_samples(tmp_path, [(start, end, 6.0, metadata)]), day)
    assert observation.sample_counts == {"steps": 1}
    assert observation.daily_activity_totals == {}
    assert observation.last_known_daily_activity_totals == {}


@pytest.mark.parametrize(
    "calendar_metadata",
    [
        {"calendar_day": DAY},
        {"time_zone_identifier": "UTC"},
        {"calendar_day": DAY, "time_zone_identifier": "Not/AZone"},
        {"calendar_day": DAY, "time_zone_identifier": "Asia/Tokyo"},
        {"calendar_day": "2026-06-10", "time_zone_identifier": "UTC"},
        {"calendar_day": "2026-02-30", "time_zone_identifier": "UTC"},
        {"calendar_day": "20260609", "time_zone_identifier": "UTC"},
        {"calendar_day": "", "time_zone_identifier": "UTC"},
        {"calendar_day": DAY, "time_zone_identifier": ""},
        {"calendar_day": None, "time_zone_identifier": "UTC"},
        {"calendar_day": DAY, "time_zone_identifier": None},
        {"calendar_day": DAY, "time_zone_identifier": 9},
        {"calendar_day": 20260609, "time_zone_identifier": "UTC"},
    ],
)
@pytest.mark.parametrize("marker", [None, "complete"])
def test_invalid_calendar_metadata_cannot_certify_a_total(
    tmp_path: Path,
    calendar_metadata: dict[str, object],
    marker: str | None,
) -> None:
    db_path = _ingest_samples(tmp_path, [(START, END, 6.0, DAILY)])
    metadata = {**DAILY, **calendar_metadata}
    if marker is not None:
        metadata["aggregation_completeness"] = marker
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute(
            "update samples set metadata_json = ?",
            (json.dumps(metadata),),
        )
    result = get_daily_summary(db_path, start_date="2026-06-09", end_date="2026-06-11")
    assert all(day.daily_activity_totals == {} for day in result.days)
    with sqlite3.connect(db_path) as connection:
        assert connection.execute("select count(*) from samples").fetchone() == (1,)


@pytest.mark.parametrize(
    ("field", "boundary"),
    [
        ("end_time", "invalid"),
        ("end_time", "2026-06-10T00:00:00"),
        ("end_time", "2026-06-10T0:0:0Z"),
        ("end_time", START),
        ("end_time", "2026-06-08T00:00:00Z"),
        ("start_time", "2026-06-09T00:00:00"),
        ("start_time", "2026-06-09T0:0:0Z"),
    ],
)
def test_malformed_or_empty_stored_boundary_cannot_certify_a_total(
    tmp_path: Path,
    field: str,
    boundary: str,
) -> None:
    db_path = _ingest_samples(tmp_path, [(START, END, 6.0, COMPLETE)])
    with sqlite3.connect(db_path) as connection:
        if field == "start_time":
            _ = connection.execute("update samples set start_time = ?", (boundary,))
        else:
            _ = connection.execute("update samples set end_time = ?", (boundary,))
    assert _day(db_path).daily_activity_totals == {}


def test_raw_and_partial_keep_mixed_representation_without_completed_total(
    tmp_path: Path,
) -> None:
    raw = {"aggregation": "sum", "sample_kind": "raw_quantity"}
    day = _day(
        _ingest_samples(tmp_path, [(START, END, 2.0, raw), (START, END, 20.0, PARTIAL)])
    )
    assert day.sample_statistics["steps"].total == 22.0
    assert day.sample_counts == {"steps": 2}
    assert day.sample_total_semantics == {"steps": "mixed_sum_semantics"}
    assert day.daily_activity_totals == {}
    assert day.last_known_daily_activity_totals == {}


def test_missing_and_raw_only_rows_do_not_infer_zero(tmp_path: Path) -> None:
    raw = {"aggregation": "sum", "sample_kind": "raw_quantity"}
    db_path = _ingest_samples(tmp_path, [(START, END, 2.0, raw)])
    assert _day(db_path).sample_total_semantics == {"steps": "raw_sample_sum"}
    assert _day(db_path).daily_activity_totals == {}
    missing = _day(db_path, "2026-06-10")
    assert missing.daily_activity_totals == {}
    assert missing.sample_counts == {}

from pathlib import Path

import pytest

from health_bridge.mcp.server import dispatch_request
from health_bridge.mcp.types import (
    JsonObject,
    required_list,
    required_object,
    required_string,
)
from health_bridge.queries._common import seconds_between
from tests.queries.test_latest_sleep_period import JSON_OBJECT, Session, sleep_db


def report(db: Path, arguments: JsonObject) -> JsonObject:
    before = (
        db.read_bytes(),
        db.stat().st_mtime_ns,
        db.stat().st_mode,
        tuple(db.parent.iterdir()),
    )
    response = dispatch_request(
        db,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "get_sleep_report", "arguments": arguments},
        },
    )
    assert "result" in response, response
    content = required_list(required_object(response["result"])["content"])
    assert (
        db.read_bytes(),
        db.stat().st_mtime_ns,
        db.stat().st_mode,
        tuple(db.parent.iterdir()),
    ) == before
    return JSON_OBJECT.validate_json(
        required_string(required_object(content[0])["text"])
    )


def period_rows(result: JsonObject) -> list[JsonObject]:
    return [required_object(item) for item in required_list(result["periods"])]


def asleep(start: str, end: str) -> Session:
    return Session(start, end, (("core", start, end),))


@pytest.mark.parametrize("include_intervals", [False, True])
def test_fragmented_night_and_later_nap_are_all_retained(
    tmp_path: Path, include_intervals: bool
) -> None:
    db = sleep_db(
        tmp_path,
        (
            asleep("2026-06-11T13:00:00Z", "2026-06-11T13:20:00Z"),
            asleep("2026-06-10T23:00:00Z", "2026-06-11T03:00:00Z"),
            asleep("2026-06-11T03:10:00Z", "2026-06-11T07:00:00Z"),
        ),
    )
    result = report(
        db,
        {
            "timezone": "UTC",
            "local_date": "2026-06-11",
            "reference_time": "2026-06-11T20:00:00Z",
            "include_intervals": include_intervals,
        },
    )
    periods = period_rows(result)
    assert [period["asleep_seconds"] for period in periods] == [14400, 13800, 1200]
    assert result["recorded_asleep_seconds"] == 29400
    assert [required_object(period["period"])["start"] for period in periods] == [
        "2026-06-10T23:00:00Z",
        "2026-06-11T03:10:00Z",
        "2026-06-11T13:00:00Z",
    ]
    assert result["unknown_duration_period_count"] == 0
    assert result["incomplete_evidence_period_count"] == 0
    assert all(
        (period["evidence"] is not None) is include_intervals for period in periods
    )


@pytest.mark.parametrize(
    ("timezone", "local_end", "day_start"),
    [
        ("Asia/Kolkata", "2026-06-11T02:30:00+05:30", "2026-06-10T18:30:00Z"),
        ("Asia/Seoul", "2026-06-11T06:00:00+09:00", "2026-06-10T15:00:00Z"),
    ],
)
def test_wake_date_counts_full_cross_midnight_period(
    tmp_path: Path, timezone: str, local_end: str, day_start: str
) -> None:
    start, end = "2026-06-10T14:00:00Z", "2026-06-10T21:00:00Z"
    db = sleep_db(tmp_path, (asleep(start, end),))
    result = report(
        db, {"timezone": timezone, "reference_time": "2026-06-11T04:00:00Z"}
    )
    assert result["requested_local_date"] is None
    assert result["local_date"] == "2026-06-11"
    assert required_object(result["day_bounds"])["start"] == day_start
    assert required_object(period_rows(result)[0]["period"])["local_end"] == local_end
    assert result["recorded_asleep_seconds"] == 25200


def test_no_previous_day_substitution(tmp_path: Path) -> None:
    db = sleep_db(tmp_path, (asleep("2026-06-09T20:00:00Z", "2026-06-10T04:00:00Z"),))
    result = report(
        db,
        {
            "timezone": "UTC",
            "local_date": "2026-06-11",
            "reference_time": "2026-06-12T04:00:00Z",
        },
    )
    assert result["status"] == "no_eligible_periods"
    assert result["periods"] == []
    assert result["recorded_asleep_seconds"] is None
    assert result["truncated"] is False


def test_connected_members_expand_before_and_after_midnight(tmp_path: Path) -> None:
    db = sleep_db(
        tmp_path,
        (
            asleep("2026-06-09T23:00:00Z", "2026-06-10T01:00:00Z"),
            asleep("2026-06-10T00:30:00Z", "2026-06-10T20:00:00Z"),
            asleep("2026-06-10T19:00:00Z", "2026-06-11T03:00:00Z"),
            asleep("2026-06-11T23:00:00Z", "2026-06-12T01:00:00Z"),
            asleep("2026-06-12T00:30:00Z", "2026-06-12T08:00:00Z"),
        ),
    )
    result = report(
        db,
        {
            "timezone": "UTC",
            "local_date": "2026-06-11",
            "reference_time": "2026-06-13T00:00:00Z",
            "include_intervals": True,
        },
    )
    periods = period_rows(result)
    assert len(periods) == 1
    assert periods[0]["session_count"] == 3
    assert result["recorded_asleep_seconds"] == 28 * 3600
    assert required_object(periods[0]["period"])["start"] == "2026-06-09T23:00:00Z"
    assert result["other_wake_date_count"] == 1


def test_future_connected_observation_cannot_manufacture_completed_sleep(
    tmp_path: Path,
) -> None:
    db = sleep_db(
        tmp_path,
        (
            asleep("2026-06-10T23:00:00Z", "2026-06-11T02:00:00Z"),
            asleep("2026-06-11T01:00:00Z", "2026-06-12T01:00:00Z"),
            asleep("2026-06-12T01:00:00Z", "2026-06-12T03:00:00Z"),
            asleep("2026-06-11T10:00:00Z", "2026-06-11T11:00:00Z"),
        ),
    )
    result = report(
        db,
        {
            "timezone": "UTC",
            "local_date": "2026-06-11",
            "reference_time": "2026-06-11T04:00:00Z",
        },
    )
    assert result["periods"] == []
    assert result["omitted_after_reference_count"] == 1
    assert result["recorded_asleep_seconds"] is None


def test_end_at_midnight_is_attributed_to_new_date(tmp_path: Path) -> None:
    db = sleep_db(tmp_path, (asleep("2026-06-10T23:00:00Z", "2026-06-11T00:00:00Z"),))
    result = report(db, {"timezone": "UTC", "reference_time": "2026-06-11T00:00:00Z"})
    assert result["recorded_asleep_seconds"] == 3600
    assert result["local_date"] == "2026-06-11"


@pytest.mark.parametrize(
    ("start", "end", "date", "day_hours"),
    [
        ("2026-03-08T06:30:00Z", "2026-03-08T07:30:00Z", "2026-03-08", 23),
        ("2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-11-01", 25),
    ],
)
def test_report_dst_elapsed_time_and_day_bounds(
    tmp_path: Path, start: str, end: str, date: str, day_hours: int
) -> None:
    db = sleep_db(tmp_path, (asleep(start, end),))
    result = report(
        db,
        {
            "timezone": "America/New_York",
            "local_date": date,
            "reference_time": date + "T20:00:00Z",
        },
    )
    bounds = required_object(result["day_bounds"])
    assert (
        seconds_between(
            required_string(bounds["start"]), required_string(bounds["end"])
        )
        == day_hours * 3600
    )
    assert result["recorded_asleep_seconds"] == 3600


def test_partial_known_contribution_does_not_zero_unknown_periods(
    tmp_path: Path,
) -> None:
    db = sleep_db(
        tmp_path,
        (
            asleep("2026-06-11T00:00:00Z", "2026-06-11T01:00:00Z"),
            Session("2026-06-11T02:00:00Z", "2026-06-11T03:00:00Z"),
            Session(
                "2026-06-11T04:00:00Z",
                "2026-06-11T05:00:00Z",
                (("awake", "2026-06-11T04:00:00Z", "2026-06-11T05:00:00Z"),),
            ),
            Session(
                "2026-06-11T06:00:00Z",
                "2026-06-11T07:00:00Z",
                (("in_bed", "2026-06-11T06:00:00Z", "2026-06-11T07:00:00Z"),),
            ),
            Session(
                "2026-06-11T08:00:00Z",
                "2026-06-11T09:00:00Z",
                (("legacy", "2026-06-11T08:00:00Z", "2026-06-11T09:00:00Z"),),
            ),
        ),
    )
    result = report(
        db,
        {
            "timezone": "UTC",
            "local_date": "2026-06-11",
            "reference_time": "2026-06-12T00:00:00Z",
            "include_intervals": True,
        },
    )
    periods = period_rows(result)
    assert result["recorded_asleep_seconds"] == 3600
    assert result["recorded_awake_seconds"] == 3600
    assert result["recorded_in_bed_seconds"] == 3600
    assert result["unknown_duration_period_count"] == 4
    assert result["incomplete_evidence_period_count"] == 4
    assert all(
        period["duration_status"] == "unknown" and period["asleep_seconds"] is None
        for period in periods[1:]
    )
    assert any(
        "asleepUnspecified" in required_string(note)
        for note in required_list(result["missing_data_notes"])
    )


def test_clipping_cross_stage_sources_and_uncovered_time(tmp_path: Path) -> None:
    a, b, c, d, e = (f"2026-06-11T0{hour}:00:00Z" for hour in range(5))
    db = sleep_db(
        tmp_path,
        (
            Session(a, c, (("core", "2026-06-10T23:00:00Z", c), ("awake", a, c))),
            Session(b, e, (("deep", b, d), ("in_bed", b, d)), source=2),
        ),
    )
    result = report(
        db,
        {
            "timezone": "UTC",
            "reference_time": "2026-06-11T08:00:00Z",
            "include_intervals": True,
        },
    )
    period = period_rows(result)[0]
    assert period["asleep_seconds"] == 10800
    assert period["stage_seconds"] == {
        "core": 7200,
        "deep": 7200,
        "awake": 7200,
        "in_bed": 7200,
    }
    assert period["uncovered_seconds"] == 3600
    assert period["evidence_incomplete"] is True
    detail = required_object(period["evidence"])
    assert detail["asleep_intervals"] == [{"start": a, "end": d}]
    assert len(required_list(period["sources_used"])) == 2

from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from health_bridge.mcp.server import dispatch_request
from health_bridge.mcp.types import JsonObject
from tests.queries.test_latest_sleep_period import Session, sleep_db
from tests.queries.test_sleep_report import period_rows, report


@pytest.mark.parametrize("count", [500, 501])
@pytest.mark.parametrize("expand", [False, True])
def test_global_session_cap_requires_complete_membership(
    tmp_path: Path, count: int, expand: bool
) -> None:
    origin = datetime(2026, 6, 11, tzinfo=UTC)
    sessions: list[Session] = []
    for index in range(count):
        start = origin + timedelta(seconds=index - count + 1 if expand else index)
        end = start + timedelta(seconds=2) if expand else origin + timedelta(hours=3)
        sessions.append(
            Session(
                start.strftime("%Y-%m-%dT%H:%M:%SZ"), end.strftime("%Y-%m-%dT%H:%M:%SZ")
            )
        )
    db = sleep_db(tmp_path, tuple(sessions))
    result = report(
        db,
        {
            "timezone": "UTC",
            "local_date": "2026-06-11",
            "reference_time": "2026-06-11T08:00:00Z",
            "include_intervals": True,
        },
    )
    assert result["truncated"] is (count > 500)
    if count > 500:
        assert result["status"] == "withheld"
        assert result["withheld_reason"] == "session_limit"
        assert result["periods"] == []
        assert result["unknown_duration_period_count"] is None
    else:
        assert period_rows(result)[0]["session_count"] == 500
    assert result["recorded_asleep_seconds"] is None


@pytest.mark.parametrize("count", [500, 501])
def test_stage_budget_is_global_and_withholds_all_earlier_totals(
    tmp_path: Path, count: int
) -> None:
    sessions: list[Session] = []
    for hour, size in ((0, 250), (2, count - 250)):
        origin = datetime(2026, 6, 11, hour, tzinfo=UTC)
        stamps = [
            (origin + timedelta(seconds=i)).strftime("%Y-%m-%dT%H:%M:%SZ")
            for i in range(size + 1)
        ]
        sessions.append(
            Session(
                stamps[0],
                stamps[-1],
                tuple(("core", stamps[i], stamps[i + 1]) for i in range(size)),
            )
        )
    db = sleep_db(tmp_path, tuple(sessions))
    result = report(
        db,
        {
            "timezone": "UTC",
            "reference_time": "2026-06-11T08:00:00Z",
            "include_intervals": True,
        },
    )
    periods = period_rows(result)
    assert len(periods) == 2
    assert result["truncated"] is (count > 500)
    if count > 500:
        assert result["withheld_reason"] == "stage_limit"
        assert result["recorded_asleep_seconds"] is None
        assert result["recorded_awake_seconds"] is None
        assert result["recorded_in_bed_seconds"] is None
        assert all(
            period["duration_status"] == "withheld"
            and period["asleep_seconds"] is None
            and period["stage_seconds"] is None
            and period["evidence"] is None
            for period in periods
        )
    else:
        assert result["recorded_asleep_seconds"] == 500
        assert [period["asleep_seconds"] for period in periods] == [250, 250]


@pytest.mark.parametrize(
    "arguments",
    [
        {},
        {"timezone": "Invalid/Zone"},
        {"timezone": "/etc/passwd"},
        {"timezone": "UTC", "local_date": "2026-02-30"},
        {"timezone": "UTC", "local_date": "20260611"},
        {"timezone": "UTC", "local_date": "9999-12-31"},
        {"timezone": "Asia/Seoul", "local_date": "0001-01-01"},
        {"timezone": "UTC", "reference_time": "2026-06-11T04:00:00"},
        {"timezone": "UTC", "reference_time": "2026-06-11T04:00:00+00:00"},
        {"timezone": "UTC", "reference_time": "2026-06-11T04:00:00.1Z"},
        {"timezone": "UTC", "reference_time": "2026-02-30T04:00:00Z"},
        {"timezone": "Asia/Seoul", "reference_time": "9999-12-31T23:59:59Z"},
        {"timezone": "UTC", "include_intervals": "true"},
        {"timezone": "UTC", "limit": 1},
    ],
)
def test_report_rejects_invalid_arguments_before_read(
    tmp_path: Path, arguments: JsonObject
) -> None:
    response = dispatch_request(
        tmp_path / "absent.sqlite",
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "get_sleep_report", "arguments": arguments},
        },
    )
    assert response["error"] == {
        "code": -32602,
        "message": "Invalid tool call arguments.",
    }
    assert not (tmp_path / "absent.sqlite").exists()

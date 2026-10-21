from datetime import UTC, datetime, tzinfo
from pathlib import Path
from typing import ClassVar

import pytest
from typing_extensions import override

from health_bridge.queries import sleep_report_models
from tests.queries.test_latest_sleep_period import Session, sleep_db
from tests.queries.test_sleep_report import asleep, period_rows, report


def test_default_reference_is_captured_once_through_mcp(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    class Clock(datetime):
        calls: ClassVar[int] = 0

        @classmethod
        @override
        def now(cls, tz: tzinfo | None = None) -> datetime:
            cls.calls += 1
            return datetime(2026, 6, 10, 23, 59, 59, tzinfo=UTC).astimezone(tz)

    db = sleep_db(tmp_path, (asleep("2026-06-10T18:00:00Z", "2026-06-10T22:00:00Z"),))
    monkeypatch.setattr(sleep_report_models, "datetime", Clock)
    result = report(db, {"timezone": "Asia/Seoul"})
    assert Clock.calls == 1
    assert result["reference_time"] == "2026-06-10T23:59:59Z"
    assert result["local_date"] == "2026-06-11"
    assert result["requested_local_date"] is None
    assert result["recorded_asleep_seconds"] == 14400


@pytest.mark.parametrize("stage", [None, "awake", "in_bed", "legacy_unknown"])
def test_unknown_asleep_contribution_is_not_zero(
    tmp_path: Path, stage: str | None
) -> None:
    start, end = "2026-06-11T00:00:00Z", "2026-06-11T01:00:00Z"
    db = sleep_db(
        tmp_path, (Session(start, end, ((stage, start, end),) if stage else ()),)
    )
    result = report(
        db,
        {
            "timezone": "UTC",
            "reference_time": "2026-06-11T03:00:00Z",
            "include_intervals": True,
        },
    )
    assert result["recorded_asleep_seconds"] is None
    assert result["unknown_duration_period_count"] == 1
    assert period_rows(result)[0]["evidence_incomplete"] is True
    assert period_rows(result)[0]["evidence"] is not None


@pytest.mark.parametrize("local_date", ["2026-06-11", "2011-12-30"])
def test_empty_store_or_skipped_local_date_has_no_fallback(
    tmp_path: Path, local_date: str
) -> None:
    db = sleep_db(tmp_path, ())
    result = report(
        db,
        {
            "timezone": "Pacific/Apia",
            "local_date": local_date,
            "reference_time": "2026-06-12T00:00:00Z",
        },
    )
    assert result["status"] == "no_eligible_periods"
    assert result["recorded_asleep_seconds"] is None
    assert result["periods"] == []

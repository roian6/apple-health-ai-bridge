from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Final

import pytest
from pydantic import JsonValue, TypeAdapter

from health_bridge.mcp.server import dispatch_request
from health_bridge.mcp.types import (
    JsonObject,
    required_list,
    required_object,
    required_string,
)
from health_bridge.storage import initialize_database
from health_bridge.storage.database import connect_database

JSON_OBJECT: Final = TypeAdapter(dict[str, JsonValue])


@dataclass(frozen=True)
class Session:
    start: str
    end: str
    stages: tuple[tuple[str, str, str], ...] = ()
    source: int = 1


def sleep_db(tmp_path: Path, sessions: tuple[Session, ...]) -> Path:
    db = tmp_path / "sleep.sqlite"
    initialize_database(db)
    with connect_database(db) as connection:
        _ = connection.executemany(
            "insert into sources(source_id,source_key,name,kind) values (?,?,?,?)",
            (
                (1, "synthetic.watch", "Synthetic watch", "watch"),
                (2, "synthetic.phone", "Synthetic phone", "phone"),
            ),
        )
        for index, session in enumerate(sessions, start=1):
            _ = connection.execute(
                (
                    "insert into sleep_sessions(sleep_session_id,source_id,"
                    "client_record_id,start_time,end_time) values (?,?,?,?,?)"
                ),
                (
                    index,
                    session.source,
                    f"synthetic-sleep-{index}",
                    session.start,
                    session.end,
                ),
            )
            _ = connection.executemany(
                (
                    "insert into sleep_stage_intervals(sleep_session_id,stage,"
                    "start_time,end_time) values (?,?,?,?)"
                ),
                ((index, *stage) for stage in session.stages),
            )
    return db


def latest(db: Path, timezone: str, reference: str) -> JsonObject:
    before = db.read_bytes(), db.stat().st_mtime_ns, db.stat().st_mode
    response = dispatch_request(
        db,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "get_latest_sleep_period",
                "arguments": {
                    "timezone": timezone,
                    "reference_time": reference,
                },
            },
        },
    )
    assert "error" not in response, response
    assert (db.read_bytes(), db.stat().st_mtime_ns, db.stat().st_mode) == before
    content = required_list(required_object(response["result"])["content"])
    return JSON_OBJECT.validate_json(
        required_string(required_object(content[0])["text"])
    )


@pytest.mark.parametrize(
    ("zone", "local_start", "local_end", "window_start"),
    [
        (
            "Asia/Kolkata",
            "2026-06-11T00:00:00+05:30",
            "2026-06-11T03:00:00+05:30",
            "2026-06-04T18:30:00Z",
        ),
        (
            "Asia/Seoul",
            "2026-06-11T03:30:00+09:00",
            "2026-06-11T06:30:00+09:00",
            "2026-06-04T15:00:00Z",
        ),
    ],
)
def test_latest_unions_stages_and_sources_in_local_window(
    tmp_path: Path,
    zone: str,
    local_start: str,
    local_end: str,
    window_start: str,
) -> None:
    # Given: local midnight in Kolkata, overlapping sources and conflicting stages.
    a, b, c, d = (f"2026-06-10T{hour}:30:00Z" for hour in ("18", "19", "20", "21"))
    db = sleep_db(
        tmp_path,
        (
            Session(a, c, (("core", a, c), ("awake", b, c), ("in_bed", a, c))),
            Session(b, d, (("deep", b, d),), source=2),
        ),
    )
    # When
    result = latest(db, zone, "2026-06-11T04:00:00Z")
    # Then
    period = required_object(result["selected_period"])
    assert period == {
        "start": a,
        "end": d,
        "local_start": local_start,
        "local_end": local_end,
        "local_end_date": "2026-06-11",
    }
    assert required_object(result["search_window"])["start"] == window_start
    assert result["asleep_seconds"] == 10800
    assert result["asleep_intervals"] == [{"start": a, "end": d}]
    assert result["stage_seconds"] == {
        "core": 7200,
        "deep": 7200,
        "awake": 3600,
        "in_bed": 7200,
    }
    assert result["awake_seconds"] == 3600
    assert result["in_bed_seconds"] == 7200
    assert len(required_list(result["sessions"])) == 2
    assert len(required_list(result["sources_used"])) == 2
    assert result["truncated"] is False


def test_latest_nap_wins_and_ongoing_group_is_excluded(tmp_path: Path) -> None:
    # Given: overnight, afternoon nap, then an ongoing overlapping group.
    db = sleep_db(
        tmp_path,
        (
            Session("2026-06-10T14:00:00Z", "2026-06-10T22:00:00Z"),
            Session("2026-06-11T04:00:00Z", "2026-06-11T05:00:00Z"),
            Session("2026-06-11T06:00:00Z", "2026-06-11T07:00:00Z"),
            Session("2026-06-11T06:30:00Z", "2026-06-11T09:00:00Z", source=2),
        ),
    )
    # When
    result = latest(db, "Asia/Seoul", "2026-06-11T08:00:00Z")
    # Then
    assert required_object(result["selected_period"])["end"] == "2026-06-11T05:00:00Z"
    assert result["asleep_seconds"] is None
    assert result["stage_seconds"] == {}
    assert any(
        "nap" in required_string(note)
        for note in required_list(result["missing_data_notes"])
    )


@pytest.mark.parametrize(
    ("start", "end", "reference", "offsets"),
    [
        (
            "2026-03-08T06:30:00Z",
            "2026-03-08T07:30:00Z",
            "2026-03-08T12:00:00Z",
            ("-05:00", "-04:00"),
        ),
        (
            "2026-11-01T05:30:00Z",
            "2026-11-01T06:30:00Z",
            "2026-11-01T12:00:00Z",
            ("-04:00", "-05:00"),
        ),
    ],
)
def test_elapsed_union_uses_instants_across_dst(
    tmp_path: Path,
    start: str,
    end: str,
    reference: str,
    offsets: tuple[str, str],
) -> None:
    # Given
    db = sleep_db(tmp_path, (Session(start, end, (("rem", start, end),)),))
    # When
    result = latest(db, "America/New_York", reference)
    # Then
    assert result["asleep_seconds"] == 3600
    period = required_object(result["selected_period"])
    assert required_string(period["local_start"]).endswith(offsets[0])
    assert required_string(period["local_end"]).endswith(offsets[1])


def test_clips_legacy_stages_preserves_cross_midnight_envelope(tmp_path: Path) -> None:
    # Given: a session starting before the search lower bound, unknown legacy stage.
    start, end = "2026-06-04T18:00:00Z", "2026-06-04T20:00:00Z"
    db = sleep_db(
        tmp_path,
        (
            Session(
                start,
                end,
                (
                    ("core", "2026-06-04T17:00:00Z", "2026-06-04T21:00:00Z"),
                    ("legacy_unknown", start, end),
                    ("awake", end, "2026-06-04T21:00:00Z"),
                ),
            ),
        ),
    )
    # When
    result = latest(db, "Asia/Kolkata", "2026-06-11T04:00:00Z")
    # Then
    assert (
        required_object(result["selected_period"])["local_start"]
        == "2026-06-04T23:30:00+05:30"
    )
    assert result["asleep_seconds"] == 7200
    assert result["awake_seconds"] is None
    assert result["stage_seconds"] == {"core": 7200, "legacy_unknown": 7200}
    assert result["stage_intervals"] == [
        {"session_index": 0, "stage": "core", "start": start, "end": end},
        {"session_index": 0, "stage": "legacy_unknown", "start": start, "end": end},
    ]


@pytest.mark.parametrize(
    "sessions",
    [
        (),
        (
            Session("2026-06-04T17:00:00Z", "2026-06-04T18:30:00Z"),
            Session("2026-06-11T05:00:00Z", "2026-06-11T06:00:00Z"),
            Session("2026-06-11T03:00:00Z", "2026-06-11T05:00:00Z"),
            Session("2026-06-11T02:00:00Z", "2026-06-11T02:00:00Z"),
        ),
    ],
)
def test_empty_or_ineligible_records_are_unknown(
    tmp_path: Path, sessions: tuple[Session, ...]
) -> None:
    # Given
    db = sleep_db(tmp_path, sessions)
    # When
    result = latest(db, "Asia/Kolkata", "2026-06-11T04:00:00Z")
    # Then
    assert result["selected_period"] is None
    assert result["asleep_seconds"] is None
    assert result["truncated"] is False


@pytest.mark.parametrize("count", [500, 501])
def test_candidate_session_limit_never_selects_from_partial_set(
    tmp_path: Path, count: int
) -> None:
    # Given
    origin = datetime(2026, 6, 11, tzinfo=UTC)
    db = sleep_db(
        tmp_path,
        tuple(
            Session(
                (origin + timedelta(seconds=i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "2026-06-11T03:00:00Z",
            )
            for i in range(count)
        ),
    )
    # When
    result = latest(db, "Asia/Seoul", "2026-06-11T04:00:00Z")
    # Then
    assert result["truncated"] is (count > 500)
    assert len(required_list(result["sessions"])) == (500 if count == 500 else 0)
    assert (result["selected_period"] is None) is (count > 500)
    assert result["asleep_seconds"] is None


@pytest.mark.parametrize("count", [500, 501])
def test_interval_limit_withholds_partial_totals(tmp_path: Path, count: int) -> None:
    # Given
    origin = datetime(2026, 6, 11, tzinfo=UTC)
    stamps = [
        (origin + timedelta(seconds=i)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for i in range(count + 1)
    ]
    stages = tuple(("core", stamps[i], stamps[i + 1]) for i in range(count))
    db = sleep_db(tmp_path, (Session(stamps[0], stamps[-1], stages),))
    # When
    result = latest(db, "Asia/Seoul", "2026-06-11T04:00:00Z")
    # Then
    assert result["truncated"] is (count > 500)
    assert result["selected_period"] is not None
    assert result["asleep_seconds"] == (500 if count == 500 else None)
    assert len(required_list(result["stage_intervals"])) == (500 if count == 500 else 0)


@pytest.mark.parametrize(
    "arguments",
    [
        {},
        {"timezone": "Mars/Olympus", "reference_time": "2026-06-11T04:00:00Z"},
        {"timezone": "Asia/Seoul", "reference_time": "2026-06-11"},
        {"timezone": "Asia/Seoul", "reference_time": "2026-02-30T04:00:00Z"},
        {"timezone": "Asia/Seoul", "reference_time": "2026-06-11T04:00:00+00:00"},
        {"timezone": "Asia/Seoul", "reference_time": "0001-01-01T00:00:00Z"},
        {"timezone": "Asia/Seoul", "reference_time": "9999-12-31T23:59:59Z"},
        {
            "timezone": "Asia/Seoul",
            "reference_time": "2026-06-11T04:00:00Z",
            "limit": 1,
        },
    ],
)
def test_latest_rejects_arguments_before_database_access(
    tmp_path: Path, arguments: JsonObject
) -> None:
    # Given / When
    response = dispatch_request(
        tmp_path / "absent.sqlite",
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "get_latest_sleep_period", "arguments": arguments},
        },
    )
    # Then
    assert response["error"] == {
        "code": -32602,
        "message": "Invalid tool call arguments.",
    }
    assert not (tmp_path / "absent.sqlite").exists()


def test_touching_and_nested_sessions_merge_at_reference_midnight(
    tmp_path: Path,
) -> None:
    start = "2026-06-10T16:00:00Z"
    middle = "2026-06-10T17:00:00Z"
    end = "2026-06-10T18:30:00Z"
    db = sleep_db(
        tmp_path,
        (
            Session(start, middle, (("core", start, middle),)),
            Session(start, end, (("core", start, end),), source=2),
            Session(middle, end, (("rem", middle, end),)),
        ),
    )
    result = latest(db, "Asia/Kolkata", end)
    period = required_object(result["selected_period"])
    assert period["local_end"] == "2026-06-11T00:00:00+05:30"
    assert period["start"] == start
    assert result["asleep_seconds"] == 9000
    assert result["stage_seconds"] == {"core": 9000, "rem": 5400}
    assert result["asleep_intervals"] == [{"start": start, "end": end}]
    window = required_object(result["search_window"])
    assert window["local_start"] == "2026-06-05T00:00:00+05:30"
    assert window["end"] == end


@pytest.mark.parametrize("stage", ["legacy_unknown", "awake", "in_bed"])
def test_absent_asleep_stages_remain_unknown(tmp_path: Path, stage: str) -> None:
    start, end = "2026-06-11T00:00:00Z", "2026-06-11T01:00:00Z"
    db = sleep_db(tmp_path, (Session(start, end, ((stage, start, end),)),))
    result = latest(db, "Asia/Seoul", "2026-06-11T04:00:00Z")
    assert result["asleep_seconds"] is None
    assert result["asleep_intervals"] == []
    assert result["stage_seconds"] == {stage: 3600}


def test_search_uses_local_dates_across_dst_not_fixed_hours(tmp_path: Path) -> None:
    db = sleep_db(tmp_path, ())
    result = latest(db, "America/New_York", "2026-03-10T04:00:00Z")
    assert result["search_window"] == {
        "start": "2026-03-04T05:00:00Z",
        "end": "2026-03-10T04:00:00Z",
        "local_start": "2026-03-04T00:00:00-05:00",
        "local_end": "2026-03-10T00:00:00-04:00",
        "local_end_date": "2026-03-10",
    }


def test_stages_outside_search_candidates_cannot_leak_into_selected_period(
    tmp_path: Path,
) -> None:
    start, end = "2026-06-04T17:00:00Z", "2026-06-04T20:00:00Z"
    old_end = "2026-06-04T18:00:00Z"
    db = sleep_db(
        tmp_path,
        (
            Session(start, end),
            Session(start, old_end, (("core", start, old_end),), source=2),
        ),
    )
    result = latest(db, "Asia/Kolkata", "2026-06-11T04:00:00Z")
    assert len(required_list(result["sessions"])) == 1
    assert result["stage_intervals"] == []
    assert result["asleep_seconds"] is None


def test_malformed_stored_stage_is_a_controlled_database_error(tmp_path: Path) -> None:
    db = sleep_db(
        tmp_path,
        (
            Session(
                "2026-06-11T00:00:00Z",
                "2026-06-11T03:00:00Z",
                (("core", "invalid", "2026-06-11T03:00:00Z"),),
            ),
        ),
    )
    before = db.read_bytes()
    response = dispatch_request(
        db,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "get_latest_sleep_period",
                "arguments": {
                    "timezone": "Asia/Seoul",
                    "reference_time": "2026-06-11T04:00:00Z",
                },
            },
        },
    )
    assert response["error"] == {
        "code": -32000,
        "message": "Health Bridge database is unavailable.",
    }
    assert db.read_bytes() == before

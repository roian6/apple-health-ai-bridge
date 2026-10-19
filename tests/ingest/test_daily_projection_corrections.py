import json
import sys
from pathlib import Path
from subprocess import run
from typing import TYPE_CHECKING, Final, Literal

import pytest

import health_bridge
from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import DeletedRecord, Sample, SyncCursor
from health_bridge.ingest import ingest_batch
from health_bridge.queries import get_daily_summary, get_timeseries
from health_bridge.queries.models import DailySummaryResult
from tests.fixture_helpers import FIXTURE_PATH
from tests.mcp.committed_read_support import (
    JSON_OBJECT,
    line_process,
    send,
    status_payload,
)

if TYPE_CHECKING:
    from health_bridge.mcp.types import JsonObject

START: Final = "2026-06-01T00:00:00Z"
END: Final = "2026-06-02T00:00:00Z"
NAMESPACE: Final = "synthetic-root-observation-owner"
CLI: Final = (
    "from pathlib import Path; import sys; "
    f"expected=Path({str(Path(health_bridge.__file__).resolve())!r}); "
    "sys.path.insert(0, str(expected.parent.parent)); import health_bridge; "
    "assert Path(health_bridge.__file__).resolve() == expected; "
    "from health_bridge.cli import run; run()"
)


def _fixture() -> HealthBridgeBatchV1:
    return HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())


def _daily(value: float = 6.0, day: str = "2026-06-01") -> Sample:
    end = END if day == "2026-06-01" else "2026-06-03T00:00:00Z"
    return Sample(
        client_record_id=f"synthetic-root-daily-{day.replace('-', '')}",
        source_key=_fixture().sources[0].source_key,
        type_code="steps",
        start_time=f"{day}T00:00:00Z",
        end_time=end,
        value=value,
        unit="count",
        metadata={
            "aggregation": "daily_sum",
            "aggregation_completeness": "complete",
            "sample_kind": "daily_aggregate",
            "source_resolution": "healthkit_statistics_merged_sources",
            "calendar_day": day,
            "time_zone_identifier": "UTC",
        },
    )


def _raw(value: float = 2.0, day: str = "2026-06-01") -> Sample:
    return Sample(
        client_record_id="synthetic-root-raw",
        source_key=_fixture().sources[0].source_key,
        type_code="steps",
        start_time=f"{day}T01:00:00Z",
        end_time=f"{day}T01:01:00Z",
        value=value,
        unit="count",
        metadata={"sample_kind": "raw_quantity", "aggregation": "sum"},
    )


def _deletion(known: bool = True) -> DeletedRecord:
    return DeletedRecord(
        record_family="sample",
        source_key=_raw().source_key,
        client_record_id=_raw().client_record_id if known else "synthetic-unmapped",
        deleted_at="2026-06-03T01:00:00Z",
    )


def _batch(
    samples: tuple[Sample, ...] = (),
    deleted: tuple[DeletedRecord, ...] = (),
    sequence: int | None = None,
    statistics: bool = False,
) -> HealthBridgeBatchV1:
    fixture = _fixture()
    cursors: tuple[SyncCursor, ...] = ()
    if sequence is not None:
        observation: JsonObject = {
            "namespace": NAMESPACE,
            "sequence": sequence,
            "type_code": "steps",
            "raw_intervals": [
                {
                    "client_record_id": sample.client_record_id,
                    "start_time": sample.start_time,
                    "end_time": sample.end_time,
                }
                for sample in samples
                if sample.metadata.get("sample_kind") == "raw_quantity"
            ],
        }
        if statistics:
            observation["statistics_window"] = {
                "start_time": START,
                "end_time": "2026-06-03T00:00:00Z",
            }
        cursors = (
            SyncCursor(
                source_key=fixture.sources[0].source_key,
                cursor_kind="daily_projection_observation:steps",
                cursor_value=json.dumps(observation, sort_keys=True),
            ),
        )
    return fixture.model_copy(
        update={
            "generated_at": "2026-06-04T00:00:00Z",
            "samples": samples,
            "deleted_records": deleted,
            "workouts": (),
            "sleep_sessions": (),
            "sync": fixture.sync.model_copy(update={"cursors": cursors}),
        }
    )


def _send(db: Path, batch: HealthBridgeBatchV1) -> None:
    parsed = HealthBridgeBatchV1.model_validate_json(batch.model_dump_json())
    assert ingest_batch(db, parsed, "synthetic-root-regression").status == "succeeded"


def _total(db: Path, day: str = "2026-06-01") -> float | None:
    end = "2026-06-02" if day == "2026-06-01" else "2026-06-03"
    return get_daily_summary(db, day, end).days[0].daily_activity_totals.get("steps")


def test_imports_use_this_independent_main_source() -> None:
    expected = Path(__file__).resolve().parents[2] / "src"
    assert Path(health_bridge.__file__).resolve().is_relative_to(expected)


@pytest.mark.parametrize("value", [6.0, 0.0])
def test_newer_populated_projection_controls_remain_useful(
    tmp_path: Path,
    value: float,
) -> None:
    # Given: a real positive projection and a newer observed value.
    db = tmp_path / "synthetic.sqlite"
    _send(db, _batch((_daily(10.0),), sequence=1, statistics=True))
    assert _total(db) == 10.0
    # When: a genuine later scoped observation is ingested.
    _send(db, _batch((_daily(value),), sequence=3, statistics=True))
    # Then: both positive and actual zero remain available as current totals.
    assert _total(db) == value


@pytest.mark.parametrize("known", [True, False])
def test_raw_deletion_withholds_current_total_without_destroying_observation(
    tmp_path: Path,
    known: bool,
) -> None:
    # Given: populated success proves the fixture reached actual projection ingest.
    db = tmp_path / "synthetic.sqlite"
    _send(db, _batch((_daily(), _raw()), sequence=1, statistics=True))
    assert _total(db) == 6.0
    # When: known or unmapped raw deletion reaches the existing ingest transaction.
    _send(db, _batch(deleted=(_deletion(known),), sequence=2))
    # Then: preserve the last-known value, but do not advertise it as current.
    points = get_timeseries(db, ("steps",), START, END).points
    assert any(point.value == 6.0 for point in points)
    assert _total(db) is None, "raw deletion left an affected projection current"


def test_raw_correction_invalidates_old_and_new_days_but_not_another_source(
    tmp_path: Path,
) -> None:
    # Given: two affected days and independent projections from another source.
    db = tmp_path / "synthetic.sqlite"
    daily = (_daily(), _daily(10.0, "2026-06-02"))
    other = tuple(
        sample.model_copy(
            update={
                "source_key": _fixture().sources[1].source_key,
                "value": 20.0,
            }
        )
        for sample in daily
    )
    initial = _batch((*daily, *other, _raw()), sequence=1, statistics=True)
    other_cursor = (
        _batch(other, sequence=1, statistics=True)
        .sync.cursors[0]
        .model_copy(
            update={"source_key": other[0].source_key},
        )
    )
    initial = initial.model_copy(
        update={
            "sync": initial.sync.model_copy(
                update={
                    "cursors": (*initial.sync.cursors, other_cursor),
                }
            ),
        }
    )
    _send(db, initial)
    assert _total(db) == 26.0
    assert _total(db, "2026-06-02") == 30.0
    # When: the same raw identity changes both value and date.
    _send(db, _batch((_raw(1.0, "2026-06-02"),), sequence=2))
    # Then: only the unrelated source's completed projections stay current.
    assert _total(db) == 20.0
    assert _total(db, "2026-06-02") == 20.0
    assert (
        len(get_timeseries(db, ("steps",), START, "2026-06-03T00:00:00Z").points) == 5
    )


@pytest.mark.parametrize("newer", [0.0, 6.0])
def test_unseen_older_daily_cannot_overwrite_a_newer_scoped_value(
    tmp_path: Path,
    newer: float,
) -> None:
    # Given: the current 6/0 control was genuinely accepted at a higher order.
    db = tmp_path / "synthetic.sqlite"
    _send(db, _batch((_daily(10.0),), sequence=1, statistics=True))
    _send(db, _batch((_daily(newer),), sequence=3, statistics=True))
    assert _total(db) == newer
    # When: a distinct unseen older observation arrives with a later client clock.
    older = _batch((_daily(7.0),), sequence=2, statistics=True)
    _send(db, older.model_copy(update={"generated_at": "2026-06-09T00:00:00Z"}))
    # Then: causal order governs the retained value, not arrival/client timestamps.
    assert _total(db) == newer, "late old delivery overwrote the accepted correction"


def test_late_raw_change_cannot_undo_newer_raw_and_daily_observations(
    tmp_path: Path,
) -> None:
    # Given: raw and daily observations share one durable order domain.
    db = tmp_path / "synthetic.sqlite"
    _send(db, _batch((_raw(),), sequence=1))
    _send(db, _batch((_raw(4.0),), sequence=3))
    _send(db, _batch((_daily(0.0),), sequence=4, statistics=True))
    assert _total(db) == 0.0
    # When: an earlier raw correction arrives after the newer reaggregation.
    _send(db, _batch((_raw(1.0),), sequence=2))
    # Then: reopening real queries retains both newer representations.
    assert _total(db) == 0.0
    raw = [
        point
        for point in get_timeseries(db, ("steps",), START, END).points
        if point.metadata.get("sample_kind") == "raw_quantity"
    ]
    assert [point.value for point in raw] == [4.0]


def test_empty_statistics_window_cannot_restore_a_deleted_day(tmp_path: Path) -> None:
    # Given: a raw deletion invalidated the previous positive projection.
    db = tmp_path / "synthetic.sqlite"
    _send(db, _batch((_daily(), _raw()), sequence=1, statistics=True))
    assert _total(db) == 6.0
    _send(db, _batch(deleted=(_deletion(),), sequence=2))
    # When: the producer reports a successful query window without readable values.
    _send(db, _batch(sequence=3, statistics=True))
    # Then: no zero or current baseline is invented; last-known 6 survives.
    assert [
        point.value for point in get_timeseries(db, ("steps",), START, END).points
    ] == [6.0]
    assert _total(db) is None


def test_identical_unordered_replay_does_not_reinvalidate_after_reaggregation(
    tmp_path: Path,
) -> None:
    # Given: an unordered legacy raw observation was already applied.
    db = tmp_path / "synthetic.sqlite"
    legacy = _batch((_raw(),))
    _send(db, legacy)
    _send(db, _batch((_daily(),), sequence=3, statistics=True))
    assert _total(db) == 6.0
    # When: the exact same unordered payload is retried after restart/reopen.
    _send(db, legacy)
    # Then: this retry is not a new mutation or restoration authority.
    assert _total(db) == 6.0
    assert len(get_timeseries(db, ("steps",), START, END).points) == 2


@pytest.mark.parametrize("surface", ["cli", "stdio"])
def test_real_consumers_stop_advertising_invalid_total(
    tmp_path: Path,
    surface: Literal["cli", "stdio"],
) -> None:
    # Given: actual serialization of a useful current projection is available.
    db = tmp_path / "synthetic.sqlite"
    _send(db, _batch((_daily(), _raw()), sequence=1, statistics=True))
    assert _total(db) == 6.0
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "get_daily_summary",
            "arguments": {"start_date": "2026-06-01", "end_date": "2026-06-02"},
        },
    }
    # When: deletion commits before a CLI read or between two calls in one MCP process.
    match surface:
        case "cli":
            _send(db, _batch(deleted=(_deletion(),), sequence=2))
            output = run(
                [
                    sys.executable,
                    "-c",
                    CLI,
                    "query",
                    "daily-summary",
                    "--db",
                    str(db),
                    "--start-date",
                    "2026-06-01",
                    "--end-date",
                    "2026-06-02",
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            assert output.returncode == 0
            assert output.stderr == ""
            summary = DailySummaryResult.model_validate_json(output.stdout)
        case "stdio":
            with line_process(
                [sys.executable, "-c", CLI, "mcp", "start", "--db", str(db)]
            ) as mcp:
                before = status_payload(
                    JSON_OBJECT.validate_json(send(mcp, json.dumps(request)))
                )
                assert DailySummaryResult.model_validate_json(json.dumps(before)).days[
                    0
                ].daily_activity_totals == {"steps": 6.0}
                _send(db, _batch(deleted=(_deletion(),), sequence=2))
                after = status_payload(
                    JSON_OBJECT.validate_json(
                        send(mcp, json.dumps({**request, "id": 2}))
                    )
                )
                summary = DailySummaryResult.model_validate_json(json.dumps(after))
    # Then: actual consumer output cannot present the old 6 as a current total.
    assert summary.days[0].daily_activity_totals.get("steps") is None


root_batch = _batch
daily_sample = _daily
raw_sample = _raw
raw_deletion = _deletion
ingest_root_batch = _send
current_total = _total

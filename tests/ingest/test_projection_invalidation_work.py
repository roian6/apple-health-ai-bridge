import json
import sqlite3
from collections.abc import Generator
from contextlib import contextmanager
from datetime import date, timedelta
from pathlib import Path

import pytest

import health_bridge.ingest as ingest_module
from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import Sample
from health_bridge.queries import get_daily_summary
from health_bridge.storage.database import connect_database
from tests.ingest import test_daily_projection_corrections as root
from tests.mcp.committed_read_support import JSON_OBJECT

FIRST = date(2026, 6, 1)
DAYS = 14
END = (FIRST + timedelta(days=DAYS)).isoformat()


def _batch(samples: tuple[Sample, ...], sequence: int) -> HealthBridgeBatchV1:
    batch = root.root_batch(samples, sequence=sequence, statistics=sequence == 1)
    if sequence == 1:
        cursor = batch.sync.cursors[0]
        observation = JSON_OBJECT.validate_json(cursor.cursor_value)
        observation["statistics_window"] = {
            "start_time": root.START,
            "end_time": END + "T00:00:00Z",
        }
        batch = batch.model_copy(
            update={
                "sync": batch.sync.model_copy(
                    update={
                        "cursors": (
                            cursor.model_copy(
                                update={"cursor_value": json.dumps(observation)}
                            ),
                        )
                    }
                )
            }
        )
    return HealthBridgeBatchV1.model_validate_json(batch.model_dump_json())


def _seed(db: Path) -> None:
    template = root.daily_sample(6.0)
    samples = tuple(
        template.model_copy(
            update={
                "client_record_id": f"synthetic-work-daily-{index}",
                "start_time": f"{FIRST + timedelta(days=index):%Y-%m-%d}T00:00:00Z",
                "end_time": f"{FIRST + timedelta(days=index + 1):%Y-%m-%d}T00:00:00Z",
                "metadata": {
                    **template.metadata,
                    "calendar_day": (FIRST + timedelta(days=index)).isoformat(),
                },
            }
        )
        for index in range(DAYS)
    )
    root.ingest_root_batch(db, _batch(samples, 1))
    before = get_daily_summary(db, FIRST.isoformat(), END)
    assert len(before.days) == DAYS
    assert all(day.daily_activity_totals == {"steps": 6.0} for day in before.days)


def _changes(count: int) -> HealthBridgeBatchV1:
    return _batch(
        tuple(
            root.raw_sample(1.0).model_copy(
                update={"client_record_id": f"synthetic-work-raw-{index}"}
            )
            for index in range(count)
        ),
        2,
    )


def _assert_only_affected_day(db: Path) -> None:
    after = get_daily_summary(db, FIRST.isoformat(), END)
    assert after.days[0].daily_activity_totals.get("steps") is None
    assert after.days[0].sample_statistics["steps"].projection_status == "last_known"
    assert all(day.daily_activity_totals == {"steps": 6.0} for day in after.days[1:])


def test_raw_volume_preserves_per_day_invalidation_control(tmp_path: Path) -> None:
    db = tmp_path / "control.sqlite"
    _seed(db)
    root.ingest_root_batch(db, _changes(128))
    _assert_only_affected_day(db)


def test_doubling_raw_batch_does_not_quadruple_sqlite_work(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    ticks = 0

    def observe_work() -> int:
        nonlocal ticks
        ticks += 1
        return 0

    @contextmanager
    def measured_connection(path: Path) -> Generator[sqlite3.Connection, None, None]:
        with connect_database(path) as connection:
            connection.set_progress_handler(observe_work, 100)
            try:
                yield connection
            finally:
                connection.set_progress_handler(None, 0)

    work: list[int] = []
    for count in (64, 128):
        db = tmp_path / f"scale-{count}.sqlite"
        _seed(db)
        with monkeypatch.context() as patch:
            patch.setattr(ingest_module, "connect_database", measured_connection)
            ticks = 0
            root.ingest_root_batch(db, _changes(count))
            work.append(ticks)
        _assert_only_affected_day(db)
    assert work[0] > 0
    assert work[1] <= 3 * work[0] + 20, (
        "Doubling actual raw ingest approaches quadratic SQLite work: "
        f"{work[0]} -> {work[1]} progress callbacks"
    )

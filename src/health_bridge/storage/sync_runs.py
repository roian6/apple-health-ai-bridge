import sqlite3
from datetime import UTC, datetime

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.storage.models import IngestResult

INSERT_SYNC_RUN_SQL = (
    "insert into sync_runs (started_at, finished_at, status, schema_id, "
    "schema_version, fixture_name, source_count, health_type_count, sample_count, "
    "workout_count, sleep_session_count, deleted_record_count, sync_cursor_count, "
    "error_summary, sync_window_start, sync_window_end) "
    "values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
)


def insert_sync_run(
    connection: sqlite3.Connection,
    fixture_name: str,
    result: IngestResult,
    batch: HealthBridgeBatchV1 | None,
) -> None:
    timestamp = _utc_now()
    schema_id = None if batch is None else batch.schema_id
    schema_version = None if batch is None else batch.schema_version
    sync_window_start = None if batch is None else batch.sync.sync_window.start_time
    sync_window_end = None if batch is None else batch.sync.sync_window.end_time
    _ = connection.execute(
        INSERT_SYNC_RUN_SQL,
        (
            timestamp,
            timestamp,
            result.status,
            schema_id,
            schema_version,
            fixture_name,
            result.source_count,
            result.health_type_count,
            result.sample_count,
            result.workout_count,
            result.sleep_session_count,
            result.deleted_record_count,
            result.sync_cursor_count,
            result.error_summary,
            sync_window_start,
            sync_window_end,
        ),
    )


def _utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")

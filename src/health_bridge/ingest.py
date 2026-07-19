import json
import sqlite3
from pathlib import Path

from pydantic import ValidationError

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.storage.database import connect_database, initialize_database
from health_bridge.storage.models import (
    IngestResult,
    failed_ingest_result,
)
from health_bridge.storage.records import upsert_batch_records
from health_bridge.storage.sync_runs import insert_sync_run

MALFORMED_JSON_SUMMARY = "Fixture JSON could not be decoded."
SCHEMA_ERROR_SUMMARY = "Fixture did not match health_bridge.batch.v1 schema."
STORAGE_ERROR_SUMMARY = "Fixture records could not be stored."


def ingest_fixture(db_path: Path, input_path: Path) -> IngestResult:
    initialize_database(db_path)
    try:
        batch = HealthBridgeBatchV1.model_validate_json(input_path.read_bytes())
    except json.JSONDecodeError:
        result = failed_ingest_result(MALFORMED_JSON_SUMMARY)
        _record_failed_sync_run(db_path, input_path.name, result)
        raise
    except ValidationError as exc:
        error_summary = (
            MALFORMED_JSON_SUMMARY
            if _is_malformed_json_error(exc)
            else SCHEMA_ERROR_SUMMARY
        )
        result = failed_ingest_result(error_summary)
        _record_failed_sync_run(db_path, input_path.name, result)
        raise

    return ingest_batch(db_path, batch, input_path.name)


def ingest_batch(
    db_path: Path,
    batch: HealthBridgeBatchV1,
    source_name: str,
) -> IngestResult:
    initialize_database(db_path)
    result = _successful_result(batch)
    try:
        with connect_database(db_path) as connection:
            upsert_batch_records(connection, batch)
            insert_sync_run(connection, source_name, result, batch)
    except sqlite3.Error:
        failed_result = failed_ingest_result(STORAGE_ERROR_SUMMARY)
        _record_failed_sync_run(db_path, source_name, failed_result, batch)
        raise
    return result


def _successful_result(batch: HealthBridgeBatchV1) -> IngestResult:
    return IngestResult(
        status="succeeded",
        source_count=len({source.source_key for source in batch.sources}),
        health_type_count=len(
            {health_type.type_code for health_type in batch.health_types}
        ),
        sample_count=len(
            {
                (sample.source_key, sample.type_code, sample.client_record_id)
                for sample in batch.samples
            },
        ),
        workout_count=len(
            {
                (workout.source_key, workout.client_record_id)
                for workout in batch.workouts
            },
        ),
        sleep_session_count=len(
            {
                (sleep_session.source_key, sleep_session.client_record_id)
                for sleep_session in batch.sleep_sessions
            },
        ),
        deleted_record_count=len(
            {
                (
                    deleted_record.source_key,
                    deleted_record.record_family,
                    deleted_record.client_record_id,
                )
                for deleted_record in batch.deleted_records
            },
        ),
        sync_cursor_count=len(
            {(cursor.source_key, cursor.cursor_kind) for cursor in batch.sync.cursors},
        ),
    )


def _record_failed_sync_run(
    db_path: Path,
    source_name: str,
    result: IngestResult,
    batch: HealthBridgeBatchV1 | None = None,
) -> None:
    with connect_database(db_path) as connection:
        insert_sync_run(connection, source_name, result, batch)


def _is_malformed_json_error(exc: ValidationError) -> bool:
    return "Invalid JSON" in str(exc)

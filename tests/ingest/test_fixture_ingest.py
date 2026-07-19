import sqlite3
from pathlib import Path
from typing import Final

import pytest
from pydantic import TypeAdapter, ValidationError

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import (
    DeletedRecord,
    HealthType,
    Sample,
    SleepSession,
    Source,
    SyncContext,
    SyncCursor,
    TimeWindow,
)
from health_bridge.ingest import ingest_batch, ingest_fixture
from health_bridge.storage import initialize_database
from health_bridge.storage.sqlite_rows import fetch_one_int

FIXTURE_PATH = Path("fixtures/health_bridge_batch_v1.synthetic.json")
SOURCE_PROVENANCE_SQL = (
    "select name, kind, bundle_id, device_model from sources where source_key = ?"
)
FAILED_SYNC_RUN_SQL = (
    "select status, error_summary, sample_count, source_count "
    "from sync_runs order by sync_run_id desc limit 1"
)
SOURCE_ROW_ADAPTER: Final[TypeAdapter[tuple[str, str, str, str] | None]] = TypeAdapter(
    tuple[str, str, str, str] | None,
)
FAILED_SYNC_ROW_ADAPTER: Final[TypeAdapter[tuple[str, str | None, int, int] | None]] = (
    TypeAdapter(tuple[str, str | None, int, int] | None)
)
CURSOR_VALUE_ADAPTER: Final[TypeAdapter[tuple[str] | None]] = TypeAdapter(
    tuple[str] | None,
)
CLIENT_RECORD_ID_ROWS_ADAPTER: Final[TypeAdapter[list[tuple[str]]]] = TypeAdapter(
    list[tuple[str]],
)
BASELINE_NAMESPACE_ROW_ADAPTER: Final[TypeAdapter[tuple[str, int] | None]] = (
    TypeAdapter(tuple[str, int] | None)
)
COUNT_ROW_ADAPTER: Final[TypeAdapter[tuple[int] | None]] = TypeAdapter(
    tuple[int] | None
)
COUNT_QUERIES = {
    "sources": "select count(*) from sources",
    "health_types": "select count(*) from health_types",
    "health_type_aliases": "select count(*) from health_type_aliases",
    "samples": "select count(*) from samples",
    "workouts": "select count(*) from workouts",
    "sleep_sessions": "select count(*) from sleep_sessions",
    "sleep_stage_intervals": "select count(*) from sleep_stage_intervals",
    "deleted_records": "select count(*) from deleted_records",
    "sync_cursors": "select count(*) from sync_cursors",
    "sync_runs": "select count(*) from sync_runs",
}


def fetch_count(connection: sqlite3.Connection, table_name: str) -> int:
    return fetch_one_int(connection, COUNT_QUERIES[table_name])


def test_ingest_fixture_stores_batch_records_when_fixture_is_valid(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    initialize_database(db_path)

    # When
    result = ingest_fixture(db_path, FIXTURE_PATH)

    # Then
    with sqlite3.connect(db_path) as connection:
        counts = {
            table_name: fetch_count(connection, table_name)
            for table_name in (
                "sources",
                "health_types",
                "health_type_aliases",
                "samples",
                "workouts",
                "sleep_sessions",
                "sleep_stage_intervals",
                "deleted_records",
                "sync_cursors",
                "sync_runs",
            )
        }
        source_row = SOURCE_ROW_ADAPTER.validate_python(
            connection.execute(
                SOURCE_PROVENANCE_SQL,
                ("synthetic.phone.alpha",),
            ).fetchone(),
        )

    assert result.status == "succeeded"
    assert counts == {
        "sources": 2,
        "health_types": 4,
        "health_type_aliases": 5,
        "samples": 3,
        "workouts": 1,
        "sleep_sessions": 1,
        "sleep_stage_intervals": 5,
        "deleted_records": 1,
        "sync_cursors": 2,
        "sync_runs": 1,
    }
    assert source_row == (
        "Synthetic Phone Alpha",
        "phone",
        "com.example.synthetic.healthbridge",
        "SyntheticPhone1,1",
    )


def test_ingest_fixture_does_not_duplicate_logical_records_when_repeated(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    initialize_database(db_path)

    # When
    first_result = ingest_fixture(db_path, FIXTURE_PATH)
    second_result = ingest_fixture(db_path, FIXTURE_PATH)

    # Then
    with sqlite3.connect(db_path) as connection:
        samples_count = fetch_count(connection, "samples")
        sync_runs_count = fetch_count(connection, "sync_runs")

    assert first_result.status == "succeeded"
    assert second_result.status == "succeeded"
    assert samples_count == 3
    assert sync_runs_count == 2


def test_ingest_fixture_records_failed_sync_run_when_schema_version_is_invalid(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    invalid_path = tmp_path / "invalid.json"
    fixture_text = FIXTURE_PATH.read_text(encoding="utf-8")
    _ = invalid_path.write_text(
        fixture_text.replace('"schema_version": "1.0.0"', '"schema_version": "2.0.0"'),
        encoding="utf-8",
    )
    initialize_database(db_path)

    # When / Then
    with pytest.raises(ValidationError):
        _ = ingest_fixture(db_path, invalid_path)

    with sqlite3.connect(db_path) as connection:
        row = FAILED_SYNC_ROW_ADAPTER.validate_python(
            connection.execute(
                FAILED_SYNC_RUN_SQL,
            ).fetchone(),
        )

    assert row is not None
    assert row == (
        "failed",
        "Fixture did not match health_bridge.batch.v1 schema.",
        0,
        0,
    )
    assert row[1] is not None
    assert "2.0.0" not in row[1]


def test_ingest_fixture_records_failed_sync_run_when_storage_write_fails(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    invalid_storage_path = tmp_path / "invalid-storage.json"
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    invalid_sample = batch.samples[0].model_copy(
        update={"source_key": "synthetic.missing.source"},
    )
    invalid_batch = batch.model_copy(update={"samples": (invalid_sample,)})
    _ = invalid_storage_path.write_text(
        invalid_batch.model_dump_json(),
        encoding="utf-8",
    )
    initialize_database(db_path)

    # When / Then
    with pytest.raises(sqlite3.Error):
        _ = ingest_fixture(db_path, invalid_storage_path)

    with sqlite3.connect(db_path) as connection:
        sync_runs_count = fetch_count(connection, "sync_runs")
        samples_count = fetch_count(connection, "samples")
        row = FAILED_SYNC_ROW_ADAPTER.validate_python(
            connection.execute(
                FAILED_SYNC_RUN_SQL,
            ).fetchone(),
        )

    assert sync_runs_count == 1
    assert samples_count == 0
    assert row is not None
    assert row[0] == "failed"
    assert row[1] == "Fixture records could not be stored."


def test_ingest_fixture_counts_unique_logical_records_when_batch_has_duplicates(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    duplicate_path = tmp_path / "duplicate-sample.json"
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    duplicate_batch = batch.model_copy(
        update={"samples": (*batch.samples, batch.samples[0])},
    )
    _ = duplicate_path.write_text(
        duplicate_batch.model_dump_json(),
        encoding="utf-8",
    )
    initialize_database(db_path)

    # When
    result = ingest_fixture(db_path, duplicate_path)

    # Then
    with sqlite3.connect(db_path) as connection:
        samples_count = fetch_count(connection, "samples")
        row = FAILED_SYNC_ROW_ADAPTER.validate_python(
            connection.execute(
                FAILED_SYNC_RUN_SQL,
            ).fetchone(),
        )

    assert result.sample_count == 3
    assert samples_count == 3
    assert row is not None
    assert row[0] == "succeeded"
    assert row[2] == 3


def test_ingest_fixture_ignores_duplicate_sleep_intervals_in_same_batch(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "duplicate-sleep.sqlite"
    duplicate_path = tmp_path / "duplicate-sleep.json"
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    sleep_session = batch.sleep_sessions[0]
    duplicate_sleep_session = sleep_session.model_copy(
        update={
            "stage_intervals": (
                *sleep_session.stage_intervals,
                sleep_session.stage_intervals[0],
            ),
        },
    )
    duplicate_batch = batch.model_copy(
        update={"sleep_sessions": (duplicate_sleep_session,)},
    )
    _ = duplicate_path.write_text(
        duplicate_batch.model_dump_json(),
        encoding="utf-8",
    )
    initialize_database(db_path)

    # When
    result = ingest_fixture(db_path, duplicate_path)

    # Then
    with sqlite3.connect(db_path) as connection:
        sleep_stage_count = fetch_count(connection, "sleep_stage_intervals")
        sync_runs_count = fetch_count(connection, "sync_runs")

    assert result.status == "succeeded"
    assert sleep_stage_count == 5
    assert sync_runs_count == 1


def test_ingest_batch_supersedes_partial_sleep_revision_with_complete_session(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "sleep-revision.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    complete = batch.sleep_sessions[0]
    partial = complete.model_copy(
        update={
            "client_record_id": "synthetic-sleep-partial-20260604",
            "end_time": complete.stage_intervals[1].end_time,
            "stage_intervals": complete.stage_intervals[:2],
        }
    )
    partial_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (partial,),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        }
    )
    complete_batch = partial_batch.model_copy(update={"sleep_sessions": (complete,)})
    _ = ingest_batch(db_path, partial_batch, "sleep-partial")

    # When
    result = ingest_batch(db_path, complete_batch, "sleep-complete")

    # Then
    with sqlite3.connect(db_path) as connection:
        session_rows = connection.execute(
            "select client_record_id, start_time, end_time from sleep_sessions"
        ).fetchall()
        interval_count = fetch_count(connection, "sleep_stage_intervals")

    assert result.status == "succeeded"
    assert session_rows == [
        (complete.client_record_id, complete.start_time, complete.end_time)
    ]
    assert interval_count == len(complete.stage_intervals)


def test_ingest_batch_does_not_regress_complete_sleep_with_late_partial_replay(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "sleep-revision-regression.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    complete = batch.sleep_sessions[0]
    partial = complete.model_copy(
        update={
            "client_record_id": "synthetic-sleep-partial-20260604",
            "end_time": complete.stage_intervals[1].end_time,
            "stage_intervals": complete.stage_intervals[:2],
        }
    )
    complete_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (complete,),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        }
    )
    partial_batch = complete_batch.model_copy(update={"sleep_sessions": (partial,)})
    _ = ingest_batch(db_path, complete_batch, "sleep-complete")

    # When
    result = ingest_batch(db_path, partial_batch, "sleep-partial-replay")

    # Then
    with sqlite3.connect(db_path) as connection:
        session_rows = connection.execute(
            "select client_record_id, start_time, end_time from sleep_sessions"
        ).fetchall()
        interval_count = fetch_count(connection, "sleep_stage_intervals")

    assert result.status == "succeeded"
    assert session_rows == [
        (complete.client_record_id, complete.start_time, complete.end_time)
    ]
    assert interval_count == len(complete.stage_intervals)


def test_superseded_sleep_revision_cannot_resurrect_after_winner_is_deleted(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "sleep-supersession-tombstones.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    complete = batch.sleep_sessions[0]
    partial = complete.model_copy(
        update={
            "client_record_id": "synthetic-sleep-superseded-partial",
            "end_time": complete.stage_intervals[1].end_time,
            "stage_intervals": complete.stage_intervals[:2],
        }
    )
    base_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        }
    )
    partial_batch = base_batch.model_copy(update={"sleep_sessions": (partial,)})
    complete_batch = base_batch.model_copy(update={"sleep_sessions": (complete,)})
    delete_winner_batch = base_batch.model_copy(
        update={
            "sleep_sessions": (),
            "deleted_records": (
                DeletedRecord(
                    record_family="sleep_session",
                    source_key=complete.source_key,
                    client_record_id=complete.client_record_id,
                    deleted_at="2026-06-05T00:00:00Z",
                ),
            ),
        }
    )
    _ = ingest_batch(db_path, partial_batch, "sleep-partial")
    _ = ingest_batch(db_path, complete_batch, "sleep-complete")
    _ = ingest_batch(db_path, delete_winner_batch, "sleep-delete-winner")

    # When
    result = ingest_batch(db_path, partial_batch, "sleep-replay-superseded")

    # Then
    with sqlite3.connect(db_path) as connection:
        session_count = fetch_count(connection, "sleep_sessions")
        tombstone_rows = CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
            connection.execute(
                "select client_record_id from deleted_records where record_family = ?",
                ("sleep_session",),
            ).fetchall()
        )
        tombstone_ids = {row[0] for row in tombstone_rows}

    assert result.status == "succeeded"
    assert session_count == 0
    assert tombstone_ids == {partial.client_record_id, complete.client_record_id}


def test_ingest_batch_accepts_authoritative_shortened_sleep_revision(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "sleep-authoritative-shortening.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    original = batch.sleep_sessions[0]
    shortened = original.model_copy(
        update={
            "client_record_id": "synthetic-sleep-shortened-revision",
            "end_time": original.stage_intervals[3].end_time,
            "stage_intervals": original.stage_intervals[:4],
        }
    )
    base_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        }
    )
    original_batch = base_batch.model_copy(
        update={"sleep_sessions": (original,), "deleted_records": ()}
    )
    correction_batch = base_batch.model_copy(
        update={
            "sleep_sessions": (shortened,),
            "deleted_records": (
                DeletedRecord(
                    record_family="sleep_session",
                    source_key=original.source_key,
                    client_record_id=original.client_record_id,
                    deleted_at="2026-06-05T00:00:00Z",
                ),
            ),
        }
    )
    _ = ingest_batch(db_path, original_batch, "sleep-original")

    # When
    result = ingest_batch(db_path, correction_batch, "sleep-shortened")

    # Then
    with sqlite3.connect(db_path) as connection:
        session_rows = connection.execute(
            "select client_record_id, start_time, end_time from sleep_sessions"
        ).fetchall()
        tombstone_ids = {
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    (
                        "select client_record_id from deleted_records "
                        "where record_family = ?"
                    ),
                    ("sleep_session",),
                ).fetchall()
            )
        }

    assert result.status == "succeeded"
    assert session_rows == [
        (shortened.client_record_id, shortened.start_time, shortened.end_time)
    ]
    assert tombstone_ids == {original.client_record_id}


def test_first_anchored_sleep_baseline_replaces_shifted_legacy_revision(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "sleep-anchored-baseline.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    legacy = batch.sleep_sessions[0]
    shifted = legacy.model_copy(
        update={
            "client_record_id": "synthetic-sleep-shifted-revision",
            "start_time": legacy.stage_intervals[1].start_time,
            "stage_intervals": legacy.stage_intervals[1:],
        }
    )
    legacy_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (legacy,),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        }
    )
    anchored_batch = legacy_batch.model_copy(
        update={
            "sleep_sessions": (shifted,),
            "sync": batch.sync.model_copy(
                update={
                    "cursors": (
                        SyncCursor(
                            source_key=shifted.source_key,
                            cursor_kind="anchored_sleep_sync",
                            cursor_value="synthetic-sleep-anchor-1",
                        ),
                    )
                }
            ),
        }
    )
    _ = ingest_batch(db_path, legacy_batch, "sleep-legacy")

    # When
    result = ingest_batch(db_path, anchored_batch, "sleep-first-anchored-baseline")

    # Then
    with sqlite3.connect(db_path) as connection:
        session_rows = connection.execute(
            "select client_record_id, start_time, end_time from sleep_sessions"
        ).fetchall()
        tombstone_ids = {
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    (
                        "select client_record_id from deleted_records "
                        "where record_family = ?"
                    ),
                    ("sleep_session",),
                ).fetchall()
            )
        }

    assert result.status == "succeeded"
    assert session_rows == [
        (shifted.client_record_id, shifted.start_time, shifted.end_time)
    ]
    assert tombstone_ids == {legacy.client_record_id}


def _assert_equal_pending_empty_sleep_epoch_is_ignored(
    db_path: Path,
    empty_reset_batch: HealthBridgeBatchV1,
) -> None:
    replay = empty_reset_batch.model_copy(
        update={
            "sync": empty_reset_batch.sync.model_copy(
                update={
                    "cursors": tuple(
                        cursor.model_copy(
                            update={"cursor_value": "synthetic-regressed-anchor"}
                        )
                        if cursor.cursor_kind == "anchored_sleep_sync"
                        else cursor
                        for cursor in empty_reset_batch.sync.cursors
                    )
                }
            )
        }
    )
    result = ingest_batch(db_path, replay, "sleep-equal-empty-epoch-replay")
    with sqlite3.connect(db_path) as connection:
        anchor = CURSOR_VALUE_ADAPTER.validate_python(
            connection.execute(
                "select cursor_value from sync_cursors where cursor_kind = ?",
                ("anchored_sleep_sync",),
            ).fetchone()
        )
    assert result.status == "succeeded"
    assert anchor == ("synthetic-new-anchor",)


def _assert_equal_authoritative_sleep_epoch_is_ignored(
    db_path: Path,
    reset_batch: HealthBridgeBatchV1,
    rebound: SleepSession,
) -> None:
    equal_epoch_replay = reset_batch.model_copy(
        update={
            "sleep_sessions": (
                rebound.model_copy(
                    update={"client_record_id": "synthetic-equal-epoch-stale-sleep"}
                ),
            ),
            "sync": reset_batch.sync.model_copy(
                update={
                    "cursors": tuple(
                        cursor.model_copy(
                            update={"cursor_value": "synthetic-old-anchor"}
                        )
                        if cursor.cursor_kind == "anchored_sleep_sync"
                        else cursor
                        for cursor in reset_batch.sync.cursors
                    )
                }
            ),
        }
    )
    equal_result = ingest_batch(
        db_path,
        equal_epoch_replay,
        "sleep-equal-authoritative-epoch-replay",
    )
    with sqlite3.connect(db_path) as connection:
        equal_session_ids = {
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    "select client_record_id from sleep_sessions"
                ).fetchall()
            )
        }
        equal_anchor = CURSOR_VALUE_ADAPTER.validate_python(
            connection.execute(
                "select cursor_value from sync_cursors where cursor_kind = ?",
                ("anchored_sleep_sync",),
            ).fetchone()
        )
    assert equal_result.status == "succeeded"
    assert equal_session_ids == {rebound.client_record_id}
    assert equal_anchor == ("synthetic-new-anchor",)


def test_sleep_baseline_reset_rebinds_identity_when_receiver_already_has_anchor(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "sleep-baseline-reset.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    original = batch.sleep_sessions[0].model_copy(
        update={"client_record_id": "synthetic-old-sleep-revision"}
    )
    rebound = original.model_copy(
        update={"client_record_id": "synthetic-new-sleep-revision"}
    )
    original_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (original,),
            "deleted_records": (),
            "sync": batch.sync.model_copy(
                update={
                    "cursors": (
                        SyncCursor(
                            source_key=original.source_key,
                            cursor_kind="anchored_sleep_sync",
                            cursor_value="synthetic-old-anchor",
                        ),
                        SyncCursor(
                            source_key=original.source_key,
                            cursor_kind="anchored_sleep_baseline_reset",
                            cursor_value="v2:1",
                        ),
                    )
                }
            ),
        }
    )
    reset_batch = original_batch.model_copy(
        update={
            "sleep_sessions": (rebound,),
            "sync": batch.sync.model_copy(
                update={
                    "cursors": (
                        SyncCursor(
                            source_key=rebound.source_key,
                            cursor_kind="anchored_sleep_sync",
                            cursor_value="synthetic-new-anchor",
                        ),
                        SyncCursor(
                            source_key=rebound.source_key,
                            cursor_kind="anchored_sleep_baseline_reset",
                            cursor_value="v2:3",
                        ),
                    )
                }
            ),
        }
    )
    empty_reset_batch = reset_batch.model_copy(update={"sleep_sessions": ()})
    _ = ingest_batch(db_path, original_batch, "sleep-old-namespace")

    empty_result = ingest_batch(
        db_path,
        empty_reset_batch,
        "sleep-empty-new-namespace",
    )

    with sqlite3.connect(db_path) as connection:
        sessions_after_empty = [
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    "select client_record_id from sleep_sessions"
                ).fetchall()
            )
        ]
        pending_namespace = BASELINE_NAMESPACE_ROW_ADAPTER.validate_python(
            connection.execute(
                (
                    "select namespace, authoritative_applied "
                    "from sleep_baseline_namespaces where namespace = ?"
                ),
                ("v2:3",),
            ).fetchone()
        )

    assert empty_result.status == "succeeded"
    assert sessions_after_empty == [original.client_record_id]
    assert pending_namespace == ("v2:3", 0)
    _assert_equal_pending_empty_sleep_epoch_is_ignored(db_path, empty_reset_batch)

    result = ingest_batch(db_path, reset_batch, "sleep-rebound-namespace")

    with sqlite3.connect(db_path) as connection:
        session_ids = [
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    "select client_record_id from sleep_sessions"
                ).fetchall()
            )
        ]
        tombstone_ids = {
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    (
                        "select client_record_id from deleted_records "
                        "where record_family = ?"
                    ),
                    ("sleep_session",),
                ).fetchall()
            )
        }

        applied_namespace = BASELINE_NAMESPACE_ROW_ADAPTER.validate_python(
            connection.execute(
                (
                    "select namespace, authoritative_applied "
                    "from sleep_baseline_namespaces where namespace = ?"
                ),
                ("v2:3",),
            ).fetchone()
        )

    assert result.status == "succeeded"
    assert session_ids == [rebound.client_record_id]
    assert tombstone_ids == {original.client_record_id}
    assert applied_namespace == ("v2:3", 1)

    _assert_equal_authoritative_sleep_epoch_is_ignored(db_path, reset_batch, rebound)

    with pytest.raises(sqlite3.Error):
        _ = ingest_batch(
            db_path,
            original_batch,
            "sleep-stale-old-namespace-replay",
        )

    with sqlite3.connect(db_path) as connection:
        replayed_session_ids = [
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    "select client_record_id from sleep_sessions"
                ).fetchall()
            )
        ]
        replayed_tombstone_ids = {
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    (
                        "select client_record_id from deleted_records "
                        "where record_family = ?"
                    ),
                    ("sleep_session",),
                ).fetchall()
            )
        }
        reset_cursor = CURSOR_VALUE_ADAPTER.validate_python(
            connection.execute(
                ("select cursor_value from sync_cursors where cursor_kind = ?"),
                ("anchored_sleep_baseline_reset",),
            ).fetchone()
        )
        seen_namespaces = {
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    "select namespace from sleep_baseline_namespaces"
                ).fetchall()
            )
        }

    assert replayed_session_ids == [rebound.client_record_id]
    assert replayed_tombstone_ids == {original.client_record_id}
    assert reset_cursor == ("v2:3",)
    assert seen_namespaces == {
        "v2:1",
        "v2:3",
    }

    delayed = original_batch.model_copy(
        update={
            "sleep_sessions": (
                original.model_copy(
                    update={"client_record_id": "synthetic-unseen-delayed-sleep"}
                ),
            ),
            "sync": original_batch.sync.model_copy(
                update={
                    "cursors": tuple(
                        cursor.model_copy(update={"cursor_value": "v2:2"})
                        if cursor.cursor_kind == "anchored_sleep_baseline_reset"
                        else cursor
                        for cursor in original_batch.sync.cursors
                    )
                }
            ),
        }
    )
    with pytest.raises(sqlite3.Error):
        _ = ingest_batch(db_path, delayed, "sleep-unseen-delayed-epoch")
    with sqlite3.connect(db_path) as connection:
        sessions_after_delayed = {
            row[0]
            for row in CLIENT_RECORD_ID_ROWS_ADAPTER.validate_python(
                connection.execute(
                    "select client_record_id from sleep_sessions"
                ).fetchall()
            )
        }
        reset_after_delayed = CURSOR_VALUE_ADAPTER.validate_python(
            connection.execute(
                "select cursor_value from sync_cursors where cursor_kind = ?",
                ("anchored_sleep_baseline_reset",),
            ).fetchone()
        )
    assert sessions_after_delayed == {rebound.client_record_id}
    assert reset_after_delayed == ("v2:3",)


def test_sleep_baseline_reset_without_anchored_cursor_is_rejected(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "sleep-incomplete-reset.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    source_key = batch.sleep_sessions[0].source_key
    incomplete = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "deleted_records": (),
            "sync": batch.sync.model_copy(
                update={
                    "cursors": (
                        SyncCursor(
                            source_key=source_key,
                            cursor_kind="anchored_sleep_baseline_reset",
                            cursor_value="v2:1",
                        ),
                    )
                }
            ),
        }
    )

    with pytest.raises(sqlite3.Error):
        _ = ingest_batch(db_path, incomplete, "sleep-incomplete-reset")

    with sqlite3.connect(db_path) as connection:
        assert fetch_count(connection, "sleep_sessions") == 0
        assert connection.execute(
            "select count(*) from sleep_baseline_namespaces"
        ).fetchone() == (0,)


def test_installation_scoped_sleep_baselines_do_not_delete_other_devices(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "sleep-installation-sources.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    original_session = batch.sleep_sessions[0]
    original_source = next(
        source
        for source in batch.sources
        if source.source_key == original_session.source_key
    )

    def installation_batch(source_key: str, record_id: str) -> HealthBridgeBatchV1:
        session = original_session.model_copy(
            update={"source_key": source_key, "client_record_id": record_id}
        )
        source = original_source.model_copy(update={"source_key": source_key})
        return batch.model_copy(
            update={
                "sources": (source,),
                "samples": (),
                "workouts": (),
                "sleep_sessions": (session,),
                "deleted_records": (),
                "sync": batch.sync.model_copy(
                    update={
                        "cursors": (
                            SyncCursor(
                                source_key=source_key,
                                cursor_kind="anchored_sleep_sync",
                                cursor_value=f"anchor-{record_id}",
                            ),
                            SyncCursor(
                                source_key=source_key,
                                cursor_kind="anchored_sleep_baseline_reset",
                                cursor_value="v2:1",
                            ),
                        )
                    }
                ),
            }
        )

    legacy_batch = installation_batch(
        "apple_health.phone",
        "synthetic-legacy-phone-sleep",
    )
    _ = ingest_batch(db_path, legacy_batch, "sleep-legacy-phone")
    _ = ingest_batch(
        db_path,
        installation_batch(
            "apple_health.phone.installation-a",
            "synthetic-installation-a-sleep",
        ),
        "sleep-installation-a",
    )
    _ = ingest_batch(
        db_path,
        installation_batch(
            "apple_health.phone.installation-b",
            "synthetic-installation-b-sleep",
        ),
        "sleep-installation-b",
    )
    _ = ingest_batch(
        db_path,
        legacy_batch,
        "sleep-delayed-legacy-phone-replay",
    )

    with sqlite3.connect(db_path) as connection:
        installation_rows = TypeAdapter(list[tuple[str, str]]).validate_python(
            connection.execute(
                """
                select sources.source_key, sleep_sessions.client_record_id
                from sleep_sessions join sources using (source_id)
                """
            ).fetchall()
        )
        records = set(installation_rows)
        legacy_tombstone = COUNT_ROW_ADAPTER.validate_python(
            connection.execute(
                """
                select count(*) from deleted_records
                join sources using (source_id)
                where sources.source_key = ? and client_record_id = ?
                """,
                ("apple_health.phone", "synthetic-legacy-phone-sleep"),
            ).fetchone()
        )
        retirement_marker = CURSOR_VALUE_ADAPTER.validate_python(
            connection.execute(
                """
                select cursor_value from sync_cursors
                join sources using (source_id)
                where sources.source_key = ? and cursor_kind = ?
                """,
                ("apple_health.phone", "sleep_source_retired"),
            ).fetchone()
        )
    assert records == {
        (
            "apple_health.phone.installation-a",
            "synthetic-installation-a-sleep",
        ),
        (
            "apple_health.phone.installation-b",
            "synthetic-installation-b-sleep",
        ),
    }
    assert legacy_tombstone == (1,)
    assert retirement_marker == ("retired-by:apple_health.phone.installation-b",)


def test_ingest_batch_accepts_authoritative_stage_only_sleep_revision(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "sleep-authoritative-stage-correction.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    original = batch.sleep_sessions[0]
    corrected = original.model_copy(
        update={
            "client_record_id": "synthetic-sleep-stage-revision",
            "stage_intervals": tuple(reversed(original.stage_intervals)),
        }
    )
    original_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (original,),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        }
    )
    corrected_batch = original_batch.model_copy(
        update={
            "sleep_sessions": (corrected,),
            "deleted_records": (
                DeletedRecord(
                    record_family="sleep_session",
                    source_key=original.source_key,
                    client_record_id=original.client_record_id,
                    deleted_at="2026-06-05T00:00:00Z",
                ),
            ),
        }
    )
    _ = ingest_batch(db_path, original_batch, "sleep-stage-original")

    # When
    result = ingest_batch(db_path, corrected_batch, "sleep-stage-corrected")

    # Then
    with sqlite3.connect(db_path) as connection:
        session_rows = connection.execute(
            "select client_record_id from sleep_sessions"
        ).fetchall()
        interval_rows = connection.execute(
            """
            select stage, start_time, end_time
            from sleep_stage_intervals
            order by sleep_stage_interval_id
            """
        ).fetchall()

    assert result.status == "succeeded"
    assert session_rows == [(corrected.client_record_id,)]
    assert interval_rows == [
        (interval.stage, interval.start_time, interval.end_time)
        for interval in corrected.stage_intervals
    ]


def test_ingest_batch_replaces_stages_for_same_sleep_record_revision(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "sleep-stage-correction.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    corrected = batch.sleep_sessions[0]
    initial = corrected.model_copy(
        update={"stage_intervals": corrected.stage_intervals[:-1]}
    )
    initial_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (initial,),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        }
    )
    corrected_batch = initial_batch.model_copy(update={"sleep_sessions": (corrected,)})
    _ = ingest_batch(db_path, initial_batch, "sleep-initial")

    # When
    result = ingest_batch(db_path, corrected_batch, "sleep-corrected")

    # Then
    with sqlite3.connect(db_path) as connection:
        interval_count = fetch_count(connection, "sleep_stage_intervals")
        session_count = fetch_count(connection, "sleep_sessions")

    assert result.status == "succeeded"
    assert session_count == 1
    assert interval_count == len(corrected.stage_intervals)


def test_ingest_batch_accepts_equal_end_correction_for_existing_duplicate_id(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "sleep-equal-end-correction.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    complete = batch.sleep_sessions[0]
    original = complete.model_copy(
        update={"stage_intervals": complete.stage_intervals[:1]}
    )
    correction_id = "synthetic-sleep-equal-end-correction"
    correction = complete.model_copy(update={"client_record_id": correction_id})
    original_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (original,),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        }
    )
    correction_batch = original_batch.model_copy(
        update={"sleep_sessions": (correction,)}
    )
    _ = ingest_batch(db_path, original_batch, "sleep-original")
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute("drop index sleep_sessions_source_start_unique")
        source_id = fetch_one_int(
            connection,
            "select source_id from sources where source_key = ?",
            (complete.source_key,),
        )
        cursor = connection.execute(
            """
            insert into sleep_sessions
                (source_id, client_record_id, start_time, end_time)
            values (?, ?, ?, ?)
            """,
            (source_id, correction_id, complete.start_time, complete.end_time),
        )
        duplicate_session_id = cursor.lastrowid
        _ = connection.execute(
            """
            insert into sleep_stage_intervals
                (sleep_session_id, stage, start_time, end_time)
            values (?, ?, ?, ?)
            """,
            (
                duplicate_session_id,
                complete.stage_intervals[0].stage,
                complete.stage_intervals[0].start_time,
                complete.stage_intervals[0].end_time,
            ),
        )

    # When
    result = ingest_batch(db_path, correction_batch, "sleep-correction")

    # Then
    with sqlite3.connect(db_path) as connection:
        session_rows = connection.execute(
            "select client_record_id from sleep_sessions"
        ).fetchall()
        interval_count = fetch_count(connection, "sleep_stage_intervals")

    assert result.status == "succeeded"
    assert session_rows == [(correction_id,)]
    assert interval_count == len(correction.stage_intervals)


def test_ingest_batch_reconciles_deleted_records_by_removing_active_rows(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "deleted-records.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    _ = ingest_fixture(db_path, FIXTURE_PATH)
    delete_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (),
            "deleted_records": (
                DeletedRecord(
                    record_family="sample",
                    source_key="synthetic.phone.alpha",
                    client_record_id=batch.samples[0].client_record_id,
                    deleted_at="2026-06-09T00:00:00Z",
                ),
                DeletedRecord(
                    record_family="workout",
                    source_key="synthetic.watch.bravo",
                    client_record_id=batch.workouts[0].client_record_id,
                    deleted_at="2026-06-09T00:00:00Z",
                ),
                DeletedRecord(
                    record_family="sleep_session",
                    source_key=batch.sleep_sessions[0].source_key,
                    client_record_id=batch.sleep_sessions[0].client_record_id,
                    deleted_at="2026-06-09T00:00:00Z",
                ),
            ),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        },
    )

    # When
    result = ingest_batch(db_path, delete_batch, "delete-batch")

    # Then
    with sqlite3.connect(db_path) as connection:
        counts = {
            table_name: fetch_count(connection, table_name)
            for table_name in (
                "samples",
                "workouts",
                "sleep_sessions",
                "sleep_stage_intervals",
                "deleted_records",
                "sync_runs",
            )
        }

    assert result.status == "succeeded"
    assert result.deleted_record_count == 3
    assert counts == {
        "samples": 2,
        "workouts": 0,
        "sleep_sessions": 0,
        "sleep_stage_intervals": 0,
        "deleted_records": 4,
        "sync_runs": 2,
    }


def test_ingest_batch_does_not_resurrect_tombstoned_records_from_late_replay(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "late-replay.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    delete_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (),
            "deleted_records": (
                DeletedRecord(
                    record_family="sample",
                    source_key=batch.samples[0].source_key,
                    client_record_id=batch.samples[0].client_record_id,
                    deleted_at="2026-06-09T00:00:00Z",
                ),
                DeletedRecord(
                    record_family="workout",
                    source_key=batch.workouts[0].source_key,
                    client_record_id=batch.workouts[0].client_record_id,
                    deleted_at="2026-06-09T00:00:00Z",
                ),
                DeletedRecord(
                    record_family="sleep_session",
                    source_key=batch.sleep_sessions[0].source_key,
                    client_record_id=batch.sleep_sessions[0].client_record_id,
                    deleted_at="2026-06-09T00:00:00Z",
                ),
            ),
            "sync": batch.sync.model_copy(update={"cursors": ()}),
        },
    )
    replay_batch = batch.model_copy(update={"deleted_records": ()})
    _ = ingest_batch(db_path, delete_batch, "delete-first")

    # When
    result = ingest_batch(db_path, replay_batch, "late-active-replay")

    # Then
    with sqlite3.connect(db_path) as connection:
        counts = {
            table_name: fetch_count(connection, table_name)
            for table_name in (
                "samples",
                "workouts",
                "sleep_sessions",
                "sleep_stage_intervals",
                "deleted_records",
                "sync_runs",
            )
        }

    assert result.status == "succeeded"
    assert counts == {
        "samples": 2,
        "workouts": 0,
        "sleep_sessions": 0,
        "sleep_stage_intervals": 0,
        "deleted_records": 3,
        "sync_runs": 2,
    }


def test_ingest_batch_does_not_regress_timestamp_sync_cursor_from_late_replay(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "cursor-regression.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    cursor_kind = "foreground_quantity_sync:heart_rate"
    newer_cursor = SyncCursor(
        source_key="synthetic.phone.alpha",
        cursor_kind=cursor_kind,
        cursor_value="2026-06-16T01:00:00Z",
    )
    older_cursor = newer_cursor.model_copy(
        update={"cursor_value": "2026-06-16T00:00:00Z"},
    )
    newer_batch = batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": (newer_cursor,)}),
        },
    )
    older_batch = newer_batch.model_copy(
        update={
            "sync": batch.sync.model_copy(update={"cursors": (older_cursor,)}),
        },
    )
    _ = ingest_batch(db_path, newer_batch, "newer-final-cursor-chunk")

    # When
    result = ingest_batch(db_path, older_batch, "late-older-cursor-replay")

    # Then
    with sqlite3.connect(db_path) as connection:
        row = CURSOR_VALUE_ADAPTER.validate_python(
            connection.execute(
                """
                select sync_cursors.cursor_value
                from sync_cursors
                join sources on sources.source_id = sync_cursors.source_id
                where sources.source_key = ? and sync_cursors.cursor_kind = ?
                """,
                ("synthetic.phone.alpha", cursor_kind),
            ).fetchone(),
        )
        sync_runs_count = fetch_count(connection, "sync_runs")

    assert result.status == "succeeded"
    assert sync_runs_count == 2
    assert row == ("2026-06-16T01:00:00Z",)


def test_ingest_batch_accepts_equal_and_newer_timestamp_sync_cursors(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "cursor-forward.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    cursor_kind = "foreground_quantity_sync:heart_rate"
    base_cursor = SyncCursor(
        source_key="synthetic.phone.alpha",
        cursor_kind=cursor_kind,
        cursor_value="2026-06-16T01:00:00Z",
    )
    equal_cursor = base_cursor.model_copy()
    newer_cursor = base_cursor.model_copy(
        update={"cursor_value": "2026-06-16T02:00:00Z"},
    )
    base_batch = _cursor_only_batch(batch, base_cursor)
    equal_batch = _cursor_only_batch(batch, equal_cursor)
    newer_batch = _cursor_only_batch(batch, newer_cursor)

    # When
    _ = ingest_batch(db_path, base_batch, "base-timestamp-cursor")
    equal_result = ingest_batch(db_path, equal_batch, "equal-timestamp-cursor")
    newer_result = ingest_batch(db_path, newer_batch, "newer-timestamp-cursor")

    # Then
    assert equal_result.status == "succeeded"
    assert newer_result.status == "succeeded"
    assert _stored_cursor_value(db_path, "synthetic.phone.alpha", cursor_kind) == (
        "2026-06-16T02:00:00Z",
    )


def test_ingest_batch_keeps_opaque_sync_cursors_last_write_wins(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "opaque-cursor.sqlite"
    initialize_database(db_path)
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    cursor_kind = "anchored_object_query"
    first_cursor = SyncCursor(
        source_key="synthetic.phone.alpha",
        cursor_kind=cursor_kind,
        cursor_value="opaque-anchor-2",
    )
    later_cursor = first_cursor.model_copy(
        update={"cursor_value": "opaque-anchor-1"},
    )

    # When
    _ = ingest_batch(db_path, _cursor_only_batch(batch, first_cursor), "first-opaque")
    result = ingest_batch(
        db_path, _cursor_only_batch(batch, later_cursor), "later-opaque"
    )

    # Then
    assert result.status == "succeeded"
    assert _stored_cursor_value(db_path, "synthetic.phone.alpha", cursor_kind) == (
        "opaque-anchor-1",
    )


def test_ingest_batch_canonicalizes_legacy_active_energy_samples_and_cursors(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "active-energy-canonical.sqlite"
    initialize_database(db_path)
    window = TimeWindow(
        start_time="2026-06-16T00:00:00Z",
        end_time="2026-06-16T01:00:00Z",
    )
    batch = HealthBridgeBatchV1(
        schema_id="health_bridge.batch.v1",
        schema_version="1.0.0",
        generated_at="2026-06-16T01:00:00Z",
        export_window=window,
        sources=(
            Source(
                source_key="apple_health.phone",
                name="Synthetic Phone",
                kind="phone",
                bundle_id="dev.example.HealthBridgeCompanion",
                device_model="SyntheticPhone",
            ),
        ),
        health_types=(
            HealthType(
                type_code="active_energy",
                display_name="Active Energy",
                category="activity",
                default_unit="kcal",
                sensitivity="moderate",
                aliases=("HKQuantityTypeIdentifierActiveEnergyBurned",),
            ),
        ),
        samples=(
            Sample(
                client_record_id="hk-quantity-active-energy-abc123",
                source_key="apple_health.phone",
                type_code="active_energy",
                start_time="2026-06-16T00:10:00Z",
                end_time="2026-06-16T00:15:00Z",
                value=42.0,
                unit="kcal",
            ),
        ),
        workouts=(),
        sleep_sessions=(),
        deleted_records=(),
        sync=SyncContext(
            sync_window=window,
            cursors=(
                SyncCursor(
                    source_key="apple_health.phone",
                    cursor_kind="foreground_quantity_sync:active_energy",
                    cursor_value="2026-06-16T01:00:00Z",
                ),
            ),
        ),
    )

    # When
    result = ingest_batch(db_path, batch, "legacy-active-energy")

    # Then
    with sqlite3.connect(db_path) as connection:
        sample_rows = connection.execute(
            """
            select type_code, client_record_id, value
            from samples
            order by sample_id
            """,
        ).fetchall()
        health_type_rows = connection.execute(
            "select type_code from health_types order by type_code",
        ).fetchall()
        alias_rows = connection.execute(
            "select type_code, alias from health_type_aliases order by alias",
        ).fetchall()

    assert result.status == "succeeded"
    assert sample_rows == [("energy", "hk-quantity-energy-abc123", 42.0)]
    assert health_type_rows == [("energy",)]
    assert ("energy", "active_energy") in alias_rows
    assert _stored_cursor_value(
        db_path,
        "apple_health.phone",
        "foreground_quantity_sync:energy",
    ) == ("2026-06-16T01:00:00Z",)
    assert (
        _stored_cursor_value(
            db_path,
            "apple_health.phone",
            "foreground_quantity_sync:active_energy",
        )
        is None
    )


@pytest.mark.parametrize(
    ("incoming_type_code", "incoming_client_record_id"),
    [
        ("active_energy", "hk-quantity-active-energy-abc123"),
        ("energy", "hk-quantity-energy-abc123"),
    ],
)
def test_ingest_batch_promotes_existing_legacy_active_energy_sample_without_duplicate(
    tmp_path: Path,
    incoming_type_code: str,
    incoming_client_record_id: str,
) -> None:
    # Given
    db_path = tmp_path / "active-energy-sample-migration.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source_cursor = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                "apple_health.phone",
                "Synthetic Phone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "SyntheticPhone",
            ),
        )
        _ = connection.execute(
            """
            insert into health_types (
                type_code, display_name, category, default_unit, sensitivity
            )
            values (?, ?, ?, ?, ?)
            """,
            ("active_energy", "Active Energy", "activity", "kcal", "moderate"),
        )
        _ = connection.execute(
            """
            insert into samples (
                source_id, type_code, client_record_id, start_time, end_time,
                value, unit, metadata_json
            )
            values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source_cursor.lastrowid,
                "active_energy",
                "hk-quantity-active-energy-abc123",
                "2026-06-16T00:10:00Z",
                "2026-06-16T00:15:00Z",
                21.0,
                "kcal",
                "{}",
            ),
        )
    window = TimeWindow(
        start_time="2026-06-16T00:00:00Z",
        end_time="2026-06-16T01:00:00Z",
    )
    batch = HealthBridgeBatchV1(
        schema_id="health_bridge.batch.v1",
        schema_version="1.0.0",
        generated_at="2026-06-16T01:00:00Z",
        export_window=window,
        sources=(
            Source(
                source_key="apple_health.phone",
                name="Synthetic Phone",
                kind="phone",
                bundle_id="dev.example.HealthBridgeCompanion",
                device_model="SyntheticPhone",
            ),
        ),
        health_types=(
            HealthType(
                type_code=incoming_type_code,
                display_name="Active Energy",
                category="activity",
                default_unit="kcal",
                sensitivity="moderate",
                aliases=("HKQuantityTypeIdentifierActiveEnergyBurned",),
            ),
        ),
        samples=(
            Sample(
                client_record_id=incoming_client_record_id,
                source_key="apple_health.phone",
                type_code=incoming_type_code,
                start_time="2026-06-16T00:10:00Z",
                end_time="2026-06-16T00:15:00Z",
                value=42.0,
                unit="kcal",
            ),
        ),
        workouts=(),
        sleep_sessions=(),
        deleted_records=(),
        sync=SyncContext(sync_window=window, cursors=()),
    )

    # When
    result = ingest_batch(db_path, batch, "legacy-active-energy-sample")

    # Then
    with sqlite3.connect(db_path) as connection:
        sample_rows = connection.execute(
            """
            select type_code, client_record_id, value
            from samples
            order by sample_id
            """,
        ).fetchall()
    assert result.status == "succeeded"
    assert sample_rows == [("energy", "hk-quantity-energy-abc123", 42.0)]


def test_ingest_batch_skips_active_energy_replay_after_legacy_tombstone(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "active-energy-legacy-tombstone-replay.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source_cursor = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                "apple_health.phone",
                "Synthetic Phone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "SyntheticPhone",
            ),
        )
        _ = connection.execute(
            """
            insert into deleted_records (
                source_id, record_family, client_record_id, deleted_at
            )
            values (?, ?, ?, ?)
            """,
            (
                source_cursor.lastrowid,
                "sample",
                "hk-quantity-active-energy-abc123",
                "2026-06-16T00:20:00Z",
            ),
        )
    window = TimeWindow(
        start_time="2026-06-16T00:00:00Z",
        end_time="2026-06-16T01:00:00Z",
    )
    batch = HealthBridgeBatchV1(
        schema_id="health_bridge.batch.v1",
        schema_version="1.0.0",
        generated_at="2026-06-16T01:00:00Z",
        export_window=window,
        sources=(
            Source(
                source_key="apple_health.phone",
                name="Synthetic Phone",
                kind="phone",
                bundle_id="dev.example.HealthBridgeCompanion",
                device_model="SyntheticPhone",
            ),
        ),
        health_types=(
            HealthType(
                type_code="active_energy",
                display_name="Active Energy",
                category="activity",
                default_unit="kcal",
                sensitivity="moderate",
                aliases=(),
            ),
        ),
        samples=(
            Sample(
                client_record_id="hk-quantity-active-energy-abc123",
                source_key="apple_health.phone",
                type_code="active_energy",
                start_time="2026-06-16T00:10:00Z",
                end_time="2026-06-16T00:15:00Z",
                value=42.0,
                unit="kcal",
            ),
        ),
        workouts=(),
        sleep_sessions=(),
        deleted_records=(),
        sync=SyncContext(sync_window=window, cursors=()),
    )

    # When
    result = ingest_batch(db_path, batch, "legacy-active-energy-late-replay")

    # Then
    with sqlite3.connect(db_path) as connection:
        sample_count = fetch_count(connection, "samples")
    assert result.status == "succeeded"
    assert sample_count == 0


def test_ingest_batch_removes_existing_legacy_sample_after_canonical_tombstone(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "active-energy-canonical-tombstone-legacy-row.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source_cursor = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                "apple_health.phone",
                "Synthetic Phone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "SyntheticPhone",
            ),
        )
        source_id = source_cursor.lastrowid
        _ = connection.execute(
            """
            insert into health_types (
                type_code, display_name, category, default_unit, sensitivity
            )
            values (?, ?, ?, ?, ?)
            """,
            ("active_energy", "Active Energy", "activity", "kcal", "moderate"),
        )
        _ = connection.execute(
            """
            insert into samples (
                source_id, type_code, client_record_id, start_time, end_time,
                value, unit, metadata_json
            )
            values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source_id,
                "active_energy",
                "hk-quantity-active-energy-abc123",
                "2026-06-16T00:10:00Z",
                "2026-06-16T00:15:00Z",
                21.0,
                "kcal",
                "{}",
            ),
        )
        _ = connection.execute(
            """
            insert into deleted_records (
                source_id, record_family, client_record_id, deleted_at
            )
            values (?, ?, ?, ?)
            """,
            (
                source_id,
                "sample",
                "hk-quantity-energy-abc123",
                "2026-06-16T00:20:00Z",
            ),
        )
    window = TimeWindow(
        start_time="2026-06-16T00:00:00Z",
        end_time="2026-06-16T01:00:00Z",
    )
    batch = HealthBridgeBatchV1(
        schema_id="health_bridge.batch.v1",
        schema_version="1.0.0",
        generated_at="2026-06-16T01:00:00Z",
        export_window=window,
        sources=(
            Source(
                source_key="apple_health.phone",
                name="Synthetic Phone",
                kind="phone",
                bundle_id="dev.example.HealthBridgeCompanion",
                device_model="SyntheticPhone",
            ),
        ),
        health_types=(
            HealthType(
                type_code="active_energy",
                display_name="Active Energy",
                category="activity",
                default_unit="kcal",
                sensitivity="moderate",
                aliases=(),
            ),
        ),
        samples=(
            Sample(
                client_record_id="hk-quantity-active-energy-abc123",
                source_key="apple_health.phone",
                type_code="active_energy",
                start_time="2026-06-16T00:10:00Z",
                end_time="2026-06-16T00:15:00Z",
                value=42.0,
                unit="kcal",
            ),
        ),
        workouts=(),
        sleep_sessions=(),
        deleted_records=(),
        sync=SyncContext(sync_window=window, cursors=()),
    )

    # When
    result = ingest_batch(db_path, batch, "legacy-active-energy-after-delete")

    # Then
    with sqlite3.connect(db_path) as connection:
        sample_count = fetch_count(connection, "samples")
    assert result.status == "succeeded"
    assert sample_count == 0


def test_ingest_batch_deletes_legacy_active_energy_sample_from_canonical_tombstone(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "active-energy-legacy-delete.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source_cursor = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                "apple_health.phone",
                "Synthetic Phone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "SyntheticPhone",
            ),
        )
        _ = connection.execute(
            """
            insert into health_types (
                type_code, display_name, category, default_unit, sensitivity
            )
            values (?, ?, ?, ?, ?)
            """,
            ("active_energy", "Active Energy", "activity", "kcal", "moderate"),
        )
        _ = connection.execute(
            """
            insert into samples (
                source_id, type_code, client_record_id, start_time, end_time,
                value, unit, metadata_json
            )
            values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source_cursor.lastrowid,
                "active_energy",
                "hk-quantity-active-energy-abc123",
                "2026-06-16T00:10:00Z",
                "2026-06-16T00:15:00Z",
                21.0,
                "kcal",
                "{}",
            ),
        )
    window = TimeWindow(
        start_time="2026-06-16T00:00:00Z",
        end_time="2026-06-16T01:00:00Z",
    )
    batch = HealthBridgeBatchV1(
        schema_id="health_bridge.batch.v1",
        schema_version="1.0.0",
        generated_at="2026-06-16T01:00:00Z",
        export_window=window,
        sources=(
            Source(
                source_key="apple_health.phone",
                name="Synthetic Phone",
                kind="phone",
                bundle_id="dev.example.HealthBridgeCompanion",
                device_model="SyntheticPhone",
            ),
        ),
        health_types=(
            HealthType(
                type_code="active_energy",
                display_name="Active Energy",
                category="activity",
                default_unit="kcal",
                sensitivity="moderate",
                aliases=(),
            ),
        ),
        samples=(),
        workouts=(),
        sleep_sessions=(),
        deleted_records=(
            DeletedRecord(
                record_family="sample",
                source_key="apple_health.phone",
                client_record_id="hk-quantity-energy-abc123",
                deleted_at="2026-06-16T00:20:00Z",
            ),
        ),
        sync=SyncContext(sync_window=window, cursors=()),
    )

    # When
    result = ingest_batch(db_path, batch, "legacy-active-energy-delete")

    # Then
    with sqlite3.connect(db_path) as connection:
        sample_count = fetch_count(connection, "samples")
        tombstone_ids = connection.execute(
            "select client_record_id from deleted_records order by client_record_id",
        ).fetchall()
    assert result.status == "succeeded"
    assert sample_count == 0
    assert tombstone_ids == [("hk-quantity-energy-abc123",)]


def test_ingest_batch_promotes_newer_legacy_active_energy_cursor_to_canonical(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "active-energy-cursor-migration.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        cursor = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                "apple_health.phone",
                "Synthetic Phone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "SyntheticPhone",
            ),
        )
        _ = connection.execute(
            """
            insert into sync_cursors (source_id, cursor_kind, cursor_value)
            values (?, ?, ?)
            """,
            (
                cursor.lastrowid,
                "foreground_quantity_sync:active_energy",
                "2026-06-17T01:00:00Z",
            ),
        )
    window = TimeWindow(
        start_time="2026-06-16T00:00:00Z",
        end_time="2026-06-16T01:00:00Z",
    )
    batch = HealthBridgeBatchV1(
        schema_id="health_bridge.batch.v1",
        schema_version="1.0.0",
        generated_at="2026-06-16T01:00:00Z",
        export_window=window,
        sources=(
            Source(
                source_key="apple_health.phone",
                name="Synthetic Phone",
                kind="phone",
                bundle_id="dev.example.HealthBridgeCompanion",
                device_model="SyntheticPhone",
            ),
        ),
        health_types=(
            HealthType(
                type_code="active_energy",
                display_name="Active Energy",
                category="activity",
                default_unit="kcal",
                sensitivity="moderate",
                aliases=("HKQuantityTypeIdentifierActiveEnergyBurned",),
            ),
        ),
        samples=(),
        workouts=(),
        sleep_sessions=(),
        deleted_records=(),
        sync=SyncContext(
            sync_window=window,
            cursors=(
                SyncCursor(
                    source_key="apple_health.phone",
                    cursor_kind="foreground_quantity_sync:active_energy",
                    cursor_value="2026-06-16T01:00:00Z",
                ),
            ),
        ),
    )

    # When
    result = ingest_batch(db_path, batch, "legacy-active-energy-cursor")

    # Then
    assert result.status == "succeeded"
    assert _stored_cursor_value(
        db_path,
        "apple_health.phone",
        "foreground_quantity_sync:energy",
    ) == ("2026-06-17T01:00:00Z",)
    assert _stored_cursor_value(
        db_path,
        "apple_health.phone",
        "foreground_quantity_sync:active_energy",
    ) == ("2026-06-17T01:00:00Z",)


def _cursor_only_batch(
    batch: HealthBridgeBatchV1,
    cursor: SyncCursor,
) -> HealthBridgeBatchV1:
    return batch.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (),
            "deleted_records": (),
            "sync": batch.sync.model_copy(update={"cursors": (cursor,)}),
        },
    )


def _stored_cursor_value(
    db_path: Path,
    source_key: str,
    cursor_kind: str,
) -> tuple[str] | None:
    with sqlite3.connect(db_path) as connection:
        return CURSOR_VALUE_ADAPTER.validate_python(
            connection.execute(
                """
                select sync_cursors.cursor_value
                from sync_cursors
                join sources on sources.source_id = sync_cursors.source_id
                where sources.source_key = ? and sync_cursors.cursor_kind = ?
                """,
                (source_key, cursor_kind),
            ).fetchone(),
        )

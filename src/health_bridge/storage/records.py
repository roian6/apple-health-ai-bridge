import json
import sqlite3
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.storage.catalog import source_id, upsert_catalog
from health_bridge.storage.sleep import (
    plan_sleep_baseline_resets,
    upsert_sleep_sessions,
)
from health_bridge.storage.sync_state import upsert_sync_state
from health_bridge.storage.tombstones import record_is_tombstoned
from health_bridge.timeseries_catalog import (
    canonical_sample_client_record_id,
    canonical_sample_type_code,
    compatible_deleted_sample_client_record_ids,
)

SampleIDRow: TypeAlias = tuple[int]
SAMPLE_ID_ROW_ADAPTER: TypeAdapter[SampleIDRow | None] = TypeAdapter(
    SampleIDRow | None,
)
LEGACY_SAMPLE_TYPE_BY_CANONICAL: Final[dict[str, str]] = {
    "energy": "active_energy",
    "weight": "body_mass",
}

UPSERT_SAMPLE_SQL = (
    "insert into samples (source_id, type_code, client_record_id, start_time, "
    "end_time, value, unit, metadata_json) values (?, ?, ?, ?, ?, ?, ?, ?) "
    "on conflict(source_id, type_code, client_record_id) do update set "
    "start_time = excluded.start_time, end_time = excluded.end_time, "
    "value = excluded.value, unit = excluded.unit, "
    "metadata_json = excluded.metadata_json, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)
SELECT_SAMPLE_ID_SQL = (
    "select sample_id from samples "
    "where source_id = ? and type_code = ? and client_record_id = ?"
)
DELETE_SAMPLE_SQL = "delete from samples where sample_id = ?"
PROMOTE_SAMPLE_ALIAS_SQL = (
    "update samples set type_code = ?, client_record_id = ?, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
    "where sample_id = ?"
)
UPSERT_WORKOUT_SQL = (
    "insert into workouts (source_id, client_record_id, workout_type, start_time, "
    "end_time, duration_seconds, energy_kcal, distance_meters) "
    "values (?, ?, ?, ?, ?, ?, ?, ?) "
    "on conflict(source_id, client_record_id) do update set "
    "workout_type = excluded.workout_type, start_time = excluded.start_time, "
    "end_time = excluded.end_time, duration_seconds = excluded.duration_seconds, "
    "energy_kcal = excluded.energy_kcal, distance_meters = excluded.distance_meters, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)


def upsert_batch_records(
    connection: sqlite3.Connection,
    batch: HealthBridgeBatchV1,
) -> None:
    upsert_catalog(connection, batch)
    sleep_reset_plan = plan_sleep_baseline_resets(connection, batch)
    _upsert_samples(connection, batch)
    _upsert_workouts(connection, batch)
    upsert_sleep_sessions(connection, batch, sleep_reset_plan)
    upsert_sync_state(
        connection,
        batch,
        stale_sleep_reset_source_keys=sleep_reset_plan.stale_source_keys,
    )


def _upsert_samples(connection: sqlite3.Connection, batch: HealthBridgeBatchV1) -> None:
    for sample in batch.samples:
        canonical_type_code = canonical_sample_type_code(sample.type_code)
        canonical_client_record_id = canonical_sample_client_record_id(
            sample.type_code,
            sample.client_record_id,
        )
        current_source_id = source_id(connection, sample.source_key)
        if _sample_is_tombstoned(
            connection,
            source_id_value=current_source_id,
            canonical_client_record_id=canonical_client_record_id,
        ):
            _delete_sample_aliases(
                connection,
                source_id_value=current_source_id,
                canonical_client_record_id=canonical_client_record_id,
            )
            continue
        legacy_alias_key = _legacy_sample_alias_key(
            canonical_type_code,
            canonical_client_record_id,
        )
        if legacy_alias_key is not None:
            _promote_legacy_sample_alias(
                connection,
                source_id_value=current_source_id,
                legacy_key=legacy_alias_key,
                canonical_key=(canonical_type_code, canonical_client_record_id),
            )
        elif (
            canonical_type_code != sample.type_code
            or canonical_client_record_id != sample.client_record_id
        ):
            _promote_legacy_sample_alias(
                connection,
                source_id_value=current_source_id,
                legacy_key=(sample.type_code, sample.client_record_id),
                canonical_key=(canonical_type_code, canonical_client_record_id),
            )
        metadata_json = json.dumps(
            sample.metadata,
            sort_keys=True,
            separators=(",", ":"),
        )
        _ = connection.execute(
            UPSERT_SAMPLE_SQL,
            (
                current_source_id,
                canonical_type_code,
                canonical_client_record_id,
                sample.start_time,
                sample.end_time,
                sample.value,
                sample.unit,
                metadata_json,
            ),
        )


def _sample_is_tombstoned(
    connection: sqlite3.Connection,
    *,
    source_id_value: int,
    canonical_client_record_id: str,
) -> bool:
    return any(
        record_is_tombstoned(
            connection,
            source_id_value=source_id_value,
            record_family="sample",
            client_record_id=candidate_id,
        )
        for candidate_id in compatible_deleted_sample_client_record_ids(
            canonical_client_record_id,
        )
    )


def _legacy_sample_alias_key(
    canonical_type_code: str,
    canonical_client_record_id: str,
) -> tuple[str, str] | None:
    legacy_type_code = LEGACY_SAMPLE_TYPE_BY_CANONICAL.get(canonical_type_code)
    if legacy_type_code is None:
        return None
    compatible_ids = compatible_deleted_sample_client_record_ids(
        canonical_client_record_id,
    )
    legacy_candidate_index = 1
    if len(compatible_ids) <= legacy_candidate_index:
        return None
    return (legacy_type_code, compatible_ids[legacy_candidate_index])


def _delete_sample_aliases(
    connection: sqlite3.Connection,
    *,
    source_id_value: int,
    canonical_client_record_id: str,
) -> None:
    for candidate_id in compatible_deleted_sample_client_record_ids(
        canonical_client_record_id,
    ):
        _ = connection.execute(
            "delete from samples where source_id = ? and client_record_id = ?",
            (source_id_value, candidate_id),
        )


def _promote_legacy_sample_alias(
    connection: sqlite3.Connection,
    *,
    source_id_value: int,
    legacy_key: tuple[str, str],
    canonical_key: tuple[str, str],
) -> None:
    legacy_type_code, legacy_client_record_id = legacy_key
    canonical_type_code, canonical_client_record_id = canonical_key
    legacy_row = SAMPLE_ID_ROW_ADAPTER.validate_python(
        connection.execute(
            SELECT_SAMPLE_ID_SQL,
            (source_id_value, legacy_type_code, legacy_client_record_id),
        ).fetchone(),
    )
    if legacy_row is None:
        return
    canonical_row = SAMPLE_ID_ROW_ADAPTER.validate_python(
        connection.execute(
            SELECT_SAMPLE_ID_SQL,
            (source_id_value, canonical_type_code, canonical_client_record_id),
        ).fetchone(),
    )
    legacy_sample_id = int(legacy_row[0])
    if canonical_row is not None:
        _ = connection.execute(DELETE_SAMPLE_SQL, (legacy_sample_id,))
        return
    _ = connection.execute(
        PROMOTE_SAMPLE_ALIAS_SQL,
        (canonical_type_code, canonical_client_record_id, legacy_sample_id),
    )


def _upsert_workouts(
    connection: sqlite3.Connection,
    batch: HealthBridgeBatchV1,
) -> None:
    for workout in batch.workouts:
        current_source_id = source_id(connection, workout.source_key)
        if record_is_tombstoned(
            connection,
            source_id_value=current_source_id,
            record_family="workout",
            client_record_id=workout.client_record_id,
        ):
            continue
        _ = connection.execute(
            UPSERT_WORKOUT_SQL,
            (
                current_source_id,
                workout.client_record_id,
                workout.workout_type,
                workout.start_time,
                workout.end_time,
                workout.duration_seconds,
                workout.energy_kcal,
                workout.distance_meters,
            ),
        )

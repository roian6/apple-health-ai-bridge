import sqlite3
from pathlib import Path
from typing import ClassVar, Final, Literal, TypeAlias

from pydantic import BaseModel, ConfigDict, TypeAdapter

from health_bridge.storage.database import connect_database, initialize_database

DEFAULT_ANCHORED_STEP_SOURCE_KEY: Final = "apple_health.phone"
STEP_TYPE_CODE: Final = "steps"
ANCHORED_STEP_CURSOR_KIND: Final = "anchored_step_sync"
ANCHORED_STEP_BOOTSTRAP_CURSOR_KIND: Final = "anchored_step_bootstrap_start"
RAW_STEP_SAMPLE_ID_PREFIX: Final = "hk-step-sample-%"
LEGACY_DAILY_STEP_ID_PREFIX: Final = "hk-steps-%"
SOURCE_EXISTS_SQL: Final = "select count(*) from sources where source_key = ?"
RAW_STEP_SAMPLE_COUNT_SQL: Final = """
select count(*)
from samples
join sources on sources.source_id = samples.source_id
where sources.source_key = ?
  and samples.type_code = ?
  and samples.client_record_id like ?
"""
LEGACY_DAILY_STEP_SAMPLE_COUNT_SQL: Final = """
select count(*)
from samples
join sources on sources.source_id = samples.source_id
where sources.source_key = ?
  and samples.type_code = ?
  and samples.client_record_id like ?
"""
OVERLAPPING_LEGACY_DAILY_STEP_SAMPLE_COUNT_SQL: Final = """
select count(*)
from samples as legacy_samples
join sources on sources.source_id = legacy_samples.source_id
where sources.source_key = ?
  and legacy_samples.type_code = ?
  and legacy_samples.client_record_id like ?
  and exists (
    select 1
    from samples as raw_samples
    where raw_samples.source_id = legacy_samples.source_id
      and raw_samples.type_code = ?
      and raw_samples.client_record_id like ?
      and legacy_samples.client_record_id = 'hk-steps-' || strftime(
        '%Y%m%d',
        raw_samples.start_time
      )
  )
"""
STEP_TOMBSTONE_COUNT_SQL: Final = """
select count(*)
from deleted_records
join sources on sources.source_id = deleted_records.source_id
where sources.source_key = ?
  and deleted_records.record_family = 'sample'
  and deleted_records.client_record_id like ?
"""
CURSOR_EXISTS_SQL: Final = """
select count(*)
from sync_cursors
join sources on sources.source_id = sync_cursors.source_id
where sources.source_key = ?
  and sync_cursors.cursor_kind = ?
"""
LATEST_RAW_STEP_END_SQL: Final = """
select max(samples.end_time)
from samples
join sources on sources.source_id = samples.source_id
where sources.source_key = ?
  and samples.type_code = ?
  and samples.client_record_id like ?
"""
LATEST_STEP_TOMBSTONE_SQL: Final = """
select max(deleted_records.deleted_at)
from deleted_records
join sources on sources.source_id = deleted_records.source_id
where sources.source_key = ?
  and deleted_records.record_family = 'sample'
  and (
    deleted_records.client_record_id like ?
    or deleted_records.client_record_id like ?
  )
"""
IntRow: TypeAlias = tuple[int]
OptionalStringRow: TypeAlias = tuple[str | None]
INT_ROW_ADAPTER: Final[TypeAdapter[IntRow | None]] = TypeAdapter(IntRow | None)
OPTIONAL_STRING_ROW_ADAPTER: Final[TypeAdapter[OptionalStringRow | None]] = TypeAdapter(
    OptionalStringRow | None,
)


class AnchoredStepValidationSnapshot(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)

    schema_id: Literal["health_bridge.dev.anchored_step_validation.v1"] = (
        "health_bridge.dev.anchored_step_validation.v1"
    )
    source_key: str
    type_code: Literal["steps"] = STEP_TYPE_CODE
    raw_sample_count: int
    legacy_daily_sample_count: int
    sample_tombstone_count: int
    legacy_daily_tombstone_count: int
    has_anchor_cursor: bool
    has_bootstrap_cursor: bool
    latest_raw_sample_end: str | None
    latest_tombstone_deleted_at: str | None
    verdict: str
    missing_data_notes: tuple[str, ...]


def read_anchored_step_validation_snapshot(
    db_path: Path,
    *,
    source_key: str = DEFAULT_ANCHORED_STEP_SOURCE_KEY,
) -> AnchoredStepValidationSnapshot:
    initialize_database(db_path)
    with connect_database(db_path) as connection:
        source_exists = _fetch_int(connection, SOURCE_EXISTS_SQL, (source_key,)) > 0
        raw_sample_count = _fetch_int(
            connection,
            RAW_STEP_SAMPLE_COUNT_SQL,
            (source_key, STEP_TYPE_CODE, RAW_STEP_SAMPLE_ID_PREFIX),
        )
        legacy_daily_sample_count = _fetch_int(
            connection,
            LEGACY_DAILY_STEP_SAMPLE_COUNT_SQL,
            (source_key, STEP_TYPE_CODE, LEGACY_DAILY_STEP_ID_PREFIX),
        )
        overlapping_legacy_daily_sample_count = _fetch_int(
            connection,
            OVERLAPPING_LEGACY_DAILY_STEP_SAMPLE_COUNT_SQL,
            (
                source_key,
                STEP_TYPE_CODE,
                LEGACY_DAILY_STEP_ID_PREFIX,
                STEP_TYPE_CODE,
                RAW_STEP_SAMPLE_ID_PREFIX,
            ),
        )
        sample_tombstone_count = _fetch_int(
            connection,
            STEP_TOMBSTONE_COUNT_SQL,
            (source_key, RAW_STEP_SAMPLE_ID_PREFIX),
        )
        legacy_daily_tombstone_count = _fetch_int(
            connection,
            STEP_TOMBSTONE_COUNT_SQL,
            (source_key, LEGACY_DAILY_STEP_ID_PREFIX),
        )
        has_anchor_cursor = (
            _fetch_int(
                connection, CURSOR_EXISTS_SQL, (source_key, ANCHORED_STEP_CURSOR_KIND)
            )
            > 0
        )
        has_bootstrap_cursor = (
            _fetch_int(
                connection,
                CURSOR_EXISTS_SQL,
                (source_key, ANCHORED_STEP_BOOTSTRAP_CURSOR_KIND),
            )
            > 0
        )
        latest_raw_sample_end = _fetch_optional_string(
            connection,
            LATEST_RAW_STEP_END_SQL,
            (source_key, STEP_TYPE_CODE, RAW_STEP_SAMPLE_ID_PREFIX),
        )
        latest_tombstone_deleted_at = _fetch_optional_string(
            connection,
            LATEST_STEP_TOMBSTONE_SQL,
            (source_key, RAW_STEP_SAMPLE_ID_PREFIX, LEGACY_DAILY_STEP_ID_PREFIX),
        )

    notes = _validation_notes(
        source_exists=source_exists,
        raw_sample_count=raw_sample_count,
        overlapping_legacy_daily_sample_count=overlapping_legacy_daily_sample_count,
        has_anchor_cursor=has_anchor_cursor,
    )
    return AnchoredStepValidationSnapshot(
        source_key=source_key,
        raw_sample_count=raw_sample_count,
        legacy_daily_sample_count=legacy_daily_sample_count,
        sample_tombstone_count=sample_tombstone_count,
        legacy_daily_tombstone_count=legacy_daily_tombstone_count,
        has_anchor_cursor=has_anchor_cursor,
        has_bootstrap_cursor=has_bootstrap_cursor,
        latest_raw_sample_end=latest_raw_sample_end,
        latest_tombstone_deleted_at=latest_tombstone_deleted_at,
        verdict=_validation_verdict(
            source_exists=source_exists,
            raw_sample_count=raw_sample_count,
            overlapping_legacy_daily_sample_count=overlapping_legacy_daily_sample_count,
            has_anchor_cursor=has_anchor_cursor,
        ),
        missing_data_notes=notes,
    )


def anchored_step_validation_json(snapshot: AnchoredStepValidationSnapshot) -> str:
    return snapshot.model_dump_json()


def _validation_verdict(
    *,
    source_exists: bool,
    raw_sample_count: int,
    overlapping_legacy_daily_sample_count: int,
    has_anchor_cursor: bool,
) -> str:
    if not source_exists:
        return "no_step_source"
    if not has_anchor_cursor:
        return "missing_anchor_cursor"
    if raw_sample_count == 0:
        return "no_raw_samples"
    if overlapping_legacy_daily_sample_count > 0:
        return "legacy_daily_coexists"
    return "validated"


def _validation_notes(
    *,
    source_exists: bool,
    raw_sample_count: int,
    overlapping_legacy_daily_sample_count: int,
    has_anchor_cursor: bool,
) -> tuple[str, ...]:
    notes: list[str] = []
    if not source_exists:
        notes.append("No apple_health.phone source has been stored yet.")
    if not has_anchor_cursor:
        notes.append("No anchored Step Count cursor has been stored yet.")
    if raw_sample_count == 0:
        notes.append("No anchored raw Step Count samples have been stored yet.")
    if overlapping_legacy_daily_sample_count > 0:
        notes.append(
            "Legacy daily Step Count rows still coexist with anchored raw samples."
        )
    return tuple(notes)


def _fetch_int(
    connection: sqlite3.Connection,
    sql: str,
    parameters: tuple[object, ...] = (),
) -> int:
    row = INT_ROW_ADAPTER.validate_python(
        connection.execute(sql, parameters).fetchone()
    )
    return 0 if row is None else row[0]


def _fetch_optional_string(
    connection: sqlite3.Connection,
    sql: str,
    parameters: tuple[object, ...],
) -> str | None:
    row = OPTIONAL_STRING_ROW_ADAPTER.validate_python(
        connection.execute(sql, parameters).fetchone(),
    )
    return None if row is None else row[0]

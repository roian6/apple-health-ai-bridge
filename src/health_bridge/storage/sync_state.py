import re
import sqlite3
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.storage.catalog import source_id
from health_bridge.storage.tombstones import delete_active_record, upsert_deleted_record
from health_bridge.timeseries_catalog import (
    canonical_deleted_sample_client_record_id,
    canonical_sync_cursor_kind,
    compatible_deleted_sample_client_record_ids,
)

CursorValueRow: TypeAlias = tuple[str] | None
CURSOR_VALUE_ROW_ADAPTER: Final[TypeAdapter[CursorValueRow]] = TypeAdapter(
    CursorValueRow,
)
UTC_TIMESTAMP_RE: Final = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
UPSERT_CURSOR_SQL = (
    "insert into sync_cursors (source_id, cursor_kind, cursor_value) "
    "values (?, ?, ?) on conflict(source_id, cursor_kind) do update set "
    "cursor_value = excluded.cursor_value, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)
SELECT_CURSOR_VALUE_SQL: Final = (
    "select cursor_value from sync_cursors where source_id = ? and cursor_kind = ?"
)
LEGACY_CURSOR_KIND_COMPATIBILITY: Final[dict[str, tuple[str, ...]]] = {
    "foreground_quantity_sync:energy": ("foreground_quantity_sync:active_energy",),
    "foreground_quantity_sync:weight": ("foreground_quantity_sync:body_mass",),
}
SLEEP_CURSOR_KINDS: Final = frozenset(
    {
        "foreground_sleep_sync",
        "anchored_sleep_sync",
        "anchored_sleep_baseline_reset",
    }
)


def upsert_sync_state(
    connection: sqlite3.Connection,
    batch: HealthBridgeBatchV1,
    *,
    stale_sleep_reset_source_keys: frozenset[str],
) -> None:
    for deleted_record in batch.deleted_records:
        if (
            deleted_record.record_family == "sleep_session"
            and deleted_record.source_key in stale_sleep_reset_source_keys
        ):
            continue
        deleted_source_id = source_id(connection, deleted_record.source_key)
        if deleted_record.record_family == "sample":
            client_record_id = canonical_deleted_sample_client_record_id(
                deleted_record.client_record_id,
            )
            active_record_ids = compatible_deleted_sample_client_record_ids(
                client_record_id,
            )
        else:
            client_record_id = deleted_record.client_record_id
            active_record_ids = (client_record_id,)
        for active_record_id in active_record_ids:
            delete_active_record(
                connection,
                source_id_value=deleted_source_id,
                record_family=deleted_record.record_family,
                client_record_id=active_record_id,
            )
        upsert_deleted_record(
            connection,
            source_id_value=deleted_source_id,
            record_family=deleted_record.record_family,
            client_record_id=client_record_id,
            deleted_at=deleted_record.deleted_at,
        )
    for cursor in batch.sync.cursors:
        if (
            cursor.source_key in stale_sleep_reset_source_keys
            and cursor.cursor_kind in SLEEP_CURSOR_KINDS
        ):
            continue
        source_id_value = source_id(connection, cursor.source_key)
        cursor_kind = canonical_sync_cursor_kind(cursor.cursor_kind)
        cursor_value = _effective_cursor_value(
            connection,
            source_id_value=source_id_value,
            cursor_kind=cursor_kind,
            incoming_cursor_value=cursor.cursor_value,
        )
        if not _should_upsert_cursor(
            connection,
            source_id_value=source_id_value,
            cursor_kind=cursor_kind,
            cursor_value=cursor_value,
        ):
            continue
        _ = connection.execute(
            UPSERT_CURSOR_SQL,
            (
                source_id_value,
                cursor_kind,
                cursor_value,
            ),
        )


def _effective_cursor_value(
    connection: sqlite3.Connection,
    *,
    source_id_value: int,
    cursor_kind: str,
    incoming_cursor_value: str,
) -> str:
    """Preserve newer legacy cursor progress when writing canonical cursor rows."""
    compatible_values = [incoming_cursor_value]
    for legacy_cursor_kind in LEGACY_CURSOR_KIND_COMPATIBILITY.get(cursor_kind, ()):
        legacy_row = CURSOR_VALUE_ROW_ADAPTER.validate_python(
            connection.execute(
                SELECT_CURSOR_VALUE_SQL,
                (source_id_value, legacy_cursor_kind),
            ).fetchone(),
        )
        if legacy_row is not None:
            compatible_values.append(legacy_row[0])
    utc_values = [value for value in compatible_values if _is_utc_timestamp(value)]
    if len(utc_values) == len(compatible_values):
        return max(utc_values)
    return incoming_cursor_value


def _should_upsert_cursor(
    connection: sqlite3.Connection,
    *,
    source_id_value: int,
    cursor_kind: str,
    cursor_value: str,
) -> bool:
    existing_row = CURSOR_VALUE_ROW_ADAPTER.validate_python(
        connection.execute(
            SELECT_CURSOR_VALUE_SQL,
            (source_id_value, cursor_kind),
        ).fetchone(),
    )
    if existing_row is None:
        return True
    existing_cursor_value = existing_row[0]
    if _is_utc_timestamp(existing_cursor_value) and _is_utc_timestamp(cursor_value):
        return cursor_value >= existing_cursor_value
    return True


def _is_utc_timestamp(value: str) -> bool:
    return UTC_TIMESTAMP_RE.fullmatch(value) is not None

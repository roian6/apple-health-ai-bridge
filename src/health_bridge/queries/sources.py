import sqlite3
from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.queries._common import (
    connect_readonly,
    fetch_all_sources,
    fetch_store_period,
    notes_for_count,
)
from health_bridge.queries.models import SourceDetail, SourcesResult, SyncCursorDetail

SourceDetailRow: TypeAlias = tuple[str, str, str, str | None, str | None]
SyncCursorRow: TypeAlias = tuple[str, str, str]
SOURCE_DETAIL_ROWS_ADAPTER: Final[TypeAdapter[list[SourceDetailRow]]] = TypeAdapter(
    list[SourceDetailRow],
)
SYNC_CURSOR_ROWS_ADAPTER: Final[TypeAdapter[list[SyncCursorRow]]] = TypeAdapter(
    list[SyncCursorRow],
)

SOURCES_SQL: Final = (
    "select source_key, name, kind, bundle_id, device_model "
    "from sources order by source_key"
)
SYNC_CURSORS_SQL: Final = (
    "select sources.source_key, sync_cursors.cursor_kind, sync_cursors.updated_at "
    "from sync_cursors join sources on sources.source_id = sync_cursors.source_id "
    "where sync_cursors.cursor_kind not like 'daily_projection_%' "
    "order by sources.source_key, sync_cursors.cursor_kind"
)


def connection_has_observations(
    connection: sqlite3.Connection, installation_id_hash: str
) -> bool:
    """Require a confirmed health-data upload and observations still stored."""
    # Receiver invitations import this query; defer receiver package initialization.
    from health_bridge.receiver.source_binding import (  # noqa: PLC0415
        PHONE_SOURCE_PREFIX,
    )

    return (
        connection.execute(
            """
        select 1 from sources
        where source_key = ? and exists (
            select 1 from sync_runs where receiver_installation_id_hash = ?
                and status = 'succeeded'
                and (sample_count > 0 or workout_count > 0 or sleep_session_count > 0)
        ) and (
            exists (select 1 from samples where samples.source_id = sources.source_id)
            or exists (select 1 from workouts
                where workouts.source_id = sources.source_id)
            or exists (select 1 from sleep_sessions
                where sleep_sessions.source_id = sources.source_id)
        ) limit 1
        """,
            (PHONE_SOURCE_PREFIX + installation_id_hash, installation_id_hash),
        ).fetchone()
        is not None
    )


def explain_sources(db_path: Path) -> SourcesResult:
    with connect_readonly(db_path) as connection:
        source_rows = SOURCE_DETAIL_ROWS_ADAPTER.validate_python(
            connection.execute(SOURCES_SQL).fetchall(),
        )
        cursor_rows = SYNC_CURSOR_ROWS_ADAPTER.validate_python(
            connection.execute(SYNC_CURSORS_SQL).fetchall(),
        )
        sources_used = fetch_all_sources(connection)
        period = fetch_store_period(connection)
    sources = tuple(_source_from_row(row) for row in source_rows)
    sync_cursors = tuple(_cursor_from_row(row) for row in cursor_rows)
    return SourcesResult(
        period=period,
        sources=sources,
        sync_cursors=sync_cursors,
        sources_used=sources_used,
        missing_data_notes=notes_for_count(len(sources)),
        truncated=False,
    )


def _source_from_row(row: SourceDetailRow) -> SourceDetail:
    source_key, name, kind, bundle_id, device_model = row
    return SourceDetail(
        source_key=source_key,
        name=name,
        kind=kind,
        bundle_id=bundle_id,
        device_model=device_model,
    )


def _cursor_from_row(row: SyncCursorRow) -> SyncCursorDetail:
    source_key, cursor_kind, updated_at = row
    return SyncCursorDetail(
        source_key=source_key,
        cursor_kind=cursor_kind,
        updated_at=updated_at,
    )

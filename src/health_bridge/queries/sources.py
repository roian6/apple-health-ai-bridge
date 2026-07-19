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
    "order by sources.source_key, sync_cursors.cursor_kind"
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

import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar, Final, TypeAlias

from pydantic import BaseModel, ConfigDict, TypeAdapter

from health_bridge.storage.database import connect_readonly_database
from health_bridge.storage.sqlite_rows import fetch_one_int, fetch_optional_sync_status

SOURCE_COUNT_SQL: Final = "select count(*) from sources"
HEALTH_TYPE_COUNT_SQL: Final = "select count(*) from health_types"
SAMPLE_COUNT_SQL: Final = "select count(*) from samples"
WORKOUT_COUNT_SQL: Final = "select count(*) from workouts"
SLEEP_SESSION_COUNT_SQL: Final = "select count(*) from sleep_sessions"
DELETED_RECORD_COUNT_SQL: Final = "select count(*) from deleted_records"
SYNC_CURSOR_COUNT_SQL: Final = "select count(*) from sync_cursors"
SYNC_RUN_COUNT_SQL: Final = "select count(*) from sync_runs"
LAST_SYNC_STATUS_SQL: Final = (
    "select status, error_summary from sync_runs order by sync_run_id desc limit 1"
)
LATEST_SYNC_SQL: Final = """
select sync_run_id, started_at, finished_at, status,
       sample_count, workout_count, sleep_session_count,
       deleted_record_count, sync_cursor_count, error_summary,
       sync_window_start, sync_window_end
from sync_runs
order by sync_run_id desc
limit 1
"""
METRIC_STATUS_SQL: Final = """
with metric_catalog as (
    select type_code, display_name, category, default_unit, sensitivity
    from health_types
    union all
    select 'workout', 'Workouts', 'activity', 'session', 'moderate'
    where exists (select 1 from workouts)
      and not exists (select 1 from health_types where type_code = 'workout')
    union all
    select 'sleep_analysis', 'Sleep Analysis', 'sleep', 'stage', 'moderate'
    where exists (select 1 from sleep_sessions)
      and not exists (
          select 1 from health_types where type_code = 'sleep_analysis'
      )
)
select ht.type_code, ht.display_name, ht.category, ht.default_unit,
       ht.sensitivity,
       case
           when ht.type_code = 'workout'
           then coalesce(workout_counts.workout_count, 0)
           when ht.type_code = 'sleep_analysis'
           then coalesce(sleep_counts.sleep_count, 0)
           else coalesce(sample_counts.sample_count, 0)
       end as record_count,
       case
           when ht.type_code = 'workout'
           then workout_counts.first_record_start
           when ht.type_code = 'sleep_analysis'
           then sleep_counts.first_record_start
           else sample_counts.first_record_start
       end as first_record_start,
       case
           when ht.type_code = 'workout'
           then workout_counts.latest_record_end
           when ht.type_code = 'sleep_analysis'
           then sleep_counts.latest_record_end
           else sample_counts.latest_record_end
       end as latest_record_end,
       coalesce(cursor_counts.cursor_count, 0) as cursor_count,
       cursor_counts.latest_cursor_updated_at
from metric_catalog ht
left join (
    select type_code, count(*) as sample_count,
           min(start_time) as first_record_start,
           max(end_time) as latest_record_end
    from samples
    group by type_code
) sample_counts on sample_counts.type_code = ht.type_code
left join (
    select count(*) as workout_count,
           min(start_time) as first_record_start,
           max(end_time) as latest_record_end
    from workouts
) workout_counts
left join (
    select count(*) as sleep_count,
           min(start_time) as first_record_start,
           max(end_time) as latest_record_end
    from sleep_sessions
) sleep_counts
left join (
    select canonical_cursor_kind as cursor_kind,
           count(*) as cursor_count,
           max(latest_cursor_updated_at) as latest_cursor_updated_at
    from (
        select sync_cursors.source_id,
               case sync_cursors.cursor_kind
                   when 'foreground_quantity_sync:active_energy'
                   then 'foreground_quantity_sync:energy'
                   when 'foreground_quantity_sync:body_mass'
                   then 'foreground_quantity_sync:weight'
                   else sync_cursors.cursor_kind
               end as canonical_cursor_kind,
               max(sync_cursors.updated_at) as latest_cursor_updated_at
        from sync_cursors
        group by sync_cursors.source_id, canonical_cursor_kind
    ) canonical_cursors
    group by canonical_cursor_kind
) cursor_counts on cursor_counts.cursor_kind = case
    when ht.type_code = 'workout' then 'foreground_workout_sync'
    when ht.type_code = 'sleep_analysis' then 'foreground_sleep_sync'
    else 'foreground_quantity_sync:' || ht.type_code
end
order by ht.type_code
"""
SYNC_CURSOR_STATUS_SQL: Final = """
select sources.source_key, sync_cursors.cursor_kind, sync_cursors.updated_at
from sync_cursors
join sources on sources.source_id = sync_cursors.source_id
order by sync_cursors.updated_at desc, sources.source_key, sync_cursors.cursor_kind
"""
RECEIVER_STATUS_SQL: Final = """
select coalesce(sum(case when revoked_at is null then 1 else 0 end), 0),
       coalesce(sum(case when revoked_at is not null then 1 else 0 end), 0),
       count(*),
       max(last_used_at)
from receiver_tokens
"""

LatestSyncRow: TypeAlias = tuple[
    int,
    str,
    str,
    str,
    int,
    int,
    int,
    int,
    int,
    str | None,
    str | None,
    str | None,
]
MetricStatusRow: TypeAlias = tuple[
    str,
    str,
    str,
    str,
    str,
    int,
    str | None,
    str | None,
    int,
    str | None,
]
SyncCursorStatusRow: TypeAlias = tuple[str, str, str]
ReceiverStatusRow: TypeAlias = tuple[int, int, int, str | None]

LATEST_SYNC_ROW_ADAPTER: Final[TypeAdapter[LatestSyncRow | None]] = TypeAdapter(
    LatestSyncRow | None,
)
METRIC_STATUS_ROWS_ADAPTER: Final[TypeAdapter[list[MetricStatusRow]]] = TypeAdapter(
    list[MetricStatusRow],
)
SYNC_CURSOR_STATUS_ROWS_ADAPTER: Final[TypeAdapter[list[SyncCursorStatusRow]]] = (
    TypeAdapter(list[SyncCursorStatusRow])
)
RECEIVER_STATUS_ROW_ADAPTER: Final[TypeAdapter[ReceiverStatusRow | None]] = TypeAdapter(
    ReceiverStatusRow | None,
)


class StatusModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class LatestSyncStatus(StatusModel):
    sync_run_id: int
    started_at: str
    finished_at: str
    status: str
    sample_count: int
    workout_count: int
    sleep_session_count: int
    deleted_record_count: int
    sync_cursor_count: int
    error_summary: str | None
    sync_window_start: str | None
    sync_window_end: str | None


class ReceiverStatus(StatusModel):
    has_active_token: bool
    active_token_count: int
    revoked_token_count: int
    total_token_count: int
    latest_token_last_used_at: str | None


class MetricStatus(StatusModel):
    display_name: str
    category: str
    default_unit: str
    sensitivity: str
    record_count: int
    first_record_start: str | None
    latest_record_end: str | None
    cursor_count: int
    latest_cursor_updated_at: str | None


class SyncCursorStatus(StatusModel):
    source_key: str
    cursor_kind: str
    updated_at: str


class BridgeStatusSnapshot(StatusModel):
    schema_id: str = "health_bridge.status.v1"
    counts: dict[str, int]
    latest_sync: LatestSyncStatus | None
    receiver: ReceiverStatus
    metrics: dict[str, MetricStatus]
    sync_cursors: tuple[SyncCursorStatus, ...]
    missing_data_notes: tuple[str, ...]
    truncated: bool


def read_status_markdown(db_path: Path) -> str:
    return render_status_markdown(read_status_snapshot(db_path))


def render_status_markdown(snapshot: BridgeStatusSnapshot) -> str:
    lines = [
        "# Health Bridge Context",
        "",
        "This local-first bridge status is redacted for agent/wiki context.",
        "",
        "## Store Counts",
    ]
    lines.extend(f"- {name}: {count}" for name, count in snapshot.counts.items())
    lines.extend(["", "## Latest Sync"])
    if snapshot.latest_sync is None:
        lines.append("- status: none")
    else:
        latest = snapshot.latest_sync
        lines.extend(
            [
                f"- sync_run_id: {latest.sync_run_id}",
                f"- status: {latest.status}",
                f"- started_at: {latest.started_at}",
                f"- finished_at: {latest.finished_at}",
                f"- samples: {latest.sample_count}",
                f"- workouts: {latest.workout_count}",
                f"- sleep_sessions: {latest.sleep_session_count}",
                f"- deleted_records: {latest.deleted_record_count}",
                f"- sync_cursors: {latest.sync_cursor_count}",
            ]
        )
        if latest.error_summary is not None:
            lines.append(f"- error_summary: {latest.error_summary}")
    lines.extend(["", "## Receiver"])
    lines.extend(
        [
            f"- has_active_token: {snapshot.receiver.has_active_token}",
            f"- active_token_count: {snapshot.receiver.active_token_count}",
            f"- revoked_token_count: {snapshot.receiver.revoked_token_count}",
        ]
    )
    lines.extend(["", "## Synced Metrics"])
    if not snapshot.metrics:
        lines.append("- none")
    else:
        for type_code, metric in snapshot.metrics.items():
            latest_cursor_updated_at = metric.latest_cursor_updated_at or "none"
            lines.extend(
                [
                    f"- {type_code}",
                    f"  - display_name: {metric.display_name}",
                    f"  - category: {metric.category}",
                    f"  - sensitivity: {metric.sensitivity}",
                    f"  - record_count: {metric.record_count}",
                    f"  - first_record_start: {metric.first_record_start or 'none'}",
                    f"  - latest_record_end: {metric.latest_record_end or 'none'}",
                    f"  - cursor_count: {metric.cursor_count}",
                    f"  - latest_cursor_updated_at: {latest_cursor_updated_at}",
                ]
            )
    lines.extend(["", "## Cursor Freshness"])
    if not snapshot.sync_cursors:
        lines.append("- none")
    else:
        lines.extend(_cursor_freshness_line(cursor) for cursor in snapshot.sync_cursors)
    lines.extend(["", "## Redaction Notes"])
    lines.extend(f"- {note}" for note in snapshot.missing_data_notes)
    return "\n".join(lines) + "\n"


def _cursor_freshness_line(cursor: SyncCursorStatus) -> str:
    return (
        f"- {cursor.source_key} / {cursor.cursor_kind}: updated_at={cursor.updated_at}"
    )


@dataclass(frozen=True, slots=True)
class BridgeStatus:
    counts: dict[str, int]
    last_sync_status: str | None
    last_sync_error: str | None


def read_status(db_path: Path) -> BridgeStatus:
    with connect_readonly_database(db_path) as connection:
        counts = _read_counts(connection)
        row = fetch_optional_sync_status(
            connection,
            LAST_SYNC_STATUS_SQL,
        )

    return BridgeStatus(
        counts=counts,
        last_sync_status=None if row is None else str(row[0]),
        last_sync_error=None if row is None else row[1],
    )


def read_status_snapshot(db_path: Path) -> BridgeStatusSnapshot:
    with connect_readonly_database(db_path) as connection:
        counts = _read_counts(connection)
        latest_sync = _read_latest_sync(connection)
        receiver = _read_receiver_status(connection)
        metrics = _read_metric_statuses(connection)
        sync_cursors = _read_sync_cursor_statuses(connection)
    return BridgeStatusSnapshot(
        counts=counts,
        latest_sync=latest_sync,
        receiver=receiver,
        metrics=metrics,
        sync_cursors=sync_cursors,
        missing_data_notes=_status_notes(latest_sync, receiver, metrics),
        truncated=False,
    )


def _read_counts(connection: sqlite3.Connection) -> dict[str, int]:
    return {
        "sources": fetch_one_int(connection, SOURCE_COUNT_SQL),
        "health_types": fetch_one_int(connection, HEALTH_TYPE_COUNT_SQL),
        "samples": fetch_one_int(connection, SAMPLE_COUNT_SQL),
        "workouts": fetch_one_int(connection, WORKOUT_COUNT_SQL),
        "sleep_sessions": fetch_one_int(connection, SLEEP_SESSION_COUNT_SQL),
        "deleted_records": fetch_one_int(connection, DELETED_RECORD_COUNT_SQL),
        "sync_cursors": fetch_one_int(connection, SYNC_CURSOR_COUNT_SQL),
        "sync_runs": fetch_one_int(connection, SYNC_RUN_COUNT_SQL),
    }


def _read_latest_sync(connection: sqlite3.Connection) -> LatestSyncStatus | None:
    row = LATEST_SYNC_ROW_ADAPTER.validate_python(
        connection.execute(LATEST_SYNC_SQL).fetchone(),
    )
    if row is None:
        return None
    return LatestSyncStatus(
        sync_run_id=row[0],
        started_at=row[1],
        finished_at=row[2],
        status=row[3],
        sample_count=row[4],
        workout_count=row[5],
        sleep_session_count=row[6],
        deleted_record_count=row[7],
        sync_cursor_count=row[8],
        error_summary=row[9],
        sync_window_start=row[10],
        sync_window_end=row[11],
    )


def _read_receiver_status(connection: sqlite3.Connection) -> ReceiverStatus:
    row = RECEIVER_STATUS_ROW_ADAPTER.validate_python(
        connection.execute(RECEIVER_STATUS_SQL).fetchone(),
    )
    if row is None:
        return ReceiverStatus(
            has_active_token=False,
            active_token_count=0,
            revoked_token_count=0,
            total_token_count=0,
            latest_token_last_used_at=None,
        )
    active_count = row[0]
    return ReceiverStatus(
        has_active_token=active_count > 0,
        active_token_count=active_count,
        revoked_token_count=row[1],
        total_token_count=row[2],
        latest_token_last_used_at=row[3],
    )


def _read_metric_statuses(connection: sqlite3.Connection) -> dict[str, MetricStatus]:
    rows = METRIC_STATUS_ROWS_ADAPTER.validate_python(
        connection.execute(METRIC_STATUS_SQL).fetchall(),
    )
    return {
        type_code: MetricStatus(
            display_name=display_name,
            category=category,
            default_unit=default_unit,
            sensitivity=sensitivity,
            record_count=record_count,
            first_record_start=first_record_start,
            latest_record_end=latest_record_end,
            cursor_count=cursor_count,
            latest_cursor_updated_at=latest_cursor_updated_at,
        )
        for (
            type_code,
            display_name,
            category,
            default_unit,
            sensitivity,
            record_count,
            first_record_start,
            latest_record_end,
            cursor_count,
            latest_cursor_updated_at,
        ) in rows
    }


def _read_sync_cursor_statuses(
    connection: sqlite3.Connection,
) -> tuple[SyncCursorStatus, ...]:
    rows = SYNC_CURSOR_STATUS_ROWS_ADAPTER.validate_python(
        connection.execute(SYNC_CURSOR_STATUS_SQL).fetchall(),
    )
    return tuple(
        SyncCursorStatus(
            source_key=source_key,
            cursor_kind=cursor_kind,
            updated_at=updated_at,
        )
        for source_key, cursor_kind, updated_at in rows
    )


def _status_notes(
    latest_sync: LatestSyncStatus | None,
    receiver: ReceiverStatus,
    metrics: dict[str, MetricStatus],
) -> tuple[str, ...]:
    redacted_items = [
        "sample values",
        "cursor values",
        "bearer tokens",
        "token prefixes",
        "token hashes",
    ]
    redaction_note_prefix = ", ".join(redacted_items[:-1])
    last_redacted_item = redacted_items[-1]
    redaction_note = (
        f"Status is redacted: {redaction_note_prefix}, "
        f"and {last_redacted_item} are omitted."
    )
    notes = [redaction_note]
    if latest_sync is None:
        notes.append("No sync runs have been recorded yet.")
    if not receiver.has_active_token:
        notes.append("No active receiver token is configured for companion uploads.")
    if _has_optional_records_without_core_daily_lanes(latest_sync, metrics):
        core_note_subject = "Latest successful sync has optional sample records"
        core_note_detail = "but core daily lanes have no records yet"
        core_note_lanes = "steps, workout, and sleep_analysis are all empty."
        notes.append(f"{core_note_subject}, {core_note_detail}: {core_note_lanes}")
    return tuple(notes)


def _has_optional_records_without_core_daily_lanes(
    latest_sync: LatestSyncStatus | None,
    metrics: dict[str, MetricStatus],
) -> bool:
    if latest_sync is None or latest_sync.status != "succeeded":
        return False
    core_type_codes = ("steps", "workout", "sleep_analysis")
    core_record_count = sum(
        metrics[type_code].record_count
        for type_code in core_type_codes
        if type_code in metrics
    )
    optional_record_count = sum(
        metric.record_count
        for type_code, metric in metrics.items()
        if type_code not in core_type_codes
    )
    return optional_record_count > 0 and core_record_count == 0

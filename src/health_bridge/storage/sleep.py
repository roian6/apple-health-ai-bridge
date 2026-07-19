import re
import sqlite3
from dataclasses import dataclass
from typing import Final

from pydantic import TypeAdapter, ValidationError

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import SleepSession
from health_bridge.storage.catalog import source_id
from health_bridge.storage.sqlite_rows import fetch_one_int
from health_bridge.storage.tombstones import (
    record_is_tombstoned,
    upsert_deleted_record,
)

UPSERT_SLEEP_SESSION_SQL = (
    "insert into sleep_sessions (source_id, client_record_id, start_time, end_time) "
    "values (?, ?, ?, ?) on conflict(source_id, client_record_id) do update set "
    "start_time = excluded.start_time, end_time = excluded.end_time, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)
DELETE_SLEEP_INTERVALS_SQL = (
    "delete from sleep_stage_intervals where sleep_session_id = ?"
)
INSERT_SLEEP_INTERVAL_SQL = (
    "insert into sleep_stage_intervals "
    "(sleep_session_id, stage, start_time, end_time) "
    "values (?, ?, ?, ?) "
    "on conflict(sleep_session_id, stage, start_time, end_time) do nothing"
)
SELECT_SLEEP_SESSION_ID_SQL = (
    "select sleep_session_id from sleep_sessions "
    "where source_id = ? and client_record_id = ?"
)
SELECT_SLEEP_REVISIONS_SQL = (
    "select sleep_session_id, client_record_id, end_time from sleep_sessions "
    "where source_id = ? and start_time = ? "
    "order by end_time desc, sleep_session_id asc"
)
SELECT_SOURCE_SLEEP_SESSIONS_SQL = (
    "select sleep_session_id, client_record_id from sleep_sessions where source_id = ?"
)
SELECT_SYNC_CURSOR_SQL = (
    "select 1 from sync_cursors where source_id = ? and cursor_kind = ?"
)
SELECT_SYNC_CURSOR_VALUE_SQL = (
    "select cursor_value from sync_cursors where source_id = ? and cursor_kind = ?"
)
ENSURE_LEGACY_PHONE_SOURCE_SQL = (
    "insert into sources (source_key, name, kind) "
    "values (?, 'Apple Health on iPhone', 'phone') "
    "on conflict(source_key) do nothing"
)
UPSERT_SLEEP_SOURCE_RETIRED_SQL = (
    "insert into sync_cursors (source_id, cursor_kind, cursor_value) "
    "values (?, ?, ?) on conflict(source_id, cursor_kind) do update set "
    "cursor_value = excluded.cursor_value, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)
SELECT_SLEEP_BASELINE_NAMESPACE_SQL = (
    "select authoritative_applied from sleep_baseline_namespaces "
    "where source_id = ? and namespace = ?"
)
INSERT_SLEEP_BASELINE_NAMESPACE_SQL = (
    "insert into sleep_baseline_namespaces "
    "(source_id, namespace, authoritative_applied) values (?, ?, ?) "
    "on conflict(source_id, namespace) do nothing"
)
MARK_SLEEP_BASELINE_AUTHORITATIVE_SQL = (
    "update sleep_baseline_namespaces set authoritative_applied = 1 "
    "where source_id = ? and namespace = ?"
)
DELETE_SLEEP_SESSION_SQL = "delete from sleep_sessions where sleep_session_id = ?"
ANCHORED_SLEEP_CURSOR_KIND: Final = "anchored_sleep_sync"
ANCHORED_SLEEP_BASELINE_RESET_CURSOR_KIND: Final = "anchored_sleep_baseline_reset"
SLEEP_REVISION_ROWS_ADAPTER: Final[TypeAdapter[list[tuple[int, str, str]]]] = (
    TypeAdapter(list[tuple[int, str, str]])
)
SLEEP_IDENTITY_ROWS_ADAPTER: Final[TypeAdapter[list[tuple[int, str]]]] = TypeAdapter(
    list[tuple[int, str]]
)
CURSOR_EXISTS_ADAPTER: Final[TypeAdapter[tuple[int] | None]] = TypeAdapter(
    tuple[int] | None
)
CURSOR_VALUE_ADAPTER: Final[TypeAdapter[tuple[str] | None]] = TypeAdapter(
    tuple[str] | None
)
MISSING_SLEEP_SESSION_ERROR = "sleep session was not available after upsert"
CONFLICTING_SLEEP_BASELINE_RESET_ERROR = (
    "batch contains conflicting sleep baseline reset namespaces"
)
INCOMPLETE_SLEEP_BASELINE_RESET_ERROR = (
    "sleep baseline reset requires an anchored sleep cursor for the same source"
)
INVALID_ORDERED_SLEEP_BASELINE_RESET_ERROR = (
    "sleep baseline reset has an invalid ordered epoch"
)
STALE_ORDERED_SLEEP_BASELINE_RESET_ERROR = (
    "sleep baseline reset epoch is older than the receiver epoch"
)
ORDERED_RESET_RE: Final = re.compile(r"^v2:([1-9]\d*)$")
LEGACY_PHONE_SLEEP_SOURCE_KEY: Final = "apple_health.phone"
INSTALLATION_PHONE_SLEEP_SOURCE_PREFIX: Final = "apple_health.phone."
SLEEP_SOURCE_RETIRED_CURSOR_KIND: Final = "sleep_source_retired"


class StaleOrderedSleepBaselineResetError(sqlite3.IntegrityError):
    def __init__(self, current_epoch: int) -> None:
        super().__init__(STALE_ORDERED_SLEEP_BASELINE_RESET_ERROR)
        self.current_epoch: int = current_epoch


@dataclass(frozen=True)
class SleepBaselineResetPlan:
    authoritative_source_keys: frozenset[str]
    stale_source_keys: frozenset[str]


def _reconcile_sleep_revision(
    connection: sqlite3.Connection,
    *,
    current_source_id: int,
    sleep_session: SleepSession,
    authoritative_deletions: dict[str, str],
) -> bool:
    revisions = SLEEP_REVISION_ROWS_ADAPTER.validate_python(
        connection.execute(
            SELECT_SLEEP_REVISIONS_SQL,
            (current_source_id, sleep_session.start_time),
        ).fetchall()
    )
    if not revisions:
        return True

    preferred_session_id, _, preferred_end_time = revisions[0]
    incoming_client_exists = any(
        existing_client_record_id == sleep_session.client_record_id
        for _, existing_client_record_id, _ in revisions
    )
    existing_other_client_ids = {
        existing_client_record_id
        for _, existing_client_record_id, _ in revisions
        if existing_client_record_id != sleep_session.client_record_id
    }
    explicitly_displaces_all_revisions = bool(existing_other_client_ids) and (
        existing_other_client_ids <= authoritative_deletions.keys()
    )
    incoming_is_preferred = (
        explicitly_displaces_all_revisions
        or sleep_session.end_time > preferred_end_time
        or (sleep_session.end_time == preferred_end_time and incoming_client_exists)
    )
    revisions_to_delete = (
        [
            (session_id, existing_client_record_id)
            for session_id, existing_client_record_id, _ in revisions
            if session_id != preferred_session_id
        ]
        if not incoming_is_preferred
        else [
            (session_id, existing_client_record_id)
            for session_id, existing_client_record_id, _ in revisions
            if existing_client_record_id != sleep_session.client_record_id
        ]
    )
    superseded_client_record_ids = {
        existing_client_record_id
        for _, existing_client_record_id in revisions_to_delete
    }
    if not incoming_is_preferred and not incoming_client_exists:
        superseded_client_record_ids.add(sleep_session.client_record_id)
    superseded_at = (
        sleep_session.end_time if incoming_is_preferred else preferred_end_time
    )
    for superseded_client_record_id in superseded_client_record_ids:
        upsert_deleted_record(
            connection,
            source_id_value=current_source_id,
            record_family="sleep_session",
            client_record_id=superseded_client_record_id,
            deleted_at=authoritative_deletions.get(
                superseded_client_record_id,
                superseded_at,
            ),
        )
    for session_id, _ in revisions_to_delete:
        _ = connection.execute(DELETE_SLEEP_SESSION_SQL, (session_id,))
    return incoming_is_preferred


def plan_sleep_baseline_resets(
    connection: sqlite3.Connection,
    batch: HealthBridgeBatchV1,
) -> SleepBaselineResetPlan:
    reset_values_by_source: dict[str, set[str]] = {}
    for cursor in batch.sync.cursors:
        if cursor.cursor_kind != ANCHORED_SLEEP_BASELINE_RESET_CURSOR_KIND:
            continue
        reset_values_by_source.setdefault(cursor.source_key, set()).add(
            cursor.cursor_value
        )

    anchored_source_keys = {
        cursor.source_key
        for cursor in batch.sync.cursors
        if cursor.cursor_kind == ANCHORED_SLEEP_CURSOR_KIND
    }
    authoritative_source_keys: set[str] = set()
    stale_source_keys: set[str] = (
        {LEGACY_PHONE_SLEEP_SOURCE_KEY}
        if _legacy_phone_sleep_source_is_retired(connection)
        else set()
    )
    addition_source_keys = {session.source_key for session in batch.sleep_sessions}
    for source_key, reset_values in reset_values_by_source.items():
        if source_key in stale_source_keys:
            continue
        authoritative, stale = _plan_sleep_baseline_reset_for_source(
            connection,
            source_key=source_key,
            reset_values=reset_values,
            has_anchored_cursor=source_key in anchored_source_keys,
            has_readable_additions=source_key in addition_source_keys,
        )
        if authoritative:
            authoritative_source_keys.add(source_key)
        if stale:
            stale_source_keys.add(source_key)
    if any(
        source_key.startswith(INSTALLATION_PHONE_SLEEP_SOURCE_PREFIX)
        for source_key in authoritative_source_keys
    ):
        authoritative_source_keys.discard(LEGACY_PHONE_SLEEP_SOURCE_KEY)
        stale_source_keys.add(LEGACY_PHONE_SLEEP_SOURCE_KEY)
    return SleepBaselineResetPlan(
        authoritative_source_keys=frozenset(authoritative_source_keys),
        stale_source_keys=frozenset(stale_source_keys),
    )


def _plan_sleep_baseline_reset_for_source(
    connection: sqlite3.Connection,
    *,
    source_key: str,
    reset_values: set[str],
    has_anchored_cursor: bool,
    has_readable_additions: bool,
) -> tuple[bool, bool]:
    if len(reset_values) != 1:
        raise sqlite3.IntegrityError(CONFLICTING_SLEEP_BASELINE_RESET_ERROR)
    if not has_anchored_cursor:
        raise sqlite3.IntegrityError(INCOMPLETE_SLEEP_BASELINE_RESET_ERROR)
    namespace = next(iter(reset_values))
    incoming_epoch = _ordered_reset_epoch(namespace)
    current_source_id = source_id(connection, source_key)
    current_row = CURSOR_VALUE_ADAPTER.validate_python(
        connection.execute(
            SELECT_SYNC_CURSOR_VALUE_SQL,
            (current_source_id, ANCHORED_SLEEP_BASELINE_RESET_CURSOR_KIND),
        ).fetchone()
    )
    current_namespace = current_row[0] if current_row is not None else None
    current_epoch = (
        _ordered_reset_epoch(current_namespace)
        if current_namespace is not None
        else None
    )
    namespace_row = CURSOR_EXISTS_ADAPTER.validate_python(
        connection.execute(
            SELECT_SLEEP_BASELINE_NAMESPACE_SQL,
            (current_source_id, namespace),
        ).fetchone()
    )
    if namespace == current_namespace:
        if namespace_row is not None and namespace_row[0] == 1:
            return False, True
        if namespace_row is None:
            _ = connection.execute(
                INSERT_SLEEP_BASELINE_NAMESPACE_SQL,
                (current_source_id, namespace, int(has_readable_additions)),
            )
            return has_readable_additions, False
        if namespace_row[0] == 0 and has_readable_additions:
            _ = connection.execute(
                MARK_SLEEP_BASELINE_AUTHORITATIVE_SQL,
                (current_source_id, namespace),
            )
            return True, False
        return False, True
    if (
        current_epoch is not None
        and incoming_epoch is not None
        and incoming_epoch < current_epoch
    ):
        raise StaleOrderedSleepBaselineResetError(current_epoch)
    is_older_than_current = current_namespace is not None and incoming_epoch is None
    if is_older_than_current or namespace_row is not None:
        return False, True
    _ = connection.execute(
        INSERT_SLEEP_BASELINE_NAMESPACE_SQL,
        (current_source_id, namespace, int(has_readable_additions)),
    )
    return has_readable_additions, False


def _legacy_phone_sleep_source_is_retired(connection: sqlite3.Connection) -> bool:
    row = CURSOR_EXISTS_ADAPTER.validate_python(
        connection.execute(
            """
            select 1 from sync_cursors join sources using (source_id)
            where sources.source_key = ? and sync_cursors.cursor_kind = ?
            """,
            (LEGACY_PHONE_SLEEP_SOURCE_KEY, SLEEP_SOURCE_RETIRED_CURSOR_KIND),
        ).fetchone()
    )
    return row is not None


def _ordered_reset_epoch(namespace: str) -> int | None:
    match = ORDERED_RESET_RE.fullmatch(namespace)
    if match is not None:
        return int(match.group(1))
    if namespace.startswith("v2:"):
        raise sqlite3.IntegrityError(INVALID_ORDERED_SLEEP_BASELINE_RESET_ERROR)
    return None


def _sleep_deletions_by_source(
    batch: HealthBridgeBatchV1,
    *,
    stale_source_keys: frozenset[str],
) -> dict[str, dict[str, str]]:
    deletions_by_source: dict[str, dict[str, str]] = {}
    for deleted_record in batch.deleted_records:
        if deleted_record.record_family != "sleep_session":
            continue
        if deleted_record.source_key in stale_source_keys:
            continue
        deletions_by_source.setdefault(deleted_record.source_key, {})[
            deleted_record.client_record_id
        ] = deleted_record.deleted_at
    return deletions_by_source


def _prepare_initial_authoritative_baselines(
    connection: sqlite3.Connection,
    batch: HealthBridgeBatchV1,
    reset_plan: SleepBaselineResetPlan,
) -> None:
    anchored_source_keys = {
        cursor.source_key
        for cursor in batch.sync.cursors
        if cursor.cursor_kind == ANCHORED_SLEEP_CURSOR_KIND
        and cursor.source_key not in reset_plan.stale_source_keys
    }
    baseline_reset_source_keys = reset_plan.authoritative_source_keys
    installation_reset_sources = sorted(
        source_key
        for source_key in baseline_reset_source_keys
        if source_key.startswith(INSTALLATION_PHONE_SLEEP_SOURCE_PREFIX)
    )
    if installation_reset_sources:
        _retire_legacy_phone_sleep_source(
            connection,
            retired_by=installation_reset_sources[0],
            retired_at=batch.generated_at,
        )
    incoming_ids_by_source: dict[str, set[str]] = {}
    for sleep_session in batch.sleep_sessions:
        incoming_ids_by_source.setdefault(sleep_session.source_key, set()).add(
            sleep_session.client_record_id
        )

    for source_key in anchored_source_keys:
        incoming_client_record_ids = incoming_ids_by_source.get(source_key, set())
        if not incoming_client_record_ids:
            continue
        current_source_id = source_id(connection, source_key)
        existing_cursor = CURSOR_EXISTS_ADAPTER.validate_python(
            connection.execute(
                SELECT_SYNC_CURSOR_SQL,
                (current_source_id, ANCHORED_SLEEP_CURSOR_KIND),
            ).fetchone()
        )
        if existing_cursor is not None and source_key not in baseline_reset_source_keys:
            continue
        existing_sessions = SLEEP_IDENTITY_ROWS_ADAPTER.validate_python(
            connection.execute(
                SELECT_SOURCE_SLEEP_SESSIONS_SQL,
                (current_source_id,),
            ).fetchall()
        )
        for session_id, existing_client_record_id in existing_sessions:
            if existing_client_record_id in incoming_client_record_ids:
                continue
            upsert_deleted_record(
                connection,
                source_id_value=current_source_id,
                record_family="sleep_session",
                client_record_id=existing_client_record_id,
                deleted_at=batch.generated_at,
            )
            _ = connection.execute(DELETE_SLEEP_SESSION_SQL, (session_id,))


def _retire_legacy_phone_sleep_source(
    connection: sqlite3.Connection,
    *,
    retired_by: str,
    retired_at: str,
) -> None:
    _ = connection.execute(
        ENSURE_LEGACY_PHONE_SOURCE_SQL,
        (LEGACY_PHONE_SLEEP_SOURCE_KEY,),
    )
    legacy_source_id = source_id(connection, LEGACY_PHONE_SLEEP_SOURCE_KEY)
    existing_sessions = SLEEP_IDENTITY_ROWS_ADAPTER.validate_python(
        connection.execute(
            SELECT_SOURCE_SLEEP_SESSIONS_SQL,
            (legacy_source_id,),
        ).fetchall()
    )
    for session_id, client_record_id in existing_sessions:
        upsert_deleted_record(
            connection,
            source_id_value=legacy_source_id,
            record_family="sleep_session",
            client_record_id=client_record_id,
            deleted_at=retired_at,
        )
        _ = connection.execute(DELETE_SLEEP_SESSION_SQL, (session_id,))
    _ = connection.execute(
        UPSERT_SLEEP_SOURCE_RETIRED_SQL,
        (
            legacy_source_id,
            SLEEP_SOURCE_RETIRED_CURSOR_KIND,
            f"retired-by:{retired_by}",
        ),
    )


def upsert_sleep_sessions(
    connection: sqlite3.Connection,
    batch: HealthBridgeBatchV1,
    reset_plan: SleepBaselineResetPlan,
) -> None:
    _prepare_initial_authoritative_baselines(connection, batch, reset_plan)
    deletions_by_source = _sleep_deletions_by_source(
        batch,
        stale_source_keys=reset_plan.stale_source_keys,
    )
    for sleep_session in batch.sleep_sessions:
        if sleep_session.source_key in reset_plan.stale_source_keys:
            continue
        current_source_id = source_id(connection, sleep_session.source_key)
        authoritative_deletions = deletions_by_source.get(
            sleep_session.source_key,
            {},
        )
        if sleep_session.client_record_id in authoritative_deletions:
            continue
        if record_is_tombstoned(
            connection,
            source_id_value=current_source_id,
            record_family="sleep_session",
            client_record_id=sleep_session.client_record_id,
        ):
            continue
        if not _reconcile_sleep_revision(
            connection,
            current_source_id=current_source_id,
            sleep_session=sleep_session,
            authoritative_deletions=authoritative_deletions,
        ):
            continue
        _ = connection.execute(
            UPSERT_SLEEP_SESSION_SQL,
            (
                current_source_id,
                sleep_session.client_record_id,
                sleep_session.start_time,
                sleep_session.end_time,
            ),
        )
        current_sleep_session_id = sleep_session_id(
            connection,
            current_source_id,
            sleep_session.client_record_id,
        )
        _ = connection.execute(DELETE_SLEEP_INTERVALS_SQL, (current_sleep_session_id,))
        for interval in sleep_session.stage_intervals:
            _ = connection.execute(
                INSERT_SLEEP_INTERVAL_SQL,
                (
                    current_sleep_session_id,
                    interval.stage,
                    interval.start_time,
                    interval.end_time,
                ),
            )


def sleep_session_id(
    connection: sqlite3.Connection,
    current_source_id: int,
    client_record_id: str,
) -> int:
    try:
        sleep_session_id_value = fetch_one_int(
            connection,
            SELECT_SLEEP_SESSION_ID_SQL,
            (current_source_id, client_record_id),
        )
    except ValidationError as exc:
        raise sqlite3.IntegrityError(MISSING_SLEEP_SESSION_ERROR) from exc
    if sleep_session_id_value <= 0:
        raise sqlite3.IntegrityError(MISSING_SLEEP_SESSION_ERROR)
    return sleep_session_id_value

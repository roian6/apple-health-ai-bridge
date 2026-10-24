import sqlite3
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from threading import Barrier, Event

import pytest
from pydantic import TypeAdapter

from health_bridge.ingest import ingest_batch
from health_bridge.queries import list_synced_metrics
from health_bridge.queries._common import connect_readonly
from health_bridge.storage import database
from health_bridge.storage._database_migrations import migration_was_applied
from health_bridge.storage.database import connect_database, initialize_database
from health_bridge.storage.migration_backup import (
    delivery_receipt_backup_path,
    delivery_receipt_rollback_guard_path,
)
from tests.fixture_helpers import initialized_fixture_db
from tests.queries.catalogue_fixtures import catalogue_batch

MIGRATION_ID = "012_catalogue_coverage_index"
INDEX_NAME = "samples_type_coverage"
INDEX_COLUMNS = ("type_code", "start_time", "sample_id", "end_time")
INDEX_ROWS = TypeAdapter(list[tuple[int, int, str]])


def _index_columns(connection: sqlite3.Connection) -> tuple[str, ...]:
    rows = INDEX_ROWS.validate_python(
        connection.execute("pragma index_info(samples_type_coverage)").fetchall()
    )
    return tuple(column for _, _, column in rows)


def _migration_count(connection: sqlite3.Connection) -> int:
    return TypeAdapter(tuple[int]).validate_python(
        connection.execute(
            "select count(*) from schema_migrations where migration_id = ?",
            (MIGRATION_ID,),
        ).fetchone()
    )[0]


def _create_populated_011_database(tmp_path: Path) -> Path:
    db_path = initialized_fixture_db(tmp_path)
    assert (
        ingest_batch(db_path, catalogue_batch(7), "synthetic-catalogue-upgrade").status
        == "succeeded"
    )

    # Preserve the real 008 backup and guard while modeling the previous schema.
    with connect_database(db_path) as connection:
        _ = connection.execute("drop index if exists samples_type_coverage")
        _ = connection.execute(
            "delete from schema_migrations where migration_id = ?", (MIGRATION_ID,)
        )

    return db_path


def _receipt_artifacts(db_path: Path) -> tuple[bytes, bytes]:
    return (
        delivery_receipt_backup_path(db_path).read_bytes(),
        delivery_receipt_rollback_guard_path(db_path).read_bytes(),
    )


def test_fresh_database_has_exact_catalogue_covering_index(tmp_path: Path) -> None:
    db_path = tmp_path / "synthetic-fresh.sqlite"

    initialize_database(db_path)

    with closing(sqlite3.connect(db_path)) as connection:
        assert _index_columns(connection) == INDEX_COLUMNS
        assert connection.execute(
            """select name, \"unique\", partial from pragma_index_list('samples')
            where name = ?""",
            (INDEX_NAME,),
        ).fetchone() == (INDEX_NAME, 0, 0)
        assert _migration_count(connection) == 1


def test_populated_011_upgrade_preserves_catalogue_and_receipt_artifacts(
    tmp_path: Path,
) -> None:
    db_path = _create_populated_011_database(tmp_path)
    previous = list_synced_metrics(db_path)
    artifacts = _receipt_artifacts(db_path)
    assert previous.stored_coverage is not None
    assert previous.latest_sync_window is not None
    assert len(previous.metrics) == 5

    initialize_database(db_path)

    assert list_synced_metrics(db_path) == previous
    assert _receipt_artifacts(db_path) == artifacts
    with closing(sqlite3.connect(db_path)) as connection:
        assert _index_columns(connection) == INDEX_COLUMNS
        assert _migration_count(connection) == 1
        assert connection.execute("pragma integrity_check").fetchone() == ("ok",)
        assert connection.execute("pragma foreign_key_check").fetchall() == []


def test_011_catalogue_query_does_not_apply_pending_migration(tmp_path: Path) -> None:
    db_path = _create_populated_011_database(tmp_path)
    before = db_path.read_bytes()
    artifacts = _receipt_artifacts(db_path)

    with connect_readonly(db_path) as connection:
        assert connection.execute("pragma query_only").fetchone() == (1,)
        result = list_synced_metrics(db_path)
        assert _index_columns(connection) == ()
        assert _migration_count(connection) == 0

    assert len(result.metrics) == 5
    assert result.metrics[0].record_count > 0
    assert result.stored_coverage is not None
    assert result.latest_sync_window is not None
    assert db_path.read_bytes() == before
    assert _receipt_artifacts(db_path) == artifacts


def test_repeated_initialization_never_rebuilds_catalogue_index(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = _create_populated_011_database(tmp_path)
    initialize_database(db_path)
    before = db_path.read_bytes()
    artifacts = _receipt_artifacts(db_path)
    real_connect = sqlite3.connect
    denied_actions: list[int] = []

    def connect_without_index_changes(path: Path) -> sqlite3.Connection:
        connection = real_connect(path)

        def authorizer(
            action: int,
            _arg1: str | None,
            _arg2: str | None,
            _database_name: str | None,
            _trigger_name: str | None,
        ) -> int:
            if action in (sqlite3.SQLITE_CREATE_INDEX, sqlite3.SQLITE_DROP_INDEX):
                denied_actions.append(action)
                return sqlite3.SQLITE_DENY

            return sqlite3.SQLITE_OK

        connection.set_authorizer(authorizer)
        return connection

    with monkeypatch.context() as hooks:
        hooks.setattr(sqlite3, "connect", connect_without_index_changes)
        initialize_database(db_path)
        initialize_database(db_path)

    assert denied_actions == []
    assert db_path.read_bytes() == before
    assert _receipt_artifacts(db_path) == artifacts
    with closing(real_connect(db_path)) as connection:
        assert _index_columns(connection) == INDEX_COLUMNS
        assert _migration_count(connection) == 1


def test_concurrent_initializers_recheck_012_and_create_index_once(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = _create_populated_011_database(tmp_path)
    previous = list_synced_metrics(db_path)
    artifacts = _receipt_artifacts(db_path)
    worker_count = 4
    prelock_barrier = Barrier(worker_count)
    index_creations: list[str | None] = []
    real_connect = sqlite3.connect

    def synchronized_migration_check(
        connection: sqlite3.Connection, migration_id: str
    ) -> bool:
        was_applied = migration_was_applied(connection, migration_id)
        if migration_id == MIGRATION_ID and not connection.in_transaction:
            assert not was_applied
            _ = prelock_barrier.wait(timeout=10)

        return was_applied

    def connect_with_index_observer(path: Path) -> sqlite3.Connection:
        connection = real_connect(path)

        def authorizer(
            action: int,
            arg1: str | None,
            _arg2: str | None,
            _database_name: str | None,
            _trigger_name: str | None,
        ) -> int:
            if action == sqlite3.SQLITE_CREATE_INDEX and arg1 == INDEX_NAME:
                index_creations.append(arg1)

            return sqlite3.SQLITE_OK

        connection.set_authorizer(authorizer)
        return connection

    with monkeypatch.context() as hooks:
        hooks.setattr(database, "_migration_was_applied", synchronized_migration_check)
        hooks.setattr(sqlite3, "connect", connect_with_index_observer)
        with ThreadPoolExecutor(max_workers=worker_count) as executor:
            futures = [
                executor.submit(initialize_database, db_path)
                for _ in range(worker_count)
            ]
            for future in futures:
                future.result(timeout=15)

    assert index_creations == [INDEX_NAME]
    assert list_synced_metrics(db_path) == previous
    assert _receipt_artifacts(db_path) == artifacts
    with closing(real_connect(db_path)) as connection:
        assert _index_columns(connection) == INDEX_COLUMNS
        assert _migration_count(connection) == 1


def test_012_waits_for_reader_then_commits_complete_migration(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = _create_populated_011_database(tmp_path)
    previous = list_synced_metrics(db_path)
    commit_attempted = Event()
    real_connect = sqlite3.connect

    def connect_with_commit_observer(path: Path) -> sqlite3.Connection:
        connection = real_connect(path)

        def trace(statement: str) -> None:
            if statement.strip().lower() == "commit":
                commit_attempted.set()

        connection.set_trace_callback(trace)
        return connection

    with ThreadPoolExecutor(max_workers=1) as executor:
        with connect_readonly(db_path) as reader, monkeypatch.context() as hooks:
            hooks.setattr(sqlite3, "connect", connect_with_commit_observer)
            future = executor.submit(initialize_database, db_path)
            assert commit_attempted.wait(timeout=5)
            assert not future.done()
            assert _index_columns(reader) == ()
            assert _migration_count(reader) == 0
            assert list_synced_metrics(db_path) == previous

        future.result(timeout=10)

    assert list_synced_metrics(db_path) == previous
    with closing(real_connect(db_path)) as connection:
        assert _index_columns(connection) == INDEX_COLUMNS
        assert _migration_count(connection) == 1


def test_012_waits_for_writer_then_preserves_committed_rows(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = _create_populated_011_database(tmp_path)
    begin_attempted = Event()
    real_connect = sqlite3.connect

    def connect_with_begin_observer(path: Path) -> sqlite3.Connection:
        connection = real_connect(path)

        def trace(statement: str) -> None:
            if statement.strip().lower() == "begin immediate":
                begin_attempted.set()

        connection.set_trace_callback(trace)
        return connection

    with ThreadPoolExecutor(max_workers=1) as executor:
        with connect_database(db_path) as writer:
            _ = writer.execute("begin immediate")
            _ = writer.execute("update sources set name = 'Synthetic committed source'")
            with monkeypatch.context() as hooks:
                hooks.setattr(sqlite3, "connect", connect_with_begin_observer)
                future = executor.submit(initialize_database, db_path)
                assert begin_attempted.wait(timeout=5)
                assert not future.done()
                assert _index_columns(writer) == ()
                assert _migration_count(writer) == 0

        future.result(timeout=10)

    result = list_synced_metrics(db_path)
    assert {source.name for source in result.sources_used} == {
        "Synthetic committed source"
    }
    with closing(real_connect(db_path)) as connection:
        assert _index_columns(connection) == INDEX_COLUMNS
        assert _migration_count(connection) == 1


def test_failure_after_create_index_rolls_back_index_and_ledger(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = _create_populated_011_database(tmp_path)
    previous = list_synced_metrics(db_path)
    artifacts = _receipt_artifacts(db_path)
    real_connect = sqlite3.connect
    created_columns: list[tuple[str, ...]] = []

    def connect_with_denied_ledger_write(path: Path) -> sqlite3.Connection:
        connection = real_connect(path)
        has_created_index = False

        def authorizer(
            action: int,
            arg1: str | None,
            _arg2: str | None,
            _database_name: str | None,
            _trigger_name: str | None,
        ) -> int:
            nonlocal has_created_index
            if action == sqlite3.SQLITE_CREATE_INDEX and arg1 == INDEX_NAME:
                has_created_index = True
            if (
                has_created_index
                and action == sqlite3.SQLITE_INSERT
                and arg1 == "schema_migrations"
            ):
                created_columns.append(_index_columns(connection))
                return sqlite3.SQLITE_DENY

            return sqlite3.SQLITE_OK

        connection.set_authorizer(authorizer)
        return connection

    with monkeypatch.context() as hooks:
        hooks.setattr(sqlite3, "connect", connect_with_denied_ledger_write)
        with pytest.raises(sqlite3.DatabaseError, match="not authorized"):
            initialize_database(db_path)

    assert created_columns
    assert all(columns == INDEX_COLUMNS for columns in created_columns)
    assert list_synced_metrics(db_path) == previous
    assert _receipt_artifacts(db_path) == artifacts
    with closing(real_connect(db_path)) as connection:
        assert _index_columns(connection) == ()
        assert _migration_count(connection) == 0

    initialize_database(db_path)

    assert list_synced_metrics(db_path) == previous
    with closing(real_connect(db_path)) as connection:
        assert _index_columns(connection) == INDEX_COLUMNS
        assert _migration_count(connection) == 1

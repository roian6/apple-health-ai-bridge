import os
import sqlite3
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from typing import Literal

import pytest

from health_bridge.mcp import server
from health_bridge.mcp.server import dispatch_request, mcp_smoke_result
from health_bridge.mcp.types import JsonMapping, JsonObject
from health_bridge.queries import catalog
from health_bridge.queries._common import (
    connect_readonly,
    fetch_all_sources,
    fetch_latest_sync_window,
)
from health_bridge.queries.catalog import list_synced_metrics
from health_bridge.queries.models import Period, SourceUsed
from health_bridge.storage._query_database import DatabaseReadError
from health_bridge.storage.database import connect_database
from health_bridge.storage.sqlite_rows import fetch_one_int
from tests.fixture_helpers import initialized_fixture_db
from tests.mcp.committed_read_support import (
    WRITER,
    line_process,
    receive,
    send,
    status_payload,
    status_request,
)


def test_query_connection_enforces_query_only_and_closes(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with connect_readonly(db_path) as connection:
        assert connection.in_transaction
        assert connection.execute("pragma query_only").fetchone() == (1,)
        with pytest.raises(sqlite3.OperationalError, match="readonly"):
            _ = connection.execute("delete from samples")
    with pytest.raises(sqlite3.ProgrammingError, match="closed"):
        _ = connection.execute("select 1")


def test_reader_record_lock_survives_other_same_process_connection_cleanup(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with line_process([sys.executable, "-u", "-c", WRITER, str(db_path)]) as writer:
        assert receive(writer) == "ready"
        with connect_readonly(db_path) as reader:
            before = fetch_one_int(reader, "select count(*) from samples")
            with connect_database(db_path) as other:
                assert other.execute("select 1").fetchone() == (1,)
            assert send(writer, "commit") == "blocked"
            assert fetch_one_int(reader, "select count(*) from samples") == before
        assert send(writer, "commit") == "committed"


def test_threaded_receiver_writer_and_reader_keep_committed_results(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    previous = status_payload(dispatch_request(db_path, status_request()))
    ready, finish = Event(), Event()

    def write() -> None:
        with connect_database(db_path) as connection:
            _ = connection.execute("begin immediate")
            _ = connection.execute("delete from samples")
            ready.set()
            assert finish.wait(timeout=5)

    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(write)
        try:
            assert ready.wait(timeout=5)
            assert (
                status_payload(dispatch_request(db_path, status_request())) == previous
            )
            assert list_synced_metrics(db_path).metrics
        finally:
            finish.set()
        future.result(timeout=5)
    assert status_payload(dispatch_request(db_path, status_request())) != previous


@pytest.mark.parametrize("boundary", ["window", "sources", "smoke"])
def test_component_queries_share_outer_transaction(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    boundary: Literal["window", "sources", "smoke"],
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    previous = list_synced_metrics(db_path)
    outcomes: list[str] = []
    writer_script = WRITER.replace(
        "    connection.execute('delete from workouts')",
        """    connection.execute('delete from workouts')
    connection.execute("update sources set name='Synthetic committed writer'")
    connection.execute(
        "update sync_runs set sync_window_start='2026-06-10T00:00:00Z', "
        "sync_window_end='2026-06-11T00:00:00Z'"
    )""",
    )
    with (
        monkeypatch.context() as read_hooks,
        line_process(
            [sys.executable, "-u", "-c", writer_script, str(db_path)]
        ) as writer,
    ):
        assert receive(writer) == "ready"
        if boundary == "window":

            def before_window(connection: sqlite3.Connection) -> Period | None:
                outcomes.append(send(writer, "commit"))
                return fetch_latest_sync_window(connection)

            read_hooks.setattr(catalog, "fetch_latest_sync_window", before_window)
        elif boundary == "sources":

            def before_sources(
                connection: sqlite3.Connection,
            ) -> tuple[SourceUsed, ...]:
                outcomes.append(send(writer, "commit"))
                return fetch_all_sources(connection)

            read_hooks.setattr(catalog, "fetch_all_sources", before_sources)
        else:

            def between_tools(path: Path, request: JsonMapping) -> JsonObject:
                result = dispatch_request(path, request)
                if request.get("id") == 2:
                    outcomes.append(send(writer, "commit"))
                return result

            read_hooks.setattr(server, "dispatch_request", between_tools)
            assert mcp_smoke_result(db_path)["called_tool"] == "list_synced_metrics"

        if boundary != "smoke":
            assert list_synced_metrics(db_path) == previous

        assert outcomes == ["blocked"]
        assert send(writer, "commit") == "committed"

    committed = list_synced_metrics(db_path)
    assert committed.metrics != previous.metrics
    assert committed.stored_coverage != previous.stored_coverage
    assert committed.latest_sync_window != previous.latest_sync_window
    assert committed.sources_used != previous.sources_used


@pytest.mark.parametrize(
    ("suffix", "payload"),
    [
        ("-wal", b"corrupt"),
        ("-shm", b"corrupt"),
        ("-journal", b"corrupt"),
        ("-journal", bytes(512)),
    ],
)
def test_corrupt_sidecars_refuse_without_mutation(
    tmp_path: Path,
    suffix: str,
    payload: bytes,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    sidecar = Path(f"{db_path}{suffix}")
    _ = sidecar.write_bytes(payload)
    sidecar.chmod(0o600)
    before = {p.name: p.read_bytes() for p in tmp_path.iterdir() if p.is_file()}
    response = dispatch_request(db_path, status_request())
    assert response.get("error") == {
        "code": -32000,
        "message": "Health Bridge database is unavailable.",
    }
    assert {p.name: p.read_bytes() for p in tmp_path.iterdir() if p.is_file()} == before


@pytest.mark.parametrize("kind", ["symlink", "hardlink", "public"])
def test_unsafe_journal_refuses_without_repair(tmp_path: Path, kind: str) -> None:
    db_path = initialized_fixture_db(tmp_path)
    target = tmp_path / "synthetic-target"
    _ = target.write_bytes(bytes(512))
    target.chmod(0o640)
    journal = Path(f"{db_path}-journal")
    match kind:
        case "symlink":
            journal.symlink_to(target)
        case "hardlink":
            os.link(target, journal)
        case "public":
            _ = journal.write_bytes(bytes(512))
            journal.chmod(0o640)
        case _:
            pytest.fail("unknown test case")
    journal_mode = journal.lstat().st_mode
    response = dispatch_request(db_path, status_request())
    assert "error" in response
    assert target.read_bytes() == bytes(512)
    assert target.stat().st_mode & 0o777 == 0o640
    assert journal.lstat().st_mode == journal_mode


@pytest.mark.parametrize(
    "kind", ["corrupt", "uninitialized", "wal", "symlink", "hardlink", "parent"]
)
def test_unsafe_or_unsupported_databases_refuse(tmp_path: Path, kind: str) -> None:
    db_path = initialized_fixture_db(tmp_path)
    match kind:
        case "corrupt":
            _ = db_path.write_bytes(b"synthetic corrupt database")
        case "uninitialized":
            with connect_database(db_path) as connection:
                _ = connection.execute("drop table schema_migrations")
        case "wal":
            with connect_database(db_path) as connection:
                _ = connection.execute("pragma journal_mode = wal")
            assert not Path(f"{db_path}-wal").exists()
        case "symlink":
            target = db_path.with_suffix(".target")
            _ = db_path.rename(target)
            db_path.symlink_to(target)
        case "hardlink":
            os.link(db_path, db_path.with_suffix(".alias"))
        case "parent":
            tmp_path.chmod(0o777)
        case _:
            pytest.fail("unknown test case")
    try:
        response = dispatch_request(db_path, status_request())
        assert "error" in response
        assert "result" not in response
        assert not Path(f"{db_path}-shm").exists()
    finally:
        tmp_path.chmod(0o700)


def test_long_writer_descriptor_retention_is_bounded_and_recovers(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with connect_database(db_path) as writer:
        _ = writer.execute("begin immediate")
        for _ in range(300):
            try:
                with connect_readonly(db_path) as reader:
                    assert reader.execute("select 1").fetchone() == (1,)
            except DatabaseReadError:
                break
        else:
            pytest.fail("overlapping descriptor lifetimes must have bounded retention")
    with connect_readonly(db_path) as reader:
        assert reader.execute("select 1").fetchone() == (1,)


@pytest.mark.skipif(sys.platform != "linux", reason="Linux descriptor inventory")
def test_descriptor_cleanup_after_success_and_error(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    before = len(list(Path("/proc/self/fd").iterdir()))
    for _ in range(10):
        with connect_database(db_path) as writer:
            _ = writer.execute("begin immediate")
            with connect_readonly(db_path) as reader:
                assert reader.execute("select 1").fetchone() == (1,)
            with (
                pytest.raises(DatabaseReadError),
                connect_readonly(db_path) as reader,
            ):
                _ = reader.execute("delete from samples")
    assert len(list(Path("/proc/self/fd").iterdir())) == before

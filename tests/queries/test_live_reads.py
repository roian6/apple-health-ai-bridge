from __future__ import annotations

import multiprocessing
import os
import sqlite3
import sys
from contextlib import contextmanager
from pathlib import Path
from subprocess import run
from typing import TYPE_CHECKING, TypeAlias

import pytest
from typer.testing import CliRunner

import health_bridge.storage.database as database_module
from health_bridge.cli import app
from health_bridge.mcp.server import dispatch_request
from health_bridge.mcp.types import required_list, required_object, required_string
from health_bridge.queries import get_timeseries
from health_bridge.queries.models import TimeseriesResult
from health_bridge.status import BridgeStatusSnapshot, read_status_snapshot
from health_bridge.storage._database_lock_files import require_live_readable_database
from health_bridge.storage.database import (
    connect_database,
    connect_live_readonly_database,
    connect_readonly_database,
    database_access_lock,
    database_lifecycle_lock,
    exclusive_database_maintenance,
)
from health_bridge.storage.sqlite_rows import fetch_one_int
from tests.fixture_helpers import initialized_fixture_db

if TYPE_CHECKING:
    from collections.abc import Generator
    from multiprocessing.connection import Connection, PipeConnection

    MessagePipe: TypeAlias = Connection[str, str] | PipeConnection[str, str]

START = "2026-06-01T00:00:00Z"
END = "2026-06-08T00:00:00Z"


def _writer(db_path: Path, mode: str, pipe: MessagePipe) -> None:
    with connect_database(db_path) as connection:
        assert connection.execute(f"pragma journal_mode={mode}").fetchone() == (mode,)
        # A writer must prepare WAL shared memory before live reader admission.
        assert fetch_one_int(connection, "select count(*) from samples") > 0
        pipe.send("ready")
        while pipe.poll(20):
            command = pipe.recv()
            if command == "stop":
                break
            if command == "stage":
                _ = connection.execute("delete from samples where type_code = 'steps'")
            elif command == "commit":
                connection.commit()
            elif command == "exclusive":
                _ = connection.execute("begin exclusive")
            else:
                raise AssertionError(command)
            pipe.send(command)


def _receive(pipe: MessagePipe, expected: str) -> None:
    assert pipe.poll(10), f"child did not report {expected}"
    assert pipe.recv() == expected


@contextmanager
def held_writer(db_path: Path, mode: str) -> Generator[MessagePipe, None, None]:
    context = multiprocessing.get_context("spawn")
    parent, child = context.Pipe()
    process = context.Process(target=_writer, args=(db_path, mode, child))
    process.start()
    child.close()
    try:
        _receive(parent, "ready")
        yield parent
    finally:
        parent.send("stop")
        process.join(timeout=10)
        if process.is_alive():
            process.terminate()
            process.join(timeout=10)
        parent.close()
        assert process.exitcode == 0


def _point_count(db_path: Path, surface: str) -> int:
    if surface == "api":
        return len(get_timeseries(db_path, ("steps",), START, END).points)
    if surface == "cli":
        result = run(
            [
                sys.executable,
                "-c",
                "from health_bridge.cli import run; run()",
                "query",
                "timeseries",
                "--db",
                str(db_path),
                "--types",
                "steps",
                "--start-time",
                START,
                "--end-time",
                END,
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        assert result.returncode == 0, result.stderr
        return len(TimeseriesResult.model_validate_json(result.stdout).points)
    response = dispatch_request(
        db_path,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "get_timeseries",
                "arguments": {
                    "type_codes": ["steps"],
                    "start_time": START,
                    "end_time": END,
                },
            },
        },
    )
    assert "result" in response, response
    content = required_list(required_object(response["result"])["content"])
    payload = required_string(required_object(content[0])["text"])
    return len(TimeseriesResult.model_validate_json(payload).points)


@pytest.mark.parametrize("mode", ["delete", "wal"])
@pytest.mark.parametrize("surface", ["api", "cli", "mcp"])
def test_public_queries_read_commits_while_other_process_holds_writer(
    tmp_path: Path,
    mode: str,
    surface: str,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with held_writer(db_path, mode) as writer:
        assert _point_count(db_path, surface) == 1
        writer.send("stage")
        _receive(writer, "stage")
        assert _point_count(db_path, surface) == 1
        writer.send("commit")
        _receive(writer, "commit")
        assert _point_count(db_path, surface) == 0


@pytest.mark.parametrize("mode", ["delete", "wal"])
def test_status_surfaces_read_while_other_process_holds_writer(
    tmp_path: Path,
    mode: str,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    expected = read_status_snapshot(db_path).counts
    with held_writer(db_path, mode):
        assert read_status_snapshot(db_path).counts == expected
        result = CliRunner().invoke(app, ["status", "--json", "--db", str(db_path)])
        assert result.exit_code == 0, result.output
        assert (
            BridgeStatusSnapshot.model_validate_json(result.stdout).counts == expected
        )
        response = dispatch_request(
            db_path,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "get_bridge_status", "arguments": {}},
            },
        )
        assert "result" in response, response


def test_wal_read_transaction_keeps_snapshot_across_committed_write(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with held_writer(db_path, "wal") as writer:
        with connect_live_readonly_database(db_path) as reader:
            before = fetch_one_int(reader, "select count(*) from samples")
            writer.send("stage")
            _receive(writer, "stage")
            writer.send("commit")
            _receive(writer, "commit")
            assert fetch_one_int(reader, "select count(*) from samples") == before
        assert _point_count(db_path, "api") == 0


def test_writer_permission_checks_preserve_wal_read_locks(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with held_writer(db_path, "wal") as writer:
        with connect_live_readonly_database(db_path) as reader:
            before = fetch_one_int(reader, "select count(*) from samples")
            writer.send("stage")
            _receive(writer, "stage")
            writer.send("commit")
            _receive(writer, "commit")
            shared_memory = Path(f"{db_path}-shm")
            shared_memory.chmod(0o644)
            with connect_database(db_path):
                pass
            assert shared_memory.stat().st_mode & 0o077 == 0
            probe = run(
                [
                    sys.executable,
                    "-c",
                    "import sqlite3,sys; c=sqlite3.connect(sys.argv[1],timeout=0); print(c.execute('pragma wal_checkpoint(truncate)').fetchone()[0])",  # noqa: E501
                    str(db_path),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            assert probe.returncode == 0, probe.stderr
            assert probe.stdout.strip() == "1", "reader must prevent WAL truncation"
            assert fetch_one_int(reader, "select count(*) from samples") == before
        assert _point_count(db_path, "api") == 0


@pytest.mark.parametrize("mode", ["delete", "wal"])
def test_read_connection_rejects_sql_writes(tmp_path: Path, mode: str) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with held_writer(db_path, mode), connect_live_readonly_database(db_path) as reader:
        assert reader.execute("pragma query_only").fetchone() == (1,)
        for statement in (
            "delete from samples",
            "create table forbidden(value)",
            "create temp table forbidden(value)",
        ):
            with pytest.raises(sqlite3.OperationalError, match="readonly"):
                _ = reader.execute(statement)
        _ = reader.execute("pragma query_only = off")
        with pytest.raises(sqlite3.OperationalError, match="readonly"):
            _ = reader.execute("delete from samples")


def _maintenance(db_path: Path, pipe: MessagePipe) -> None:
    pipe.send("ready")
    assert pipe.poll(10)
    assert pipe.recv() == "start"
    pipe.send("attempting")
    with exclusive_database_maintenance(db_path):
        pipe.send("acquired")


def test_live_reader_serializes_maintenance_in_another_process(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    context = multiprocessing.get_context("spawn")
    parent, child = context.Pipe()
    process = context.Process(target=_maintenance, args=(db_path, child))
    process.start()
    child.close()
    try:
        _receive(parent, "ready")
        with connect_live_readonly_database(db_path):
            for lock in (database_lifecycle_lock, database_access_lock):
                with (
                    pytest.raises(BlockingIOError),
                    lock(
                        db_path,
                        exclusive=True,
                        create=False,
                        nonblocking=True,
                    ),
                ):
                    pass
            parent.send("start")
            _receive(parent, "attempting")
            assert not parent.poll(0.2)
        _receive(parent, "acquired")
    finally:
        process.join(timeout=10)
        if process.is_alive():
            process.terminate()
            process.join(timeout=10)
        parent.close()
        assert process.exitcode == 0


def test_maintenance_rejects_live_query_without_empty_result(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with exclusive_database_maintenance(db_path), pytest.raises(BlockingIOError):
        _ = _point_count(db_path, "api")


@pytest.mark.parametrize("mode", ["delete", "wal"])
def test_immutable_snapshot_still_excludes_live_writer(
    tmp_path: Path, mode: str
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with (
        held_writer(db_path, mode),
        pytest.raises(BlockingIOError),
        connect_readonly_database(db_path),
    ):
        pass
    with connect_readonly_database(db_path) as reader:
        assert reader.execute("select count(*) from samples").fetchone() is not None


def test_sidecar_free_wal_requires_writer_preparation_without_mutation(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with held_writer(db_path, "wal"):
        pass
    before = {
        path.name: (path.stat().st_mode, path.read_bytes())
        for path in tmp_path.iterdir()
    }
    with (
        pytest.raises(OSError, match="existing WAL"),
        connect_live_readonly_database(db_path),
    ):
        pass
    assert {
        path.name: (path.stat().st_mode, path.read_bytes())
        for path in tmp_path.iterdir()
    } == before


@pytest.mark.parametrize(
    ("target", "attack"),
    [
        ("database", "symlink"),
        ("database", "hardlink"),
        ("parent", "symlink"),
        ("sidecar", "symlink"),
        ("sidecar", "hardlink"),
    ],
)
def test_live_reader_rejects_file_aliases(
    tmp_path: Path, target: str, attack: str
) -> None:
    directory = tmp_path / "store"
    directory.mkdir(mode=0o700)
    db_path = initialized_fixture_db(directory)
    if target == "parent":
        displaced = tmp_path / "original"
        _ = directory.rename(displaced)
        directory.symlink_to(displaced, target_is_directory=True)
    else:
        path = db_path if target == "database" else Path(f"{db_path}-journal")
        if target == "sidecar":
            _ = path.write_bytes(b"synthetic")
            path.chmod(0o600)
        displaced = directory / "original"
        if attack == "hardlink":
            os.link(path, displaced)
        else:
            _ = path.rename(displaced)
            path.symlink_to(displaced)
    with (
        pytest.raises(OSError, match=r"symlink|invalid|Too many levels"),
        connect_live_readonly_database(db_path),
    ):
        pass


@pytest.mark.parametrize("target", ["database", "parent"])
@pytest.mark.parametrize("phase", ["validation", "sqlite_open"])
def test_live_reader_rejects_path_swap_after_lock_acquisition(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    target: str,
    phase: str,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    original_connect = sqlite3.connect
    original_validate = require_live_readable_database

    def swap_path() -> None:
        if target == "parent":
            _ = tmp_path.rename(tmp_path.with_name(f"{tmp_path.name}-original"))
            tmp_path.mkdir(mode=0o700)
        else:
            _ = db_path.rename(tmp_path / "original.sqlite")
        _ = db_path.write_bytes(b"")

    def swapped_validate(path: Path) -> os.stat_result:
        swap_path()
        return original_validate(path)

    def swapped_connect(
        database: str, *, uri: bool, timeout: float
    ) -> sqlite3.Connection:
        swap_path()
        return original_connect(database, uri=uri, timeout=timeout)

    if phase == "validation":
        monkeypatch.setattr(
            database_module, "require_live_readable_database", swapped_validate
        )
    else:
        monkeypatch.setattr(sqlite3, "connect", swapped_connect)
    with (
        pytest.raises(OSError, match="path changed"),
        connect_live_readonly_database(db_path),
    ):
        pass


@pytest.mark.parametrize("mode", ["delete", "wal"])
def test_repeated_live_reads_bound_descriptors_and_release_them_on_close(
    tmp_path: Path,
    mode: str,
) -> None:
    descriptor_directory = Path("/dev/fd")
    if not descriptor_directory.is_dir():
        pytest.skip("descriptor enumeration requires /dev/fd")
    db_path = initialized_fixture_db(tmp_path)
    before = len(tuple(descriptor_directory.iterdir()))
    with connect_database(db_path) as writer:
        assert writer.execute(f"pragma journal_mode={mode}").fetchone() == (mode,)
        _ = writer.execute("begin immediate")
        active = len(tuple(descriptor_directory.iterdir()))
        for _ in range(20):
            assert _point_count(db_path, "api") == 1
        assert len(tuple(descriptor_directory.iterdir())) <= active + 4
        _assert_sqlite_lock_held(db_path, "begin immediate")
    assert len(tuple(descriptor_directory.iterdir())) == before


def test_sqlite_exclusive_writer_remains_unavailable_with_bounded_timeout(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with held_writer(db_path, "delete") as writer:
        writer.send("exclusive")
        _receive(writer, "exclusive")
        with connect_live_readonly_database(db_path) as reader:
            assert reader.execute("pragma busy_timeout").fetchone() == (1000,)
            with pytest.raises(sqlite3.OperationalError, match="locked"):
                _ = reader.execute("select count(*) from samples")


def test_default_live_read_does_not_change_files_or_modes(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with held_writer(db_path, "delete"):
        before = {
            path.name: (path.stat().st_mode, path.stat().st_mtime_ns, path.read_bytes())
            for path in tmp_path.iterdir()
        }
        assert _point_count(db_path, "api") == 1
        assert {
            path.name: (path.stat().st_mode, path.stat().st_mtime_ns, path.read_bytes())
            for path in tmp_path.iterdir()
        } == before


def test_live_query_does_not_release_same_process_writers_sqlite_lock(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with connect_database(db_path) as writer:
        _ = writer.execute("begin immediate")
        assert _point_count(db_path, "api") == 1
        _assert_sqlite_lock_held(db_path, "begin immediate")


def test_same_process_writer_does_not_release_live_readers_sqlite_lock(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with connect_live_readonly_database(db_path) as reader:
        assert fetch_one_int(reader, "select count(*) from samples") > 0
        with connect_database(db_path):
            pass
        assert _point_count(db_path, "api") == 1
        _assert_sqlite_lock_held(db_path, "begin exclusive")


def _assert_sqlite_lock_held(db_path: Path, statement: str) -> None:
    probe = run(
        [
            sys.executable,
            "-c",
            "import sqlite3,sys; c=sqlite3.connect(sys.argv[1],timeout=0); c.execute(sys.argv[2]); c.rollback()",  # noqa: E501
            str(db_path),
            statement,
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert probe.returncode != 0, "another connection released the SQLite lock"
    assert "database is locked" in probe.stderr


@pytest.mark.parametrize(
    "target", ["parent", "access.lock", "lifecycle.lock", "-journal"]
)
def test_live_reader_rejects_insecure_paths_without_repair(
    tmp_path: Path, target: str
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    if target == "parent":
        path = tmp_path
    elif target == "-journal":
        path = Path(f"{db_path}{target}")
        _ = path.write_bytes(b"synthetic")
    else:
        path = Path(f"{db_path}.{target}")
    path.chmod(0o777 if target == "parent" else 0o666)
    before = path.stat().st_mode
    with (
        pytest.raises(OSError, match=r"private|writable"),
        connect_live_readonly_database(db_path),
    ):
        pass
    assert path.stat().st_mode == before

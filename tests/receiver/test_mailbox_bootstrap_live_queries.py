from __future__ import annotations

import json
import os
import sys
from contextlib import contextmanager
from subprocess import CompletedProcess, run
from threading import Event, Thread
from typing import TYPE_CHECKING, cast

import pytest
from pydantic import TypeAdapter

import health_bridge.receiver.mailbox_runtime as runtime_module
from health_bridge.mailbox.connections import MailboxConnectionStore
from health_bridge.mcp.types import (
    required_list,
    required_object,
    required_string,
)
from health_bridge.queries import get_timeseries
from health_bridge.queries.models import TimeseriesResult
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.storage.database import (
    connect_live_readonly_database,
    connect_readonly_database,
    exclusive_database_maintenance,
)
from health_bridge.storage.sqlite_rows import fetch_one_int
from tests.fixture_helpers import initialized_fixture_db
from tests.queries.test_live_reads import END, START, held_writer

if TYPE_CHECKING:
    import sqlite3
    from collections.abc import Callable, Generator
    from contextlib import AbstractContextManager
    from pathlib import Path

    from health_bridge.mcp.types import JsonObject


CLI = [sys.executable, "-c", "from health_bridge.cli import run; run()"]


def _consumer(db: Path, surface: str) -> CompletedProcess[str]:
    arguments = [
        "query",
        "timeseries",
        "--types",
        "steps",
        "--start-time",
        START,
        "--end-time",
        END,
        "--db",
        str(db),
    ]
    requests = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {
                    "name": "bootstrap-concurrency-regression",
                    "version": "1",
                },
            },
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {
            "jsonrpc": "2.0",
            "id": 2,
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
    ]
    if surface == "mcp":
        arguments = ["mcp", "start", "--db", str(db)]
    return run(
        [*CLI, *arguments],
        input="\n".join(json.dumps(request) for request in requests) + "\n"
        if surface == "mcp"
        else None,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def _mcp_response(result: CompletedProcess[str]) -> JsonObject:
    responses = [
        cast("JsonObject", TypeAdapter(dict[str, object]).validate_json(line))
        for line in result.stdout.splitlines()
    ]
    return next(response for response in responses if response.get("id") == 2)


def _data(result: CompletedProcess[str], surface: str) -> TimeseriesResult:
    assert result.returncode == 0, result.stderr
    if surface == "cli":
        return TimeseriesResult.model_validate_json(result.stdout)
    response = _mcp_response(result)
    assert "result" in response, response
    content = required_list(required_object(response["result"])["content"])
    return TimeseriesResult.model_validate_json(
        required_string(required_object(content[0])["text"])
    )


def _worker(db: Path, home: Path) -> runtime_module.MailboxRuntimeWorker:
    root = home / "provider"
    root.mkdir(mode=0o700)
    return runtime_module.MailboxRuntimeWorker(
        db_path=db,
        mailbox_root=root,
        pairing_keys=MailboxKeyStore.production(),
        pairing_connections=MailboxConnectionStore.production(),
    )


@contextmanager
def _held_bootstrap(
    worker: runtime_module.MailboxRuntimeWorker,
    monkeypatch: pytest.MonkeyPatch,
) -> Generator[list[tuple[int, int, bool]], None, None]:
    entered = Event()
    release = Event()
    errors: list[BaseException] = []
    snapshots: list[tuple[int, int, bool]] = []

    def observe(
        factory: Callable[[Path], AbstractContextManager[sqlite3.Connection]],
    ) -> Callable[[Path], AbstractContextManager[sqlite3.Connection]]:
        @contextmanager
        def boundary(db: Path) -> Generator[sqlite3.Connection, None, None]:
            # Both factories and their OS/SQLite locks are real, unmodified code.
            with factory(db) as connection:
                before = fetch_one_int(connection, "select count(*) from samples")
                assert connection.execute("pragma query_only").fetchone() == (1,)
                entered.set()
                assert release.wait(30), "bootstrap observer was not released"
                yield connection
                snapshots.append(
                    (
                        before,
                        fetch_one_int(connection, "select count(*) from samples"),
                        connection.in_transaction,
                    )
                )

        return boundary

    monkeypatch.setattr(
        runtime_module,
        "connect_readonly_database",
        observe(connect_readonly_database),
        raising=False,
    )
    monkeypatch.setattr(
        runtime_module,
        "connect_live_readonly_database",
        observe(connect_live_readonly_database),
        raising=False,
    )

    def bootstrap() -> None:
        try:
            worker.run_once()
        except BaseException as error:  # noqa: BLE001
            errors.append(error)

    thread = Thread(target=bootstrap)
    thread.start()
    try:
        assert entered.wait(10), errors
        yield snapshots
    finally:
        release.set()
        thread.join(15)
        assert not thread.is_alive(), "bootstrap retained its owner after release"
        assert not errors, errors


@pytest.mark.parametrize("surface", ["cli", "mcp"])
def test_native_bootstrap_allows_actual_query_while_its_read_is_held(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    surface: str,
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    db = initialized_fixture_db(tmp_path)
    expected = get_timeseries(db, ("steps",), START, END)
    assert len(expected.points) == 1
    worker = _worker(db, tmp_path)
    with _held_bootstrap(worker, monkeypatch):
        actual = _data(_consumer(db, surface), surface)
        assert actual == expected  # Includes time, source, unit and value.
    assert _data(_consumer(db, surface), surface) == expected


@pytest.mark.parametrize("mode", ["delete", "wal"])
@pytest.mark.parametrize("surface", ["cli", "mcp"])
def test_native_bootstrap_and_actual_query_share_an_uncommitted_writer(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    mode: str,
    surface: str,
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    db = initialized_fixture_db(tmp_path)
    expected = get_timeseries(db, ("steps",), START, END)
    assert len(expected.points) == 1
    worker = _worker(db, tmp_path)
    with held_writer(db, mode) as writer:
        writer.send("stage")
        assert writer.poll(10)
        assert writer.recv() == "stage"
        with _held_bootstrap(worker, monkeypatch):
            assert _data(_consumer(db, surface), surface) == expected
        writer.send("commit")
        assert writer.poll(10)
        assert writer.recv() == "commit"
        assert get_timeseries(db, ("steps",), START, END).points == ()


def test_native_bootstrap_keeps_readonly_snapshot_across_wal_commit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    db = initialized_fixture_db(tmp_path)
    worker = _worker(db, tmp_path)
    with held_writer(db, "wal") as writer:
        with _held_bootstrap(worker, monkeypatch) as snapshots:
            writer.send("stage")
            assert writer.poll(10)
            assert writer.recv() == "stage"
            writer.send("commit")
            assert writer.poll(10)
            assert writer.recv() == "commit"
            assert get_timeseries(db, ("steps",), START, END).points == ()
        assert len(snapshots) == 1
        before, after, transactional = snapshots[0]
        assert before == after
        assert before > 0
        assert transactional


@pytest.mark.parametrize("surface", ["cli", "mcp"])
@pytest.mark.parametrize("owner", ["snapshot", "maintenance"])
def test_exclusive_database_owner_still_refuses_bootstrap_and_real_query(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    surface: str,
    owner: str,
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    db = initialized_fixture_db(tmp_path)
    worker = _worker(db, tmp_path)
    expected = get_timeseries(db, ("steps",), START, END)
    held = (
        connect_readonly_database
        if owner == "snapshot"
        else exclusive_database_maintenance
    )
    with held(db):
        worker.run_once()  # Contention is a deferred poll, not terminal death.
        assert not worker.terminal_error()
        result = _consumer(db, surface)
        if surface == "cli":
            assert result.returncode != 0
            assert "BlockingIOError" in result.stderr
        else:
            assert result.returncode == 0
            assert _mcp_response(result)["error"] == {
                "code": -32000,
                "message": "Health Bridge database is unavailable.",
            }
    assert _data(_consumer(db, surface), surface) == expected


@pytest.mark.parametrize("unsafe", ["symlink", "hardlink", "permissions"])
def test_native_bootstrap_refuses_unsafe_database_without_repair(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    unsafe: str,
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    db = initialized_fixture_db(tmp_path)
    worker = _worker(db, tmp_path)
    if unsafe == "symlink":
        target = db.with_name("foreign.sqlite")
        _ = db.rename(target)
        db.symlink_to(target)
    elif unsafe == "hardlink":
        os.link(db, db.with_name("foreign.sqlite"))
    else:
        db.parent.chmod(0o777)
    before = db.lstat()
    parent_mode = db.parent.stat().st_mode
    contents = db.read_bytes()
    with pytest.raises((OSError, ValueError)):
        worker.run_once()
    after = db.lstat()
    assert (before.st_ino, before.st_mode, before.st_nlink) == (
        after.st_ino,
        after.st_mode,
        after.st_nlink,
    )
    assert db.read_bytes() == contents
    assert db.parent.stat().st_mode == parent_mode

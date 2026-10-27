import json
import sqlite3
import subprocess
import sys
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from threading import Event
from typing import cast

import pytest
from pydantic import TypeAdapter

import health_bridge.receiver.mailbox_runtime as runtime
from health_bridge.mcp.types import (
    JsonObject,
    required_list,
    required_object,
    required_string,
)
from health_bridge.queries.models import SyncedMetricsResult
from health_bridge.receiver.delivery_acceptance import DeliveryAcceptanceService
from health_bridge.receiver.mailbox_runtime import MailboxRuntimeWorker
from health_bridge.storage.database import (
    connect_database,
    connect_live_readonly_database,
    exclusive_database_maintenance,
    initialize_database,
)
from tests.receiver.delivery_acceptance_support import NOW_MS
from tests.receiver.native_pairing_support import LegacyPeer, stage_native


def test_bootstrap_worker_retries_real_sqlite_contention(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Given a real rollback-journal EXCLUSIVE writer and the real bootstrap reader.
    peer = LegacyPeer(tmp_path)
    _ = stage_native(peer)
    root = tmp_path / "provider"
    root.mkdir()
    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        poll_interval_seconds=0.01,
    )
    attempted, resume, recovered = Event(), Event(), Event()
    failures: list[OSError | sqlite3.Error] = []
    run_once = worker.run_once

    def observe_cycle() -> None:
        first = not attempted.is_set()
        try:
            run_once()
            if not first:
                recovered.set()
        except (OSError, sqlite3.Error) as exc:
            failures.append(exc)
            raise
        finally:
            if first:
                attempted.set()
                assert resume.wait(5), "test did not release the contended cycle"

    monkeypatch.setattr(worker, "run_once", observe_cycle)
    try:
        with connect_database(peer.db) as writer:
            _ = writer.execute("begin exclusive")
            # When a real worker cycle exceeds the SQLite reader's busy timeout.
            worker.start()
            assert attempted.wait(5), "worker did not attempt the locked read"
            # Then the original SQLite busy code survives the query wrapper.
            assert len(failures) == 1
            failure = failures[0]
            assert isinstance(failure, sqlite3.OperationalError)
            assert failure.sqlite_errorcode == sqlite3.SQLITE_BUSY
            writer.rollback()
        resume.set()
        assert recovered.wait(5), "worker did not recover after contention ended"
    finally:
        resume.set()
        stopped = worker.stop()
    assert stopped
    assert not worker.terminal_error()
    assert worker.health_error() is None


def test_bootstrap_shared_read_coexists_with_writer(tmp_path: Path) -> None:
    db = tmp_path / "health.sqlite"
    initialize_database(db)
    with connect_database(db) as writer:
        _ = writer.execute("begin immediate")
        try:
            with connect_live_readonly_database(db) as reader:
                assert reader.execute(
                    "select count(*) from receiver_devices"
                ).fetchone() == (0,)
                with pytest.raises(sqlite3.OperationalError, match="readonly"):
                    _ = reader.execute("delete from receiver_devices")
        except BlockingIOError:
            pytest.fail("bootstrap read requires an exclusive snapshot lock")


def test_bootstrap_read_respects_exclusive_maintenance(tmp_path: Path) -> None:
    db = tmp_path / "health.sqlite"
    initialize_database(db)
    with (
        exclusive_database_maintenance(db),
        pytest.raises(BlockingIOError),
        connect_live_readonly_database(db),
    ):
        pass


def test_bootstrap_preserves_current_readonly_wal_refusal(tmp_path: Path) -> None:
    db = tmp_path / "health.sqlite"
    initialize_database(db)
    with connect_database(db) as writer:
        assert writer.execute("pragma journal_mode=wal").fetchone() == ("wal",)
        with (
            pytest.raises(OSError, match="unavailable"),
            connect_live_readonly_database(db),
        ):
            pass


@pytest.mark.parametrize("surface", ["cli", "mcp"])
def test_running_bootstrap_and_writer_leave_installed_queries_available(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    surface: str,
) -> None:
    peer = LegacyPeer(tmp_path)
    trusted = peer.register()
    assert (
        DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
        .accept(peer.upload(trusted))
        .receipt.result
        == "committed"
    )
    root = tmp_path / "provider"
    root.mkdir()
    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        poll_interval_seconds=0.01,
    )
    entered, release = Event(), Event()

    @contextmanager
    def held_read(path: Path) -> Generator[sqlite3.Connection, None, None]:
        with connect_live_readonly_database(path) as database:
            entered.set()
            assert release.wait(15)
            yield database

    monkeypatch.setattr(runtime, "connect_live_readonly_database", held_read)
    try:
        with held_writer(peer.db):
            worker.start()
            assert entered.wait(5)
            arguments = ["query", "synced-metrics", "--db", str(peer.db)]
            request_input = None
            if surface == "mcp":
                arguments = ["mcp", "start", "--db", str(peer.db)]
                requests: list[JsonObject] = [
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2024-11-05",
                            "capabilities": {},
                            "clientInfo": {"name": "synthetic", "version": "1"},
                        },
                    },
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {"name": "list_synced_metrics", "arguments": {}},
                    },
                ]
                request_input = "\n".join(json.dumps(item) for item in requests) + "\n"
            result = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    "from health_bridge.cli import run; run()",
                    *arguments,
                ],
                input=request_input,
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            assert result.returncode == 0, result.stderr
            payload = result.stdout
            if surface == "mcp":
                responses = [
                    cast(
                        "JsonObject", TypeAdapter(dict[str, object]).validate_json(line)
                    )
                    for line in payload.splitlines()
                ]
                response = next(item for item in responses if item.get("id") == 2)
                content = required_list(required_object(response["result"])["content"])
                payload = required_string(required_object(content[0])["text"])
            assert (
                SyncedMetricsResult.model_validate_json(payload).metrics[0].record_count
                == 1
            )
            assert worker.is_alive()
    finally:
        release.set()
        assert worker.stop()


@contextmanager
def held_writer(db: Path) -> Generator[None, None, None]:
    with connect_database(db) as writer:
        _ = writer.execute("begin immediate")
        _ = writer.execute("update samples set value = value + 1")
        try:
            yield
        finally:
            writer.rollback()

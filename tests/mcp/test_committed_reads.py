import json
import sqlite3
import sys
from pathlib import Path
from subprocess import run

import pytest

import health_bridge.status as status_module
from health_bridge.mcp.server import dispatch_request
from health_bridge.mcp.types import required_object
from health_bridge.storage.database import (
    connect_database,
    connect_readonly_database,
    exclusive_database_maintenance,
)
from health_bridge.storage.sqlite_rows import fetch_one_int
from tests.fixture_helpers import initialized_fixture_db
from tests.mcp.committed_read_support import (
    JSON_OBJECT,
    WRITER,
    cli_command,
    line_process,
    receive,
    send,
    status_payload,
    status_request,
)


def test_cli_and_mcp_read_committed_rows_during_receiver_write(tmp_path: Path) -> None:
    # Given: the real storage writer has changed rows but has not committed.
    db_path = initialized_fixture_db(tmp_path)
    previous = status_payload(dispatch_request(db_path, status_request()))
    with line_process([sys.executable, "-u", "-c", WRITER, str(db_path)]) as writer:
        assert receive(writer) == "ready"
        # When: independent CLI and MCP processes read the held transaction.
        cli = run(
            cli_command(db_path), capture_output=True, text=True, timeout=5, check=False
        )
        with line_process(
            ["health-bridge", "mcp", "start", "--db", str(db_path)]
        ) as mcp:
            response = JSON_OBJECT.validate_json(
                send(mcp, json.dumps(status_request()))
            )
            # Then: both expose the previous complete committed epoch.
            assert cli.returncode == 0, "CLI must serve the committed snapshot"
            assert cli.stderr == ""
            assert JSON_OBJECT.validate_json(cli.stdout) == previous
            assert status_payload(response) == previous
            assert send(writer, "commit") == "committed"
            current = status_payload(
                JSON_OBJECT.validate_json(send(mcp, json.dumps(status_request(2))))
            )
            counts = required_object(current["counts"])
            assert counts["samples"] == counts["workouts"] == 0
            assert current != previous
        next_cli = run(
            cli_command(db_path), capture_output=True, text=True, timeout=5, check=False
        )
        assert next_cli.returncode == 0
        assert next_cli.stderr == ""
        assert JSON_OBJECT.validate_json(next_cli.stdout) == current


def test_mcp_component_selects_hold_one_committed_epoch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given: a separate writer is ready to commit between status SELECTs.
    db_path = initialized_fixture_db(tmp_path)
    previous = status_payload(dispatch_request(db_path, status_request()))
    original = fetch_one_int
    outcomes: list[str] = []
    with line_process([sys.executable, "-u", "-c", WRITER, str(db_path)]) as writer:
        assert receive(writer) == "ready"

        def between_selects(connection: sqlite3.Connection, sql: str) -> int:
            value = original(connection, sql)
            if sql == status_module.SAMPLE_COUNT_SQL:
                outcomes.append(send(writer, "commit"))
            return value

        monkeypatch.setattr(status_module, "fetch_one_int", between_selects)
        # When: dispatch runs the real SQL, with only an inter-SELECT barrier added.
        response = dispatch_request(db_path, status_request())
        # Then: rollback-journal commit waits for the entire response transaction.
        assert status_payload(response) == previous
        assert outcomes == ["blocked"]
        assert send(writer, "commit") == "committed"
    monkeypatch.setattr(status_module, "fetch_one_int", original)
    current = status_payload(dispatch_request(db_path, status_request()))
    counts = required_object(current["counts"])
    assert counts["samples"] == counts["workouts"] == 0


def test_same_process_reader_cleanup_preserves_writer_record_lock(
    tmp_path: Path,
) -> None:
    # Given: a real managed writer holds a SQLite RESERVED lock in this process.
    db_path = initialized_fixture_db(tmp_path)
    previous = status_payload(dispatch_request(db_path, status_request()))
    probe = """
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1], timeout=0)
try:
    connection.execute('begin immediate')
except sqlite3.OperationalError:
    print('blocked')
else:
    print('acquired')
finally:
    connection.close()
"""
    with connect_database(db_path) as writer:
        _ = writer.execute("begin immediate")
        _ = writer.execute("delete from samples")
        # When: a reader closes, a second writer opens/closes, and strict access fails.
        response = dispatch_request(db_path, status_request())
        assert status_payload(response) == previous
        with connect_database(db_path) as other:
            assert other.execute("select count(*) from samples").fetchone() != (0,)
        with pytest.raises(BlockingIOError), connect_readonly_database(db_path):
            pass
        result = run(
            [sys.executable, "-c", probe, str(db_path)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        # Then: no non-SQLite descriptor close has released the writer's lock.
        assert result.returncode == 0
        assert result.stderr == ""
        assert result.stdout.strip() == "blocked"
    result = run(
        [sys.executable, "-c", probe, str(db_path)],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    assert result.returncode == 0
    assert result.stderr == ""
    assert result.stdout.strip() == "acquired"


def test_stdio_operational_refusal_then_valid_read_in_same_process(
    tmp_path: Path,
) -> None:
    # Given: maintenance excludes ordinary reads.
    db_path = initialized_fixture_db(tmp_path)
    with line_process(["health-bridge", "mcp", "start", "--db", str(db_path)]) as mcp:
        with exclusive_database_maintenance(db_path):
            # When: an operational request is refused, then retried after maintenance.
            refused = JSON_OBJECT.validate_json(send(mcp, json.dumps(status_request())))
            cli = run(
                cli_command(db_path),
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        valid = JSON_OBJECT.validate_json(send(mcp, json.dumps(status_request(2))))
        # Then: the same stdio process survives with redacted protocol and no stderr.
        assert refused == {
            "jsonrpc": "2.0",
            "id": 1,
            "error": {
                "code": -32000,
                "message": "Health Bridge database is unavailable.",
            },
        }
        assert cli.returncode == 1
        assert cli.stdout == ""
        assert cli.stderr == "Health Bridge database is unavailable.\n"
        assert valid["id"] == 2
        assert "counts" in status_payload(valid)

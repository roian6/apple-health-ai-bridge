import os
import sys
from pathlib import Path
from subprocess import run

import pytest

from health_bridge.queries.catalog import list_synced_metrics
from health_bridge.queries.models import SyncedMetricsResult
from tests.fixture_helpers import initialized_fixture_db
from tests.mcp.committed_read_support import WRITER, line_process, receive, send


def test_query_cli_reads_committed_metrics_during_receiver_write(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    previous = list_synced_metrics(db_path)
    with line_process([sys.executable, "-u", "-c", WRITER, str(db_path)]) as writer:
        assert receive(writer) == "ready"
        result = run(
            ["health-bridge", "query", "synced-metrics", "--db", str(db_path)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        assert result.returncode == 0
        assert result.stderr == ""
        assert SyncedMetricsResult.model_validate_json(result.stdout) == previous
        assert send(writer, "commit") == "committed"
    assert list_synced_metrics(db_path) != previous


def test_query_cli_bounds_exclusive_sqlite_contention(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    exclusive_writer = WRITER.replace("begin immediate", "begin exclusive")
    with line_process(
        [sys.executable, "-u", "-c", exclusive_writer, str(db_path)],
    ) as writer:
        assert receive(writer) == "ready"
        result = run(
            ["health-bridge", "query", "synced-metrics", "--db", str(db_path)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        assert result.returncode == 1
        assert result.stdout == ""
        assert result.stderr == "Health Bridge database is unavailable.\n"


@pytest.mark.parametrize("target", ["database", "journal"])
def test_query_cli_refuses_fifo_without_blocking(tmp_path: Path, target: str) -> None:
    db_path = initialized_fixture_db(tmp_path)
    path = db_path if target == "database" else Path(f"{db_path}-journal")
    if target == "database":
        path.unlink()
    os.mkfifo(path, 0o600)
    result = run(
        ["health-bridge", "query", "synced-metrics", "--db", str(db_path)],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    assert result.returncode == 1
    assert result.stdout == ""
    assert result.stderr == "Health Bridge database is unavailable.\n"

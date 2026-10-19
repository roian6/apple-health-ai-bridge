import os
import sys
from pathlib import Path
from subprocess import run
from typing import Final

import pytest

from health_bridge.mcp.server import dispatch_request
from health_bridge.storage.database import connect_database
from tests.fixture_helpers import initialized_fixture_db
from tests.mcp.committed_read_support import status_request

PROBE: Final = """
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1], timeout=0)
try:
    connection.execute('begin immediate')
except sqlite3.OperationalError:
    sys.exit(0)
else:
    sys.exit(1)
finally:
    connection.close()
"""


def assert_writer_is_locked(db_path: Path) -> None:
    probe = run(
        [sys.executable, "-c", PROBE, str(db_path)],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    assert probe.returncode == 0, "another process acquired the live writer's lock"
    assert probe.stdout == probe.stderr == ""


@pytest.mark.parametrize("suffix", [".access.lock", ".lifecycle.lock"])
def test_rejected_lock_hardlink_keeps_same_process_writer_lock(
    tmp_path: Path,
    suffix: str,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    lock_path = Path(f"{db_path}{suffix}")
    displaced = tmp_path / "displaced.lock"
    with connect_database(db_path) as writer:
        _ = writer.execute("begin immediate")
        _ = writer.execute("delete from samples")
        _ = lock_path.rename(displaced)
        os.link(db_path, lock_path)
        try:
            response = dispatch_request(db_path, status_request())
            assert "error" in response
        finally:
            lock_path.unlink()
            _ = displaced.rename(lock_path)
        assert_writer_is_locked(db_path)


def test_wal_refusal_and_sidecar_protection_preserve_writer_lock(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with connect_database(db_path) as setup:
        assert setup.execute("pragma journal_mode = wal").fetchone() == ("wal",)
    with connect_database(db_path) as writer:
        _ = writer.execute("begin immediate")
        _ = writer.execute("delete from samples")
        assert "error" in dispatch_request(db_path, status_request())
        with connect_database(db_path) as other:
            assert other.execute("select 1").fetchone() == (1,)
        assert_writer_is_locked(db_path)

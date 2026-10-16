import subprocess
import sys
from pathlib import Path

import pytest

from tests.fixture_helpers import initialized_fixture_db


@pytest.mark.parametrize("surface", ["query", "mcp", "cli"])
def test_cold_public_read_surface_reads_saved_synthetic_records(
    tmp_path: Path, surface: str
) -> None:
    db = initialized_fixture_db(tmp_path)
    programs = {
        "query": (
            "from health_bridge.queries import list_synced_metrics; "
            "from pathlib import Path; import sys; "
            "assert any(m.record_count for m in "
            "list_synced_metrics(Path(sys.argv[1])).metrics)"
        ),
        "mcp": (
            "from health_bridge.mcp.server import mcp_smoke_result; "
            "from pathlib import Path; import sys; "
            "assert mcp_smoke_result(Path(sys.argv[1]))"
        ),
        "cli": "from health_bridge.cli import run; run()",
    }
    args = [sys.executable, "-c", programs[surface]]
    args += (
        ["query", "synced-metrics", "--db", str(db)] if surface == "cli" else [str(db)]
    )
    completed = subprocess.run(
        args, capture_output=True, text=True, timeout=20, check=False
    )
    assert completed.returncode == 0, completed.stderr

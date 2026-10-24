from pathlib import Path
from subprocess import run

import pytest

from health_bridge.ingest import ingest_batch
from health_bridge.mcp.server import dispatch_request
from health_bridge.mcp.types import required_list, required_object
from health_bridge.queries.models import Period, SyncedMetricsResult
from health_bridge.storage import initialize_database
from tests.mcp.committed_read_support import JSON_OBJECT
from tests.mcp.test_mcp_server import ToolCallResponse
from tests.queries.catalogue_fixtures import catalogue_batch


@pytest.mark.parametrize("has_records", [True, False])
def test_catalogue_cli_and_mcp_serialize_explicit_coverage_and_legacy_period(
    tmp_path: Path,
    has_records: bool,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    initialize_database(db)
    if has_records:
        for day in (1, 7):
            _ = ingest_batch(db, catalogue_batch(day), "synthetic-catalogue")

    response = ToolCallResponse.model_validate(
        dispatch_request(
            db,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": "list_synced_metrics", "arguments": {}},
            },
        )
    )
    text = response.result.content[0].text
    mcp = SyncedMetricsResult.model_validate_json(text)
    cli = run(
        ["health-bridge", "query", "synced-metrics", "--db", str(db)],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )

    assert cli.returncode == 0
    assert cli.stderr == ""
    assert SyncedMetricsResult.model_validate_json(cli.stdout) == mcp
    assert JSON_OBJECT.validate_json(cli.stdout) == JSON_OBJECT.validate_json(text)
    wire = JSON_OBJECT.validate_json(text)
    if has_records:
        assert mcp.period == Period(
            start="2026-06-07T00:00:00Z", end="2026-06-08T00:00:00Z"
        )
        assert mcp.stored_coverage == Period(
            start="2026-06-01T12:00:00Z", end="2026-06-07T12:00:05Z"
        )
        assert mcp.latest_sync_window == mcp.period
        metric = required_object(required_list(wire["metrics"])[0])
        assert metric["first_record_start"] == "2026-06-01T12:00:00Z"
        assert metric["latest_record_end"] == "2026-06-07T12:00:05Z"
    else:
        assert wire["stored_coverage"] is None
        assert wire["latest_sync_window"] is None
        assert wire["period"] == {"start": "", "end": ""}


def test_catalogue_still_rejects_date_filter_arguments(tmp_path: Path) -> None:
    response = dispatch_request(
        tmp_path / "unused.sqlite",
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "list_synced_metrics",
                "arguments": {
                    "start_time": "2026-06-01T00:00:00Z",
                    "end_time": "2026-06-02T00:00:00Z",
                },
            },
        },
    )

    assert response["error"] == {
        "code": -32602,
        "message": "Invalid tool call arguments.",
    }

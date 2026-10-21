import json
from pathlib import Path
from subprocess import run

import pytest

from health_bridge.mcp.types import required_list, required_object, required_string
from tests.queries.test_latest_sleep_period import JSON_OBJECT, Session, sleep_db


@pytest.mark.parametrize("surface", ["cli", "stdio"])
def test_sleep_report_public_binary_returns_overlap_union(
    tmp_path: Path, surface: str
) -> None:
    start, end = "2026-06-11T00:00:00Z", "2026-06-11T03:00:00Z"
    db = sleep_db(
        tmp_path,
        (
            Session(
                start,
                end,
                (
                    ("core", start, "2026-06-11T02:00:00Z"),
                    ("deep", "2026-06-11T01:00:00Z", end),
                ),
            ),
        ),
    )
    before = db.read_bytes(), db.stat().st_mtime_ns, tuple(tmp_path.iterdir())
    arguments = {
        "timezone": "Asia/Kolkata",
        "local_date": "2026-06-11",
        "reference_time": "2026-06-11T04:00:00Z",
    }
    if surface == "cli":
        command = [
            "query",
            "sleep-report",
            "--db",
            str(db),
            "--timezone",
            arguments["timezone"],
            "--local-date",
            arguments["local_date"],
            "--reference-time",
            arguments["reference_time"],
        ]
        stdin = None
    else:
        command = ["mcp", "start", "--db", str(db)]
        stdin = (
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {"name": "get_sleep_report", "arguments": arguments},
                }
            )
            + "\n"
        )
    completed = run(
        ["uv", "run", "--no-sync", "health-bridge", *command],
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stderr
    assert completed.stderr == ""
    payload = JSON_OBJECT.validate_json(completed.stdout)
    if surface == "stdio":
        assert "result" in payload, payload
        content = required_list(required_object(payload["result"])["content"])
        payload = JSON_OBJECT.validate_json(
            required_string(required_object(content[0])["text"])
        )
    assert payload["recorded_asleep_seconds"] == 10800
    assert payload["local_date"] == "2026-06-11"
    assert len(required_list(payload["periods"])) == 1
    assert required_object(required_list(payload["periods"])[0])["evidence"] is None
    assert (db.read_bytes(), db.stat().st_mtime_ns, tuple(tmp_path.iterdir())) == before


def test_report_stdio_discovery_validation_and_detailed_cli_agree(
    tmp_path: Path,
) -> None:
    start, end = "2026-06-11T00:00:00Z", "2026-06-11T03:00:00Z"
    db = sleep_db(tmp_path, (Session(start, end, (("core", start, end),)),))
    before = db.read_bytes(), db.stat().st_mtime_ns, tuple(tmp_path.iterdir())
    arguments = {
        "timezone": "Asia/Seoul",
        "local_date": "2026-06-11",
        "reference_time": "2026-06-11T04:00:00Z",
        "include_intervals": True,
    }
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "get_sleep_report",
                "arguments": {**arguments, "local_date": "invalid"},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "get_sleep_report", "arguments": arguments},
        },
    ]
    mcp = run(
        ["uv", "run", "--no-sync", "health-bridge", "mcp", "start", "--db", str(db)],
        input="".join(json.dumps(request) + "\n" for request in requests),
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert mcp.returncode == 0, mcp.stderr
    assert mcp.stderr == ""
    replies = [JSON_OBJECT.validate_json(line) for line in mcp.stdout.splitlines()]
    assert len(replies) == 4
    tools = required_list(required_object(replies[1]["result"])["tools"])
    definition = next(
        required_object(tool)
        for tool in tools
        if required_object(tool)["name"] == "get_sleep_report"
    )
    assert required_object(definition["inputSchema"])["required"] == ["timezone"]
    assert required_object(definition["annotations"])["readOnlyHint"] is True
    assert replies[2]["error"] == {
        "code": -32602,
        "message": "Invalid tool call arguments.",
    }
    content = required_list(required_object(replies[3]["result"])["content"])
    payload = JSON_OBJECT.validate_json(
        required_string(required_object(content[0])["text"])
    )
    cli = run(
        [
            "uv",
            "run",
            "--no-sync",
            "health-bridge",
            "query",
            "sleep-report",
            "--db",
            str(db),
            "--timezone",
            "Asia/Seoul",
            "--local-date",
            "2026-06-11",
            "--reference-time",
            "2026-06-11T04:00:00Z",
            "--include-intervals",
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert cli.returncode == 0, cli.stderr
    assert cli.stderr == ""
    assert JSON_OBJECT.validate_json(cli.stdout) == payload
    period = required_object(required_list(payload["periods"])[0])
    assert required_object(period["evidence"])["asleep_intervals"] == [
        {"start": start, "end": end}
    ]
    assert (db.read_bytes(), db.stat().st_mtime_ns, tuple(tmp_path.iterdir())) == before


def test_report_cli_invalid_arguments_do_not_open_database(tmp_path: Path) -> None:
    completed = run(
        [
            "uv",
            "run",
            "--no-sync",
            "health-bridge",
            "query",
            "sleep-report",
            "--db",
            str(tmp_path / "missing.sqlite"),
            "--timezone",
            "UTC",
            "--local-date",
            "2026-02-30",
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert completed.returncode == 2
    assert "Invalid sleep report arguments" in completed.stderr
    assert "Traceback" not in completed.stderr
    assert not (tmp_path / "missing.sqlite").exists()

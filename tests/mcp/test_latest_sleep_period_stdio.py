import json
from pathlib import Path
from subprocess import run

from health_bridge.mcp.types import required_list, required_object, required_string
from tests.queries.test_latest_sleep_period import JSON_OBJECT, Session, sleep_db


def test_latest_sleep_cli_and_stdio_agree_and_leave_db_unchanged(
    tmp_path: Path,
) -> None:
    start, middle, end = (f"2026-06-11T{hour}:00:00Z" for hour in ("00", "01", "03"))
    db = sleep_db(
        tmp_path,
        (
            Session(
                start,
                end,
                (
                    ("core", start, "2026-06-11T02:00:00Z"),
                    ("deep", middle, end),
                ),
            ),
        ),
    )
    before = db.read_bytes(), db.stat().st_mtime_ns
    args = {"timezone": "Asia/Kolkata", "reference_time": "2026-06-11T04:00:00Z"}
    cli = run(
        [
            "uv",
            "run",
            "health-bridge",
            "query",
            "latest-sleep-period",
            "--db",
            str(db),
            "--timezone",
            args["timezone"],
            "--reference-time",
            args["reference_time"],
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    assert cli.returncode == 0, cli.stderr
    assert cli.stderr == ""
    payload = JSON_OBJECT.validate_json(cli.stdout)
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "get_latest_sleep_period",
                "arguments": {**args, "timezone": "Invalid/Zone"},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "get_latest_sleep_period", "arguments": args},
        },
    ]
    mcp = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db)],
        input="".join(json.dumps(request) + "\n" for request in requests),
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    assert mcp.returncode == 0, mcp.stderr
    assert mcp.stderr == ""
    responses = [JSON_OBJECT.validate_json(line) for line in mcp.stdout.splitlines()]
    assert len(responses) == 4
    tools = required_list(required_object(responses[1]["result"])["tools"])
    definition = next(
        required_object(tool)
        for tool in tools
        if required_object(tool)["name"] == "get_latest_sleep_period"
    )
    assert required_object(definition["annotations"])["readOnlyHint"] is True
    assert required_object(definition["inputSchema"])["required"] == [
        "timezone",
        "reference_time",
    ]
    assert responses[2]["error"] == {
        "code": -32602,
        "message": "Invalid tool call arguments.",
    }
    content = required_list(required_object(responses[3]["result"])["content"])
    assert (
        JSON_OBJECT.validate_json(required_string(required_object(content[0])["text"]))
        == payload
    )
    assert payload["asleep_seconds"] == 10800
    assert (db.read_bytes(), db.stat().st_mtime_ns) == before


def test_latest_sleep_cli_rejects_bad_timezone_without_traceback(
    tmp_path: Path,
) -> None:
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "query",
            "latest-sleep-period",
            "--db",
            str(tmp_path / "missing.sqlite"),
            "--timezone",
            "Invalid/Zone",
            "--reference-time",
            "2026-06-11T04:00:00Z",
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    assert result.returncode == 2
    assert "Invalid latest sleep arguments" in result.stderr
    assert "Traceback" not in result.stderr
    assert not (tmp_path / "missing.sqlite").exists()

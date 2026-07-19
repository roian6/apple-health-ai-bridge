from __future__ import annotations

from subprocess import run
from typing import TYPE_CHECKING, ClassVar

import pytest
from jsonschema import Draft202012Validator
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from health_bridge.mcp.server import dispatch_request
from health_bridge.mcp.tools import (
    DATE_RANGE_INPUT_SCHEMA,
    MCP_TOOL_DEFINITIONS,
    TIMESERIES_INPUT_SCHEMA,
    DateRangeArgs,
    TimeseriesArgs,
)
from health_bridge.mcp.types import required_object
from health_bridge.storage import initialize_database
from health_bridge.storage.database import connect_database
from tests.fixture_helpers import initialized_fixture_db

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.mcp.types import JsonObject, JsonValue


class McpTestModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class ToolListEntry(McpTestModel):
    name: str


class ToolListResult(McpTestModel):
    tools: list[ToolListEntry]


class ToolListResponse(McpTestModel):
    id: int
    result: ToolListResult


class InitializeResult(McpTestModel):
    protocol_version: str = Field(alias="protocolVersion")


class InitializeResponse(McpTestModel):
    id: int
    result: InitializeResult


class TextContent(McpTestModel):
    type: str
    text: str


class ToolCallResult(McpTestModel):
    content: list[TextContent]


class ToolCallResponse(McpTestModel):
    result: ToolCallResult


class ErrorPayload(McpTestModel):
    code: int
    message: str


class ErrorResponse(McpTestModel):
    id: int
    error: ErrorPayload


class MetricSummary(McpTestModel):
    type_code: str
    record_count: int


class SmokeCallResult(McpTestModel):
    metrics: list[MetricSummary]
    missing_data_notes: list[str]


class SmokeContextResult(McpTestModel):
    title: str
    has_store_counts: bool
    has_redaction_notes: bool
    forbidden_hits: list[str]


class TimeseriesPoint(McpTestModel):
    type_code: str


class TimeseriesCallPayload(McpTestModel):
    points: list[TimeseriesPoint]


class SupportedTimeseriesType(McpTestModel):
    type_code: str
    category: str
    aggregation: str


class SupportedTimeseriesPayload(McpTestModel):
    total_type_count: int
    types: list[SupportedTimeseriesType]
    missing_data_notes: list[str]


class SmokeOutput(McpTestModel):
    listed_tools: list[str]
    called_tool: str
    call_result: SmokeCallResult
    context_tool: str
    context_result: SmokeContextResult


class SmokeLatestSync(McpTestModel):
    status: str


class SmokeMetricStatus(McpTestModel):
    record_count: int


class SmokeCursorStatus(McpTestModel):
    cursor_kind: str
    updated_at: str


class SmokeBridgeStatus(McpTestModel):
    schema_id: str
    counts: dict[str, int]
    latest_sync: SmokeLatestSync
    metrics: dict[str, SmokeMetricStatus]
    sync_cursors: list[SmokeCursorStatus]


EXPECTED_TOOL_NAMES = (
    "get_bridge_status",
    "get_bridge_context_markdown",
    "list_supported_timeseries_types",
    "list_synced_metrics",
    "get_timeseries",
    "get_workouts",
    "get_sleep_summary",
    "get_daily_summary",
    "explain_sources",
)


def test_mcp_tool_definitions_expose_only_read_only_tools() -> None:
    # Given / When
    tool_names = {tool.name for tool in MCP_TOOL_DEFINITIONS}
    descriptions = " ".join(tool.description.lower() for tool in MCP_TOOL_DEFINITIONS)

    # Then
    assert tool_names == set(EXPECTED_TOOL_NAMES)
    assert "query_health_sql" not in tool_names
    assert "sql" not in descriptions
    assert "read-only" in descriptions
    assert "clinical interpretation" in descriptions


def test_mcp_dispatch_lists_and_calls_read_only_tool(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    list_response = ToolListResponse.model_validate(
        dispatch_request(
            db_path,
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        ),
    )
    call_response = ToolCallResponse.model_validate(
        dispatch_request(
            db_path,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "list_synced_metrics", "arguments": {}},
            },
        ),
    )
    payload = SmokeCallResult.model_validate_json(call_response.result.content[0].text)

    # Then
    assert list_response.id == 1
    assert list_response.result.tools[0].name == "get_bridge_status"
    assert call_response.result.content[0].type == "text"
    assert any(metric.type_code == "weight" for metric in payload.metrics)
    metrics_by_type = {metric.type_code: metric for metric in payload.metrics}
    assert metrics_by_type["workout"].record_count == 1
    assert metrics_by_type["sleep_analysis"].record_count == 1
    assert payload.missing_data_notes != []


def test_mcp_dispatch_calls_supported_timeseries_catalog(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    call_response = ToolCallResponse.model_validate(
        dispatch_request(
            db_path,
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {
                    "name": "list_supported_timeseries_types",
                    "arguments": {"category": "body"},
                },
            },
        ),
    )
    payload_text = call_response.result.content[0].text
    payload = SupportedTimeseriesPayload.model_validate_json(payload_text)
    types_by_code = {entry.type_code: entry for entry in payload.types}

    # Then
    assert payload.total_type_count == 80
    assert set(types_by_code) == {
        "body_fat_mass",
        "body_fat_percentage",
        "body_mass_index",
        "body_temperature",
        "height",
        "lean_body_mass",
        "skeletal_muscle_mass",
        "skin_temperature",
        "waist_circumference",
        "weight",
    }
    assert types_by_code["weight"].aggregation == "latest"
    assert all(entry.category == "body" for entry in payload.types)
    assert "metadata only" in payload.missing_data_notes[0]
    assert "token" not in payload_text
    assert "cursor" not in payload_text


def test_mcp_dispatch_rejects_malformed_tool_call_without_traceback(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    malformed_params: tuple[JsonValue, ...] = ({}, [], None, "bad")
    for params in malformed_params:
        # When
        response = dispatch_request(
            db_path,
            {
                "jsonrpc": "2.0",
                "id": 9,
                "method": "tools/call",
                "params": params,
            },
        )

        # Then
        assert response == {
            "jsonrpc": "2.0",
            "id": 9,
            "error": {"code": -32602, "message": "Invalid tool call arguments."},
        }


def test_mcp_dispatch_rejects_extra_tool_arguments_without_traceback(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    response = dispatch_request(
        db_path,
        {
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "list_supported_timeseries_types",
                "arguments": {"category": "body", "unexpected": "ignored?"},
            },
        },
    )

    # Then
    assert response == {
        "jsonrpc": "2.0",
        "id": 10,
        "error": {"code": -32602, "message": "Invalid tool call arguments."},
    }


def test_mcp_dispatch_rejects_invalid_ranges_without_terminating_server(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    calls: tuple[tuple[str, JsonObject], ...] = (
        (
            "get_daily_summary",
            {"start_date": "2026-02-30", "end_date": "2026-03-01"},
        ),
        (
            "get_daily_summary",
            {"start_date": "2026-06-09", "end_date": "2026-06-01"},
        ),
        (
            "get_timeseries",
            {
                "type_codes": ["steps"],
                "start_time": "not-a-timestamp",
                "end_time": "2026-06-08T00:00:00Z",
            },
        ),
        (
            "get_timeseries",
            {
                "type_codes": ["steps"],
                "start_time": "2026-06-09T00:00:00Z",
                "end_time": "2026-06-08T00:00:00Z",
            },
        ),
    )

    for request_id, (name, arguments) in enumerate(calls, start=20):
        response = dispatch_request(
            db_path,
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            },
        )
        assert response == {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32602, "message": "Invalid tool call arguments."},
        }

    later = ToolListResponse.model_validate(
        dispatch_request(
            db_path,
            {"jsonrpc": "2.0", "id": 24, "method": "tools/list"},
        )
    )
    assert later.id == 24
    assert later.result.tools


def test_mcp_missing_database_is_controlled_and_has_no_filesystem_side_effect(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "missing-parent" / "health.sqlite"

    response = dispatch_request(
        db_path,
        {
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": {"name": "get_bridge_status", "arguments": {}},
        },
    )
    later = dispatch_request(
        db_path,
        {"jsonrpc": "2.0", "id": 12, "method": "tools/list"},
    )

    assert response == {
        "jsonrpc": "2.0",
        "id": 11,
        "error": {"code": -32000, "message": "Health Bridge database is unavailable."},
    }
    assert later["id"] == 12
    assert "result" in later
    assert not db_path.parent.exists()


def test_mcp_read_only_status_does_not_repair_database_mode_or_mtime(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    db_path.chmod(0o640)
    before = db_path.stat()

    response = dispatch_request(
        db_path,
        {
            "jsonrpc": "2.0",
            "id": 17,
            "method": "tools/call",
            "params": {"name": "get_bridge_status", "arguments": {}},
        },
    )
    after = db_path.stat()

    assert "result" in response
    assert after.st_mode == before.st_mode
    assert after.st_mtime_ns == before.st_mtime_ns


def test_mcp_read_only_refuses_wal_without_creating_shm(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    wal_path = db_path.with_name(f"{db_path.name}-wal")
    shm_path = db_path.with_name(f"{db_path.name}-shm")
    _ = wal_path.write_bytes(b"synthetic WAL presence sentinel")
    before = wal_path.read_bytes()

    response = dispatch_request(
        db_path,
        {
            "jsonrpc": "2.0",
            "id": 18,
            "method": "tools/call",
            "params": {"name": "get_bridge_status", "arguments": {}},
        },
    )

    assert response == {
        "jsonrpc": "2.0",
        "id": 18,
        "error": {"code": -32000, "message": "Health Bridge database is unavailable."},
    }
    assert wal_path.read_bytes() == before
    assert not shm_path.exists()


def test_mcp_read_only_refuses_active_writer_snapshot(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with connect_database(db_path) as connection:
        _ = connection.execute("begin immediate")
        response = dispatch_request(
            db_path,
            {
                "jsonrpc": "2.0",
                "id": 20,
                "method": "tools/call",
                "params": {"name": "get_bridge_status", "arguments": {}},
            },
        )
        connection.rollback()

    assert response == {
        "jsonrpc": "2.0",
        "id": 20,
        "error": {"code": -32000, "message": "Health Bridge database is unavailable."},
    }


def test_mcp_rejects_noncanonical_date_forms(tmp_path: Path) -> None:
    definition = next(
        tool for tool in MCP_TOOL_DEFINITIONS if tool.name == "get_workouts"
    )
    assert definition.input_schema == DATE_RANGE_INPUT_SCHEMA

    for invalid_date in ("20260601", "2026-W23-1"):
        with pytest.raises(ValidationError):
            _ = DateRangeArgs(
                start_date=invalid_date,
                end_date="2026-06-02",
            )
        response = dispatch_request(
            tmp_path / "unused.sqlite",
            {
                "jsonrpc": "2.0",
                "id": 19,
                "method": "tools/call",
                "params": {
                    "name": "get_workouts",
                    "arguments": {
                        "start_date": invalid_date,
                        "end_date": "2026-06-02",
                    },
                },
            },
        )
        assert response["error"] == {
            "code": -32602,
            "message": "Invalid tool call arguments.",
        }


def test_mcp_stdio_survives_missing_database_without_traceback(tmp_path: Path) -> None:
    db_path = tmp_path / "missing-parent" / "health.sqlite"
    stdin = (
        '{"jsonrpc":"2.0","id":11,"method":"tools/call",'
        '"params":{"name":"get_bridge_status","arguments":{}}}\n'
        '{"jsonrpc":"2.0","id":12,"method":"tools/list"}\n'
    )

    result = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db_path)],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    lines = result.stdout.splitlines()
    missing = ErrorResponse.model_validate_json(lines[0])
    later = ToolListResponse.model_validate_json(lines[1])

    assert result.returncode == 0
    assert result.stderr == ""
    assert missing.id == 11
    assert missing.error.code == -32000
    assert missing.error.message == "Health Bridge database is unavailable."
    assert later.id == 12
    assert not db_path.parent.exists()


def test_mcp_stdio_survives_malformed_legacy_sleep_row(tmp_path: Path) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with connect_database(db_path) as connection:
        _ = connection.execute(
            "update sleep_stage_intervals set start_time = ?",
            ("not-a-timestamp",),
        )
    stdin = (
        '{"jsonrpc":"2.0","id":21,"method":"tools/call",'
        '"params":{"name":"get_sleep_summary","arguments":'
        '{"start_date":"2026-06-01","end_date":"2026-06-08"}}}\n'
        '{"jsonrpc":"2.0","id":22,"method":"tools/list"}\n'
    )

    result = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db_path)],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    lines = result.stdout.splitlines()
    malformed = ErrorResponse.model_validate_json(lines[0])
    later = ToolListResponse.model_validate_json(lines[1])

    assert result.returncode == 0
    assert result.stderr == ""
    assert malformed.id == 21
    assert malformed.error.code == -32000
    assert malformed.error.message == "Health Bridge database is unavailable."
    assert later.id == 22


def test_mcp_stdio_classifies_stored_row_validation_as_database_error(
    tmp_path: Path,
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    with connect_database(db_path) as connection:
        _ = connection.execute("update sources set name = ?", (b"\x80",))
    stdin = (
        '{"jsonrpc":"2.0","id":23,"method":"tools/call",'
        '"params":{"name":"explain_sources","arguments":{}}}\n'
        '{"jsonrpc":"2.0","id":24,"method":"tools/list"}\n'
    )

    result = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db_path)],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    lines = result.stdout.splitlines()
    malformed = ErrorResponse.model_validate_json(lines[0])
    later = ToolListResponse.model_validate_json(lines[1])

    assert result.returncode == 0
    assert result.stderr == ""
    assert malformed.id == 23
    assert malformed.error.code == -32000
    assert malformed.error.message == "Health Bridge database is unavailable."
    assert later.id == 24


def test_mcp_dispatch_calls_redacted_bridge_status_tool(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    call_response = ToolCallResponse.model_validate(
        dispatch_request(
            db_path,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "get_bridge_status", "arguments": {}},
            },
        ),
    )
    payload_text = call_response.result.content[0].text

    # Then
    payload = SmokeBridgeStatus.model_validate_json(payload_text)
    assert payload.schema_id == "health_bridge.status.v1"
    assert payload.counts["samples"] == 3
    assert payload.latest_sync.status == "succeeded"
    assert payload.metrics["heart_rate"].record_count == 1
    assert payload.sync_cursors[0].cursor_kind == "anchored_object_query"
    assert "synthetic-cursor" not in payload_text
    assert "token_hash" not in payload_text


def test_mcp_dispatch_calls_redacted_markdown_context_tool(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    call_response = ToolCallResponse.model_validate(
        dispatch_request(
            db_path,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "get_bridge_context_markdown", "arguments": {}},
            },
        ),
    )
    payload_text = call_response.result.content[0].text

    # Then
    assert payload_text.startswith("# Health Bridge Context\n")
    assert "## Store Counts" in payload_text
    assert "## Redaction Notes" in payload_text
    assert "heart_rate" in payload_text
    assert "synthetic-cursor" not in payload_text
    assert "token_hash" not in payload_text
    assert "bearer_token" not in payload_text
    assert "healthbridge://pair" not in payload_text


def test_mcp_start_stdio_calls_redacted_markdown_context_tool(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    stdin = (
        '{"jsonrpc":"2.0","id":1,"method":"tools/call",'
        '"params":{"name":"get_bridge_context_markdown","arguments":{}}}\n'
    )

    # When
    result = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db_path)],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    call_response = ToolCallResponse.model_validate_json(result.stdout.splitlines()[0])
    payload_text = call_response.result.content[0].text

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert payload_text.startswith("# Health Bridge Context\n")
    assert "## Redaction Notes" in payload_text
    assert "synthetic-cursor" not in payload_text
    assert "token_hash" not in payload_text


def test_mcp_start_stdio_rejects_malformed_tool_call_without_traceback(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    stdin = (
        '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":[]}\n'
        '{"jsonrpc":"2.0","id":10,"method":"tools/call",'
        '"params":{"name":"get_timeseries","arguments":[]}}\n'
    )

    # When
    result = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db_path)],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    lines = result.stdout.splitlines()
    params_response = ErrorResponse.model_validate_json(lines[0])
    arguments_response = ErrorResponse.model_validate_json(lines[1])

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert params_response.id == 9
    assert params_response.error.code == -32602
    assert params_response.error.message == "Invalid tool call arguments."
    assert arguments_response.id == 10
    assert arguments_response.error.code == -32602
    assert arguments_response.error.message == "Invalid tool call arguments."


def test_timeseries_schema_and_runtime_accept_the_same_timestamp_forms() -> None:
    validator = Draft202012Validator(TIMESERIES_INPUT_SCHEMA)
    properties = required_object(TIMESERIES_INPUT_SCHEMA["properties"])
    start_schema = required_object(properties["start_time"])
    end_schema = required_object(properties["end_time"])
    assert start_schema["format"] == "date-time"
    assert end_schema["format"] == "date-time"
    assert "runtime validation" in str(start_schema["description"])
    assert "nonexistent calendar dates" in str(end_schema["description"])
    valid = {
        "type_codes": ["step_count"],
        "start_time": "2026-06-01T00:00:00Z",
        "end_time": "2026-06-02T00:00:00Z",
    }
    assert validator.is_valid(valid)  # pyright: ignore[reportUnknownMemberType]
    _ = TimeseriesArgs.model_validate(valid)

    for invalid_time in ("2026-06-01T00:00:00+00:00", "2026-06-01T00:00:00.123Z"):
        invalid = {**valid, "start_time": invalid_time}
        assert not validator.is_valid(invalid)  # pyright: ignore[reportUnknownMemberType]
        with pytest.raises(ValidationError):
            _ = TimeseriesArgs.model_validate(invalid)

    impossible = {**valid, "start_time": "2026-02-30T00:00:00Z"}
    with pytest.raises(ValidationError):
        _ = TimeseriesArgs.model_validate(impossible)


def test_mcp_start_stdio_lists_and_calls_timeseries_tool(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    stdin = (
        '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'
        '{"jsonrpc":"2.0","id":2,"method":"tools/call",'
        '"params":{"name":"get_timeseries","arguments":'
        '{"type_codes":["steps"],'
        '"start_time":"2026-06-01T00:00:00Z",'
        '"end_time":"2026-06-08T00:00:00Z"}}}\n'
    )

    # When
    result = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db_path)],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    lines = result.stdout.splitlines()
    list_response = ToolListResponse.model_validate_json(lines[0])
    call_response = ToolCallResponse.model_validate_json(lines[1])
    payload = TimeseriesCallPayload.model_validate_json(
        call_response.result.content[0].text,
    )

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert list_response.result.tools[0].name == "get_bridge_status"
    assert call_response.result.content[0].type == "text"
    assert payload.points[0].type_code == "steps"


def test_mcp_start_stdio_ignores_initialized_notification(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    stdin = (
        '{"jsonrpc":"2.0","id":1,"method":"initialize",'
        '"params":{"protocolVersion":"2024-11-05",'
        '"capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}\n'
        '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n'
    )

    # When
    result = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db_path)],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    lines = result.stdout.splitlines()
    initialize_response = InitializeResponse.model_validate_json(lines[0])
    list_response = ToolListResponse.model_validate_json(lines[1])

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert len(lines) == 2
    assert initialize_response.result.protocol_version == "2024-11-05"
    assert list_response.result.tools[0].name == "get_bridge_status"


def test_mcp_smoke_command_lists_and_calls_without_hosted_client(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = run(
        ["uv", "run", "health-bridge", "mcp", "smoke", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    output = SmokeOutput.model_validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.listed_tools == list(EXPECTED_TOOL_NAMES)
    assert output.called_tool == "list_synced_metrics"
    assert any(metric.type_code == "weight" for metric in output.call_result.metrics)
    assert output.context_tool == "get_bridge_context_markdown"
    assert output.context_result.title == "# Health Bridge Context"
    assert output.context_result.has_store_counts is True
    assert output.context_result.has_redaction_notes is True
    assert output.context_result.forbidden_hits == []


def test_mcp_smoke_command_handles_initialized_empty_store(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "empty.sqlite"
    initialize_database(db_path)

    # When
    result = run(
        ["uv", "run", "health-bridge", "mcp", "smoke", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    output = SmokeOutput.model_validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.listed_tools == list(EXPECTED_TOOL_NAMES)
    assert output.called_tool == "list_synced_metrics"
    assert output.call_result.metrics == []
    assert "availability is unknown" in output.call_result.missing_data_notes[0]
    assert output.context_tool == "get_bridge_context_markdown"
    assert output.context_result.title == "# Health Bridge Context"
    assert output.context_result.has_store_counts is True
    assert output.context_result.has_redaction_notes is True
    assert output.context_result.forbidden_hits == []

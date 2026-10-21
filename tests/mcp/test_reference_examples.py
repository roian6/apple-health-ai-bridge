from __future__ import annotations

import re
import shlex
from pathlib import Path
from subprocess import run
from typing import Final

from pydantic import BaseModel, JsonValue
from typer.core import TyperGroup
from typer.main import get_command

from health_bridge.cli import app
from health_bridge.mcp.tools import MCP_TOOL_DEFINITIONS
from health_bridge.mcp.types import required_object
from health_bridge.queries.latest_sleep_models import LatestSleepPeriodResult
from health_bridge.queries.models import (
    DailySummaryResult,
    SleepSummaryResult,
    SourcesResult,
    SyncedMetricsResult,
    TimeseriesResult,
    WorkoutsResult,
)
from health_bridge.queries.sleep_report_models import SleepReportResult
from health_bridge.status import BridgeStatusSnapshot
from health_bridge.timeseries_catalog import SupportedTimeseriesCatalog
from tests.mcp.test_mcp_server import ToolCallResponse

REFERENCE: Final = Path("docs/reference")
RESULT_MODELS: Final[dict[str, type[BaseModel]]] = {
    "get_bridge_status": BridgeStatusSnapshot,
    "list_supported_timeseries_types": SupportedTimeseriesCatalog,
    "list_synced_metrics": SyncedMetricsResult,
    "get_timeseries": TimeseriesResult,
    "get_workouts": WorkoutsResult,
    "get_sleep_summary": SleepSummaryResult,
    "get_latest_sleep_period": LatestSleepPeriodResult,
    "get_sleep_report": SleepReportResult,
    "get_daily_summary": DailySummaryResult,
    "explain_sources": SourcesResult,
}


class ToolParameters(BaseModel):
    name: str
    arguments: dict[str, JsonValue]


class ToolRequest(BaseModel):
    jsonrpc: str
    id: int
    method: str
    params: ToolParameters


def test_cli_reference_covers_registered_public_commands_and_options() -> None:
    # Given
    reference = (REFERENCE / "cli.md").read_text()
    pending = [("", get_command(app))]
    # When
    while pending:
        prefix, command = pending.pop()
        if command.hidden:
            continue
        # Then
        assert f"`health-bridge{prefix}`" in reference
        for parameter in command.params:
            for option in parameter.opts:
                assert re.search(rf"`{re.escape(option)}(?:`| )", reference), (
                    prefix,
                    option,
                )
        completed = run(
            ["uv", "run", "health-bridge", *prefix.split(), "--help"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        assert completed.returncode == 0, completed.stderr
        if isinstance(command, TyperGroup):
            pending.extend(
                (f"{prefix} {name}", child) for name, child in command.commands.items()
            )


def test_reference_examples_run_through_cli_and_all_mcp_tools(tmp_path: Path) -> None:
    # Given
    tmp_path.chmod(0o700)
    db = tmp_path / "reference.sqlite"
    cli_reference = (REFERENCE / "cli.md").read_text()
    mcp_reference = (REFERENCE / "mcp.md").read_text()
    commands = [
        match[1]
        for match in re.finditer(r"```bash\n(.*?)\n```", cli_reference, re.DOTALL)
    ]
    requests = [
        ToolRequest.model_validate_json(match[1])
        for match in re.finditer(r"```json\n(.*?)\n```", mcp_reference, re.DOTALL)
    ]
    assert commands
    assert len(requests) == len(MCP_TOOL_DEFINITIONS)
    # When
    outputs: list[str] = []
    for block in commands:
        for line in block.splitlines():
            arguments = [
                str(db) if arg == "$QA_DB" else arg for arg in shlex.split(line)
            ]
            completed = run(
                arguments, capture_output=True, text=True, timeout=30, check=False
            )
            assert completed.returncode == 0, completed.stderr
            outputs.append(completed.stdout)
    completed = run(
        ["uv", "run", "health-bridge", "mcp", "start", "--db", str(db)],
        input="\n".join(request.model_dump_json() for request in requests) + "\n",
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    # Then
    assert completed.returncode == 0, completed.stderr
    assert len(completed.stdout.splitlines()) == len(requests)
    names = [request.params.name for request in requests]
    assert names == [tool.name for tool in MCP_TOOL_DEFINITIONS]
    cli_outputs: dict[str, str] = dict(
        zip(
            (
                "get_bridge_status",
                "get_bridge_context_markdown",
                "list_supported_timeseries_types",
                "list_synced_metrics",
                "get_timeseries",
                "get_workouts",
                "get_sleep_summary",
                "get_latest_sleep_period",
                "get_daily_summary",
                "get_sleep_report",
                "explain_sources",
            ),
            (outputs[index] for index in (2, 10, 9, 3, 4, 5, 6, 12, 7, 13, 8)),
            strict=True,
        )
    )
    for name, line in zip(names, completed.stdout.splitlines(), strict=True):
        response = ToolCallResponse.model_validate_json(line)
        payload = response.result.content[0].text
        if name == "get_bridge_context_markdown":
            assert payload.startswith("# Health Bridge Context\n")
            assert payload.strip() == cli_outputs[name].strip()
            continue
        model = RESULT_MODELS[name].model_validate_json(payload)
        assert model == RESULT_MODELS[name].model_validate_json(cli_outputs[name])
        for field in type(model).model_fields:
            assert f"`{field}`" in mcp_reference, (name, field)
    status = BridgeStatusSnapshot.model_validate_json(outputs[2])
    assert status.counts["samples"] == 3
    timeseries = TimeseriesResult.model_validate_json(outputs[4])
    assert [point.value for point in timeseries.points] == [4321.0]
    assert timeseries.truncated is False


def test_mcp_reference_documents_actual_parameter_schemas() -> None:
    # Given
    reference = (REFERENCE / "mcp.md").read_text()
    # When / Then
    for tool in MCP_TOOL_DEFINITIONS:
        assert f"### `{tool.name}`" in reference
        for name in required_object(tool.input_schema["properties"]):
            assert f"`{name}`" in reference
    for code in (-32700, -32600, -32601, -32602, -32603, -32000):
        assert f"`{code}`" in reference

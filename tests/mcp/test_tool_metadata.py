from pathlib import Path
from typing import Final

import pytest

from health_bridge.mcp.server import dispatch_request
from health_bridge.mcp.types import (
    JsonObject,
    required_list,
    required_object,
    required_string,
)

TOOL_PARAMETERS: Final = {
    "get_bridge_status": (),
    "get_bridge_context_markdown": (),
    "list_supported_timeseries_types": ("category",),
    "list_synced_metrics": (),
    "get_timeseries": ("type_codes", "start_time", "end_time"),
    "get_workouts": ("start_date", "end_date"),
    "get_sleep_summary": ("start_date", "end_date"),
    "get_latest_sleep_period": ("timezone", "reference_time"),
    "get_sleep_report": (
        "timezone",
        "local_date",
        "reference_time",
        "include_intervals",
    ),
    "get_daily_summary": ("start_date", "end_date"),
    "explain_sources": (),
}


@pytest.fixture
def listed_tools(tmp_path: Path) -> dict[str, JsonObject]:
    response = dispatch_request(
        tmp_path / "absent.sqlite",
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    )
    tools = required_list(required_object(response["result"])["tools"])
    return {
        required_string(required_object(tool)["name"]): required_object(tool)
        for tool in tools
    }


def test_list_preserves_tool_and_parameter_contracts(
    listed_tools: dict[str, JsonObject],
) -> None:
    # Given / When: the emitted tools/list response, without a database.
    assert listed_tools.keys() == TOOL_PARAMETERS.keys()
    for name, parameters in TOOL_PARAMETERS.items():
        tool = listed_tools[name]
        schema = required_object(tool["inputSchema"])
        properties = required_object(schema["properties"])
        # Then: no new signatures or structured-output promise.
        assert "outputSchema" not in tool
        assert schema["type"] == "object"
        assert schema["additionalProperties"] is False
        assert set(properties) == set(parameters)
        required = {
            "list_supported_timeseries_types": [],
            "get_sleep_report": ["timezone"],
        }.get(name, list(parameters))
        assert schema.get("required", []) == required


@pytest.mark.parametrize("name", TOOL_PARAMETERS)
def test_each_emitted_tool_has_closed_read_only_hints(
    listed_tools: dict[str, JsonObject], name: str
) -> None:
    # Given / When: each actual advertised tool.
    tool = listed_tools[name]
    # Then: hints describe side effects, not authorization or immutable results.
    assert tool.get("annotations") == {
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    }


@pytest.mark.parametrize("name", TOOL_PARAMETERS)
def test_emitted_parameters_are_documented(
    listed_tools: dict[str, JsonObject], name: str
) -> None:
    # Given / When: descriptions consumed by the assistant through tools/list.
    tool = listed_tools[name]
    properties = required_object(required_object(tool["inputSchema"])["properties"])
    # Then: tool and all accepted parameters carry usable documentation.
    assert required_string(tool["description"]).strip()
    for parameter in properties.values():
        assert required_string(required_object(parameter).get("description")).strip()

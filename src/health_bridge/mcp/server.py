import json
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar, Final, TypeAlias, cast

from pydantic import BaseModel, ConfigDict, ValidationError

from health_bridge import __version__
from health_bridge.mcp.tools import (
    MCP_TOOL_DEFINITIONS,
    TOOL_ARGUMENT_MODELS,
    TOOL_CALLERS,
)
from health_bridge.mcp.types import (
    JsonMapping,
    JsonObject,
    JsonShapeError,
    JsonValue,
    optional_request_id,
    required_list,
    required_object,
    required_string,
)

Handler: TypeAlias = Callable[[Path, "JsonRpcRequest"], JsonObject]


@dataclass(frozen=True, slots=True)
class JsonRpcRequest:
    request_id: int | str | None
    method: str
    params: JsonObject


class McpServerModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class SmokeMetric(McpServerModel):
    type_code: str
    record_count: int


class SmokePayload(McpServerModel):
    metrics: tuple[SmokeMetric, ...]
    missing_data_notes: tuple[str, ...]


def dispatch_request(db_path: Path, request: JsonMapping) -> JsonObject:
    try:
        parsed_request = _parse_request(request)
    except (KeyError, JsonShapeError):
        request_id = _request_id_or_none(request.get("id"))
        method = request.get("method")
        if method == "tools/call":
            return _error(request_id, -32602, "Invalid tool call arguments.")
        return _error(request_id, -32600, "Invalid request.")
    handler = HANDLERS.get(parsed_request.method)
    if handler is None:
        return _error(parsed_request.request_id, -32601, "Method not found.")
    return handler(db_path, parsed_request)


def _request_id_or_none(value: JsonValue) -> int | str | None:
    try:
        return optional_request_id(value)
    except JsonShapeError:
        return None


def mcp_smoke_result(db_path: Path) -> JsonObject:
    list_response = dispatch_request(
        db_path,
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    )
    call_response = dispatch_request(
        db_path,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "list_synced_metrics", "arguments": {}},
        },
    )
    context_response = dispatch_request(
        db_path,
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "get_bridge_context_markdown", "arguments": {}},
        },
    )
    tools_value = required_object(list_response["result"])["tools"]
    tools: list[JsonValue] = [
        required_string(required_object(tool)["name"])
        for tool in required_list(tools_value)
    ]
    content = required_list(required_object(call_response["result"])["content"])
    text = required_string(required_object(content[0])["text"])
    context_content = required_list(
        required_object(context_response["result"])["content"],
    )
    context_text = required_string(required_object(context_content[0])["text"])
    result: JsonObject = {
        "listed_tools": tools,
        "called_tool": "list_synced_metrics",
        "call_result": _smoke_call_result(text),
        "context_tool": "get_bridge_context_markdown",
        "context_result": _smoke_context_result(context_text),
    }
    return result


def serve_stdio(db_path: Path) -> None:
    while True:
        try:
            line = input()
        except EOFError:
            return
        try:
            request = _stdio_request_from_json(line)
        except json.JSONDecodeError:
            response = _error(None, -32700, "Parse error.")
            print(json.dumps(response, separators=(",", ":")), flush=True)  # noqa: T201
            continue
        except (KeyError, JsonShapeError):
            response = _error(None, -32600, "Invalid request.")
            print(json.dumps(response, separators=(",", ":")), flush=True)  # noqa: T201
            continue
        if request["method"] == "notifications/initialized":
            continue
        try:
            response = dispatch_request(db_path, request)
        except Exception:  # noqa: BLE001 - request-level MCP fail-safe boundary.
            response = _error(
                _request_id_or_none(request.get("id")),
                -32603,
                "Internal MCP request failure.",
            )
        print(json.dumps(response, separators=(",", ":")), flush=True)  # noqa: T201


def _parse_request(request: JsonMapping) -> JsonRpcRequest:
    method = required_string(request["method"])
    request_id = optional_request_id(request.get("id"))
    params_value = request.get("params", {})
    return JsonRpcRequest(
        request_id=request_id,
        method=method,
        params=required_object(params_value),
    )


def _initialize(_db_path: Path, request: JsonRpcRequest) -> JsonObject:
    return {
        "jsonrpc": "2.0",
        "id": request.request_id,
        "result": {
            "protocolVersion": "2024-11-05",
            "serverInfo": {"name": "health-bridge", "version": __version__},
            "capabilities": {"tools": {}},
        },
    }


def _list_tools(_db_path: Path, request: JsonRpcRequest) -> JsonObject:
    return {
        "jsonrpc": "2.0",
        "id": request.request_id,
        "result": {
            "tools": [
                {
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": dict(tool.input_schema),
                }
                for tool in MCP_TOOL_DEFINITIONS
            ],
        },
    }


def _call_tool(db_path: Path, request: JsonRpcRequest) -> JsonObject:
    try:
        name = required_string(request.params["name"])
        arguments = required_object(request.params.get("arguments", {}))
    except (KeyError, JsonShapeError):
        return _error(request.request_id, -32602, "Invalid tool call arguments.")
    caller = TOOL_CALLERS.get(name)
    argument_model = TOOL_ARGUMENT_MODELS.get(name)
    if caller is None or argument_model is None:
        return _error(request.request_id, -32602, "Unknown read-only tool.")
    try:
        validated_arguments = cast(
            "JsonMapping",
            argument_model.model_validate(arguments).model_dump(),
        )
    except ValidationError:
        return _error(request.request_id, -32602, "Invalid tool call arguments.")
    try:
        payload = caller(db_path, validated_arguments)
        text = payload if isinstance(payload, str) else payload.model_dump_json()
    except (ValidationError, OSError, RuntimeError, ValueError, sqlite3.Error):
        return _error(
            request.request_id,
            -32000,
            "Health Bridge database is unavailable.",
        )
    return {
        "jsonrpc": "2.0",
        "id": request.request_id,
        "result": {"content": [{"type": "text", "text": text}]},
    }


def _smoke_call_result(text: str) -> JsonObject:
    payload = SmokePayload.model_validate_json(text)
    metric_summaries: list[JsonValue] = [
        {"type_code": metric.type_code, "record_count": metric.record_count}
        for metric in payload.metrics
    ]
    notes: list[JsonValue] = list(payload.missing_data_notes)
    result: JsonObject = {
        "metrics": metric_summaries,
        "missing_data_notes": notes,
    }
    return result


def _smoke_context_result(text: str) -> JsonObject:
    title = text.splitlines()[0] if text else ""
    forbidden_markers = (
        "synthetic-cursor",
        "token_hash",
        "bearer_token",
        "healthbridge://pair",
    )
    forbidden_hits: list[JsonValue] = [
        marker for marker in forbidden_markers if marker in text
    ]
    return {
        "title": title,
        "has_store_counts": "## Store Counts" in text,
        "has_redaction_notes": "## Redaction Notes" in text,
        "forbidden_hits": forbidden_hits,
    }


def _stdio_request_from_json(line: str) -> JsonObject:
    raw_request = required_object(cast("JsonValue", json.loads(line)))
    return {
        "jsonrpc": "2.0",
        "id": optional_request_id(raw_request.get("id")),
        "method": required_string(raw_request["method"]),
        "params": raw_request.get("params", {}),
    }


def _error(request_id: int | str | None, code: int, message: str) -> JsonObject:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }


HANDLERS: Final[dict[str, Handler]] = {
    "initialize": _initialize,
    "tools/list": _list_tools,
    "tools/call": _call_tool,
}

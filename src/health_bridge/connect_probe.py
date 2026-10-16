import json
import subprocess  # nosec B404

from pydantic import JsonValue, TypeAdapter

from health_bridge.mcp.types import JsonObject, required_list, required_object


def probe(executable: str, args: list[str]) -> str:
    requests: list[JsonObject] = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "health-bridge-connect", "version": "1"},
            },
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "list_synced_metrics", "arguments": {}},
        },
    ]
    completed = subprocess.run(  # noqa: S603  # nosec B603
        [executable, *args],
        input="\n".join(json.dumps(item) for item in requests) + "\n",
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    if completed.returncode != 0 or len(completed.stdout) > 4 * 1024 * 1024:
        message = "Read-only MCP server probe failed; configuration is retained."
        raise ValueError(message)
    responses = [
        TypeAdapter(dict[str, JsonValue]).validate_json(line)
        for line in completed.stdout.splitlines()
    ]
    if [r.get("id") for r in responses] != [1, 2, 3] or any(
        "error" in r for r in responses
    ):
        message = "MCP protocol readback failed; configuration is retained."
        raise ValueError(message)
    listed = required_list(required_object(responses[1]["result"])["tools"])
    if "list_synced_metrics" not in [
        required_object(tool).get("name") for tool in listed
    ]:
        message = "MCP tool list did not prove read-only access."
        raise ValueError(message)
    if required_object(responses[2]["result"]).get("isError") is True:
        message = "Saved metric readback failed; configuration is retained."
        raise ValueError(message)
    return "server_probe_verified_app_reload_or_trust_needed"

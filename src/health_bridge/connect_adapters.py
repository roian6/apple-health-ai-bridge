import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from pydantic import JsonValue


@dataclass(frozen=True, slots=True)
class Adapter:
    name: str
    format: Literal["json", "jsonc", "toml", "yaml"]
    keys: tuple[str, ...]
    cli: str | None
    reload: str

    def entry(self, executable: str, args: list[str]) -> dict[str, JsonValue]:
        if self.name == "opencode":
            return {"type": "local", "command": [executable, *args], "enabled": True}
        result: dict[str, JsonValue] = {"command": executable, "args": list(args)}
        if self.name in {"vscode", "claude-code"}:
            result["type"] = "stdio"
        return result


ADAPTERS = {
    adapter.name: adapter
    for adapter in (
        Adapter(
            "codex", "toml", ("mcp_servers",), "codex", "Start a new Codex session."
        ),
        Adapter(
            "claude-code",
            "json",
            ("mcpServers",),
            "claude",
            "Start a new Claude Code session.",
        ),
        Adapter(
            "opencode",
            "jsonc",
            ("mcp",),
            "opencode",
            "Start a local OpenCode session; check for project overrides.",
        ),
        Adapter(
            "hermes",
            "yaml",
            ("mcp_servers",),
            "hermes",
            "Reload MCP yourself in the selected Hermes profile when ready.",
        ),
        Adapter(
            "openclaw",
            "jsonc",
            ("mcp", "servers"),
            "openclaw",
            "Verify with openclaw mcp show health-bridge --json, then reload yourself.",
        ),
        Adapter(
            "claude-desktop",
            "json",
            ("mcpServers",),
            None,
            "Restart Claude Desktop yourself on macOS or Windows.",
        ),
        Adapter(
            "cursor",
            "json",
            ("mcpServers",),
            "cursor",
            "Review MCP trust in Cursor. Cloud agents require their own host.",
        ),
        Adapter(
            "vscode",
            "jsonc",
            ("servers",),
            "code",
            "Review MCP trust and start the server in the selected VS Code profile.",
        ),
    )
}


def effective_path(adapter: Adapter, explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit.expanduser().absolute()
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    profile_env = {"hermes": "HERMES_PROFILE", "openclaw": "OPENCLAW_PROFILE"}
    if os.environ.get(profile_env.get(adapter.name, "")):
        message = "Select this named profile's exact file with --config."
        raise ValueError(message)
    if adapter.name == "vscode":
        message = (
            "Use MCP: Open User Configuration in the intended VS Code profile/host; "
            "select that file with --config, or choose a .vscode/mcp.json workspace."
        )
        raise ValueError(message)
    if adapter.name == "claude-desktop" and sys.platform != "darwin":
        message = "Select --config on the desktop host; native app proof is required."
        raise ValueError(message)
    if adapter.name == "opencode":
        return opencode_path(config)
    paths = {
        "codex": Path(os.environ.get("CODEX_HOME", home / ".codex")) / "config.toml",
        "claude-code": Path(os.environ.get("CLAUDE_CONFIG_DIR", home)) / ".claude.json",
        "hermes": Path(os.environ.get("HERMES_HOME", home / ".hermes")) / "config.yaml",
        "openclaw": Path(
            os.environ.get(
                "OPENCLAW_CONFIG_PATH",
                Path(os.environ.get("OPENCLAW_STATE_DIR", home / ".openclaw"))
                / "openclaw.json",
            )
        ),
        "claude-desktop": home
        / "Library/Application Support/Claude/claude_desktop_config.json",
        "cursor": home / ".cursor/mcp.json",
    }
    return paths[adapter.name].expanduser().absolute()


def opencode_path(config: Path) -> Path:
    if os.environ.get("OPENCODE_CONFIG_CONTENT"):
        message = "OPENCODE_CONFIG_CONTENT is active; select --config and review it."
        raise ValueError(message)
    override = os.environ.get("OPENCODE_CONFIG")
    if override:
        return Path(override).expanduser().absolute()
    directory = Path(os.environ.get("OPENCODE_CONFIG_DIR", config / "opencode"))
    filename = (
        "opencode.jsonc" if (directory / "opencode.jsonc").exists() else "opencode.json"
    )
    return directory / filename

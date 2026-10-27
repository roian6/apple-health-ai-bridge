# Connect your AI client

Use an existing receiver database; pairing and sync stay unchanged. If you have
not set up the receiver yet, start with the [setup guide](setup.md). Find its
installed executable on the receiver computer:

```bash
command -v health-bridge
```

Use the database path from setup, normally
`~/.local/share/health-bridge/health.sqlite`, expanded to an absolute path.

## Choose your AI client

The recipes below work with the existing local `mcp start` server. Keep the
receiver and client on the computer that can read the database. A browser-only
or remote/cloud agent does not gain access to that file from these settings.

Choose your client, open its settings, and merge only the named `health-bridge`
entry. Back up the file first; keep other servers and preferences. Replace the
executable and database strings with your own absolute paths. Configuration
values are not shell commands: `~` and `$HOME` are not expanded inside them.

| Client | Configuration to open | Recipe |
| --- | --- | --- |
| Codex CLI | `~/.codex/config.toml`, or your selected `CODEX_HOME` | [TOML](#codex-cli) |
| Claude Code | Project `.mcp.json` | [Project-scoped JSON](#claude-code) |
| Claude Desktop | Settings > Developer > Edit Config | [Desktop JSON](#claude-desktop) |
| Cursor | Settings > MCP, or project `.cursor/mcp.json` | [JSON](#cursor) |
| Hermes Agent | Your active profile's `config.yaml` | [YAML](#hermes-agent) |
| OpenCode | Your selected `opencode.json` or `opencode.jsonc` | [Local command array](#opencode) |
| Visual Studio Code | MCP: Open Workspace Folder MCP Configuration | [Local format](#vs-code-local-format) |
| OpenClaw | Your active profile's `openclaw.json` | [Manual configuration](#openclaw-manual-configuration) |
| Antigravity CLI | Workspace `.agents/mcp_config.json` | [CLI JSON](#antigravity-cli) |

### Codex CLI

Add this table to the selected TOML file:

```toml
[mcp_servers.health-bridge]
command = "/absolute/path/to/health-bridge"
args = ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
```

Start a new Codex session and inspect `/mcp`.
[Official configuration reference](https://developers.openai.com/codex/mcp/).

### Claude Code

Merge this document into `.mcp.json` in the project where you will use the
bridge. This is project scope, not Claude Desktop configuration:

```json
{
  "mcpServers": {
    "health-bridge": {
      "type": "stdio",
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
    }
  }
}
```

Start Claude Code in that project, approve the MCP server when asked, and check
`/mcp`. [Official MCP guide](https://code.claude.com/docs/en/mcp).

### Claude Desktop

On macOS, Developer > Edit Config opens
`~/Library/Application Support/Claude/claude_desktop_config.json`.
Merge a `mcpServers.health-bridge` entry using the JSON above; the `type` field
can be omitted. Fully quit and restart the app, then inspect its MCP connection.
This is manual configuration, not a packaged desktop extension.
[Official local-server tutorial](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

### Cursor

Use the same `mcpServers` JSON shown for Claude Code, including `"type": "stdio"`,
in project `.cursor/mcp.json` or the intended global `~/.cursor/mcp.json`.
Review MCP trust and the server status in Cursor before asking a question.
Local desktop configuration is not a cloud-agent connection.
[Official MCP guide](https://cursor.com/docs/mcp).

### Hermes Agent

Merge into the active profile's YAML file, normally `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  health-bridge:
    command: /absolute/path/to/health-bridge
    args:
      - mcp
      - start
      - --db
      - /absolute/path/to/health.sqlite
```

Use the configuration file selected by your profile or `HERMES_HOME`, not another
profile's file. Reload MCP in the intended session and inspect its available
tools. [Official MCP guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp).

### OpenCode

Merge into the selected global or project OpenCode file:

```json
{
  "mcp": {
    "health-bridge": {
      "type": "local",
      "command": ["/absolute/path/to/health-bridge", "mcp", "start", "--db", "/absolute/path/to/health.sqlite"],
      "enabled": true
    }
  }
}
```

Start a local session and check `opencode mcp list`. Project, custom, and
administrator configuration can affect which entry is used.
[Official MCP guide](https://opencode.ai/docs/mcp-servers/).

### VS Code Local format

Use the command palette to open the workspace's MCP configuration, then merge:

```json
{
  "servers": {
    "health-bridge": {
      "type": "stdio",
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
    }
  }
}
```

This is `.vscode/mcp.json` **Local format**. A portable Copilot configuration
uses a different root key; do not paste this document into it. Review trust,
start the server, and inspect its output. Remote/WSL sessions require paths valid
on the host actually running the server.
[Official configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration).

### OpenClaw manual configuration

For the native `mcp.servers` configuration, merge the following entry into the
selected profile:

```json
{
  "mcp": {
    "servers": {
      "health-bridge": {
        "command": "/absolute/path/to/health-bridge",
        "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
      }
    }
  }
}
```

Reload the intended gateway/session and verify the connection. This is not a
replacement for an older mcporter configuration. Keep existing JSON5
syntax, comments, and unrelated settings when editing. [Official MCP guide](https://docs.openclaw.ai/tools/mcp).

### Antigravity CLI

Use the `mcpServers` JSON shown for Claude Code, without the `type` field, in
workspace `.agents/mcp_config.json`. The global destination is
`~/.gemini/config/mcp_config.json`; choose that only when you intend to grant
access across projects. Restart the CLI session and review MCP trust.
This is Antigravity CLI, not the legacy Gemini CLI `.gemini/settings.json` path.
[Official MCP guide](https://antigravity.google/docs/mcp).

## Check the connection

Reload the client, review its trust prompts, and ask it to call
`get_bridge_status` and `list_synced_metrics`. Compare the records with the
receiver status, then [ask your first question](setup.md#ask-your-first-question).
Configuration preparation, server access, and a model choosing a tool are
separate checks.

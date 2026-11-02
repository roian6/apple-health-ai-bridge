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

### AI chat apps

| Client | Configuration to open | Recipe |
| --- | --- | --- |
| ChatGPT Desktop | The selected Codex host's `config.toml` | [Desktop TOML](#chatgpt-desktop) |
| Claude Desktop | Settings > Developer > Edit Config | [Desktop JSON](#claude-desktop) |
| LM Studio | Program > Install > Edit mcp.json | [JSON](#lm-studio) |
| Cherry Studio | Settings > MCP > MCP Servers > Add | [Desktop fields](#cherry-studio) |

### Agents & harnesses

| Client | Configuration to open | Recipe |
| --- | --- | --- |
| OpenClaw | Your active profile's `openclaw.json` | [Manual configuration](#openclaw-manual-configuration) |
| Hermes Agent | Your active profile's `config.yaml` | [YAML](#hermes-agent) |
| Goose | `~/.config/goose/config.yaml` | [Extension YAML](#goose) |
| Pi | `~/.pi/agent/mcp.json` | [JSON](#pi) |

### Coding agents & developer tools

| Client | Configuration to open | Recipe |
| --- | --- | --- |
| Claude Code | Project `.mcp.json` | [Project-scoped JSON](#claude-code) |
| Codex CLI | `~/.codex/config.toml`, or your selected `CODEX_HOME` | [TOML](#codex-cli) |
| GitHub Copilot CLI | `~/.copilot/mcp-config.json` | [CLI JSON](#github-copilot-cli) |
| Cursor | Settings > MCP, or project `.cursor/mcp.json` | [JSON](#cursor) |
| Visual Studio Code | MCP: Open Workspace Folder MCP Configuration | [Local format](#vs-code-local-format) |
| Warp | Settings > Agents > MCP servers > Add | [Local-agent JSON](#warp) |
| Antigravity CLI | Workspace `.agents/mcp_config.json` | [CLI JSON](#antigravity-cli) |
| OpenCode | Your selected `opencode.json` or `opencode.jsonc` | [Local command array](#opencode) |
| Amp | `~/.config/amp/settings.json` | [Settings JSON](#amp) |
| Factory Droid | `~/.factory/mcp.json` | [Local JSON](#factory-droid) |

## Client setup recipes

### ChatGPT Desktop

Use a desktop version with Settings > MCP servers. ChatGPT Desktop, Codex CLI,
and the IDE extension share MCP configuration for the same Codex host.
Merge this table into that host's `config.toml`, normally
`~/.codex/config.toml`, or the file under your selected `CODEX_HOME`:

```toml
[mcp_servers.health-bridge]
command = "/absolute/path/to/health-bridge"
args = ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
```

In the desktop app, open Settings > MCP servers and select Restart. Type `/mcp`
in the composer to inspect connected servers. The executable and database paths
must exist on the selected host. This is local desktop configuration, not
ChatGPT web's remote plugin setup.
[Official MCP guide](https://learn.chatgpt.com/docs/extend/mcp).

### Claude Desktop

On macOS, Developer > Edit Config opens
`~/Library/Application Support/Claude/claude_desktop_config.json`. Merge:

```json
{
  "mcpServers": {
    "health-bridge": {
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
    }
  }
}
```

Fully quit and restart the app, then inspect its MCP connection.
This is manual configuration, not a packaged desktop extension.
[Official local-server tutorial](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

### LM Studio

Open Program > Install > Edit mcp.json and merge:

```json
{
  "mcpServers": {
    "health-bridge": {
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
    }
  }
}
```

Save and inspect the server's available tools before asking a question.
The selected model must also support tool use; a configured server alone does
not establish that. [Official MCP guide](https://lmstudio.ai/docs/app/mcp).

### Cherry Studio

In the desktop app, open Settings > MCP > MCP Servers > Add and choose a local
standard-input/output connection. Enter these fields:

| Field | Value |
| --- | --- |
| Name | `health-bridge` |
| Command | `/absolute/path/to/health-bridge` |
| Arguments | Four separate values, listed below |
| Environment variables | None required |

1. `mcp`
2. `start`
3. `--db`
4. `/absolute/path/to/health.sqlite`

Enable the server and inspect its healthy status and tool list. Then open
Work > the intended Agent's menu > Edit > MCP and enable this server for that
Agent. Adding the server without binding it to the Agent is not enough.
Inspect the server log if the connection fails.
[Official MCP guide](https://www.cherryai.com/docs/en/advanced-basic/extensions/mcp/).

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

### Goose

Merge this extension into `~/.config/goose/config.yaml`. Goose uses `cmd` for
the executable and a separate `args` list:

```yaml
extensions:
  health-bridge:
    name: Health Bridge
    type: stdio
    cmd: /absolute/path/to/health-bridge
    args: ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
    enabled: true
    envs: {}
    timeout: 300
```

Restart Goose and confirm that Health Bridge is enabled under Extensions before
checking its tools. Preserve any other extensions in the file.
[Official extensions guide](https://goose-docs.ai/docs/getting-started/using-extensions/).

### Pi

Merge into `~/.pi/agent/mcp.json`:

```json
{
  "mcpServers": {
    "health-bridge": {
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
    }
  }
}
```

Run `/reload` after editing the file, then inspect connections with `/mcp`.
`pi mcp list` lists configured servers. Project-scoped `.pi/mcp.json` is also
supported but requires project trust.
[Official MCP guide](https://pi.dev/docs/latest/mcp).

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

### Codex CLI

Add this table to the selected TOML file:

```toml
[mcp_servers.health-bridge]
command = "/absolute/path/to/health-bridge"
args = ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
```

Start a new Codex session and inspect `/mcp`.
[Official configuration reference](https://developers.openai.com/codex/mcp/).

### GitHub Copilot CLI

Merge into `~/.copilot/mcp-config.json`:

```json
{
  "mcpServers": {
    "health-bridge": {
      "type": "local",
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"],
      "env": {},
      "tools": ["*"]
    }
  }
}
```

Open a local Copilot CLI session and use `/mcp show health-bridge` to inspect
status and tools. `copilot mcp get health-bridge` is the terminal alternative.
Organization policies may restrict MCP servers. This configuration is for the
CLI, not Copilot cloud agent or VS Code's Local format.
[Official MCP guide](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers).

### Cursor

Use the same `mcpServers` JSON shown for Claude Code, including `"type": "stdio"`,
in project `.cursor/mcp.json` or the intended global `~/.cursor/mcp.json`.
Review MCP trust and the server status in Cursor before asking a question.
Local desktop configuration is not a cloud-agent connection.
[Official MCP guide](https://cursor.com/docs/mcp).

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

### Warp

For a local Warp agent, open Settings > Agents > MCP servers > Add. Paste:

```json
{
  "mcpServers": {
    "health-bridge": {
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
    }
  }
}
```

Save and start the server. MCP settings show its running status and available
tools; use View Logs to diagnose failures. This recipe is for local agents,
not Warp cloud agents, which cannot read this computer's database.
[Official MCP guide](https://docs.warp.dev/agents/capabilities/mcp/).

### Antigravity CLI

Use the `mcpServers` JSON shown for Claude Code, without the `type` field, in
workspace `.agents/mcp_config.json`. The global destination is
`~/.gemini/config/mcp_config.json`; choose that only when you intend to grant
access across projects. Restart the CLI session and review MCP trust.
This is Antigravity CLI, not the legacy Gemini CLI `.gemini/settings.json` path.
[Official MCP guide](https://antigravity.google/docs/mcp).

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

### Amp

Merge into your user settings at `~/.config/amp/settings.json`:

```json
{
  "amp.mcpServers": {
    "health-bridge": {
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"]
    }
  }
}
```

Start a local Amp session and use `amp mcp doctor` to inspect configuration and
approval state. Workspace `.amp/settings.json` requires explicit server approval.
Amp orbs execute on another machine and do not read your local user settings or
database. [Official MCP guide](https://ampcode.com/docs/customize/mcp).

### Factory Droid

Merge into `~/.factory/mcp.json`:

```json
{
  "mcpServers": {
    "health-bridge": {
      "type": "stdio",
      "command": "/absolute/path/to/health-bridge",
      "args": ["mcp", "start", "--db", "/absolute/path/to/health.sqlite"],
      "disabled": false
    }
  }
}
```

Configuration changes reload automatically. In a local Droid session, use `/mcp`
to inspect the connection and tools, or run `droid mcp list` from the terminal.
Organization policies may restrict servers. Run Droid on the database host.
[Official MCP guide](https://docs.factory.com/harness/mcp).

## Check the connection

First, check the local server independently:

```bash
health-bridge mcp smoke --db /absolute/path/to/health.sqlite
```

Then reload the client, review its trust prompts, and ask it to call
`get_bridge_status` and `list_synced_metrics`. Compare the records with the
receiver status, then [ask your first question](setup.md#ask-your-first-question).
Configuration preparation, server access, and a model choosing a tool are
separate checks.

# Connect an AI app

Run `health-bridge connect`, or choose an app after successful interactive setup.
Choose Later to keep the completed installation. The npm preview remains subject
to the availability conditions in [setup](setup.md).

The wizard offers configuration targets for Codex, Claude Code, OpenCode, Hermes,
OpenClaw, Claude Desktop, Cursor and VS Code/GitHub Copilot. OpenClaw is conditional:
its installed CLI must positively verify its version and MCP command capability.
Missing, failing, timed-out or unsupported OpenClaw checks refuse changes and keep
the existing configuration. Native OpenClaw consumption remains unverified until
tested in the actual compatible app; a configuration format alone is not support
proof. The wizard previews the exact app, config/profile file,
computer and read-only Health Bridge entry, then asks permission. A private backup
precedes the merge. Unrelated entries and comments remain. Conflicting entries or
concurrent changes stop the write; identical repeat runs do not duplicate entries.
Redirected input previews only; `--json` exports a local stdio descriptor.

Use `--client NAME --config PATH` to select an effective profile or project file.
Formats: Codex TOML (`mcp_servers`), Hermes YAML (`mcp_servers`), OpenCode JSONC
(`mcp`), OpenClaw JSONC (`mcp.servers`), Claude Code/Desktop and Cursor JSON
(`mcpServers`), VS Code JSONC (`servers`). JSON5 syntax beyond JSONC is refused.
Codex honors CODEX_HOME; Claude Code honors CLAUDE_CONFIG_DIR; OpenCode honors its
config variables; Hermes honors HERMES_HOME; OpenClaw honors OPENCLAW_CONFIG_PATH
and OPENCLAW_STATE_DIR. Named Hermes/OpenClaw profiles require an explicit path.
In VS Code use **MCP: Open User Configuration** in the intended profile/host and
select that file. Insiders, remote hosts, workspaces and Copilot Agent Host can
use different files. Project overrides may shadow user configuration.

Configuration prepared, server probe verified, app missing and reload/trust needed
are distinct states. The stdio probe initializes, lists tools and reads synced
metrics. This does not prove a desktop app consumed the settings. Reload yourself,
review trust, and test in the app. Setup does not log in to a provider or make a
paid model request. Claude Desktop needs a supported OS; local Cursor config
does not connect cloud agents automatically.

If a server check fails, the prepared entry and its private backup remain. Setup
reports `configuration_prepared`, not `configured_and_verified`, including when
only some selected server checks passed. `configured_mcp_clients` lists the entries
prepared during this attempt; `configured_and_verified` means all their server
checks passed, not that the AI app consumed them. Fix the backend or database and
rerun `connect`; an unchanged entry is reused without another backup or duplicate.

For another computer, use `health-bridge connect --ssh-alias EXISTING_ALIAS`.
The alias must already be an explicit Host in ~/.ssh/config. This produces
preparation guidance without SSH, data/credential copying or local GUI changes.
Obtain the Health Bridge computer's stable command with `connect --json`, then
prepare and verify the SSH stdio command on the AI computer separately.

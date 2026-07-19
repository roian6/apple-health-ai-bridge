# Agent-Assisted Receiver and MCP Setup

Apple Health AI Bridge is designed so a local AI agent can handle most receiver, database, and MCP setup work for a user. This document explains what agents can safely automate and where platform or user-owned boundaries remain.

## What an agent can usually handle

A capable local agent can:

- check prerequisites such as Git, `uv`, and Python;
- clone the repository and run `uv sync --all-extras --dev`;
- initialize a local SQLite database;
- ingest synthetic fixtures;
- start or supervise the local receiver;
- verify `/health` from the machine that runs the receiver;
- generate private setup material when the user is ready for real-device testing;
- write MCP client configuration snippets;
- run redacted `status`, `query`, and `mcp smoke` commands;
- run public release audit and test gates;
- summarize failures without copying real health values or secrets into public places.

## Synthetic first

Agents should start with the synthetic path before touching real-device setup:

```bash
uv sync --all-extras --dev
uv run health-bridge init --db .tmp/quickstart.sqlite
uv run health-bridge ingest-fixture \
  --db .tmp/quickstart.sqlite \
  --input fixtures/health_bridge_batch_v1.synthetic.json
uv run health-bridge status --db .tmp/quickstart.sqlite --markdown
uv run health-bridge mcp smoke --db .tmp/quickstart.sqlite
```

This proves the local Python/SQLite/MCP path without an iPhone and without private pairing material.

## Receiver setup pattern

For local-only smoke testing on the same machine, keep the receiver running in one terminal:

```bash
uv run health-bridge init --db .tmp/device.sqlite
uv run health-bridge receiver start --db .tmp/device.sqlite --host 127.0.0.1 --port 8765
```

Then verify from another terminal:

```bash
curl -fsS http://127.0.0.1:8765/health
uv run health-bridge status --db .tmp/device.sqlite --markdown
```

For a physical iPhone, prepare the real receiver route first by following [the receiver route guide](setup.md#what-the-receiver-url-means). Existing Tailscale users can use Route A; other installers should follow the provider-neutral private-ingress checklist in Route B. Direct LAN is an explicit local-only fallback. Do not put a sample hostname into pairing material.

After that route has set the exact batch URL in `HEALTH_BRIDGE_RECEIVER_URL`, derive and check its health endpoint:

```bash
: "${HEALTH_BRIDGE_RECEIVER_URL:?follow docs/setup.md and set the real URL first}"
PHONE_REACHABLE_BASE_URL="${HEALTH_BRIDGE_RECEIVER_URL%/v1/batches}"
curl -fsS "$PHONE_REACHABLE_BASE_URL/health"
```

Also open that exact phone-facing `/health` URL on the physical iPhone. Routes A and B use HTTPS; Route C deliberately uses HTTP only on the same trusted LAN. Continue only after the selected route succeeds from the phone.

Then create the private setup page from the already verified batch URL:

```bash
uv run health-bridge dev device-session \
  --db .tmp/device.sqlite \
  --label ios-companion \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --setup-page .tmp/ios-companion-device-session.html
```

The generated setup page contains a temporary, single-use invitation and remains private until pairing or expiry. Do not paste it into public issues, docs, chat, logs, or commits. Prefer `dev device-session` for onboarding because its stdout is redacted. Expert receiver commands such as `health-bridge receiver create-token` and `health-bridge receiver create-pairing --format json|deeplink` require explicit secret-output flags and should not be used by agents unless the user asked for raw secret material. New pairing defaults to invitation v2; long-lived bearer material is available only through explicit `--legacy-v1` compatibility.

See [`self-build.md`](self-build.md) for the full Mac/iPhone handoff sequence and [`pairing.md`](pairing.md) for the QR-first pairing/fallback matrix.

## MCP setup pattern

A local MCP client can launch the read-only server like this:

```json
{
  "command": "uv",
  "args": ["run", "health-bridge", "mcp", "start", "--db", ".tmp/quickstart.sqlite"],
  "cwd": "/absolute/path/to/apple-health-ai-bridge"
}
```

If the client cannot set `cwd`, use `uv --directory`:

```json
{
  "command": "uv",
  "args": ["--directory", "/absolute/path/to/apple-health-ai-bridge", "run", "health-bridge", "mcp", "start", "--db", ".tmp/quickstart.sqlite"]
}
```

The MCP surface is intentionally read-only. It exposes fixed tools for status, context Markdown, synced metric coverage, timeseries, workouts, sleep, daily summaries, sources, and supported type metadata.

## Boundaries agents cannot remove

Agents can reduce setup burden, but they cannot fully remove Apple platform and local-network constraints. These cases may still require user action or a future product surface:

- the user only has an iPhone and no always-on computer for a receiver;
- Apple Developer Program enrollment and App Store Connect approval;
- physical TestFlight install, Health permission, and local network permission taps;
- Mac/Xcode signing or keychain approval that requires GUI interaction;
- sleeping laptops, firewalls, router rules, corporate networks, or VPN/private-network misconfiguration;
- receiver host changes after pairing;
- support situations where the agent cannot access the user’s local machine;
- non-agent users who expect a normal app install and setup wizard.

## Product implication

Near-term accessibility should focus on TestFlight plus clear agent-assisted setup docs. A desktop/tray receiver app should be reconsidered after TestFlight feedback shows repeated receiver/MCP setup failures that local agents cannot solve.

Hosted relay, manual export import, and Shortcuts fallback remain outside near-term scope unless the project explicitly changes direction.

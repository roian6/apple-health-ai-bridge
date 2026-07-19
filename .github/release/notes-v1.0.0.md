# Apple Health AI Bridge v1.0.0

Apple Health AI Bridge 1.0.0 is the first coordinated public release of the local-first Apple Health bridge and the Health Bridge iPhone companion.

## Highlights

- Health Bridge for iOS `1.0.0 (15)`, distributed through the approved official TestFlight public invitation.
- Read-only access to every runtime-available HealthKit type implemented by the companion, with Apple's per-type permission controls.
- User-owned receiver and SQLite database with no hosted health-data relay.
- `health-bridge setup` for private database creation, single-use pairing, receiver commands, and same-host stdio MCP integration.
- Read-only CLI and MCP tools for status, daily summaries, time series, workouts, sleep, and provenance.
- Durable upload/outbox recovery, receiver source binding, and privacy-preserving release guardrails.

## Install the receiver

```bash
uv tool install "git+https://github.com/roian6/apple-health-ai-bridge.git@v1.0.0"
```

Then follow the [setup guide](https://github.com/roian6/apple-health-ai-bridge/blob/v1.0.0/docs/setup.md). Install the iPhone companion from the official TestFlight page linked by the project website.

## Verify the release

The GitHub Release assets include:

- `apple_health_ai_bridge-1.0.0-py3-none-any.whl`
- `apple_health_ai_bridge-1.0.0.tar.gz`
- `SHA256SUMS`
- `release-metadata.json`

The metadata binds the Python version, iOS marketing version/build, exact Git commit/tree, and batch schema. Verify `SHA256SUMS` before using downloaded artifacts.

## Boundaries

- HealthKit access is read-only.
- The receiver is intended for trusted local or private-network deployment, not the public internet.
- MCP and CLI query surfaces do not expose raw SQL or write tools.
- Health Bridge does not provide medical advice, diagnosis, treatment, or emergency monitoring.

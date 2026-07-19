# Apple Health AI Bridge agent instructions

This file gives safe operating rules for AI coding agents and automation working in this repository. The project is fixture-first, local-first, and privacy-sensitive.

## Core rules

- Use synthetic fixtures or deliberately Apple Health-shaped smoke data in tests, docs, issues, and examples.
- Do not commit real HealthKit exports, health values, screenshots with health values, receiver databases, logs with personal data, pairing links, setup pages, bearer tokens, token hashes, cursor values, or local outbox payloads.
- Keep HealthKit access read-only by default. Do not add HealthKit write APIs unless the project explicitly changes scope.
- Do not add telemetry, analytics, advertising hooks, hidden hosted sync, data brokers, or third-party AI upload paths without an explicit privacy review.
- Keep MCP and CLI query surfaces read-only. Do not expose raw SQL by default.
- Keep receiver examples local or private-network oriented. Public internet deployment needs separate hardening guidance.

## Public documentation style

Public docs should read like product and developer documentation, not internal project notes.

Avoid adding:

- stage diaries;
- private implementation plans;
- agent/tool-specific work instructions;
- private QA transcripts;
- personal account details;
- raw validation logs;
- App Store Connect or signing material.

If detailed planning or private validation notes are needed, keep them outside the public repository.

## Useful commands

```bash
uv sync --all-extras --dev --locked
uv run health-bridge init --db .tmp/quickstart.sqlite
uv run health-bridge ingest-fixture \
  --db .tmp/quickstart.sqlite \
  --input fixtures/health_bridge_batch_v1.synthetic.json
uv run health-bridge status --db .tmp/quickstart.sqlite --markdown
uv run health-bridge mcp smoke --db .tmp/quickstart.sqlite
```

Before release-facing changes:

```bash
uv run python scripts/public-release-audit.py --strict
git diff --check
uv run ruff format --check .
uv run ruff check .
uv run basedpyright
uv run bandit -r src -q
uv run pip-audit --local --skip-editable
uv run pytest -q
```

For iOS work, run Swift/Xcode gates on a Mac when app source, entitlements, assets, privacy manifests, or project settings change.

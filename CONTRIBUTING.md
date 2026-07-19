# Contributing

Thanks for helping improve Apple Health AI Bridge.

This project handles health-adjacent data, so contributions must preserve the local-first and privacy-first boundary before anything else.

## Core Rules

- Use synthetic fixtures or deliberately Apple Health-shaped smoke data only.
- Do not include real HealthKit exports, screenshots with health values, receiver DBs, logs with personal data, pairing deep links, setup-page contents, bearer tokens, token hashes, cursor values, or local outbox payloads in issues, PRs, commits, docs, or tests.
- Keep HealthKit access read-only by default. Do not add HealthKit write APIs unless the project explicitly changes scope.
- Do not add telemetry, analytics, advertising hooks, hidden cloud upload, third-party AI calls, or data-mining paths.
- Keep examples local-first. Hosted relay or remote MCP features need an explicit project decision and separate privacy review.

## Development Setup

```bash
uv sync --all-extras --dev --locked
uv run health-bridge --version
uv run health-bridge init --db .tmp/quickstart.sqlite
uv run health-bridge ingest-fixture \
  --db .tmp/quickstart.sqlite \
  --input fixtures/health_bridge_batch_v1.synthetic.json
uv run health-bridge mcp smoke --db .tmp/quickstart.sqlite
```

For iOS work:

```bash
cd ios/HealthBridgeCompanion
swift test
xcodebuild -project HealthBridgeCompanion.xcodeproj \
  -target HealthBridgeCompanion \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project HealthBridgeCompanion.xcodeproj \
  -target HealthBridgeCompanion \
  -sdk iphoneos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Real-device HealthKit validation is useful, but any reported evidence must be redacted and aggregate-only.

## Before Opening a PR

Run the Python gates for non-iOS changes:

```bash
uv run ruff format --check .
uv run ruff check .
uv run basedpyright
uv run bandit -r src -q
uv run pip-audit --local --skip-editable
uv run pytest -q
uv run python scripts/public-release-audit.py --strict
git diff --check
```

For iOS/Swift changes, use Xcode 16 or later and also run Swift package tests and the relevant Xcode build.

## PR Shape

Prefer small PRs that do one thing. If you are looking for safe starter work, see [`docs/contribution-ideas.md`](docs/contribution-ideas.md). Good PRs include:

- a short summary;
- privacy boundary notes;
- tests run;
- screenshots only if they contain no real health values, tokens, setup pages, or pairing material;
- docs updates when user-facing behavior changes.

## License

By contributing, you agree that your contribution is submitted under the Apache License 2.0 unless explicitly stated otherwise.

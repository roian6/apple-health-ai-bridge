# Contributing

<p>
  <a href="https://github.com/roian6/apple-health-ai-bridge/actions/workflows/python.yml"><img src="https://img.shields.io/github/actions/workflow/status/roian6/apple-health-ai-bridge/python.yml?branch=main&amp;label=Python&amp;style=flat-square" alt="Python CI" height="20"></a>
  <a href="https://github.com/roian6/apple-health-ai-bridge/actions/workflows/ios.yml"><img src="https://img.shields.io/github/actions/workflow/status/roian6/apple-health-ai-bridge/ios.yml?branch=main&amp;label=iOS&amp;style=flat-square" alt="iOS CI" height="20"></a>
</p>

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

## Interface references

See the [CLI reference](../docs/reference/cli.md) for command options and output
formats, and the [MCP reference](../docs/reference/mcp.md) for all eleven tools,
parameters, results, date boundaries, and errors.

## Automated tests

Add automated tests for major functionality and behavior-changing bug fixes.
For fixes, first reproduce the defect with a failing regression test, then verify
the corrected behavior. Cover the relevant success, invalid-input, empty-data,
date-boundary, or failure-recovery cases through the public boundary involved.
Use synthetic fixtures; a source-string assertion alone does not demonstrate
runtime behavior. Documentation examples should also run through the CLI or MCP.

Representative patterns already in the suite include
[`tests/queries/test_date_boundaries.py`](../tests/queries/test_date_boundaries.py),
[`tests/receiver/test_delivery_acceptance_failures.py`](../tests/receiver/test_delivery_acceptance_failures.py),
and [`DeliveryProtocolV1TamperTests.swift`](../ios/HealthBridgeCompanion/Tests/HealthBridgeCompanionCoreTests/DeliveryProtocolV1TamperTests.swift).
Keep deterministic fuzz contracts in the normal suite; run the native campaign
on its supported platform. Explain in the PR when a change has no testable
behavior, such as a prose-only correction.

### Fast local feedback

While iterating, start with the test file covering the change, then widen to
related tests when you change a shared fixture or interface. For example, an
issue-form change can start with:

```bash
uv run pytest -q tests/guardrails/test_issue_forms.py
```

To investigate one failing case, use its full node ID:

```bash
uv run pytest -q tests/guardrails/test_issue_forms.py::test_bug_report_keeps_reproduction_required
```

A focused run is feedback for that selection, not a replacement for the complete
[pre-PR checks](#before-opening-a-pr). Keep the existing assertions and fix the
failure rather than excluding it. Run the complete gates once the changes are
ready for review, instead of after every small edit.

Keep the command, result, source revision and any uncommitted changes with your
local verification notes. Reuse a passing result only while its inputs and
environment are unchanged; a commit ID alone does not describe a dirty worktree.
Changes to code, tests, fixtures, configuration, dependencies or tool versions
invalidate the affected results. Do not repeat an unchanged passing check just
to produce another copy of the same evidence.

For concurrent runs in separate worktrees, use separate synthetic data,
temporary directories and test HOME directories. A different database filename
alone does not isolate the HOME-relative database lock. Do not use personal
health data or share a mutable test database between runs.

## Swift static analysis

From the repository root, run `bash scripts/swift-analysis.sh` on macOS with
Xcode selected. The wrapper downloads [SwiftLint 0.65.1](https://github.com/realm/SwiftLint/releases/tag/0.65.1)
(MIT licensed), verifies its pinned archive SHA-256, and uses only temporary
tooling. Linux ARM64 is supported when its required runtime, including SourceKit,
is available; a missing runtime is a failure, not a successful analysis.

The policy in [`.github/linters/swiftlint.yml`](linters/swiftlint.yml) checks every Swift file in the
iOS App, CompanionCore, and macOS ACK helper. Tests, separate QA app harnesses,
package manifests, and generated builds are outside these production roots;
QA support authored inside CompanionCore remains included.

The bounded [rule set](https://realm.github.io/SwiftLint/rule-directory.html)
detects forced casts/tries that can trap, duplicate conditions/enum cases and
identical operands that can conceal logic errors, discarded notification
observers and unsafe observer detachment, strong delegate references, and invalid
IBInspectable declarations. It deliberately does not enforce formatting or file
length. Review policy changes on their merits; do not remove rules or add
baselines/source suppressions to hide findings.

The wrapper prints the version and file coverage, accepts a clean synthetic
control, and requires a known-bad forced cast to fail with the expected rule.
Download, checksum, runtime, empty-scope, control, and production violations fail
the command. The existing **Swift tests and unsigned app builds** job in
[iOS CI](workflows/ios.yml) runs it before the unchanged tests and builds.
Static analysis complements those gates and does not replace them.

## Input Fuzzing

The optional `fuzz` dependency group pins Atheris 3.1.0 for Linux x86_64
CPython 3.12-3.14. It is separate from runtime dependencies and normal development
setup. From the repository root in that environment:

```bash
uv sync --locked --dev --group fuzz --python 3.12
scratch="$(mktemp -d)"
uv run --no-sync python -m scripts.fuzz.campaign "$scratch"
```

The campaign copies the committed synthetic seeds into the temporary directory,
replays them, then mutates each target for 45 seconds. Inputs are capped at 4096
bytes, five seconds per input, and 512 MiB RSS per engine process; each process
also has a 90-second wall-clock deadline. The targets call the receiver's batch
model and MCP's date-range argument model without opening a database or listener.
Only Pydantic validation rejections are expected. Unexpected exceptions, crashes,
timeouts, missing engine support, or failure to demonstrate new coverage features
produce a nonzero exit status. Logs, copied corpora, and crash artifacts remain
under `$scratch`; inspect them locally and remove that directory when finished.

Replay a minimized synthetic crash with the same target and resource bounds:

```bash
uv run --no-sync python -m scripts.fuzz.engine batch \
  "$scratch/batch/artifacts/crash-REPLACE_WITH_HASH" \
  -runs=1 -max_len=4096 -timeout=5 -rss_limit_mb=512 \
  "-artifact_prefix=$scratch/batch/artifacts/"
```

Use `mcp_dates` for MCP date-range reproducers. Report a minimal synthetic
reproducer and traceback for unexpected failures; do not broaden exception
handling to hide them. On ARM64, macOS, Windows, or other unsupported engine
environments, run the deterministic validator and harness contracts:

```bash
uv sync --all-extras --dev --locked
uv run pytest -q tests/fuzzing tests/guardrails/test_fuzzing_workflow.py
uv run basedpyright scripts/fuzz
```

## Branches and Design Decisions

Use a short branch name with one of these prefixes:

- `fix/` for defects;
- `feat/` for accepted features;
- `docs/` for documentation;
- `chore/` for maintenance and repository operations.

Get a maintainer decision before implementation when a change affects HealthKit permissions or read/write scope, receiver authentication or pairing, disconnect/reset/deletion behavior, outbox or cursor semantics, public/hosted network paths, telemetry, analytics, advertising, third-party AI calls, privacy copy, entitlements, or App Review disclosures.

Non-trivial features should link an accepted issue. The public triage, merge, and release process is recorded in [`docs/maintainer-guide.md`](../docs/maintainer-guide.md).

## Before Opening a PR

Run the Python gates for non-iOS changes:

```bash
uv run ruff format --check .
uv run ruff check .
uv run basedpyright
uv run bandit -r src -q
uv run pip-audit --local --skip-editable
uv run pytest -q --durations=30 --durations-min=1.0
uv run python scripts/public-release-audit.py --strict
git diff --check
```

The duration report identifies slow tests without reducing the test selection.
Use it to guide optimization rather than assuming the largest test file is the
slowest.

For iOS/Swift changes, use Xcode 16 or later and also run Swift package tests and the relevant Xcode build.

## PR Shape

Prefer small PRs that do one thing. If you are looking for safe starter work, see [`docs/contribution-ideas.md`](../docs/contribution-ideas.md). Good PRs include:

- a short summary;
- privacy boundary notes;
- tests run;
- screenshots only if they contain no real health values, tokens, setup pages, or pairing material;
- docs updates when user-facing behavior changes.

## License

By contributing, you agree that your contribution is submitted under the Apache License 2.0 unless explicitly stated otherwise.

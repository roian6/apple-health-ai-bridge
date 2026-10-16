# iOS Self-Build Guide

Apple Health AI Bridge can be tried with synthetic data on any development machine. Real Apple Health sync is a separate developer-preview path that needs an iPhone, a Mac with Xcode, signing access for a local development build, and compatible receiver and companion builds. Direct needs a receiver URL the iPhone can reach; native iCloud pairing needs the updated companion and Mac helper, with no HTTP URL or tunnel.

The App Store is the normal installation path. This guide remains available for contributors and advanced users who prefer to build and sign the iOS companion themselves.

## Prerequisites

- A Mac with Xcode 16 or later.
- A paired iPhone running iOS 18 or later.
- Git, Python 3.11+, and `uv` on the machine running the receiver.
- A private LAN, VPN, or other private-network address that the iPhone can reach.
- A local checkout of this repository on the Mac if you plan to build/install from the helper scripts.

Do not use public internet receiver URLs unless you have done a separate security review. Do not paste pairing links, setup pages, bearer tokens, receiver databases, or raw HealthKit values into chat, issues, PRs, or logs.

## 1. Prove the synthetic path first

Run the synthetic contributor smoke commands below before touching the iPhone. This confirms the Python, SQLite, CLI, and MCP path with synthetic data only.

```bash
uv sync --all-extras --dev
uv run health-bridge init --db .tmp/quickstart.sqlite
uv run health-bridge ingest-fixture \
  --db .tmp/quickstart.sqlite \
  --input fixtures/health_bridge_batch_v1.synthetic.json
uv run health-bridge status --db .tmp/quickstart.sqlite --markdown
uv run health-bridge mcp smoke --db .tmp/quickstart.sqlite
```

## 2. Use the shared receiver setup

Follow the [setup guide](setup.md) for the receiver and phone handoff instead of repeating route preparation or service assembly here. It distinguishes the unreleased supervised-setup candidate from published `receiver-v1.1.2`. The receiver computer and the Mac used to build the app need not be the same host.

For a source checkout of the candidate, `uv run health-bridge setup` runs the same explicit setup operation. It installs/starts the owned per-user receiver, remembers the database and prints the private live connection URL. It does not build, sign or install the companion. Build the app before issuing an invitation when practical; re-run setup if the invitation expires.

## 3. Build, install, and launch the companion

The helper scripts read local device/signing values from a gitignored file:

```bash
cp scripts/ios-device-local.env.example scripts/ios-device-local.env 2>/dev/null || true
$EDITOR scripts/ios-device-local.env
```

If no example file exists, create `scripts/ios-device-local.env` with your own local values:

```bash
export DEVICE_ID=<your-device-id>
export BUNDLE_ID=<your-companion-bundle-id>
# Optional signing overrides, if needed:
# export DEVELOPMENT_TEAM=<your-apple-developer-team-id>
# export ALLOW_PROVISIONING_UPDATES=1
```

Then run:

```bash
scripts/ios-device-status.sh
scripts/ios-device-run.sh
```

If SSH or a headless shell fails at `CodeSign ... errSecInternalComponent`, use the GUI Terminal wrappers from the Mac session instead:

```bash
open scripts/ios-device-run-local.command
```

If the wrapper opens a keychain prompt, the human at the Mac must approve it. The scripts do not remove the need for Apple signing, device trust, Health permission, or physical iPhone taps.

## 4. Pair and sync on the iPhone

Follow the [phone handoff in the setup guide](setup.md#2-pair-the-iphone-and-start-syncing). Verify the app is your intended isolated development build before opening the private connection URL. If the invitation expired while building, re-run setup rather than modifying saved pairing or app data.

On the iPhone:

1. Open the generated setup page from a trusted path.
2. Import or open the pairing link in the companion.
3. Confirm the app shows the paired receiver.
4. Tap **Allow Health Access** or **Review Permissions**, grant only the Apple Health read permissions you want to test, then enable **Automatic Sync** when that behavior is in scope.
5. Verify the first stored observations, automatic delivery, preservation of an existing OFF setting and cold recovery separately. A foreground **Sync Now** result alone does not prove automatic sync.

## 5. Verify redacted local output

Back on the receiver machine, verify without printing raw HealthKit values or secrets:

```bash
uv run health-bridge status --markdown
uv run health-bridge query synced-metrics
```

These commands use the database saved by setup. If you deliberately selected a different database, pass that same existing path with `--db`. The setup terminal and connection page distinguish pairing from the first stored records.

MCP requires the same explicit database path: `uv run health-bridge mcp smoke --db "<database path used by setup>"`. `health-bridge setup --json` reports that path and the exact MCP command without private connection links.

Success means the receiver records a new sync run and local status/MCP output confirms records in aggregate/redacted form. It does not prove guaranteed background freshness; iOS background delivery remains best-effort.

## Cleanup

- Keep the live connection page available while waiting for the first records. Re-run setup to resume; an already paired receiver does not need the obsolete invitation HTML.
- For manually exported Direct invitation files, remove the private copy when handoff is finished or the invitation expires.
- Keep `.tmp/`, receiver databases, local logs, and `scripts/ios-device-local.env` out of Git.
- Revoke old receiver tokens if a setup page or pairing link might have been exposed.

# iOS Self-Build Guide

Apple Health AI Bridge can be tried with synthetic data on any development machine. Real Apple Health sync is a separate developer-preview path that needs an iPhone, a Mac with Xcode, signing access for a local development build, and a receiver URL the iPhone can reach.

This guide is the safe first path for people who want to self-build the iOS companion before an official TestFlight build is available.

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

## 2. Prepare the route and run core setup

Follow [the receiver route guide](setup.md#what-the-receiver-url-means) before generating pairing material. Existing Tailscale users can use Route A; Route B is the agent-assisted private-ingress path; Route C is the explicit local-only fallback.

After the selected route sets `HEALTH_BRIDGE_RECEIVER_URL`, run exactly one setup command. Routes A and B keep the receiver on loopback:

```bash
uv run health-bridge setup \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --db .tmp/device.sqlite \
  --setup-page .tmp/ios-companion-device-session.html
```

Route C instead repeats its deliberate LAN bind and must never be port-forwarded to the public internet:

```bash
uv run health-bridge setup \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --db .tmp/device.sqlite \
  --setup-page .tmp/ios-companion-device-session.html \
  --receiver-host 0.0.0.0 \
  --receiver-port 8765
```

Setup creates the private page and prints the exact receiver command, but its same-host MCP smoke does not prove receiver or phone reachability.

## 3. Supervise, start, and verify the receiver

Put the printed receiver command under the approved service manager and start it. Require `{"status":"ok"}` from the printed local health URL first. Then derive the phone-facing endpoint:

```bash
PHONE_REACHABLE_BASE_URL="${HEALTH_BRIDGE_RECEIVER_URL%/v1/batches}"
```

Open that exact phone-facing `/health` URL on the physical iPhone and require the same response. Routes A and B use HTTPS; Route C deliberately uses HTTP only on the same trusted LAN. Do not substitute `127.0.0.1` in iPhone setup material; that would point to the iPhone itself.

The setup-generated HTML contains a temporary, single-use invitation—not the long-lived device credential. Keep it private and do not open it for pairing until the app build below is installed. If it expires while building or verifying, follow [the documented fresh-invitation recovery](setup.md#start-and-verify-the-receiver) after both health checks pass.

## 4. Build, install, and launch the companion

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

## 5. Pair and sync on the iPhone

Follow the current [Pair the iPhone](setup.md#pair-the-iphone) handoff. If the invitation expired while the app was being built, rotate it only after the receiver and both health checks still pass.

On the iPhone:

1. Open the generated setup page from a trusted path.
2. Import or open the pairing link in the companion.
3. Confirm the app shows the paired receiver.
4. Tap the primary action (`Allow Health access`, `Sync Now`, or `Retry Sync`, depending on state).
5. Grant only the Apple Health read permissions you want to test.

## 6. Verify redacted local output

Back on the receiver machine, verify without printing raw HealthKit values or secrets:

```bash
uv run health-bridge status --db .tmp/device.sqlite --markdown
uv run health-bridge mcp smoke --db .tmp/device.sqlite
```

For active real-device validation, start a watcher from the secret-redacted manifest's `baseline_sync_run_id`:

```bash
uv run health-bridge dev watch-sync-runs \
  --db .tmp/device.sqlite \
  --after-sync-run-id <baseline_sync_run_id> \
  --timeout-seconds 3600
```

Success means the receiver records a new sync run and local status/MCP output confirms records in aggregate/redacted form. It does not prove guaranteed background freshness; iOS background delivery remains best-effort.

## Cleanup

- Delete generated setup pages after pairing.
- Keep `.tmp/`, receiver databases, local logs, and `scripts/ios-device-local.env` out of Git.
- Revoke old receiver tokens if a setup page or pairing link might have been exposed.

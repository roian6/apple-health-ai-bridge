# Set up Health Bridge

> **Unreleased onboarding preview.** Until the immutable `receiver-v1.1.3` release and its assets are published and verified, this guide is an unreleased preview; use the [published Receiver/CLI 1.1.2 guide](https://github.com/roian6/apple-health-ai-bridge/blob/receiver-v1.1.2/docs/setup.md). Direct/Tailscale retains Companion 1.1.1 compatibility. iCloud-native first pairing requires the updated companion and matching signed helper; those updates are not published yet. The coordinated source candidate pairs Receiver/CLI 1.1.3 with Companion 1.1.2/build 62; neither the candidate app nor its matching signed helper is implied to be available by this guide. Existing installations do not change when you read this guide.

## Before you start

You need an iPhone running iOS 18 or later and a macOS or Linux computer to store the receiver database. Keep that computer awake and reachable while syncing; native Windows is not currently supported. Your AI must be able to run commands on that computer, directly or through an existing approved SSH connection.

Health Bridge saves the Apple Health data you choose on this computer. Its background process, called the receiver, accepts data from your iPhone. The recommended connection uses Tailscale, a connection app installed on both devices. Sign in with the same account and keep Tailscale enabled on the iPhone. Setup prepares a private HTTPS connection; it does not log you in or make the computer public. If you already have a prepared HTTPS or same-network connection, choose **More connection options**.

On a Mac, you can instead send data through iCloud Drive using the same Apple Account on both devices. Keep the Mac logged in; delivery can be delayed. Guided setup reuses a matching signed helper and finds its iCloud Documents folder. If the helper is missing, setup offers to discover, download and verify the exact signed release. If it is unavailable, choose Tailscale, return to connection choices or pause. Selecting local ZIP/manifest files remains an advanced offline option. **The signed 1.1.3 helper release is not publicly available yet.** An older helper cannot substitute for it. In this candidate, both first pairing and subsequent delivery use iCloud; the iPhone needs no Tailscale or prepared receiver address. Use the updated companion for this path, not the currently published app. See [Mac iCloud details](icloud-mailbox-service.md) for advanced configuration.

## 1. Install the receiver and run setup

The Python package and optional npm thin launcher use the same receiver and CLI. The launcher requires Node.js 18 or newer with npm/npx and manages its private Python runtime; it does not require the user to install Python separately. There is no published npm/PyPI install target yet for this preview. Use only the exact GitHub assets after the availability condition above is met; unpublished test archives are not replacements for the immutable release.

After publication and verification, install the receiver:

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.1.3"
```

For the optional one-shot Node path, use the exact release archive:

```bash
npm exec --yes --package="https://github.com/roian6/apple-health-ai-bridge/releases/download/receiver-v1.1.3/apple-health-ai-bridge-0.1.0.tgz" -- health-bridge setup
```

The commands below assume the installed `health-bridge` command is on PATH. If you use a one-shot npm runner instead, keep that same approved runner prefix for setup and later queries; do not install a second receiver to obtain a different command.

For the Python installation, run:

```bash
health-bridge setup
```

On a human stdin/stdout terminal, an existing or explicitly configured connection resumes directly. Fresh setup offers **Tailscale (Recommended)**, **iCloud Mailbox (Mac only, Beta)** on a Mac, **More connection options**, and **Set up later**. Prerequisites appear before selection. More connection options reuses already-prepared HTTPS or a same-network-only LAN route. Use arrows and Enter, or Esc to leave; `NO_COLOR` and dumb terminals use numbered choices. EOF or Ctrl-C pauses safely. If Tailscale is unavailable, you can open its official setup page, prepare it yourself and retry, supply an existing private URL, or leave. Setup does not install or log in to a provider for you.

Continuing explicitly opts into a supervised per-user receiver and its private route. Setup initializes or reuses the database, installs and starts the owned Linux systemd or Mac LaunchAgent service, checks receiver readiness, prepares an invitation and remembers the database and setup options. It refuses to replace a conflicting service or route. Explicit flags override remembered defaults.

Guided setup opens the **private connection URL** in a local desktop browser when available. A headless terminal provides the URL for a trusted screen or your iPhone. The terminal and page follow the same persisted pairing and receipt state: connection alone and empty diagnostic uploads do not complete setup. Terminal waiting stops after ten minutes; unpaired invitations also stop at their original expiry. An already paired installation can resume local progress after page expiry, and Ctrl-C retains the running receiver. The page updates while visible until completion or original expiry (normally 20 minutes); pairing does not extend it.

`setup --no-input` and `setup --json` never prompt, wait, open a browser or configure an AI client. Combining either with `--configure-client` is rejected before preparation. Captured output contains no invitation URL or QR; run setup in a human terminal for that handoff. Detailed redacted service, route, path and MCP information remains available in `setup --json`.

If setup reports a missing prerequisite or unavailable route, resolve that specific problem before pairing. A successful local health check does not prove that the iPhone can reach the computer. Re-running setup reuses the owned healthy receiver and remembered database; it does not reset data, replace a paired device or change the app's Automatic Sync setting. A still-usable invitation is reused; when a new invitation is needed, use the newly printed connection URL.

## 2. Pair the iPhone and start syncing

Download [Health Bridge for AI from the App Store](https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806), or keep your compatible installed companion. TestFlight remains available for beta builds.

Open the connection page on the computer and scan its QR with iPhone Camera. If the page is already open in iPhone Safari, tap **Open in Health Bridge for AI**. The app also accepts the setup link or server address plus invitation code as fallbacks; see [pairing details](pairing.md).

If you need to install Health Bridge for AI (companion app), return to the connection page afterward and tap **Open in Health Bridge for AI**. After connecting, tap **Allow Health Access**, select the Apple Health read permissions you want to grant, then turn on **Automatic Sync**, which starts OFF. To re-request access, use **Request Health Access Again**. HealthKit stays read-only. **Sync Now** is an optional immediate delivery test.

Re-running receiver setup preserves the app's Automatic Sync setting. iOS decides when background delivery runs, so a sleeping receiver, disconnected private network or unavailable Health data can delay updates. The page confirms stored records, not all types, current observation dates or future background timing.

## 3. Read the stored data with your AI

On the receiver computer, start with:

```bash
health-bridge status --json
health-bridge query synced-metrics
```

Setup remembers the database; normal queries do not need `--db`. Give your agent the packaged [Health Bridge Skill](../skills/health-bridge/SKILL.md) and command access to the receiver computer, directly or through an existing approved SSH connection. Setup does not grant AI execution access. The agent should check stored metric coverage and observation dates before answering, and distinguish missing data from zero activity. Existing records remain readable even when setup is waiting for a new confirmed health-data upload.

Guided setup finishes only after records arrive from the connected iPhone, are saved, and a read-only query returns saved data. Run `health-bridge query synced-metrics` to see the saved kinds of data and their dates. Give your AI command access to this computer and the Health Bridge Skill to ask questions about those records. Setup does not automatically connect an AI app. Optional MCP connection settings are available through `--configure-client` without `--json` or `--no-input`; a failed AI-app connection keeps your saved data and command access intact.

For example, ask: “Summarize the sleep records stored for the last seven days and tell me about any gaps.” Use `health-bridge query --help` to choose a query, then its `--help` for date ranges. Queries return structured JSON. MCP is optional for the CLI/Skill path.

## Existing-route options

These options preserve deliberate Direct/Tailscale/LAN deployments. Do not replace a working route just to follow the default setup path.

### Already use Tailscale

Without `--receiver-url`, setup finds this computer's Tailscale hostname and prepares a private HTTPS connection using Tailscale Serve. Sign in to Tailscale with the same account on both devices and keep it enabled on the iPhone. Existing unrelated Serve mappings are not overwritten; a conflict is reported instead. Tailscale is optional when another suitable connection already exists.

### Agent-assisted private HTTPS ingress

If you already operate a suitable HTTPS tunnel or reverse proxy, keep the receiver on loopback and pass its real batch URL:

```bash
health-bridge setup --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL"
```

`HEALTH_BRIDGE_RECEIVER_URL` must be the actual phone-reachable `/v1/batches` endpoint, not an example hostname. Its origin must also route `/health`, `/setup` and `/v1/pairing/redeem` to the receiver. Explicitly supplying the URL does not ask setup to install or reconfigure a tunnel provider.

If no suitable private route exists, choose one with the user before changing DNS, tunnels, proxies, firewall rules or network exposure. An agent must not create a provider account, activate a paid plan, start a trial, accept provider terms or incur charges without previewing that action and obtaining explicit approval for each account or billing effect. Logging in is not that approval. A public HTTPS endpoint is not automatically private.

### Local-network-only route

This local-network-only route is available when off-network sync is not needed:

```bash
health-bridge setup \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --receiver-host 0.0.0.0 \
  --receiver-port 8765
```

Use the real LAN `/v1/batches` URL. Numeric LAN IPs are supported, but a DHCP reservation or stable local hostname avoids re-pairing after address changes. On a Mac, `scutil --get LocalHostName` identifies the hostname normally used with `.local`. A bare IP may not trigger Apple's Local Network permission correctly; the Local Network permission alert may fail, so prefer a working hostname when necessary. If Tailscale is using an exit node, **Allow LAN access** may be needed.

This route deliberately uses HTTP only on the same trusted LAN and stops working when the phone leaves it. Do not expose port 8765 directly to the public internet. Loopback addresses such as `127.0.0.1` point at the iPhone itself when used in phone setup material.

## Troubleshooting

- **The connection page is not ready:** check the setup error and the receiver's local health endpoint. Do not pair against an unstarted service or replace another application's occupied port.
- **The computer works but the iPhone cannot connect:** check the exact phone-facing `/health` URL in iPhone Safari, private-network connectivity and the host's sleep/firewall state. Do not disable certificate checks or iOS transport security.
- **The page expired or became unavailable:** run the same setup command to check the existing connection. An already paired device stays paired; use the CLI to check its confirmed upload state. If pairing is still pending, use the newly printed private URL. Revoked devices or tokens cannot read progress through the old page.
- **No data after pairing:** review the app's sync state and Apple Health permissions. Permission denial and unavailable types are intentionally indistinguishable to an app; an empty accepted upload is not proof of stored coverage.
- **A metric is missing or stale:** query `synced-metrics` and the requested observation period. A supported-type list or recent ingestion timestamp is not evidence of current observations.
- **Pairing material was exposed:** stop using it; explicitly rotate the invitation or revoke the affected device/token as appropriate. Never publish connection URLs, QR images, invitation codes, credentials, database paths or raw health records in support reports.

## Remove local bridge data

Removing local bridge data is separate from normal setup and sync. Stop the receiver first, then preview the existing purge command (a dry-run without `--confirm`):

```bash
health-bridge receiver purge --db ~/.local/share/health-bridge/health.sqlite
```

Review the listed SQLite database and sidecars before adding `--confirm`. The command refuses confirmation while the receiver is using the database. This does not delete Apple Health data on the iPhone. If it reports `recovery-required`, preserve the private quarantine and do not restart the receiver until recovery has been reviewed.

The app's **Reset Private Sync State** is also destructive and user-confirmed. It clears receiver-scoped cursors, proofs, journals and queued uploads only after closing admission and draining active work. Disconnect or a new connection never adopts a previous connection's queued data; see [private-state details](pairing.md).

## Browser and advanced connection choices

Use my own secure connection (advanced) requires an already configured secure route from your iPhone to this computer. An ordinary website is not a receiver, and typing a URL creates no route. Choose guided Tailscale if unsure. The route must forward /health, /setup, /v1/pairing/redeem and /v1/batches.

Setup always prints its private human-copyable URL, even if the browser opens. Use --no-browser or an SSH terminal to keep browser launch disabled. A direct-route URL can be opened on a trusted computer or iPhone with that route. The iCloud loopback setup page is local-only: use the Mac's screen or trusted screen sharing on a headless Mac Mini, then scan its QR. Do not open that loopback URL directly on the iPhone. Keep the setup URL private; JSON and captured machine status withhold it.

A timeout or Ctrl-C keeps the connection and saved data. Check the iPhone's Health access, Automatic Sync and network/iCloud prerequisites, then rerun setup. Completion still requires stored health records and successful readback. [Connect an AI app](connect.md) during successful setup or later with health-bridge connect.

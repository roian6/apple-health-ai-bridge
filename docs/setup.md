# Set up Health Bridge for AI

The normal path is: install the iPhone companion, prepare a receiver on the computer that will store your data, establish a private route that the iPhone can reach away from home, pair once, and leave Automatic Sync enabled.

## Before you start

You need:

- an iPhone running iOS 18 or later;
- an approved build shown on the [Health Bridge install status page](https://healthbridge.chanhyo.dev/install/), or a self-build;
- a macOS or Linux computer for the receiver and private database; native Windows is not currently supported;
- [`uv`](https://docs.astral.sh/uv/);
- for continuous sync away from home, either an existing Tailscale connection or an agent-managed private HTTPS ingress; for an explicit local-only evaluation, a same-LAN route with the limitations below;
- optionally, direct terminal access or a same-host stdio MCP client.

## What the receiver URL means

The receiver URL is the exact address the iPhone uses to upload to the receiver computer. **The project does not issue this URL**, and a documentation hostname is not a working endpoint. The URL must:

- for continuous sync, be reachable from the physical iPhone on Wi-Fi and cellular data and use a stable private HTTPS route;
- for an explicit local-only evaluation, be reachable from the iPhone on that LAN and be understood to stop working when the phone leaves it;
- end exactly in `/v1/batches`;
- route the same origin's `/health` and `/v1/pairing/redeem` paths to the receiver;
- remain available whenever automatic sync should succeed.

A local-network-only route stops syncing when the iPhone leaves that network. It remains useful for development and explicit local-only use, but it is not the primary continuous-sync path.

Choose one of the following routes **before** running `health-bridge setup`.

## Route A: Already use Tailscale

This is the shortest supported remote path for someone who already uses Tailscale. It is not a product requirement, and the setup guide does not ask a new user to adopt Tailscale by default.

Prerequisites:

1. Tailscale is already installed and signed in on the receiver computer and iPhone.
2. Both devices are in the same tailnet.
3. Tailscale is connected on the iPhone.
4. The receiver computer can remain awake and connected when automatic sync is expected.
5. Every Route A deployment has a least-privilege Tailscale [grant](https://tailscale.com/docs/features/access-control/grants) (or an existing ACL policy) restricting TCP `8443` on this receiver to the intended user or device. Do not rely on a default allow-all policy for a health-data receiver. On a personal tailnet, review its member and device list; on a shared tailnet, also verify that a non-granted identity cannot open the route.

On the receiver computer, inspect the current device Serve configuration first:

```bash
tailscale version
tailscale status
tailscale serve status
```

If HTTPS port `8443` already has a handler, stop and have the installer preserve the existing service instead of replacing it. Port `8443` is used here to keep Health Bridge separate from a common HTTPS `443` handler.

When port `8443` is available, configure an explicit private HTTPS listener that proxies to the receiver's loopback backend:

```bash
tailscale serve --bg --https=8443 http://127.0.0.1:8765
tailscale serve status
```

The final status must show the HTTPS `8443` handler proxying to `http://127.0.0.1:8765`. Use Serve, not Funnel. Funnel publishes a service to the public internet; this path is intended to stay inside your tailnet. If Tailscale asks an administrator to enable HTTPS or Serve, follow the official Tailscale prompt and then rerun the command.

To remove only this Health Bridge listener later, coordinate so no other administrator changes Serve during rollback. Immediately before removal, run `tailscale serve status` and confirm the HTTPS `8443` handler still points to `http://127.0.0.1:8765`. If it has changed or the result is ambiguous, stop and preserve the newer configuration. If it still matches, use the same listener flag with `off`:

```bash
tailscale serve --https=8443 off
tailscale serve status
```

The final status must show only that the Health Bridge handler is gone. This rollback targets HTTPS `8443` with `off` and never invokes the whole-configuration `reset` command; do not substitute `reset`.

Build the exact batch URL from the current node's Tailscale DNS name, then run setup:

```bash
TAILSCALE_DNS_NAME="$(
  tailscale status --json |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
)"
: "${TAILSCALE_DNS_NAME:?Tailscale did not report a DNS name; enable the required tailnet DNS/HTTPS feature and retry}"
export HEALTH_BRIDGE_RECEIVER_URL="https://${TAILSCALE_DNS_NAME}:8443/v1/batches"

uv tool install "git+https://github.com/roian6/apple-health-ai-bridge.git@v1.0.0"
health-bridge setup --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL"
```

Setup keeps the receiver on its safe loopback default, which is the correct backend for Tailscale Serve. It creates private state and a pairing page whose single-use invitation normally expires in about 20 minutes, prints the receiver launch command, and verifies only the same-host MCP process. It does **not** prove that the iPhone can reach the receiver.

Before treating Route A as a continuous-sync installation, have the installer put the printed receiver command under the host's existing service manager. The reviewed service plan must run as the receiver owner, start at boot, restart on failure, preserve the loopback bind and private database path, keep health values and credentials out of logs, and include exact stop/disable/remove rollback commands. Tailscale Serve persists only the network route; until supervision passes, sync works only while the foreground receiver process remains running.

Start and enable the supervised receiver service. For a temporary evaluation only, run the printed foreground command instead. Then verify the exact route from the iPhone before scanning the pairing QR:

1. Remove `/v1/batches` from `HEALTH_BRIDGE_RECEIVER_URL` and append `/health`.
2. Open that HTTPS health URL in Safari on the iPhone while Tailscale is connected.
3. Require the response `{"status":"ok"}`.
4. Only then open the private pairing page on the receiver computer and scan its QR with iPhone Camera.

If the iPhone cannot open `/health`, do not create another invitation yet. Check Tailscale connection state, Serve status, MagicDNS/HTTPS availability, the grant or ACL, and whether the supervised receiver process is running.

If the original invitation expired while supervision or route checks were being completed, create a fresh same-label invitation only after `/health` succeeds. The new invitation rotates the previous active same-label invitation:

```bash
health-bridge receiver create-pairing \
  --db ~/.local/share/health-bridge/health.sqlite \
  --label iPhone \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --format setup-page \
  --setup-page ~/.local/share/health-bridge/iphone-setup.html
```

Open only the newly written private page and delete the stale page if it was saved elsewhere.

## Route B: Agent-assisted private HTTPS ingress

Use this path when the receiver or AI-agent host already has—or can deliberately provision—a stable private HTTPS ingress without requiring Tailscale. The phone-facing side must be HTTPS with a certificate trusted by iOS. Plain HTTP may be used only from the reverse proxy to `127.0.0.1:8765` on the same host.

A reverse proxy alone does not create internet reachability. The host still needs an intentional private-network route, secure outbound tunnel, or other reviewed ingress that the iPhone can use away from home. An unguessable hostname is not an access-control boundary.

Ask the setup agent to follow this provider-neutral ingress checklist:

1. **Discover without changing the host.** Inspect the OS, existing private-network clients, DNS and HTTPS ingress or tunnel services, reverse proxies, firewall, service manager, and whether port `8765` is already in use. Do not install a provider, change DNS, open a firewall port, publish a service, or run `health-bridge setup` during discovery.
2. **Return a reviewable plan.** Show the proposed topology, provider or account prerequisites, exact DNS/ingress/firewall/service changes, whether the route is private or publicly reachable, rollback steps, and privacy/exposure trade-offs. Wait for explicit approval before applying the plan.
3. **Keep the receiver private.** Bind Health Bridge to `127.0.0.1:8765`; terminate phone-facing TLS at the approved proxy or tunnel. Do not expose port `8765`, use plain HTTP toward the phone, use a self-signed certificate, treat an unguessable hostname as security, enable Tailscale Funnel, or add a browser-login layer that the iOS app cannot satisfy.
4. **Proxy only the phone protocol.** On one HTTPS origin, allow `GET /health`, `POST /v1/batches`, and `POST /v1/pairing/redeem`. Preserve the `Authorization` header and request bodies. Permit batches up to `5,000,000` bytes and pairing redemption bodies up to `4,096` bytes. Disable request-body and authorization-header logging. Supervise the receiver process and TLS certificate renewal.
5. **Stop at a public-only design.** If the only workable route is publicly reachable, do not silently publish it. Explain that it needs a deployment-specific hardening review outside this private-ingress guide.
6. **Verify before pairing.** After the approved route exists, set `HEALTH_BRIDGE_RECEIVER_URL` to the exact origin plus `/v1/batches` and run `health-bridge setup`. Immediately start the printed receiver command, check `GET /health` locally, and then open the exact HTTPS `/health` URL from the physical iPhone. Only after both health checks pass should the user open the generated pairing page and scan its QR.

Do not print or paste the private URL, pairing page, QR payload, invitation, receiver credential, or database into public chat, issues, logs, or documentation.

The agent should finish with a redacted handoff containing:

- whether the receiver service is running;
- whether the local `/health` check passed;
- whether the physical iPhone opened the exact HTTPS `/health` URL;
- the local path of the private pairing page, without its contents;
- the next single user action;
- rollback commands for every network or service change.

If no suitable private route exists, the agent must stop and present the infrastructure choices rather than inventing an endpoint or silently making the receiver public.

## Install and run core setup

If Route A did not already install the package, install the signed release after `v1.0.0` appears on the project's GitHub Releases page:

```bash
uv tool install "git+https://github.com/roian6/apple-health-ai-bridge.git@v1.0.0"
```

After Route A or Route B has set `HEALTH_BRIDGE_RECEIVER_URL` to a real, configured `/v1/batches` URL:

```bash
health-bridge setup --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL"
```

Core setup:

- creates owner-only private state and a single-use pairing page;
- prepares a receiver launch command;
- creates a client-neutral local stdio MCP access descriptor;
- runs a same-host Health Bridge MCP self-test;
- detects known client adapters without modifying them.

It does **not** configure any AI or MCP client by default. Adding a client creates a new process that can read the private health database, so that action requires an explicit choice.

For automation or review, request the secret-redacted onboarding schema:

```bash
health-bridge setup \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --json
```

The JSON contains `access_descriptors`, not a supposedly universal client config. A local descriptor identifies the MCP protocol, stdio transport, executable, arguments, optional working directory, and environment references.

The command creates owner-only files under `~/.local/share/health-bridge/`. The generated pairing HTML is secret because it contains a temporary single-use invitation. Do not paste it into chat, commit it, or place it on a web server.

## Start and verify the receiver

Run the `receiver_start_command` printed by setup as a supervised process. A private HTTPS proxy or tunnel should keep the receiver on the safe loopback default. Do not expose port 8765 directly to the public internet.

The printed `receiver_health_url` should return:

```json
{"status":"ok"}
```

A successful check from the receiver host proves local readiness. A successful check from the physical iPhone over the chosen route proves phone reachability. The local MCP smoke proves neither.

The current setup command prepares the exact launch command but does not install an operating-system service. Use the existing supervised service or agent-managed service plan approved in Route B.

## Pair the iPhone

Pair only after the receiver and phone route are ready:

1. On the receiver computer, open the generated pairing HTML file on a trusted screen. If the receiver is headless, securely copy that one file to a trusted local screen; do not publish it or place it on a web server.
2. Scan the displayed QR with iPhone Camera and open the setup link. As a fallback, open the securely transferred HTML on the iPhone and tap its pairing button.
3. Confirm the receiver connection in Health Bridge for AI.
4. Tap **Allow Health Access**.
5. Review Apple’s native HealthKit authorization sheet.
6. Enable **Automatic Sync**.

The app asks for all runtime-supported read types in one authorization flow. Apple’s sheet lets you allow or deny individual types.

## Verify the first sync

```bash
health-bridge status \
  --db ~/.local/share/health-bridge/health.sqlite \
  --json
```

Then call `get_bridge_status` or `list_synced_metrics`, or use the direct read-only query CLI. Missing data must be reported as unknown; it may mean no record, denied permission, source gaps, or sync gaps.

## Connect an MCP client intentionally

Configure only a client you intend to grant health-data access:

```bash
health-bridge setup \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --configure-client hermes
```

`--configure-client` is repeatable, but configuring more than one client grants each one access. Non-interactive and `--json` runs still make no client changes unless this option is present.

For another same-host stdio MCP client, render `access_descriptors` into that client's documented configuration schema. Do not copy a root key from an unrelated product.

## Local-network-only fallback

Use direct LAN access only when you deliberately accept that sync stops away from that LAN. Numeric LAN IPs are supported, but DHCP may change them. On macOS, `scutil --get LocalHostName` can provide a Bonjour name; append `.local` and port `8765` for a same-LAN route.

Direct LAN HTTP requires an explicit non-loopback `--receiver-host`, matching receiver port, and iOS Local Network access. Plain HTTP exposes health payloads and the device credential to that LAN while in transit. The Local Network permission alert may fail to resolve the first attempt if access is denied or the route does not recover in time. If an exit node is active, enable **Allow LAN access** or use the private HTTPS route instead.

This fallback is not the recommended continuous-sync configuration.

## Deployment boundaries

- Keep SQLite on the receiver host. Do not share it over a network mount.
- A same-host stdio MCP descriptor does not create remote MCP access.
- Container/NAS deployment is not yet first-class; supervision, persistent paths, private HTTPS routing, and pairing handoff remain operator responsibilities.
- Health Bridge does not silently downgrade HTTPS to HTTP or discover and trust endpoints automatically.
- A public reverse proxy is not automatically private or hardened merely because it uses TLS.

## Remove local bridge data

Stop the receiver first. The command is a dry-run unless `--confirm` is present:

```bash
health-bridge receiver purge --db ~/.local/share/health-bridge/health.sqlite
```

Review the listed SQLite database and sidecars, then repeat with `--confirm` to remove only that local bridge scope. The command refuses confirmation while the receiver is using the database. This does not delete Apple Health data on the iPhone.

If the command returns `recovery-required`, do not restart the receiver. Review the structured source, quarantine, and truncated path lists; the command preserves the private quarantine rather than reporting a false rollback after an irreversible partial purge.

## Troubleshooting

### The iPhone cannot reach the receiver

- Test the exact HTTPS `/health` URL from the iPhone, not only from the receiver host.
- Confirm the receiver process and reverse proxy or tunnel are both running.
- For Tailscale, confirm both devices are in the same tailnet, the iPhone tunnel is connected, Serve is active, and Funnel is not in use.
- If Tailscale uses an exit node while you test a LAN fallback, enable **Allow LAN access**.
- Confirm that host, scheme, and port did not change after invitation creation.
- Do not work around certificate errors by trusting a self-signed certificate or disabling iOS transport security.
- Do not publish the pairing page while troubleshooting.

### No MCP client was configured

This is the safe default. Use `--configure-client hermes` or `--configure-client openclaw` only after deciding that client should gain access.

### Health types are missing

Open iOS Settings and review Health permissions for Health Bridge. The app requests every implemented type available on the current runtime, but Apple may withhold types that are unavailable, restricted, or denied.

### Pairing material was exposed

Do not use it. Create a fresh setup invitation and revoke the affected paired device or token from the receiver CLI.

## Private-state and connection safety

**Reset Private Sync State** is intentionally destructive and user-confirmed. The app first closes upload admission, stops HealthKit background delivery, cancels active work, and revalidates the connection generation. Only after those barriers does it remove receiver-scoped cursors, proofs, journals, and queued payloads. Launch recovery completes an interrupted clear before automatic sync can resume.

Disconnect and every connection replacement use the same local terminal barrier. Disconnect completes locally only after active pairing, foreground uploads, and restored background tasks have drained and saved settings are cleared. A different connection never adopts an old connection's queued records; mismatched or unknown items remain quarantined until the user explicitly deletes queued uploads.

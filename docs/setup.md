# Set up Health Bridge for AI

The normal path is: install the iPhone companion, prepare a receiver on the computer that will store your data, establish a private route that the iPhone can reach away from home, pair once, and leave Automatic Sync enabled.

## Before you start

You need:

- an iPhone running iOS 18 or later;
- an approved build shown on the [Health Bridge install status page](https://healthbridge.chanhyo.dev/install/), or a self-build;
- a macOS or Linux computer for the receiver and private database; native Windows is not currently supported;
- [`uv`](https://docs.astral.sh/uv/);
- for continuous sync away from home, either an existing Tailscale connection or an agent-assisted private HTTPS ingress; for an explicit local-only evaluation, a same-LAN route with the limitations below;
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

Build the exact batch URL from the current node's Tailscale DNS name. This route-preparation step only sets the URL; continue with the common setup sequence below:

```bash
TAILSCALE_DNS_NAME="$(
  tailscale status --json |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
)"
: "${TAILSCALE_DNS_NAME:?Tailscale did not report a DNS name; enable the required tailnet DNS/HTTPS feature and retry}"
export HEALTH_BRIDGE_RECEIVER_URL="https://${TAILSCALE_DNS_NAME}:8443/v1/batches"
```

## Route B: Agent-assisted private HTTPS ingress

Use this path when the receiver or AI-agent host already has—or can deliberately provision—a stable private HTTPS ingress without requiring Tailscale. The phone-facing side must be HTTPS with a certificate trusted by iOS. Plain HTTP may be used only from the reverse proxy to `127.0.0.1:8765` on the same host.

A reverse proxy alone does not create internet reachability. The host still needs an intentional private-network route, secure outbound tunnel, or other reviewed ingress that the iPhone can use away from home. An unguessable hostname is not an access-control boundary.

Ask the setup agent to follow this provider-neutral ingress checklist:

1. **Discover without changing the host.** Inspect the OS, existing private-network clients, DNS and HTTPS ingress or tunnel services, reverse proxies, firewall, service manager, and whether port `8765` is already in use. Do not install a provider, change DNS, open a firewall port, publish a service, or run `health-bridge setup` during discovery.
2. **Return a reviewable plan.** Show the proposed topology, provider or account prerequisites, exact DNS/ingress/firewall/service changes, whether the route is private or publicly reachable, rollback steps, and privacy/exposure trade-offs. Wait for explicit approval before applying the plan.
3. **Keep the receiver private.** Bind Health Bridge to `127.0.0.1:8765`; terminate phone-facing TLS at the approved proxy or tunnel. Do not expose port `8765`, use plain HTTP toward the phone, use a self-signed certificate, treat an unguessable hostname as security, enable Tailscale Funnel, or add a browser-login layer that the iOS app cannot satisfy.
4. **Proxy only the phone protocol.** On one HTTPS origin, allow `GET /health`, `POST /v1/batches`, and `POST /v1/pairing/redeem`. Preserve the `Authorization` header and request bodies. Permit batches up to `5,000,000` bytes and pairing redemption bodies up to `4,096` bytes. Disable request-body and authorization-header logging. Supervise the receiver process and TLS certificate renewal.
5. **Stop at a public-only design.** If the only workable route is publicly reachable, do not silently publish it. Explain that it needs a deployment-specific hardening review outside this private-ingress guide.
6. **Prepare the common handoff.** After the approved route exists, set `HEALTH_BRIDGE_RECEIVER_URL` to the exact origin plus `/v1/batches`. Do not claim phone reachability yet; continue with common setup, receiver start, and physical-iPhone verification below.

Do not print or paste the private URL, pairing page, QR payload, invitation, receiver credential, or database into public chat, issues, logs, or documentation.

The agent should finish route preparation with a redacted handoff containing:

- confirmation that `HEALTH_BRIDGE_RECEIVER_URL` is set locally, without printing its value;
- the loopback backend and planned supervised service;
- the exact local and phone-facing health checks to run after receiver start, without private host details;
- the next common setup command;
- rollback commands for every network or service change.

After the common verification sequence, the handoff must be updated with whether both health checks passed and the next single physical-iPhone action.

If no suitable private route exists, the agent must stop and present the infrastructure choices rather than inventing an endpoint or silently making the receiver public.

## Route C: Local-network-only fallback

Use this route only for development, evaluation, or a deliberate same-LAN installation. Sync stops whenever the iPhone leaves that LAN. The phone-facing connection is plain HTTP, so health payloads and the device credential are visible to that LAN while in transit. Use only a trusted, isolated network; never forward receiver port `8765` from the router to the public internet.

Set `HEALTH_BRIDGE_LAN_HOST` to the receiver's real, stable LAN hostname or private address. On macOS, a Bonjour hostname can be derived without inventing a sample endpoint:

```bash
export HEALTH_BRIDGE_LAN_HOST="$(scutil --get LocalHostName).local"
```

On Linux, have the installer select and verify the actual LAN address that belongs to the receiver's intended interface; do not blindly choose the first address when VPN, container, or multiple network interfaces exist. Numeric LAN IPs are supported, but DHCP may change them, so reserve the address or update and re-pair after a change. Then set the exact URL locally:

```bash
: "${HEALTH_BRIDGE_LAN_HOST:?Set this to the receiver's verified LAN hostname or private address}"
export HEALTH_BRIDGE_RECEIVER_URL="http://${HEALTH_BRIDGE_LAN_HOST}:8765/v1/batches"
```

Continue with the common setup sequence below. Route C must use its explicit `0.0.0.0:8765` bind; Routes A and B keep the loopback default.

After setup, use the printed receiver command with the same bind and port. Keep the iPhone on that LAN, grant the app's iOS Local Network permission, derive the health URL as `${HEALTH_BRIDGE_RECEIVER_URL%/v1/batches}/health`, and open that exact URL on the physical iPhone before pairing. The Local Network permission alert may fail to resolve the first attempt if access is denied or the route does not recover in time. If an exit node is active, enable **Allow LAN access** or use Route A or Route B instead.

## Install and run core setup

Install the signed release after `v1.0.0` appears on the project's GitHub Releases page:

```bash
uv tool install "git+https://github.com/roian6/apple-health-ai-bridge.git@v1.0.0"
```

After the selected route has set `HEALTH_BRIDGE_RECEIVER_URL` to its real, configured `/v1/batches` URL, run exactly one setup command.

For Route A or Route B, keep the safe loopback bind:

```bash
health-bridge setup --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL"
```

For Route C, explicitly bind to the LAN interface and matching port:

```bash
health-bridge setup \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --receiver-host 0.0.0.0 \
  --receiver-port 8765
```

Core setup:

- creates owner-only private state and a single-use pairing page;
- prepares a receiver launch command;
- creates a client-neutral local stdio MCP access descriptor;
- runs a same-host Health Bridge MCP self-test;
- detects known client adapters without modifying them.

It does **not** configure any AI or MCP client by default. Adding a client creates a new process that can read the private health database, so that action requires an explicit choice.

For automation or review, append `--json` to the exact Route A/B or Route C setup command above. The result is a secret-redacted onboarding schema.

The JSON contains `access_descriptors`, not a supposedly universal client config. A local descriptor identifies the MCP protocol, stdio transport, executable, arguments, optional working directory, and environment references.

The command creates owner-only files under `~/.local/share/health-bridge/`. The generated pairing HTML is secret because it contains a temporary, single-use invitation that normally expires in about 20 minutes. Do not paste it into chat, commit it, or place it on a web server.

## Start and verify the receiver

Run the `receiver_start_command` printed by setup as a supervised process. For Route A or Route B, keep the loopback bind behind the private HTTPS route. Route C deliberately uses the printed `0.0.0.0:8765` LAN bind and must never be port-forwarded to the public internet.

The current setup command prepares the exact launch command but does not install an operating-system service. The installer must use the host's existing service manager, run as the receiver owner, start at boot, restart on failure, keep health values and credentials out of logs, and provide exact stop/disable/remove rollback commands. Until supervision passes, sync works only while the foreground receiver process remains running.

The printed `receiver_health_url` should return:

```json
{"status":"ok"}
```

Verify in this order:

1. Check the printed health URL from the receiver host to prove local readiness.
2. Derive the phone-facing health URL as `${HEALTH_BRIDGE_RECEIVER_URL%/v1/batches}/health`.
3. Open that exact URL on the physical iPhone. Routes A and B require their private HTTPS connection; Route C requires the same trusted LAN and iOS Local Network permission.
4. Require `{"status":"ok"}` before opening any pairing page.

The local MCP smoke proves neither receiver readiness nor phone reachability. If the physical-iPhone check fails, keep the pairing page private and fix the selected route, service, and access policy first.

If the original invitation expires during service or route verification, create a fresh same-label invitation only after both health checks pass. This rotates the previous active same-label invitation:

```bash
health-bridge receiver create-pairing \
  --db ~/.local/share/health-bridge/health.sqlite \
  --label iPhone \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --format setup-page \
  --setup-page ~/.local/share/health-bridge/iphone-setup.html
```

Open only the newly written private page and securely remove stale copies from every location where they were saved or transferred.

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

Configure only a client you intend to grant health-data access. Append `--configure-client hermes` (or another documented client name) to the same Route A/B or Route C setup command used above; Route C must repeat its explicit `--receiver-host` and `--receiver-port` flags.

`--configure-client` is repeatable, but configuring more than one client grants each one access. Non-interactive and `--json` runs still make no client changes unless this option is present.

For another same-host stdio MCP client, render `access_descriptors` into that client's documented configuration schema. Do not copy a root key from an unrelated product.

## Deployment boundaries

- Keep SQLite on the receiver host. Do not share it over a network mount.
- A same-host stdio MCP descriptor does not create remote MCP access.
- Container/NAS deployment is not yet first-class; supervision, persistent paths, private HTTPS routing, and pairing handoff remain operator responsibilities.
- Health Bridge does not silently downgrade HTTPS to HTTP or discover and trust endpoints automatically.
- A public reverse proxy is not automatically private or hardened merely because it uses TLS.
- Do not expose port 8765 directly to the public internet.

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

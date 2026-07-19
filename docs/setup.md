# Set up Health Bridge for AI

The normal path is: install an approved iPhone companion build, prepare a receiver on the computer that will store your data, pair once, and leave Automatic Sync enabled. The install status page is authoritative about whether a public TestFlight build is currently available; use the self-build path until it is.

## Before you start

You need:

- an iPhone running iOS 18 or later;
- an approved build shown on the [Health Bridge install status page](https://healthbridge.chanhyo.dev/install/), or a self-build;
- a macOS or Linux computer for the receiver and private database; native Windows is not currently supported;
- [`uv`](https://docs.astral.sh/uv/);
- a phone-reachable private URL for the receiver;
- optionally, direct terminal access or a same-host stdio MCP client.

The receiver URL must end in `/v1/batches`. Prefer HTTPS over Tailscale or another private network. Plain HTTP can be acceptable on a trusted local network, but it exposes health payloads and the device credential to that network while in transit.

## Install and prepare

Run the version-pinned install after `v1.0.0` appears on the project's GitHub Releases page:

```bash
uv tool install "git+https://github.com/roian6/apple-health-ai-bridge.git@v1.0.0"

health-bridge setup \
  --receiver-url https://your-private-host.example/v1/batches
```

Core setup:

- creates private state and a single-use pairing page;
- prepares a receiver launch command;
- creates a client-neutral local stdio MCP access descriptor;
- runs a Health Bridge MCP self-test;
- detects known client adapters without modifying them.

It does **not** configure any AI or MCP client by default. Adding a client creates a new process that can read the private health database, so that action requires an explicit choice.

For automation or review, request the secret-redacted onboarding schema:

```bash
health-bridge setup \
  --receiver-url https://your-private-host.example/v1/batches \
  --json
```

The JSON contains `access_descriptors`, not a supposedly universal client config. A local descriptor identifies:

- protocol: MCP;
- transport: stdio;
- executable and arguments;
- optional working directory;
- environment references.

It is equivalent to:

```bash
health-bridge mcp start \
  --db ~/.local/share/health-bridge/health.sqlite
```

Client configuration roots such as `mcpServers` or `servers` are product conventions, not part of the MCP transport standard. A client adapter must render the canonical descriptor into that client's documented format.

The command creates owner-only files under `~/.local/share/health-bridge/`. The generated pairing HTML is secret because it contains a temporary single-use invitation. Do not paste it into chat, commit it, or place it on a public web server.

## Start the receiver

Run the `receiver_start_command` printed by setup as a supervised process on the machine your iPhone can reach. The safe default bind address is loopback. A trusted-LAN deployment must opt into a non-loopback bind explicitly, and a reverse proxy should keep the receiver on loopback.

Check readiness with the printed `receiver_health_url`. A successful response is:

```json
{"status":"ok"}
```

The current setup command prepares the exact launch command but does not install an operating-system service. Use your normal service manager until the cross-platform service installer is available.

## Pair the iPhone

Create or open the private setup page only after the receiver is ready:

1. On the receiver computer, open the generated pairing HTML file on a trusted
   screen. If the receiver is headless, securely copy that one file to a trusted
   local computer or phone; do not publish it or place it on a public web server.
2. Scan the displayed QR with iPhone Camera and open the setup link. As a fallback,
   open the securely transferred HTML on the iPhone and tap its pairing button.
3. Confirm the receiver connection in Health Bridge for AI.
4. Tap **Allow Health Access**.
5. Review Apple’s native HealthKit authorization sheet.
6. Enable **Automatic Sync**.

The app asks for all runtime-supported read types in one authorization flow. Health Bridge does not define a smaller basic tier or a second opt-in switch. Apple’s sheet lets you allow or deny individual types.

## Verify the first sync

```bash
health-bridge status \
  --db ~/.local/share/health-bridge/health.sqlite \
  --json
```

Then call the local MCP tools `get_bridge_status` or `list_synced_metrics`, or use the direct read-only query CLI. Missing data must be reported as unknown; it may mean no record, denied permission, source gaps, or sync gaps.

## Connect an MCP client intentionally

Hermes and OpenClaw are the first bundled registrar examples; they are convenience adapters, not the product boundary. Configure only a client you intend to grant health-data access:

```bash
health-bridge setup \
  --receiver-url https://your-private-host.example/v1/batches \
  --configure-client hermes
```

`--configure-client` is repeatable, but configuring more than one client grants each one access. Non-interactive and `--json` runs still make no client changes unless this option is present.

For another same-host stdio MCP client, render `access_descriptors` into that client's documented configuration schema. Do not copy a root key from an unrelated product.

## Deployment patterns

### Local workstation

Run the receiver, database, direct CLI, and optional MCP process on the same Mac or Linux host. This is the supported shortest path.

### No AI agent yet

Pair and collect data now. Direct CLI status and query commands work immediately, and you can connect an MCP client later without re-exporting HealthKit history.

### Agent on another host

The current release candidate does not provide an authenticated remote MCP server. Keep SQLite on the receiver host. An advanced operator may use an explicit SSH-wrapped stdio command, but this is not yet the one-command path. Do not share the SQLite file over a network mount.

### Container or NAS

Container/NAS deployment is not yet first-class. Run the receiver and direct CLI beside the persistent database. A same-host MCP process can use stdio there. Service supervision, private TLS, safe pairing handoff, and host/container path translation remain operator responsibilities.

A future remote transport must use a separate MCP read credential and authorization boundary. Never reuse the iPhone ingest credential as an MCP read credential.

## Build from source

TestFlight is the normal iPhone installation path. Use [self-build.md](self-build.md) when contributing to the iOS app or validating a local source change.

## Remove local bridge data

Stop the receiver first. The command is a dry-run unless `--confirm` is present:

```bash
health-bridge receiver purge --db ~/.local/share/health-bridge/health.sqlite
```

Review the listed SQLite database and sidecars, then repeat with `--confirm` to remove only that local bridge scope. The command refuses confirmation while the receiver is using the database. This does not delete Apple Health data on the iPhone. Empty private `.lifecycle.lock` and `.access.lock` coordination files and a private `.purge-*` directory containing zero-byte tomb files may remain; they contain no health records.

If the command returns `recovery-required`, do not restart the receiver. Review the structured source, quarantine, and truncated path lists; the command preserves the private quarantine rather than reporting a false rollback after an irreversible partial purge.

## Troubleshooting

### The iPhone cannot reach the receiver

- Confirm the phone and receiver host are on the same trusted LAN or private network.
- Prefer valid HTTPS, then Tailscale HTTPS/MagicDNS, then Bonjour on the same LAN. Numeric LAN IPs are supported, but LAN addresses may change under DHCP. Numeric overlay-network addresses can encounter iOS transport-policy failures over plain HTTP, so use HTTPS/MagicDNS when available.
- On macOS, a Bonjour hostname from `scutil --get LocalHostName` with the `.local` suffix is usually easier to keep stable. For example, if the command prints `My-Mac`, use `http://My-Mac.local:8765/v1/batches` while the phone is on the same LAN.
- The first request waits briefly while Apple presents the Local Network permission alert. The Local Network permission alert may fail to resolve that first attempt if access is denied or the route does not recover in time. Allow access. If pairing still reports a local-network error, confirm the route and receiver, then tap **Retry Pairing**; the saved single-use attempt is reused rather than creating a new secret.
- If Tailscale is routing through an exit node and you are connecting to a LAN address, enable **Allow LAN access** in Tailscale or use the receiver's Tailscale HTTPS/MagicDNS URL instead.
- Open the printed health URL from the phone’s browser.
- Confirm the URL in the app exactly matches the receiver URL.
- `health-bridge setup` rejects a loopback receiver URL because it would point at the iPhone. If you intentionally use direct trusted-LAN HTTP without a reverse proxy, set a non-loopback `--receiver-host` explicitly; setup rejects a direct-LAN URL paired with a loopback-only bind.
- For any numeric HTTP URL, setup verifies that the address is assigned to this receiver host. This catches cloud-private VCN addresses, stale LAN addresses, shared-address routes, and unintended remote plaintext endpoints that the iPhone may not be able to route to safely. Shared IPv4 address space remains accepted when address-ownership, bind, and port validation succeeds, but setup warns that plain HTTP on an overlay-network route may encounter iOS transport-policy failures and recommends HTTPS/MagicDNS when available. `--allow-nonlocal-receiver-address` is only for an intentional reverse proxy or private ingress: it bypasses address-ownership validation only, not bind or port validation, reachability, or iOS transport policy.
- Health Bridge does not silently downgrade HTTPS to HTTP or send an invitation to discovered endpoints. Correct the explicit receiver URL and retry.
- Do not expose the receiver directly to the public internet.

### No MCP client was configured

This is the safe default. Use `--configure-client hermes` or `--configure-client openclaw` only after deciding that client should gain access. For any other same-host client, render `access_descriptors` into that client's own format.

### Health types are missing

Open iOS Settings and review Health permissions for Health Bridge. The app requests every implemented type available on the current runtime, but Apple may withhold types that are unavailable, restricted, or denied.

### Pairing material was exposed

Do not use it. Create a fresh setup invitation and revoke the affected paired device or token from the receiver CLI.

## Private state reset safety

**Reset Private Sync State** is intentionally destructive and user-confirmed. The app first closes upload admission, stops HealthKit background delivery, cancels active work, and revalidates the connection generation. Only after those barriers does it persist the private clear intent and remove receiver-scoped cursors, proofs, journals, and queued payloads. Launch recovery completes an interrupted clear before automatic sync can resume.

## Connection replacement safety

Disconnect and every connection replacement, including legacy v1 replacement, use the same local terminal barrier. Disconnect completes locally only after active pairing, foreground uploads, and restored background tasks have drained and the saved settings are cleared. This boundary does not retract a network request that was already sent, so receiver-side device or token revocation remains a separate action when needed. A different connection never adopts an old connection's queued records: the oldest mismatched or unknown item stays quarantined until the user explicitly deletes queued uploads.

# Encrypted iCloud Mailbox service (Beta)

Encrypted iCloud Mailbox is an explicit opt-in, Mac-only Beta. Direct remains
the default transport, and a Direct failure never selects mailbox delivery
automatically. Before iCloud transfer, the app applies application-layer
encryption and a sender signature to the unchanged batch bytes. The user-owned
receiver decrypts and commits accepted batches, then publishes encrypted,
receiver-signed ACKs; the app advances committed progress only after validating
a committed ACK.

The mailbox service keeps that local receiver running for the Mac user who
selected the Beta. It runs the supported `health-bridge receiver start` command
as an optional per-user macOS LaunchAgent. The receiver remains the only owner
of mailbox discovery, import, database writes, and acknowledgements.

This service and its signed ACK helper are optional. Direct and Tailscale setups
do not download, install, validate, or enable either component, and
`health-bridge setup` never installs them implicitly.

The iCloud container and receiver are owned and operated by the user. The
project developer does not have access to either endpoint or the transmitted
HealthKit records. App Store Connect may remain “Data Not Collected” only while
that developer-no-access boundary remains true.

## Install and verify the signed helper

Use the Receiver/CLI `1.1.0` GitHub Release assets. Download these files with a
browser into one private local directory; Health Bridge does not silently
download them:

- `apple_health_ai_bridge-1.1.0-py3-none-any.whl`;
- `HealthBridgeMailboxAckPublisher-1.1.0.zip`;
- `HealthBridgeMailboxAckPublisher-1.1.0.manifest.json`;
- `release-metadata.json`;
- `SHA256SUMS`.

Do not extract the helper zip yourself. From that directory, verify the exact
release asset set, install the wheel, structurally validate the helper, and then
explicitly install it:

```bash
shasum -a 256 -c SHA256SUMS
uv tool install ./apple_health_ai_bridge-1.1.0-py3-none-any.whl
health-bridge mailbox helper verify \
  --archive ./HealthBridgeMailboxAckPublisher-1.1.0.zip \
  --manifest ./HealthBridgeMailboxAckPublisher-1.1.0.manifest.json \
  --json
health-bridge mailbox helper install \
  --archive ./HealthBridgeMailboxAckPublisher-1.1.0.zip \
  --manifest ./HealthBridgeMailboxAckPublisher-1.1.0.manifest.json \
  --json
health-bridge mailbox helper status --json
```

The expected final result is `{"code": "ready"}`. Structural `verify` is
available on non-macOS hosts for synthetic or downloaded packets. Installation
and removal are macOS-only. On macOS, installation additionally checks the
strict/deep code signature, bundle identity and version/build, required iCloud
and sandbox entitlements, and hardened runtime without exposing raw `codesign`
or plist output.

The installer accepts one bounded zip root and rejects traversal, absolute
paths, links, special files, duplicate names, extra roots, and size/count limit
violations. It uses a private sibling staging generation and one no-clobber
directory rename at `~/Library/Application Support/HealthBridge/helpers`, so the
helper app, manifest, and ownership record become visible together. It never
overwrites a foreign or drifted app.

Helper status uses fixed, path-free codes:

| Code | Meaning |
| --- | --- |
| `ready` | The exact owned generation and platform signature checks pass. |
| `not_installed` | No helper generation is installed. |
| `foreign_helper` | The fixed location is partial or has no matching ownership record. |
| `helper_drift` | Owned metadata, app bytes, identity, permissions, or signature changed. |
| `unsupported_host` | Installed-helper inspection is unavailable on this host. |

## Create mailbox pairing material

Set the exact values for the user-selected iCloud container and the already
configured private receiver route. Then run the existing public setup command:

```bash
: "${HEALTH_BRIDGE_RECEIVER_URL:?Set the exact private /v1/batches URL}"
: "${HEALTH_BRIDGE_MAILBOX_ROOT:?Set the existing HealthBridgeMailbox/v1 path}"
: "${HEALTH_BRIDGE_ICLOUD_CONTAINER_IDENTIFIER:?Set the selected container identifier}"
health-bridge setup \
  --receiver-url "$HEALTH_BRIDGE_RECEIVER_URL" \
  --transport icloud-mailbox \
  --mailbox-root "$HEALTH_BRIDGE_MAILBOX_ROOT" \
  --icloud-container-identifier "$HEALTH_BRIDGE_ICLOUD_CONTAINER_IDENTIFIER"
```

This creates the private database, temporary single-use pairing page, and
mailbox-aware receiver command. Keep the setup page and its pairing link out of
chat, logs, Git, and web servers. Pair only after the private redemption route
and local receiver health check work. iCloud mailbox delivery remains
best-effort and may be delayed by iCloud and iOS scheduling.

## Before installing the service

Complete mailbox setup first. You need these existing paths:

- the absolute path to the `health-bridge` executable;
- the private receiver SQLite database;
- the selected iCloud container's `HealthBridgeMailbox/v1` directory.

The executable, database, mailbox directory, and their parent directories must
not use symlink traversal or group/world-writable permissions. The database and
mailbox must belong to the current user. Validation fails closed without
repairing or replacing unsafe paths.

Validate the inputs without installing or starting anything:

```bash
health-bridge mailbox service validate \
  --executable /absolute/path/to/health-bridge \
  --db /absolute/private/path/health.sqlite \
  --mailbox-root "$HOME/Library/Mobile Documents/CONTAINER/Documents/HealthBridgeMailbox/v1" \
  --icloud-container-identifier iCloud.example.HealthBridgeCompanion \
  --json
```

A valid result is `{"code": "valid"}`. Structural validation is available on
non-macOS hosts, but all lifecycle operations are macOS-only.

## Install and operate

Installation is always explicit. On the Mac user account that owns the receiver
data, run the same arguments with `install`:

```bash
health-bridge mailbox service install \
  --executable /absolute/path/to/health-bridge \
  --db /absolute/private/path/health.sqlite \
  --mailbox-root "$HOME/Library/Mobile Documents/CONTAINER/Documents/HealthBridgeMailbox/v1" \
  --icloud-container-identifier iCloud.example.HealthBridgeCompanion \
  --json
```

The installed plist contains only a stable public service label, the absolute
executable and private service-config paths, and bounded launch policy. Database
paths, mailbox paths, container identifiers, bearer tokens, pairing links, and
health values are not written to the plist or status output.

`install` is create-only and idempotent for an identical owned generation. It
does not rewrite an existing service when executable paths or generated service
artifacts change. If first-install publication or bootstrap fails, files created
by that attempt are retired from their active names with an exclusive rename and
scrubbed through their retained file descriptors. The same install can be
retried. Empty owner-only recovery markers and directories may remain.

## Upgrade or reconfigure

Use the explicit one-step upgrade command to change an executable path,
receiver path, mailbox selection, or generated service-artifact version:

```bash
health-bridge mailbox service upgrade \
  --executable /absolute/path/to/new/health-bridge \
  --db /absolute/private/path/health.sqlite \
  --mailbox-root "$HOME/Library/Mobile Documents/CONTAINER/Documents/HealthBridgeMailbox/v1" \
  --icloud-container-identifier iCloud.example.HealthBridgeCompanion \
  --json
```

Upgrade first verifies the currently installed plist, configuration, and
ownership record against their stored generation. It never replaces a foreign
or drifted manifest. If the old job is loaded, upgrade requires a successful
bootout, replaces only the owned service artifacts through no-clobber,
directory-bound publication, and bootstraps the new generation. Replaced active
names are moved to private recovery names rather than deleted. A failed bootstrap
restores the previous artifact bytes and
attempts to reactivate the old job. `upgraded` reports a changed generation;
`already_current` reports an idempotent request. The fixed
`upgrade_recovery_required` error means automatic rollback or reactivation did
not complete and the owned service state needs operator inspection.

Check the service with:

```bash
health-bridge mailbox service status --json
```

Status returns one fixed code:

| Code | Meaning |
| --- | --- |
| `not_installed` | No Health Bridge mailbox service files exist. |
| `installed_inactive` | Owned service files exist, but launchd reports no running service. |
| `running_healthy` | launchd reports a running service and the local receiver health check is healthy. |
| `degraded_retryable` | The service is running but local mailbox health is temporarily unavailable or retryable. |
| `terminal_failed` | The local receiver reports a terminal mailbox failure. |
| `helper_not_ready` | The owned service exists, but the signed helper is not installed. |
| `helper_drift` | The helper location, ownership record, bytes, identity, or signature drifted. |
| `manifest_drift` | Service ownership, contents, topology, or permissions no longer match. |

Only `running_healthy` exits with status 0. Other status states exit 1 so scripts
cannot mistake degraded or drifted supervision for a healthy receiver.

With `--json`, successful results, status results, and lifecycle errors all use
the single object shape `{"code": "fixed_code"}` on standard output. Errors exit
nonzero and do not add path-bearing diagnostics or raw launchctl output. Without
`--json`, failures use a fixed privacy-safe message on standard error.

Request one bounded restart and recovery sequence with:

```bash
health-bridge mailbox service restart --json
```

The result is `restarted` when launchd accepts the direct restart. After a
failed kickstart, recovery inspects the service first. A loaded service must
boot out successfully before one bootstrap and kickstart; an unregistered
service skips bootout and bootstraps once. A failed required bootout stops
recovery. Failed or timed-out launchd operations return fixed privacy-safe
errors and never print raw launchctl output.

## Uninstall

Stop and remove the service with:

```bash
health-bridge mailbox service uninstall --json
```

Uninstall is idempotent. It retires only the exact Health Bridge-owned plist,
private service configuration, ownership record, and service logs from their
active service names. Verified sensitive content is scrubbed through retained
file descriptors. Empty owner-only retirement markers and directories may
remain. Uninstall does not delete the receiver database, mailbox, encryption
keys, pairing state, or any Apple Health data. Drifted or foreign files are left
untouched for manual inspection.

Uninstall verifies only the owned service artifacts. It still works if the
saved executable, receiver database, or mailbox directory was moved or deleted;
it never recreates or deletes those receiver-data locations.

After uninstalling the service, retire the helper only if its exact owned
generation still verifies:

```bash
health-bridge mailbox helper uninstall --json
```

The result is `uninstalled` or `already_uninstalled`. Uninstall atomically
removes the verified generation from the active `helpers` path and preserves it
under a private `.helpers-retired-*` quarantine name; it never recursively
deletes helper bytes automatically. Foreign or drifted content is not deleted.
The helper command does not delete the receiver database, mailbox contents,
keys, pairing state, or Apple Health data. Quarantined generations may be
reviewed and removed manually only after the user confirms no concurrent process
owns them.

## Synthetic structural check

The following check uses only empty synthetic files and does not install a
service:

```bash
SYNTH_HOME="$(mktemp -d)"
SYNTH_CONTAINER="iCloud~dev~example~HealthBridgeCompanion"
mkdir -p "$SYNTH_HOME/bin" "$SYNTH_HOME/private"
mkdir -p "$SYNTH_HOME/Library/Mobile Documents/$SYNTH_CONTAINER/Documents/HealthBridgeMailbox/v1"
printf '#!/bin/sh\nexit 0\n' >"$SYNTH_HOME/bin/health-bridge"
touch "$SYNTH_HOME/private/health.sqlite"
chmod 700 "$SYNTH_HOME" "$SYNTH_HOME/bin" "$SYNTH_HOME/private"
chmod 700 "$SYNTH_HOME/bin/health-bridge"
chmod 600 "$SYNTH_HOME/private/health.sqlite"
find "$SYNTH_HOME/Library" -type d -exec chmod 700 {} +
HOME="$SYNTH_HOME" health-bridge mailbox service validate \
  --executable "$SYNTH_HOME/bin/health-bridge" \
  --db "$SYNTH_HOME/private/health.sqlite" \
  --mailbox-root "$SYNTH_HOME/Library/Mobile Documents/$SYNTH_CONTAINER/Documents/HealthBridgeMailbox/v1" \
  --icloud-container-identifier iCloud.dev.example.HealthBridgeCompanion \
  --json
```

This check proves rendering and filesystem validation only. It is not evidence
of a real macOS launchd lifecycle or physical iPhone/iCloud delivery.

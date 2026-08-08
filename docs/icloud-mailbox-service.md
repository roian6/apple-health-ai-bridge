# Encrypted iCloud Mailbox service (Beta)

The mailbox service keeps the local receiver running for a Mac user who has
explicitly selected Encrypted iCloud Mailbox (Beta). It runs the supported
`health-bridge receiver start` command as a per-user macOS LaunchAgent. The
receiver remains the only owner of mailbox discovery, import, database writes,
and acknowledgements.

This service is optional. Direct and Tailscale setups do not install or enable
it, and `health-bridge setup` never installs it implicitly.

## Before installing

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

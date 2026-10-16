# Apple Health AI Bridge Receiver/CLI 1.1.3

**Coordinated release.**

Compatible iOS Companion: `1.1.2 (62)`

Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`

The updated Companion and matching signed helper are required for iCloud-native first pairing. This is a coordinated source candidate, not an already available app update: the signed app, Apple distribution and immutable receiver/helper assets must be verified separately. Existing Direct installations retain Companion 1.1.1 compatibility.

## Highlights

- One `health-bridge setup` command creates or reuses the supervised per-user receiver, prepares the existing private route and remembers the database.
- A private connection page reports receiver readiness, pairing and the first received upload separately. It opens the installed companion; iCloud-native first pairing requires Companion 1.1.2 and the matching helper, while existing Direct installations remain compatible.
- Normal `status` and `query` commands use remembered configuration instead of repeating a database path. The packaged Skill can use those read-only commands; MCP remains optional.
- The optional thin Node launcher bootstraps the same digest-pinned Python package. It does not add a second receiver or scheduler.
- Existing connections, stored observations, Automatic Sync OFF settings and explicitly selected mailbox services remain intact.
- iCloud-native pairing uses encrypted mailbox requests and completion without an HTTP/HTTPS receiver URL; it remains an explicit Mac-only choice and does not change the Direct default.
- Activity totals distinguish completed days from current-day and unknown observations. Zero, unavailable and stale values stay distinct, and storage failures are not reported as transfer successes.

## Installation availability

Run these exact commands only after the immutable `receiver-v1.1.3` release and all of its assets have been published and verified. Until then, keep the existing installation and follow the published `receiver-v1.1.2` guide. Do not substitute `main` or an older mailbox helper.

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.1.3"
health-bridge setup
```

The optional Node install route uses the exact GitHub release archive, not an unverified registry name:

```bash
npm exec --yes --package="https://github.com/roian6/apple-health-ai-bridge/releases/download/receiver-v1.1.3/apple-health-ai-bridge-0.1.0.tgz" -- health-bridge setup
```

Keep that same runner prefix for later commands if using one-shot npm execution. The Python path provides a stable installed `health-bridge` executable.

## Expected release assets

- `apple_health_ai_bridge-1.1.3-py3-none-any.whl`
- `apple_health_ai_bridge-1.1.3.tar.gz`
- `apple-health-ai-bridge-0.1.0.tgz`
- `HealthBridgeMailboxAckPublisher-1.1.3.zip`
- `HealthBridgeMailboxAckPublisher-1.1.3.manifest.json`
- `SHA256SUMS`
- `release-metadata.json`

The version-bound signed and notarized Mac helper is used only by the explicit Mac-only mailbox Beta; Direct installations do not download or install it. The release packet still includes that mandatory artifact and binds the exact signed tag object, commit, full tree and helper source tree. Final publication requires the real helper manifest, accepted notarization, stapled ticket, Gatekeeper acceptance and the complete checksum set.

## Privacy and compatibility

HealthKit access remains read-only. The existing app uses **Allow Health Access** or **Review Permissions**, followed by the user's separate **Automatic Sync** choice. Direct remains the default with no automatic fallback. Encrypted iCloud Mailbox remains an explicit opt-in Mac-only Beta. The batch and retained Direct pairing protocols are unchanged. The native iCloud candidate adds encrypted request/completion pairing without an HTTP receiver URL and requires updated companion and helper builds; this does not establish support in an already released companion. This release adds no hosted health-data storage, telemetry, advertising, data broker or automatic third-party AI upload.

# Apple Health AI Bridge Receiver/CLI 1.1.0 and iOS Companion 1.1.0 (16)

**Coordinated release.**

Compatible iOS Companion: `1.1.0 (16)`

Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`

This release adds Encrypted iCloud Mailbox as an explicit opt-in, Mac-only Beta transport. Direct remains the default transport, and a failed Direct delivery never falls back automatically to iCloud Mailbox.

## Highlights

- Keeps Direct as the default for existing and new setups unless the user explicitly selects Encrypted iCloud Mailbox (Beta).
- Adds application-layer encryption and signatures before mailbox delivery. iCloud carries encrypted envelopes and encrypted, receiver-signed ACKs rather than plaintext health batches.
- Uses a user-owned iCloud container and a user-owned receiver. The project developer does not operate or have access to either endpoint.
- Offers an optional per-user macOS LaunchAgent to keep the mailbox receiver running. Installation, upgrade, restart, and removal remain explicit user actions.
- Commits receiver ingestion before publishing the corresponding signed ACK. The app advances committed local progress only after it validates an ACK with a committed result; retryable and terminal results remain explicit.
- Preserves Batch Protocol `health_bridge.batch.v1` version `1.0.0`; mailbox delivery wraps the unchanged batch bytes in the delivery envelope.

## Install or upgrade the receiver

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.1.0"
```

Direct remains the default setup path. Users who deliberately choose the Mac-only Beta can follow the [Encrypted iCloud Mailbox service guide](https://github.com/roian6/apple-health-ai-bridge/blob/receiver-v1.1.0/docs/icloud-mailbox-service.md).

## Verify the release

The GitHub Release assets include:

- `apple_health_ai_bridge-1.1.0-py3-none-any.whl`
- `apple_health_ai_bridge-1.1.0.tar.gz`
- `SHA256SUMS`
- `release-metadata.json`

`release-metadata.json` records `release_scope` as `coordinated`, Receiver/CLI `1.1.0`, compatible iOS Companion `1.1.0 (16)`, and Batch Protocol `health_bridge.batch.v1 (1.0.0)` with the exact Git commit and tree. Verify `SHA256SUMS` before using downloaded artifacts.

## Privacy and operating boundaries

- HealthKit access remains read-only.
- Encrypted iCloud Mailbox is not a developer-hosted relay. It uses the user's iCloud container and the receiver the user owns and operates.
- App Store Connect may remain “Data Not Collected” only while the developer and integrated third parties cannot access the user's HealthKit records, iCloud container, receiver, or transmitted records. Reassess App Privacy if that boundary changes.
- The project adds no telemetry, advertising, data broker, or automatic third-party AI upload path.
- Public release artifacts contain no health data, pairing material, receiver identifiers, private topology, signing material, account details, or owner-only validation evidence.

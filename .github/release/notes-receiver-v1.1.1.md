# Apple Health AI Bridge Receiver/CLI 1.1.1

**Receiver-only release.**

Compatible iOS Companion: `1.1.0 (39)`

Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`

No TestFlight update is required.

This patch makes the signed Mailbox ACK helper available for normal Mac installation.

## Highlights

- Ships a universal Mac helper signed with Developer ID, notarized by Apple, and accepted by Gatekeeper.
- Verifies the helper archive, publisher, entitlements, source revision, and public manifest before installation.
- Keeps Direct as the default transport. Encrypted iCloud Mailbox remains an explicit opt-in, Mac-only Beta.
- Does not require Xcode or developer tools for normal installation.

## Install or upgrade the receiver

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.1.1"
```

Direct remains the default setup path. Users who deliberately choose the Mac-only Beta can follow the [Encrypted iCloud Mailbox service guide](https://github.com/roian6/apple-health-ai-bridge/blob/receiver-v1.1.1/docs/icloud-mailbox-service.md).

## Verify the release

The GitHub Release assets include:

- `apple_health_ai_bridge-1.1.1-py3-none-any.whl`
- `apple_health_ai_bridge-1.1.1.tar.gz`
- `HealthBridgeMailboxAckPublisher-1.1.1.zip`
- `HealthBridgeMailboxAckPublisher-1.1.1.manifest.json`
- `SHA256SUMS`
- `release-metadata.json`

`release-metadata.json` records `release_scope` as `receiver`, Receiver/CLI `1.1.1`, compatible iOS Companion `1.1.0 (39)`, Batch Protocol `health_bridge.batch.v1 (1.0.0)`, and the expected helper component/version/source tree with the exact Git tag object, commit, and tree. The helper manifest additionally binds its Developer ID distribution identity and notarization contract. `SHA256SUMS` covers the wheel, source archive, helper zip, helper manifest, and release metadata.

## Privacy and operating boundaries

- HealthKit access remains read-only.
- Encrypted iCloud Mailbox remains an explicit opt-in, Mac-only Beta using the user's iCloud container and receiver.
- The project adds no telemetry, advertising, data broker, or automatic third-party AI upload path.
- Public artifacts contain no health data, pairing material, credentials, private paths, or account details.

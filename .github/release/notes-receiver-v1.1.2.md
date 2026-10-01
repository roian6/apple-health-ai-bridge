# Apple Health AI Bridge Receiver/CLI 1.1.2

**Receiver-only release.**

Compatible iOS Companion: `1.1.1 (50)`

Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`

No TestFlight update is required.

## Highlights

- Native `health-bridge status --db <database> --json` and `health-bridge mcp smoke --db <database>` can read the local database while the receiver continues running.
- The receiver retains lifecycle protection and transaction-scoped database access exclusion without holding an access lock for its entire lifetime.
- SQLite connections close when their operation finishes, including error paths.
- The matching macOS Mailbox ACK helper requires a new exact-source signed and notarized build for this receiver version.

## Installation availability

Run the receiver upgrade command below only after the immutable `receiver-v1.1.2` release and all of its assets have been published and verified. Until then, keep your existing installation or wait. Do not substitute `main` or an older mailbox helper.

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.1.2"
```

Keep the receiver running when using native CLI or MCP reads with Receiver/CLI `1.1.2`. Stop it before destructive local database operations such as a confirmed purge.

## Expected release assets

- `apple_health_ai_bridge-1.1.2-py3-none-any.whl`
- `apple_health_ai_bridge-1.1.2.tar.gz`
- `HealthBridgeMailboxAckPublisher-1.1.2.zip`
- `HealthBridgeMailboxAckPublisher-1.1.2.manifest.json`
- `SHA256SUMS`
- `release-metadata.json`

`release-metadata.json` records `release_scope` as `receiver`, Receiver/CLI `1.1.2`, compatible iOS Companion `1.1.1 (50)`, and Batch Protocol `health_bridge.batch.v1 (1.0.0)`. It binds the exact signed tag object, commit, Git tree, and helper source tree. The helper manifest binds the new archive digest, version/build, Developer ID distribution identity, and notarization contract. Publication requires accepted notarization, a stapled ticket, and Gatekeeper acceptance. `SHA256SUMS` covers the wheel, source archive, helper zip, helper manifest, and release metadata.

## Privacy and transport compatibility

HealthKit access remains read-only. Direct remains the default transport with no automatic fallback. Encrypted iCloud Mailbox remains an explicit opt-in, Mac-only Beta using the user's iCloud container and receiver. Batch and pairing protocols are unchanged. This release adds no telemetry, advertising, data broker, hosted sync, or automatic third-party AI upload path.

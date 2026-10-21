# Apple Health AI Bridge Receiver/CLI 1.1.3

**Receiver-only release.**

Compatible iOS Companion: `1.1.1 (50)`

Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`

No TestFlight update is required for this Receiver upgrade.

## Highlights

- Query committed SQLite snapshots through the CLI and MCP while Receiver ingestion continues, without treating unfinished writes as committed data.
- Handle completed-day calendar coverage, raw-record corrections and deletions, explicit zero projections, and stale replays consistently. Day summaries use the collection evidence supplied by the companion rather than inventing missing observations.
- Respond to MCP ping requests and provide clearer tool and parameter metadata for AI clients.
- Download and independently verify native GitHub provenance bundles for the Python package and the final helper-bound release packet.

## Components

Receiver/CLI and its matching signed macOS Mailbox ACK helper advance to `1.1.3`. iOS Companion and Batch Protocol versions remain unchanged. Companion-side HealthKit collection fixes are delivered through a separate iOS release, not by upgrading the Receiver.

## Install or upgrade

Use the command below after `receiver-v1.1.3` and its complete asset set are published and verified:

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.1.3"
```

For an existing installation, stop the Receiver before replacing its installed package and retain the database, credentials and pairing. This release adds projection-state tables and a fence-order index through migrations `010` and `011`. Take a consistent backup before a database upgrade. Do not restore an older database over newer acknowledged records.

Direct remains the default transport. Mac-only iCloud Mailbox installations use the new `HealthBridgeMailboxAckPublisher-1.1.3.zip` and its matching manifest; an older signed archive is not a substitute. Follow the [matching helper verification guide](https://github.com/roian6/apple-health-ai-bridge/blob/receiver-v1.1.3/docs/icloud-mailbox-service.md) before installation.

## Release assets

- `apple_health_ai_bridge-1.1.3-py3-none-any.whl`
- `apple_health_ai_bridge-1.1.3.tar.gz`
- `release-metadata.json`
- `receiver-build-provenance.intoto.jsonl`
- `HealthBridgeMailboxAckPublisher-1.1.3.zip`
- `HealthBridgeMailboxAckPublisher-1.1.3.manifest.json`
- `SHA256SUMS`
- `receiver-final-provenance.intoto.jsonl`

The signed tag, source commit/tree, artifact digests and helper manifest identify this exact release. The build bundle covers the wheel, source archive and release metadata. The final bundle covers the helper, manifest and checksum file. `SHA256SUMS` covers the six package/helper inputs, excluding itself and the final proof; verify the final proof with native attestation verification.

The new helper must be Developer ID signed, accepted by notarization, stapled and accepted by Gatekeeper. HealthKit permissions, pairing and Batch Protocol remain unchanged.

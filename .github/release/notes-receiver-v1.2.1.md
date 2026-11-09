# Apple Health AI Bridge Receiver/CLI `1.2.1`

**Receiver-only release**

This patch repairs the native Mailbox publication boundary in the Receiver and
its matching macOS helper. No TestFlight update is required.

## Highlights

- Replace Receiver access to helper-private Mailbox files with bounded,
  request-bound native publication IPC.
- Require matching Receiver and helper support before using ACK, pairing, or
  Receiver-capability publication; an old helper is rejected before receiver
  startup binds the network listener.
- Preserve committed pairing receipts across native publication failures and
  make retryable service failures visible.
- Keep DB commit, receipt storage, ACK signing, and device cursor advancement
  with their existing owners. The helper remains the native file publisher.

## Compatibility

Compatible iOS Companion: `1.2.0 (51)`

Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`

## Install or upgrade

After the matching release assets are qualified and published, the exact source
install reference is:

```bash
uv tool install "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.2.1"
```

The Receiver wheel and its macOS helper asset must be qualified and installed as
one matching pair. Receiver `1.2.0` uses the legacy file handoff; a helper-only or
wheel-only replacement does not qualify the repaired boundary.

Use the documented preservation-first service/helper replacement sequence.
Retain the existing receiver database, keys, mailbox identity, and pairing.
Helper quarantine and replacement are not atomic with service replacement; an
installation failure must leave the service stopped rather than claim rollback.

## Limits and privacy

- No iOS source, Companion version/build, or Batch protocol changes.
- No new HealthKit writes, telemetry, or third-party AI calls.
- No claim that this resolves every startup, active-CPU, or ACK symptom in the
  broader iCloud incident.

## Release assets and provenance

Use the matching wheel/source distribution and macOS helper archive/manifest,
with their checksums and source-bound candidate provenance. Native distribution
requires the exact-source signed/notarized helper and qualification described in
`docs/icloud-mailbox-service.md`. A source version change alone is not proof of
notarization, provider propagation, or physical-device ACK acceptance.

Publication must provide the exact matching asset set:

- `apple_health_ai_bridge-1.2.1-py3-none-any.whl`
- `apple_health_ai_bridge-1.2.1.tar.gz`
- `release-metadata.json`
- `receiver-build-provenance.intoto.jsonl`
- `HealthBridgeMailboxAckPublisher-1.2.1.zip`
- `HealthBridgeMailboxAckPublisher-1.2.1.manifest.json`
- `SHA256SUMS`
- `receiver-final-provenance.intoto.jsonl`

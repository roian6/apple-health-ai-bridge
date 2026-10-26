# Apple Health AI Bridge Receiver/CLI 1.2.0

**Coordinated release.**

Keep automatic sync responsive while sleep data is prepared, and get clearer sleep, workout, nutrition, and sync-coverage results. This coordinated source candidate advances Receiver/CLI and iOS Companion while keeping Batch Protocol 1.0.0 compatible.

## Highlights

- Sleep data preparation runs away from the main actor so automatic sync can stay responsive.
- Nutrition delivery is gated by explicit Receiver capability. When supported, the Companion sends the five documented nutrition types; unknown or unsupported capability holds nutrition without treating missing records as zero.
- Sleep queries use the requested local timezone and keep separate observed periods, naps, coverage, and unknown evidence distinct.
- Sync status separates retained record coverage from the latest successful sync window and reports per-metric checkpoints.
- Workout exports preserve stable identity and HealthKit activity types, including distinct names for historical activity types and unmapped HealthKit values.
- The source includes a native URL-free pairing path for the explicit, Mac-only iCloud Mailbox Beta. Use it only with a specifically matched, qualified Receiver, Mac helper, and iPhone Companion build set using the same user-authorized iCloud container. Direct stays the default and never falls back automatically.

## Compatibility

Compatible iOS Companion: `1.2.0 (51)`

Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`

## Install or upgrade

The published Receiver/CLI baseline remains `1.1.5` (`receiver-v1.1.5`). Keep your current installation until this coordinated candidate is approved and its release is published and verified. Only then use the pinned install command below.

Before upgrading, stop the Receiver and back up the database. Keep the existing database, credentials, and pairing. Initialization applies migration `012_catalogue_coverage_index`, which builds a catalogue coverage index synchronously and may need extra disk space or wait for database readers or writers. It also applies migration `013_mailbox_enrollment` for native Mailbox enrollment state. The project doesn't support running an older Receiver/CLI against a database after these migrations; restore the pre-upgrade database backup before returning to an older version.

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.2.0"
health-bridge init --db "$HEALTH_BRIDGE_DB"
```

## Limits and privacy

Direct remains the default transport, and a Direct failure doesn't switch to Mailbox delivery. Mailbox is an explicit opt-in Beta for matched Mac and iPhone builds; URL-free pairing requires the qualified native build set and an existing user-authorized iCloud container. Nutrition support is connection-bound: unknown or unsupported capability doesn't mean nutrition was delivered. The project documents HealthKit access as read-only.

## Release assets and provenance

The candidate release packet must contain exactly these eight assets. These are requirements, not a claim that the files have been generated, qualified, or approved:

- `apple_health_ai_bridge-1.2.0-py3-none-any.whl`
- `apple_health_ai_bridge-1.2.0.tar.gz`
- `release-metadata.json`
- `receiver-build-provenance.intoto.jsonl`
- `HealthBridgeMailboxAckPublisher-1.2.0.zip`
- `HealthBridgeMailboxAckPublisher-1.2.0.manifest.json`
- `SHA256SUMS`
- `receiver-final-provenance.intoto.jsonl`

Bind the packet to the exact source commit and tree, signed tag object, workflow run and attempt, and original candidate artifact. `SHA256SUMS` must cover the wheel, source archive, release metadata, build provenance, helper archive, and helper manifest; it excludes itself and final provenance. Build provenance covers the wheel, source archive, and release metadata. Final provenance covers the helper archive, helper manifest, and checksum file. Follow the [release criteria](criteria.md) and [maintainer release procedure](../../docs/release-operations.md) before publication.

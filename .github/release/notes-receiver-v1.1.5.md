# Apple Health AI Bridge Receiver/CLI 1.1.5

**Receiver-only release.**

Compatible iOS Companion: `1.1.1 (50)`

Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`

No TestFlight update is required for this Receiver upgrade.

## Maintenance scope

This bounded patch is based on published Receiver/CLI `1.1.3`. It repairs signed
macOS Mailbox ACK helper archive creation and installation: release archives
exclude AppleDouble metadata, the installer rejects `._` and `__MACOSX` entries,
and the release verifier installs the final ZIP through the production installer
before checking the installed bundle and its arm64/x86_64 architectures.

Release automation adds candidate preparation, protected maintenance-source
validation, exact artifact reconciliation, and recovery checks. The failed signed
`receiver-v1.1.4` tag is retired and preserved; it is not an upgrade target.
The development-only filelock dependency is pinned to `4.2.1`.

Receiver query behavior, data catalogs, nutrition, sleep, status, and query
windows remain as in `1.1.3`. This patch adds no database migration. The iOS
source, iOS version/build, and Batch Protocol are unchanged.

## Install or upgrade

Use the command and downloads below only after immutable `receiver-v1.1.5` and
all eight release assets have been published and verified. Until then, keep your
existing installation or wait. Do not substitute `main` or an older helper.

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.1.5"
```

Stop the Receiver before replacing its installed package; retain the existing
database, credentials, and pairing. Direct remains the default transport.
For the Mac-only iCloud Mailbox Beta, Receiver/CLI `1.1.5` requires the same-release
`HealthBridgeMailboxAckPublisher-1.1.5.zip` and matching manifest. An older signed
helper is not a substitute. Use the release assets named here when following the
[helper verification and installation guide](https://github.com/roian6/apple-health-ai-bridge/blob/receiver-v1.1.5/docs/icloud-mailbox-service.md).
Do not manually extract or repackage the signed archive.

## Release assets

- `apple_health_ai_bridge-1.1.5-py3-none-any.whl`
- `apple_health_ai_bridge-1.1.5.tar.gz`
- `release-metadata.json`
- `receiver-build-provenance.intoto.jsonl`
- `HealthBridgeMailboxAckPublisher-1.1.5.zip`
- `HealthBridgeMailboxAckPublisher-1.1.5.manifest.json`
- `SHA256SUMS`
- `receiver-final-provenance.intoto.jsonl`

Verify the signed tag, source commit/tree, artifact digests, helper manifest,
and native GitHub provenance bundles. `SHA256SUMS` covers the six package/helper
inputs, excluding itself and the final proof. The build proof covers the wheel,
source archive, and release metadata; the final proof covers the helper archive,
helper manifest, and checksum file.

The exact helper must be Developer ID signed, notarized, stapled, and accepted
by Gatekeeper. Native installation must complete and helper status must report
`ready`. HealthKit permissions and pairing remain unchanged.

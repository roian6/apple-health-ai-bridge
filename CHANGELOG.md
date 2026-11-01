# Changelog

## Unreleased

The following iOS fixes are on `main` only and are not included in the released iOS Companion 1.2.0 (build 51):

- Keep queue refresh outside upload acceptance (#147).
- Allow explicit recovery of lost Mailbox keys (#150).
- Reuse authenticated Mailbox cancellation on retry (#152).

Source version labels may still match the released components; they do not make later commits part of the shipped app.

## Receiver/CLI 1.2.0

Published as [receiver-v1.2.0](https://github.com/roian6/apple-health-ai-bridge/releases/tag/receiver-v1.2.0) on October 30, 2026. The coordinated installation default is Receiver/CLI 1.2.0 with iOS Companion 1.2.0 (build 51), keeping Batch Protocol `health_bridge.batch.v1` (1.0.0). Get the matching app through the [App Store](https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806) or [TestFlight](https://testflight.apple.com/join/GF4dbSEV), and check its version and build before upgrading.

- Manual sync and retry can process pending work whether Automatic Sync is on or off. Accepted Sleep work finishes persistence and recovery before it is retired, so storage failures remain retryable.
- Nutrition delivery keeps mixed-batch order and receipt history, avoiding replay of older workout or sample values when nutrition support is enabled.
- UV raw observations use min/max/average aggregation instead of being summed. Migration `014_uv_raw_aggregation` updates existing raw UV rows that still use sum aggregation.

Before upgrading from Receiver/CLI 1.1.5, stop the Receiver and back up the database. Initialization applies migrations 012, 013, and 014; migration 012 may need extra disk space and can wait for database readers or writers. Older Receiver/CLI versions are not supported against a database after these migrations, so restore the pre-upgrade backup before downgrading. The Companion's newer queue format cannot be opened by older app builds; an older mixed nutrition queue with incomplete delivery history stays on hold, and you should contact support before resetting private sync state.

Follow the maintained [setup and upgrade guide](docs/setup.md) for authenticated capability routing and existing-user migration steps. Encrypted iCloud Mailbox remains an explicit opt-in, Mac-only Beta; its [helper guide](docs/icloud-mailbox-service.md) covers verification and replacement separately from service reconfiguration.

## Receiver/CLI 1.1.5

Published as [receiver-v1.1.5](https://github.com/roian6/apple-health-ai-bridge/releases/tag/receiver-v1.1.5),
this bounded maintenance release is based on Receiver/CLI 1.1.3. It repairs signed
macOS Mailbox ACK helper archive creation and installation and adds protected
candidate preparation, publication reconciliation, and recovery checks.

Receiver query behavior and database migrations remain as in 1.1.3. Compatible
iOS Companion 1.1.1 (50) and Batch Protocol health_bridge.batch.v1 (1.0.0) are
unchanged. See the [exact release notes](.github/release/notes-receiver-v1.1.5.md)
for scope and assets.

The retained receiver-v1.1.4 tag was never published and is unsupported.

## Historical releases

- [Receiver/CLI 1.2.0](https://github.com/roian6/apple-health-ai-bridge/releases/tag/receiver-v1.2.0)
- [Receiver/CLI 1.1.3](.github/release/notes-receiver-v1.1.3.md)
- [Receiver/CLI 1.1.2](.github/release/notes-receiver-v1.1.2.md)
- [Receiver/CLI 1.1.1](.github/release/notes-receiver-v1.1.1.md)
- [Receiver/CLI 1.1.0](.github/release/notes-receiver-v1.1.0.md)
- [1.0.1](.github/release/notes-v1.0.1.md)
- [1.0.0](.github/release/notes-v1.0.0.md)

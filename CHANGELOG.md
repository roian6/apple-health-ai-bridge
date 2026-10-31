# Changelog

## Unreleased

The forward-port source versions are Receiver/CLI 1.2.0, iOS Companion 1.2.0 (build 51), and Batch Protocol `health_bridge.batch.v1` (1.0.0). Source metadata does not set public installation defaults: the App Store currently offers iOS Companion 1.1.1 (build 50), build 51 remains under App Store and external TestFlight review, and the guided Receiver/CLI install stays pinned to 1.1.5 until a matched app build is available and the controlled cutover is ready.

## Receiver/CLI 1.2.0

Published as [receiver-v1.2.0](https://github.com/roian6/apple-health-ai-bridge/releases/tag/receiver-v1.2.0) on October 30, 2026. This coordinated source release advances Receiver/CLI and iOS Companion while keeping Batch Protocol `health_bridge.batch.v1` (1.0.0). The matching iOS Companion 1.2.0 (build 51) is not yet available through the App Store or external TestFlight while review is pending; the published Receiver does not move the default install pin by itself.

- Manual sync and retry can process pending work whether Automatic Sync is on or off. Accepted Sleep work finishes persistence and recovery before it is retired, so storage failures remain retryable.
- Nutrition delivery keeps mixed-batch order and receipt history, avoiding replay of older workout or sample values when nutrition support is enabled.
- UV raw observations use min/max/average aggregation instead of being summed. Migration `014_uv_raw_aggregation` updates existing raw UV rows that still use sum aggregation.

Before upgrading from Receiver/CLI 1.1.5, stop the Receiver and back up the database. Initialization applies migrations 012, 013, and 014; migration 012 may need extra disk space and can wait for database readers or writers. Older Receiver/CLI versions are not supported against a database after these migrations, so restore the pre-upgrade backup before downgrading. The Companion's newer queue format cannot be opened by older app builds; an older mixed nutrition queue with incomplete delivery history stays on hold, and you should contact support before resetting private sync state.

The 1.2.0 source notes identify iOS Companion 1.2.0 (build 51) as the compatible app and Batch Protocol `health_bridge.batch.v1` (1.0.0). That source compatibility declaration does not mean build 51 has cleared review or change public install defaults.

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

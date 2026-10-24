# Changelog

## Receiver/CLI 1.1.4

A maintenance patch based on Receiver/CLI 1.1.3:

- Repair signed Mailbox ACK helper packaging and installation by excluding and
  rejecting AppleDouble metadata and checking the installed final archive.
- Validate protected maintenance source authorization at release boundaries.
- Update the development-only filelock dependency to 4.2.1.

The Mac-only mailbox Beta requires the matching 1.1.4 helper. iOS Companion
1.1.1 (50), Batch Protocol 1.0.0 / `health_bridge.batch.v1`, iOS source, and schemas
are unchanged. No TestFlight update or database migration is required. Receiver
query, catalog, nutrition, sleep, status, and query-window behavior stays at 1.1.3.

Use the [1.1.4 release notes](.github/release/notes-receiver-v1.1.4.md) and their
installation commands only after the exact release and all eight assets have
been published and verified.

## Historical releases

The original release notes remain unchanged:

- [Receiver/CLI 1.1.3](.github/release/notes-receiver-v1.1.3.md)
- [Receiver/CLI 1.1.2](.github/release/notes-receiver-v1.1.2.md)
- [Receiver/CLI 1.1.1](.github/release/notes-receiver-v1.1.1.md)
- [Receiver/CLI 1.1.0](.github/release/notes-receiver-v1.1.0.md)
- [1.0.1](.github/release/notes-v1.0.1.md)
- [1.0.0](.github/release/notes-v1.0.0.md)

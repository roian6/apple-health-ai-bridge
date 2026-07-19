# Architecture and trust boundaries

Health Bridge for AI is a local bridge between HealthKit and agent-readable tools. It is not a hosted health service.

## Data path

```text
iPhone HealthKit
  -> iOS companion
  -> user-owned receiver
  -> local SQLite database
  -> read-only CLI / MCP
  -> Hermes, OpenClaw, or another local agent
```

The companion asks HealthKit for read permission only. The receiver accepts authenticated batches from paired devices and stores normalized records in SQLite. The CLI and MCP server expose fixed, bounded read-only queries over that store.

## Components

| Component | Role |
| --- | --- |
| iOS companion | Reads allowed HealthKit records, protects receiver credentials in Keychain, queues failed uploads, and sends foreground or automatic batches. |
| Receiver | Runs on user-owned infrastructure, validates device credentials, ingests batches, and writes SQLite rows. |
| SQLite store | Keeps sources, type codes, time windows, sync runs, tombstones, and redacted cursor metadata. |
| Setup CLI | Creates the private store and pairing page, prepares the receiver, emits a client-neutral stdio MCP descriptor, and optionally runs installed client adapters. |
| MCP server | Exposes fixed read-only health observation tools. It does not provide raw SQL access. |

## Unified HealthKit scope

The product has one read scope: every implemented HealthKit type available on the current iOS runtime. The same set drives the native authorization request, foreground sync, observer registration, scheduled background refresh, and launch catch-up.

The code uses different **sync strategies**, not product tiers:

- steps use a dedicated anchored lane;
- workouts use a dedicated anchored lane;
- sleep uses a correction-aware anchored lane;
- supported quantity types use the generic anchored quantity lane.

Those implementation paths do not create “basic” and “additional” user scopes. Apple’s authorization sheet remains the only per-type allow/deny interface.

A type can produce records only when the companion implements its reader and payload mapping, the current runtime can construct the HealthKit object type, and the user grants read access. Unsupported, unavailable, denied, or absent data remains unknown rather than being fabricated.

`Sync Now` attempts the complete runtime-supported set and may perform historical catch-up. Automatic paths prioritize recent changes and use bounded fallback windows where no cursor exists. iOS controls whether and when background execution occurs, so automatic delivery is eventually complete rather than guaranteed to be immediate. Force-quitting the iOS app may suspend background delivery until the user opens it again.

## Pairing and authorization boundary

Pairing invitations are temporary and single-use. Redemption produces a device credential stored in the iOS Keychain and hashed by the receiver.

The current receiver is a **single-user store**. Every active paired device credential authorizes writes to that whole store; the device mapping supports lifecycle and revocation but is not a multi-tenant data-isolation boundary. A hosted relay, shared receiver database, or mutually untrusted devices would require a new principal and namespace design before release.

## Delivery and recovery

Uploads enter a private ordered outbox. A successful HTTP response is required before the corresponding committed progress advances. Failed or interrupted uploads remain queued and retry in order.

Cursorless automatic reads may send a bounded recent window but do not silently consume the wider foreground backfill. Status surfaces expose cursor metadata and sync outcomes without exposing opaque cursor values.

### Sleep corrections

Sleep sessions are derived from child HealthKit samples, so the companion keeps a private, backup-excluded manifest and transition journal. It advances the opaque HealthKit sleep anchor only after the exact correction or deletion payload has been accepted by the receiver.

Each installation uses a separate sleep source key and a Keychain-backed ordered reset epoch. The receiver rejects older reset epochs and ignores an already-authoritative equal epoch, preventing delayed baselines from replacing newer state. Empty baselines never delete prior data until a non-empty authoritative baseline for that epoch arrives.

During a user-confirmed private-state reset, deletion occurs only after upload admission is closed, active transfers are drained, the connection generation is revalidated, and the durable clear intent is persisted. Launch recovery finishes an interrupted clear before automatic sync resumes.

## Agent boundary

MCP tools expose:

- redacted bridge status;
- supported and synced metric catalogs;
- bounded time-series observations;
- workouts, sleep summaries, and daily summaries;
- source provenance and missing-data caveats.

They do not expose raw SQL, pairing material, bearer tokens, token hashes, opaque cursor values, or clinical recommendations.

## Deployment boundary

- The receiver is intended for a trusted LAN or private network.
- Pairing pages must never be published or pasted into chat.
- Plain HTTP exposes health payloads and the device credential to the local network while in transit; prefer private HTTPS where practical.
- SQLite is protected by owner-only filesystem permissions, not by an application-level database encryption layer.
- The project includes no telemetry, advertising, hidden cloud upload, or third-party AI call by default.

## Operational limits

`health-bridge setup` prepares the receiver command and private pairing material but does not silently install or enable an operating-system service. Hosted infrastructure remains outside the current scope.

# Apple Health AI Bridge Roadmap

The current public set is Receiver/CLI `1.1.1`, iOS Companion `1.1.1 (50)` on the App Store and TestFlight, and Batch Protocol `health_bridge.batch.v1 (1.0.0)`.

## Available today

- App Store installation for the iOS companion, with TestFlight reserved for beta builds;
- user-owned receiver and SQLite storage on macOS or Linux;
- read-only HealthKit sync for the types documented in [supported health data](supported-health-data.md);
- Automatic Sync with best-effort timing controlled by iOS, plus an explicit manual sync action;
- bounded read-only CLI, JSON, Markdown, and MCP query surfaces;
- Direct delivery by default, with Encrypted iCloud Mailbox as an explicit opt-in, Mac-only Beta;
- source, release provenance, privacy boundaries, and security guidance published for inspection.

## Near term

1. Keep App Store, receiver, setup, privacy, security, and version surfaces aligned with each released build.
2. Make receiver routing, pairing, Automatic Sync, and the first local query easier to complete with guided setup and clearer recovery guidance.
3. Expand client-specific setup examples for MCP-compatible agents while preserving explicit user control over client configuration.
4. Improve recurring query workflows and the presentation of freshness, sources, and missing data.
5. Prioritize onboarding and reliability improvements from repeated user feedback without weakening the local-first, read-only product boundaries.

## Later

- a guided installer or desktop receiver experience for users who prefer not to operate the CLI directly;
- an optional hosted or managed relay only after a separate privacy/security review;
- additional MCP client integrations and reusable query workflows;
- broader HealthKit family support guided by real use cases.

## Product boundaries

- no HealthKit write-back;
- no medical decisions, scoring, or emergency use;
- no hidden hosted sync;
- no public remote MCP by default;
- no collection of health values for product analytics.

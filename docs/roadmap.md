# Apple Health AI Bridge Roadmap

The current public release set is Receiver/CLI `1.1.1`, iOS Companion `1.1.1 (50)` on the App Store and TestFlight, and the unchanged Batch Protocol `health_bridge.batch.v1 (1.0.0)`.

## Current state

Works today:

- synthetic fixture ingest into local SQLite;
- local receiver batch ingest;
- read-only CLI, JSON, Markdown, and MCP query surfaces;
- an App Store iOS companion with a separate self-build path for contributors;
- read-only sync support for the types documented in [supported health data](supported-health-data.md), selected through the native Apple Health permission sheet;
- Automatic Sync with best-effort timing controlled by iOS, plus an explicit manual sync action;
- public brand assets, security guidance, contribution rules, and release criteria.

Current operational constraints:

- real Apple Health sync requires an iPhone and a macOS or Linux receiver computer; a local iOS self-build additionally requires Mac/Xcode and signing;
- receiver setup is aimed at technical users or agent-assisted local setup;
- background sync is best-effort and controlled by iOS;
- broad non-quantity HealthKit families are not implemented yet;
- Encrypted iCloud Mailbox remains an explicit opt-in, Mac-only Beta; Direct remains the default and has no automatic fallback to mailbox delivery.

## Near term

1. Keep the public docs short, current, and free of internal planning notes.
2. Keep the synthetic quickstart and MCP smoke path reliable for first-time users.
3. Prepare each release candidate from the current release tree with a unique build number and fresh validation.
4. Keep install and review guidance current for the exact released build.
5. Improve receiver setup documentation and failure recovery.
6. Keep the [release criteria](../.github/release/criteria.md) passing.

## Later

- broader HealthKit family support beyond direct quantity samples;
- stronger receiver deployment guidance for private networks;
- optional hosted or managed relay design, only after a separate privacy/security review;
- clearer setup documentation for users who are not already using local agents.

## Non-goals for the current release

- HealthKit write-back;
- medical decisions, scoring, or emergency use;
- hidden hosted sync;
- public remote MCP by default;
- committing real health data, pairing material, or private receiver evidence.

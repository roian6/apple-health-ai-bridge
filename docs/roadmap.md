# Apple Health AI Bridge Roadmap

Apple Health AI Bridge is preparing a coordinated stable v1.0.0 release. The exact iOS Build 15 candidate, approved TestFlight Public Link, repository tag, package artifacts, and install site are released as one verified set.

## Current state

Works today:

- synthetic fixture ingest into local SQLite;
- local receiver batch ingest;
- read-only CLI, JSON, Markdown, and MCP query surfaces;
- iOS companion source for a self-build HealthKit path;
- read-only sync support for steps, workouts, sleep, and direct quantity samples selected through the native Apple Health permission sheet;
- public brand assets, security guidance, contribution rules, and release criteria.

Current operational constraints:

- real Apple Health sync requires iPhone + Mac/Xcode + signing;
- receiver setup is aimed at technical users or agent-assisted local setup;
- background sync is best-effort and controlled by iOS;
- broad non-quantity HealthKit families are not implemented yet.

## Near term

1. Keep the public docs short, current, and free of internal planning notes.
2. Keep the synthetic quickstart and MCP smoke path reliable for first-time users.
3. Prepare every TestFlight candidate from the current release tree with a unique build number and fresh validation.
4. Keep the tester-facing install and review guidance current for the exact approved build.
5. Improve receiver setup guidance and failure recovery.
6. Keep the [release criteria](../.github/release/criteria.md) passing.

## Later

- broader HealthKit family support beyond direct quantity samples;
- stronger receiver deployment guidance for private networks;
- optional hosted or managed relay design, only after a separate privacy/security review;
- richer onboarding for users who are not already using local agents.

## Non-goals for v1.0.0

- HealthKit write-back;
- medical decisions, scoring, or emergency use;
- hidden hosted sync;
- public remote MCP by default;
- committing real health data, pairing material, or private receiver evidence.

# Security Policy

The current stable source release is `v1.0.0`. The iOS companion is distributed through public TestFlight. The default deployment model remains local-first and user-owned.

## Sensitive Data

Do not post any of the following in public issues, pull requests, screenshots, logs, docs, or chats:

- real HealthKit exports or sample values;
- screenshots containing health values or identifiable sources;
- receiver SQLite databases;
- bearer tokens, token hashes, pairing URLs, pairing deep links, or setup-page contents;
- local outbox payloads;
- sync cursor values;
- private-network endpoint details when they identify a real deployment.

Use synthetic fixtures and redacted aggregate counts instead.

## Reporting a Vulnerability

Do not file sensitive vulnerabilities, secrets, or personal health data in a
public GitHub issue.

1. Prefer [GitHub private vulnerability reporting](https://github.com/roian6/apple-health-ai-bridge/security/advisories/new).
2. If private reporting is unavailable, email `healthbridge@chanhyo.dev` with the subject prefix `[SECURITY]`.

Start with the minimum information needed to coordinate privately. Do not attach
real HealthKit values, tokens, pairing material, setup pages, receiver databases,
cursor values, local outbox payloads, private keys, provisioning profiles, or
private endpoint details. If a sensitive artifact is genuinely necessary, first
agree on a safe transfer method with the maintainer.

A useful report should include:

- affected component;
- impact;
- reproduction steps using synthetic data;
- whether HealthKit permissions, receiver authentication, local outbox storage, or MCP output are involved;
- no real tokens, no real health values, and no pairing material.

For non-security setup and product questions, use the [support page](https://healthbridge.chanhyo.dev/support). See the public [privacy policy](https://healthbridge.chanhyo.dev/privacy) for the current Health Bridge privacy statement.

## Supported Versions

Version 1.0.0 and later receive security fixes on the main branch.

## Security Model Boundaries

- HealthKit access is read-only by default.
- The receiver is intended for user-owned local/private-network deployment.
- MCP and CLI tools are read-only query surfaces over the local store.
- The project does not intentionally include telemetry, analytics, advertising hooks, hidden cloud upload, or third-party AI calls.

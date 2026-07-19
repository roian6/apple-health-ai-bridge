# Maintainer guide

This guide records the public triage, merge, and release process for Apple Health AI Bridge. It complements [CONTRIBUTING.md](../CONTRIBUTING.md), [SECURITY.md](../SECURITY.md), and [SUPPORT.md](../SUPPORT.md).

## Solo-maintainer phase

While the repository has one direct maintainer, the main ruleset keeps pull requests, required checks, linear history, resolved review threads, squash-only merging, deletion protection, and non-fast-forward protection. The required approval count is `0`, and last-push approval is disabled because an author cannot approve their own pull request.

When a second trusted maintainer is added, restore one required approval and last-push approval. Do not enable required code-owner review before that reviewer exists.

Do not routinely disable the main ruleset or push directly to `main`. Emergency changes still use a narrowly scoped pull request and the same required checks.

## Intake and triage

1. Move sensitive security reports out of public Issues and into GitHub private vulnerability reporting.
2. Reproduce ordinary defects with synthetic fixtures or redacted aggregate output.
3. Assign one area label and one status label. Add a priority only when impact justifies it.
4. Classify the issue as accepted, needs reproduction, needs a design decision, blocked, duplicate, or out of scope.
5. Add a milestone only after the work is assigned to an actual release.

Recommended area labels:

- `area: ios`
- `area: python`
- `area: receiver`
- `area: mcp`
- `area: docs`

Recommended workflow labels:

- `privacy-review`
- `needs-reproduction`
- `needs-decision`
- `blocked`
- `breaking-change`
- `release-note`
- `priority: p0`, `priority: p1`, `priority: p2`

Do not use an automatic stale closer by default. Review inactive issues manually each month.

## Design decisions before implementation

Require an accepted issue and maintainer decision before implementation when a change affects:

- HealthKit permissions or read/write scope;
- receiver authentication, pairing, disconnect, reset, or deletion;
- outbox, cursor, correction, or replay semantics;
- public internet, hosted, remote, telemetry, analytics, advertising, or third-party AI paths;
- privacy policy, App Review notes, entitlements, screenshots, or App Privacy Details.

## Pull requests

- Use `fix/`, `feat/`, `docs/`, or `chore/` branch prefixes.
- Keep each pull request focused on one change.
- Use synthetic fixtures and redact all public evidence.
- Run the Python gates in `CONTRIBUTING.md` and the relevant Swift/Xcode gates for iOS changes.
- Resolve every review thread.
- Require these exact status checks on `main`:
  - `Python quality and package checks`
  - `Swift tests and unsigned app builds`
- Use squash merge only. The pull-request title becomes the durable change summary.

Fork pull requests must run with read-only workflow permissions, no repository secrets, no persisted checkout credentials, and no `pull_request_target` execution of untrusted code.

## Releases

Use SemVer:

- `v1.0.1` for backward-compatible fixes;
- `v1.1.0` for the next backward-compatible feature set;
- a major version for intentional breaking changes.

Before release:

1. collect merged work labeled `release-note` or `breaking-change`;
2. update versions and release notes in one reviewed pull request;
3. run the full public, Python, and iOS gates;
4. create a signed annotated tag for the exact approved commit;
5. let the protected exact-tag workflow build, verify, attest, and publish an immutable release;
6. verify the remote tag, release assets, checksums, attestations, and linked site state.

Treat source-release status and TestFlight/App Store distribution status as separate facts.

## Response targets

These are targets, not guarantees:

- private security report acknowledgement within 72 hours;
- issue triage within five business days;
- pull-request initial response within seven days.

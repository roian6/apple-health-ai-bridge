# Maintainer guide

This guide records the public triage, merge, and release process for Apple Health AI Bridge. It complements [CONTRIBUTING.md](../CONTRIBUTING.md), [SECURITY.md](../SECURITY.md), and [SUPPORT.md](../SUPPORT.md).

## Solo-maintainer phase

While the repository has one direct maintainer, the main ruleset keeps pull requests, required checks, linear history, resolved review threads, squash-only merging, deletion protection, and non-fast-forward protection. The required approval count is `0`, and last-push approval is disabled because an author cannot approve their own pull request.

One required approval and last-push approval may be enabled when a second trusted maintainer can provide human review, or when an independently eligible native automated reviewer has been demonstrated on a real pull request. For an automated reviewer, read back the App's identity, review state, reviewed commit, and GitHub's actual approval and last-push eligibility before changing the rules. A summary comment or successful check alone is not an eligible review. Do not enable required code-owner review before an eligible code owner exists.

The repository's `.coderabbit.yaml` configures English reviews, walkthrough summaries, incremental review, and the request-changes workflow, with author approval overrides disabled and drafts excluded. Installing the hosted CodeRabbit App and confirming its effective configuration are separate maintainer actions. This configuration does not establish that the App is installed, that its reviews satisfy a rule, or that an approval requirement has been activated.

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
  - `Analyze Python`
- Use squash merge only. The pull-request title becomes the durable change summary.

Fork pull requests must run with read-only workflow permissions, no repository secrets, no persisted checkout credentials, and no `pull_request_target` execution of untrusted code.

## Releases

Version each component independently:

- existing `v1.0.0` and `v1.0.1` tags are immutable historical Receiver/CLI releases;
- future Receiver/CLI releases use `receiver-v<semver>`;
- iOS source or distribution checkpoints use `ios-v<marketing-version>-build.<build>`;
- Batch Protocol versions change only when the wire contract changes.

Set `release_scope` explicitly in `component-versions.json`. Use `receiver` only when Receiver/CLI advances while the compatible iOS Companion and Batch Protocol remain identical to the predecessor baseline. Use `ios` only when the iOS Companion version and/or build advances while Receiver/CLI and Batch Protocol remain identical to the predecessor baseline. Use `coordinated` when Receiver/CLI and at least one other component advance together; version equality never determines scope.

Before release:

For future releases, verify test additions for major functionality and
behavior-changing fixes against the contributor policy. Require
`bash scripts/swift-analysis.sh`, including both controls and complete production
file coverage, in `.github/workflows/ios.yml` on the exact source commit, alongside
the existing Python, Swift test, and unsigned build gates. Resolve findings before
publication. This obligation applies prospectively; it does not assert that these
analyses ran for historical immutable releases.

1. collect merged work labeled `release-note` or `breaking-change`;
2. update each changed authoritative version source, `component-versions.json`, and release notes in one reviewed pull request;
3. state the exact compatible iOS Companion version/build and exact compatible Batch Protocol schema identifier/version in the release notes;
4. run the full public, Python, and iOS gates;
5. create a signed annotated component-scoped tag for the exact approved default-branch commit, or the receiver maintenance target authorized below;
6. let the protected exact-tag workflow verify the source authority and its actual first-parent baseline, then build, verify, attest, and publish an immutable release;
7. verify the remote tag, release assets, checksums, attestations, and linked site state.

Treat source-release status and TestFlight/App Store distribution status as separate facts.

### Protected receiver maintenance patches

For `receiver-v1.1.4`, the maintenance source is
`refs/heads/fix/receiver-1.1.4`, based on immutable `receiver-v1.1.3` at
`a4fd59e2f222251ab9ff76cb0eb08524035fcb6d`. Keep later main product changes out of
that branch. Backport only the reviewed release policy and required fixes; do
not reset main or substitute the maintenance SHA for default main.

Protect the exact maintenance branch with reviewed squash merges, the same
required checks and latest-push approval requirements, and deletion/force-push
protection. The checked-in Python, iOS and CodeQL workflows accept PRs and run
on pushes to this exact branch. Confirm the effective hosted checks and rules
before merging; source configuration alone does not provision protection.

After the maintenance PR's GitHub squash commit is known and its checks have
passed, use a separate reviewed main PR to add its exact authorization to
`.github/release/receiver-maintenance.json`. Retain the root schema identifier
`health_bridge.receiver_maintenance.v1` and put the five fields documented in
[versioning](versioning.md#receiver-maintenance-source) in `releases`. Do not
reserve a target with a placeholder SHA. Until that PR merges, the empty list
intentionally blocks non-main releases.

Create the signed annotated tag only on the authorized squash target. Keep the
existing maintainer/tag/commit identity checks, protected `github-release`
environment, tag rules and exact-tag dispatch requirements. Maintenance records
do not authorize branch-based dispatch, expand environment policies, waive
checks, or replace release artifacts. The eight-asset set, SHA-256 verification,
helper validation, and build/final attestations remain required. Source review,
hosted governance readiness, and actual release publication are separate gates.

## Response targets

These are targets, not guarantees:

- private security report acknowledgement within 72 hours;
- issue triage within five business days;
- pull-request initial response within seven days.

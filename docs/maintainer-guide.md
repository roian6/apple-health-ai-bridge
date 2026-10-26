# Maintainer guide

This guide records the public triage, merge, and release process for Apple Health AI Bridge. It complements [CONTRIBUTING.md](../.github/CONTRIBUTING.md), [SECURITY.md](../.github/SECURITY.md), and [SUPPORT.md](../.github/SUPPORT.md).

## Current repository ruleset

The main ruleset requires one approving review and approval of the latest push. It dismisses stale reviews, requires review threads to be resolved, and allows squash merging only. It also protects required checks, linear history, branch deletion, and non-fast-forward updates.

Keep the approval requirement aligned with an eligible reviewer. A second trusted maintainer can provide human review; an automated reviewer counts only after it has been demonstrated as eligible on a real pull request. For an automated reviewer, read back the App's identity, review state, reviewed commit, and GitHub's actual approval and last-push eligibility before changing the rules. A summary comment or successful check alone is not an eligible review. Do not enable required code-owner review before an eligible code owner exists.

The repository's `.coderabbit.yaml` configures English reviews, walkthrough summaries, incremental review, and the request-changes workflow, with author approval overrides disabled and drafts excluded. The anchored `reviews.auto_review.base_branches` entries include `release` and the documented `fix/`, `feat/`, `docs/`, and `chore/` working branches in addition to the default branch, so stacked PRs can receive review and classification before retargeting. Other target branches are not enabled by a catch-all pattern. Installing the hosted CodeRabbit App and confirming its effective configuration are separate maintainer actions. This configuration does not establish that the App is installed, that its reviews satisfy a rule, or that an approval requirement has been activated.

Do not routinely disable the main ruleset or push directly to `main`. Emergency changes still use a narrowly scoped pull request and the same required checks.

## Intake and triage

1. Move sensitive security reports out of public Issues and into GitHub private vulnerability reporting.
2. Reproduce ordinary defects with synthetic fixtures or redacted aggregate output.
3. Type and area labels are classified from the issue's requested work or the PR's actual changes. Existing issue-form labels remain useful input. Assign a human triage status and add a priority only when impact justifies it.
4. Classify the issue as accepted, needs reproduction, needs a design decision, blocked, duplicate, or out of scope.
5. Add a milestone only after the work is assigned to an actual release.

The [CodeRabbit configuration](../.coderabbit.yaml) shares one set of type and area instructions between PR reviews and issue labeling. Automatic application is enabled for these classifications only. Existing valid type labels should be respected, and multiple areas may apply when several components are directly affected. Background mentions and behavior explicitly left unchanged are not reasons to add an area. Genuinely unclear work can remain unclassified for maintainer triage.

CodeRabbit is the only automatic PR classifier. PR labels are part of its normal review rather than a separate review request. Labels may be delayed when a review is skipped or its allowance is exhausted; do not request another full review just to refresh labels. Working-branch review coverage consumes the same developer review allowance. Repository YAML is read from the PR branch, so changing the default-branch configuration does not retroactively replace an older PR's configuration; existing PRs adopt the new policy through their normal source integration. Issue classification is configured separately, with automatic enrichment comments and implementation planning disabled. Configuration validation alone does not establish App permission, service availability, or successful label application.

Area labels describe the directly affected responsibility, not every language or helper used to implement it. A brand renderer and its regression tests do not imply Python package work or CI changes. Python-specific validation/fuzzing infrastructure and real packaging changes can qualify for `area: python`; actual workflow, build/release, lint/security or review/label automation changes qualify for `area: ci`. Brand assets and documentation qualify for `area: docs`. Supporting files do not change the primary type by themselves.

Priority, acceptance, reproduction status, blocking decisions, privacy review, breaking-change assessment, and release notes remain maintainer decisions and are excluded from the automatic label list. Preserve existing and human-applied labels; do not treat classification as approval to implement or release work. Repository review requirements and billing settings are unchanged.

The existing [label rules](../.github/labeler.yml) and commit-pinned [Multi Labeler](https://github.com/fuxingloh/multi-labeler) action remain an append-only **issue-only, area-only** fallback. The workflow has no PR event or PR-write permission; it cannot add path-derived areas to PRs before or after semantic classification. Its six area rules remain available for explicit issue titles and form selections without comments or new merge requirements. CodeRabbit owns automatic primary-type classification, while explicit issue-form and human type labels remain respected. Retire this final issue fallback only after native CodeRabbit area application, existing-label preservation, and quiet operation have been verified on genuine free-form issue events. Existing labels are not bulk-removed during the transition, and fallback-origin labels are not evidence of CodeRabbit writes.

Recommended area labels (a PR may span several):

- `area: ios`
- `area: python`
- `area: receiver`
- `area: mcp`
- `area: docs`
- `area: ci`

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
- Run the Python gates in [`.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md) and the relevant Swift/Xcode gates for iOS changes.
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
2. update each changed authoritative version source, `component-versions.json`, and release notes drafted from the [release notes template](../.github/release/release-notes-template.md) in one reviewed pull request;
3. state the exact compatible iOS Companion version/build and exact compatible Batch Protocol schema identifier/version in the release notes;
4. run the full public, Python, and iOS gates;
5. freeze the reviewed release source and create a genuine signed annotated tag locally;
6. run the release-branch candidate workflow and qualify the same package/helper on the owner Mac before pushing the exact tag object;
7. use the protected tag-based publication workflow, then verify downloaded public bytes and isolated installation before moving install pins.

Follow [release operations](release-operations.md) for exact candidate IDs, artifact transport, native staging and recovery commands. Source-release status and TestFlight/App Store distribution status are separate facts.

### Protected stable source

Maintain one protected `release` branch. Enable repository merge commits for reviewed main-to-release promotions while preserving main's existing squash-only and linear-history requirements. Release requires the same reviews, latest-push approval, resolved conversations, strict required checks and deletion/force-push protection, without bypass actors. The source policy verifies effective hosted rules; checked-in configuration alone does not provision them.

Use short fix branches from release, squash reviewed fixes when appropriate, and forward-port needed runtime fixes to main. Prepare candidate versions only on the stable line. Release-control changes on main do not require changing main's runtime version or moving published install pins.

Source eligibility is an exact PR merge plus successful checks, signed tag binding and trusted-main policy. No per-patch main JSON grant is required. Policy can revoke a commit or tag object explicitly. A candidate cannot authorize itself by editing its own policy copy.

The old `receiver-v1.1.4` tag is retained as a retired unpublished, unsupported candidate. Its unconsumed grant is empty; its immutable identity is recorded in the static policy. Published `receiver-v1.1.5` completes the stable maintenance bootstrap from `receiver-v1.1.3`. Forward-port its workflow fixes, component metadata, and published installation references through a normal main PR. Preserve main's unreleased runtime features and migrations; advancing its source version does not publish those features.

## Response targets

These are targets, not guarantees:

- private security report acknowledgement within 72 hours;
- issue triage within five business days;
- pull-request initial response within seven days.

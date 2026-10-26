# Release criteria

Use this checklist before publishing a release or making a public launch announcement.

The App Store is the normal iPhone installation path. TestFlight is for beta
distribution, and source-build remains a separate path for contributors and
developers.

Prepare future Receiver/CLI notes with the
[release notes template](release-notes-template.md). Keep the release scope,
component compatibility, and published notes body aligned with the versioned
source and the checks below.

A coordinated release is a cutover, not a source-only preview. Before announcing the new GitHub Release or updating the official website install surface, the matching signed iOS build must pass external Beta App Review. The release-branch candidate workflow validates the reviewed source and genuine local signed tag, reruns source gates, and creates an immutable attested Actions packet. Native qualification precedes the public tag push; the protected tag-based continuation reconciles and publishes the complete helper-bound packet. Keep version-specific public surfaces on HOLD until the signed iOS candidate, exact helper, GitHub Release, and coordinated cutover checks below all pass; verify the Public Link anonymously immediately after the approved build is intentionally assigned.

A private TestFlight candidate may be archived, uploaded, assigned to a private tester group, and submitted for external Beta App Review before the public tag only when the private release packet records the exact source commit and tree, signed archive metadata and checksum, complete source/package gates, and real-device smoke evidence. This validation does not authorize a public TestFlight link, App Store submission, GitHub Release, or website cutover. Before any version-specific public action, verify the final reviewed snapshot against the approved signed candidate, confirm external approval, publish the required checksums and provenance, and then verify anonymous Public Link access after assignment.

A receiver-only patch may advance the Receiver/CLI version while keeping the last verified iOS Companion version/build and Batch Protocol unchanged. For that scope, maintainers must not upload a new TestFlight build merely to make version numbers match. The exact-tag workflow must still run the iOS source gates, the versioned notes must name the exact compatible iOS Companion and Batch Protocol and state that no TestFlight update is required, and `release-metadata.json` must set `release_scope` to `receiver` while independently recording every component version. An iOS-only checkpoint must declare `release_scope` as `ios`, preserve the Receiver/CLI version/tag and Batch Protocol, advance the iOS marketing version and/or build with a higher build number, and use an `ios-v<marketing-version>-build.<build>` tag without invoking Receiver/CLI artifact or release-note validation. A coordinated release must declare `release_scope` as `coordinated`, advance Receiver/CLI plus iOS Companion or Batch Protocol, and name the exact resulting compatibility in its notes. Update `component-versions.json` in the same commit as any authoritative version source; release validation must reject drift between that index, `pyproject.toml`, Xcode settings, and the canonical batch fixture.

An iOS-only source checkpoint tag must trigger the read-only **Python quality and package checks** and **Swift tests and unsigned app builds** workflows. The Python workflow pins the live annotated tag object, verifies its signature and maintainer identity, qualifies the exact reviewed release source against trusted-main policy and the previous independently verified iOS checkpoint, and runs `release_tools.py validate`; the iOS workflow reruns the existing Swift and unsigned app source gates. Neither workflow may publish artifacts, enter the `github-release` environment, or mutate repository contents. Before creating the first iOS checkpoint tag, configure and read back a tag ruleset targeting `refs/tags/ios-v*` that restricts updates and deletions and allows only the intended release maintainer to create a new tag. A failed check or missing ruleset keeps the checkpoint and every downstream TestFlight/App Store claim on HOLD.

## Historical release contracts

The following version-specific requirements record earlier release contracts. They
do not identify the current candidate; use its declared component versions and the
applicable publication checks below.

For the coordinated 1.1.0 packet, review every public note, checklist, and App Review surface against the same product boundary: Direct is the default and never falls back automatically; Encrypted iCloud Mailbox is an explicit opt-in, Mac-only Beta with application-layer encryption, signed ACK/commit semantics, a user-owned iCloud container and receiver, and an optional per-user macOS LaunchAgent. Batch Protocol remains `health_bridge.batch.v1 (1.0.0)`. App Store Connect may remain “Data Not Collected” only while neither the developer nor an integrated third party can access the user's receiver, iCloud container, or transmitted HealthKit records.

Mailbox publication is release-blocking for Receiver/CLI `1.1.1`: the release must contain `HealthBridgeMailboxAckPublisher-1.1.1.zip` and `HealthBridgeMailboxAckPublisher-1.1.1.manifest.json`. The helper manifest must bind the archive SHA-256/size, component version/build, exact annotated tag object/commit/tree, canonical `macos/HealthBridgeMailboxAckPublisher` Git tree, Developer ID publisher and Team ID, a non-device-limited provisioning profile, secure timestamp, hardened runtime, accepted notarization, stapled ticket, and Gatekeeper assessment. Final `SHA256SUMS` must cover both helper assets as well as the wheel, sdist, and release metadata. Publication fails unless the exact downloadable helper satisfies this contract.

## Required checks

For future releases, confirm automated regression tests accompany major
functionality and behavior-changing bug fixes. Require the exact source commit
to pass `bash scripts/swift-analysis.sh` in `.github/workflows/ios.yml`, including
the clean and known-bad controls and all production Swift scopes, in addition to
the existing Swift tests and unsigned builds. Retain the tool version, archive
digest, file coverage, and findings with the release validation evidence. A Linux
runtime blocker does not satisfy the native macOS gate. This prospective check
does not change the validation claims of historical immutable releases.

```bash
test -z "$(git status --porcelain=v1)"
uv sync --all-extras --dev --locked
uv run python scripts/public-release-audit.py --strict
git diff --check
git diff --cached --check
uv run ruff format --check .
uv run ruff check .
uv run basedpyright
uv run bandit -r src -q
uv run pip-audit --local --skip-editable
uv run pytest -q
rm -rf dist
uv build --build-constraints .github/release/build-constraints.txt --require-hashes --out-dir dist
uv run python scripts/package-smoke.py --dist-dir dist
version="$(uv version --short)"
uv run python scripts/release_tools.py validate --repo . --tag "receiver-v$version"
gitleaks git --config .github/linters/gitleaks.toml --redact --no-banner --log-opts='--all'
```

Use Gitleaks `v8.30.0` and verify the release-archive checksum against the immutable value in `.github/workflows/python.yml` before running the command. The scan must cover every reachable ref; a working-tree-only scan is not sufficient. Both `checks` and `build-and-test` must pass on the exact source commit before publication or cutover.

The package smoke inspects the wheel and source distribution, installs the wheel into a fresh environment, initializes every bundled migration, and runs the synthetic status/MCP path. Source-tree tests do not replace this artifact check.

## Signed tag publication

Before pushing a release tag, configure and read back these repository-side gates. They are not created by the workflow itself:

1. Create the GitHub Actions environment **`github-release`**. Add **Required reviewers** so publishing pauses for an explicit maintainer approval after QA. Add a deployment tag rule matching `receiver-v*` and do not allow deployments from branches or from legacy `v*` tags. This prevents the historical `v*` workflow stored in an old commit from entering the publication environment. If the repository has only one release maintainer, that maintainer may approve the environment gate; the approval still must be a distinct, deliberate release action after the tag jobs finish.
2. Create an active tag ruleset targeting `refs/tags/v*`. Enable **Restrict creations**, **Restrict deletions**, and **Restrict updates**, with no bypass actors. Applying the ruleset preserves existing `v1.0.0` and `v1.0.1` while it denies every new legacy tag creation and prevents either historical tag from being moved, deleted, or recreated.
3. Create a separate active tag ruleset targeting `refs/tags/receiver-v*`. Enable **Restrict creations**, **Restrict deletions**, and **Restrict updates**. Limit bypass to the release maintainer role needed to create a new signed tag; the workflow token does not need tag mutation permission. Never bypass the ruleset to move or recreate an existing version.
4. Open GitHub repository **Settings → General → Releases** and select **Enable release immutability**. Read back all four controls immediately before the next tag: the environment name/reviewer and `receiver-v*` deployment rule, the no-bypass legacy `v*` ruleset, the protected `receiver-v*` creation ruleset, and release immutability enabled.

The downloadable proof policy starts prospectively at Receiver/CLI `1.1.3`
(including prereleases with that version core). Earlier immutable releases retain
their original asset contracts; do not retrofit bundles or checksums onto
`receiver-v1.1.2` or any older release. Adding this policy does not change the
current source version or publish a new release.

Release metadata v4 binds core provenance to `release.yml@refs/heads/release`; final provenance remains bound to `publish-release.yml@refs/tags/<tag>`. Both source and signer digests must equal the frozen source SHA. Historical v3 packets retain their original tag-based proof contract, without a fallback for new candidates.

The candidate workflow exports the action's original signed Sigstore bundle as `receiver-build-provenance.intoto.jsonl`. Its exact subjects remain the wheel, sdist and `release-metadata.json`. Candidate preparation has no Release write permission and no Apple credentials. A genuine local annotated tag is verified against registered maintainer SSH signing keys before its public ref is pushed.

Follow [release operations](../../docs/release-operations.md) to freeze the candidate, dispatch the exact source, obtain the original run/attempt/artifact, stage and verify the native helper, then publish the same signed tag object. The existing native staging script accepts a locally verified tag; no placeholder tag or second helper manifest is needed.

The protected publication workflow runs only from that public tag. It downloads the original candidate artifact, verifies its native proof and execution snapshot, and verifies the exact staged helper on a clean macOS runner before publication. `github-release` retains its `receiver-v*` tag-only policy and required reviewer gate. Main is not a privileged publication ref.

The final packet contains exactly eight assets. `SHA256SUMS` covers the two Python artifacts, release metadata, original build proof, helper archive and helper manifest. It excludes itself and the final proof. Final provenance attests exactly the helper archive, helper manifest and checksums.

All Release-changing workflow jobs share one repository publication mutex. Reconciliation downloads remote bytes before mutation, preserves matching files and uploads only missing files. An existing valid final proof is reused byte-for-byte. A matching published release is verify-only, including recovery after publication succeeded but readback failed. Duplicate releases, unknown files, wrong bytes or identities, expired candidate evidence and stale baselines HOLD. Never delete/recreate a draft, clobber an asset, move a public tag or rerun blindly to repair a conflict.

The strict audit also rejects unreviewed RFC1918 addresses, user-specific macOS or
Linux home paths, account-linked email addresses, signing team IDs, non-neutral
bundle identifiers, live `hbi_` invitation secrets, and unknown valid-shaped
manual pairing codes, including concrete values accidentally added to the audit or
guardrail definition files themselves. Only designated synthetic fixtures and
reviewed system/product namespaces are allowlisted.

Run Swift and Xcode checks on a Mac when iOS code, project settings, assets, entitlements, or privacy manifests change:

```bash
cd ios/HealthBridgeCompanion
swift test
xcodebuild -project HealthBridgeCompanion.xcodeproj \
  -target HealthBridgeCompanion \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project HealthBridgeCompanion.xcodeproj \
  -target HealthBridgeCompanion \
  -sdk iphoneos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Before archiving, read the highest existing build number in App Store Connect and set `CURRENT_PROJECT_VERSION` to a greater integer. Record the selected marketing version, build number, Git commit, and tree in the private release packet. If the build may move from internal testing to an external group, do not upload it with the `TestFlight Internal Only` option.

A physical iPhone smoke test is required before claiming that real Apple Health sync works in a release.

For an in-place upgrade, identify the currently active predecessor build from TestFlight rather than hardcoding a historical number. Open that predecessor while online, disable Background Sync, and wait for its cancellation to finish before installing the candidate. The candidate must use a new background-session identifier, reconnect to the predecessor identifier only to cancel inherited tasks, and never let legacy callbacks mutate the current outbox. Then verify the recovery-required reset/re-pair flow before any new upload. Updated client code cannot retract a request that completed before it executed, so the pre-upgrade cancellation is part of the distribution test gate.

These current-tree checks are necessary but do not inspect deleted blobs, remote
refs, or issue and pull-request history. When a private history must remain
private, publish from a separately audited one-root snapshot with a neutral
author, zero inherited remotes, and only the final tracked tree.

## Public repository hygiene

The public repository should contain:

- source code;
- synthetic fixtures;
- public docs and templates;
- reproducible test commands;
- generated brand/app icon assets that are deliberately tracked.

It should not contain:

- real HealthKit values, exports, screenshots, or identifiable source names;
- receiver databases;
- bearer tokens, token hashes, pairing links, setup pages, or cursor values;
- local outbox payloads;
- private endpoint details;
- App Store Connect account material, signing certificates, provisioning profiles, or filled reviewer notes;
- internal planning transcripts, stage diaries, private QA logs, or tool-specific cleanup reports.

Use `.public-release-denylist.local` for private values that should be checked locally but never committed. Start from `.github/release/public-release-denylist.local.example`; the `.local` file is gitignored and is read by the strict audit.

## QA evidence

Public QA evidence should be reproducible and concise:

- synthetic quickstart passes from a fresh database;
- MCP smoke returns a compact read-only summary;
- docs explain the local-first and read-only boundaries;
- real-device checks, when performed, are summarized only with redacted aggregate statements.

Do not publish detailed private device-session logs or screenshots to prove diligence.

## Release wording

Safe wording:

- developer preview;
- local-first;
- read-only HealthKit access;
- self-build iOS path;
- TestFlight planned or available only after it is intentionally published;
- background sync is best-effort.

Avoid claims that the project exports every Apple Health family, guarantees background freshness, provides a hosted service by default, or makes clinical decisions.

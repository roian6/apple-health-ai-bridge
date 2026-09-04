# Release criteria

Use this checklist before publishing a release or making a public launch announcement.

A coordinated release is a cutover, not a source-only preview. Before announcing the new GitHub Release or updating the official website install surface, the matching signed iOS build must pass external Beta App Review. The tagged-release workflow separately validates an annotated GitHub-verified tag and commit, reruns the exact-tag Python and iOS source gates, creates an attested helper-pending draft with the wheel, sdist, and source-bound metadata, and deliberately does not publish it. The bound manual continuation publishes only after the owner supplies the newly signed exact-source helper and public manifest. Keep version-specific public surfaces on HOLD until the signed iOS candidate, exact helper, GitHub Release, and coordinated cutover checks below all pass; verify the Public Link anonymously immediately after the approved build is intentionally assigned.

A private TestFlight candidate may be archived, uploaded, assigned to a private tester group, and submitted for external Beta App Review before the public tag only when the private release packet records the exact source commit and tree, signed archive metadata and checksum, complete source/package gates, and real-device smoke evidence. This validation does not authorize a public TestFlight link, App Store submission, GitHub Release, or website cutover. Before any version-specific public action, verify the final reviewed snapshot against the approved signed candidate, confirm external approval, publish the required checksums and provenance, and then verify anonymous Public Link access after assignment.

A receiver-only patch may advance the Receiver/CLI version while keeping the last verified iOS Companion version/build and Batch Protocol unchanged. For that scope, maintainers must not upload a new TestFlight build merely to make version numbers match. The exact-tag workflow must still run the iOS source gates, the versioned notes must name the exact compatible iOS Companion and Batch Protocol and state that no TestFlight update is required, and `release-metadata.json` must set `release_scope` to `receiver` while independently recording every component version. An iOS-only checkpoint must declare `release_scope` as `ios`, preserve the Receiver/CLI version/tag and Batch Protocol, advance the iOS marketing version and/or build with a higher build number, and use an `ios-v<marketing-version>-build.<build>` tag without invoking Receiver/CLI artifact or release-note validation. A coordinated release must declare `release_scope` as `coordinated`, advance Receiver/CLI plus iOS Companion or Batch Protocol, and name the exact resulting compatibility in its notes. Update `component-versions.json` in the same commit as any authoritative version source; release validation must reject drift between that index, `pyproject.toml`, Xcode settings, and the canonical batch fixture.

For the coordinated 1.1.0 packet, review every public note, checklist, and App Review surface against the same product boundary: Direct is the default and never falls back automatically; Encrypted iCloud Mailbox is an explicit opt-in, Mac-only Beta with application-layer encryption, signed ACK/commit semantics, a user-owned iCloud container and receiver, and an optional per-user macOS LaunchAgent. Batch Protocol remains `health_bridge.batch.v1 (1.0.0)`. App Store Connect may remain “Data Not Collected” only while neither the developer nor an integrated third party can access the user's receiver, iCloud container, or transmitted HealthKit records.

Mailbox publication is release-blocking for Receiver/CLI `1.1.1`: the release must contain `HealthBridgeMailboxAckPublisher-1.1.1.zip` and `HealthBridgeMailboxAckPublisher-1.1.1.manifest.json`. The helper manifest must bind the archive SHA-256/size, component version/build, exact annotated tag object/commit/tree, canonical `macos/HealthBridgeMailboxAckPublisher` Git tree, Developer ID publisher and Team ID, a non-device-limited provisioning profile, secure timestamp, hardened runtime, accepted notarization, stapled ticket, and Gatekeeper assessment. Final `SHA256SUMS` must cover both helper assets as well as the wheel, sdist, and release metadata. Publication fails unless the exact downloadable helper satisfies this contract.

## Required checks

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
uv build --build-constraints build-constraints.txt --require-hashes --out-dir dist
uv run python scripts/package-smoke.py --dist-dir dist
version="$(uv version --short)"
case "$version" in
  1.0.0|1.0.1)
    # Historical tags predate component-transition baselines.
    uv run python scripts/release_tools.py validate --repo . --tag "v$version"
    ;;
  *)
    release_tag="receiver-v$version"
    git fetch origin main
    tag_target_commit="$(git rev-parse HEAD)"
    default_main_commit="$(git rev-parse origin/main)"
    baseline_commit="$(git rev-parse "${tag_target_commit}^1")"
    test "$tag_target_commit" = "$default_main_commit"
    uv run python scripts/release_tools.py validate \
      --repo . \
      --tag "$release_tag" \
      --tag-target-commit "$tag_target_commit" \
      --default-main-commit "$default_main_commit" \
      --baseline-commit "$baseline_commit"
    ;;
esac
gitleaks git --redact --no-banner --log-opts='--all'
```

Use Gitleaks `v8.30.0` and verify the release-archive checksum against the immutable value in `.github/workflows/python.yml` before running the command. The scan must cover every reachable ref; a working-tree-only scan is not sufficient. Both `checks` and `build-and-test` must pass on the exact source commit before publication or cutover.

The package smoke inspects the wheel and source distribution, installs the wheel into a fresh environment, initializes every bundled migration, and runs the synthetic status/MCP path. Source-tree tests do not replace this artifact check.

## Signed tag publication

Before pushing a release tag, configure and read back these repository-side gates. They are not created by the workflow itself:

1. Create the GitHub Actions environment **`github-release`**. Add **Required reviewers** so publishing pauses for an explicit maintainer approval after QA. Add a deployment tag rule matching `receiver-v*` and do not allow deployments from branches or from legacy `v*` tags. This prevents the historical `v*` workflow stored in an old commit from entering the publication environment. If the repository has only one release maintainer, that maintainer may approve the environment gate; the approval still must be a distinct, deliberate release action after the tag jobs finish.
2. Create an active tag ruleset targeting `refs/tags/v*`. Enable **Restrict creations**, **Restrict deletions**, and **Restrict updates**, with no bypass actors. Applying the ruleset preserves existing `v1.0.0` and `v1.0.1` while it denies every new legacy tag creation and prevents either historical tag from being moved, deleted, or recreated.
3. Create a separate active tag ruleset targeting `refs/tags/receiver-v*`. Enable **Restrict creations**, **Restrict deletions**, and **Restrict updates**. Limit bypass to the release maintainer role needed to create a new signed tag; the workflow token does not need tag mutation permission. Never bypass the ruleset to move or recreate an existing version.
4. Open GitHub repository **Settings → General → Releases** and select **Enable release immutability**. Read back all four controls immediately before the next tag: the environment name/reviewer and `receiver-v*` deployment rule, the no-bypass legacy `v*` ruleset, the protected `receiver-v*` creation ruleset, and release immutability enabled.

The tagged workflow creates one helper-pending draft and attests the core packet; it cannot publish. If that phase fails, inspect and remove only that unpublished draft before retrying. Never move or reuse a published version tag.

On the canonical owner Mac, create a private xcconfig outside the repository with the Apple Developer Team, production helper bundle identifier, matching expected bundle identifier, and iCloud container overrides. Do not commit that overlay or signing material. From a clean checkout at the exact signed tag, stage a new helper:

```bash
scripts/stage-mailbox-helper-release.sh \
  --tag "$tag" \
  --xcconfig "$PRIVATE_HELPER_SIGNING_XCCONFIG" \
  --notary-keychain-profile "$PRIVATE_NOTARY_KEYCHAIN_PROFILE" \
  --output-dir "$PRIVATE_HELPER_RELEASE_DIR"
```

The staging command verifies the signed annotated tag and clean canonical helper source; checks the non-secret publisher, Team ID, bundle, and iCloud container against source-controlled release-policy digests; builds with a Developer ID Application identity, secure timestamp, hardened runtime, and a non-device-limited provisioning profile; validates the exact bundle, application, Team ID, sandbox, and iCloud entitlements; submits a private temporary zip with the named Keychain profile and waits for an accepted notarization; staples and validates the ticket; requires Gatekeeper acceptance; then creates and revalidates the deterministic final assets. It prints only public filenames and the helper SHA-256. It emits no credential, Keychain profile name, private path, raw entitlement/profile data, or notary/signing log.

Attach the two newly staged helper files to the existing helper-pending draft without replacing any asset. Then manually run **Continue helper-bound release** with the exact draft database ID, tag, and printed helper SHA-256. A clean GitHub-hosted macOS runner first downloads the exact bound draft assets and independently verifies source/archive/manifest binding, Developer ID publisher and Team ID, profile and entitlements, timestamp and hardened runtime, stapled notarization, and Gatekeeper acceptance. The publish job requires that gate, reverifies the live signed tag/commit identities, current default-main equality, Git tree, existing unpublished draft ID, exact helper source binding and digest, and exact five-asset pre-checksum set. It creates and uploads a new `SHA256SUMS` without clobbering, attests the helper/manifest/checksum, reverifies the exact six-asset draft, and only then changes that same draft to published. It refuses an already published release and cannot create or replace a release.

GitHub defines the push payload's `after` field as the most recent **commit** on the pushed ref. For an annotated tag, the release workflow therefore binds the peeled target commit to `github.event.after`; it separately binds the live tag ref to the locally fetched annotated tag object, verifies the signed tag's internal name, and relies on the active tag ruleset to prevent creation/update/deletion races.

Create a new Receiver/CLI version only from the clean, reviewed, GitHub-verified release commit. Sign the annotated tag with the repository's configured SSH signing key:

```bash
test "$(git config user.name)" = "Chanhyo Jung"
case "$(git config user.email)" in
  *@users.noreply.github.com) ;;
  *) echo "use the GitHub noreply address shown in account settings" >&2; exit 1 ;;
esac
commit_sha="$(git rev-parse HEAD)"
repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
commit_verified="$(gh api "/repos/$repo/commits/$commit_sha" \
  --jq '.commit.verification.verified == true and .commit.verification.reason == "valid" and .author.login == "roian6" and .committer.login == "web-flow" and .commit.author.name == "Chanhyo Jung" and .commit.committer.name == "GitHub"')"
test "$commit_verified" = "true"
tag="receiver-v$(uv version --short)"
git tag -s "$tag" -m "Apple Health AI Bridge Receiver/CLI ${tag#receiver-v}"
git verify-tag "$tag"
test "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse HEAD)"
git push origin "refs/tags/$tag"
```

Do not create a lightweight tag or manually create/replace the GitHub Release. The tagged-release workflow verifies the annotated tag and target commit through GitHub, then creates the helper-pending draft from exact-tag core artifacts. The continuation may publish only that bound draft. A failed workflow is a release blocker; fix the source or workflow and use a new version rather than replacing published assets.

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

Use `.public-release-denylist.local` for private values that should be checked locally but never committed. Start from `.public-release-denylist.local.example`; the `.local` file is gitignored and is read by the strict audit.

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

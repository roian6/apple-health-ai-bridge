# Release criteria

Use this checklist before publishing a release or making a public launch announcement.

The first public launch is a coordinated cutover, not a source-only preview. Before the repository, GitHub Release, or official website install surface is announced, the matching signed iOS build must pass external Beta App Review and its official TestFlight public invitation must be verified anonymously. The tagged-release workflow separately validates an annotated GitHub-verified tag and commit, reruns the exact-tag Python and iOS source gates, publishes wheel/sdist/checksum/metadata artifacts, and records GitHub build provenance. Keep every public surface on HOLD until the signed iOS candidate, TestFlight invitation, and final audited one-root tree all pass the cutover checks below.

A private TestFlight candidate may be archived, uploaded, assigned to a private tester group, and submitted for external Beta App Review before the public tag only when the private release packet records the exact source commit and tree, signed archive metadata and checksum, complete source/package gates, and real-device smoke evidence. This validation does not authorize a public TestFlight link, App Store submission, or repository launch. Before any public action, verify the final audited one-root snapshot against the reviewed signed candidate, confirm external approval and anonymous Public Link access, then publish the required checksums and provenance.

A receiver-only patch may advance the Python receiver version while keeping the last verified iOS companion version/build unchanged. For that scope, maintainers must not upload a new TestFlight build merely to make version numbers match. The exact-tag workflow must still run the iOS source gates, the versioned notes must name the compatible iOS companion and state that no TestFlight update is required, and `release-metadata.json` must set `release_scope` to `receiver` while independently recording the receiver version, iOS source version/build, and batch contract.

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
uv run python scripts/release_tools.py validate --repo . --tag "v$(uv version --short)"
gitleaks git --redact --no-banner --log-opts='--all'
```

Use Gitleaks `v8.30.0` and verify the release-archive checksum against the immutable value in `.github/workflows/python.yml` before running the command. The scan must cover every reachable ref; a working-tree-only scan is not sufficient. Both `checks` and `build-and-test` must pass on the exact source commit before publication or cutover.

The package smoke inspects the wheel and source distribution, installs the wheel into a fresh environment, initializes every bundled migration, and runs the synthetic status/MCP path. Source-tree tests do not replace this artifact check.

## Signed tag publication

Before pushing a release tag, configure and read back these repository-side gates. They are not created by the workflow itself:

1. Create the GitHub Actions environment **`github-release`**. Add **Required reviewers** so publishing pauses for an explicit maintainer approval after QA. Add a custom **deployment tag rule** matching `v*` and do not allow deployment from branches. If the repository has only one release maintainer, that maintainer may approve the environment gate; the approval still must be a distinct, deliberate release action after the tag jobs finish.
2. Create an **active tag ruleset** targeting `refs/tags/v*`. Enable **Restrict creations**, **Restrict deletions**, and **Restrict updates**. Limit bypass to the release maintainer role needed to create a new signed tag; the workflow token does not need tag mutation permission. Never bypass the ruleset to move or recreate an existing version.
3. Open GitHub repository **Settings → General → Releases** and select **Enable release immutability**. Read back all three settings immediately before the first tag: environment name and reviewer, `v*` deployment tag rule, active tag ruleset/ref pattern, and release immutability enabled.

The workflow creates a draft, attaches and attests every asset, and only then publishes it; publication locks the tag and assets. If a draft-stage workflow fails, inspect and remove only that unpublished draft before retrying. Never move or reuse a published version tag.

GitHub defines the push payload's `after` field as the most recent **commit** on the pushed ref. For an annotated tag, the release workflow therefore binds the peeled target commit to `github.event.after`; it separately binds the live tag ref to the locally fetched annotated tag object, verifies the signed tag's internal name, and relies on the active tag ruleset to prevent creation/update/deletion races.

Create the first public version only from the clean, reviewed root commit with the repository's configured SSH signing key:

```bash
test "$(git config user.name)" = "Chanhyo Jung"
case "$(git config user.email)" in
  *@users.noreply.github.com) ;;
  *) echo "use the GitHub noreply address shown in account settings" >&2; exit 1 ;;
esac
commit_sha="$(git rev-parse HEAD)"
git verify-commit HEAD
repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
commit_verified="$(gh api "/repos/$repo/commits/$commit_sha" \
  --jq '.commit.verification.verified == true and .commit.verification.reason == "valid" and .author.login == "roian6" and .committer.login == "roian6"')"
test "$commit_verified" = "true"
tag="v$(uv version --short)"
git tag -s "$tag" -m "Apple Health AI Bridge ${tag#v}"
git verify-tag "$tag"
test "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse HEAD)"
git push origin "refs/tags/$tag"
```

Do not create a lightweight tag or manually create/replace the GitHub Release. The tagged-release workflow verifies the annotated tag and target commit through GitHub, then creates the release from the exact-tag artifacts. A failed workflow is a release blocker; fix the source or workflow and use a new version rather than replacing published assets.

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

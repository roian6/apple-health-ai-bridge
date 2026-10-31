# Versioning and compatibility

Apple Health AI Bridge contains independently released components. Always include the component name when presenting a version; the phrase “repository version” is intentionally avoided because a Git checkout is identified by a commit or tag, not by a single product version.

## Forward-port source versions

| Surface | Source version | Identifier or status |
| --- | --- | --- |
| Receiver/CLI | `1.2.0` | Published as `receiver-v1.2.0` |
| iOS Companion | `1.2.0` (build `51`) | App Store and external TestFlight review pending |
| Batch Protocol | `1.0.0` | `health_bridge.batch.v1` |

The authoritative machine-readable mapping is [`component-versions.json`](../component-versions.json). It declares `release_scope` explicitly. Validation compares the index with the Python package, Xcode settings and canonical Batch fixture. These source versions do not set public installation defaults: the App Store currently offers iOS Companion `1.1.1` (build `50`), while build `51` remains under review and is not available through the App Store or external TestFlight. Keep the guided Receiver/CLI install pinned to `1.1.5` until the matching app build is available and the controlled cutover updates commands, guide links, helper references and compatibility copy together.

Receiver/CLI `1.2.0` is published. The App Store and external TestFlight distribution of iOS Companion `1.2.0` (build `51`) is still pending review, so do not present the coordinated build set as available. The current installation default remains Receiver/CLI `1.1.5`; do not infer general compatibility between that app and Receiver/CLI `1.2.0`.

### One stable release branch

`main` integrates development; `release` is the single protected stable source branch. Promote reviewed main changes through a two-parent merge into release so repeated promotions preserve ancestry. Short fixes may squash into release and are forward-ported to main when needed. Do not reset, rebase or reverse-merge the stable branch to synchronize it. Main retains its squash and linear-history rules.

A candidate identifies an exact source commit/tree, component baseline, genuine signed annotated tag object and workflow run/attempt/artifact. Neither branch tip is the release identity. Subsequent main or release commits do not invalidate a frozen candidate.

[`release-policy.json`](../.github/release/release-policy.json), fetched from current protected default main, supplies the authority. Qualification verifies visible active release protection, an exact GitHub-verified squash or two-parent PR merge, approval of the reviewed head, and passing release-push checks on the final source SHA. Administrators must separately confirm that protection has no bypass actors: GitHub hides that list from read-only tokens. Required contexts remain **Python quality and package checks**, **Swift tests and unsigned app builds**, and **Analyze Python**. A skipped CodeRabbit review is not approval. Candidate-local policy and caller claims cannot grant authority. Trusted-main revocations stop continuation.

Receiver transitions use the last actually published stable Receiver release. Drafts and existing tags do not establish a published baseline. Same-line patch gaps require exact retired unpublished tag records; the records preserve the original tag object and explain the skipped number. The unconsumed `receiver-v1.1.4` maintenance grant is retired; its existing tag remains immutable. The retirement does not prohibit descendants of its source.

A preparation commit and later reviewed fixes may retain the candidate version. The final source is compared with the published baseline, not its immediate parent. Receiver-only patches preserve compatible iOS source/version/build and Batch Protocol. iOS checkpoints use their own previous signed checkpoint with successful exact-tag verification, independently of the Receiver published baseline. Source checkpoints do not assert App Store or TestFlight distribution.

### Candidate and publication provenance

Candidate preparation runs `release.yml@refs/heads/release` at the dispatched source SHA. It imports and verifies the genuine local signed tag against registered maintainer signing keys, runs source/package gates and emits an immutable Actions artifact. It creates neither a public tag ref nor a GitHub Release. Remote tag verification remains pending.

Publication runs `publish-release.yml@refs/tags/<tag>` at that same source SHA behind the existing tag-only `github-release` environment. Release metadata v4 selects strict branch-based core provenance; v3 retains historical tag-based verification. Both roles require exact source and signer digests and exact subject sets. The helper manifest and final eight-asset contract retain their existing formats.

See [release operations](release-operations.md) for local tag transport, native qualification, publication and recovery. Matching published releases are verify-only. Partial drafts retain matching bytes and receive only missing assets; conflicts, expired evidence or changed baselines HOLD before mutation.

## Version surfaces

### Receiver/CLI

The Python package, receiver service, CLI, and MCP server share one semantic version from `pyproject.toml`. Receiver-only fixes may advance this version without changing the iOS app.

The signed macOS mailbox ACK helper is a Receiver/CLI release asset. Its public manifest binds the helper component version/build, signed zip digest, exact Receiver/CLI tag object/commit/tree, canonical helper source tree, Developer ID publisher and Team ID, non-device-limited provisioning profile, secure timestamp, hardened runtime, notarization, stapled ticket, and Gatekeeper assessment. It is required only for the explicit Mac-only mailbox Beta; Direct installations do not download, install, or validate it.

Starting with the release after `1.0.1`, receiver release tags use the component-scoped form:

```text
receiver-v1.0.2
```

Release notes use the same tag in their filename and install examples.

### iOS Companion

The user-visible app version is Xcode `MARKETING_VERSION`. App Store Connect and TestFlight additionally require a monotonically increasing `CURRENT_PROJECT_VERSION` build number. Display both when identifying an installed build:

```text
iOS Companion 1.1.1 (build 50)
```

An iOS source or distribution checkpoint may use a component-scoped tag such as:

```text
ios-v1.1.1-build.50
```

An iOS tag does not publish Receiver/CLI artifacts. TestFlight/App Store release gates remain authoritative for distributed app builds.

### Batch Protocol

Batch Protocol versions describe the wire contract, not either product artifact. A compatible Receiver/CLI or iOS Companion patch must not bump the protocol merely to align numbers. Breaking protocol changes require a new schema identifier/version and an explicit compatibility or migration policy.

## Compatibility policy

- Do not bump an unchanged component merely to make the numbers match.
- Future release notes must state the exact compatible iOS Companion version/build and Batch Protocol schema identifier/version.
- Historical release notes remain as published. When their prose predates explicit component labels, use the immutable tagged source and `release-metadata.json` to establish exact compatibility rather than rewriting history.
- `component-versions.json` must change in the same commit as any authoritative version source.
- Receiver-only releases still run the iOS source gates and record the compatible app build.
- Receiver-only transitions keep iOS Companion and Batch Protocol values identical to the predecessor baseline while Receiver/CLI advances.
- iOS-only transitions declare `release_scope` as `ios`, keep Receiver/CLI and Batch Protocol identical to the predecessor baseline, and advance the iOS marketing version and/or build with a higher build number.
- Coordinated transitions declare `release_scope` as `coordinated`, advance Receiver/CLI plus at least one other component, and must not regress any component.
- App-only releases verify compatibility with the published receiver before TestFlight or App Store promotion.
- Existing `v1.0.0` and `v1.0.1` tags remain immutable. They are historical receiver release tags and are not renamed.
- Future Receiver/CLI tags use `receiver-v<semver>`; future iOS source/distribution tags use `ios-v<marketing-version>-build.<build>`.

## Release presentation

GitHub release display names are separate from immutable release tags. Through
Receiver/CLI `1.1.3`, the display name remains the exact raw tag, including the
historical `v1.0.0` and `v1.0.1` names. Starting at `1.1.4`, the display name must
be exactly `Receiver/CLI <version>`; for example, `Receiver/CLI 1.1.4` for
`receiver-v1.1.4`. The raw tag is not an alternative display name for these new
releases.

The release tool's `tag-info` JSON derives `title` from the canonical tag. The
release reconciler uses that value when creating a draft, and
the shared identity verifier requires it at the core, helper, final-draft and
published stages. Publication preserves the verified draft title; it does not
patch the title afterward. At every stage, the release body must still exactly
match the source notes file.

This presentation rule does not rename tags, notes files or assets, change
component versions, or relax source binding, helper requirements, signatures,
checksums or provenance verification.

Use labels such as:

```text
Receiver/CLI 1.1.5
Compatible iOS Companion 1.1.1 (build 50)
Batch Protocol health_bridge.batch.v1 (1.0.0)
```

Avoid an unlabeled phrase such as “Health Bridge 1.1.0” when it could be read as the app, receiver, or protocol version.

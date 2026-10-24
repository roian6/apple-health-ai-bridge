# Versioning and compatibility

Apple Health AI Bridge contains independently released components. Always include the component name when presenting a version; the phrase “repository version” is intentionally avoided because a Git checkout is identified by a commit or tag, not by a single product version.

## Source compatibility

| Surface | Current version | Public identifier |
| --- | --- | --- |
| Receiver/CLI | `1.1.4` | Release tag `receiver-v1.1.4` |
| iOS Companion | `1.1.1` | Source candidate build `50` |
| Batch Protocol | `1.0.0` | `health_bridge.batch.v1` |

The authoritative machine-readable mapping is [`component-versions.json`](../component-versions.json). The index declares `release_scope` explicitly rather than deriving scope from equal version numbers. Release validation compares the index with `pyproject.toml`, the Xcode project settings, and the canonical batch fixture. A normal tagged release requires the tag target to equal the live default-main commit. The candidate is compared with its actual first-parent baseline. A stale branch or regressing Receiver/CLI, iOS Companion, or Batch Protocol value therefore fails before publication.

### Receiver maintenance source

A receiver patch may use a protected maintenance branch when later main changes
must be excluded. The sole exception authority is
[`.github/release/receiver-maintenance.json`](../.github/release/receiver-maintenance.json)
read from the live protected default-main Git commit. The file defaults to an
empty `releases` list, which authorizes no maintenance release. A candidate's
copy of the file and workflow dispatch inputs cannot grant authorization.

Each record has exactly five string fields: `tag`, `branch_ref`, `base_tag`,
`base_commit`, and `target_commit`. It pins one canonical receiver tag, its
`refs/heads/fix/receiver-<version>` branch, the immutable preceding receiver tag
and peeled commit, and the exact reviewed target commit. The version must be
the next patch on the base's major/minor line. Unknown fields, duplicate JSON
keys, duplicate tags/branches/targets, and incomplete records fail closed.

The live protected maintenance branch HEAD and signed annotated release tag
must both resolve to that exact target. The target must descend linearly from
the pinned base; its real first parent must still carry the base receiver
version. The target declares `receiver` scope, advances only the receiver patch,
and preserves the base iOS source tree, iOS version/build and Batch Protocol
identity/version. The ordinary component-source checks still apply.

The shared release-source resolver refreshes GitHub tag/commit identity and
default-main authority during tagged verification, packet verification, draft
creation, macOS helper verification, continuation, and immediately before final
publication. Moving a branch or revoking its record prevents subsequent stages.
`default_main_commit` always identifies actual default main; it never identifies
the maintenance target. iOS checkpoint tags retain their main-only policy.

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

Use labels such as:

```text
Receiver/CLI 1.1.4
Compatible iOS Companion 1.1.1 (build 50)
Batch Protocol health_bridge.batch.v1 (1.0.0)
```

Avoid an unlabeled phrase such as “Health Bridge 1.1.0” when it could be read as the app, receiver, or protocol version.

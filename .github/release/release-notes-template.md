# Release notes template

## How to use this template

Lead with the user-visible benefit, then explain compatibility and upgrading. Keep detailed asset and provenance information in a collapsible section. Use one logical line per prose paragraph so GitHub can wrap it naturally.

Commit the finished body as `.github/release/notes-<tag>.md` before signing. Initial staging, publication and recovery require the exact source-bound title and body. After publication, hosted title/notes may be edited while the immutable tag and assets stay unchanged; use the explicit read-only `--published-artifacts-only` audit in `docs/release-operations.md` and review the copy separately.

The GitHub title must use the validated component/version format, such as `Receiver/CLI <receiver_version>`; do not repeat it as a large heading in the body. Keep each complete `Compatible iOS Companion` and `Compatible Batch Protocol` declaration below intact: splitting a label and its backticked value across Markdown table cells will not pass the source-note validator.

Replace the scope placeholder with `Coordinated release` when the component index says `coordinated`. For `receiver` scope, use `Receiver-only release` and `No TestFlight update is required` instead. Include only the applicable declarations; they are checked by the source-note validator.

## Release body

[Explain the most useful improvement in one or two sentences.]

## Highlights

- [Describe an observable improvement and link its issue or PR when useful.]
- [Say which setup is affected when a change is conditional.]
- [Leave internal refactors out unless they explain behavior or upgrade risk.]

## Compatibility

[Applicable scope declaration.]

Compatible iOS Companion: `<ios_version> (<build>)`

[State whether the matching iPhone build is available in the App Store, available to external TestFlight testers, or still awaiting review. A published Receiver artifact does not mean the app can already be installed.]

## Install or upgrade

[Link the applicable setup guide. For existing users, explain stopping the Receiver, backing up, installing the verified package, initializing the same database if required, and restarting the existing service. State whether pairing and credentials are preserved.]

[Explain signed-helper replacement separately from service reconfiguration. Include migration, downgrade and pending-queue restrictions that affect the user's decision.]

## Limits and privacy

[Keep this short and actionable. Distinguish limits of the released setup from a feature or channel still pending. Describe only actual privacy implications; do not invent new collection, retention or permission claims.]

<details>
<summary>Release assets and provenance</summary>

Compatible Batch Protocol: `health_bridge.batch.v1 (<batch_version>)`

Receiver-only publication contains the exact expected core files:

- `apple_health_ai_bridge-<receiver_version>-py3-none-any.whl`
- `apple_health_ai_bridge-<receiver_version>.tar.gz`
- `release-metadata.json`
- `receiver-build-provenance.intoto.jsonl`

For a complete native-helper release, list all eight assets, adding:

- `HealthBridgeMailboxAckPublisher-<receiver_version>.zip`
- `HealthBridgeMailboxAckPublisher-<receiver_version>.manifest.json`
- `SHA256SUMS`
- `receiver-final-provenance.intoto.jsonl`

[Provide the actual signature, checksum and provenance instructions. Do not imply a checksum alone proves the source or publisher. `release-metadata.json` and the versioned helper manifest remain the downloadable compatibility records. `SHA256SUMS` covers the two Python packages, release metadata, original build proof, helper archive and helper manifest; the final provenance covers the helper archive, helper manifest and checksums.]

</details>

Before publishing, confirm the rendered body, exact component declarations, actual channel availability, source-bound metadata and required maintainer review. Preserve the published tag, assets and original source notes when improving later editorial copy.

# Release operations

Use one protected `release` branch for stable source. `main` remains the development line. A release is identified by its signed tag object, source commit/tree and immutable artifacts, rather than either branch's current tip. Component versions remain independent; see [versioning](versioning.md).

## Prerequisites

Keep the existing required checks and review conditions on both branches. Main retains squash-only and linear history. Release permits reviewed two-parent merges from main and squash merges for short fixes, with no bypass actors, no force pushes and no deletions. Enable merge commits at repository level without relaxing main's rules. CodeRabbit must actually review the PR; skipped review is not approval.

The `github-release` environment must retain required reviewers and allow only `receiver-v*` tags. Protect stable tag creation, updates and deletion, and enable immutable Releases. Source files do not provision these hosted settings. The policy resolver reads effective release rules and the current protected main policy on every qualification. GitHub hides ruleset bypass lists from read-only callers; an administrator must separately read back the no-bypass setting. Qualification independently checks exact PR approvals, resolved threads and successful source checks, and rejects a nonempty bypass list whenever the API exposes it.

## Freeze and build a candidate

Merge the release PR, then wait for the required push checks on its exact merge SHA. Use an independent, clean checkout at that SHA. Follow-up source commits need their own review/check receipts; an already prepared component version need not change simply because its Git parent changed.

Create a genuine annotated SSH-signed tag locally using the registered maintainer identity. Do not push it yet:

```bash
source_commit="$(git rev-parse HEAD)"
tag="receiver-v$(uv version --short)"
git tag -s "$tag" -m "Apple Health AI Bridge Receiver/CLI ${tag#receiver-v}"
git verify-tag "$tag"
tag_object="$(git rev-parse "refs/tags/$tag^{tag}")"
test "$(git rev-parse "$tag^{commit}")" = "$source_commit"
signed_tag_object="$(git cat-file tag "$tag_object" | python3 -c 'import base64, sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())')"
gh workflow run release.yml --ref release \
  -f source_commit="$source_commit" -f tag="$tag" \
  -f tag_object="$tag_object" -f signed_tag_object="$signed_tag_object"
```

The dispatch fails before checkout when the requested source differs from the execution snapshot. A rerun uses the original `github.sha` and workflow SHA; it must never substitute a newer branch checkout. Each attempt produces a separately named `candidate-<run-id>-<attempt>` artifact. Do not mix files from different attempts.

The raw signed tag object is public, non-executable data. It contains no signing key. Import is limited to an owned independent checkout; the importer checks the exact object hash, tagger, tag name, target commit, tree and registered SSH signer. A conflicting existing local tag is a HOLD, never a replacement.

Record the successful run ID, attempt and artifact database ID from Actions. Set `release_workspace` to an operator-owned directory outside the source checkout. Download the exact artifact into a new child directory, keeping the source checkout clean:

```bash
candidate_dist="$release_workspace/candidate-dist"
candidate_record="$release_workspace/candidate.json"
uv run python scripts/release_candidate.py --phase download --local --repo . \
  --run-id "$candidate_run_id" --attempt "$candidate_attempt" \
  --artifact-id "$candidate_artifact_id" --dist-dir "$candidate_dist" \
  --output "$candidate_record"
```

`--local` verifies the registered signer again and keeps remote tag verification pending. The artifact API digest, source/run/attempt identity, expiry, per-file digests and native core attestation must all pass. The source eligibility receipt is revalidated against current trusted-main policy. Branch advancement alone is allowed; explicit revocation, changed baseline, missing approval or nonpassing checks is not.

## Native qualification before public tag creation

On the owner Mac, retain the normal login HOME and Keychain. From the same clean source with the same local signed tag, use the existing native staging contract:

```bash
scripts/stage-mailbox-helper-release.sh \
  --tag "$tag" \
  --xcconfig "$PRIVATE_HELPER_SIGNING_XCCONFIG" \
  --notary-keychain-profile "$PRIVATE_NOTARY_KEYCHAIN_PROFILE" \
  --output-dir "$PRIVATE_HELPER_RELEASE_DIR"
```

The existing script verifies signing, provisioning, hardened runtime, secure timestamp, notarization, stapling and Gatekeeper, and emits the genuine helper archive and manifest. Keep signing material outside Git. Qualify the same wheel with the installed package smoke and the native installer in an isolated QA namespace. Synthetic source tests are not native signing or installation evidence.

Keep the printed archive and manifest SHA-256 values. Copy only those two public helper files into `$candidate_dist`. Preserve `$candidate_record` outside that directory. Once all candidate and native gates pass, publish exactly the verified tag object:

```bash
git push origin "refs/tags/$tag:refs/tags/$tag"
test "$(gh api "repos/roian6/apple-health-ai-bridge/git/ref/tags/$tag" --jq .object.sha)" = "$tag_object"
```

An absent remote ref may be created; an existing identical ref is reused. A different ref is a HOLD. Never force-push, delete or recreate a stable tag. If qualification required a source change, preserve the failed attempt and create a new candidate identity instead.

## Stage and publish

On the qualified Mac, with no publication workflow active for this repository, stage the packet through the reconciler. This command performs real Release writes only after fresh candidate, remote signed-tag, native proof and helper verification:

```bash
uv run python scripts/release_recovery.py --phase stage --repo . \
  --dist-dir "$candidate_dist" --candidate-record "$candidate_record" \
  --candidate-artifact "$candidate_artifact_id" \
  --helper-sha256 "$helper_sha256" \
  --helper-manifest-sha256 "$helper_manifest_sha256" \
  > "$release_workspace/stage.json"
release_id="$(jq -er '.release_id' "$release_workspace/stage.json")"
gh workflow run publish-release.yml --ref "$tag" \
  -f draft_release_id="$release_id" \
  -f tag="$tag" -f candidate_run_id="$candidate_run_id" \
  -f candidate_attempt="$candidate_attempt" \
  -f candidate_artifact_id="$candidate_artifact_id" \
  -f helper_sha256="$helper_sha256" \
  -f helper_manifest_sha256="$helper_manifest_sha256"
```

The tag selects the executing workflow, not merely an input value. The workflow checks the same source SHA, uses `github-release`, verifies the staged helper on a clean macOS runner, then reconciles checksums and final proof under the repository publication mutex. Candidate core provenance describes `release.yml@refs/heads/release`; final provenance describes `publish-release.yml@refs/tags/<tag>`. Both retain exact source/signer digests and exact subject sets. Metadata v4 explicitly selects the new core provenance role; historical v3 packets remain verifiable under their original tag role.

After publication, download and verify public bytes and run isolated installed-package/native installation checks. Only then update moving install pins. An iOS source checkpoint never publishes Receiver artifacts or proves App Store/TestFlight distribution.

## Resume from observed state

Reissue the same staging or publication operation with the original immutable IDs and hashes after inspecting the reported failure. After staging has returned an ID, pass `--release-id "$release_id"` on staging retries as well. A missing or different pinned Release is a HOLD, never a reason to recreate it. Reconciliation reads GitHub state and downloads asset bytes; a local completion flag is never authority.

| Observed state | Action |
| --- | --- |
| Draft creation succeeded but its response was lost | Find the unique matching release and continue |
| Some core/helper/checksum assets are present | Reuse matching bytes and upload only missing assets |
| Final proof is already present | Verify native identity and subjects, then reuse its original bytes |
| Publication succeeded but readback failed | Verify the published release; perform no writes |
| Unknown file, duplicate release, wrong bytes/source or invalid proof | HOLD before mutation |
| Candidate artifact expired or another stable version was published first | HOLD; qualify a new attempt or candidate as appropriate |

Do not clobber assets, delete/recreate drafts, sign a replacement for an existing valid proof or retry a whole run as a substitute for reconciliation. Preserve the exact failure and remote identities for diagnosis. The retired unpublished `receiver-v1.1.4` tag remains untouched; its policy record accounts for the patch gap without pretending it was published.

## iOS source checkpoints

An iOS checkpoint uses an exact reviewed release source and a local signed `ios-v<version>-build.<build>` tag. Before pushing that tag, qualify its source and component transition:

```bash
uv run python scripts/release_source_policy.py --local-tag --repo . \
  --tag "$ios_tag" --commit "$(git rev-parse HEAD)" \
  --tag-object "$(git rev-parse "refs/tags/$ios_tag^{tag}")" \
  > "$release_workspace/ios-source.json"
uv run python scripts/release_tools.py validate --repo . --tag "$ios_tag" \
  --source-receipt "$release_workspace/ios-source.json"
```

The source receipt marks remote tag verification as pending. Both commands must succeed before the public ref is created. The iOS version/build baseline is the previous signed checkpoint whose exact-tag Python and Swift checks passed. Receiver compatibility is checked against the independently published Receiver tag declared by the candidate, so an unrelated Receiver release does not force an app version change. After the tag is pushed, the read-only Python and iOS workflows verify its public identity and rerun source gates. These operations create no Receiver Release and perform no App Store, TestFlight or device automation.

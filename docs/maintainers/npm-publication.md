# npm publication gate

The intended registry commands are **not publicly available yet**:

```bash
npx -y apple-health-ai-bridge setup
npx -y apple-health-ai-bridge connect
```

Consumers need Node.js >=18 with npm/npx. The package's single executable lets
npm infer `health-bridge`. Python owns setup and connections; the Node launcher
installs the exact digest-bound wheel outside the npx cache. Cache eviction
does not remove that runtime, receiver identity or saved data.

Before advertising these commands, complete every gate below. This repository
does not reserve an npm name, create accounts, configure trusted publishers,
enable protection or publish anything. A registry 404 is not name ownership.

1. Establish npm account/name ownership, account/2FA requirements, initial version
   and dist-tag approval. Build the receiver from the reviewed annotated tag.
   Run release audit, package smoke, Python and Node tests. The npm payload is
   exactly package.json, health-bridge.mjs, backend-pin.json and the bundled
   skills/health-bridge/SKILL.md. The wheel pin must use the immutable GitHub
   release URL, version and SHA-256. File/loopback pins are fixtures only.
2. Complete protected Mac signing using stage-mailbox-helper-release.sh with the
   exact receiver tag, private xcconfig, notary Keychain profile and private output.
   It requires the approved Developer ID identity, production iCloud profile,
   universal2 build, hardened runtime, secure timestamp, accepted notarization,
   stapled ticket and Gatekeeper acceptance. Continue via publish-release.yml;
   unsigned fixtures cannot replace this gate. Keep signing material/logs private.
3. Publish/read back the immutable GitHub release: exact wheel, sdist, npm tarball,
   helper ZIP/manifest, release-metadata.json and SHA256SUMS. Verify source identity,
   attestations and protected Mac results. helper_download.py SOURCE_TREE must
   equal the reviewed helper source tree; source changes require new native gates.
4. Configure the npm trusted publisher for this exact repository, publish-npm.yml
   and protected environment npm-publish. Require reviewers and restrict refs.
   Publication needs a GitHub-hosted runner, Node >=22.14 and npm >=11.5.1.
   Review direct/staged publication and dist-tag permissions for the account.
   No long-lived npm token fallback is provided. Resolve first-publication account
   limitations separately if OIDC is not available for the selected package.
5. Manually review release database ID, full source commit, metadata SHA-256,
   tarball SHA-256 and dist-tag before running the workflow. The protected job
   checks the immutable release, exact file set, SHA256SUMS, attestations and
   wheel binding, then publishes the existing tarball without rebuilding it.
   Only that job has id-token: write. Never dispatch it as a local test.
6. Independently read npm version, dist-tags, integrity, tarball bytes and
   provenance after publication. Compare bytes with the approved tarball and
   exercise the short commands in a clean environment. Only then change the
   public installation instructions to claim availability.

Local registry, Linux signature fixtures and synthetic MCP records are fixture
proof only. Native Mac services/signatures, physical iPhone delivery and actual
desktop-app consumption remain separate acceptance gates.

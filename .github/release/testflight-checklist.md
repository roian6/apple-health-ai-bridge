# TestFlight Readiness

This reusable maintainer checklist helps prepare an official TestFlight beta for Apple Health AI Bridge. The App Store is the normal iPhone installation path. TestFlight is a beta distribution path, and source-build remains separate for contributors and developers. Keep account-owned App Store Connect, signing, reviewer, support, and demo receiver material outside the public repository until it is intentionally published.

Keep public install surfaces on the latest published compatible release while a candidate is in review. Before submitting the candidate for external Beta App Review, add it to the intended external group with **Automatically notify testers** deselected. Do not announce the candidate or update its public link until the matching build has passed review and the release packet is ready. At cutover, manually notify testers and verify the group's Public Link anonymously.

## What the public repository may contain

- iOS companion source with placeholder bundle/team settings.
- Privacy manifest and guardrail tests.
- Public App Review posture notes with placeholders only.
- Synthetic reviewer-demo helper code.
- Public README, architecture, self-build, QA, and release criteria docs.

## What stays private

- Apple Developer Team ID and App Store Connect account details.
- Distribution certificates and provisioning profiles.
- Private bundle ID operating notes that identify an account.
- Filled App Review submission text before publication.
- TestFlight public link before intentional announcement.
- Demo receiver URL, setup pages, pairing links, bearer tokens, or receiver DBs.
- Screenshots that show real health values or identifiable private sources.
- Paid app pricing, tax, banking, or seller-operation records.

## Readiness checklist

### Account and identity

- [ ] The candidate is installed on an iPhone running iOS 18 or later.
- [ ] Xcode 16 or later is used for archive and signing validation.
- [ ] Record the candidate's iOS Companion version and build, Receiver/CLI version and tag, and Batch Protocol version in the private release packet. Confirm they match the declared release scope and compatibility notes.
- [ ] Apple Developer Program membership is active.
- [ ] Individual vs organization seller path is decided.
- [ ] App Store Connect access is available.
- [ ] Real bundle ID is configured outside the public repository.
- [ ] Checked-in Xcode defaults remain public-neutral placeholders.

### App Store metadata

- [ ] App name and subtitle are chosen.
- [ ] Support URL or support email exists.
- [ ] Privacy policy URL exists.
- [ ] App category is chosen.
- [ ] Screenshots or demo images contain no real health values.
- [ ] App Privacy Details match the local-first/read-only behavior and the developer-collection boundary has not changed.
- [ ] If App Store Connect remains “Data Not Collected,” reviewer notes explain that Apple Health records go only to the user-selected receiver, not to the developer.

### HealthKit and privacy review posture

- [ ] HealthKit access is read-only.
- [ ] `NSHealthUpdateUsageDescription`, if present for App Review clarity, states that the app does not write data to Apple Health.
- [ ] Requested HealthKit types exactly match `docs/supported-health-data.md`, the live Privacy Policy, and the private App Review Notes packet.
- [ ] The Swift disclosure-parity test passes so a newly requested type cannot be added silently.
- [ ] Local receiver networking is explained.
- [ ] No hidden cloud, analytics, advertising hooks, data brokers, or third-party AI upload paths exist.
- [ ] Background sync copy remains best-effort.
- [ ] Receiver disconnect and queued-data handling are understandable.
- [ ] Direct is described as the default transport with no automatic fallback.
- [ ] Encrypted iCloud Mailbox is described as an explicit opt-in, Mac-only Beta using application-layer encryption, a user-owned iCloud container and receiver, signed ACK/commit semantics, and an optional per-user macOS LaunchAgent.
- [ ] For a Receiver/CLI release, confirm the matching exact-source signed helper, public manifest, signing and notarization checks, eight-asset packet, checksums, and both provenance bundles pass the release criteria before publication. An iOS-only checkpoint keeps the compatible published Receiver/CLI release.

### Demo and reviewer access, when Apple requests it

- [ ] `.github/release/app-review-notes-template.md` is used only as a placeholder packet.
- [ ] If Apple requests a demonstration receiver, synthetic material is generated privately with `dev app-review-demo`; otherwise no developer-hosted demo receiver is created.
- [ ] When a demo receiver is required, the emitted legacy reviewer credential is kept reachable only for the review window and its lack of automatic expiry is understood.
- [ ] When a demo receiver is required, the emitted `revoke_reviewer_access_command` is retained privately and run immediately after review.
- [ ] Review notes explain what data goes where.
- [ ] Review notes explain that the app is an Apple Health data bridge for user-owned infrastructure.
- [ ] No real health values, tokens, setup pages, pairing links, receiver DBs, or private endpoints are pasted into review notes.

### Build gates

Run on the Mac/Xcode host before uploading:

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

Then use the private signing/archive flow for TestFlight upload.

### Fresh-user physical gate

The detailed procedure, evidence fields, and validator requirements are in
[`docs/qa/public-release-qa.md`](../../docs/qa/public-release-qa.md). Before
cutover, confirm a clean uninstall/reinstall, absent bundle, and empty
**Not Connected** first launch; verify the advertised `/health` route, scan the
setup-page QR with the iPhone Camera, and do not relaunch before pairing commits.
`devicectl --payload-url` was not used. Exercise native permission prompts and
record exactly one invitation redemption and one active mapped credential.

Complete **All** history sync and unchanged-data idempotence with zero duplicate
device, credential, and record identities. Receiver-offline **Sync Now** must
finish within eight seconds, without Health collection, enqueue, or per-lane
upload attempts. Separately verify durable mid-transfer queue recovery to zero
against the same receiver and a write-free **Check Connection**. Label whether
Keychain freshness is proven or remains `container-clean, keychain freshness
unproven`. Run `scripts/validate-fresh-device-evidence.py` with independently
computed expected hashes; keep the strict aggregate evidence private. Checklist
prose is not release evidence.

When code changes after an approved beta build, prepare a new candidate rather than treating the old approval as validation of the new tree:

1. choose the marketing version for the intended release scope;
2. increment to a unique App Store Connect build number;
3. rerun Swift, simulator, unsigned iPhoneOS, archive, and artifact readback gates;
4. upload and verify processing against the exact source commit;
5. expect the new build to require its own external Beta App Review before external testers can use it.

## Public install guidance

Direct ordinary users to the current App Store release and the project's install
status page. Advertise a TestFlight beta only after its approval, group assignment,
and anonymous Public Link checks pass.

Use the exact iOS Companion version/build and Receiver/CLI compatibility from the
release packet, not a copied historical example. Keep self-build documented as a
separate contributor path, and do not describe source validation as distribution approval.

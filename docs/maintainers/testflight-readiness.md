# TestFlight Readiness

This maintainer checklist helps prepare an official TestFlight beta for Apple Health AI Bridge. Keep account-owned App Store Connect, signing, reviewer, support, and demo receiver material outside the public repository until it is intentionally published.

For the coordinated stable v1.0.0 launch, the exact TestFlight build must pass external Beta App Review and its Public Link must be anonymously verified before the matching repository release and install surface are announced. Self-build remains supported after launch, but it does not bypass this release-order gate for the official v1.0.0 surfaces.

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

### Demo and reviewer access

- [ ] `docs/maintainers/app-review-notes-template.example.md` is used only as a placeholder packet.
- [ ] Synthetic demo receiver material is generated privately with `dev app-review-demo`.
- [ ] The emitted legacy reviewer credential is kept reachable for the review window and its lack of automatic expiry is understood.
- [ ] The emitted `revoke_reviewer_access_command` is retained privately and run immediately after review.
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

- [ ] This is a clean uninstall/reinstall run, not an upgrade install or private-state reset.
- [ ] Bundle absence was verified before installing the sealed candidate.
- [ ] First launch showed **Not Connected** with no saved receiver, pending pairing, recovery banner, or queued upload before any setup payload was delivered.
- [ ] The exact advertised `/health` URL was reachable from the iPhone's active LAN or VPN route.
- [ ] Pairing used the setup-page QR and iPhone Camera; `devicectl --payload-url` was not used.
- [ ] The app was not relaunched between Camera handoff and pairing commit.
- [ ] Receiver baseline and final aggregate evidence show exactly one invitation redemption and one active mapped credential.
- [ ] Native Local Network and Apple Health permission prompts were exercised by a human.
- [ ] First sync used **All** history and was allowed to finish while progressing, without an outer operation timeout; **Cancel** preserved already queued uploads.
- [ ] First sync and unchanged-data idempotence produced the required sync-run/accepted-batch deltas with zero duplicate device, credential, and record identities.
- [ ] Receiver-offline **Sync Now** returned within eight seconds (five-second preflight plus at most three seconds scheduling overhead), without Health collection, enqueue, or per-lane upload attempts.
- [ ] A separate mid-transfer outage created a durable queue, preserved it across background/foreground, and same-receiver recovery drained it to zero without duplicates.
- [ ] **Check Connection** performed no durable synthetic write.
- [ ] The report labels whether Keychain freshness was proven on a never-installed/erased device or remains unproven on a container-clean device.
- [ ] If Linux is under test, receiver PID/database/request/redemption/ingest evidence remained Linux-owned; a Mac-hosted receiver was not substituted.
- [ ] `scripts/validate-fresh-device-evidence.py` returned PASS using independently computed expected source-tree, app-executable, and receiver-executable hashes; the strict private aggregate evidence file was not committed.

When code changes after an approved beta build, prepare a new candidate rather than treating the old approval as validation of the new tree:

1. keep the same marketing version while the first App Store version is still unreleased, unless release scope deliberately changes;
2. increment to a unique App Store Connect build number;
3. rerun Swift, simulator, unsigned iPhoneOS, archive, and artifact readback gates;
4. upload and verify processing against the exact source commit;
5. expect the new build to require its own external Beta App Review before external testers can use it.

## Public wording after TestFlight exists

Safe README wording after intentional publication:

> Official TestFlight beta is available as a convenience install path. The source code remains open, and self-build remains supported for developers who prefer to run their own build.

Avoid implying that TestFlight is required for the open-source code path or that a future paid/App Store build hides core source code.

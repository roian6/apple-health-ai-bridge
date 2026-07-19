# App Review Notes Template Example

Use this public example as a starting shape for TestFlight/App Store review notes. Do not commit filled reviewer credentials, support contacts, bearer tokens, pairing deep links, setup-page paths, private receiver URLs, seller information, or real HealthKit values here.

## Purpose

Apple Health AI Bridge is a local-first companion that turns Apple Health data the user permits into source-grounded context for the user's own receiver and local agent tools.

## Read-only HealthKit

- The app requests read-only access to every runtime-available implemented type in the machine-checked disclosure below.
- The same unified set drives permission, foreground-sync, observer, and background-refresh scope.
- The user still controls access to each requested type in Apple Health, and only allowed records can sync.
- HealthKit write APIs are not used.
- HealthKit data is not modified, deleted, diagnosed, or scored by the app.

## Exact supported HealthKit types

- The complete machine-checked disclosure is `docs/supported-health-data.md`.
- Paste that document's full **Requested read types** list into the private App Review Notes packet and explain that Apple Health lets the user allow or deny every requested type individually.
- Confirm the same list is present on the live Privacy Policy before submission.
- `App/PrivacyInfo.xcprivacy` declares no tracking and does not declare developer-collected data. In normal operation, Apple Health records go directly to the receiver selected by the user; neither the developer nor an integrated third-party partner can access that receiver.
- App Store Connect may remain “Data Not Collected” only while that developer-collection boundary is true. Re-answer App Privacy and update the manifest if the receiver, hosting, analytics, support, or data flow changes so the developer or an integrated third-party partner can access transmitted records beyond servicing a request in real time.

## User-owned receiver

- Data goes to the receiver URL the user pairs in the app.
- The default product posture is local/user-owned infrastructure.
- Normal v2 pairing uses a short-lived single-use invitation; the app generates the long-lived device credential locally and stores it in Keychain.
- The App Review demo helper intentionally emits a revocable legacy v1 reviewer credential because Apple's review schedule is longer than the v2 invitation lifetime. That reviewer credential does not expire automatically and must be revoked after review; regenerating the packet at the same setup-page path revokes only the credential recorded by the previous reviewer packet.

## Privacy posture

- No ads, tracking, data brokers, or hidden telemetry.
- No hidden cloud upload or automatic third-party AI upload.
- Data collection is for app functionality only.
- No clinical decision support or readiness scoring.
- Background refresh is best-effort; iOS decides when refresh windows run.

## Demo access placeholder

Prepare this material in a private release workspace, not in the public repository:

```bash
uv run health-bridge dev app-review-demo \
  --db <private-demo-db> \
  --fixture fixtures/health_bridge_batch_v1.synthetic.json \
  --receiver-url <private-demo-receiver>/v1/batches \
  --setup-page <private-demo-setup-page.html>
```

1. Start the emitted `receiver_start_command` and keep it reachable for the entire review window.
2. Open the generated setup page only on the reviewer/demo device.
3. Paste reviewer-safe instructions and the complete `healthkit_read_types_disclosure` list into App Review Notes after replacing all placeholders privately.
4. After review, run the emitted `revoke_reviewer_access_command`, delete the setup page, and disable the demo receiver.

Never paste real personal pairing links, bearer tokens, setup-page URLs, private endpoints, or HealthKit values into this template.

## Deletion and revocation

- **Disconnect from Server** removes the saved receiver URL/token and disables automatic sync.
- **Reset Private Sync State** (or its dynamic recovery/queued-upload label) deletes unsent local retry payloads and resets local cursors, upload proofs, and backfill progress so the next connected sync rebuilds receiver history.
- HealthKit permission revocation is available in the Apple Health app's app permission settings.

## Private fields to fill outside Git

- Support URL or email.
- Privacy policy URL.
- Apple Developer account / seller name.
- Demo receiver URL and setup material.

# Direct sync responsiveness tests

Run the package tests on a Mac with Xcode selected:

```sh
cd ios/HealthBridgeCompanion
swift test --filter AnchoredSleepSyncPreparationTests
```

These tests run the real sleep transition factory and batch encoder with synthetic
history. A bounded barrier verifies that MainActor can run while preparation is
blocked. They also cover cancellation and forced-baseline behavior. They do not
measure a physical iPhone's frame rate or verify the app caller by themselves.

The app regressions exercise automatic launch catch-up through the view model.
They use temporary stores, an injected synthetic HealthKit reader and a stubbed
transport. The isolated test host prevents normal app startup, observers and
background scheduling. No receiver or Health permissions are required.

Choose an available iPhone simulator with `xcrun simctl list devices available`,
then set `HEALTH_BRIDGE_TEST_SIMULATOR_ID` to its identifier. Run from the same
directory:

```sh
xcodebuild -project HealthBridgeCompanion.xcodeproj \
  -scheme HealthBridgeCompanion \
  -destination "platform=iOS Simulator,id=$HEALTH_BRIDGE_TEST_SIMULATOR_ID" \
  -derivedDataPath .build/direct-sync-app-tests \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -D HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST' \
  -only-testing:HealthBridgeCompanionAppTests/HealthBridgeCompanionResetAdmissionTests/testIssue96AutomaticSleepPreparationKeepsMainActorResponsive \
  -only-testing:HealthBridgeCompanionAppTests/HealthBridgeCompanionResetAdmissionTests/testIssue96CancellationDuringSleepPreparationCannotJournalOrAdvanceAnchor \
  -only-testing:HealthBridgeCompanionAppTests/HealthBridgeCompanionResetAdmissionTests/testIssue96ConnectionChangeDuringSleepPreparationCannotJournalOrAdvanceAnchor \
  test
```

The build condition must apply to both the app host and test target. Require
**three app tests executed, zero skipped**. Without the isolated-host condition,
these app regressions skip and do not verify responsiveness.

The tests establish preparation scheduling and preservation of delivery state.
Manifest file I/O and outbox reconciliation remain on their existing owner and
may need separate profiling. Use synthetic inputs for profiling, and do not
attach health exports, payloads, pairing material or unreviewed traces to reports.

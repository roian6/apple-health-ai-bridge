import XCTest
@testable import HealthBridgeCompanionCore

final class SleepSyncBatchFactoryTests: XCTestCase {
    func testFactoryBuildsStableSleepSessionRecordsForReceiverContract() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "C3E4C5B6-1111-2222-3333-444455556666"))
        let sleepSessions = [
            HealthKitSleepSessionSummary(
                uuid: sessionID,
                start: try date("2026-06-14T15:00:00Z"),
                end: try date("2026-06-14T22:30:00Z"),
                stageIntervals: [
                    HealthKitSleepStageSummary(
                        stage: "deep",
                        start: try date("2026-06-14T17:00:00Z"),
                        end: try date("2026-06-14T18:10:00Z")
                    ),
                    HealthKitSleepStageSummary(
                        stage: "in_bed",
                        start: try date("2026-06-14T15:00:00Z"),
                        end: try date("2026-06-14T15:20:00Z")
                    ),
                    HealthKitSleepStageSummary(
                        stage: "rem",
                        start: try date("2026-06-14T20:00:00Z"),
                        end: try date("2026-06-14T22:30:00Z")
                    ),
                ]
            )
        ]

        let batch = SleepSyncBatchFactory.makeSleepBatch(
            sleepSessions: sleepSessions,
            windowStart: try date("2026-06-14T00:00:00Z"),
            windowEnd: try date("2026-06-15T00:00:00Z"),
            generatedAt: try date("2026-06-15T00:00:01Z")
        )

        XCTAssertEqual(batch.generatedAt, "2026-06-15T00:00:01Z")
        XCTAssertEqual(batch.exportWindow.startTime, "2026-06-14T00:00:00Z")
        XCTAssertEqual(batch.exportWindow.endTime, "2026-06-15T00:00:00Z")
        XCTAssertEqual(batch.sources, [HealthBridgeAppleHealthSource.phone])
        XCTAssertEqual(batch.healthTypes, [.sleepAnalysis])
        XCTAssertTrue(batch.samples.isEmpty)
        XCTAssertTrue(batch.workouts.isEmpty)
        XCTAssertTrue(batch.deletedRecords.isEmpty)
        XCTAssertEqual(batch.sleepSessions.count, 1)
        let session = try XCTUnwrap(batch.sleepSessions.first)
        XCTAssertEqual(session.clientRecordID, "hk-sleep-20260614t150000z-20260614t223000z")
        XCTAssertEqual(session.sourceKey, "apple_health.phone")
        XCTAssertEqual(session.startTime, "2026-06-14T15:00:00Z")
        XCTAssertEqual(session.endTime, "2026-06-14T22:30:00Z")
        XCTAssertEqual(session.stageIntervals, [
            HealthBridgeSleepStageInterval(stage: "in_bed", startTime: "2026-06-14T15:00:00Z", endTime: "2026-06-14T15:20:00Z"),
            HealthBridgeSleepStageInterval(stage: "deep", startTime: "2026-06-14T17:00:00Z", endTime: "2026-06-14T18:10:00Z"),
            HealthBridgeSleepStageInterval(stage: "rem", startTime: "2026-06-14T20:00:00Z", endTime: "2026-06-14T22:30:00Z"),
        ])
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_sleep_sync",
                cursorValue: "2026-06-15T00:00:00Z"
            )
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }

    func testFactorySortsSessionsAndFiltersInvalidSessionsAndIntervals() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let invalidID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))

        let batch = SleepSyncBatchFactory.makeSleepBatch(
            sleepSessions: [
                HealthKitSleepSessionSummary(
                    uuid: secondID,
                    start: try date("2026-06-14T16:00:00Z"),
                    end: try date("2026-06-14T23:00:00Z"),
                    stageIntervals: [
                        HealthKitSleepStageSummary(stage: "awake", start: try date("2026-06-14T16:05:00Z"), end: try date("2026-06-14T16:00:00Z")),
                        HealthKitSleepStageSummary(stage: "core", start: try date("2026-06-14T16:10:00Z"), end: try date("2026-06-14T19:00:00Z")),
                    ]
                ),
                HealthKitSleepSessionSummary(
                    uuid: firstID,
                    start: try date("2026-06-13T15:00:00Z"),
                    end: try date("2026-06-13T22:00:00Z"),
                    stageIntervals: [
                        HealthKitSleepStageSummary(stage: "deep", start: try date("2026-06-13T17:00:00Z"), end: try date("2026-06-13T18:00:00Z")),
                    ]
                ),
                HealthKitSleepSessionSummary(
                    uuid: invalidID,
                    start: try date("2026-06-15T10:00:00Z"),
                    end: try date("2026-06-15T10:00:00Z"),
                    stageIntervals: [
                        HealthKitSleepStageSummary(stage: "core", start: try date("2026-06-15T10:00:00Z"), end: try date("2026-06-15T11:00:00Z")),
                    ]
                ),
            ],
            windowStart: try date("2026-06-13T00:00:00Z"),
            windowEnd: try date("2026-06-16T00:00:00Z"),
            generatedAt: try date("2026-06-16T00:00:01Z")
        )

        XCTAssertEqual(batch.sleepSessions.map(\.clientRecordID), [
            "hk-sleep-20260613t150000z-20260613t220000z",
            "hk-sleep-20260614t160000z-20260614t230000z",
        ])
        XCTAssertEqual(batch.sleepSessions[1].stageIntervals.map(\.stage), ["core"])
    }

    func testFactoryUsesReplayStableSleepSessionIdentityFromSessionWindowNotHealthKitSampleUUID() throws {
        let firstBatch = SleepSyncBatchFactory.makeSleepBatch(
            sleepSessions: [
                HealthKitSleepSessionSummary(
                    uuid: try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
                    start: try date("2026-06-14T15:00:00Z"),
                    end: try date("2026-06-14T22:30:00Z"),
                    stageIntervals: [
                        HealthKitSleepStageSummary(stage: "core", start: try date("2026-06-14T16:00:00Z"), end: try date("2026-06-14T20:00:00Z")),
                    ]
                ),
            ],
            windowStart: try date("2026-06-14T00:00:00Z"),
            windowEnd: try date("2026-06-15T00:00:00Z"),
            generatedAt: try date("2026-06-15T00:00:01Z")
        )
        let replayBatch = SleepSyncBatchFactory.makeSleepBatch(
            sleepSessions: [
                HealthKitSleepSessionSummary(
                    uuid: try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
                    start: try date("2026-06-14T15:00:00Z"),
                    end: try date("2026-06-14T22:30:00Z"),
                    stageIntervals: [
                        HealthKitSleepStageSummary(stage: "core", start: try date("2026-06-14T16:00:00Z"), end: try date("2026-06-14T20:00:00Z")),
                    ]
                ),
            ],
            windowStart: try date("2026-06-14T00:00:00Z"),
            windowEnd: try date("2026-06-15T00:00:00Z"),
            generatedAt: try date("2026-06-15T00:00:02Z")
        )

        XCTAssertEqual(
            firstBatch.sleepSessions.map(\.clientRecordID),
            ["hk-sleep-20260614t150000z-20260614t223000z"]
        )
        XCTAssertEqual(replayBatch.sleepSessions.map(\.clientRecordID), firstBatch.sleepSessions.map(\.clientRecordID))
    }

    func testForegroundUploadPolicyAllowsCursorOnlySleepBatch() throws {
        let batch = SleepSyncBatchFactory.makeSleepBatch(
            sleepSessions: [],
            windowStart: try date("2026-06-14T00:00:00Z"),
            windowEnd: try date("2026-06-15T00:00:00Z"),
            generatedAt: try date("2026-06-15T00:00:01Z")
        )

        XCTAssertTrue(batch.sleepSessions.isEmpty)
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_sleep_sync",
                cursorValue: "2026-06-15T00:00:00Z"
            )
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }
    func testAnchoredManifestEmitsAuthoritativeTombstoneWhenSessionEndShortens() throws {
        let initialChild = try sleepChild(
            uuid: "10000000-0000-0000-0000-000000000001",
            stage: "core",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let initial = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(added: [initialChild], anchor: "sleep-anchor-1", receivedAt: "2026-06-15T00:00:00Z"),
            generatedAt: try date("2026-06-15T00:00:00Z")
        ))
        let originalID = try XCTUnwrap(initial.batch.sleepSessions.first?.clientRecordID)
        let shortenedChild = try sleepChild(
            uuid: "10000000-0000-0000-0000-000000000002",
            stage: "core",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T21:45:00Z"
        )

        let corrected = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: initial.manifest,
            changes: anchoredChanges(
                added: [shortenedChild],
                deletedUUIDs: [initialChild.uuid],
                anchor: "sleep-anchor-2",
                receivedAt: "2026-06-15T01:00:00Z"
            ),
            generatedAt: try date("2026-06-15T01:00:00Z")
        ))

        XCTAssertEqual(corrected.batch.sleepSessions.count, 1)
        XCTAssertEqual(corrected.batch.sleepSessions.first?.endTime, "2026-06-14T21:45:00Z")
        XCTAssertNotEqual(corrected.batch.sleepSessions.first?.clientRecordID, originalID)
        XCTAssertEqual(corrected.batch.deletedRecords.map(\.clientRecordID), [originalID])
        XCTAssertEqual(corrected.manifest.publishedSessions, corrected.batch.sleepSessions)
    }

    func testAnchoredManifestTombstonesOldIdentityWhenSessionStartShifts() throws {
        let initialChild = try sleepChild(
            uuid: "20000000-0000-0000-0000-000000000001",
            stage: "core",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let initial = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(added: [initialChild], anchor: "sleep-anchor-1", receivedAt: "2026-06-15T00:00:00Z")
        ))
        let originalID = try XCTUnwrap(initial.batch.sleepSessions.first?.clientRecordID)
        let shiftedChild = try sleepChild(
            uuid: "20000000-0000-0000-0000-000000000002",
            stage: "core",
            start: "2026-06-14T15:20:00Z",
            end: "2026-06-14T22:30:00Z"
        )

        let corrected = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: initial.manifest,
            changes: anchoredChanges(
                added: [shiftedChild],
                deletedUUIDs: [initialChild.uuid],
                anchor: "sleep-anchor-2",
                receivedAt: "2026-06-15T01:00:00Z"
            )
        ))

        XCTAssertEqual(corrected.batch.sleepSessions.map(\.startTime), ["2026-06-14T15:20:00Z"])
        XCTAssertEqual(corrected.batch.deletedRecords.map(\.clientRecordID), [originalID])
        XCTAssertEqual(corrected.manifest.publishedSessions.count, 1)
    }

    func testAnchoredManifestEmitsFullSessionDeletionOnlyFromExplicitChildDeletions() throws {
        let child = try sleepChild(
            uuid: "30000000-0000-0000-0000-000000000001",
            stage: "deep",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let initial = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(added: [child], anchor: "sleep-anchor-1", receivedAt: "2026-06-15T00:00:00Z")
        ))
        let originalID = try XCTUnwrap(initial.batch.sleepSessions.first?.clientRecordID)

        let deleted = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: initial.manifest,
            changes: anchoredChanges(
                deletedUUIDs: [child.uuid],
                anchor: "sleep-anchor-2",
                receivedAt: "2026-06-15T01:00:00Z"
            )
        ))

        XCTAssertTrue(deleted.batch.sleepSessions.isEmpty)
        XCTAssertEqual(deleted.batch.deletedRecords.map(\.clientRecordID), [originalID])
        XCTAssertTrue(deleted.manifest.activeChildSamples.isEmpty)
        XCTAssertTrue(deleted.manifest.publishedSessions.isEmpty)
    }

    func testAnchoredManifestStageOnlyCorrectionCreatesOneReplacementRevision() throws {
        let originalChild = try sleepChild(
            uuid: "40000000-0000-0000-0000-000000000001",
            stage: "core",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let initial = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(added: [originalChild], anchor: "sleep-anchor-1", receivedAt: "2026-06-15T00:00:00Z")
        ))
        let originalID = try XCTUnwrap(initial.batch.sleepSessions.first?.clientRecordID)
        let correctedChild = try sleepChild(
            uuid: "40000000-0000-0000-0000-000000000002",
            stage: "deep",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )

        let corrected = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: initial.manifest,
            changes: anchoredChanges(
                added: [correctedChild],
                deletedUUIDs: [originalChild.uuid],
                anchor: "sleep-anchor-2",
                receivedAt: "2026-06-15T01:00:00Z"
            )
        ))

        XCTAssertEqual(corrected.batch.sleepSessions.count, 1)
        XCTAssertEqual(corrected.batch.sleepSessions.first?.stageIntervals.map(\.stage), ["deep"])
        XCTAssertEqual(corrected.batch.deletedRecords.map(\.clientRecordID), [originalID])
        XCTAssertEqual(corrected.manifest.publishedSessions.count, 1)
    }

    func testAnchoredManifestNeverReusesRetiredIdentityWhenPriorRawShapeReturns() throws {
        let partialChild = try sleepChild(
            uuid: "50000000-0000-0000-0000-000000000001",
            stage: "core",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T20:00:00Z"
        )
        let partial = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(added: [partialChild], anchor: "sleep-anchor-1", receivedAt: "2026-06-15T00:00:00Z")
        ))
        let partialID = try XCTUnwrap(partial.batch.sleepSessions.first?.clientRecordID)
        let completeChild = try sleepChild(
            uuid: "50000000-0000-0000-0000-000000000002",
            stage: "rem",
            start: "2026-06-14T20:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let complete = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: partial.manifest,
            changes: anchoredChanges(added: [completeChild], anchor: "sleep-anchor-2", receivedAt: "2026-06-15T01:00:00Z")
        ))
        let completeID = try XCTUnwrap(complete.batch.sleepSessions.first?.clientRecordID)

        let shortenedAgain = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: complete.manifest,
            changes: anchoredChanges(
                deletedUUIDs: [completeChild.uuid],
                anchor: "sleep-anchor-3",
                receivedAt: "2026-06-15T02:00:00Z"
            )
        ))
        let replacementID = try XCTUnwrap(shortenedAgain.batch.sleepSessions.first?.clientRecordID)

        XCTAssertNotEqual(completeID, partialID)
        XCTAssertNotEqual(replacementID, partialID)
        XCTAssertNotEqual(replacementID, completeID)
        XCTAssertEqual(shortenedAgain.batch.deletedRecords.map(\.clientRecordID), [completeID])
    }

    func testEmptyInitialAnchoredResultCreatesNonDestructivePendingBaseline() throws {
        let transition = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(
                anchor: "sleep-anchor-empty",
                receivedAt: "2026-06-15T00:00:00Z"
            )
        ))

        XCTAssertTrue(transition.batch.sleepSessions.isEmpty)
        XCTAssertTrue(transition.batch.deletedRecords.isEmpty)
        XCTAssertTrue(transition.manifest.baselineResetPending == true)
        XCTAssertEqual(transition.manifest.anchorCursorValue, "sleep-anchor-empty")
    }

    func testEmptyResultAfterManifestReservationKeepsFullBaselinePending() throws {
        let reservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            historyStartDate: try date("2026-05-16T00:00:00Z")
        )

        let transition = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: reservation,
            changes: anchoredChanges(
                anchor: "sleep-anchor-pending",
                receivedAt: "2026-06-15T00:00:00Z"
            )
        ))
        let retryPlan = SleepSyncBatchFactory.manifestPlan(
            transition.manifest,
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            requestedHistoryStartDate: reservation.historyStartDate
        )

        XCTAssertTrue(transition.batch.sleepSessions.isEmpty)
        XCTAssertTrue(transition.batch.deletedRecords.isEmpty)
        XCTAssertTrue(transition.manifest.baselineResetPending == true)
        XCTAssertNil(retryPlan.anchorCursorValue)
        XCTAssertTrue(retryPlan.forceRepublishAll)
        XCTAssertNil(reservation.anchorCursorValue)
    }

    func testManifestReservationKeepsInitialRevisionIdentityStableAcrossRetry() throws {
        let namespace = try XCTUnwrap(
            UUID(uuidString: "80000000-0000-0000-0000-000000000001")
        )
        let reservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            historyStartDate: try date("2026-05-16T00:00:00Z"),
            sourceKey: "apple_health.phone.installation-a",
            baselineResetEpoch: 42,
            identityNamespace: namespace
        )
        let child = try sleepChild(
            uuid: "80000000-0000-0000-0000-000000000002",
            stage: "rem",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let changes = anchoredChanges(
            added: [child],
            anchor: "sleep-anchor-reserved",
            receivedAt: "2026-06-15T00:00:00Z"
        )

        let first = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: reservation,
            changes: changes,
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            historyStartDate: reservation.historyStartDate
        ))
        let retried = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: reservation,
            changes: changes,
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            historyStartDate: reservation.historyStartDate
        ))

        XCTAssertNil(reservation.anchorCursorValue)
        XCTAssertTrue(
            first.batch.sync.cursors.contains {
                $0.cursorKind == SleepSyncBatchFactory.baselineResetCursorKind
                    && $0.cursorValue == "v2:42"
            }
        )
        XCTAssertEqual(first.batch.sources.map(\.sourceKey), ["apple_health.phone.installation-a"])
        XCTAssertEqual(
            first.batch.sleepSessions.map(\.sourceKey),
            ["apple_health.phone.installation-a"]
        )
        XCTAssertEqual(first.manifest.identityNamespace, namespace)
        XCTAssertEqual(first.manifest.baselineResetEpoch, 42)
        XCTAssertEqual(
            first.batch.sleepSessions.map(\.clientRecordID),
            retried.batch.sleepSessions.map(\.clientRecordID)
        )
    }

    func testPersistedLegacySleepStateRequiresInstallationSourceMigration() throws {
        let installationSource = "apple_health.phone.installation-a"
        let legacyBatch = SleepSyncBatchFactory.makeSleepBatch(
            sleepSessions: [
                HealthKitSleepSessionSummary(
                    uuid: try XCTUnwrap(UUID(uuidString: "81000000-0000-0000-0000-000000000001")),
                    start: try date("2026-06-14T15:00:00Z"),
                    end: try date("2026-06-14T22:30:00Z"),
                    stageIntervals: []
                )
            ],
            windowStart: try date("2026-06-14T00:00:00Z"),
            windowEnd: try date("2026-06-15T00:00:00Z")
        )
        let mixedManifest = SleepSyncManifest(
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            historyStartDate: try date("2026-05-16T00:00:00Z"),
            sourceKey: installationSource,
            baselineResetEpoch: 42,
            identityNamespace: try XCTUnwrap(
                UUID(uuidString: "81000000-0000-0000-0000-000000000002")
            ),
            nextRevisionSequence: 2,
            anchorCursorValue: "legacy-anchor",
            activeChildSamples: [],
            publishedSessions: legacyBatch.sleepSessions
        )

        XCTAssertTrue(
            SleepSyncBatchFactory.requiresInstallationSourceMigration(
                manifest: mixedManifest,
                pendingBatch: legacyBatch,
                expectedSourceKey: installationSource
            )
        )

        let reservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            historyStartDate: mixedManifest.historyStartDate,
            sourceKey: installationSource,
            baselineResetEpoch: 43
        )
        XCTAssertFalse(
            SleepSyncBatchFactory.requiresInstallationSourceMigration(
                manifest: reservation,
                pendingBatch: nil,
                expectedSourceKey: installationSource
            )
        )
    }

    func testSleepManifestScopeChangeResetsAnchorAndRepublishesBaseline() throws {
        let child = try sleepChild(
            uuid: "70000000-0000-0000-0000-000000000001",
            stage: "core",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let historyStartDate = try date("2026-05-16T00:00:00Z")
        let initial = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(
                added: [child],
                anchor: "sleep-anchor-generation-1",
                receivedAt: "2026-06-15T00:00:00Z"
            ),
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            historyStartDate: historyStartDate
        ))

        let reusable = SleepSyncBatchFactory.manifestPlan(
            initial.manifest,
            receiverSettingsGeneration: "g1",
            historyDepth: .lastDays(30),
            requestedHistoryStartDate: historyStartDate
        )
        XCTAssertEqual(reusable.previousManifest, initial.manifest)
        XCTAssertEqual(reusable.anchorCursorValue, "sleep-anchor-generation-1")
        XCTAssertFalse(reusable.forceRepublishAll)

        let reset = SleepSyncBatchFactory.manifestPlan(
            initial.manifest,
            receiverSettingsGeneration: "g2",
            historyDepth: .lastDays(90),
            requestedHistoryStartDate: try date("2026-03-17T00:00:00Z")
        )
        XCTAssertNil(reset.anchorCursorValue)
        XCTAssertTrue(reset.forceRepublishAll)
        XCTAssertTrue(reset.previousManifest?.activeChildSamples.isEmpty == true)
        XCTAssertEqual(
            reset.previousManifest?.publishedSessions,
            initial.manifest.publishedSessions
        )

        let emptyReset = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: reset.previousManifest,
            changes: anchoredChanges(
                anchor: "sleep-anchor-pending-baseline",
                receivedAt: "2026-06-15T00:30:00Z"
            ),
            receiverSettingsGeneration: "g2",
            historyDepth: .lastDays(90),
            historyStartDate: reset.historyStartDate,
            forceRepublishAll: reset.forceRepublishAll
        ))
        XCTAssertTrue(emptyReset.batch.sleepSessions.isEmpty)
        XCTAssertTrue(emptyReset.batch.deletedRecords.isEmpty)
        XCTAssertTrue(emptyReset.manifest.baselineResetPending == true)
        XCTAssertTrue(
            emptyReset.batch.sync.cursors.contains {
                $0.cursorKind == SleepSyncBatchFactory.baselineResetCursorKind
            }
        )

        let pendingPlan = SleepSyncBatchFactory.manifestPlan(
            emptyReset.manifest,
            receiverSettingsGeneration: "g2",
            historyDepth: .lastDays(90),
            requestedHistoryStartDate: reset.historyStartDate
        )
        XCTAssertNil(pendingPlan.anchorCursorValue)
        XCTAssertTrue(pendingPlan.forceRepublishAll)

        let republished = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: pendingPlan.previousManifest,
            changes: anchoredChanges(
                added: [child],
                anchor: "sleep-anchor-generation-2",
                receivedAt: "2026-06-15T01:00:00Z"
            ),
            receiverSettingsGeneration: "g2",
            historyDepth: .lastDays(90),
            historyStartDate: pendingPlan.historyStartDate,
            forceRepublishAll: pendingPlan.forceRepublishAll
        ))
        XCTAssertEqual(republished.batch.sleepSessions.count, 1)
        XCTAssertEqual(
            republished.batch.sleepSessions.first?.clientRecordID,
            initial.batch.sleepSessions.first?.clientRecordID
        )
        XCTAssertTrue(
            republished.batch.sync.cursors.contains {
                $0.cursorKind == SleepSyncBatchFactory.baselineResetCursorKind
            }
        )
    }

    func testFileSleepManifestStoreRoundTripsDurablePrivateState() throws {
        let child = try sleepChild(
            uuid: "60000000-0000-0000-0000-000000000001",
            stage: "rem",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let transition = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(added: [child], anchor: "sleep-anchor-1", receivedAt: "2026-06-15T00:00:00Z"),
            receiverSettingsGeneration: "g-test"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("sleep-manifest.json")
        let store = try FileSleepSyncManifestStore(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(try store.loadManifest())
        XCTAssertNil(try store.loadPendingTransition())
        try store.saveManifest(transition.manifest)

        XCTAssertEqual(try store.loadManifest(), transition.manifest)
        let pending = SleepSyncPendingTransition(
            payload: Data("synthetic-sleep-payload".utf8),
            manifest: transition.manifest,
            receiverBindingID: "11111111-1111-1111-1111-111111111111",
            connectionGeneration: "g-test"
        )
        try store.savePendingTransition(pending)
        XCTAssertEqual(try store.loadPendingTransition(), pending)
        let tracked = pending.assigningOutboxItemID("00000000000000000001-payload.json")
        try store.savePendingTransition(tracked)
        XCTAssertEqual(try store.loadPendingTransition(), tracked)
        let rejected = tracked.markingRejected(minimumResetEpoch: 57)
        try store.savePendingTransition(rejected)
        let loadedRejected = try XCTUnwrap(store.loadPendingTransition())
        XCTAssertEqual(loadedRejected.rejectedMinimumResetEpoch, 57)
        XCTAssertEqual(loadedRejected.outboxItemID, tracked.outboxItemID)
        XCTAssertThrowsError(try store.clearPendingTransition(id: "different-transition"))
        try store.clearPendingTransition(id: rejected.id)
        XCTAssertNil(try store.loadPendingTransition())

        try store.savePendingTransition(tracked)
        try store.resetSynchronizationState()
        XCTAssertNil(try store.loadPendingTransition())
        XCTAssertNil(try store.loadManifest())
        try store.saveManifest(transition.manifest)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testSleepConflictRecoveryDurablyReservesFloorBeforeRetiringFIFOItem() throws {
        let child = try sleepChild(
            uuid: "60000000-0000-0000-0000-000000000002",
            stage: "rem",
            start: "2026-06-14T15:00:00Z",
            end: "2026-06-14T22:30:00Z"
        )
        let transition = try XCTUnwrap(makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: anchoredChanges(
                added: [child],
                anchor: "sleep-anchor-conflict",
                receivedAt: "2026-06-15T00:00:00Z"
            ),
            receiverSettingsGeneration: "g-conflict"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory.appendingPathComponent("outbox"))
        let store = try FileSleepSyncManifestStore(
            fileURL: directory.appendingPathComponent("sleep-manifest.json")
        )
        let payload = try JSONEncoder().encode(transition.batch)
        let receiverBindingID = "11111111-1111-1111-1111-111111111111"
        let item = try outbox.enqueue(payload, receiverIdentity: receiverBindingID)
        let pending = SleepSyncPendingTransition(
            payload: payload,
            manifest: transition.manifest,
            receiverBindingID: receiverBindingID,
            connectionGeneration: "g-conflict",
            outboxItemID: item.id
        )
        try store.saveManifest(transition.manifest)
        try store.savePendingTransition(pending)
        let tokenStore = SleepRecoveryTokenStore()
        let epochStore = SleepResetEpochStore(
            tokenStore: tokenStore,
            epochFloorProvider: { 1 }
        )

        try SleepBaselineRejectionRecovery.recover(
            itemID: item.id,
            minimumResetEpoch: 200,
            outbox: outbox,
            manifestStore: store,
            epochStore: epochStore
        )

        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertNil(try store.loadManifest())
        XCTAssertNil(try store.loadPendingTransition())
        XCTAssertGreaterThan(UInt64(tokenStore.token) ?? 0, 200)
    }
}

private final class SleepRecoveryTokenStore: ReceiverTokenStoring {
    var token = ""

    func loadToken() throws -> String { token }

    func saveToken(_ token: String) throws {
        self.token = token
    }
}

private func makeAnchoredSleepTransition(
    previousManifest: SleepSyncManifest?,
    changes: HealthKitAnchoredSleepChanges,
    generatedAt: Date = Date(),
    receiverSettingsGeneration: String = "g-test",
    historyDepth: HealthHistoryDepth = .allAvailable,
    historyStartDate: Date? = nil,
    forceRepublishAll: Bool = false,
    newManifestNamespace: UUID = UUID()
) -> AnchoredSleepSyncTransition? {
    SleepSyncBatchFactory.makeAnchoredSleepTransition(
        previousManifest: previousManifest,
        changes: changes,
        receiverSettingsGeneration: receiverSettingsGeneration,
        historyDepth: historyDepth,
        historyStartDate: historyStartDate,
        forceRepublishAll: forceRepublishAll,
        generatedAt: generatedAt,
        newManifestNamespace: newManifestNamespace
    )
}

private func anchoredChanges(
    added: [HealthKitSleepChildSample] = [],
    deletedUUIDs: [UUID] = [],
    anchor: String,
    receivedAt: String
) -> HealthKitAnchoredSleepChanges {
    let receivedDate = ISO8601DateFormatter().date(from: receivedAt)!
    return HealthKitAnchoredSleepChanges(
        addedSamples: added,
        deletedSamples: deletedUUIDs.map {
            HealthKitDeletedSleepSample(uuid: $0, deletedAt: receivedDate)
        },
        anchorCursorValue: anchor,
        receivedAt: receivedDate
    )
}

private func sleepChild(
    uuid: String,
    stage: String,
    start: String,
    end: String
) throws -> HealthKitSleepChildSample {
    HealthKitSleepChildSample(
        uuid: try XCTUnwrap(UUID(uuidString: uuid)),
        stage: stage,
        start: try date(start),
        end: try date(end)
    )
}

private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return try XCTUnwrap(formatter.date(from: string))
}

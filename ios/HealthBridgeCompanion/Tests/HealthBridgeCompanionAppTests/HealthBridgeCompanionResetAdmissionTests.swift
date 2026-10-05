import Combine
import CryptoKit
import Foundation
import HealthKit
import UIKit
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class HealthBridgeCompanionResetAdmissionTests: XCTestCase {
    func testAutomaticStepsCharacterizationDeliversRawThenUnchangedAnchorSendsNothing() async throws {
        try await exerciseAutomaticStepsUnchangedAnchor(expectMergedDaily: false)
    }

    func testAutomaticStepsRegressionUnchangedRawAnchorDeliversMergedCompletedDay() async throws {
        try await exerciseAutomaticStepsUnchangedAnchor(expectMergedDaily: true)
    }

    func testAutomaticStepsDailyReadFailureKeepsGenerationAcrossRelaunch() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.failStepsDailyRead = true
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])

        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(fixture.dailyRequests.contains(["steps"]))
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)
        XCTAssertEqual(try fixture.pending(), original, "A raw ACK cannot cover the failed daily query.")
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.failStepsDailyRead = false
        runtime = try await makeStepsFaultRuntime(fixture)
        XCTAssertEqual(try fixture.pending(), original, "The original generation must survive reconstruction.")
        let rawReadsBeforeRetry = fixture.rawAnchors.count
        await runtime?.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: try fixture.pending().keys.sorted())
        )

        XCTAssertEqual(fixture.rawAnchors.count, rawReadsBeforeRetry + 1)
        XCTAssertEqual(fixture.rawAnchors.last, fixture.currentAnchor)
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsRawReadFailureRetriesBothRepresentations() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.failRawRead = true
        let runtime = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(fixture.rawAnchors, [fixture.previousAnchor])
        XCTAssertTrue(try fixture.acceptedSamples(kind: "raw_quantity").isEmpty)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        XCTAssertEqual(try fixture.pending(), original, "Daily availability cannot discharge a failed raw read.")

        fixture.failRawRead = false
        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: try fixture.pending().keys.sorted())
        )

        XCTAssertEqual(fixture.rawAnchors, [fixture.previousAnchor, fixture.previousAnchor])
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsDailyReadFailureDoesNotBlockOtherSelectedDailyType() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        let otherType = "basal_energy"
        XCTAssertTrue(HealthBridgeBackgroundSync.dailyActivityTypeCodes.contains(otherType))
        let entry = try XCTUnwrap(HealthKitTypeCatalog.entry(for: otherType))
        XCTAssertEqual(entry.objectKind, .quantity)
        XCTAssertEqual(entry.aggregation, .sum)
        XCTAssertEqual(entry.canonicalUnit, "kcal")
        fixture.failStepsDailyRead = true
        let runtime = try await makeStepsFaultRuntime(fixture)
        XCTAssertTrue(runtime.viewModel.automaticSyncSelectedEligibleTypeCodes().contains(otherType))
        let selected = [otherType, "steps"]
        let original = try fixture.admit(selected)

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: selected))

        XCTAssertTrue(fixture.dailyRequests.contains(["steps"]))
        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        let otherSamples = try fixture.acceptedSamples(kind: "daily_aggregate").filter { $0.typeCode == otherType }
        XCTAssertEqual(otherSamples.map(\.value), [345])
        XCTAssertEqual(otherSamples.first?.unit, "kcal")
        let retained = try fixture.pending()
        XCTAssertEqual(retained, original.filter { $0.key == "steps" })
        XCTAssertNil(retained[otherType])

        fixture.failStepsDailyRead = false
        let dailyReadsBeforeRetry = fixture.dailyRequests.count
        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: retained.keys.sorted())
        )

        XCTAssertEqual(Array(fixture.dailyRequests.dropFirst(dailyReadsBeforeRetry)), [["steps"]])
        XCTAssertEqual(try fixture.acceptedSamples(kind: "daily_aggregate").filter {
            $0.typeCode == otherType
        }.count, 1, "Retry must not broaden the retained Steps selection.")
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsRawTransportFailureKeepsGenerationAcrossRelaunch() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.setFailedStepsSampleKinds(["raw_quantity"])
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])
        let schedulesBeforeFailure = fixture.declinedBackgroundSchedules

        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertTrue(try fixture.acceptedSamples(kind: "raw_quantity").isEmpty)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        XCTAssertEqual(try fixture.pending(), original)
        XCTAssertFalse(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty)
        XCTAssertGreaterThan(fixture.declinedBackgroundSchedules, schedulesBeforeFailure)
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.recorder.setFailedStepsSampleKinds([])
        fixture.failStepsDailyRead = true
        runtime = try await makeStepsFaultRuntime(fixture)
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(fixture.dailyRequests.contains(["steps"]))
        XCTAssertEqual(try fixture.pending(), original, "Restored raw ACK must not cover an uncollected daily representation.")
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)

        fixture.failStepsDailyRead = false
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsDailyTransportFailureDoesNotRetireNewerGeneration() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.setFailedStepsSampleKinds(["daily_aggregate"])
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])
        let schedulesBeforeFailure = fixture.declinedBackgroundSchedules

        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)
        XCTAssertEqual(try fixture.pending(), original, "Queued daily data is not accepted coverage.")
        XCTAssertFalse(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty)
        XCTAssertGreaterThan(fixture.declinedBackgroundSchedules, schedulesBeforeFailure)
        let newer = try fixture.admit(["steps"])
        XCTAssertNotEqual(newer["steps"], original["steps"])
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.recorder.setFailedStepsSampleKinds([])
        fixture.failRawRead = true
        runtime = try await makeStepsFaultRuntime(fixture)
        let rawReadsBeforeRetry = fixture.rawAnchors.count
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "daily_aggregate").filter { $0.typeCode == "steps" }.count, 1)
        XCTAssertEqual(fixture.rawAnchors.count, rawReadsBeforeRetry + 1)
        XCTAssertEqual(try fixture.pending(), newer, "Older daily ACK must not retire the newer failed raw generation.")

        fixture.failRawRead = false
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsLegacyRawRetirementKeepsDailyObligationAcrossRelaunch() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.setFailedStepsSampleKinds(["raw_quantity"])
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])

        // The old dispatcher invoked this unchanged public worker with its Steps marker.
        // Persist through the real enqueue path; do not edit queue/cursor state afterward.
        let queuedRaw = await runtime?.automaticSyncRuntime.viewModel.syncRecentStepCounts(
            executionMode: .automatic,
            pendingGenerationRetirements: original
        )
        XCTAssertEqual(queuedRaw, true)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        let legacyOutbox = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox"))
        XCTAssertFalse(try legacyOutbox.pendingItems().isEmpty)
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            contentsOf: legacyOutbox.directoryURL.appendingPathComponent(".enqueue-transaction")
        )) as? [String: Any])
        XCTAssertEqual(journal["version"] as? Int, 2)
        let transactions = try XCTUnwrap(journal["transactions"] as? [[String: Any]])
        XCTAssertEqual(transactions.count, 1)
        let transaction = try XCTUnwrap(transactions.first)
        XCTAssertEqual(transaction["pendingGenerationRetirements"] as? [String: Int], original)
        XCTAssertNil(transaction["stepsRawAndDailyCoverage"])
        let checkpoint = try XCTUnwrap(transaction["cursorCheckpoint"] as? [String: Any])
        XCTAssertEqual(checkpoint["cursorKind"] as? String, StepCountSyncBatchFactory.anchoredCursorKind)
        XCTAssertTrue(fixture.dailyRequests.isEmpty)
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.recorder.setFailedStepsSampleKinds([])
        fixture.failStepsDailyRead = true
        runtime = try await makeStepsFaultRuntime(fixture)
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(fixture.dailyRequests.contains(["steps"]), "An inherited raw retirement marker cannot stand for daily collection.")
        XCTAssertEqual(try fixture.pending(), original, "Legacy raw ACK must retain its unfulfilled daily Steps obligation.")
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)

        fixture.failStepsDailyRead = false
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        try assertStepsFaultCompletion(fixture)
    }

    private func makeStepsFaultRuntime(
        _ fixture: AutomaticStepsFaultFixture
    ) async throws -> HealthBridgeCompanionApplicationRuntime {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        fixture.sessions.append(session)
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let viewModel = try makeViewModel(
            root: fixture.root,
            defaults: defaults,
            settingsStore: fixture.makeSettingsStore(defaults: defaults),
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: fixture.pairingPendingStore,
                installationIDStore: fixture.installationStore,
                cancellationStore: fixture.pairingCancellationStore,
                installationIDGenerator: { "synthetic-steps-fault-installation" }
            ),
            outbox: try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")),
            receiverClient: ReceiverClient(session: session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                fileURL: fixture.root.appendingPathComponent("diagnostics.json")
            ),
            readAnchoredStepChanges: { anchor, start, receivedAt in
                try fixture.readRaw(anchor: anchor, start: start, receivedAt: receivedAt)
            },
            readDailyActivityAggregates: { types, start, end, calendar in
                try fixture.readDaily(types: types, start: start, end: end, calendar: calendar)
            },
            scheduleDirectBackgroundUploads: {
                fixture.declineBackgroundScheduling()
            }
        )
        await viewModel.bootstrap()
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
    }

    private func assertStepsFaultCompletion(_ fixture: AutomaticStepsFaultFixture) throws {
        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        let daily = try fixture.acceptedSamples(kind: "daily_aggregate").filter { $0.typeCode == "steps" }
        XCTAssertFalse(daily.isEmpty, "Completion requires an accepted merged daily Steps payload.")
        let expected = try XCTUnwrap(fixture.completedStepsDay)
        for sample in daily {
            XCTAssertEqual(sample.value, 4_321)
            XCTAssertEqual(sample.unit, "count")
            XCTAssertEqual(sample.startTime, HealthBridgeUTCFormatter.string(from: expected.dayStart))
            XCTAssertEqual(sample.endTime, HealthBridgeUTCFormatter.string(from: expected.dayEnd))
            XCTAssertEqual(sample.metadata["aggregation"], "daily_sum")
            XCTAssertEqual(sample.metadata["aggregation_completeness"], "complete")
            XCTAssertEqual(sample.metadata["source_resolution"], "healthkit_statistics_merged_sources")
            XCTAssertEqual(sample.metadata["calendar_day"], expected.calendarDay)
            XCTAssertEqual(sample.metadata["time_zone_identifier"], expected.timeZoneIdentifier)
            let day = try XCTUnwrap(expected.calendarDay).replacingOccurrences(of: "-", with: "")
            XCTAssertEqual(sample.clientRecordID, "hk-daily-activity-steps-\(day)")
        }
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(try fixture.pending().isEmpty)
        XCTAssertTrue(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty)
    }

    private func exerciseAutomaticStepsUnchangedAnchor(expectMergedDaily: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticStepsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AutomaticStepsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-steps-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let backgroundSyncStore = BackgroundSyncSettingsStore(userDefaults: defaults)
        try backgroundSyncStore.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let previousAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 41))
        let currentAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 42))
        let cursorStore = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        try cursorStore.saveCursorValue(
            previousAnchor,
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        )
        CoreLaneUploadProofStore(userDefaults: defaults).markUploadedRecords(
            lane: .steps, receiverBindingID: receiverBindingID
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let recorder = PayloadFenceNetworkRecorder()
        PayloadFenceURLProtocol.networkRecorder = recorder
        defer { PayloadFenceURLProtocol.networkRecorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var rawReadCount = 0
        var dailyReadCount = 0
        var unchangedRun = false
        var expectedCompletedDay: HealthKitDailyActivityAggregate?
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { "synthetic-steps-installation" }
            ),
            outbox: outbox,
            receiverClient: ReceiverClient(session: session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                fileURL: root.appendingPathComponent("diagnostics.json")
            ),
            readAnchoredStepChanges: { anchor, predicateStart, receivedAt in
                rawReadCount += 1
                XCTAssertEqual(anchor, unchangedRun ? currentAnchor : previousAnchor)
                XCTAssertNil(predicateStart)
                let start = receivedAt.addingTimeInterval(-120)
                return HealthKitAnchoredStepChanges(
                    stepSamples: unchangedRun ? [] : [HealthKitStepSampleSummary(
                        uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000058")),
                        start: start,
                        end: receivedAt.addingTimeInterval(-60),
                        count: 17
                    )],
                    deletedStepSamples: [],
                    anchorCursorValue: currentAnchor,
                    windowStart: start,
                    windowEnd: receivedAt
                )
            },
            readDailyActivityAggregates: { typeCodes, start, end, calendar in
                dailyReadCount += 1
                XCTAssertEqual(typeCodes, ["steps"])
                XCTAssertEqual(calendar.timeZone, Calendar.current.timeZone)
                guard unchangedRun, expectMergedDaily else { return [] }
                let today = calendar.startOfDay(for: end)
                let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
                let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
                XCTAssertLessThanOrEqual(start, yesterday)
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "yyyy-MM-dd"
                let completedDay = HealthKitDailyActivityAggregate(
                    typeCode: "steps", dayStart: yesterday, dayEnd: today, value: 4_321,
                    calendarDay: formatter.string(from: yesterday),
                    timeZoneIdentifier: calendar.timeZone.identifier
                )
                expectedCompletedDay = completedDay
                return [completedDay, HealthKitDailyActivityAggregate(
                    typeCode: "steps", dayStart: today, dayEnd: tomorrow, value: 99,
                    isComplete: false,
                    calendarDay: formatter.string(from: today),
                    timeZoneIdentifier: calendar.timeZone.identifier
                )]
            }
        )
        await viewModel.bootstrap()
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
        XCTAssertTrue(viewModel.automaticSyncSelectedEligibleTypeCodes().contains("steps"))
        try backgroundSyncStore.markPendingObserverTypeCodes(["steps"])
        XCTAssertNotNil(try backgroundSyncStore.loadPendingObserverTypeCodeGenerations()["steps"])
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        let firstBatches = try recorder.payloads.map { try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0) }
        XCTAssertEqual(firstBatches.count, 1)
        let rawBatch = try XCTUnwrap(firstBatches.first)
        XCTAssertEqual(rawBatch.samples.count, 1)
        let rawSample = try XCTUnwrap(rawBatch.samples.first)
        XCTAssertEqual(rawSample.typeCode, "steps")
        XCTAssertEqual(rawSample.value, 17)
        XCTAssertEqual(rawSample.metadata["sample_kind"], "raw_quantity")
        XCTAssertEqual(rawBatch.sync.cursors.first?.cursorKind, StepCountSyncBatchFactory.anchoredCursorKind)
        XCTAssertEqual(try cursorStore.cursorValue(
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), currentAnchor)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertTrue(try backgroundSyncStore.loadPendingObserverTypeCodeGenerations().isEmpty)

        unchangedRun = true
        let dailyReadsBefore = dailyReadCount
        try backgroundSyncStore.markPendingObserverTypeCodes(["steps"])
        XCTAssertNotNil(try backgroundSyncStore.loadPendingObserverTypeCodeGenerations()["steps"])
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(rawReadCount, 2)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertTrue(try backgroundSyncStore.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertEqual(try cursorStore.cursorValue(
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), currentAnchor)
        let laterBatches = try recorder.payloads.dropFirst(firstBatches.count).map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
        }
        if expectMergedDaily {
            XCTAssertGreaterThan(dailyReadCount, dailyReadsBefore, "An unchanged raw anchor still requires merged daily statistics.")
            XCTAssertEqual(laterBatches.count, 1, "The Steps generation must not retire without delivering its completed-day total.")
            let dailyBatch = try XCTUnwrap(laterBatches.first, "Missing accepted daily Steps payload after the unchanged raw read.")
            let completedDay = try XCTUnwrap(expectedCompletedDay)
            XCTAssertEqual(dailyBatch.samples.count, 1, "Today must not be emitted as a complete day.")
            let sample = try XCTUnwrap(dailyBatch.samples.first)
            XCTAssertEqual(sample.typeCode, "steps")
            XCTAssertEqual(sample.unit, "count")
            XCTAssertEqual(sample.value, 4_321)
            XCTAssertNotEqual(sample.value, rawSample.value)
            XCTAssertEqual(sample.startTime, HealthBridgeUTCFormatter.string(from: completedDay.dayStart))
            XCTAssertEqual(sample.endTime, HealthBridgeUTCFormatter.string(from: completedDay.dayEnd))
            XCTAssertEqual(sample.metadata["sample_kind"], "daily_aggregate")
            XCTAssertEqual(sample.metadata["aggregation"], "daily_sum")
            XCTAssertEqual(sample.metadata["aggregation_completeness"], "complete")
            XCTAssertEqual(sample.metadata["source_resolution"], "healthkit_statistics_merged_sources")
            XCTAssertEqual(sample.metadata["calendar_day"], completedDay.calendarDay)
            XCTAssertEqual(sample.metadata["time_zone_identifier"], completedDay.timeZoneIdentifier)
            XCTAssertEqual(sample.clientRecordID, "hk-daily-activity-steps-\(try XCTUnwrap(completedDay.calendarDay).replacingOccurrences(of: "-", with: ""))")
            XCTAssertEqual(dailyBatch.sync.cursors.first?.cursorKind, DailyActivityAggregateSyncPolicy.cursorKind)
        } else {
            XCTAssertEqual(dailyReadCount, 2, "Each Steps opportunity must successfully read its empty daily representation before completion.")
            XCTAssertTrue(laterBatches.isEmpty, "Unchanged raw Steps with no daily totals must not send a payload.")
        }
    }

    func testDidFinishLaunchingPreparesHealthKitObserversBeforeAsyncBootstrap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdLaunchObserverPreparationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ColdLaunchObserverPreparationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        let bootstrapEntered = expectation(description: "async bootstrap entered")
        let blocker = BlockingBootstrapCleanup(
            onStart: { bootstrapEntered.fulfill() },
            onCancel: {}
        )
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox")),
            cancelInheritedLegacyUploads: { await blocker.wait() }
        )
        var observerPreparationCompleted = false
        let runtime = HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel,
            backgroundLaunchPreparation: {
                observerPreparationCompleted = true
            }
        )
        XCTAssertTrue(runtime.automaticSyncRuntime.viewModel === viewModel)
        let delegate = HealthBridgeBackgroundURLSessionAppDelegate(
            applicationRuntime: runtime
        )

        let didFinish = delegate.application(
            UIApplication.shared,
            didFinishLaunchingWithOptions: nil
        )

        XCTAssertTrue(didFinish)
        XCTAssertTrue(observerPreparationCompleted)
        let entry = await XCTWaiter.fulfillment(of: [bootstrapEntered], timeout: 2)
        XCTAssertEqual(entry, .completed)
        guard entry == .completed else {
            blocker.release()
            return
        }
        let joinedBootstrap = Task { @MainActor in
            await runtime.bootstrap()
        }
        blocker.release()
        await joinedBootstrap.value
    }

    func testApplicationRuntimeCoalescesBackgroundAndVisibleBootstrapOnOneViewModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationRuntimeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ApplicationRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        let entered = expectation(description: "application-owned bootstrap entered")
        let recorder = BootstrapInvocationRecorder()
        let blocker = BlockingBootstrapCleanup(
            onStart: {
                recorder.recordInvocation()
                entered.fulfill()
            },
            onCancel: {}
        )
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox")),
            cancelInheritedLegacyUploads: { await blocker.wait() }
        )
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
        let delegate = HealthBridgeBackgroundURLSessionAppDelegate(
            applicationRuntime: runtime
        )

        let backgroundLaunch = Task { @MainActor in
            await runtime.bootstrap()
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(entry, .completed)
        guard entry == .completed else {
            backgroundLaunch.cancel()
            return
        }
        let visibleLaunch = Task { @MainActor in
            await runtime.bootstrap()
        }
        await Task.yield()
        blocker.release()
        await backgroundLaunch.value
        await visibleLaunch.value

        XCTAssertTrue(runtime.viewModel === viewModel)
        XCTAssertTrue(delegate.applicationRuntime === runtime)
        XCTAssertEqual(recorder.invocationCount, 1)
    }

    func testAutomaticSyncOwnerPublishesOneCoarseSyncingState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticSyncOwnerUIStateTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AutomaticSyncOwnerUIStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox"))
        )
        var observedStates: [Bool] = []
        let observation = viewModel.$automaticSyncOwnerIsActive.sink {
            observedStates.append($0)
        }

        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        withExtendedLifetime(observation) {}

        XCTAssertEqual(observedStates, [false, true, false])
        XCTAssertFalse(viewModel.syncPresentationIsActive)

        let uploader = BackgroundURLSessionOutboxUploader.shared
        uploader.setAutomaticContinuationAdmissionOpen(true)
        defer { uploader.setAutomaticContinuationAdmissionOpen(false) }
        runtime.automaticSyncRuntime.stopAdmission()
        XCTAssertFalse(uploader.automaticContinuationAdmissionIsOpen)
    }

    func testStaleSleepRecoveryDoesNotBlockLaterStepsQuery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticSleepBootstrapFIFOTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AutomaticSleepBootstrapFIFOTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-sleep-fifo-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let currentGeneration = settingsStore.receiverSettingsGenerationToken
        let staleGeneration = "g0"
        XCTAssertNotEqual(currentGeneration, staleGeneration)

        let backgroundSyncStore = BackgroundSyncSettingsStore(userDefaults: defaults)
        try backgroundSyncStore.setEnabledDurably(true)
        try backgroundSyncStore.markPendingObserverTypeCodes(["sleep_analysis", "steps"])
        XCTAssertEqual(backgroundSyncStore.pendingObserverTypeCodes, ["sleep_analysis", "steps"])
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )

        let installationID = "synthetic-sleep-fifo-installation"
        let sleepSourceKey = "apple_health.phone.\(installationID)"
        let sleepStore = try FileSleepSyncManifestStore(
            fileURL: root.appendingPathComponent("sleep.json")
        )
        let staleReservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: staleGeneration,
            historyDepth: .allAvailable,
            historyStartDate: nil,
            sourceKey: sleepSourceKey,
            baselineResetEpoch: 1,
            identityNamespace: try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")
            )
        )
        let staleTransition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: staleReservation,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [],
                deletedSamples: [],
                anchorCursorValue: "synthetic-stale-sleep-anchor",
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            receiverSettingsGeneration: staleGeneration,
            historyDepth: .allAvailable,
            historyStartDate: nil,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try sleepStore.saveManifest(staleTransition.manifest)
        try sleepStore.savePendingTransition(SleepSyncPendingTransition(
            payload: try HealthBridgeBatchEncoder().encode(staleTransition.batch),
            manifest: staleTransition.manifest,
            receiverBindingID: receiverBindingID,
            connectionGeneration: staleGeneration,
            outboxItemID: "missing-synthetic-sleep-payload.json"
        ))

        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        let cursorStore = try FileSyncCursorStore(
            fileURL: root.appendingPathComponent("cursors.json")
        )
        try cursorStore.saveCursorValue(
            "synthetic-malformed-steps-anchor",
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        )
        CoreLaneUploadProofStore(userDefaults: defaults).markUploadedRecords(
            lane: .steps,
            receiverBindingID: receiverBindingID
        )
        let networkRecorder = PayloadFenceNetworkRecorder()
        PayloadFenceURLProtocol.networkRecorder = networkRecorder
        defer { PayloadFenceURLProtocol.networkRecorder = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PayloadFenceURLProtocol.self]
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { installationID }
            ),
            outbox: outbox,
            receiverClient: ReceiverClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            readAnchoredSleepChanges: { _, _, receivedAt in
                HealthKitAnchoredSleepChanges(
                    addedSamples: [],
                    deletedSamples: [],
                    anchorCursorValue: "synthetic-bootstrap-sleep-anchor",
                    receivedAt: receivedAt
                )
            }
        )
        await viewModel.bootstrap()
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)

        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: ["sleep_analysis", "steps"])
        )

        let replacementManifest = try XCTUnwrap(sleepStore.loadManifest())
        XCTAssertEqual(replacementManifest.receiverSettingsGeneration, currentGeneration)
        XCTAssertNil(
            replacementManifest.anchorCursorValue,
            "An empty initial Sleep read must not advance the durable anchor before acceptance is finalized."
        )
        let acknowledgedTransition = try XCTUnwrap(sleepStore.loadPendingTransition())
        XCTAssertEqual(acknowledgedTransition.connectionGeneration, currentGeneration)
        XCTAssertEqual(
            acknowledgedTransition.manifest.anchorCursorValue,
            "synthetic-bootstrap-sleep-anchor"
        )
        let acknowledgedOutboxItemID = try XCTUnwrap(acknowledgedTransition.outboxItemID)
        XCTAssertNil(try outbox.pendingItem(id: acknowledgedOutboxItemID))
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertGreaterThan(networkRecorder.invocationCount, 0)

        try backgroundSyncStore.markPendingObserverTypeCodes(["sleep_analysis", "steps"])
        var processedTypeCodes: [String] = []
        let engine = AutomaticSyncEngine(
            pendingStore: backgroundSyncStore,
            processType: { typeCode, pendingGenerations in
                processedTypeCodes.append(typeCode)
                return await viewModel.processAutomaticSyncType(
                    typeCode,
                    pendingGenerations: pendingGenerations
                )
            }
        )
        try await engine.requestRun(
            reason: .observerBatch(typeCodes: ["sleep_analysis", "steps"])
        )

        let committedManifest = try XCTUnwrap(sleepStore.loadManifest())
        XCTAssertEqual(committedManifest.receiverSettingsGeneration, currentGeneration)
        XCTAssertEqual(
            committedManifest.anchorCursorValue,
            "synthetic-bootstrap-sleep-anchor"
        )
        let currentTransition = try XCTUnwrap(sleepStore.loadPendingTransition())
        XCTAssertEqual(currentTransition.connectionGeneration, currentGeneration)
        XCTAssertEqual(
            currentTransition.manifest.receiverSettingsGeneration,
            currentGeneration
        )
        let currentOutboxItemID = try XCTUnwrap(currentTransition.outboxItemID)
        XCTAssertNotNil(try outbox.pendingItem(id: currentOutboxItemID))
        XCTAssertEqual(processedTypeCodes, ["sleep_analysis", "steps"])
        XCTAssertTrue(
            viewModel.statusMessage.hasPrefix(
                "Step sync failed: HealthKit anchor cursor was not valid base64."
            ),
            "The later Steps lane must reach its real query path while automatic Sleep finalizes receiver acceptance."
        )
    }

    func testAutomaticSyncDiagnosticStorePersistsCancellationInIOSContainers() throws {
        let manager = FileManager.default
        let applicationSupport = try XCTUnwrap(
            manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        for (label, base) in [
            ("temporary", manager.temporaryDirectory),
            ("application-support", applicationSupport),
        ] {
            let root = base
                .appendingPathComponent("HealthBridgeCompanionAppTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? manager.removeItem(at: root) }
            let store = AutomaticSyncDiagnosticStore(
                fileURL: root.appendingPathComponent("diagnostics.json")
            )
            let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
            draft.noteFailure(.classified(stage: .unknown, isCancellation: true))
            draft.noteCompletion(.interrupted)

            XCTAssertTrue(store.recordFinal(draft.record), label)
            XCTAssertEqual(store.latestRecord?.failure?.category, .cancellation, label)
        }
    }

    func testCancelledBackgroundHandlerFinalizesWithoutBootstrapOrMutatingFIFOAndCursors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "BackgroundHandlerCancellation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true }
        )
        try settings.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-cancellation-credential", rotateBindingID: true
        )
        let binding = try XCTUnwrap(settings.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 3, in: outbox, receiverBindingID: binding)
        let before = try outbox.pendingItems()
        let payloads = try before.map { try Data(contentsOf: $0.fileURL) }
        let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        try cursors.saveCursorValue("synthetic-progress", receiverBindingID: binding, sourceKey: "steps", cursorKind: "anchor")
        let background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.markPendingObserverTypeCodes(["sleep_analysis", "steps"])
        let generations = try background.loadPendingObserverTypeCodeGenerations()
        let diagnostics = AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json"))
        let viewModel = try makeViewModel(
            root: root, defaults: defaults, settingsStore: settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: outbox,
            automaticSyncDiagnosticStore: diagnostics,
            cancelInheritedLegacyUploads: {
                XCTFail("An already expired handler must not start bootstrap payload cleanup")
                return BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
            }
        )
        let entered = expectation(description: "before real background handler")
        let returned = expectation(description: "real handler returned after cancellation finalization")
        var resume: CheckedContinuation<Void, Never>?
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
        let task = Task { @MainActor in
            await withCheckedContinuation { resume = $0; entered.fulfill() }
            await runtime.handleBackgroundRefresh()
            XCTAssertEqual(background.lastRun?.outcome, .interrupted)
            XCTAssertEqual(diagnostics.latestRecord?.failure?.category, .cancellation)
            returned.fulfill()
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(entry, .completed)
        guard entry == .completed else { task.cancel(); return }
        task.cancel()
        resume?.resume()
        let exit = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(exit, .completed)
        guard exit == .completed else { return }
        await task.value
        XCTAssertEqual(try outbox.pendingItems(), before)
        XCTAssertEqual(try before.map { try Data(contentsOf: $0.fileURL) }, payloads)
        XCTAssertEqual(try cursors.cursorValue(receiverBindingID: binding, sourceKey: "steps", cursorKind: "anchor"), "synthetic-progress")
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), generations)
        XCTAssertNil(background.lastTaskSchedule, "Disabled automatic sync must not submit a request")
    }

    func testBlockedAutomaticOpportunityCannotRecordCompletedSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockedAutomaticOpportunityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "BlockedAutomaticOpportunityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settings.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-blocked-opportunity-credential",
            rotateBindingID: true
        )
        let background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        try background.markPendingObserverTypeCodes(["steps"])
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let diagnostics = AutomaticSyncDiagnosticStore(
            fileURL: root.appendingPathComponent("diagnostics.json")
        )
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox")),
            automaticSyncDiagnosticStore: diagnostics
        )
        await viewModel.bootstrap()
        let engine = AutomaticSyncEngine(
            pendingStore: background,
            processType: { _, _ in .blocked },
            performOpportunity: { opportunity, processPendingTypes in
                _ = await viewModel.performAutomaticSyncOpportunity(
                    opportunity: opportunity,
                    processPendingTypes: processPendingTypes
                )
            }
        )

        try await engine.requestRun(reason: .observerBatch(typeCodes: ["steps"]))

        let lastRun = try XCTUnwrap(background.lastRun)
        XCTAssertEqual(lastRun.outcome, .interrupted)
        XCTAssertFalse(lastRun.succeeded)
        XCTAssertEqual(diagnostics.latestRecord?.runOutcome, .deferred)
        XCTAssertGreaterThan(diagnostics.latestRecord?.remainingPendingLaneCount ?? 0, 0)
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), ["steps": 1])
    }

    func testRuntimeIneligibleGenerationRetiresWithoutBlockingLaterEligibleWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeIneligibleAutomaticTypeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "RuntimeIneligibleAutomaticTypeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settings.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-ineligible-type-credential",
            rotateBindingID: true
        )
        let unavailableTypeCode = "aaa_runtime_unavailable_quantity"
        let background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        try background.markPendingObserverTypeCodes([unavailableTypeCode, "steps"])
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: outbox
        )
        await viewModel.bootstrap()
        XCTAssertFalse(
            viewModel.automaticSyncSelectedEligibleTypeCodes().contains(unavailableTypeCode)
        )
        var processedTypeCodes: [String] = []
        let engine = AutomaticSyncEngine(
            pendingStore: background,
            processType: { typeCode, pendingGenerations in
                processedTypeCodes.append(typeCode)
                guard typeCode == unavailableTypeCode else { return .noPayload }
                return await viewModel.processAutomaticSyncType(
                    typeCode,
                    pendingGenerations: pendingGenerations
                )
            }
        )

        try await engine.requestRun(reason: .scheduledRefresh)

        XCTAssertEqual(processedTypeCodes, [unavailableTypeCode, "steps"])
        XCTAssertTrue(try background.loadPendingObserverTypeCodeGenerations().isEmpty)

        try background.markPendingObserverTypeCodes([unavailableTypeCode])
        let retainedGenerations = try background.loadPendingObserverTypeCodeGenerations()
        var outboxRetirements = retainedGenerations
        outboxRetirements["synthetic_group_peer"] = 1
        _ = try outbox.enqueueSequence(
            [Data("synthetic-ineligible-retirement".utf8)],
            receiverIdentity: try XCTUnwrap(settings.receiverBindingID),
            pendingGenerationRetirements: outboxRetirements
        )

        let protectedResult = await viewModel.processAutomaticSyncType(
            unavailableTypeCode,
            pendingGenerations: retainedGenerations
        )

        XCTAssertEqual(protectedResult, .payloadEnqueued)
        XCTAssertEqual(
            try background.loadPendingObserverTypeCodeGenerations(),
            retainedGenerations
        )
    }

    func testConfirmedResetDuringPairingTerminalRequestWaitsThenDeletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 36, in: outbox, receiverBindingID: receiverBindingID)

        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())

        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox
        )
        XCTAssertEqual(viewModel.pendingOutboxCount, 36)
        XCTAssertEqual(try outbox.pendingItems().count, 36)

        let resetReturned = expectation(description: "confirmed reset returned")
        var resetObservation: ResetObservation?
        var resetObservationError: Error?
        let resetObservationTask = Task { @MainActor in
            for await requestIsActive in viewModel.$terminalTransitionRequestIsActive.values {
                guard requestIsActive,
                      viewModel.terminalTransitionRequestIsActive else {
                    continue
                }
                await viewModel.clearPendingOutbox()
                do {
                    resetObservation = ResetObservation(
                        queuedItemCount: try outbox.pendingItems().count,
                        clearIntentIsActive: outbox.clearIntentIsActive
                    )
                } catch {
                    resetObservationError = error
                }
                resetReturned.fulfill()
                return
            }
        }
        await Task.yield()
        let bootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
        }
        await fulfillment(of: [resetReturned], timeout: 3)
        resetObservationTask.cancel()
        await resetObservationTask.value
        if let resetObservationError {
            throw resetObservationError
        }
        let observation = try XCTUnwrap(resetObservation)

        XCTAssertEqual(observation.queuedItemCount, 0)
        XCTAssertFalse(observation.clearIntentIsActive)

        await bootstrapTask.value
        XCTAssertNil(try pairingStateStore.loadPending())
    }

    func testConfirmedResetCancelsBlockingBootstrapCleanupBeforeWaiting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 36, in: outbox, receiverBindingID: receiverBindingID)

        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())

        let cleanupStarted = expectation(description: "bootstrap cleanup started")
        let cleanupCancelled = expectation(description: "bootstrap cleanup cancelled")
        let blockingCleanup = BlockingBootstrapCleanup(
            onStart: { cleanupStarted.fulfill() },
            onCancel: { cleanupCancelled.fulfill() }
        )
        defer { blockingCleanup.release() }
        var cleanupInvocationCount = 0
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            cancelInheritedLegacyUploads: {
                cleanupInvocationCount += 1
                if cleanupInvocationCount == 1 {
                    return await blockingCleanup.wait()
                }
                return BackgroundUploadCancellationResult(
                    cancelledCount: 0,
                    fullyFinalized: true
                )
            }
        )

        let bootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
        }
        await fulfillment(of: [cleanupStarted], timeout: 1)

        let resetReturned = expectation(description: "confirmed reset returned")
        let resetTask = Task { @MainActor in
            await viewModel.clearPendingOutbox()
            resetReturned.fulfill()
        }
        await fulfillment(of: [cleanupCancelled, resetReturned], timeout: 1)
        blockingCleanup.release()
        await resetTask.value
        await bootstrapTask.value

        XCTAssertEqual(try outbox.pendingItems().count, 0)
        XCTAssertFalse(outbox.clearIntentIsActive)
        XCTAssertNil(try pairingStateStore.loadPending())
    }

    func testPendingPairingCancellationBlocksConnectionCheckDuringBootstrapCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())

        let cleanupStarted = expectation(description: "bootstrap cleanup started")
        let cleanupCancelled = expectation(description: "bootstrap cleanup cancelled")
        let blockingCleanup = BlockingBootstrapCleanup(
            releaseOnCancellation: false,
            onStart: { cleanupStarted.fulfill() },
            onCancel: { cleanupCancelled.fulfill() }
        )
        defer { blockingCleanup.release() }
        let networkRecorder = PayloadFenceNetworkRecorder()
        PayloadFenceURLProtocol.networkRecorder = networkRecorder
        defer { PayloadFenceURLProtocol.networkRecorder = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PayloadFenceURLProtocol.self]
        var cleanupInvocationCount = 0
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            receiverClient: ReceiverClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            cancelInheritedLegacyUploads: {
                cleanupInvocationCount += 1
                if cleanupInvocationCount == 1 {
                    return await blockingCleanup.wait()
                }
                return BackgroundUploadCancellationResult(
                    cancelledCount: 0,
                    fullyFinalized: true
                )
            }
        )

        let bootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
        }
        await fulfillment(of: [cleanupStarted], timeout: 1)

        let cancellationReturned = expectation(description: "pending pairing cancellation returned")
        let cancellationTask = Task { @MainActor in
            await viewModel.cancelPendingPairing()
            cancellationReturned.fulfill()
        }
        await fulfillment(of: [cleanupCancelled], timeout: 1)
        XCTAssertTrue(try pairingStateStore.hasPendingCancellation())
        XCTAssertNotNil(settingsStore.terminalCancellationExpectedGeneration)

        let originalHistoryDepth = viewModel.healthHistoryDepth
        let competingHistoryDepthOption = originalHistoryDepth == .allAvailable
            ? "last_30_days"
            : "all_available"
        viewModel.setHealthHistoryDepthOption(competingHistoryDepthOption)
        XCTAssertEqual(viewModel.healthHistoryDepth, originalHistoryDepth)

        let statusBeforeConnectionCheck = viewModel.statusMessage
        let statusErrorBeforeConnectionCheck = viewModel.statusIsError
        let settingsGenerationBeforeConnectionCheck =
            settingsStore.receiverSettingsGenerationToken
        let receiverURLBeforeConnectionCheck = settingsStore.receiverURLString
        let pendingItemsBeforeConnectionCheck = try outbox.pendingItems().count
        await viewModel.checkConnection()

        XCTAssertFalse(viewModel.backgroundRefreshSchedulingAdmissionIsOpen)
        XCTAssertEqual(networkRecorder.invocationCount, 0)
        XCTAssertFalse(viewModel.isCheckingConnection)
        XCTAssertEqual(viewModel.statusMessage, statusBeforeConnectionCheck)
        XCTAssertEqual(viewModel.statusIsError, statusErrorBeforeConnectionCheck)
        XCTAssertEqual(
            settingsStore.receiverSettingsGenerationToken,
            settingsGenerationBeforeConnectionCheck
        )
        XCTAssertEqual(settingsStore.receiverURLString, receiverURLBeforeConnectionCheck)
        XCTAssertEqual(try outbox.pendingItems().count, pendingItemsBeforeConnectionCheck)

        await viewModel.bootstrap()
        XCTAssertEqual(cleanupInvocationCount, 1)

        blockingCleanup.release()
        await fulfillment(of: [cancellationReturned], timeout: 1)
        await cancellationTask.value
        await bootstrapTask.value

        XCTAssertNil(try pairingStateStore.loadPending())
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertFalse(viewModel.hasPendingPairing)
    }

    func testPendingPairingCancellationSurvivesRelaunchWhileTerminalDrainIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())
        let cancellationGeneration = settingsStore.receiverSettingsGenerationToken

        let drainStarted = expectation(description: "terminal background drain started")
        let blockingDrain = BlockingBootstrapCleanup(
            releaseOnCancellation: false,
            onStart: { drainStarted.fulfill() },
            onCancel: {}
        )
        defer { blockingDrain.release() }
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            terminalBackgroundPayloadDrain: {
                await blockingDrain.wait().fullyFinalized
            }
        )

        let cancellationTask = Task { @MainActor in
            await viewModel.cancelPendingPairing()
        }
        await fulfillment(of: [drainStarted], timeout: 1)
        XCTAssertTrue(try pairingStateStore.hasPendingCancellation())
        XCTAssertEqual(
            settingsStore.terminalCancellationExpectedGeneration,
            cancellationGeneration
        )
        XCTAssertEqual(
            settingsStore.receiverSettingsGenerationToken,
            cancellationGeneration
        )

        let relaunchedCoordinator = ReceiverPairingCoordinator(
            client: ReceiverClient(),
            stateStore: pairingStateStore,
            settingsStore: settingsStore
        )
        let recovered = try await relaunchedCoordinator.resumePendingPairing()

        XCTAssertNil(recovered)
        XCTAssertNil(try pairingStateStore.loadPending())
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertFalse(try pairingStateStore.hasPendingCancellation())
        XCTAssertNil(settingsStore.terminalCancellationExpectedGeneration)

        cancellationTask.cancel()
        blockingDrain.release()
        await cancellationTask.value
    }

    func testBootstrapFinishesTerminalIntentAfterCommittedClearWithTrustedEmptyOutbox() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let receiverTokenStore = MemoryReceiverTokenStore()
        let preCutoverBackupStore = MemoryReceiverTokenStore()
        let pendingStore = MemoryReceiverTokenStore()
        let installationIDStore = MemoryReceiverTokenStore()
        let cancellationStore = MemoryReceiverTokenStore()
        var synchronizationCount = 0
        let synchronize = {
            synchronizationCount += 1
            return synchronizationCount == 1
        }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: receiverTokenStore,
            preCutoverBackupStore: preCutoverBackupStore,
            synchronize: synchronize
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationIDStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        let cancellationGeneration = settingsStore.receiverSettingsGenerationToken
        let coordinator = ReceiverPairingCoordinator(
            client: ReceiverClient(),
            stateStore: pairingStateStore,
            settingsStore: settingsStore
        )

        let outcome = try coordinator.cancelPendingPairing()

        XCTAssertEqual(outcome, .committedCleanupPending)
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertFalse(try pairingStateStore.hasPendingCancellation())
        XCTAssertEqual(
            settingsStore.terminalCancellationExpectedGeneration,
            cancellationGeneration
        )
        let committedGeneration = settingsStore.receiverSettingsGenerationToken
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        XCTAssertEqual(try outbox.pendingItems().count, 0)

        let relaunchedSettingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: receiverTokenStore,
            preCutoverBackupStore: preCutoverBackupStore,
            synchronize: synchronize
        )
        let relaunchedPairingStateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationIDStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        let relaunchedViewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: relaunchedSettingsStore,
            pairingStateStore: relaunchedPairingStateStore,
            outbox: outbox
        )

        await relaunchedViewModel.bootstrap()

        XCTAssertEqual(synchronizationCount, 3)
        XCTAssertNil(relaunchedSettingsStore.terminalCancellationExpectedGeneration)
        XCTAssertFalse(relaunchedViewModel.hasPendingPairing)
        XCTAssertTrue(try relaunchedSettingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(
            relaunchedSettingsStore.receiverSettingsGenerationToken,
            committedGeneration
        )
        XCTAssertEqual(try outbox.pendingItems().count, 0)
    }

    func testBootstrapRetiresCancellationAfterReceiverRemovalCommitsBeforeMirrors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let receiverTokenStore = MemoryReceiverTokenStore()
        let preCutoverBackupStore = MemoryReceiverTokenStore()
        let pendingStore = MemoryReceiverTokenStore()
        let installationIDStore = MemoryReceiverTokenStore()
        let cancellationStore = MemoryReceiverTokenStore()
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: receiverTokenStore,
            preCutoverBackupStore: preCutoverBackupStore,
            synchronize: { true }
        )
        let receiverURLString = "https://old.example/v1/batches"
        let bearerToken = "synthetic-device-credential"
        try settingsStore.save(
            receiverURLString: receiverURLString,
            bearerToken: bearerToken,
            rotateBindingID: true
        )
        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationIDStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())
        let cancellationGeneration = settingsStore.receiverSettingsGenerationToken
        let coordinator = ReceiverPairingCoordinator(
            client: ReceiverClient(),
            stateStore: pairingStateStore,
            settingsStore: settingsStore
        )
        try coordinator.beginPendingCancellation(
            expectedGeneration: cancellationGeneration
        )

        let mailboxIdentity = MailboxConnectionIdentityV1(
            receiverID: String(repeating: "1", count: 32),
            deviceID: String(repeating: "2", count: 32),
            devicePrincipal: "installation:" + String(repeating: "3", count: 64),
            deviceSigningKeyID: String(repeating: "4", count: 32),
            deviceAgreementKeyID: String(repeating: "5", count: 32),
            receiverSigningKeyID: "6c9a98e60055e4d14e5d591d6b7c1104",
            receiverAgreementKeyID: "cf09eac7ec4fb8e8acc48b7cc1ee77e5",
            receiverSigningPublicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            receiverAgreementPublicKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8",
            opaqueBinding: "Q0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0M",
            connectionGeneration: 1
        )
        let committedPairedMailboxRecord = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: try XCTUnwrap(
                    settingsStore.currentConnectionRecordV2()
                ).localScope.generation,
                bindingID: mailboxIdentity.opaqueBinding
            ),
            mailboxIdentity: .available(mailboxIdentity),
            activation: .paired(activeTransport: .mailbox),
            transportConfigurations: [
                .directHTTP(
                    activation: .inactive,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: receiverURLString,
                        bearerToken: bearerToken
                    )
                ),
                .mailbox(
                    activation: .active,
                    configuration: MailboxConnectionConfigurationV1()
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedRecord = try encoder.encode(committedPairedMailboxRecord)
        try receiverTokenStore.saveToken(
            "health-bridge-connection-v2:" + encodedRecord.base64EncodedString()
        )

        let relaunchedSettingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: receiverTokenStore,
            preCutoverBackupStore: preCutoverBackupStore,
            synchronize: { true }
        )
        let relaunchedPairingStateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationIDStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        XCTAssertEqual(try outbox.pendingItems().count, 0)
        XCTAssertEqual(
            relaunchedSettingsStore.terminalCancellationExpectedGeneration,
            cancellationGeneration
        )
        XCTAssertEqual(
            relaunchedSettingsStore.receiverSettingsGenerationToken,
            cancellationGeneration
        )
        XCTAssertEqual(
            try relaunchedPairingStateStore.pendingCancellationExpectedGeneration(),
            cancellationGeneration
        )
        XCTAssertNotNil(try relaunchedPairingStateStore.loadPending())
        XCTAssertEqual(
            try relaunchedSettingsStore.currentConnectionRecordV2(),
            committedPairedMailboxRecord
        )
        XCTAssertEqual(
            committedPairedMailboxRecord.transportConfigurations,
            [
                .directHTTP(
                    activation: .inactive,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: receiverURLString,
                        bearerToken: bearerToken
                    )
                ),
                .mailbox(
                    activation: .active,
                    configuration: MailboxConnectionConfigurationV1()
                ),
            ]
        )
        XCTAssertEqual(relaunchedSettingsStore.activeTransport, .mailbox)
        XCTAssertFalse(try relaunchedSettingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(
            relaunchedSettingsStore.receiverURLString,
            receiverURLString
        )
        XCTAssertNotEqual(
            relaunchedSettingsStore.receiverURLString,
            ReceiverSettingsStore.defaultReceiverURLString
        )
        XCTAssertEqual(try relaunchedSettingsStore.loadBearerToken(), bearerToken)
        XCTAssertEqual(
            defaults.string(forKey: "receiverURLString"),
            receiverURLString
        )

        let relaunchedViewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: relaunchedSettingsStore,
            pairingStateStore: relaunchedPairingStateStore,
            outbox: outbox
        )
        await relaunchedViewModel.bootstrap()

        XCTAssertNil(relaunchedSettingsStore.terminalCancellationExpectedGeneration)
        XCTAssertNil(try relaunchedPairingStateStore.loadPending())
        XCTAssertFalse(try relaunchedPairingStateStore.hasPendingCancellation())
        XCTAssertFalse(relaunchedViewModel.hasPendingPairing)
        XCTAssertNotEqual(
            try relaunchedSettingsStore.currentConnectionRecordV2(),
            committedPairedMailboxRecord
        )
        XCTAssertNil(relaunchedSettingsStore.activeTransport)
        XCTAssertTrue(try relaunchedSettingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(
            relaunchedSettingsStore.receiverSettingsGenerationToken,
            cancellationGeneration
        )
        XCTAssertEqual(
            relaunchedSettingsStore.receiverURLString,
            ReceiverSettingsStore.defaultReceiverURLString
        )
        XCTAssertEqual(try relaunchedSettingsStore.loadBearerToken(), "")
        XCTAssertNil(defaults.string(forKey: "receiverURLString"))
        XCTAssertEqual(try outbox.pendingItems().count, 0)
    }

    func testConfirmedResetRejectsBootstrapReadmissionWhileCancellationIsDraining() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 36, in: outbox, receiverBindingID: receiverBindingID)

        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())

        let cleanupStarted = expectation(description: "bootstrap cleanup started")
        let cleanupCancelled = expectation(description: "bootstrap cleanup cancelled")
        let blockingCleanup = BlockingBootstrapCleanup(
            releaseOnCancellation: false,
            onStart: { cleanupStarted.fulfill() },
            onCancel: { cleanupCancelled.fulfill() }
        )
        defer { blockingCleanup.release() }
        var cleanupInvocationCount = 0
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            cancelInheritedLegacyUploads: {
                cleanupInvocationCount += 1
                if cleanupInvocationCount == 1 {
                    return await blockingCleanup.wait()
                }
                return BackgroundUploadCancellationResult(
                    cancelledCount: 0,
                    fullyFinalized: true
                )
            }
        )

        let initialBootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
        }
        await fulfillment(of: [cleanupStarted], timeout: 1)

        let resetReturned = expectation(description: "confirmed reset returned")
        let resetTask = Task { @MainActor in
            await viewModel.clearPendingOutbox()
            resetReturned.fulfill()
        }
        await fulfillment(of: [cleanupCancelled], timeout: 1)

        let racingBootstrapReturned = expectation(
            description: "bootstrap requested during reset cancellation was rejected"
        )
        let racingBootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
            racingBootstrapReturned.fulfill()
        }
        await fulfillment(of: [racingBootstrapReturned], timeout: 0.5)

        blockingCleanup.release()
        await fulfillment(of: [resetReturned], timeout: 2)
        await resetTask.value
        await initialBootstrapTask.value
        await racingBootstrapTask.value

        XCTAssertEqual(try outbox.pendingItems().count, 0)
        XCTAssertFalse(outbox.clearIntentIsActive)
        XCTAssertNil(try pairingStateStore.loadPending())
    }

    func testConfirmedResetPersistsIntentBeforeNonCooperativeBackgroundDrain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 36, in: outbox, receiverBindingID: receiverBindingID)

        let mailboxItem = try XCTUnwrap(try outbox.pendingItems().first)
        let mailboxPayload = try Data(contentsOf: mailboxItem.fileURL)
        _ = try outbox.finalizeMailboxEnvelope(
            itemID: mailboxItem.id,
            envelope: Data("synthetic-mailbox-envelope".utf8),
            expectedPayloadSHA256: SHA256.hash(data: mailboxPayload)
                .map { String(format: "%02x", $0) }
                .joined()
        )

        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )

        let drainStarted = expectation(description: "background drain started")
        let blockingDrain = BlockingBootstrapCleanup(
            releaseOnCancellation: false,
            onStart: { drainStarted.fulfill() },
            onCancel: {}
        )
        defer { blockingDrain.release() }
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            terminalBackgroundPayloadDrain: {
                await blockingDrain.wait().fullyFinalized
            },
            terminalRecoveryDrainTimeoutNanoseconds: 100_000_000
        )

        let resetReturned = expectation(description: "confirmed reset returned after bounded drain")
        let resetTask = Task { @MainActor in
            await viewModel.clearPendingOutbox()
            resetReturned.fulfill()
        }
        await fulfillment(of: [drainStarted, resetReturned], timeout: 1)
        await resetTask.value

        XCTAssertEqual(try outbox.pendingItems().count, 36)
        XCTAssertTrue(outbox.terminalResetRequestIsActive)
        XCTAssertFalse(outbox.clearIntentIsActive)

        blockingDrain.release()
        let relaunchedViewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            terminalBackgroundPayloadDrain: { true },
            terminalRecoveryDrainTimeoutNanoseconds: 100_000_000
        )
        await relaunchedViewModel.bootstrap()

        XCTAssertEqual(try outbox.pendingItems().count, 0)
        XCTAssertFalse(outbox.terminalResetRequestIsActive)
        XCTAssertFalse(outbox.clearIntentIsActive)
    }

    private func enqueueSyntheticItems(
        count: Int,
        in outbox: FileOutbox,
        receiverBindingID: String
    ) throws {
        for sequence in 0..<count {
            let payload = Data("{\"schema_id\":\"synthetic.reset-test\",\"sequence\":\(sequence)}".utf8)
            _ = try outbox.enqueue(payload, receiverIdentity: receiverBindingID)
        }
    }

    private func syntheticInvitation() throws -> ReceiverPairingInvitation {
        try ReceiverPairingInvitation(jsonData: Data(
            """
            {
              "schema_id": "health_bridge.receiver_pairing_invitation.v2",
              "schema_version": "2.0.0",
              "label": "Synthetic reset regression",
              "receiver_url": "http://127.0.0.1:8765/v1/batches",
              "redeem_url": "http://127.0.0.1:8765/v1/pairing/redeem",
              "invitation_secret": "synthetic-invitation-credential",
              "expires_at": "2099-01-01T00:00:00Z"
            }
            """.utf8
        ))
    }

    private func makeViewModel(
        root: URL,
        defaults: UserDefaults,
        settingsStore: ReceiverSettingsStore,
        pairingStateStore: ReceiverPairingStateStore,
        outbox: FileOutbox,
        receiverClient: ReceiverClient = ReceiverClient(),
        automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore = AutomaticSyncDiagnosticStore(),
        readAnchoredSleepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredSleepChanges)? = nil,
        readAnchoredStepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredStepChanges)? = nil,
        readDailyActivityAggregates: (@MainActor (
            [String], Date, Date, Calendar
        ) async throws -> [HealthKitDailyActivityAggregate])? = nil,
        scheduleDirectBackgroundUploads: (@MainActor () async throws -> Int)? = nil,
        cancelInheritedLegacyUploads: @escaping @MainActor () async -> BackgroundUploadCancellationResult = {
            BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
        },
        terminalBackgroundPayloadDrain: (@MainActor () async -> Bool)? = nil,
        terminalRecoveryDrainTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) throws -> HealthBridgeCompanionViewModel {
        HealthBridgeCompanionViewModel(
            receiverClient: receiverClient,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            backgroundSyncStore: BackgroundSyncSettingsStore(userDefaults: defaults),
            automaticSyncDiagnosticStore: automaticSyncDiagnosticStore,
            healthPermissionRequestStore: CompanionHealthPermissionRequestStore(
                userDefaults: defaults
            ),
            healthHistoryDepthStore: HealthHistoryDepthSelectionStore(userDefaults: defaults),
            historicalBackfillStateStore: HealthHistoricalBackfillStateStore(
                userDefaults: defaults
            ),
            quantityObservationStore: QuantityObservationStore(userDefaults: defaults),
            coreLaneUploadProofStore: CoreLaneUploadProofStore(userDefaults: defaults),
            outbox: outbox,
            outboxDirectoryURL: outbox.directoryURL,
            cursorStore: try FileSyncCursorStore(
                fileURL: root.appendingPathComponent("cursors.json")
            ),
            cursorStoreFileURL: root.appendingPathComponent("cursors.json"),
            sleepManifestStore: try FileSleepSyncManifestStore(
                fileURL: root.appendingPathComponent("sleep.json")
            ),
            sleepManifestFileURL: root.appendingPathComponent("sleep.json"),
            sleepResetEpochStore: SleepResetEpochStore(
                tokenStore: MemoryReceiverTokenStore(),
                epochFloorProvider: { 1 }
            ),
            mailboxKeyStore: MailboxKeyStore(
                service: "synthetic.reset-regression",
                keychain: MemoryMailboxKeychain()
            ),
            readAnchoredSleepChanges: readAnchoredSleepChanges,
            readAnchoredStepChanges: readAnchoredStepChanges,
            readDailyActivityAggregates: readDailyActivityAggregates,
            scheduleDirectBackgroundUploads: scheduleDirectBackgroundUploads,
            cancelInheritedLegacyUploads: cancelInheritedLegacyUploads,
            terminalBackgroundPayloadDrain: terminalBackgroundPayloadDrain,
            terminalRecoveryDrainTimeoutNanoseconds: terminalRecoveryDrainTimeoutNanoseconds
        )
    }
}

@MainActor
private final class AutomaticStepsFaultFixture {
    enum ReadFailure: Error { case injected }

    let root: URL
    let suiteName = "AutomaticStepsFaultTests.\(UUID().uuidString)"
    let tokenStore = MemoryReceiverTokenStore()
    let backupStore = MemoryReceiverTokenStore()
    let pairingPendingStore = MemoryReceiverTokenStore()
    let installationStore = MemoryReceiverTokenStore()
    let pairingCancellationStore = MemoryReceiverTokenStore()
    let recorder = PayloadFenceNetworkRecorder()
    let previousAnchor: String
    let currentAnchor: String
    private(set) var receiverBindingID = ""
    var sessions: [URLSession] = []
    var failRawRead = false
    var failStepsDailyRead = false
    private(set) var declinedBackgroundSchedules = 0
    private(set) var rawAnchors: [String] = []
    private(set) var dailyRequests: [[String]] = []
    private(set) var completedStepsDay: HealthKitDailyActivityAggregate?
    private let sampleStart = Date().addingTimeInterval(-120)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticStepsFaultTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        previousAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 41))
        currentAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 42))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = makeSettingsStore(defaults: defaults)
        try settings.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-steps-fault-credential",
            rotateBindingID: true
        )
        receiverBindingID = try XCTUnwrap(settings.receiverBindingID)
        try BackgroundSyncSettingsStore(userDefaults: defaults).setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).saveCursorValue(
            previousAnchor,
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        )
        CoreLaneUploadProofStore(userDefaults: defaults).markUploadedRecords(
            lane: .steps, receiverBindingID: receiverBindingID
        )
    }

    func makeSettingsStore(defaults: UserDefaults) -> ReceiverSettingsStore {
        ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: tokenStore,
            preCutoverBackupStore: backupStore, synchronize: { true }
        )
    }

    func pending() throws -> [String: Int] {
        try BackgroundSyncSettingsStore(userDefaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
            .loadPendingObserverTypeCodeGenerations()
    }

    func admit(_ types: [String]) throws -> [String: Int] {
        let store = BackgroundSyncSettingsStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        try store.markPendingObserverTypeCodes(types)
        let admitted = try store.loadPendingObserverTypeCodeGenerations()
        XCTAssertEqual(admitted.keys.sorted(), types.sorted())
        return admitted
    }

    func stepCursor() throws -> String? {
        try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).cursorValue(
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        )
    }

    func acceptedSamples(kind: String) throws -> [HealthBridgeSample] {
        try recorder.acceptedPayloads.flatMap {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0).samples
        }.filter { $0.metadata["sample_kind"] == kind }
    }

    func readRaw(anchor: String?, start: Date?, receivedAt: Date) throws -> HealthKitAnchoredStepChanges {
        let anchor = try XCTUnwrap(anchor)
        rawAnchors.append(anchor)
        XCTAssertTrue([previousAnchor, currentAnchor].contains(anchor))
        XCTAssertNil(start)
        if failRawRead { throw ReadFailure.injected }
        return HealthKitAnchoredStepChanges(
            stepSamples: anchor == currentAnchor ? [] : [HealthKitStepSampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000058")),
                start: sampleStart, end: sampleStart.addingTimeInterval(60), count: 17
            )],
            deletedStepSamples: [], anchorCursorValue: currentAnchor,
            windowStart: sampleStart, windowEnd: receivedAt
        )
    }

    func readDaily(types: [String], start: Date, end: Date, calendar: Calendar) throws -> [HealthKitDailyActivityAggregate] {
        dailyRequests.append(types)
        XCTAssertFalse(types.isEmpty)
        XCTAssertTrue(Set(types).isSubset(of: ["steps", "basal_energy"]))
        XCTAssertEqual(calendar.timeZone, Calendar.current.timeZone)
        if failStepsDailyRead, types.contains("steps") { throw ReadFailure.injected }
        let today = calendar.startOfDay(for: end)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        XCTAssertLessThanOrEqual(start, yesterday)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return types.flatMap { type in
            let completed = HealthKitDailyActivityAggregate(
                typeCode: type, dayStart: yesterday, dayEnd: today,
                value: type == "steps" ? 4_321 : 345,
                calendarDay: formatter.string(from: yesterday),
                timeZoneIdentifier: calendar.timeZone.identifier
            )
            if type == "steps" { completedStepsDay = completed }
            return [completed, HealthKitDailyActivityAggregate(
                typeCode: type, dayStart: today, dayEnd: tomorrow, value: 99,
                isComplete: false, calendarDay: formatter.string(from: today),
                timeZoneIdentifier: calendar.timeZone.identifier
            )]
        }
    }

    func declineBackgroundScheduling() -> Int {
        declinedBackgroundSchedules += 1
        return 0
    }

    func cleanUp() {
        sessions.forEach { $0.invalidateAndCancel() }
        PayloadFenceURLProtocol.networkRecorder = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ResetObservation {
    let queuedItemCount: Int
    let clearIntentIsActive: Bool
}

private final class PayloadFenceNetworkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var recordedPayloads: [Data] = []
    private var successfulPayloads: [Data] = []
    private var failedStepsSampleKinds: Set<String> = []

    func setFailedStepsSampleKinds(_ kinds: Set<String>) {
        lock.lock()
        failedStepsSampleKinds = kinds
        lock.unlock()
    }

    func responseStatusCode(for payload: Data?) -> Int {
        lock.lock()
        let failedKinds = failedStepsSampleKinds
        lock.unlock()
        guard !failedKinds.isEmpty else { return 200 }
        guard let payload,
              let batch = try? JSONDecoder().decode(HealthBridgeBatchV1.self, from: payload) else {
            return 500
        }
        return batch.samples.contains {
            $0.typeCode == "steps" && failedKinds.contains($0.metadata["sample_kind"] ?? "")
        } ? 500 : 200
    }

    var acceptedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return successfulPayloads
    }

    func recordAcceptedPayload(_ payload: Data) {
        lock.lock()
        successfulPayloads.append(payload)
        lock.unlock()
    }

    var payloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPayloads
    }

    func recordPayload(_ payload: Data) {
        lock.lock()
        recordedPayloads.append(payload)
        lock.unlock()
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class BootstrapInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class PayloadFenceURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var networkRecorder: PayloadFenceNetworkRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.networkRecorder?.recordInvocation()
        var payload: Data?
        if let body = request.httpBody {
            payload = body
            Self.networkRecorder?.recordPayload(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else {
                    client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeContentData))
                    return
                }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            payload = body
            Self.networkRecorder?.recordPayload(body)
        }
        let statusCode = Self.networkRecorder?.responseStatusCode(for: payload) ?? 200
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = statusCode == 200 ? #"{"status":"ok"}"# : #"{"status":"synthetic_failure"}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if statusCode == 200, let payload { Self.networkRecorder?.recordAcceptedPayload(payload) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BlockingBootstrapCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: () -> Void
    private let onCancel: () -> Void
    private let releaseOnCancellation: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(
        releaseOnCancellation: Bool = true,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.releaseOnCancellation = releaseOnCancellation
        self.onStart = onStart
        self.onCancel = onCancel
    }

    func wait() async -> BackgroundUploadCancellationResult {
        onStart()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                let shouldResume = released
                if !shouldResume {
                    self.continuation = continuation
                }
                lock.unlock()
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.onCancel()
            if self.releaseOnCancellation {
                self.release()
            }
        }
        return BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class MemoryReceiverTokenStore: ReceiverTokenStoring {
    private var token = ""

    func loadToken() throws -> String { token }

    func saveToken(_ token: String) throws {
        self.token = token
    }
}

private final class MemoryMailboxKeychain: MailboxKeychainClient {
    private var items: [String: Data] = [:]
    private var trustItems: [String: Data] = [:]

    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T {
        try body()
    }

    func data(service: String, account: String) throws -> Data? {
        items["\(service)\u{0}\(account)"]
    }

    func store(_ data: Data, service: String, account: String) throws {
        items["\(service)\u{0}\(account)"] = data
    }

    func remove(service: String, account: String) throws {
        items.removeValue(forKey: "\(service)\u{0}\(account)")
    }

    func trustData(service: String, record: MailboxTrustRecord) throws -> Data? {
        trustItems["\(service)\u{0}\(record.rawValue)"]
    }

    func storeTrust(_ data: Data, service: String, record: MailboxTrustRecord) throws {
        trustItems["\(service)\u{0}\(record.rawValue)"] = data
    }

    func removeTrust(service: String, record: MailboxTrustRecord) throws {
        trustItems.removeValue(forKey: "\(service)\u{0}\(record.rawValue)")
    }
}

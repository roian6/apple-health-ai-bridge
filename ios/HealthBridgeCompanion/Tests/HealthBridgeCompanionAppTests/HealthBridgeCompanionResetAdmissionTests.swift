import Combine
import CryptoKit
import Darwin
import Foundation
import HealthKit
import UIKit
import XCTest
@testable import HealthBridgeCompanion

@MainActor
private final class RecordingBackgroundRefreshScheduler: BackgroundRefreshScheduling {
    private(set) var requestCount = 0
    private(set) var admittedRequestCount = 0
    private(set) var consumedCount = 0
    private(set) var cancelCount = 0

    func scheduleNextRefreshIfNeeded(viewModel: HealthBridgeCompanionViewModel) {
        requestCount += 1
        if viewModel.backgroundRefreshSchedulingAdmissionIsOpen
            && viewModel.backgroundSyncEnabled && viewModel.canSendConnectionTest {
            admittedRequestCount += 1
        }
    }
    func noteRequestConsumed() { consumedCount += 1 }
    func cancelPendingRefresh() { cancelCount += 1 }
}

@MainActor
final class HealthBridgeCompanionResetAdmissionTests: XCTestCase {

    func testMailboxDisconnectWithFinalizedHistoryAndInactiveDirectConfiguration() async throws {
        let fixture = try NativeMailboxAutomaticFixture(inactiveDirectURL: "https://inactive.synthetic.test/v1/batches")
        defer { fixture.cleanUp() }
        let settings = fixture.makeSettingsStore()
        let binding = try XCTUnwrap(settings.receiverBindingID)
        let item = try XCTUnwrap(fixture.outbox.enqueueSequence(
            [Data("synthetic-finalized-history".utf8)], receiverIdentity: binding).first)
        let delivery = ProductionMailboxDelivery(settingsStore: settings, outbox: fixture.outbox,
            cursorStore: try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json")),
            pendingGenerationStore: BackgroundSyncSettingsStore(userDefaults: fixture.defaults),
            keyStore: fixture.keyStore, providerLocation: fixture.providerLocation)
        _ = try await delivery.deliverPending()
        let published = try XCTUnwrap(fixture.outbox.pendingItem(id: item.id))
        let ack = try fixture.signedAcknowledgment(for: published)
        try ack.bytes.write(to: ack.url)
        let finalized = try await delivery.deliverPending()
        XCTAssertEqual(finalized.finalizedCount, 1)
        let history = try XCTUnwrap(fixture.outbox.deliveryState(for: item.id))
        XCTAssertEqual(history.phase, .committedFinalized)
        XCTAssertNotNil(history.committedReceipt)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        let runtime = try makeNativeMailboxRuntime(fixture)
        await runtime.bootstrap()
        let outcome = await runtime.viewModel.disconnectReceiver()
        guard case .disconnected(let count) = outcome else {
            return XCTFail("Trusted empty mailbox disconnect must complete, not report Can't Disconnect Yet.")
        }
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try fixture.makeSettingsStore().receiverSettingsAreCleared())
        XCTAssertNil(fixture.makeSettingsStore().terminalCancellationExpectedGeneration)
        XCTAssertFalse(runtime.viewModel.hasPendingPairing)
        XCTAssertFalse(runtime.viewModel.statusIsError)
        XCTAssertFalse(fixture.defaults.bool(forKey: "healthBridge.backgroundSync.enabled"))
        XCTAssertEqual(try FileOutbox(directory: fixture.outbox.directoryURL).deliveryState(for: item.id), history)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(fixture.rawReadCount, 0)
    }

    func testMailboxDisconnectRetainsPendingPayloadAndCurrentConnection() async throws {
        let fixture = try NativeMailboxAutomaticFixture(inactiveDirectURL: "https://inactive.synthetic.test/v1/batches")
        defer { fixture.cleanUp() }
        let settings = fixture.makeSettingsStore()
        let record = try settings.currentConnectionRecordV2()
        let item = try XCTUnwrap(fixture.outbox.enqueueSequence(
            [Data("synthetic-pending-do-not-clear".utf8)], receiverIdentity: XCTUnwrap(settings.receiverBindingID)).first)
        let payload = try Data(contentsOf: item.fileURL)
        let runtime = try makeNativeMailboxRuntime(fixture)
        await runtime.bootstrap()
        let outcome = await runtime.viewModel.disconnectReceiver()
        guard case .rejected = outcome else { return XCTFail("Pending mailbox payload must block disconnect.") }
        XCTAssertEqual(try fixture.makeSettingsStore().currentConnectionRecordV2(), record)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [item.id])
        XCTAssertNil(fixture.makeSettingsStore().terminalCancellationExpectedGeneration)
        XCTAssertTrue(fixture.defaults.bool(forKey: "healthBridge.backgroundSync.enabled"))
        XCTAssertEqual(fixture.rawReadCount, 0)
    }
    func testNativeMailboxMetadataNotificationsRespectQueryLifetime() throws {
        let observer = NativeMailboxChangeObserver()
        var wakes = 0
        observer.start { wakes += 1 }
        let first = try XCTUnwrap(observer.query)
        XCTAssertEqual(first.searchScopes as? [String], [NSMetadataQueryUbiquitousDocumentsScope])
        NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: first)
        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: first)
        XCTAssertEqual(wakes, 2)
        observer.stop()
        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: first)
        XCTAssertEqual(wakes, 2)
        observer.start { wakes += 1 }
        defer { observer.stop() }
        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: first)
        XCTAssertEqual(wakes, 2)
        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: try XCTUnwrap(observer.query))
        XCTAssertEqual(wakes, 3)
    }

    func testMailboxObservationSeamFollowsReadyRuntimeAdmission() async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let runtime = try makeNativeMailboxRuntime(fixture)
        await runtime.bootstrap()
        XCTAssertNotNil(fixture.mailboxObserver.onChange)
        XCTAssertEqual(fixture.rawReadCount, 0)
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        XCTAssertNil(fixture.mailboxObserver.onChange)
        XCTAssertEqual(fixture.rawReadCount, 0)
    }

    func testNativeMailboxReadyObserverPublishesEncryptedStepsWithoutRetiringBeforeACK() async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let runtime = try makeNativeMailboxRuntime(fixture)
        defer { runtime.automaticSyncRuntime.stopAdmission() }
        await runtime.bootstrap()
        XCTAssertTrue(runtime.viewModel.automaticSyncRuntimeIsReady)
        XCTAssertTrue(runtime.viewModel.usesMailboxTransport)
        XCTAssertEqual(fixture.rawReadCount, 0)

        let runID = UUID()
        guard case .continueProcessing = runtime.viewModel.admitAutomaticSyncObserver(
            typeCode: "steps", diagnosticRunID: runID
        ) else {
            return XCTFail("The persisted native mailbox must admit observer work.")
        }
        let admitted = try fixture.pending()
        XCTAssertEqual(admitted, ["steps": 1])

        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observer(typeCode: "steps"), diagnosticRunID: runID
        )

        XCTAssertEqual(fixture.rawReadCount, 1)
        try fixture.assertPublishedStepsAwaitingACK(admitted: admitted)
    }

    func testNativeMailboxUnseededEmptyRawACKReachesAuthoritativeDailyZero() async throws {
        let fixture = try NativeMailboxAutomaticFixture(unseededEmptyRaw: true)
        defer { fixture.cleanUp() }
        var dailyReadCount = 0
        let readDaily: @MainActor ([String], Date, Date, Calendar) async throws -> [HealthKitDailyActivityAggregate] = { types, _, end, calendar in
            dailyReadCount += 1
            XCTAssertEqual(types, ["steps"])
            let today = calendar.startOfDay(for: end)
            let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return [HealthKitDailyActivityAggregate(typeCode: "steps", dayStart: yesterday, dayEnd: today,
                value: 0, calendarDay: formatter.string(from: yesterday), timeZoneIdentifier: calendar.timeZone.identifier)]
        }
        var runtime = try makeNativeMailboxRuntime(fixture, readDailyActivityAggregates: readDaily)
        defer { runtime.automaticSyncRuntime.stopAdmission() }
        await runtime.bootstrap()
        let binding = try XCTUnwrap(fixture.makeSettingsStore().receiverBindingID)
        let proof = CoreLaneUploadProofStore(userDefaults: fixture.defaults)
        XCTAssertNil(try fixture.stepCursor())
        XCTAssertFalse(proof.hasUploadedRecords(lane: .steps, receiverBindingID: binding))
        for cycle in 1...2 {
            let runID = UUID()
            guard case .continueProcessing = runtime.viewModel.admitAutomaticSyncObserver(typeCode: "steps", diagnosticRunID: runID) else {
                return XCTFail("An unseeded native mailbox must admit Steps work.")
            }
            let admitted = try fixture.pending()
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observer(typeCode: "steps"), diagnosticRunID: runID)
            let raw = try XCTUnwrap(try fixture.outbox.pendingItems().first)
            let rawBatch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: raw.fileURL))
            XCTAssertTrue(rawBatch.samples.isEmpty)
            XCTAssertTrue(rawBatch.deletedRecords.isEmpty)
            XCTAssertFalse(rawBatch.sync.cursors.contains { $0.cursorKind == StepCountSyncBatchFactory.anchoredCursorKind })
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
            XCTAssertEqual(dailyReadCount, cycle - 1, "Publishing an unknown raw read is not acceptance.")
            XCTAssertEqual(fixture.rawReadCount, cycle)
            let rawACK = try fixture.signedAcknowledgment(for: raw)
            try rawACK.bytes.write(to: rawACK.url, options: .atomic)
            await wakeMailboxAndWait(runtime, callback: try XCTUnwrap(fixture.mailboxObserver.onChange))
            XCTAssertEqual(try fixture.outbox.deliveryState(for: raw.id)?.phase, .committedFinalized)
            XCTAssertEqual(try fixture.pending(), admitted)
            XCTAssertNil(try fixture.stepCursor())
            XCTAssertFalse(proof.hasUploadedRecords(lane: .steps, receiverBindingID: binding))
            XCTAssertEqual(fixture.rawReadCount, cycle, "ACK wakes remain delivery-only.")
            await runtime.automaticSyncRuntime.cancelAndWait()
            runtime = try makeNativeMailboxRuntime(fixture, readDailyActivityAggregates: readDaily)
            await runtime.bootstrap()
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
            XCTAssertEqual(dailyReadCount, cycle, "A later ordinary collection must reach authoritative daily statistics, not queue another unknown raw read.")
            let daily = try XCTUnwrap(try fixture.outbox.pendingItems().first)
            XCTAssertNotEqual(daily.id, raw.id)
            let dailyBatch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: daily.fileURL))
            XCTAssertEqual(dailyBatch.samples.map(\.value), [0])
            XCTAssertTrue(dailyBatch.sync.cursors.contains { $0.cursorKind == DailyProjectionObservation.cursorPrefix + "steps" })
            XCTAssertEqual(try fixture.pending(), admitted, "Only the separate daily ACK may retire the observer generation.")
            let dailyACK = try fixture.signedAcknowledgment(for: daily)
            try dailyACK.bytes.write(to: dailyACK.url, options: .atomic)
            await wakeMailboxAndWait(runtime, callback: try XCTUnwrap(fixture.mailboxObserver.onChange))
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
            XCTAssertTrue(try fixture.pending().isEmpty)
            XCTAssertNil(try fixture.stepCursor())
            XCTAssertFalse(proof.hasUploadedRecords(lane: .steps, receiverBindingID: binding))
        }
    }

    func testNativeMailboxUnknownRawACKCannotCoverNewObserverGeneration() async throws {
        let fixture = try NativeMailboxAutomaticFixture(unseededEmptyRaw: true)
        defer { fixture.cleanUp() }
        var dailyReadCount = 0
        let runtime = try makeNativeMailboxRuntime(fixture, readDailyActivityAggregates: { _, _, _, _ in
            dailyReadCount += 1
            return []
        })
        defer { runtime.automaticSyncRuntime.stopAdmission() }
        await runtime.bootstrap()
        for attempt in 1...2 {
            let runID = UUID()
            guard case .continueProcessing = runtime.viewModel.admitAutomaticSyncObserver(typeCode: "steps", diagnosticRunID: runID) else {
                return XCTFail("Each new observation generation must be admitted.")
            }
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observer(typeCode: "steps"), diagnosticRunID: runID)
            XCTAssertEqual(fixture.rawReadCount, attempt, "An older unknown-read ACK must not skip a newer generation's raw query.")
            XCTAssertEqual(dailyReadCount, 0)
            let raw = try XCTUnwrap(try fixture.outbox.pendingItems().first)
            let acknowledgment = try fixture.signedAcknowledgment(for: raw)
            try acknowledgment.bytes.write(to: acknowledgment.url, options: .atomic)
            await wakeMailboxAndWait(runtime, callback: try XCTUnwrap(fixture.mailboxObserver.onChange))
            XCTAssertFalse(try fixture.pending().isEmpty)
            XCTAssertNil(try fixture.stepCursor())
        }
    }

    func testIdleMailboxRejectsInvalidReceiptsAndStaleEpochThenFinalizesProducerCursor() async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let runtime = try makeNativeMailboxRuntime(fixture)
        defer { runtime.automaticSyncRuntime.stopAdmission() }
        await runtime.bootstrap()
        let runID = UUID()
        guard case .continueProcessing = runtime.viewModel.admitAutomaticSyncObserver(
            typeCode: "steps", diagnosticRunID: runID
        ) else { return XCTFail("Steps must be durably admitted.") }
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observer(typeCode: "steps"), diagnosticRunID: runID)
        let head = try XCTUnwrap(fixture.outbox.pendingItems().first)
        let admitted = try fixture.pending()
        let callback = try XCTUnwrap(fixture.mailboxObserver.onChange)
        let valid = try fixture.signedAcknowledgment(for: head)
        var tampered = valid.bytes
        tampered[tampered.count - 1] ^= 1
        let invalidReceipts = [
            Data("malformed synthetic receipt".utf8), tampered,
            try fixture.signedAcknowledgment(for: head, payloadDigest: String(repeating: "0", count: 64)).bytes,
            try fixture.signedAcknowledgment(for: head, generationOffset: 1).bytes,
        ]
        await wakeMailboxAndWait(runtime, callback: callback)
        for bytes in invalidReceipts {
            try bytes.write(to: valid.url, options: .atomic)
            await wakeMailboxAndWait(runtime, callback: callback)
            XCTAssertEqual(try fixture.outbox.deliveryState(for: head.id)?.phase, .published)
            XCTAssertEqual(try fixture.pending(), admitted)
            XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
            XCTAssertTrue(FileManager.default.fileExists(atPath: head.fileURL.path))
        }
        try valid.bytes.write(to: valid.url, options: .atomic)
        callback()
        await runtime.automaticSyncRuntime.cancelAndWait()
        XCTAssertEqual(try fixture.outbox.deliveryState(for: head.id)?.phase, .published)
        XCTAssertFalse(runtime.viewModel.automaticSyncOwnerIsActive)
        runtime.automaticSyncRuntime.activateIfReady(scheduleOutbox: false)
        callback()
        XCTAssertFalse(runtime.viewModel.automaticSyncOwnerIsActive, "An old observation epoch must not acquire an owner.")
        let current = try XCTUnwrap(fixture.mailboxObserver.onChange)
        await wakeMailboxAndWait(runtime, callback: current)
        XCTAssertEqual(try fixture.outbox.deliveryState(for: head.id)?.phase, .committedFinalized)
        XCTAssertEqual(try fixture.stepCursor(), fixture.nextAnchor)
        XCTAssertEqual(try fixture.pending(), admitted, "Raw receipt acceptance must retain the unfinished daily Steps obligation.")
        XCTAssertEqual(runtime.viewModel.pendingOutboxCount, 0)
        XCTAssertEqual(fixture.rawReadCount, 1, "Receipt wakes must never collect another payload.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: head.fileURL.path))
        let binding = try XCTUnwrap(head.mailboxBinding)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.outbox.directoryURL.appendingPathComponent(binding.envelopeFilename).path
        ))
    }

    func testIdleMailboxCallbackRejectsOFFAndChangedReceiverGeneration() async throws {
        for changeReceiver in [false, true] {
            try await assertIdleMailboxCallbackRejected(changeReceiver: changeReceiver)
        }
    }

    private func assertIdleMailboxCallbackRejected(changeReceiver: Bool) async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let runtime = try makeNativeMailboxRuntime(fixture)
        defer { runtime.automaticSyncRuntime.stopAdmission() }
        await runtime.bootstrap()
        let runID = UUID()
        _ = runtime.viewModel.admitAutomaticSyncObserver(typeCode: "steps", diagnosticRunID: runID)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observer(typeCode: "steps"), diagnosticRunID: runID)
        let head = try XCTUnwrap(fixture.outbox.pendingItems().first)
        let receipt = try fixture.signedAcknowledgment(for: head)
        try receipt.bytes.write(to: receipt.url, options: .atomic)
        let callback = try XCTUnwrap(fixture.mailboxObserver.onChange)
        let settings = fixture.makeSettingsStore()
        let oldGeneration = settings.receiverSettingsGenerationToken
        if changeReceiver {
            try settings.invalidateReceiverSettingsGeneration()
            XCTAssertNotEqual(settings.receiverSettingsGenerationToken, oldGeneration)
        } else {
            let disabled = expectation(description: "OFF joins delivery and native cleanup")
            let subscription = runtime.viewModel.objectWillChange
                .filter { runtime.viewModel.statusMessage == "Automatic sync is off. Sync Now still works." }
                .prefix(1).sink { _ in disabled.fulfill() }
            defer { subscription.cancel() }
            runtime.viewModel.requestBackgroundSyncEnabled(false)
            await runtime.automaticSyncRuntime.cancelAndWait()
            let result = await XCTWaiter.fulfillment(of: [disabled], timeout: 2)
            XCTAssertEqual(result, .completed)
            XCTAssertNil(fixture.mailboxObserver.onChange)
        }
        callback()
        XCTAssertFalse(runtime.viewModel.automaticSyncOwnerIsActive)
        XCTAssertEqual(try fixture.outbox.deliveryState(for: head.id)?.phase, .published)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: head.fileURL.path))
        XCTAssertEqual(fixture.rawReadCount, 1)
    }

    private func wakeMailboxAndWait(
        _ runtime: HealthBridgeCompanionApplicationRuntime,
        callback: @MainActor () -> Void
    ) async {
        let finished = expectation(description: "delivery-only owner finishes")
        let subscription = runtime.viewModel.$automaticSyncOwnerIsActive
            .dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        defer { subscription.cancel() }
        callback()
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    func testNativeMailboxColdBootstrapResumesDurablyAcknowledgedObserverWithoutAnotherTrigger() async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let bootstrapEntered = expectation(description: "actual bootstrap cleanup is blocked")
        let blocker = BlockingBootstrapCleanup(
            onStart: { bootstrapEntered.fulfill() }, onCancel: {}
        )
        defer { blocker.release() }
        let runtime = try makeNativeMailboxRuntime(
            fixture, cancelInheritedLegacyUploads: { await blocker.wait() }
        )
        defer { runtime.automaticSyncRuntime.stopAdmission() }
        let viewModel = runtime.viewModel
        let generation = viewModel.automaticSyncConnectionGeneration
        let delegate = HealthBridgeBackgroundURLSessionAppDelegate(applicationRuntime: runtime)

        XCTAssertTrue(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        XCTAssertNotNil(fixture.stepsObserver, "didFinishLaunching must synchronously prepare the real coordinator.")
        let entered = await XCTWaiter.fulfillment(of: [bootstrapEntered], timeout: 2)
        XCTAssertEqual(entered, .completed)
        guard entered == .completed else { return }
        XCTAssertFalse(viewModel.automaticSyncRuntimeIsReady)
        XCTAssertTrue(viewModel.automaticSyncObserverIsCurrent(
            expectedConnectionGeneration: generation, allowBeforeBootstrap: true
        ))
        XCTAssertFalse(viewModel.automaticSyncObserverIsCurrent(
            expectedConnectionGeneration: generation, allowBeforeBootstrap: false
        ))

        let acknowledged = expectation(description: "observer ACK sees durable admission before worker")
        let skipped = expectation(description: "real automatic owner finishes while bootstrap is blocked")
        let skippedSubscription = viewModel.$automaticSyncOwnerIsActive
            .dropFirst().filter { !$0 }.prefix(1).sink { _ in skipped.fulfill() }
        defer { skippedSubscription.cancel() }
        let suiteName = fixture.suiteName
        let outboxURL = fixture.outbox.directoryURL
        let acknowledgements = BootstrapInvocationRecorder()
        let (query, updateHandler) = try XCTUnwrap(fixture.stepsObserver)
        updateHandler(query, {
            acknowledgements.recordInvocation()
            do {
                let freshStore = BackgroundSyncSettingsStore(
                    userDefaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
                )
                XCTAssertEqual(try freshStore.loadPendingObserverTypeCodeGenerations(), ["steps": 1])
                XCTAssertNil(freshStore.lastRun, "Observer completion precedes the actual worker.")
                XCTAssertTrue(try FileOutbox(directory: outboxURL).pendingItems().isEmpty)
            } catch {
                XCTFail("Observer ACK did not observe durable admission: \(error)")
            }
            acknowledged.fulfill()
        }, nil)

        let blockedRun = await XCTWaiter.fulfillment(of: [acknowledged, skipped], timeout: 2)
        XCTAssertEqual(blockedRun, .completed)
        guard blockedRun == .completed else { return }
        XCTAssertEqual(acknowledgements.invocationCount, 1)
        XCTAssertEqual(BackgroundSyncSettingsStore(userDefaults: fixture.defaults).lastSkippedRun?.outcome, .skipped)
        XCTAssertFalse(viewModel.automaticSyncRuntimeIsReady)
        XCTAssertEqual(fixture.rawReadCount, 0)
        XCTAssertTrue(try FileOutbox(directory: outboxURL).pendingItems().isEmpty)
        let admitted = try fixture.pending()
        XCTAssertEqual(admitted, ["steps": 1])
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)

        let read = expectation(description: "bootstrap activation reaches the Steps reader")
        let collected = expectation(description: "bootstrap activation finishes real collection and publication")
        fixture.onRawRead = { read.fulfill() }
        let collectionSubscription = viewModel.$automaticSyncOwnerIsActive
            .dropFirst().filter { !$0 }.prefix(1).sink { _ in collected.fulfill() }
        defer { collectionSubscription.cancel() }

        blocker.release()
        await runtime.bootstrap()

        XCTAssertTrue(viewModel.automaticSyncRuntimeIsReady)
        XCTAssertEqual(viewModel.automaticSyncConnectionGeneration, generation)
        let resumed = await XCTWaiter.fulfillment(of: [read, collected], timeout: 2)
        XCTAssertEqual(resumed, .completed, "Bootstrap activation must collect retained observer work without another trigger.")
        XCTAssertEqual(fixture.rawReadCount, 1, "The already-ACKed observer must reach the real Steps reader after bootstrap.")
        XCTAssertEqual(try FileOutbox(directory: outboxURL).pendingItems().count, 1,
                       "Bootstrap activation must durably enqueue the retained mailbox work.")
        guard resumed == .completed else { return }
        XCTAssertEqual(acknowledgements.invocationCount, 1)
        try fixture.assertPublishedStepsAwaitingACK(admitted: admitted)
    }

    func testNativeMailboxPendingFIFOReconcilesWithoutCollectingAdmittedSteps() async throws {
        try await assertPublishedMailboxReconciles(idle: false)
    }

    func testNativeMailboxLateSignedACKWakesIdleOwnerWithoutCollection() async throws {
        try await assertPublishedMailboxReconciles(idle: true)
    }

    private func assertPublishedMailboxReconciles(idle: Bool) async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let runtime = try makeNativeMailboxRuntime(fixture)
        defer { runtime.automaticSyncRuntime.stopAdmission() }
        await runtime.bootstrap()
        let viewModel = runtime.viewModel
        XCTAssertTrue(viewModel.automaticSyncRuntimeIsReady)
        XCTAssertTrue(viewModel.usesMailboxTransport)
        let generation = viewModel.automaticSyncConnectionGeneration
        let record = try XCTUnwrap(fixture.connectionRecord)
        guard case .available(let identity) = record.mailboxIdentity else {
            return XCTFail("Canonical native mailbox identity must remain available.")
        }

        let window = HealthBridgeTimeWindow(
            startTime: "2023-11-14T22:13:20Z", endTime: "2023-11-14T22:14:20Z"
        )
        let source = HealthBridgeAppleHealthSource.phone
        let earlierBatch = HealthBridgeBatchV1(
            generatedAt: window.endTime, exportWindow: window,
            sources: [source], healthTypes: [.heartRate],
            samples: [HealthBridgeSample(
                clientRecordID: "synthetic-earlier-heart-rate", sourceKey: source.sourceKey,
                typeCode: HealthBridgeHealthType.heartRate.typeCode,
                startTime: window.startTime, endTime: window.endTime,
                value: 60, unit: HealthBridgeHealthType.heartRate.defaultUnit
            )],
            workouts: [], sleepSessions: [], deletedRecords: [],
            sync: HealthBridgeSyncContext(syncWindow: window, cursors: [])
        )
        let payload = try JSONEncoder().encode(earlierBatch)
        let earlier = try fixture.outbox.enqueue(payload, receiverIdentity: identity.opaqueBinding)
        XCTAssertNil(try FileOutbox(directory: fixture.outbox.directoryURL).pendingCursorCheckpoint())
        XCTAssertNil(earlier.mailboxBinding)
        XCTAssertEqual(fixture.rawReadCount, 0)
        let runID = UUID()
        guard case .continueProcessing = viewModel.admitAutomaticSyncObserver(
            typeCode: "steps", diagnosticRunID: runID
        ) else {
            return XCTFail("The persisted native mailbox must durably admit observer work.")
        }
        let admitted = try fixture.pending()
        XCTAssertEqual(admitted, ["steps": 1])
        var deliveryDiagnostics: [String] = []
        let subscription = viewModel.$mailboxDeliveryDiagnosticLine.dropFirst().sink {
            deliveryDiagnostics.append($0)
        }
        defer { subscription.cancel() }

        let opportunities: [AutomaticSyncReason] = [.observer(typeCode: "steps"), .launchCatchUp]
        for reason in opportunities {
            await runtime.automaticSyncRuntime.runAutomaticSync(
                reason: reason, diagnosticRunID: reason == .observer(typeCode: "steps") ? runID : UUID()
            )

            let freshOutbox = try FileOutbox(directory: fixture.outbox.directoryURL)
            XCTAssertEqual(fixture.rawReadCount, 0, "Pending FIFO delivery must defer the real Steps reader.")
            XCTAssertEqual(try freshOutbox.pendingItems().map(\.id), [earlier.id],
                           "An ordinary opportunity must not append a current batch behind the unacknowledged FIFO head.")
            XCTAssertNil(try freshOutbox.pendingCursorCheckpoint(), "Deferred collection must not stage a new Steps anchor.")
            XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
            XCTAssertEqual(try fixture.pending(), admitted)
            XCTAssertEqual(try fixture.makeSettingsStore().currentConnectionRecordV2(), record)
            XCTAssertEqual(viewModel.automaticSyncConnectionGeneration, generation)
        }

        XCTAssertTrue(deliveryDiagnostics.contains { $0.contains("phase=publish_fifo_head") })
        XCTAssertTrue(deliveryDiagnostics.contains { $0.contains("phase=reconcile_fifo_head_ack") })
        let retained = try XCTUnwrap(FileOutbox(directory: fixture.outbox.directoryURL).pendingItem(id: earlier.id))
        XCTAssertEqual(retained.deliveryState?.phase, .published)
        XCTAssertEqual(viewModel.pendingSyncSummary, "1 sync item(s) pending.")
        let binding = try XCTUnwrap(retained.mailboxBinding)
        let envelope = try Data(contentsOf: fixture.outbox.directoryURL.appendingPathComponent(binding.envelopeFilename))
        XCTAssertEqual(try Data(contentsOf: retained.fileURL), payload)
        XCTAssertNotEqual(envelope, payload)
        let locator = try MailboxLocatorV1.resolve(
            providerRoot: fixture.providerLocation.providerRoot,
            containerIdentifier: HealthBridgeAppIdentity.ubiquityContainerIdentifier,
            receiverComponent: identity.receiverID, deviceComponent: identity.deviceID,
            localRecordURL: fixture.providerLocation.localRecordURL
        )
        let published = try FileManager.default.contentsOfDirectory(
            at: XCTUnwrap(locator.lanes[.deliveries]), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(published.first)), envelope)
        let opened = try DeliveryProtocolV1.openDelivery(envelope, context: DeliveryEnvelopeOpenContext(
            receiverID: XCTUnwrap(Data(hexV1: identity.receiverID)),
            deviceID: XCTUnwrap(Data(hexV1: identity.deviceID)),
            connectionGeneration: Int64(identity.connectionGeneration),
            receiverAgreementPrivateKey: fixture.receiverAgreementKey,
            senderSigningPublicKey: Curve25519.Signing.PublicKey(
                rawRepresentation: fixture.keyStore.loadOrCreate().signingPublicKey
            )
        ))
        XCTAssertEqual(opened.plaintext, payload)
        XCTAssertEqual(try JSONDecoder().decode(HealthBridgeBatchV1.self, from: opened.plaintext), earlierBatch)

        let next = try fixture.outbox.enqueue(payload, receiverIdentity: identity.opaqueBinding)
        let tail = try fixture.outbox.enqueue(payload, receiverIdentity: identity.opaqueBinding)
        XCTAssertNotEqual(try XCTUnwrap(published.first).resourceValues(
            forKeys: [.ubiquitousItemIsUploadedKey]
        ).ubiquitousItemIsUploaded, true)
        let claims = try DeliveryProtocolV1.inspectDelivery(
            envelope, senderSigningPublicKey: Curve25519.Signing.PublicKey(
                rawRepresentation: fixture.keyStore.loadOrCreate().signingPublicKey
            )
        )
        let acknowledgment = try DeliveryProtocolV1.sealAck(
            DeliveryReceiptV1(
                result: .committed, payloadSHA256: opened.payloadSHA256,
                receiptID: 1, datasetGeneration: 1, committedAtMS: 1_700_000_061_000, errorCode: nil
            ),
            context: DeliveryAckSealContext(
                envelopeID: claims.envelopeID,
                receiverID: XCTUnwrap(Data(hexV1: identity.receiverID)),
                deviceID: XCTUnwrap(Data(hexV1: identity.deviceID)),
                connectionGeneration: Int64(identity.connectionGeneration),
                deviceAgreementPublicKey: Curve25519.KeyAgreement.PublicKey(
                    rawRepresentation: fixture.keyStore.loadOrCreate().agreementPublicKey
                ),
                receiverSigningPrivateKey: fixture.receiverSigningKey,
                receiverAgreementPrivateKey: fixture.receiverAgreementKey
            )
        )
        try acknowledgment.write(
            to: XCTUnwrap(locator.lanes[.acks]).appendingPathComponent(claims.envelopeID.hexV1 + ".hba"),
            options: .atomic
        )
        if idle {
            let finished = expectation(description: "late provider callback finishes the existing idle owner")
            var ownerStarts = 0
            let ownerSubscription = viewModel.$automaticSyncOwnerIsActive.dropFirst().sink { active in
                if active { ownerStarts += 1 } else { finished.fulfill() }
            }
            defer { ownerSubscription.cancel() }
            let callback = try XCTUnwrap(fixture.mailboxObserver.onChange)
            for _ in 0 ..< 20 { callback() }
            let result = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(result, .completed, "An idle provider change must reconcile without scene, HealthKit or manual work.")
            XCTAssertEqual(ownerStarts, 1, "Duplicate wakeups must share the existing single-flight owner.")
        } else {
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        }

        let afterACK = try FileOutbox(directory: fixture.outbox.directoryURL)
        XCTAssertEqual(try afterACK.deliveryState(for: earlier.id)?.phase, .committedFinalized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.outbox.directoryURL.appendingPathComponent(binding.envelopeFilename).path
        ))
        XCTAssertEqual(try afterACK.pendingItems().map(\.id), [next.id, tail.id])
        XCTAssertEqual(viewModel.pendingOutboxCount, 2)
        XCTAssertEqual(viewModel.pendingSyncSummary, "2 sync item(s) pending.")
        XCTAssertNotNil(try afterACK.pendingItem(id: next.id)?.mailboxBinding,
                        "An authenticated retirement must publish the next existing FIFO head in the same opportunity.")
        XCTAssertEqual(try afterACK.pendingItem(id: next.id)?.deliveryState?.phase, .published)
        XCTAssertNil(try afterACK.pendingItem(id: tail.id)?.mailboxBinding,
                     "The handoff must stop at the next unacknowledged head, not flush or poll the tail.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: XCTUnwrap(locator.lanes[.deliveries]), includingPropertiesForKeys: nil
        ).count, 2)
        XCTAssertEqual(fixture.rawReadCount, 0, "Delivery progress must not re-enter HealthKit collection.")
        XCTAssertEqual(try fixture.pending(), admitted)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        XCTAssertEqual(try fixture.makeSettingsStore().currentConnectionRecordV2(), record)
        XCTAssertEqual(viewModel.automaticSyncConnectionGeneration, generation)
    }

    func testNativeMailboxForegroundDefersLaterACKUntilEarlierTransactionIsConfirmed() async throws {
        for keepProviderACK in [true, false] {
            let fixture = try NativeMailboxAutomaticFixture()
            defer { fixture.cleanUp() }
            let record = try XCTUnwrap(fixture.connectionRecord)
            guard case .available(let identity) = record.mailboxIdentity else {
                return XCTFail("The native connection must be available without a receiver URL.")
            }
            let cursorStore = try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json"))
            let delivery = ProductionMailboxDelivery(
                settingsStore: fixture.makeSettingsStore(), outbox: fixture.outbox,
                cursorStore: cursorStore, keyStore: fixture.keyStore,
                providerLocation: fixture.providerLocation
            )
            let payload = Data("synthetic-foreground-mailbox-payload".utf8)
            var items: [FileOutboxItem] = []
            for value in ["first-v1", "second-v1"] {
                let checkpoint = FileOutboxCursorCheckpoint(
                    receiverIdentity: identity.opaqueBinding, sourceKey: "synthetic-source",
                    cursorKind: "synthetic-anchor", cursorValue: value
                )
                items.append(try XCTUnwrap(fixture.outbox.enqueueSequence(
                    [payload], receiverIdentity: identity.opaqueBinding, cursorCheckpoint: checkpoint
                ).first))
            }
            let first = items[0]
            let later = items[1]
            let published = try await delivery.deliverPending()
            XCTAssertEqual(published.waitingCount, 2)
            let device = try fixture.keyStore.loadOrCreate()
            let locator = try MailboxLocatorV1.resolve(
                providerRoot: fixture.providerLocation.providerRoot,
                containerIdentifier: HealthBridgeAppIdentity.ubiquityContainerIdentifier,
                receiverComponent: identity.receiverID, deviceComponent: identity.deviceID,
                localRecordURL: fixture.providerLocation.localRecordURL
            )
            var acknowledgments: [URL: Data] = [:]
            for (index, item) in items.enumerated() {
                let state = try XCTUnwrap(fixture.outbox.deliveryState(for: item.id))
                XCTAssertEqual(state.phase, .published)
                _ = try fixture.outbox.compareAndSetDeliveryState(
                    itemID: item.id, expected: state,
                    updated: .stable(.providerObserved, ownership: XCTUnwrap(state.ownership))
                )
                let binding = try XCTUnwrap(fixture.outbox.pendingItem(id: item.id)?.mailboxBinding)
                let envelope = try Data(contentsOf: fixture.outbox.directoryURL.appendingPathComponent(binding.envelopeFilename))
                let claims = try DeliveryProtocolV1.inspectDelivery(
                    envelope, senderSigningPublicKey: Curve25519.Signing.PublicKey(rawRepresentation: device.signingPublicKey)
                )
                let ack = try DeliveryProtocolV1.sealAck(
                    DeliveryReceiptV1(
                        result: .committed, payloadSHA256: claims.payloadSHA256,
                        receiptID: Int64(index + 1), datasetGeneration: 1,
                        committedAtMS: 1_700_000_061_000, errorCode: nil
                    ),
                    context: DeliveryAckSealContext(
                        envelopeID: claims.envelopeID,
                        receiverID: XCTUnwrap(Data(hexV1: identity.receiverID)),
                        deviceID: XCTUnwrap(Data(hexV1: identity.deviceID)),
                        connectionGeneration: Int64(identity.connectionGeneration),
                        deviceAgreementPublicKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.agreementPublicKey),
                        receiverSigningPrivateKey: fixture.receiverSigningKey,
                        receiverAgreementPrivateKey: fixture.receiverAgreementKey
                    )
                )
                let path = try XCTUnwrap(locator.lanes[.acks]).appendingPathComponent(claims.envelopeID.hexV1 + ".hba")
                acknowledgments[path] = ack
                if item.id == later.id { try ack.write(to: path, options: .atomic) }
            }

            let waiting = try await delivery.deliverPending()
            XCTAssertEqual(waiting.finalizedCount, 0)
            XCTAssertEqual(waiting.waitingCount, 2)
            let retained = try FileOutbox(directory: fixture.outbox.directoryURL)
            XCTAssertEqual(try retained.pendingItems().map(\.id), items.map(\.id))
            XCTAssertEqual(try retained.deliveryState(for: later.id)?.phase, .providerObserved,
                           "A later ACK must not be consumed before the FIFO head is confirmed.")
            XCTAssertNil(try cursorStore.cursorValue(
                receiverBindingID: identity.opaqueBinding, sourceKey: "synthetic-source", cursorKind: "synthetic-anchor"
            ))
            let headACK = try XCTUnwrap(acknowledgments.first {
                !FileManager.default.fileExists(atPath: $0.key.path)
            })
            let components = try ProductionMailboxComponents.make(
                settingsStore: fixture.makeSettingsStore(), outbox: fixture.outbox,
                keyStore: fixture.keyStore, providerLocation: fixture.providerLocation
            )
            let event = try XCTUnwrap(components.scanner.scan().events.first)
            let state = try XCTUnwrap(fixture.outbox.deliveryState(for: later.id))
            let legacy = OutboxDeliveryCoordinator(
                outbox: fixture.outbox, transport: components.transport, scanner: components.scanner,
                ownership: try XCTUnwrap(state.ownership),
                finalizer: OutboxDeliveryCursorFinalizer(outbox: fixture.outbox, cursorStore: cursorStore)
            )
            XCTAssertEqual(try legacy.consume(event, itemID: later.id), .ackVerified)
            XCTAssertThrowsError(try legacy.finalizeCommitted(itemID: later.id)) {
                XCTAssertEqual($0 as? FileOutboxCursorCheckpointError, .pendingCommit)
            }
            if !keepProviderACK {
                for path in acknowledgments.keys where path != headACK.key {
                    try FileManager.default.removeItem(at: path)
                }
            }
            let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
            XCTAssertEqual(try reopened.deliveryState(for: later.id)?.phase, .ackVerified)
            try BackgroundSyncSettingsStore(userDefaults: fixture.defaults).setEnabledDurably(false)
            let presentation = try makeNativeMailboxRuntime(fixture)
            await presentation.bootstrap()
            XCTAssertEqual(presentation.viewModel.pendingOutboxCount, 2)
            XCTAssertEqual(presentation.viewModel.pendingSyncSummary, "2 sync item(s) pending.")
            presentation.automaticSyncRuntime.stopAdmission()

            let replay = ProductionMailboxDelivery(
                settingsStore: fixture.makeSettingsStore(), outbox: reopened,
                cursorStore: try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json")),
                keyStore: fixture.keyStore, providerLocation: fixture.providerLocation
            )
            try headACK.value.write(to: headACK.key, options: .atomic)
            let accepted = try await replay.deliverPending()
            XCTAssertEqual(accepted.finalizedCount, 2)
            XCTAssertEqual(accepted.waitingCount, 0)
            let finalized = try FileOutbox(directory: fixture.outbox.directoryURL)
            XCTAssertTrue(try finalized.pendingItems().isEmpty)
            for item in [first, later] {
                XCTAssertEqual(try finalized.deliveryState(for: item.id)?.phase, .committedFinalized)
                XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
            }
            XCTAssertEqual(try cursorStore.cursorValue(
                receiverBindingID: identity.opaqueBinding, sourceKey: "synthetic-source", cursorKind: "synthetic-anchor"
            ), "second-v1")
            XCTAssertEqual(try fixture.makeSettingsStore().currentConnectionRecordV2(), record)
        }
    }

    func testNativeMailboxCleanupAdvancesPastForeignEntriesAcrossRestart() async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.makeSettingsStore()
        let connection = try settings.currentConnectionRecordV2()
        let binding = try XCTUnwrap(settings.receiverBindingID)
        let item = try XCTUnwrap(fixture.outbox.enqueueSequence(
            [Data("synthetic-cleanup".utf8)], receiverIdentity: binding
        ).first)
        func delivery() throws -> ProductionMailboxDelivery {
            ProductionMailboxDelivery(
                settingsStore: settings,
                outbox: try FileOutbox(directory: fixture.outbox.directoryURL),
                cursorStore: try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json")),
                pendingGenerationStore: BackgroundSyncSettingsStore(
                    userDefaults: try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
                ),
                keyStore: fixture.keyStore, providerLocation: fixture.providerLocation
            )
        }
        _ = try await delivery().deliverPending()
        let published = try XCTUnwrap(fixture.outbox.pendingItem(id: item.id))
        let ack = try fixture.signedAcknowledgment(for: published)
        let lane = ack.url.deletingLastPathComponent()
        for index in 0..<MailboxAckScanner.maximumEnumerationEntries {
            try Data("foreign".utf8).write(to: lane.appendingPathComponent("foreign-\(index)"))
        }
        try ack.bytes.write(to: ack.url)
        let components = try ProductionMailboxComponents.make(
            settingsStore: settings, outbox: fixture.outbox,
            keyStore: fixture.keyStore, providerLocation: fixture.providerLocation
        )
        func laneState() throws -> MailboxAckDirectoryState {
            let directory = try MailboxAckFileReader.openDirectory(lane)
            defer { _ = close(directory) }
            return try MailboxAckFileReader.directoryState(directory)
        }
        let unchanged = try laneState()
        _ = try components.locate()
        XCTAssertEqual(try laneState(), unchanged,
                       "Resolving an already private lane must not invalidate its scan checkpoint.")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lane.path)
        _ = try components.locate()
        let repairedPermissions = try FileManager.default.attributesOfItem(atPath: lane.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(repairedPermissions?.uint16Value, 0o700)
        let repaired = try laneState()
        _ = try components.locate()
        XCTAssertEqual(try laneState(), repaired)
        // A stable directory must be covered once across reopened, bounded windows.
        // This catches repeated foreign entries even when the ACK is in the first window.
        var checkpoint: String?
        var inspected = 0
        var foreignCount = 0
        var acknowledgmentNames: [String] = []
        let entryCount = MailboxAckScanner.maximumEnumerationEntries + 1
        while inspected < entryCount {
            let window = try components.scanner.candidateWindow(
                maximumEntries: MailboxAckScanner.maximumScanFiles,
                afterCheckpoint: checkpoint
            )
            guard window.inspectedEntryCount > 0 else {
                XCTFail("Reopened traversal must make progress before the directory is covered.")
                break
            }
            XCTAssertLessThanOrEqual(window.inspectedEntryCount, MailboxAckScanner.maximumScanFiles)
            inspected += window.inspectedEntryCount
            foreignCount += window.invalidNameCount
            acknowledgmentNames += window.fileNames
            checkpoint = try XCTUnwrap(window.nextCheckpoint)
        }
        XCTAssertEqual(inspected, entryCount)
        XCTAssertEqual(foreignCount, MailboxAckScanner.maximumEnumerationEntries)
        XCTAssertEqual(acknowledgmentNames, [ack.url.lastPathComponent])
        let accepted = try await delivery().deliverPending()
        XCTAssertEqual(accepted.finalizedCount, 1)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        let committed = try XCTUnwrap(fixture.outbox.deliveryState(for: item.id))
        XCTAssertEqual(committed.phase, .committedFinalized)
        XCTAssertNotNil(committed.committedReceipt)
        for _ in 0..<6 where FileManager.default.fileExists(atPath: ack.url.path) {
            let result = try await delivery().deliverPending()
            XCTAssertLessThanOrEqual(result.scannedFinalCount, MailboxAckScanner.maximumScanFiles)
            XCTAssertEqual(result.ackCleanupFailureCount, 0)
            XCTAssertEqual(result.finalizedCount, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ack.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lane.path).count,
                       MailboxAckScanner.maximumEnumerationEntries)
        XCTAssertEqual(try Data(contentsOf: lane.appendingPathComponent("foreign-0")), Data("foreign".utf8))
        XCTAssertEqual(try settings.currentConnectionRecordV2(), connection)
        XCTAssertEqual(try fixture.outbox.deliveryState(for: item.id), committed)
    }

    func testInjectedBackgroundRefreshSchedulerRecordsRequestConsumptionCancellationAndClosedAdmission() async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let scheduler = RecordingBackgroundRefreshScheduler()
        let runtime = try makeNativeMailboxRuntime(fixture, backgroundRefreshScheduler: scheduler)
        await runtime.bootstrap()
        XCTAssertGreaterThan(scheduler.requestCount, 0, "Ready bootstrap must still request its next refresh.")
        let requestsBefore = scheduler.requestCount
        await runtime.automaticSyncRuntime.handleBackgroundRefresh()
        XCTAssertEqual(scheduler.consumedCount, 1)
        XCTAssertGreaterThan(scheduler.requestCount, requestsBefore, "A consumed refresh requests its successor.")
        runtime.automaticSyncRuntime.stopAdmission()
        XCTAssertGreaterThan(scheduler.cancelCount, 0)

        let closedSuiteName = "SchedulerClosed.\(UUID().uuidString)"
        let closedDefaults = try XCTUnwrap(UserDefaults(suiteName: closedSuiteName))
        defer { closedDefaults.removePersistentDomain(forName: closedSuiteName) }
        let closedViewModel = try makeViewModel(
            root: fixture.root.appendingPathComponent("closed"),
            defaults: closedDefaults,
            settingsStore: ReceiverSettingsStore(userDefaults: closedDefaults,
                tokenStore: MemoryReceiverTokenStore(), preCutoverBackupStore: MemoryReceiverTokenStore(),
                synchronize: { true }),
            pairingStateStore: ReceiverPairingStateStore(pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(), cancellationStore: MemoryReceiverTokenStore()),
            outbox: try FileOutbox(directory: fixture.root.appendingPathComponent("closed-outbox"))
        )
        let closedScheduler = RecordingBackgroundRefreshScheduler()
        let closed = AutomaticSyncRuntime(viewModel: closedViewModel,
            backgroundDeliveryCoordinator: fixture.makeCoordinator(),
            mailboxChangeObserver: fixture.mailboxObserver,
            backgroundRefreshScheduler: closedScheduler)
        closed.prepareForBackgroundLaunch()
        closed.activateIfReady()
        XCTAssertEqual(closedScheduler.requestCount, 0, "Closed admission must not submit a refresh.")
        closed.stopAdmission()
        XCTAssertEqual(closedScheduler.cancelCount, 1)
    }

    private func makeNativeMailboxRuntime(
        _ fixture: NativeMailboxAutomaticFixture,
        cancelInheritedLegacyUploads: @escaping @MainActor () async -> BackgroundUploadCancellationResult = {
            BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
        },
        backgroundRefreshScheduler: RecordingBackgroundRefreshScheduler = RecordingBackgroundRefreshScheduler(),
        readDailyActivityAggregates: (@MainActor ([String], Date, Date, Calendar) async throws -> [HealthKitDailyActivityAggregate])? = nil
    ) throws -> HealthBridgeCompanionApplicationRuntime {
        let viewModel = try makeViewModel(
            root: fixture.root,
            defaults: fixture.defaults,
            settingsStore: fixture.makeSettingsStore(),
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { "synthetic-native-mailbox-installation" }
            ),
            outbox: fixture.outbox,
            mailboxKeyStore: fixture.keyStore,
            mailboxProviderLocation: fixture.providerLocation,
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                fileURL: fixture.root.appendingPathComponent("diagnostics.json")
            ),
            readAnchoredStepChanges: { anchor, start, receivedAt in
                try fixture.readSteps(anchor: anchor, start: start, receivedAt: receivedAt)
            },
            automaticSyncEligibleTypeCodesForTesting: ["steps"],
            readDailyActivityAggregates: { types, start, end, calendar in
                if let readDailyActivityAggregates {
                    return try await readDailyActivityAggregates(types, start, end, calendar)
                }
                XCTFail("Raw mailbox Steps must await receiver ACK before daily coverage.")
                return []
            },
            cancelInheritedLegacyUploads: cancelInheritedLegacyUploads
        )
        return HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel,
            backgroundDeliveryCoordinator: fixture.makeCoordinator(),
            mailboxChangeObserver: fixture.mailboxObserver,
            backgroundRefreshScheduler: backgroundRefreshScheduler
        )
    }

    func testAutomaticUnknownRawReadACKIsSeparateFromAuthoritativeZero() async throws {
        let fixture = try AutomaticStepsFaultFixture(hasModernCoverage: false, hasRawUploadProof: false)
        defer { fixture.cleanUp() }
        fixture.completedStepsValue = 0
        let runtime = try await makeStepsFaultRuntime(fixture, eligibleTypeCodes: ["steps"])
        _ = try fixture.admit(["steps"])
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        let batches = try fixture.recorder.acceptedPayloads.map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
        }
        XCTAssertEqual(batches.count, 2, "Unknown raw observation and authoritative statistics need independent ACKs.")
        let raw = try XCTUnwrap(batches.first)
        XCTAssertTrue(raw.samples.isEmpty)
        XCTAssertTrue(raw.deletedRecords.isEmpty)
        XCTAssertFalse(raw.sync.cursors.contains { $0.cursorKind == StepCountSyncBatchFactory.anchoredCursorKind })
        XCTAssertTrue(raw.sync.cursors.contains { $0.cursorKind == DailyProjectionObservation.cursorPrefix + "steps" })
        XCTAssertEqual(batches.last?.samples.map(\.value), [0])
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor, "Unknown raw read cannot advance the raw anchor.")
        XCTAssertTrue(try fixture.pending().isEmpty)
        attachSyntheticWire(fixture.recorder.acceptedPayloads, name: "unknown-raw-zero")
    }

    func testAutomaticLegacyStepsPreservesACKedAnchorForDeletionBeforeZero() async throws {
        let fixture = try AutomaticStepsFaultFixture(hasModernCoverage: false)
        defer { fixture.cleanUp() }
        fixture.omitRawAdditions = true
        fixture.deleteOnFirstRead = true
        fixture.completedStepsValue = 0
        let runtime = try await makeStepsFaultRuntime(fixture, eligibleTypeCodes: ["steps"])
        _ = try fixture.admit(["steps"])
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        XCTAssertEqual(fixture.rawAnchors.first, fixture.previousAnchor,
            "An ACKed legacy anchor must preserve deletion delivery.")
        let batches = try fixture.recorder.acceptedPayloads.map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
        }
        XCTAssertEqual(batches.first?.deletedRecords.count, 1)
        XCTAssertEqual(batches.last?.samples.map(\.value), [0])
        attachSyntheticWire(fixture.recorder.acceptedPayloads, name: "legacy-deletion-zero")
    }

    private func attachSyntheticWire(_ payloads: [Data], name: String) {
        for (index, payload) in payloads.enumerated() {
            let attachment = XCTAttachment(data: payload, uniformTypeIdentifier: "public.json")
            attachment.name = name + "-" + String(index)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testAutomaticStepsZeroCarriesCausalObservationAfterRawACK() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.completedStepsValue = 0
        let runtime = try await makeStepsFaultRuntime(fixture, eligibleTypeCodes: ["steps"])
        let generations = try fixture.admit(["steps"])
        fixture.inspectBeforeACK(eligible: ["steps"], admitted: generations, acceptedBefore: 0, opportunity: 1)
        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observer(typeCode: "steps"), diagnosticRunID: UUID()
        )
        let batches = try fixture.recorder.acceptedPayloads.map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
        }
        XCTAssertEqual(batches.count, 2)
        let daily = try XCTUnwrap(batches.last)
        XCTAssertEqual(daily.samples.map(\.value), [0])
        XCTAssertTrue(daily.sync.cursors.contains {
            $0.cursorKind == "daily_projection_observation:steps"
        }, "A completed zero must carry its scoped causal observation on the actual wire.")
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(try fixture.pending().isEmpty)
    }

    func testAutomaticStepsUnknownStatisticsSendsScopeWithoutInventingZero() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.unknownStepsStatistics = true
        fixture.omitRawAdditions = true
        fixture.deleteOnFirstRead = true
        let runtime = try await makeStepsFaultRuntime(fixture, eligibleTypeCodes: ["steps"])
        _ = try fixture.admit(["steps"])
        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .scheduledRefresh, diagnosticRunID: UUID()
        )
        let batches = try fixture.recorder.acceptedPayloads.map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
        }
        XCTAssertEqual(batches.count, 2, "Raw ACK cannot complete the separate unknown-day observation.")
        let daily = try XCTUnwrap(batches.last)
        XCTAssertTrue(daily.samples.isEmpty)
        XCTAssertTrue(daily.deletedRecords.isEmpty)
        XCTAssertTrue(daily.sync.cursors.contains {
            $0.cursorKind == "daily_projection_observation:steps"
        })
        XCTAssertTrue(try fixture.pending().isEmpty)
        fixture.unknownStepsStatistics = false
        fixture.completedStepsValue = 0
        _ = try fixture.admit(["steps"])
        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .launchCatchUp, diagnosticRunID: UUID()
        )
        let restored = try JSONDecoder().decode(HealthBridgeBatchV1.self,
            from: XCTUnwrap(fixture.recorder.acceptedPayloads.last))
        XCTAssertEqual(restored.samples.map(\.value), [0])
        for (index, payload) in fixture.recorder.acceptedPayloads.enumerated() {
            let attachment = XCTAttachment(data: payload, uniformTypeIdentifier: "public.json")
            attachment.name = "synthetic-deletion-unknown-zero-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testManualStepsRawAndDailyOperationsKeepACKsSeparate() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.completedStepsValue = 0
        let runtime = try await makeStepsFaultRuntime(fixture, eligibleTypeCodes: ["steps"])
        let rawAccepted = await runtime.viewModel.syncRecentStepCounts()
        XCTAssertTrue(rawAccepted)
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        let dailyAccepted = await runtime.viewModel.syncDailyActivityAggregates(typeCodes: ["steps"])
        XCTAssertTrue(dailyAccepted)
        XCTAssertEqual(fixture.authorizationRequests, [["steps"], ["steps"]])
        let batches = try fixture.recorder.acceptedPayloads.map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
        }
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].samples.first?.metadata["sample_kind"], "raw_quantity")
        XCTAssertEqual(batches[1].samples.map(\.value), [0])
        XCTAssertEqual(batches[1].samples.first?.metadata["sample_kind"], "daily_aggregate")
    }

    func testAutomaticNonStepsActivityReadsRawBeforeDailyForEveryTrigger() async throws {
        for reason in [AutomaticSyncReason.observer(typeCode: "basal_energy"),
                       .observerBatch(typeCodes: ["basal_energy"]), .scheduledRefresh, .launchCatchUp] {
            let fixture = try AutomaticStepsFaultFixture()
            defer { fixture.cleanUp() }
            let runtime = try await makeStepsFaultRuntime(fixture, eligibleTypeCodes: ["basal_energy"])
            _ = try fixture.admit(["basal_energy"])
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: reason, diagnosticRunID: UUID())
            XCTAssertEqual(fixture.quantityRawRequests, ["basal_energy"])
            let batches = try fixture.recorder.acceptedPayloads.map {
                try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
            }
            XCTAssertEqual(batches.count, 2)
            XCTAssertEqual(batches.first?.samples.first?.metadata["sample_kind"], "raw_quantity")
            XCTAssertEqual(batches.last?.samples.first?.metadata["sample_kind"], "daily_aggregate")
            XCTAssertTrue(try fixture.pending().isEmpty)
        }
    }

    func testAutomaticSyncDefaultEligibleTypesMatchRuntimeCatalog() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        let runtime = try await makeStepsFaultRuntime(fixture)
        XCTAssertEqual(
            runtime.viewModel.automaticSyncSelectedEligibleTypeCodes(),
            HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
    }

    func testAutomaticStepsTriggerInputMatrixAcceptsRawAndFreshCompletedDay() async throws {
        for eligible in [["steps"], ["basal_energy", "steps"]] {
            let input = eligible.count == 1 ? "steps" : "steps_and_basal_energy"
            let triggers: [(String, AutomaticSyncReason, AutomaticSyncDiagnosticTriggerReason)] = [
                ("observer", .observer(typeCode: "steps"), .observer),
                ("observerBatch", .observerBatch(typeCodes: Array(eligible.reversed()) + eligible), .observerBatch),
                ("scheduledRefresh", .scheduledRefresh, .scheduledRefresh),
                ("launchCatchUp", .launchCatchUp, .launchCatchUp),
            ]
            for (trigger, reason, diagnosticReason) in triggers {
                let fixture = try AutomaticStepsFaultFixture()
                defer { fixture.cleanUp() }
                let runtime = try await makeStepsFaultRuntime(fixture, eligibleTypeCodes: eligible)
                XCTAssertEqual(runtime.viewModel.automaticSyncSelectedEligibleTypeCodes(), eligible)
                let processed = trigger == "observer" ? ["steps"] : eligible
                for opportunity in 1...2 {
                    let scenario = "\(trigger)/\(input)/opportunity_\(opportunity)"
                    fixture.completedStepsValue = opportunity == 1 ? 4_321 : 5_432
                    fixture.completedBasalEnergyValue = opportunity == 1 ? 345 : 456
                    if reason == .observer(typeCode: "steps") || diagnosticReason == .observerBatch {
                        if opportunity == 1 || diagnosticReason == .observerBatch {
                            _ = try fixture.admit(eligible)
                        } else {
                            try BackgroundSyncSettingsStore(
                                userDefaults: XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
                            ).markPendingObserverTypeCodes(["steps"])
                        }
                    } else {
                        XCTAssertTrue(try fixture.pending().isEmpty, scenario)
                    }
                    let admitted = try fixture.pending()
                    let acceptedBefore = fixture.recorder.acceptedPayloads.count
                    let inspectionsBefore = fixture.recorder.responseInspectionCount
                    let dailyReadsBefore = fixture.dailyRequests.count
                    fixture.inspectBeforeACK(
                        eligible: eligible, admitted: admitted,
                        acceptedBefore: acceptedBefore, opportunity: opportunity
                    )
                    let runID = UUID()

                    await runtime.automaticSyncRuntime.runAutomaticSync(reason: reason, diagnosticRunID: runID)

                    let diagnostic = try XCTUnwrap(AutomaticSyncDiagnosticStore(
                        fileURL: fixture.root.appendingPathComponent("diagnostics.json")
                    ).latestRecord)
                    XCTAssertEqual(diagnostic.runID, runID, scenario)
                    XCTAssertEqual(diagnostic.triggerReason, diagnosticReason, scenario)
                    XCTAssertEqual(diagnostic.admissionResult, .accepted, scenario)
                    XCTAssertNil(diagnostic.failure, scenario)
                    XCTAssertEqual(
                        Array(fixture.dailyRequests.dropFirst(dailyReadsBefore)).map { $0.joined(separator: ",") }.sorted(),
                        processed.sorted(), scenario
                    )
                    XCTAssertEqual(fixture.rawAnchors, opportunity == 1
                        ? [fixture.previousAnchor] : [fixture.previousAnchor, fixture.currentAnchor], scenario)
                    let payloads = Array(fixture.recorder.acceptedPayloads.dropFirst(acceptedBefore))
                    let expectedRawTypes = processed.filter { $0 != "steps" || opportunity == 1 }.sorted()
                    XCTAssertEqual(payloads.count, processed.count + expectedRawTypes.count, scenario)
                    XCTAssertEqual(fixture.recorder.responseInspectionCount - inspectionsBefore, payloads.count, scenario)
                    XCTAssertEqual(fixture.recorder.payloads, fixture.recorder.acceptedPayloads, scenario)
                    let batches = try payloads.map { try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0) }
                    XCTAssertTrue(batches.allSatisfy { $0.samples.count == 1 }, scenario)
                    let samples = batches.flatMap(\.samples)
                    let raw = samples.filter { $0.metadata["sample_kind"] == "raw_quantity" }
                    let daily = samples.filter { $0.metadata["sample_kind"] == "daily_aggregate" }
                    XCTAssertEqual(raw.map(\.typeCode).sorted(), expectedRawTypes, scenario)
                    XCTAssertEqual(raw.filter { $0.typeCode == "steps" }.map(\.value),
                        opportunity == 1 ? [17] : [], scenario)
                    XCTAssertEqual(raw.filter { $0.typeCode == "basal_energy" }.map(\.value),
                        processed.contains("basal_energy") ? [345] : [], scenario)
                    for sample in raw {
                        XCTAssertEqual(sample.unit, sample.typeCode == "steps" ? "count" : "kcal", scenario)
                        XCTAssertEqual(sample.sourceKey, HealthBridgeAppleHealthSource.phone.sourceKey, scenario)
                        XCTAssertLessThan(sample.startTime, sample.endTime, scenario)
                    }
                    XCTAssertEqual(daily.map(\.typeCode).sorted(), processed.sorted(), scenario)
                    XCTAssertEqual(raw.count + daily.count, samples.count, scenario)
                    let expected = try XCTUnwrap(fixture.completedStepsDay)
                    for sample in daily {
                        XCTAssertEqual(sample.value, sample.typeCode == "steps"
                            ? fixture.completedStepsValue : fixture.completedBasalEnergyValue, scenario)
                        XCTAssertEqual(sample.unit, sample.typeCode == "steps" ? "count" : "kcal", scenario)
                        XCTAssertEqual(sample.startTime, HealthBridgeUTCFormatter.string(from: expected.dayStart), scenario)
                        XCTAssertEqual(sample.endTime, HealthBridgeUTCFormatter.string(from: expected.dayEnd), scenario)
                        XCTAssertEqual(sample.metadata["aggregation"], "daily_sum", scenario)
                        XCTAssertEqual(sample.metadata["aggregation_completeness"], "complete", scenario)
                        XCTAssertEqual(sample.metadata["source_resolution"], "healthkit_statistics_merged_sources", scenario)
                        XCTAssertEqual(sample.metadata["calendar_day"], expected.calendarDay, scenario)
                        XCTAssertEqual(sample.metadata["time_zone_identifier"], Calendar.current.timeZone.identifier, scenario)
                        let day = try XCTUnwrap(expected.calendarDay).replacingOccurrences(of: "-", with: "")
                        let recordType = sample.typeCode == "steps" ? "steps" : "basal-energy"
                        XCTAssertEqual(sample.clientRecordID, "hk-daily-activity-\(recordType)-\(day)", scenario)
                    }
                    XCTAssertFalse(samples.contains { $0.value == 99 }, "Incomplete today must be excluded: \(scenario)")
                    let allRaw = try fixture.acceptedSamples(kind: "raw_quantity")
                    let allDaily = try fixture.acceptedSamples(kind: "daily_aggregate")
                    XCTAssertEqual(allRaw.filter { $0.typeCode == "steps" }.map(\.value), [17], scenario)
                    XCTAssertEqual(allRaw.filter { $0.typeCode == "basal_energy" }.map(\.value),
                        processed.contains("basal_energy") ? Array(repeating: 345.0, count: opportunity) : [], scenario)
                    XCTAssertEqual(allRaw.count, 1 + (processed.contains("basal_energy") ? opportunity : 0), scenario)
                    XCTAssertTrue(Set(allRaw.map(\.clientRecordID)).isDisjoint(with: allDaily.map(\.clientRecordID)), scenario)
                    XCTAssertEqual(allDaily.filter { $0.typeCode == "steps" }.map(\.value),
                        opportunity == 1 ? [4_321] : [4_321, 5_432], scenario)
                    XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor, scenario)
                    let remaining = try fixture.pending()
                    XCTAssertEqual(remaining, trigger == "observer" ? admitted.filter { $0.key == "basal_energy" } : [:], scenario)
                    XCTAssertEqual(diagnostic.remainingPendingLaneCount, remaining.count, scenario)
                    XCTAssertTrue(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty, scenario)
                    print("ISSUE58_MATRIX \(scenario)")
                }
            }
        }
    }

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
        let acceptedRaw = try fixture.acceptedSamples(kind: "raw_quantity")
        XCTAssertEqual(acceptedRaw.map(\.typeCode).sorted(), [otherType, "steps"])
        XCTAssertEqual(acceptedRaw.filter { $0.typeCode == "steps" }.map(\.value), [17])
        XCTAssertEqual(acceptedRaw.filter { $0.typeCode == otherType }.map(\.value), [345])
        XCTAssertEqual(acceptedRaw.first { $0.typeCode == otherType }?.unit, "kcal")
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
        _ fixture: AutomaticStepsFaultFixture,
        eligibleTypeCodes: [String]? = nil
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
            requestReadAuthorization: { types in fixture.authorizationRequests.append(types) },
            readAnchoredQuantityChanges: { type, anchor, start, receivedAt in
                fixture.quantityRawRequests.append(type)
                let previousDay = Calendar.current.startOfDay(for: receivedAt).addingTimeInterval(-86_400)
                return HealthKitAnchoredQuantityChanges(
                    typeCode: type,
                    samples: [HealthKitQuantitySampleSummary(
                        uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000063")),
                        typeCode: type, start: previousDay.addingTimeInterval(3600),
                        end: previousDay.addingTimeInterval(3660), value: 345
                    )], deletedSamples: [], anchorCursorValue: fixture.currentAnchor,
                    windowStart: start ?? previousDay, windowEnd: receivedAt
                )
            },
            automaticSyncEligibleTypeCodesForTesting: eligibleTypeCodes,
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
        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").filter {
            $0.typeCode == "steps"
        }.map(\.value), [17])
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
        // This fixture represents an already ACKed raw baseline, not permission inference.
        let order = try FileOutbox(directory: root.appendingPathComponent("outbox"))
            .reserveDailyProjectionObservation()
        let baseline = DailyProjectionObservation(
            order: order, typeCode: "steps",
            rawBaseline: HealthBridgeTimeWindow(
                startTime: HealthBridgeUTCFormatter.string(from: Date().addingTimeInterval(-14 * 86_400)),
                endTime: HealthBridgeUTCFormatter.string(from: Date())
            )
        )
        let cursor = try baseline.cursor(sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey)
        try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).saveCursorValue(
            cursor.cursorValue, receiverBindingID: receiverBindingID, sourceKey: cursor.sourceKey,
            cursorKind: DailyProjectionObservation.coveragePrefix + "steps"
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
        XCTAssertEqual(firstBatches.count, 2, "Raw ACK and sample-less unknown-day observation have separate delivery receipts.")
        let firstUnknown = try XCTUnwrap(firstBatches.last)
        XCTAssertTrue(firstUnknown.samples.isEmpty, "Unknown statistics are not an invented zero.")
        XCTAssertTrue(firstUnknown.deletedRecords.isEmpty)
        XCTAssertTrue(firstUnknown.sync.cursors.contains {
            $0.cursorKind == DailyProjectionObservation.cursorPrefix + "steps"
                && $0.sourceKey == HealthBridgeAppleHealthSource.phone.sourceKey
        })
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
            // Preserve the historical test name while enforcing the current unknown-observation contract.
            XCTAssertEqual(laterBatches.count, 1)
            let unknown = try XCTUnwrap(laterBatches.first)
            XCTAssertTrue(unknown.samples.isEmpty, "Unknown statistics must not manufacture a zero-valued sample.")
            XCTAssertTrue(unknown.deletedRecords.isEmpty)
            XCTAssertTrue(unknown.sync.cursors.contains {
                $0.cursorKind == DailyProjectionObservation.cursorPrefix + "steps"
                    && $0.sourceKey == HealthBridgeAppleHealthSource.phone.sourceKey
            })
            XCTAssertFalse(unknown.sync.cursors.contains { $0.cursorKind == StepCountSyncBatchFactory.anchoredCursorKind })
        }
    }

    func testKeyRecoveryRefusalReportsSpecificReasonWithoutChangingStores() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeKeyRecoveryRefusalTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "HealthBridgeKeyRecoveryRefusalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let viewModel = try makeViewModel(
            root: root, defaults: defaults, settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: outbox
        )
        let originalSettings = try settingsStore.currentConnectionRecordV2()
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(try outbox.pendingItems().count, 0)

        await viewModel.resetLostMailboxConnectionKey()

        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertEqual(
            viewModel.statusMessage,
            "Recovery is allowed only when mailbox connection key material is provably lost."
        )
        XCTAssertEqual(try settingsStore.currentConnectionRecordV2(), originalSettings)
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(try outbox.pendingItems().count, 0)
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

    func testAutomaticUnchangedSleepDoesNotEnqueueBeforeLaterStepsQuery() async throws {
        let fixture = try NativeMailboxAutomaticFixture()
        defer { fixture.cleanUp() }
        let settingsStore = fixture.makeSettingsStore()
        let sleepStore = try FileSleepSyncManifestStore(
            fileURL: fixture.root.appendingPathComponent("sleep.json")
        )
        let manifest = SleepSyncManifest(
            receiverSettingsGeneration: settingsStore.receiverSettingsGenerationToken,
            historyDepth: .allAvailable,
            historyStartDate: nil,
            sourceKey: "apple_health.phone.synthetic-native-mailbox-installation",
            baselineResetEpoch: 1,
            identityNamespace: UUID(),
            nextRevisionSequence: 1,
            anchorCursorValue: fixture.previousAnchor,
            activeChildSamples: [],
            publishedSessions: [],
            baselineResetPending: false
        )
        try sleepStore.saveManifest(manifest)
        var queriedTypes: [String] = []
        let viewModel = try makeViewModel(
            root: fixture.root,
            defaults: fixture.defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { "synthetic-native-mailbox-installation" }
            ),
            outbox: fixture.outbox,
            mailboxKeyStore: fixture.keyStore,
            mailboxProviderLocation: fixture.providerLocation,
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                fileURL: fixture.root.appendingPathComponent("diagnostics.json")
            ),
            readAnchoredSleepChanges: { anchor, start, receivedAt in
                queriedTypes.append("sleep_analysis")
                XCTAssertEqual(anchor, fixture.previousAnchor)
                XCTAssertNil(start)
                return HealthKitAnchoredSleepChanges(
                    addedSamples: [], deletedSamples: [],
                    anchorCursorValue: fixture.previousAnchor,
                    receivedAt: receivedAt
                )
            },
            readAnchoredStepChanges: { anchor, start, _ in
                queriedTypes.append("steps")
                XCTAssertEqual(anchor, fixture.previousAnchor)
                XCTAssertNil(start)
                throw NSError(domain: "SyntheticLaterStepsReadFailure", code: 1)
            },
            automaticSyncEligibleTypeCodesForTesting: ["sleep_analysis", "steps"],
            readDailyActivityAggregates: { _, _, _, _ in
                XCTFail("A failed raw Steps read must preserve its dirty generation.")
                return []
            }
        )
        await viewModel.bootstrap()
        let runtime = HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel, backgroundDeliveryCoordinator: fixture.makeCoordinator()
        )
        defer { runtime.automaticSyncRuntime.stopAdmission() }
        let pendingStore = BackgroundSyncSettingsStore(userDefaults: fixture.defaults)
        try pendingStore.markPendingObserverTypeCodes(["sleep_analysis", "steps"])
        XCTAssertTrue(viewModel.automaticSyncRuntimeIsReady)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)

        XCTAssertEqual(queriedTypes, ["sleep_analysis", "steps"])
        XCTAssertNil(try sleepStore.loadPendingTransition(), "Unchanged automatic Sleep must not create a pending delivery.")
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty, "An unchanged anchor cannot create FIFO backlog.")
        XCTAssertEqual(try sleepStore.loadManifest(), manifest)
        let remaining = try fixture.pending()
        XCTAssertNil(remaining["sleep_analysis"])
        XCTAssertNotNil(remaining["steps"], "The real later reader failed; its durable generation must survive.")
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
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

    func testNativeAutomaticMailboxSleepManifestSaveIOFailureIsStorage() async throws {
        try await exerciseNativeMailboxSleepStorageFailure(.manifestSave)
    }
    func testNativeAutomaticMailboxSleepPendingClearIOFailureIsStorage() async throws {
        try await exerciseNativeMailboxSleepStorageFailure(.pendingClear)
    }
    func testNativeAutomaticMailboxSleepManifestLoadIOFailureIsStorage() async throws {
        try await exerciseNativeMailboxSleepStorageFailure(.manifestLoad)
    }
    func testNativeAutomaticMailboxSleepPendingLoadIOFailureIsStorage() async throws {
        try await exerciseNativeMailboxSleepStorageFailure(.pendingLoad)
    }
    func testNativeAutomaticMailboxSleepPendingSaveIOFailureIsStorage() async throws {
        try await exerciseNativeMailboxSleepStorageFailure(.pendingSave)
    }

    func testNativeAutomaticMailboxACKVerifiedSleepManifestSaveIOFailureIsStorage() async throws {
        try await exerciseNativeMailboxSleepStorageFailure(.manifestSave, recoverWithoutACK: true)
    }

    func testNativeAutomaticMailboxACKVerifiedSleepPendingClearIOFailureIsStorage() async throws {
        try await exerciseNativeMailboxSleepStorageFailure(.pendingClear, recoverWithoutACK: true)
    }

    private func exerciseNativeMailboxSleepStorageFailure(_ point: NativeSleepIOFaultStore.Point, recoverWithoutACK: Bool = false) async throws {
        let fixture = try NativeMailboxSleepFixture(queued: point != .pendingSave)
        defer { fixture.cleanUp() }
        var runtime = try await makeNativeMailboxSleepRuntime(fixture)
        fixture.faults.automaticAcknowledgment = true
        if point == .pendingSave { fixture.store.point = point }
        else { fixture.faults.storageFailureAfterAuthentication = point }
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        if point != .pendingSave {
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        }
        XCTAssertGreaterThan(fixture.store.failures.count, 0, "The real FileSleepSyncManifestStore operation must fail.")
        XCTAssertTrue(fixture.store.failures.allSatisfy { $0 == NSCocoaErrorDomain })
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel), .init(stage: .store, category: .operationFailed))
        XCTAssertEqual(fixture.diagnostics.latestRecord?.failure, .init(stage: .store, category: .operationFailed))
        XCTAssertFalse(fixture.diagnostics.latestRecord?.latestLaneSummary.contains(fixture.root.path) ?? true)
        XCTAssertFalse(runtime.viewModel.statusMessage.contains(fixture.root.path))
        XCTAssertNotNil(try fixture.store.base.loadPendingTransition())
        XCTAssertEqual(try fixture.store.base.loadManifest(), point == .pendingClear ? fixture.pending.manifest : fixture.reservation)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertNil(try fixture.cursor())
        let item = try XCTUnwrap(try fixture.outbox.pendingItems().first)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), fixture.pending.payload)
        if point == .pendingSave {
            XCTAssertEqual(fixture.faults.publishCount, 0, "Journal association must persist before publication.")
        } else {
            XCTAssertGreaterThan(fixture.faults.authenticatedACKCount, 0)
            XCTAssertEqual(item.deliveryState?.phase, .ackVerified)
        }
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        if recoverWithoutACK {
            let failures = fixture.store.failures.count
            let authenticatedACKs = fixture.faults.authenticatedACKCount
            let publishes = fixture.faults.publishCount
            let acknowledgments = try XCTUnwrap(fixture.locator.lanes[.acks])
            for acknowledgment in try FileManager.default.contentsOfDirectory(at: acknowledgments, includingPropertiesForKeys: nil)
                where acknowledgment.pathExtension == "hba" {
                try FileManager.default.removeItem(at: acknowledgment)
            }
            fixture.faults.automaticAcknowledgment = false
            await runtime.automaticSyncRuntime.cancelAndWait()
            do {
                _ = try await fixture.delivery().deliverPending()
                XCTFail("The real foreground recovery must reach the faulting Sleep store.")
            } catch is SleepStorageOperationFailure {
                // Durable ACK verification must retain local storage origin in both delivery entry points.
            } catch {
                XCTFail("ACK-verified foreground recovery lost the typed local-storage origin.")
            }
            runtime = try await makeNativeMailboxSleepRuntime(fixture, reloadStorage: true)
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
            XCTAssertGreaterThan(fixture.store.failures.count, failures)
            XCTAssertEqual(fixture.faults.authenticatedACKCount, authenticatedACKs, "Recovery must use durable ACK verification, not consume another ACK.")
            XCTAssertEqual(fixture.faults.publishCount, publishes)
            XCTAssertEqual(try fixture.outbox.pendingItems().first?.deliveryState?.phase, .ackVerified)
            XCTAssertEqual(recordedSleepFailure(runtime.viewModel), .init(stage: .store, category: .operationFailed))
            XCTAssertEqual(fixture.diagnostics.latestRecord?.failure, .init(stage: .store, category: .operationFailed))
            XCTAssertFalse(fixture.diagnostics.latestRecord?.latestLaneSummary.contains(fixture.root.path) ?? true)
            XCTAssertFalse(runtime.viewModel.statusMessage.contains(fixture.root.path))
        }
        fixture.store.point = nil
        fixture.faults.storageFailureAfterAuthentication = nil
        // ACKed work resumes finalization; it must not publish another envelope.
        let publishes = fixture.faults.publishCount
        await runtime.automaticSyncRuntime.cancelAndWait()
        runtime = try await makeNativeMailboxSleepRuntime(fixture, reloadStorage: true)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        if point == .pendingSave {
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        }
        XCTAssertNil(try fixture.store.base.loadPendingTransition())
        XCTAssertEqual(try fixture.store.base.loadManifest(), fixture.pending.manifest)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), [:])
        if point != .pendingSave { XCTAssertEqual(fixture.faults.publishCount, publishes) }
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
    }

    func testNativeAutomaticMailboxPublishCocoaIOFailureIsTransport() async throws {
        let fixture = try NativeMailboxSleepFixture()
        defer { fixture.cleanUp() }
        var runtime = try await makeNativeMailboxSleepRuntime(fixture)
        fixture.faults.publishFailure = true
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel), .init(stage: .transport, category: .operationFailed))
        XCTAssertEqual(fixture.diagnostics.latestRecord?.failure, .init(stage: .transport, category: .operationFailed))
        XCTAssertGreaterThan(fixture.faults.publishCount, 0)
        XCTAssertFalse(fixture.faults.cocoaDomains.isEmpty)
        XCTAssertTrue(fixture.faults.cocoaDomains.allSatisfy { $0 == NSCocoaErrorDomain })
        try assertNativeMailboxRetained(fixture)
        fixture.faults.publishFailure = false
        fixture.faults.automaticAcknowledgment = true
        await runtime.automaticSyncRuntime.cancelAndWait()
        runtime = try await makeNativeMailboxSleepRuntime(fixture, reloadStorage: true)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        XCTAssertGreaterThan(fixture.faults.authenticatedACKCount, 0)
        XCTAssertNil(try fixture.store.base.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), [:])
    }

    func testNativeAutomaticAuthenticatedMailboxACKPersistenceFailureIsTransport() async throws {
        let fixture = try NativeMailboxSleepFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.outbox.directoryURL.path)
            fixture.cleanUp()
        }
        var runtime = try await makeNativeMailboxSleepRuntime(fixture)
        fixture.faults.automaticAcknowledgment = true
        fixture.faults.ackPersistenceFailure = true
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.outbox.directoryURL.path)
        XCTAssertGreaterThan(fixture.faults.authenticatedACKCount, 0, "The real coordinator reached ACK persistence after authenticating a committed receipt.")
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel), .init(stage: .transport, category: .operationFailed))
        XCTAssertTrue(runtime.viewModel.mailboxDeliveryDiagnosticLine.contains("consume_ack"))
        try assertNativeMailboxRetained(fixture)
        XCTAssertEqual(try fixture.outbox.pendingItems().first?.deliveryState?.phase, .providerObserved)
        fixture.faults.ackPersistenceFailure = false
        let publishes = fixture.faults.publishCount
        await runtime.automaticSyncRuntime.cancelAndWait()
        runtime = try await makeNativeMailboxSleepRuntime(fixture, reloadStorage: true)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        XCTAssertEqual(fixture.faults.publishCount, publishes)
        XCTAssertNil(try fixture.store.base.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), [:])
    }

    func testNativeAutomaticMailboxACKCancellationRetainsPendingAndRetryOrder() async throws {
        let fixture = try NativeMailboxSleepFixture()
        defer { fixture.cleanUp() }
        var runtime = try await makeNativeMailboxSleepRuntime(fixture)
        fixture.faults.automaticAcknowledgment = true
        fixture.faults.cancelBeforeACKPersist = true
        let run = Task { @MainActor in
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        }
        await run.value
        XCTAssertGreaterThan(fixture.faults.authenticatedACKCount, 0)
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel)?.category, .cancellation)
        try assertNativeMailboxRetained(fixture)
        fixture.faults.cancelBeforeACKPersist = false
        let publishes = fixture.faults.publishCount
        await runtime.automaticSyncRuntime.cancelAndWait()
        runtime = try await makeNativeMailboxSleepRuntime(fixture, reloadStorage: true)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        XCTAssertEqual(fixture.faults.publishCount, publishes)
        XCTAssertNil(try fixture.store.base.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
    }

    private func assertNativeMailboxRetained(_ fixture: NativeMailboxSleepFixture) throws {
        XCTAssertNotNil(try fixture.store.base.loadPendingTransition())
        XCTAssertEqual(try fixture.store.base.loadManifest(), fixture.reservation)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertNil(try fixture.cursor())
        XCTAssertEqual(try fixture.outbox.pendingItems().count, 1)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
    }

    func testNativeAutomaticMailboxSleepCharacterizationUsesAuthenticatedACK() async throws {
        let fixture = try NativeMailboxSleepFixture()
        defer { fixture.cleanUp() }
        let runtime = try await makeNativeMailboxSleepRuntime(fixture)
        _ = try await fixture.delivery().publishPendingFIFOHead()
        XCTAssertEqual(try fixture.outbox.deliveryState(for: fixture.itemID)?.phase, .providerObserved)
        XCTAssertEqual(try fixture.store.base.loadManifest(), fixture.reservation)
        XCTAssertNotNil(try fixture.store.base.loadPendingTransition())
        XCTAssertNil(try fixture.cursor())
        try fixture.publishACK()
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        XCTAssertGreaterThan(fixture.componentCreations, 0)
        XCTAssertEqual(fixture.faults.authenticatedACKCount, 1)
        XCTAssertEqual(try fixture.store.base.loadManifest(), fixture.pending.manifest)
        XCTAssertNil(try fixture.store.base.loadPendingTransition())
        XCTAssertNil(try fixture.cursor(), "Sleep anchor ownership remains in the manifest.")
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), [:])
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
    }

    private func makeNativeMailboxSleepRuntime(_ fixture: NativeMailboxSleepFixture, reloadStorage: Bool = false) async throws -> HealthBridgeCompanionApplicationRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        fixture.session?.invalidateAndCancel()
        fixture.session = URLSession(configuration: configuration)
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let runtimeOutbox = try reloadStorage ? FileOutbox(directory: fixture.outbox.directoryURL) : fixture.outbox
        runtimeOutbox.automaticSyncDiagnosticStore = fixture.diagnostics
        let viewModel = try makeViewModel(root: fixture.root, defaults: fixture.defaults,
            settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(), cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { "synthetic-product64-installation" }),
            outbox: runtimeOutbox, mailboxKeyStore: fixture.keyStore,
            receiverClient: ReceiverClient(session: try XCTUnwrap(fixture.session)),
            automaticSyncDiagnosticStore: fixture.diagnostics, sleepManifestStore: fixture.store,
            mailboxComponentsFactory: { try fixture.components(settings: $0, outbox: $1, keyStore: $2) },
            readAnchoredSleepChanges: { _, _, _ in
                XCTFail("Retained pending mailbox work must not query HealthKit.")
                throw CancellationError()
            }, automaticSyncEligibleTypeCodesForTesting: ["sleep_analysis"], scheduleDirectBackgroundUploads: { 0 })
        await viewModel.bootstrap()
        XCTAssertTrue(viewModel.canSyncSleep)
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
    }

    func testAutomaticSleepPendingSaveFailureKeepsDurablePayloadForRetry() async throws {
        try await exerciseSleepStoreFailure(.pendingSave)
    }

    func testAutomaticSleepManifestSaveFailureAfterACKMakesNoNetworkRequest() async throws {
        try await exerciseSleepStoreFailure(.manifestSave)
    }

    func testAutomaticSleepPendingClearFailureAfterACKMakesNoNetworkRequest() async throws {
        try await exerciseSleepStoreFailure(.pendingClear)
    }

    func testAutomaticSleepStoreCancellationRetainsPendingState() async throws {
        let fixture = try SleepStoreFaultFixture(point: .manifestSave)
        defer { fixture.cleanUp() }
        let runtime = try await makeSleepStoreFaultRuntime(fixture)
        fixture.store.failure = CancellationError()
        fixture.store.faultEnabled = true
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel)?.category, .cancellation)
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel)?.stage, .transport)
        XCTAssertEqual(try fixture.store.loadPendingTransition(), fixture.pending)
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.reservation)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertTrue(runtime.viewModel.canSyncSleep)
        fixture.store.faultEnabled = false
        _ = await runtime.viewModel.syncRecentSleepSessions()
        XCTAssertNil(try fixture.store.loadPendingTransition())
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.pending.manifest)
    }

    func testAutomaticSleepHTTPFailureRetainsQueuedTransitionForRetry() async throws {
        let fixture = try SleepStoreFaultFixture(point: .pendingSave)
        defer { fixture.cleanUp() }
        let runtime = try await makeSleepStoreFaultRuntime(fixture)
        fixture.recorder.setForcedStatusCode(503)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        let record = try XCTUnwrap(fixture.diagnostics.latestRecord)
        // Direct HTTP failures are summarized by uploadPendingOutbox rather than thrown
        // to the Sleep recorder. Its existing transport evidence is the delivery lane.
        XCTAssertNil(recordedSleepFailure(runtime.viewModel))
        XCTAssertEqual(record.causalChain?.lanes.first?.delivery, .failed)
        XCTAssertEqual(record.runOutcome, .failed)
        XCTAssertEqual(fixture.recorder.invocationCount, 1)
        XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
        let pending = try XCTUnwrap(fixture.store.loadPendingTransition())
        let item = try XCTUnwrap(try fixture.outbox.pendingItem(id: XCTUnwrap(pending.outboxItemID)))
        XCTAssertEqual(try Data(contentsOf: item.fileURL), fixture.pending.payload)
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.reservation)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        fixture.recorder.setForcedStatusCode(nil)
        _ = await runtime.viewModel.syncRecentSleepSessions()
        XCTAssertEqual(fixture.recorder.invocationCount, 2)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [fixture.pending.payload])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), [:])
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertNil(try fixture.store.loadPendingTransition())
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.pending.manifest)
    }

    private func exerciseSleepStoreFailure(_ point: SleepStoreFaultFixture.Point) async throws {
        let fixture = try SleepStoreFaultFixture(point: point)
        defer { fixture.cleanUp() }
        let runtime = try await makeSleepStoreFaultRuntime(fixture)
        fixture.store.faultEnabled = true
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel), AutomaticSyncDiagnosticFailure(
            stage: .store, category: .operationFailed
        ))
        XCTAssertGreaterThan(fixture.store.faultCount, 0)
        XCTAssertEqual(try fixture.store.loadPendingTransition(), fixture.pending)
        XCTAssertEqual(try fixture.store.loadManifest(), point == .pendingClear
            ? fixture.pending.manifest : fixture.reservation)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertTrue(runtime.viewModel.canSyncSleep)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertFalse(runtime.viewModel.statusMessage.contains(SleepStoreFaultFixture.privateMarker))
        XCTAssertFalse(fixture.diagnostics.latestRecord?.latestLaneSummary.contains(SleepStoreFaultFixture.privateMarker) ?? true)
        if point == .pendingSave {
            let item = try XCTUnwrap(try fixture.outbox.pendingItems().first)
            XCTAssertEqual(try Data(contentsOf: item.fileURL), fixture.pending.payload)
        } else {
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        }
        // Exercise the same failure in foreground; status must not expose NSError details.
        _ = await runtime.viewModel.syncRecentSleepSessions()
        XCTAssertFalse(runtime.viewModel.statusMessage.contains(SleepStoreFaultFixture.privateMarker))
        fixture.store.faultEnabled = false
        let expectedManifest = fixture.reservation
        fixture.recorder.setBeforeResponse { payload, _ in
            XCTAssertEqual(payload, fixture.pending.payload)
            XCTAssertEqual(try fixture.store.base.loadManifest(), expectedManifest)
            XCTAssertNotNil(try fixture.store.base.loadPendingTransition())
        }
        _ = await runtime.viewModel.syncRecentSleepSessions()
        XCTAssertNil(try fixture.store.loadPendingTransition())
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.pending.manifest)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(fixture.recorder.invocationCount, point == .pendingSave ? 1 : 0)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, point == .pendingSave ? [fixture.pending.payload] : [])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(),
            point == .pendingSave ? [:] : fixture.generations)
    }

    private func recordedSleepFailure(_ viewModel: HealthBridgeCompanionViewModel) -> AutomaticSyncDiagnosticFailure? {
        // Inspect the real caller's recorder without exporting private app implementation.
        Mirror(reflecting: viewModel).children.first {
            $0.label == "backgroundAutomaticSyncFailure"
        }?.value as? AutomaticSyncDiagnosticFailure
    }

    private func makeSleepStoreFaultRuntime(_ fixture: SleepStoreFaultFixture) async throws -> HealthBridgeCompanionApplicationRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        fixture.session = session
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { "synthetic-issue64-installation" }
            ),
            outbox: fixture.outbox, receiverClient: ReceiverClient(session: session),
            automaticSyncDiagnosticStore: fixture.diagnostics,
            sleepManifestStore: fixture.store,
            readAnchoredSleepChanges: { _, _, receivedAt in
                XCTFail("Pending delivery failure must not reach a HealthKit query.")
                throw CancellationError()
            },
            automaticSyncEligibleTypeCodesForTesting: ["sleep_analysis"],
            scheduleDirectBackgroundUploads: { 0 }
        )
        await viewModel.bootstrap()
        XCTAssertTrue(viewModel.canSyncSleep)
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
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
        mailboxKeyStore: MailboxKeyStore? = nil,
        mailboxProviderLocation: MailboxProviderLocation? = nil,
        receiverClient: ReceiverClient = ReceiverClient(),
        automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore = AutomaticSyncDiagnosticStore(),
        sleepManifestStore: SleepSyncManifestStoring? = nil,
        mailboxComponentsFactory: ProductionMailboxDelivery.ComponentsFactory? = nil,
        readAnchoredSleepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredSleepChanges)? = nil,
        readAnchoredStepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredStepChanges)? = nil,
        requestReadAuthorization: (@MainActor ([String]) async throws -> Void)? = nil,
        readAnchoredQuantityChanges: (@MainActor (String, String?, Date?, Date) async throws -> HealthKitAnchoredQuantityChanges)? = nil,
        automaticSyncEligibleTypeCodesForTesting: [String]? = nil,
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
            sleepManifestStore: try sleepManifestStore ?? FileSleepSyncManifestStore(
                fileURL: root.appendingPathComponent("sleep.json")
            ),
            sleepManifestFileURL: root.appendingPathComponent("sleep.json"),
            sleepResetEpochStore: SleepResetEpochStore(
                tokenStore: MemoryReceiverTokenStore(),
                epochFloorProvider: { 1 }
            ),
            mailboxKeyStore: mailboxKeyStore ?? MailboxKeyStore(
                service: "synthetic.reset-regression",
                keychain: MemoryMailboxKeychain()
            ),
            mailboxProviderLocation: mailboxProviderLocation,
            mailboxComponentsFactory: mailboxComponentsFactory,
            readAnchoredSleepChanges: readAnchoredSleepChanges,
            readAnchoredStepChanges: readAnchoredStepChanges,
            requestReadAuthorization: requestReadAuthorization,
            readAnchoredQuantityChanges: readAnchoredQuantityChanges,
            automaticSyncEligibleTypeCodesForTesting: automaticSyncEligibleTypeCodesForTesting,
            readDailyActivityAggregates: readDailyActivityAggregates,
            scheduleDirectBackgroundUploads: scheduleDirectBackgroundUploads,
            cancelInheritedLegacyUploads: cancelInheritedLegacyUploads,
            terminalBackgroundPayloadDrain: terminalBackgroundPayloadDrain,
            terminalRecoveryDrainTimeoutNanoseconds: terminalRecoveryDrainTimeoutNanoseconds
        )
    }
}

private final class FaultingSleepManifestStore: SleepSyncManifestStoring, @unchecked Sendable {
    let base: FileSleepSyncManifestStore
    let point: SleepStoreFaultFixture.Point
    var faultEnabled = false
    var faultCount = 0
    var failure: Error = CocoaError(.fileWriteUnknown, userInfo: [
        NSLocalizedDescriptionKey: SleepStoreFaultFixture.privateMarker,
        NSFilePathErrorKey: "/synthetic/" + SleepStoreFaultFixture.privateMarker,
        NSUnderlyingErrorKey: NSError(domain: "synthetic.private", code: 1, userInfo: [
            NSLocalizedDescriptionKey: SleepStoreFaultFixture.privateMarker
        ]),
    ])

    init(base: FileSleepSyncManifestStore, point: SleepStoreFaultFixture.Point) {
        self.base = base
        self.point = point
    }

    private func fail(_ point: SleepStoreFaultFixture.Point) throws {
        if faultEnabled && self.point == point {
            faultCount += 1
            throw failure
        }
    }

    func loadManifest() throws -> SleepSyncManifest? { try base.loadManifest() }
    func loadPendingTransition() throws -> SleepSyncPendingTransition? { try base.loadPendingTransition() }
    func saveManifest(_ manifest: SleepSyncManifest) throws {
        try fail(.manifestSave)
        try base.saveManifest(manifest)
    }
    func savePendingTransition(_ transition: SleepSyncPendingTransition) throws {
        try fail(.pendingSave)
        try base.savePendingTransition(transition)
    }
    func clearPendingTransition(id: String) throws {
        try fail(.pendingClear)
        try base.clearPendingTransition(id: id)
    }
    func resetSynchronizationState() throws { try base.resetSynchronizationState() }
}

private final class SleepStoreFaultFixture: @unchecked Sendable {
    enum Point { case pendingSave, manifestSave, pendingClear }
    static let privateMarker = "synthetic-private-error-marker"
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let settings: ReceiverSettingsStore
    let background: BackgroundSyncSettingsStore
    let generations: [String: Int]
    let diagnostics: AutomaticSyncDiagnosticStore
    let outbox: FileOutbox
    let store: FaultingSleepManifestStore
    let reservation: SleepSyncManifest
    let pending: SleepSyncPendingTransition
    let recorder = PayloadFenceNetworkRecorder()
    var session: URLSession?

    init(point: Point) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Synthetic-Issue64-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "Synthetic.Issue64.SleepStore.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = ReceiverSettingsStore(userDefaults: defaults, tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true })
        try settings.save(receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-issue64-credential", rotateBindingID: true)
        background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        try background.markPendingObserverTypeCodes(["sleep_analysis"])
        generations = try background.loadPendingObserverTypeCodeGenerations()
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        diagnostics = AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json"))
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        outbox.automaticSyncDiagnosticStore = diagnostics
        let base = try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json"))
        store = FaultingSleepManifestStore(base: base, point: point)
        reservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: settings.receiverSettingsGenerationToken,
            historyDepth: HealthHistoryDepthSelectionStore(userDefaults: defaults).historyDepth, historyStartDate: nil,
            sourceKey: "apple_health.phone.synthetic-issue64-installation", baselineResetEpoch: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: reservation,
            changes: HealthKitAnchoredSleepChanges(addedSamples: [], deletedSamples: [],
                anchorCursorValue: "synthetic-issue64-anchor", receivedAt: date),
            receiverSettingsGeneration: settings.receiverSettingsGenerationToken,
            historyDepth: reservation.historyDepth, historyStartDate: nil, generatedAt: date))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let binding = try XCTUnwrap(settings.receiverBindingID)
        var itemID: String?
        if point != .pendingSave {
            let item = try outbox.enqueue(payload, receiverIdentity: binding)
            itemID = item.id
            let cursorStore = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
            // Replay a real durable receiver acceptance before the no-network fault path.
            _ = try OutboxDeliveryCursorFinalizer(outbox: outbox, cursorStore: cursorStore)
                .recordDirectReceiverAcceptance(itemID: item.id, receiverBindingID: binding)
            XCTAssertTrue(try outbox.pendingItems().isEmpty)
        }
        pending = SleepSyncPendingTransition(payload: payload, manifest: transition.manifest,
            receiverBindingID: binding, connectionGeneration: settings.receiverSettingsGenerationToken,
            outboxItemID: itemID)
        try base.saveManifest(reservation)
        try base.savePendingTransition(pending)
    }

    func cleanUp() {
        session?.invalidateAndCancel()
        PayloadFenceURLProtocol.networkRecorder = nil
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: root))
    }
}

@MainActor
private final class NativeMailboxAutomaticFixture {
    let mailboxObserver = SyntheticMailboxChangeObserver()
    let root: URL
    let suiteName = "NativeMailboxAutomaticTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let tokenStore = MemoryReceiverTokenStore()
    let backupStore = MemoryReceiverTokenStore()
    let keyStore = MailboxKeyStore(
        service: "synthetic.native-mailbox-automatic", keychain: MemoryMailboxKeychain()
    )
    let providerLocation: MailboxProviderLocation
    let outbox: FileOutbox
    let previousAnchor: String
    let nextAnchor: String
    let receiverAgreementKey: Curve25519.KeyAgreement.PrivateKey
    let receiverSigningKey: Curve25519.Signing.PrivateKey
    let unseededEmptyRaw: Bool
    private(set) var connectionRecord: ReceiverConnectionRecordV2?
    private(set) var rawReadCount = 0
    var onRawRead: (() -> Void)?
    var stepsObserver: (HKObserverQuery, HealthKitBackgroundDeliveryCoordinator.ObserverUpdateHandler)?

    init(inactiveDirectURL: String? = nil, unseededEmptyRaw: Bool = false) throws {
        self.unseededEmptyRaw = unseededEmptyRaw
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMailboxAutomaticTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        providerLocation = MailboxProviderLocation(
            providerRoot: root.appendingPathComponent("provider", isDirectory: true),
            localRecordURL: root.appendingPathComponent("mailbox-locator.json")
        )
        try FileManager.default.createDirectory(
            at: providerLocation.providerRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        previousAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 71))
        nextAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 72))
        receiverAgreementKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x22, count: 32)
        )
        receiverSigningKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x11, count: 32)
        )
        let device = try keyStore.loadOrCreate()
        let identity = MailboxConnectionIdentityV1(
            receiverID: String(repeating: "1", count: 32),
            deviceID: String(repeating: "2", count: 32),
            devicePrincipal: "installation:" + String(repeating: "3", count: 64),
            deviceSigningKeyID: device.signingKeyID,
            deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "ed25519", publicKey: receiverSigningKey.publicKey.rawRepresentation
            ),
            receiverAgreementKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "x25519", publicKey: receiverAgreementKey.publicKey.rawRepresentation
            ),
            receiverSigningPublicKey: receiverSigningKey.publicKey.rawRepresentation.base64URLEncodedString(),
            receiverAgreementPublicKey: receiverAgreementKey.publicKey.rawRepresentation.base64URLEncodedString(),
            opaqueBinding: Data(repeating: 0x33, count: 32).base64URLEncodedString(),
            connectionGeneration: 1
        )
        let settings = makeSettingsStore()
        try settings.saveMailboxPairing(
            receiverURLString: inactiveDirectURL, bearerToken: inactiveDirectURL == nil ? "" : "synthetic-inactive-token", mailboxIdentity: identity,
            expectedGeneration: settings.receiverSettingsGenerationToken
        )
        connectionRecord = try XCTUnwrap(makeSettingsStore().currentConnectionRecordV2())
        XCTAssertTrue(makeSettingsStore().hasActiveMailboxConnection)
        XCTAssertEqual(makeSettingsStore().receiverURLString, inactiveDirectURL ?? "")
        XCTAssertEqual(try makeSettingsStore().loadBearerToken(), inactiveDirectURL == nil ? "" : "synthetic-inactive-token")
        try BackgroundSyncSettingsStore(userDefaults: defaults).setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        if !unseededEmptyRaw {
            try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).saveCursorValue(
                previousAnchor, receiverBindingID: identity.opaqueBinding,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
            )
            CoreLaneUploadProofStore(userDefaults: defaults).markUploadedRecords(
                lane: .steps, receiverBindingID: identity.opaqueBinding
            )
        }
    }

    func makeSettingsStore() -> ReceiverSettingsStore {
        ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: tokenStore,
            preCutoverBackupStore: backupStore, synchronize: { true }
        )
    }

    func signedAcknowledgment(
        for item: FileOutboxItem,
        payloadDigest: String? = nil,
        generationOffset: Int64 = 0
    ) throws -> (bytes: Data, url: URL) {
        guard case .available(let identity) = try XCTUnwrap(connectionRecord).mailboxIdentity else {
            throw ProductionMailboxDeliveryError.invalidIdentity
        }
        let binding = try XCTUnwrap(item.mailboxBinding)
        let device = try keyStore.loadOrCreate()
        let envelope = try Data(contentsOf: outbox.directoryURL.appendingPathComponent(binding.envelopeFilename))
        let claims = try DeliveryProtocolV1.inspectDelivery(
            envelope, senderSigningPublicKey: Curve25519.Signing.PublicKey(rawRepresentation: device.signingPublicKey)
        )
        let bytes = try DeliveryProtocolV1.sealAck(
            DeliveryReceiptV1(
                result: .committed, payloadSHA256: payloadDigest ?? binding.payloadSHA256,
                receiptID: 1, datasetGeneration: 1, committedAtMS: 1_700_000_061_000, errorCode: nil
            ),
            context: DeliveryAckSealContext(
                envelopeID: claims.envelopeID,
                receiverID: XCTUnwrap(Data(hexV1: identity.receiverID)),
                deviceID: XCTUnwrap(Data(hexV1: identity.deviceID)),
                connectionGeneration: Int64(identity.connectionGeneration) + generationOffset,
                deviceAgreementPublicKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.agreementPublicKey),
                receiverSigningPrivateKey: receiverSigningKey,
                receiverAgreementPrivateKey: receiverAgreementKey
            )
        )
        let locator = try MailboxLocatorV1.resolve(
            providerRoot: providerLocation.providerRoot,
            containerIdentifier: HealthBridgeAppIdentity.ubiquityContainerIdentifier,
            receiverComponent: identity.receiverID, deviceComponent: identity.deviceID,
            localRecordURL: providerLocation.localRecordURL
        )
        return (bytes, try XCTUnwrap(locator.lanes[.acks]).appendingPathComponent(claims.envelopeID.hexV1 + ".hba"))
    }

    func makeCoordinator() -> HealthKitBackgroundDeliveryCoordinator {
        HealthKitBackgroundDeliveryCoordinator(
            makeObserverQuery: { [self] sampleType, updateHandler in
                let query = HKObserverQuery(sampleType: sampleType, predicate: nil, updateHandler: updateHandler)
                if sampleType.identifier == HKQuantityTypeIdentifier.stepCount.rawValue {
                    stepsObserver = (query, updateHandler)
                }
                return query
            },
            executeQuery: { _ in },
            enableDelivery: { _, completion in completion(true, nil) },
            stopQuery: { _ in },
            disableDelivery: { _ in }
        )
    }

    func pending() throws -> [String: Int] {
        try BackgroundSyncSettingsStore(userDefaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
            .loadPendingObserverTypeCodeGenerations()
    }

    func stepCursor() throws -> String? {
        try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).cursorValue(
            receiverBindingID: XCTUnwrap(makeSettingsStore().receiverBindingID),
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        )
    }

    func readSteps(anchor: String?, start: Date?, receivedAt: Date) throws -> HealthKitAnchoredStepChanges {
        rawReadCount += 1
        onRawRead?()
        if unseededEmptyRaw {
            XCTAssertNil(anchor)
            return HealthKitAnchoredStepChanges(stepSamples: [], deletedStepSamples: [], anchorCursorValue: nextAnchor,
                windowStart: receivedAt, windowEnd: receivedAt)
        }
        XCTAssertEqual(anchor, previousAnchor)
        XCTAssertNil(start)
        let sampleStart = receivedAt.addingTimeInterval(-120)
        return HealthKitAnchoredStepChanges(
            stepSamples: [HealthKitStepSampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000071")),
                start: sampleStart, end: sampleStart.addingTimeInterval(60), count: 17
            )],
            deletedStepSamples: [], anchorCursorValue: nextAnchor,
            windowStart: sampleStart, windowEnd: receivedAt
        )
    }

    func assertPublishedStepsAwaitingACK(admitted: [String: Int]) throws {
        let freshOutbox = try FileOutbox(directory: outbox.directoryURL)
        let items = try freshOutbox.pendingItems()
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.receiverIdentity, makeSettingsStore().receiverBindingID)
        XCTAssertEqual(item.deliveryState?.phase, .published)
        let binding = try XCTUnwrap(item.mailboxBinding)
        let envelope = try Data(contentsOf: outbox.directoryURL.appendingPathComponent(binding.envelopeFilename))
        let payload = try Data(contentsOf: item.fileURL)
        XCTAssertNotEqual(envelope, payload)
        let record = try XCTUnwrap(connectionRecord)
        guard case .available(let identity) = record.mailboxIdentity else {
            return XCTFail("Canonical native mailbox identity must remain available.")
        }
        let locator = try MailboxLocatorV1.resolve(
            providerRoot: providerLocation.providerRoot,
            containerIdentifier: HealthBridgeAppIdentity.ubiquityContainerIdentifier,
            receiverComponent: identity.receiverID, deviceComponent: identity.deviceID,
            localRecordURL: providerLocation.localRecordURL
        )
        let published = try FileManager.default.contentsOfDirectory(
            at: XCTUnwrap(locator.lanes[.deliveries]), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(published.first)), envelope)
        let opened = try DeliveryProtocolV1.openDelivery(envelope, context: DeliveryEnvelopeOpenContext(
            receiverID: XCTUnwrap(Data(hexV1: identity.receiverID)),
            deviceID: XCTUnwrap(Data(hexV1: identity.deviceID)),
            connectionGeneration: Int64(identity.connectionGeneration),
            receiverAgreementPrivateKey: receiverAgreementKey,
            senderSigningPublicKey: Curve25519.Signing.PublicKey(
                rawRepresentation: keyStore.loadOrCreate().signingPublicKey
            )
        ))
        XCTAssertEqual(opened.plaintext, payload, "Real signature verification and decryption must recover the durable batch.")
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: opened.plaintext)
        XCTAssertEqual(batch.samples.map(\.typeCode), ["steps"])
        XCTAssertEqual(batch.samples.map(\.value), [17])
        XCTAssertEqual(try freshOutbox.pendingCursorCheckpoint()?.cursorValue, nextAnchor)
        XCTAssertEqual(try stepCursor(), previousAnchor, "Publication cannot advance the committed anchor without receiver ACK.")
        XCTAssertEqual(try pending(), admitted, "Observer dirtiness must survive until authenticated ACK covers it.")
        XCTAssertEqual(try makeSettingsStore().currentConnectionRecordV2(), record)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class SyntheticMailboxChangeObserver: MailboxChangeObserving {
    var onChange: (@MainActor () -> Void)?

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
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
    var unknownStepsStatistics = false
    var omitRawAdditions = false
    var deleteOnFirstRead = false
    var authorizationRequests: [[String]] = []
    var quantityRawRequests: [String] = []
    var completedStepsValue: Double = 4_321
    var completedBasalEnergyValue: Double = 345
    private(set) var declinedBackgroundSchedules = 0
    private(set) var rawAnchors: [String] = []
    private(set) var dailyRequests: [[String]] = []
    private(set) var completedStepsDay: HealthKitDailyActivityAggregate?
    private let sampleStart = Date().addingTimeInterval(-120)

    init(hasModernCoverage: Bool = true, hasRawUploadProof: Bool = true) throws {
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
        if hasRawUploadProof {
            CoreLaneUploadProofStore(userDefaults: defaults).markUploadedRecords(
                lane: .steps, receiverBindingID: receiverBindingID
            )
        }
        guard hasModernCoverage else { return }
        // This fixture represents an already ACKed raw baseline, not permission inference.
        let order = try FileOutbox(directory: root.appendingPathComponent("outbox"))
            .reserveDailyProjectionObservation()
        let baseline = DailyProjectionObservation(
            order: order, typeCode: "steps",
            rawBaseline: HealthBridgeTimeWindow(
                startTime: HealthBridgeUTCFormatter.string(from: Date().addingTimeInterval(-14 * 86_400)),
                endTime: HealthBridgeUTCFormatter.string(from: Date())
            )
        )
        let cursor = try baseline.cursor(sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey)
        try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).saveCursorValue(
            cursor.cursorValue, receiverBindingID: receiverBindingID, sourceKey: cursor.sourceKey,
            cursorKind: DailyProjectionObservation.coveragePrefix + "steps"
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

    func inspectBeforeACK(eligible: [String], admitted: [String: Int], acceptedBefore: Int, opportunity: Int) {
        let root = root
        let suiteName = suiteName
        let binding = receiverBindingID
        let rawCursor = opportunity == 1 ? previousAnchor : currentAnchor
        let dailyCursor = currentAnchor
        recorder.setBeforeResponse { payload, acceptedCount in
            let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: payload)
            let pending = try BackgroundSyncSettingsStore(
                userDefaults: XCTUnwrap(UserDefaults(suiteName: suiteName))
            ).loadPendingObserverTypeCodeGenerations()
            if acceptedCount == acceptedBefore {
                XCTAssertEqual(pending.keys.sorted(), eligible.sorted())
            }
            let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
            XCTAssertTrue(try outbox.pendingItems().contains { try Data(contentsOf: $0.fileURL) == payload })
            for sample in batch.samples {
                let generation = try XCTUnwrap(pending[sample.typeCode], "Generation must remain pending before ACK.")
                if let original = admitted[sample.typeCode] { XCTAssertEqual(generation, original) }
                let isDaily = sample.metadata["sample_kind"] == "daily_aggregate"
                XCTAssertEqual(try outbox.hasPendingGenerationRetirement(
                    typeCode: sample.typeCode, generation: generation
                ), isDaily, "Only daily coverage can carry the retirement marker.")
                if sample.typeCode == "steps" {
                    let cursor = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).cursorValue(
                        receiverBindingID: binding,
                        sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                        cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
                    )
                    XCTAssertEqual(cursor, isDaily ? dailyCursor : rawCursor,
                        "Raw cursor advances only after its ACK; daily delivery preserves it.")
                }
            }
        }
    }

    func readRaw(anchor: String?, start: Date?, receivedAt: Date) throws -> HealthKitAnchoredStepChanges {
        guard let anchor else {
            rawAnchors.append("nil-bootstrap")
            return HealthKitAnchoredStepChanges(stepSamples: [], deletedStepSamples: [],
                anchorCursorValue: currentAnchor, windowStart: start ?? sampleStart, windowEnd: receivedAt)
        }
        rawAnchors.append(anchor)
        XCTAssertTrue([previousAnchor, currentAnchor].contains(anchor))
        XCTAssertNil(start)
        if failRawRead { throw ReadFailure.injected }
        return HealthKitAnchoredStepChanges(
            stepSamples: anchor == currentAnchor || omitRawAdditions ? [] : [HealthKitStepSampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000058")),
                start: sampleStart, end: sampleStart.addingTimeInterval(60), count: 17
            )],
            deletedStepSamples: deleteOnFirstRead && anchor != currentAnchor ? [HealthKitDeletedStepSample(
                uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000058")), deletedAt: receivedAt
            )] : [], anchorCursorValue: currentAnchor,
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
        return types.flatMap { type -> [HealthKitDailyActivityAggregate] in
            if type == "steps", unknownStepsStatistics { return [] }
            let completed = HealthKitDailyActivityAggregate(
                typeCode: type, dayStart: yesterday, dayEnd: today,
                value: type == "steps" ? completedStepsValue : completedBasalEnergyValue,
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
    private var forcedStatusCode: Int?
    private var recordedPayloads: [Data] = []
    private var successfulPayloads: [Data] = []
    private var failedStepsSampleKinds: Set<String> = []
    private var beforeResponse: (@Sendable (Data, Int) throws -> Void)?
    private var inspectionCount = 0

    func setBeforeResponse(_ inspect: @escaping @Sendable (Data, Int) throws -> Void) {
        lock.lock()
        beforeResponse = inspect
        lock.unlock()
    }

    var responseInspectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inspectionCount
    }

    func inspectBeforeResponse(_ payload: Data) throws {
        lock.lock()
        let inspect = beforeResponse
        let acceptedCount = successfulPayloads.count
        if inspect != nil { inspectionCount += 1 }
        lock.unlock()
        try inspect?(payload, acceptedCount)
    }

    func setFailedStepsSampleKinds(_ kinds: Set<String>) {
        lock.lock()
        failedStepsSampleKinds = kinds
        lock.unlock()
    }

    func setForcedStatusCode(_ code: Int?) {
        lock.lock()
        forcedStatusCode = code
        lock.unlock()
    }

    func responseStatusCode(for payload: Data?) -> Int {
        lock.lock()
        let failedKinds = failedStepsSampleKinds
        let forced = forcedStatusCode
        lock.unlock()
        if let forced { return forced }
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
        if statusCode == 200, let payload {
            do {
                try Self.networkRecorder?.inspectBeforeResponse(payload)
            } catch {
                XCTFail("Pre-ACK inspection failed.")
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
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

private final class NativeSleepIOFaultStore: SleepSyncManifestStoring {
    enum Point { case pendingLoad, manifestLoad, pendingSave, manifestSave, pendingClear }
    let base: FileSleepSyncManifestStore
    let fileURL: URL
    var point: Point?
    private(set) var failures: [String] = []

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        base = try FileSleepSyncManifestStore(fileURL: fileURL)
    }

    private func perform<T>(_ operationPoint: Point, _ operation: () throws -> T) throws -> T {
        guard point == operationPoint else { return try operation() }
        let target = operationPoint == .pendingLoad ? fileURL.appendingPathExtension("pending")
            : operationPoint == .manifestLoad ? fileURL : fileURL.deletingLastPathComponent()
        let permission: Int = operationPoint == .pendingLoad || operationPoint == .manifestLoad ? 0 : 0o500
        let original: Int = operationPoint == .pendingLoad || operationPoint == .manifestLoad ? 0o600 : 0o700
        try FileManager.default.setAttributes([.posixPermissions: permission], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: target.path) }
        do { return try operation() } catch {
            failures.append((error as NSError).domain)
            throw error
        }
    }
    func loadManifest() throws -> SleepSyncManifest? { try perform(.manifestLoad) { try base.loadManifest() } }
    func loadPendingTransition() throws -> SleepSyncPendingTransition? { try perform(.pendingLoad) { try base.loadPendingTransition() } }
    func saveManifest(_ manifest: SleepSyncManifest) throws { try perform(.manifestSave) { try base.saveManifest(manifest) } }
    func savePendingTransition(_ pending: SleepSyncPendingTransition) throws { try perform(.pendingSave) { try base.savePendingTransition(pending) } }
    func clearPendingTransition(id: String) throws { try perform(.pendingClear) { try base.clearPendingTransition(id: id) } }
    func resetSynchronizationState() throws { try base.resetSynchronizationState() }
}

private final class NativeMailboxFaults {
    var publishFailure = false
    var ackPersistenceFailure = false
    var cancelBeforeACKPersist = false
    var storageFailureAfterAuthentication: NativeSleepIOFaultStore.Point?
    var automaticAcknowledgment = false
    var authenticatedACKCount = 0
    var publishCount = 0
    var cocoaDomains: [String] = []
}

private struct NativeMailboxPublisher: MailboxEnvelopePublishing {
    let faults: NativeMailboxFaults
    let blockedDirectory: URL
    func publish(_ envelope: Data, finalName: String, locator: MailboxResolvedLocatorV1) throws -> URL {
        faults.publishCount += 1
        if faults.publishFailure {
            do { try envelope.write(to: blockedDirectory, options: [.atomic]) } catch {
                faults.cocoaDomains.append((error as NSError).domain)
                throw error
            }
        }
        return try POSIXMailboxEnvelopePublisher().publish(envelope, finalName: finalName, locator: locator)
    }
}

private final class NativeMailboxSleepFixture {
    let root: URL
    let suiteName = "Synthetic.Product64.Mailbox.\(UUID())"
    let defaults: UserDefaults
    let settings: ReceiverSettingsStore
    let background: BackgroundSyncSettingsStore
    let diagnostics: AutomaticSyncDiagnosticStore
    let outbox: FileOutbox
    let cursorStore: FileSyncCursorStore
    let store: NativeSleepIOFaultStore
    let keyStore = MailboxKeyStore(service: "synthetic.product64", keychain: MemoryMailboxKeychain())
    let receiverSigning = Curve25519.Signing.PrivateKey()
    let receiverAgreement = Curve25519.KeyAgreement.PrivateKey()
    let receiverID = Data(repeating: 0x63, count: 16)
    let deviceID = Data(repeating: 0x64, count: 16)
    let identity: MailboxConnectionIdentityV1
    let locator: MailboxResolvedLocatorV1
    let reservation: SleepSyncManifest
    let pending: SleepSyncPendingTransition
    let generations: [String: Int]
    let itemID: String
    let faults = NativeMailboxFaults()
    let recorder = PayloadFenceNetworkRecorder()
    var session: URLSession?
    var componentCreations = 0

    init(queued: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Synthetic-Product64-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = ReceiverSettingsStore(userDefaults: defaults, tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true })
        let deviceKeys = try keyStore.loadOrCreate()
        identity = MailboxConnectionIdentityV1(receiverID: receiverID.hexV1, deviceID: deviceID.hexV1,
            devicePrincipal: "synthetic-product64-principal", deviceSigningKeyID: deviceKeys.signingKeyID,
            deviceAgreementKeyID: deviceKeys.agreementKeyID,
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(algorithm: "ed25519", publicKey: receiverSigning.publicKey.rawRepresentation),
            receiverAgreementKeyID: try DeliveryProtocolV1.keyID(algorithm: "x25519", publicKey: receiverAgreement.publicKey.rawRepresentation),
            receiverSigningPublicKey: receiverSigning.publicKey.rawRepresentation.base64URLEncodedString(),
            receiverAgreementPublicKey: receiverAgreement.publicKey.rawRepresentation.base64URLEncodedString(),
            opaqueBinding: Data(repeating: 0x64, count: 32).base64URLEncodedString(), connectionGeneration: 1)
        try settings.saveMailboxPairing(receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-product64-credential", mailboxIdentity: identity,
            expectedGeneration: settings.receiverSettingsGenerationToken)
        let provider = root.appendingPathComponent("synthetic-provider")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        locator = try MailboxLocatorV1.resolveIsolated(providerRoot: provider,
            containerIdentifier: "synthetic.product64.container", receiverComponent: identity.receiverID,
            deviceComponent: identity.deviceID, localRecordURL: root.appendingPathComponent("local-locator.json"))
        background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        try background.markPendingObserverTypeCodes(["sleep_analysis"])
        generations = try background.loadPendingObserverTypeCodeGenerations()
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes))
        diagnostics = AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json"))
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        outbox.automaticSyncDiagnosticStore = diagnostics
        cursorStore = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        store = try NativeSleepIOFaultStore(fileURL: root.appendingPathComponent("sleep-state/sleep.json"))
        reservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: settings.receiverSettingsGenerationToken,
            historyDepth: HealthHistoryDepthSelectionStore(userDefaults: defaults).historyDepth,
            historyStartDate: nil, sourceKey: "apple_health.phone.synthetic-product64-installation", baselineResetEpoch: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(previousManifest: reservation,
            changes: HealthKitAnchoredSleepChanges(addedSamples: [], deletedSamples: [],
                anchorCursorValue: "synthetic-product64-anchor", receivedAt: date),
            receiverSettingsGeneration: settings.receiverSettingsGenerationToken,
            historyDepth: reservation.historyDepth, historyStartDate: nil, generatedAt: date))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        if queued {
            itemID = try XCTUnwrap(outbox.enqueueSequence([payload], receiverIdentity: identity.opaqueBinding,
                pendingGenerationRetirements: generations).first).id
        } else { itemID = "" }
        pending = SleepSyncPendingTransition(payload: payload, manifest: transition.manifest,
            receiverBindingID: identity.opaqueBinding, connectionGeneration: settings.receiverSettingsGenerationToken,
            outboxItemID: queued ? itemID : nil)
        try store.base.saveManifest(reservation)
        try store.base.savePendingTransition(pending)
    }

    func components(settings: ReceiverSettingsStore, outbox: FileOutbox, keyStore: MailboxKeyStore) throws -> ProductionMailboxComponents {
        XCTAssertTrue(keyStore === self.keyStore, "The VM must forward its injected memory key store.")
        componentCreations += 1
        return try ProductionMailboxComponents.make(settingsStore: settings, outbox: outbox, keyStore: keyStore,
            locate: { self.locator },
            publisher: NativeMailboxPublisher(faults: faults, blockedDirectory: root),
            observe: { url, digest in
                let bytes = try Data(contentsOf: url)
                let matches = Data(SHA256.hash(data: bytes)).hexV1 == digest
                if matches && self.faults.automaticAcknowledgment { try self.publishACK() }
                return matches
            },
            makeHydrator: { lane, names, _ in
                MailboxAckHydrator(candidates: {
                    let paths = try names?.map { lane.appendingPathComponent($0) }
                        ?? FileManager.default.contentsOfDirectory(at: lane, includingPropertiesForKeys: nil)
                    return MailboxAckHydrationCandidates(eligible: paths.filter { FileManager.default.fileExists(atPath: $0.path) },
                        skippedUnverifiableIdentityCount: 0)
                }, availability: { _ in .available }, requestDownload: { _ in XCTFail("No real provider") },
                    wait: { XCTFail("No time-based wait") }, maximumWaits: 0)
            },
            coordinatorFault: { boundary in
                if boundary == .beforeProgressFinalization,
                   let point = self.faults.storageFailureAfterAuthentication { self.store.point = point }
                guard boundary == .beforeStateWrite(.ackVerified) else { return }
                self.faults.authenticatedACKCount += 1
                if self.faults.cancelBeforeACKPersist {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
                if self.faults.ackPersistenceFailure {
                    // Fail the actual FileOutbox manifest write after the real ACK is authenticated.
                    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                        ofItemAtPath: self.outbox.directoryURL.path)
                }
            })
    }

    func delivery() -> ProductionMailboxDelivery {
        ProductionMailboxDelivery(settingsStore: settings, outbox: outbox, cursorStore: cursorStore,
            proofStore: nil, pendingGenerationStore: background, sleepStore: store,
            keyStore: keyStore, componentsFactory: { try self.components(settings: $0, outbox: $1, keyStore: $2) })
    }

    func publishACK() throws {
        let item = try XCTUnwrap(outbox.pendingItems().first)
        let record = try FileOutboxMailboxAckLookup(outbox: outbox,
            deviceSigningPublicKey: Curve25519.Signing.PublicKey(rawRepresentation: keyStore.loadOrCreate().signingPublicKey)).record(for: item)
        let bytes = try DeliveryProtocolV1.sealAck(.init(result: .committed, payloadSHA256: record.payloadSHA256,
            receiptID: 64, datasetGeneration: 1, committedAtMS: 1_700_000_000_000, errorCode: nil),
            context: .init(envelopeID: record.envelopeID, receiverID: receiverID, deviceID: deviceID,
                connectionGeneration: Int64(identity.connectionGeneration),
                deviceAgreementPublicKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyStore.loadOrCreate().agreementPublicKey),
                receiverSigningPrivateKey: receiverSigning, receiverAgreementPrivateKey: receiverAgreement))
        try bytes.write(to: try XCTUnwrap(locator.lanes[.acks]).appendingPathComponent(record.envelopeID.hexV1 + ".hba"), options: [.atomic])
    }

    func cursor() throws -> String? {
        try cursorStore.cursorValue(receiverBindingID: identity.opaqueBinding,
            sourceKey: try XCTUnwrap(reservation.sourceKey), cursorKind: "anchored_sleep_sync")
    }

    func cleanUp() {
        session?.invalidateAndCancel()
        PayloadFenceURLProtocol.networkRecorder = nil
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: root))
    }
}

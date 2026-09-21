import Combine
import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class HealthBridgeCompanionResetAdmissionTests: XCTestCase {
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
            "An empty initial Sleep read must not advance the durable anchor."
        )
        XCTAssertNil(try sleepStore.loadPendingTransition())
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertGreaterThan(networkRecorder.invocationCount, 0)
        XCTAssertEqual(
            viewModel.statusMessage,
            "Step sync failed: HealthKit anchor cursor was not valid base64.",
            "The later Steps lane must reach its real query path after stale Sleep recovery."
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
            cancelInheritedLegacyUploads: cancelInheritedLegacyUploads,
            terminalBackgroundPayloadDrain: terminalBackgroundPayloadDrain,
            terminalRecoveryDrainTimeoutNanoseconds: terminalRecoveryDrainTimeoutNanoseconds
        )
    }
}

private struct ResetObservation {
    let queuedItemCount: Int
    let clearIntentIsActive: Bool
}

private final class PayloadFenceNetworkRecorder: @unchecked Sendable {
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
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ok"}"#.utf8))
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

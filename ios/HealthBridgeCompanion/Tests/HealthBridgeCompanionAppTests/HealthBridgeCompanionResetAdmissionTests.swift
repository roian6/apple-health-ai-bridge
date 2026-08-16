import Combine
import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class HealthBridgeCompanionResetAdmissionTests: XCTestCase {
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

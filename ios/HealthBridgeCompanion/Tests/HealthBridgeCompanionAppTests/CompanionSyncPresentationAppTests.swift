import Foundation
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class CompanionSyncPresentationAppTests: XCTestCase {
    func testConnectionCheckDoesNotInventAcceptedTransfer() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()

        await viewModel.checkConnection()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(viewModel.syncPresentation.phase, .permissionRequestNeeded)
    }

    func testCursorOnlyTransferRecordsAcceptanceWithoutHealthSamples() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.values = [:]
        let viewModel = try await fixture.makeViewModel()
        await viewModel.syncSupportedQuantityMetrics()

        XCTAssertTrue(fixture.receiver.records.isEmpty)
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation?.evidenceKind, .directResponse)
    }

    func testFailedUploadDoesNotInventAcceptedTransfer() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.receiver.status = 503
        let viewModel = try await fixture.makeViewModel()

        await viewModel.syncSupportedQuantityMetrics()

        XCTAssertTrue(fixture.receiver.records.isEmpty)
        XCTAssertFalse(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testAcceptedDirectTransferSurvivesEmptyCheckAndViewModelRecreation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.defaults)
        try background.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let viewModel = try await fixture.makeViewModel(eligibleTypeCodes: ["weight"])
        await viewModel.syncSupportedQuantityMetrics()
        let accepted = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(accepted.evidenceKind, .directResponse)
        XCTAssertEqual(Set(fixture.receiver.records.map(\.typeCode)), ["weight", "dietary_protein"])
        let observation = LastAcceptedTransferObservation(
            bindingID: accepted.bindingID, generation: accepted.generation,
            observedAt: Date(timeIntervalSinceReferenceDate: 123_456), evidenceKind: .directResponse
        )
        fixture.acceptedTransferStore.record(observation)
        let batches = fixture.receiver.batches
        let reads = fixture.reads.count
        fixture.values = [:]
        try background.markPendingObserverTypeCodes(["weight"])
        let generations = try background.loadPendingObserverTypeCodeGenerations()

        let result = await viewModel.processAutomaticSyncType("weight", pendingGenerations: generations)

        XCTAssertEqual(result, .noPayloadCovering(generations))
        XCTAssertEqual(fixture.reads.count, reads + 1)
        XCTAssertEqual(fixture.reads.last, "weight")
        XCTAssertEqual(fixture.receiver.batches.count, batches.count)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.cursor("weight"), fixture.anchor)
        XCTAssertEqual(try fixture.cursor("dietary_protein"), fixture.anchor)
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation, observation)

        let reopened = try await fixture.makeViewModel()

        XCTAssertEqual(reopened.lastAcceptedTransferObservation, observation)
    }

    func testConnectionReplacementHidesPreviousAcceptedTransfer() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        await viewModel.syncSupportedQuantityMetrics()
        _ = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        viewModel.receiverURLString = "http://127.0.0.1:8766/v1/batches"
        viewModel.bearerToken = "synthetic-replacement"

        await viewModel.saveReceiverSettings()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testMailboxPublicationRemainsUnconfirmed() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        fixture.base.values = ["weight": 70]
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        await viewModel.syncSupportedQuantityMetrics()

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertTrue(try fixture.base.outbox.pendingItems().contains {
            $0.deliveryState?.phase == .providerObserved
        })
        XCTAssertEqual(viewModel.syncPresentation.phase, .mailboxConfirmationWaiting)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testAuthenticatedMailboxCommitRecordsAcceptedTransfer() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        _ = try fixture.base.enqueueMixed()
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        let pending = try XCTUnwrap(fixture.base.outbox.pendingItems().first {
            $0.deliveryState?.phase == .providerObserved
        })
        _ = try fixture.receiveAndAcknowledge(pending)
        let ackLane = try XCTUnwrap(fixture.locator.lanes[.acks])
        let ackURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: ackLane, includingPropertiesForKeys: nil
        ).first)
        let ackBytes = try Data(contentsOf: ackURL)

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        let observation = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(observation.evidenceKind, .mailboxCommit)
        XCTAssertEqual(observation.bindingID, fixture.identity.opaqueBinding)
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: pending.id))
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        let retained = LastAcceptedTransferObservation(
            bindingID: observation.bindingID, generation: observation.generation,
            observedAt: Date(timeIntervalSinceReferenceDate: 234_567), evidenceKind: .mailboxCommit
        )
        fixture.base.acceptedTransferStore.record(retained)
        let batches = fixture.base.receiver.batches.count

        // Replay the exact signed receipt after retirement, alongside new work
        // that has no ACK and therefore cannot earn another observation.
        try ackBytes.write(to: ackURL, options: .atomic)
        let next = try fixture.base.enqueueMixed(workoutEnergy: 20)
        let replayViewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        XCTAssertEqual(try fixture.components().scanner.scan().events.count, 1)

        await replayViewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertEqual(replayViewModel.lastAcceptedTransferObservation, retained)
        XCTAssertEqual(try fixture.base.outbox.pendingItems().map(\.id), [next.id])
        XCTAssertEqual(try fixture.base.outbox.pendingItem(id: next.id)?.deliveryState?.phase, .providerObserved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ackURL.path))
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertEqual(fixture.base.receiver.batches.count, batches)
    }

    func testUnavailableObservationWriteCannotChangeDirectAcceptance() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let defaults = try XCTUnwrap(UnavailableObservationDefaults(suiteName: fixture.suite + ".unavailable"))
        fixture.acceptedTransferStore = LastAcceptedTransferObservationStore(userDefaults: defaults)
        let viewModel = try await fixture.makeViewModel()

        await viewModel.syncSupportedQuantityMetrics()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertEqual(Set(fixture.receiver.records.map(\.typeCode)), ["weight", "dietary_protein"])
        XCTAssertEqual(try fixture.cursor("weight"), fixture.anchor)
        XCTAssertEqual(try fixture.cursor("dietary_protein"), fixture.anchor)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(defaults.rejectedWrites, fixture.receiver.batches.count)
        XCTAssertGreaterThan(defaults.rejectedWrites, 0)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
        let reopened = try await fixture.makeViewModel()
        XCTAssertNil(reopened.lastAcceptedTransferObservation)
    }

    func testUnavailableObservationWriteCannotChangeMailboxFinalization() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        _ = try fixture.base.enqueueMixed()
        let defaults = try XCTUnwrap(UnavailableObservationDefaults(suiteName: fixture.base.suite + ".unavailable"))
        fixture.base.acceptedTransferStore = LastAcceptedTransferObservationStore(userDefaults: defaults)
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        let pending = try XCTUnwrap(fixture.base.outbox.pendingItems().first {
            $0.deliveryState?.phase == .providerObserved
        })
        XCTAssertEqual(defaults.rejectedWrites, 0)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        _ = try fixture.receiveAndAcknowledge(pending)

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertEqual(defaults.rejectedWrites, 1)
        XCTAssertEqual(Set(fixture.base.receiver.records.map(\.typeCode)), ["weight", "dietary_protein"])
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: pending.id))
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testLateDirectResponseCannotReplaceCurrentConnectionObservation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        _ = try fixture.enqueueMixed()
        let viewModel = try await fixture.makeViewModel()
        let oldBinding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        fixture.receiver.responseProbe = probe
        let sync = Task { @MainActor in
            await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        }
        await fulfillment(of: [probe.entered], timeout: 5)
        let pending = try fixture.outbox.pendingItems()
        XCTAssertFalse(pending.isEmpty)
        try fixture.settings.save(
            receiverURLString: "http://127.0.0.1:8766/v1/batches", bearerToken: "synthetic-replacement"
        )
        let current = LastAcceptedTransferObservation(
            bindingID: try XCTUnwrap(fixture.settings.receiverBindingID),
            generation: fixture.settings.receiverSettingsGenerationToken,
            observedAt: Date(timeIntervalSinceReferenceDate: 345_678), evidenceKind: .directResponse
        )
        fixture.acceptedTransferStore.record(current)
        probe.release()
        await sync.value

        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertFalse(fixture.receiver.records.isEmpty)
        XCTAssertEqual(try fixture.outbox.pendingItems(), pending)
        XCTAssertNil(try fixture.cursors.cursorValue(
            receiverBindingID: oldBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "dietary_protein")
        ))
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation, current)
    }
}

// UserDefaults.set has no error/acknowledgment channel. Model an unavailable
// metadata destination at that existing injected boundary, not in the VM.
private final class UnavailableObservationDefaults: UserDefaults, @unchecked Sendable {
    private(set) var rejectedWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        rejectedWrites += 1
    }
}

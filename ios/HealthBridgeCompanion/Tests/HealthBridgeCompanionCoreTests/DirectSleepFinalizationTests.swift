import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class DirectSleepFinalizationTests: XCTestCase {
    func testAcceptedSleepCommitsManifestBeforeRetiringItsGeneration() async throws {
        let fixture = try DirectSleepFinalizationFixture()
        defer { fixture.remove() }

        _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
            descriptor: fixture.descriptor, sleepStore: fixture.sleep, validate: {}
        )

        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.pending.manifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        let replay = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
            descriptor: fixture.descriptor, sleepStore: fixture.sleep, validate: {}
        )
        XCTAssertFalse(replay)
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.pending.manifest)
    }

    func testWrongSleepGenerationCannotCommitOrRetireAndCorrectReplayCan() async throws {
        let fixture = try DirectSleepFinalizationFixture()
        defer { fixture.remove() }
        let wrong = DirectUploadCompletionDescriptor(
            itemID: fixture.descriptor.itemID,
            receiverGeneration: "superseded-generation",
            receiverBindingID: fixture.descriptor.receiverBindingID
        )
        do {
            _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: wrong, sleepStore: fixture.sleep, validate: {}
            )
            XCTFail("A different generation cannot commit this Sleep transition.")
        } catch OutboxDeliveryCoordinatorError.ownershipMismatch {}

        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initial)
        XCTAssertEqual(try fixture.sleep.loadPendingTransition(), fixture.pending)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [fixture.descriptor.itemID])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)

        _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
            descriptor: fixture.descriptor, sleepStore: fixture.sleep, validate: {}
        )
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.pending.manifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
    }

    func testCancellationAfterManifestCommitRetainsJournalAndGenerationForReplay() async throws {
        let fixture = try DirectSleepFinalizationFixture()
        defer { fixture.remove() }
        do {
            _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: fixture.descriptor, sleepStore: fixture.sleep,
                validate: {
                    if try fixture.sleep.loadManifest() == fixture.pending.manifest {
                        throw CancellationError()
                    }
                }
            )
            XCTFail("Cancellation after the durable manifest write must stop retirement.")
        } catch is CancellationError {}

        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.pending.manifest)
        XCTAssertEqual(try fixture.sleep.loadPendingTransition(), fixture.pending)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [fixture.descriptor.itemID])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)

        _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
            descriptor: fixture.descriptor, sleepStore: fixture.sleep, validate: {}
        )
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
    }

    func testMatchingItemIDCannotCommitDifferentPendingPayload() async throws {
        let fixture = try DirectSleepFinalizationFixture()
        defer { fixture.remove() }
        let mismatched = SleepSyncPendingTransition(
            payload: Data("different-synthetic-payload".utf8),
            manifest: fixture.pending.manifest,
            receiverBindingID: fixture.pending.receiverBindingID,
            connectionGeneration: fixture.pending.connectionGeneration,
            outboxItemID: fixture.pending.outboxItemID
        )
        try fixture.sleep.savePendingTransition(mismatched)
        do {
            _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: fixture.descriptor, sleepStore: fixture.sleep, validate: {}
            )
            XCTFail("Item identity alone cannot authenticate a different pending payload.")
        } catch OutboxDeliveryCoordinatorError.ownershipMismatch {}

        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initial)
        XCTAssertEqual(try fixture.sleep.loadPendingTransition(), mismatched)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [fixture.descriptor.itemID])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
    }

    func testAcceptedExactPayloadCanFinalizeBeforeJournalTracksItsNewItem() async throws {
        let previousIDs: [String?] = [
            nil,
            "00000000000000000001-00000000-0000-0000-0000-000000000099",
        ]
        for previousID in previousIDs {
            let fixture = try DirectSleepFinalizationFixture()
            defer { fixture.remove() }
            try fixture.sleep.savePendingTransition(SleepSyncPendingTransition(
                payload: fixture.pending.payload,
                manifest: fixture.pending.manifest,
                receiverBindingID: fixture.pending.receiverBindingID,
                connectionGeneration: fixture.pending.connectionGeneration,
                outboxItemID: previousID
            ))

            _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: fixture.descriptor, sleepStore: fixture.sleep, validate: {}
            )

            XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.pending.manifest)
            XCTAssertNil(try fixture.sleep.loadPendingTransition())
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
            XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        }
    }
}

@MainActor
private final class DirectSleepFinalizationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectSleepFinalization-\(UUID())")
    let suite = "DirectSleepFinalization.\(UUID())"
    let defaults: UserDefaults
    let background: BackgroundSyncSettingsStore
    let generations: [String: Int]
    let outbox: FileOutbox
    let sleep: FileSleepSyncManifestStore
    let initial: SleepSyncManifest
    let pending: SleepSyncPendingTransition
    let descriptor: DirectUploadCompletionDescriptor
    let finalizer: OutboxDeliveryCursorFinalizer

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.markPendingObserverTypeCodes(["sleep_analysis"])
        generations = try background.loadPendingObserverTypeCodeGenerations()
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        sleep = try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json"))
        initial = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: "generation-a", historyDepth: .allAvailable,
            historyStartDate: nil, sourceKey: "synthetic-source"
        )
        try sleep.saveManifest(initial)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: initial,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [HealthKitSleepChildSample(
                    uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000172")),
                    stage: "core", start: start, end: start.addingTimeInterval(3600)
                )],
                deletedSamples: [], anchorCursorValue: "accepted-synthetic-anchor",
                receivedAt: start.addingTimeInterval(7200)
            ),
            receiverSettingsGeneration: "generation-a", historyDepth: .allAvailable,
            historyStartDate: nil
        ))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let item = try XCTUnwrap(outbox.enqueueSequence(
            [payload], receiverIdentity: "receiver-a", pendingGenerationRetirements: generations
        ).first)
        pending = SleepSyncPendingTransition(
            payload: payload, manifest: transition.manifest, receiverBindingID: "receiver-a",
            connectionGeneration: "generation-a", outboxItemID: item.id
        )
        try sleep.savePendingTransition(pending)
        descriptor = DirectUploadCompletionDescriptor(
            itemID: item.id, receiverGeneration: "generation-a", receiverBindingID: "receiver-a"
        )
        finalizer = OutboxDeliveryCursorFinalizer(
            outbox: outbox,
            cursorStore: try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            pendingGenerationStore: background
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: root))
    }
}

import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

extension OutboxDeliveryCoordinatorTests {
    func testCursorAndSleepFinalizationAreExactlyOnce() throws {
        let harness = try OutboxDeliveryHarness()
        let deliveryFinalizer = CountingOutboxDeliveryFinalizer()
        _ = try advanceToProviderObserved(
            harness,
            sealer: CountingMailboxEnvelopeSealer(harness.fixture),
            finalizer: deliveryFinalizer
        )
        let event = try harness.publishCommittedAck()
        let receipt = try XCTUnwrap(OutboxDeliveryCommittedReceiptV1(event: event))
        let cursorOutbox = try FileOutbox(
            directory: harness.fixture.root.appendingPathComponent("cursor-outbox")
        )
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: harness.ownership.receiverBindingID,
            sourceKey: "synthetic-workout-corrections",
            cursorKind: "synthetic-anchor",
            cursorValue: "synthetic-correction-cursor",
            coreLaneUploadProof: .workouts
        )
        let cursorItem = try XCTUnwrap(
            cursorOutbox.enqueueSequence(
                [harness.fixture.payload],
                receiverIdentity: harness.ownership.receiverBindingID,
                cursorCheckpoint: checkpoint
            ).first
        )
        _ = try cursorOutbox.finalizeMailboxEnvelope(
            itemID: cursorItem.id,
            envelope: Data("synthetic-finalized-envelope".utf8),
            expectedPayloadSHA256: mailboxSHA256(harness.fixture.payload)
        )
        let encrypted = try XCTUnwrap(
            cursorOutbox.deliveryState(for: cursorItem.id)
        )
        let owned = try cursorOutbox.compareAndSetDeliveryState(
            itemID: cursorItem.id,
            expected: encrypted,
            updated: encrypted.assigning(harness.ownership)
        )
        _ = try cursorOutbox.compareAndSetDeliveryState(
            itemID: cursorItem.id,
            expected: owned,
            updated: .committed(
                phase: .ackVerified,
                ownership: harness.ownership,
                receipt: receipt
            )
        )
        let cursor = CountingSyncCursorStore()
        let suiteName = "OutboxDeliveryCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let proofStore = CoreLaneUploadProofStore(userDefaults: defaults)
        let cursorFinalizer = OutboxDeliveryCursorFinalizer(
            outbox: cursorOutbox,
            cursorStore: cursor,
            proofStore: proofStore
        )
        let context = OutboxDeliveryFinalizationContext(
            itemID: cursorItem.id,
            ownership: harness.ownership
        )
        XCTAssertFalse(try cursorFinalizer.isFinalized(context))
        try cursorFinalizer.finalize(context)
        try cursorFinalizer.finalize(context)
        XCTAssertTrue(try cursorFinalizer.isFinalized(context))
        XCTAssertEqual(cursor.saveCount, 1)
        XCTAssertNil(try cursorOutbox.pendingCursorCheckpoint())
        XCTAssertTrue(
            proofStore.hasUploadedRecords(
                lane: .workouts,
                receiverBindingID: harness.ownership.receiverBindingID
            )
        )

        let sleepRoot = harness.fixture.root.appendingPathComponent("sleep")
        let store = try FileSleepSyncManifestStore(
            fileURL: sleepRoot.appendingPathComponent("manifest.json")
        )
        let manifest = SleepSyncManifest(
            receiverSettingsGeneration: harness.ownership.receiverGeneration,
            historyDepth: .lastDays(30),
            historyStartDate: nil,
            sourceKey: "synthetic-source",
            baselineResetEpoch: harness.ownership.resetEpoch,
            identityNamespace: UUID(),
            nextRevisionSequence: 2,
            anchorCursorValue: "synthetic-anchor",
            activeChildSamples: [],
            publishedSessions: []
        )
        let pending = SleepSyncPendingTransition(
            payload: harness.fixture.payload,
            manifest: manifest,
            receiverBindingID: harness.ownership.receiverBindingID,
            connectionGeneration: harness.ownership.receiverGeneration,
            outboxItemID: harness.fixture.item.id
        )
        try store.savePendingTransition(pending)
        let sleepFinalizer = OutboxDeliverySleepFinalizer(
            store: store,
            pendingTransition: pending
        )
        let sleepContext = OutboxDeliveryFinalizationContext(
            itemID: harness.fixture.item.id,
            ownership: harness.ownership
        )
        XCTAssertFalse(try sleepFinalizer.isFinalized(sleepContext))
        try sleepFinalizer.finalize(sleepContext)
        XCTAssertTrue(try sleepFinalizer.isFinalized(sleepContext))
        try sleepFinalizer.finalize(sleepContext)
        XCTAssertEqual(try store.loadManifest(), manifest)
        XCTAssertNil(try store.loadPendingTransition())
    }

    func testCommittedFinalizationRetiresOnlyExactArtifacts() throws {
        let harness = try OutboxDeliveryHarness()
        let unrelated = try harness.fixture.outbox.enqueue(
            Data("synthetic-unrelated".utf8),
            receiverIdentity: harness.ownership.receiverBindingID
        )
        let finalizer = CountingOutboxDeliveryFinalizer()
        let coordinator = try advanceToProviderObserved(
            harness,
            sealer: CountingMailboxEnvelopeSealer(harness.fixture),
            finalizer: finalizer
        )
        _ = try coordinator.consume(
            harness.publishCommittedAck(),
            itemID: harness.fixture.item.id
        )
        _ = try coordinator.finalizeCommitted(itemID: harness.fixture.item.id)

        XCTAssertNil(try harness.fixture.outbox.pendingItem(id: harness.fixture.item.id))
        XCTAssertNotNil(try harness.fixture.outbox.pendingItem(id: unrelated.id))
        XCTAssertEqual(try Data(contentsOf: unrelated.fileURL), Data("synthetic-unrelated".utf8))
    }

    func testAckDeletionFailureKeepsCommittedFinalization() throws {
        let harness = try OutboxDeliveryHarness()
        let finalizer = CountingOutboxDeliveryFinalizer()
        let coordinator = try advanceToProviderObserved(
            harness,
            sealer: CountingMailboxEnvelopeSealer(harness.fixture),
            finalizer: finalizer
        )
        let event = try harness.publishCommittedAck()
        _ = try coordinator.consume(event, itemID: harness.fixture.item.id)
        _ = try coordinator.finalizeCommitted(itemID: harness.fixture.item.id)

        let failingScanner = MailboxAckScanner(
            context: harness.ackContext,
            lookup: FileOutboxMailboxAckLookup(
                outbox: harness.fixture.outbox,
                deviceSigningPublicKey: harness.ackContext.deviceSigningPublicKey
            ),
            locate: { harness.fixture.locator },
            fault: { boundary in
                if boundary == .beforeUnlink { throw MailboxSyntheticFailure.injected }
            }
        )
        let failingCoordinator = OutboxDeliveryCoordinator(
            outbox: harness.fixture.outbox,
            transport: harness.fixture.transport(sealer: NeverMailboxEnvelopeSealer()),
            scanner: failingScanner,
            ownership: harness.ownership,
            finalizer: finalizer
        )
        XCTAssertThrowsError(
            try failingCoordinator.deleteAcknowledgment(
                for: event,
                itemID: harness.fixture.item.id
            )
        )
        XCTAssertEqual(
            try failingCoordinator.state(itemID: harness.fixture.item.id)?.phase,
            .committedFinalized
        )
        XCTAssertEqual(finalizer.finalizeCount, 1)
    }

    func testTodo14V4MigrationInfersEncryptedWithoutResealing() throws {
        let fixture = try MailboxAckScannerFixture()
        let manifestURL = fixture.transport.outboxDirectory
            .appendingPathComponent(".fifo-sequence")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: manifestURL)
            ) as? [String: Any]
        )
        var entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        entries = entries.map { entry in
            var legacy = entry
            legacy.removeValue(forKey: "deliveryState")
            return legacy
        }
        manifest["entries"] = entries
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: manifestURL, options: [.atomic])
        let restarted = try FileOutbox(directory: fixture.transport.outboxDirectory)
        XCTAssertEqual(
            try restarted.deliveryState(for: fixture.transport.item.id)?.phase,
            .encrypted
        )
        let finalizer = CountingOutboxDeliveryFinalizer()
        let ownership = OutboxDeliveryOwnershipV1(
            receiverGeneration: "synthetic-receiver-generation",
            resetEpoch: 41,
            ackContext: fixture.context
        )
        let coordinator = OutboxDeliveryCoordinator(
            outbox: restarted,
            transport: fixture.transport.transport(
                outbox: restarted,
                sealer: NeverMailboxEnvelopeSealer()
            ),
            scanner: fixture.scanner(),
            ownership: ownership,
            finalizer: finalizer
        )
        XCTAssertEqual(
            try coordinator.advance(itemID: fixture.transport.item.id).phase,
            .published
        )
    }
}

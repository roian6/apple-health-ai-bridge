import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class DirectSleepFinalizationTests: XCTestCase {
    func testLegacySleepCleanupInterruptionRetainsAcceptanceAcrossRestart() async throws {
        for afterUnlink in [false, true] {
            let f = try DirectSleepFinalizationFixture()
            defer { f.remove() }
            let d = f.descriptor
            let manifest = f.root.appendingPathComponent("sleep.json")
            let journal = f.root.appendingPathComponent("sleep.json.pending")
            XCTAssertNotNil(try f.outbox.recordDirectUploadAccepted(itemID: d.itemID, receiverIdentity: d.receiverBindingID))
            try f.sleep.saveManifest(f.pending.manifest)
            let interrupted = try FileSleepSyncManifestStore(
                fileURL: manifest, fileManager: JournalRemovalFault(journal, afterUnlink: afterUnlink)
            )
            do {
                _ = try await f.finalizer.finalizeDirectAcknowledgments(
                    receiverBindingID: d.receiverBindingID, receiverGeneration: d.receiverGeneration,
                    sleepStore: interrupted, validate: {}
                )
                XCTFail("The injected journal removal interruption was not reached.")
            } catch JournalRemovalFault.Interruption.stop {}

            let outbox = try FileOutbox(directory: f.outbox.directoryURL)
            let sleep = try FileSleepSyncManifestStore(fileURL: manifest)
            XCTAssertEqual(try sleep.loadPendingTransition() != nil, !afterUnlink)
            XCTAssertNotNil(try outbox.directFinalizationRecordReady(receiverIdentity: d.receiverBindingID))
            XCTAssertEqual(try f.background.loadPendingObserverTypeCodeGenerations(), f.generations)
            let recovered = OutboxDeliveryCursorFinalizer(
                outbox: outbox, cursorStore: try FileSyncCursorStore(fileURL: f.root.appendingPathComponent("cursors.json")),
                pendingGenerationStore: f.background
            )
            let finished = try await recovered.finalizeDirectAcknowledgments(
                receiverBindingID: d.receiverBindingID, receiverGeneration: d.receiverGeneration,
                sleepStore: sleep, validate: {}
            )
            XCTAssertTrue(finished)
            XCTAssertNil(try sleep.loadPendingTransition())
            XCTAssertEqual(try sleep.loadManifest(), f.pending.manifest)
            XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: d.receiverBindingID))
            XCTAssertTrue(try outbox.pendingItems().isEmpty)
            XCTAssertTrue(try f.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        }
    }

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

    func testMailboxBoundSleepRejectsDirectAcceptanceWithoutChangingSleepState() async throws {
        let fixture = try DirectSleepFinalizationFixture()
        defer { fixture.remove() }
        let itemID = fixture.descriptor.itemID
        let payload = fixture.pending.payload
        let binding = try fixture.outbox.finalizeMailboxEnvelope(
            itemID: itemID, envelope: Data("synthetic-envelope".utf8),
            expectedPayloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        )

        do {
            _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: fixture.descriptor, sleepStore: fixture.sleep, validate: {}
            )
            XCTFail("A retained Direct response cannot retire a Mailbox-bound item.")
        } catch FileOutboxMailboxError.mailboxArtifactsRequireHold {}

        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initial)
        XCTAssertEqual(try fixture.sleep.loadPendingTransition(), fixture.pending)
        let item = try XCTUnwrap(fixture.outbox.pendingItem(id: itemID))
        XCTAssertEqual(item.mailboxBinding, binding)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
    }

    func testLegacyAcknowledgmentStillChecksMalformedSleepJournalBeforeFinalization() async throws {
        let fixture = try DirectSleepFinalizationFixture()
        defer { fixture.remove() }
        let descriptor = fixture.descriptor
        // This writer records a Direct ACK without a Sleep check.
        XCTAssertNotNil(try fixture.outbox.recordDirectUploadAccepted(
            itemID: descriptor.itemID, receiverIdentity: descriptor.receiverBindingID
        ))
        let journal = fixture.root.appendingPathComponent("sleep.json.pending")
        let originalJournal = try Data(contentsOf: journal)
        let damaged = Data("{".utf8)
        try damaged.write(to: journal)
        let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
        let finalizer = OutboxDeliveryCursorFinalizer(
            outbox: reopened,
            cursorStore: try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json")),
            pendingGenerationStore: fixture.background
        )

        do {
            _ = try await finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: descriptor, sleepStore: fixture.sleep, validate: {}
            )
            XCTFail("A legacy ACK does not establish that Sleep finalization already ran.")
        } catch is DecodingError {}

        do {
            let retired = try finalizer.finalizeDirectAcknowledgments(receiverBindingID: descriptor.receiverBindingID)
            XCTAssertFalse(retired, "General recovery cannot retire an unchecked legacy ACK.")
        } catch {
            // Recovery may report the unreadable journal instead of deferring.
        }
        XCTAssertEqual(try Data(contentsOf: journal), damaged)
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initial)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertNotNil(try reopened.directFinalizationRecordReady(receiverIdentity: descriptor.receiverBindingID))

        try originalJournal.write(to: journal, options: .atomic)
        do {
            _ = try await finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: descriptor, sleepStore: fixture.sleep, validate: {}
            )
            XCTFail("An unchecked ACK without the uploaded bytes cannot commit a new manifest.")
        } catch OutboxDeliveryCoordinatorError.ownershipMismatch {}
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initial)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertNotNil(try reopened.directFinalizationRecordReady(receiverIdentity: descriptor.receiverBindingID))

        // Model an upgrade after the matching manifest commit but before retirement.
        try fixture.sleep.saveManifest(fixture.pending.manifest)
        _ = try await finalizer.recordDirectReceiverAcceptanceForSync(
            descriptor: descriptor, sleepStore: fixture.sleep, validate: {}
        )
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.pending.manifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertNil(try reopened.directFinalizationRecordReady(receiverIdentity: descriptor.receiverBindingID))
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

private final class JournalRemovalFault: FileManager, @unchecked Sendable {
    enum Interruption: Error { case stop }
    let journal: URL
    let afterUnlink: Bool

    init(_ journal: URL, afterUnlink: Bool) {
        self.journal = journal
        self.afterUnlink = afterUnlink
        super.init()
    }

    override func removeItem(at url: URL) throws {
        guard url == journal else { return try super.removeItem(at: url) }
        if afterUnlink { try super.removeItem(at: url) }
        throw Interruption.stop
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

import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class DirectSleepFinalizationTests: XCTestCase {
    func testRetiredPlainDirectJournalCleanupRequiresMatchingBinding() throws {
        let f = try DirectSleepFinalizationFixture()
        defer { f.remove() }
        let directory = f.root.appendingPathComponent("plain-outbox")
        let journal = directory.appendingPathComponent(".enqueue-transaction")
        let oldBinding = "receiver-a"
        let newBinding = "receiver-b"
        let payload = try HealthBridgeBatchEncoder().encode(ConnectionTestBatchFactory.make(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let writer = try FileOutbox(directory: directory)
        let item = try writer.enqueue(payload, receiverIdentity: oldBinding)
        let cursors = try FileSyncCursorStore(fileURL: f.root.appendingPathComponent("cursors.json"))
        let interrupted = OutboxDeliveryCursorFinalizer(
            outbox: try FileOutbox(
                directory: directory, fileManager: JournalRemovalFault(journal, afterUnlink: false)
            ),
            cursorStore: cursors, pendingGenerationStore: f.background
        )
        var observedAcceptances = 0
        XCTAssertThrowsError(try interrupted.recordDirectReceiverAcceptance(
            itemID: item.id, receiverBindingID: oldBinding, sleepChecked: true,
            onNewAcceptance: { observedAcceptances += 1 }
        )) { XCTAssertTrue($0 is JournalRemovalFault.Interruption) }
        XCTAssertEqual(observedAcceptances, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))

        let outbox = try FileOutbox(directory: directory)
        let recovered = OutboxDeliveryCursorFinalizer(
            outbox: outbox, cursorStore: cursors, pendingGenerationStore: f.background
        )
        let receipt = try XCTUnwrap(outbox.directFinalizationRecordReady(receiverIdentity: oldBinding))
        XCTAssertEqual(receipt.itemIDs, [item.id])
        XCTAssertNil(receipt.cursorCheckpoint)
        XCTAssertTrue(receipt.pendingGenerationRetirements.isEmpty)
        XCTAssertNil(try outbox.directSleepCleanupIntent(for: receipt))
        XCTAssertTrue(try outbox.hasDirectAcknowledgmentWithSleepChecked(itemID: item.id, receiverIdentity: oldBinding))
        XCTAssertNil(try outbox.acceptedFinalizationHold())
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        let journalBefore = try Data(contentsOf: journal)
        XCTAssertFalse(try recovered.finalizeDirectAcknowledgments(receiverBindingID: newBinding))
        XCTAssertFalse(try outbox.retirePlainDirectReceiptsForConnectionTransition(receiverBindingID: nil))
        XCTAssertFalse(try outbox.retirePlainDirectReceiptsForConnectionTransition(receiverBindingID: newBinding))
        XCTAssertEqual(try Data(contentsOf: journal), journalBefore)

        XCTAssertTrue(try outbox.retirePlainDirectReceiptsForConnectionTransition(receiverBindingID: oldBinding))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: oldBinding))
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try f.background.loadPendingObserverTypeCodeGenerations(), f.generations)
        XCTAssertEqual(try f.sleep.loadPendingTransition(), f.pending)
    }

    func testDirectRecoveryCleansAcceptedSleepBeforeNextItemInCheckpointTransaction() async throws {
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "receiver-a", sourceKey: "synthetic-source",
            cursorKind: "synthetic-anchor", cursorValue: "next-checkpoint"
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let nextPayload = try HealthBridgeBatchEncoder().encode(StepCountSyncBatchFactory.makeAnchoredStepBatch(
            changes: HealthKitAnchoredStepChanges(
                stepSamples: [HealthKitStepSampleSummary(
                    uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000173")),
                    start: start, end: start.addingTimeInterval(60), count: 17
                )],
                deletedStepSamples: [], anchorCursorValue: checkpoint.cursorValue,
                windowStart: start, windowEnd: start.addingTimeInterval(3600)
            ),
            generatedAt: start.addingTimeInterval(3600)
        ))
        let f = try DirectSleepFinalizationFixture(checkpoint: checkpoint, nextPayload: nextPayload)
        defer { f.remove() }
        let a = f.descriptor
        let b = try XCTUnwrap(f.nextItem)
        let cursorURL = f.root.appendingPathComponent("cursors.json")
        let previousCursor = "previous-checkpoint"
        try FileSyncCursorStore(fileURL: cursorURL).saveCursorValue(
            previousCursor, receiverBindingID: a.receiverBindingID,
            sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
        )
        let manifestURL = f.root.appendingPathComponent("sleep.json")
        let interrupted = try FileSleepSyncManifestStore(
            fileURL: manifestURL,
            fileManager: JournalRemovalFault(f.root.appendingPathComponent("sleep.json.pending"), afterUnlink: false)
        )
        XCTAssertEqual(try f.outbox.uploadablePendingItems(for: a.receiverBindingID).map(\.id), [a.itemID, b.id])
        var acceptedIDs: [String] = []
        do {
            _ = try await f.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: a, sleepStore: interrupted, validate: {}, onNewAcceptance: { acceptedIDs.append(a.itemID) }
            )
            XCTFail("Expected interruption before unlinking A's Sleep journal.")
            return
        } catch JournalRemovalFault.Interruption.stop {}

        let outbox = try FileOutbox(directory: f.outbox.directoryURL)
        let sleep = try FileSleepSyncManifestStore(fileURL: manifestURL)
        let cursors = try FileSyncCursorStore(fileURL: cursorURL)
        let background = BackgroundSyncSettingsStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: f.suite)))
        let recovered = OutboxDeliveryCursorFinalizer(
            outbox: outbox, cursorStore: cursors, pendingGenerationStore: background
        )
        func cursorValue() throws -> String? {
            try cursors.cursorValue(
                receiverBindingID: a.receiverBindingID, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
            )
        }
        XCTAssertEqual(acceptedIDs, [a.itemID])
        XCTAssertEqual(try sleep.loadManifest(), f.pending.manifest)
        XCTAssertEqual(try sleep.loadPendingTransition(), f.pending)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [a.itemID, b.id])
        XCTAssertEqual(try outbox.uploadablePendingItems(for: a.receiverBindingID).map(\.id), [])
        XCTAssertEqual(try cursorValue(), previousCursor)
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), f.generations)

        // Recover through the same entry used before scheduling Direct uploads, without replaying A.
        _ = try await recovered.finalizeDirectAcknowledgments(
            receiverBindingID: a.receiverBindingID, receiverGeneration: a.receiverGeneration,
            sleepStore: sleep, validate: {}
        )
        XCTAssertNil(try sleep.loadPendingTransition(), "Recovery must clear A's journal while B is still unacknowledged.")
        XCTAssertEqual(try sleep.loadManifest(), f.pending.manifest)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [b.id])
        XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: a.receiverBindingID))
        XCTAssertFalse(try outbox.retirePlainDirectReceiptsForConnectionTransition(receiverBindingID: a.receiverBindingID))
        XCTAssertEqual(try cursorValue(), previousCursor)
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), f.generations)
        let uploadableIDs = try outbox.uploadablePendingItems(for: a.receiverBindingID).map(\.id)
        XCTAssertEqual(uploadableIDs, [b.id], "Recovery must unblock B without making accepted A uploadable again.")
        guard uploadableIDs == [b.id] else { return }

        let completed = try await recovered.recordDirectReceiverAcceptanceForSync(
            descriptor: DirectUploadCompletionDescriptor(
                itemID: b.id, receiverGeneration: a.receiverGeneration, receiverBindingID: a.receiverBindingID
            ),
            sleepStore: sleep, validate: {}, onNewAcceptance: { acceptedIDs.append(b.id) }
        )
        XCTAssertTrue(completed)
        XCTAssertEqual(acceptedIDs, [a.itemID, b.id])
        XCTAssertEqual(try cursorValue(), checkpoint.cursorValue)
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), [:])
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [])
        XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: a.receiverBindingID))
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertEqual(try sleep.loadManifest(), f.pending.manifest)
    }

    func testCursorBackedSleepCleanupHoldsDowngradeOnlyWhileIntentIsActive() async throws {
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "receiver-a", sourceKey: "synthetic-source",
            cursorKind: "synthetic-anchor", cursorValue: "next-checkpoint"
        )
        let sibling = try HealthBridgeBatchEncoder().encode(ConnectionTestBatchFactory.make(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let f = try DirectSleepFinalizationFixture(checkpoint: checkpoint, nextPayload: sibling)
        defer { f.remove() }
        let d = f.descriptor
        let directory = f.outbox.directoryURL
        let manifest = f.root.appendingPathComponent("sleep.json")
        let interrupted = try FileSleepSyncManifestStore(
            fileURL: manifest,
            fileManager: JournalRemovalFault(f.root.appendingPathComponent("sleep.json.pending"), afterUnlink: false)
        )
        XCTAssertEqual(try f.outbox.downgradeReadiness(), .ready)
        XCTAssertNoThrow(try FileOutbox.assertReadableByLegacyV3Reader(directory: directory))
        do {
            _ = try await f.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: d, sleepStore: interrupted, validate: {}
            )
            XCTFail("Expected a durable cursor-backed ACK before the injected unlink failure.")
            return
        } catch JournalRemovalFault.Interruption.stop {}

        let reopened = try FileOutbox(directory: directory)
        let journal = directory.appendingPathComponent(".enqueue-transaction")
        let beforeCleanup = try Data(contentsOf: journal)
        XCTAssertTrue(try reopened.hasDirectSleepCleanupIntent(
            itemID: d.itemID, receiverBindingID: d.receiverBindingID, receiverGeneration: d.receiverGeneration
        ))
        XCTAssertNotEqual(try reopened.downgradeReadiness(), .ready)
        XCTAssertThrowsError(try FileOutbox.assertReadableByLegacyV3Reader(directory: directory)) {
            XCTAssertEqual($0 as? FileOutboxMailboxError, .legacyReaderCannotOpen)
        }
        XCTAssertEqual(try Data(contentsOf: journal), beforeCleanup)

        let sleep = try FileSleepSyncManifestStore(fileURL: manifest)
        let recovered = OutboxDeliveryCursorFinalizer(
            outbox: reopened, cursorStore: try FileSyncCursorStore(fileURL: f.root.appendingPathComponent("cursors.json")),
            pendingGenerationStore: f.background
        )
        let cleaned = try await recovered.finalizeDirectAcknowledgments(
            receiverBindingID: d.receiverBindingID, receiverGeneration: d.receiverGeneration,
            sleepStore: sleep, validate: {}
        )
        XCTAssertTrue(cleaned)
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path), "The sibling still needs the cursor journal.")
        XCTAssertEqual(try reopened.pendingItems().map(\.id), [try XCTUnwrap(f.nextItem).id])
        XCTAssertEqual(try reopened.downgradeReadiness(), .ready)
        XCTAssertNoThrow(try FileOutbox.assertReadableByLegacyV3Reader(directory: directory))
    }

    func testGeneratedSleepIntentCanCoexistWithEarlierUncheckedLegacyAcknowledgment() async throws {
        try await assertScopedSleepRecovery(legacyAcknowledgedSleep: false)
    }

    func testLegacySleepIntentCanBeReconstructedAlongsideEarlierUncheckedAcknowledgment() async throws {
        try await assertScopedSleepRecovery(legacyAcknowledgedSleep: true)
    }

    func testAcceptedSleepRevisionCannotAdoptReplacementJournalAtCommit() async throws {
        let f = try DirectSleepFinalizationFixture()
        defer { f.remove() }
        let accepted = try f.sleep.revisionForSync()
        let replacement = SleepSyncPendingTransition(
            payload: f.pending.payload, manifest: f.pending.manifest,
            receiverBindingID: f.pending.receiverBindingID, connectionGeneration: f.pending.connectionGeneration,
            outboxItemID: f.descriptor.itemID
        )
        var reads = 0
        func store() throws -> FileSleepSyncManifestStore {
            reads += 1
            if reads == 2 { try f.sleep.savePendingTransition(replacement) }
            return f.sleep
        }
        do {
            _ = try await f.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: f.descriptor, sleepStore: store(), acceptedSleepRevision: accepted,
                validate: {}, validatePending: {}, onNewAcceptance: { XCTFail("Wrong journal credited") }
            )
            XCTFail("Expected stale revision to cancel")
        } catch is CancellationError {}
        XCTAssertEqual(try f.sleep.loadPendingTransition(), replacement)
        XCTAssertEqual(try f.sleep.loadManifest(), f.initial)
        XCTAssertNotNil(try f.outbox.pendingItem(id: f.descriptor.itemID))
    }

    func testReceiverWideRecoveryFindsPendingSleepBehindIndependentReadyReceipts() async throws {
        let binding = "receiver-a"
        let steps = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: "steps-source", cursorKind: "steps-anchor", cursorValue: "steps"
        )
        let unknown = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: "older-sleep-source",
            cursorKind: SleepSyncBatchFactory.anchoredCursorKind, cursorValue: "unknown"
        )
        let target = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: "target-sleep-source",
            cursorKind: SleepSyncBatchFactory.anchoredCursorKind, cursorValue: "target"
        )
        let older = try DirectSleepFinalizationFixture()
        defer { older.remove() }
        let f = try DirectSleepFinalizationFixture(
            checkpoint: target, leadingTransactions: [(try stepsPayload(), steps), (older.pending.payload, unknown)]
        )
        defer { f.remove() }
        let ids = try f.outbox.pendingItems().map(\.id)
        XCTAssertEqual(ids.count, 3)
        let olderSleepID = try XCTUnwrap(ids.dropFirst().first)
        let descriptor = f.descriptor
        for id in ids {
            XCTAssertNotNil(try f.outbox.recordDirectUploadAccepted(itemID: id, receiverIdentity: binding))
        }
        try f.sleep.saveManifest(f.pending.manifest)
        let outbox = try FileOutbox(directory: f.outbox.directoryURL)
        let cursor = try FileSyncCursorStore(fileURL: f.root.appendingPathComponent("cursors.json"))
        let sleep = try FileSleepSyncManifestStore(fileURL: f.root.appendingPathComponent("sleep.json"))
        let finalizer = OutboxDeliveryCursorFinalizer(
            outbox: outbox, cursorStore: cursor, pendingGenerationStore: f.background
        )
        func value(_ checkpoint: FileOutboxCursorCheckpoint) throws -> String? {
            try cursor.cursorValue(
                receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
            )
        }
        let journal = outbox.directoryURL.appendingPathComponent(".enqueue-transaction")
        let original = try Data(contentsOf: journal)
        let foreign = try await finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: "receiver-b", receiverGeneration: descriptor.receiverGeneration,
            sleepStore: sleep, validate: {}
        )
        XCTAssertFalse(foreign)
        XCTAssertEqual(try Data(contentsOf: journal), original)

        // A corrupt head is an error, not a failed match that recovery may bypass.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var transactions = try XCTUnwrap(object["transactions"] as? [[String: Any]])
        transactions[0]["directSleepCheckedItemIDs"] = [descriptor.itemID]
        object["transactions"] = transactions
        let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try corrupt.write(to: journal, options: .atomic)
        do {
            _ = try await finalizer.finalizeDirectAcknowledgments(
                receiverBindingID: binding, receiverGeneration: descriptor.receiverGeneration,
                sleepStore: sleep, validate: {}
            )
            XCTFail("Expected the corrupt journal to stop recovery.")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: journal), corrupt)
        XCTAssertEqual(try sleep.loadPendingTransition(), f.pending)
        XCTAssertNil(try value(steps))
        XCTAssertNil(try value(target))
        try original.write(to: journal, options: .atomic)

        let retiredSteps = try await finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: descriptor.receiverGeneration,
            sleepStore: sleep, validate: {}
        )
        XCTAssertTrue(retiredSteps)
        let recovered = try await finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: descriptor.receiverGeneration,
            sleepStore: sleep, validate: {}
        )
        XCTAssertTrue(recovered)
        XCTAssertEqual(try value(steps), steps.cursorValue)
        XCTAssertEqual(try value(target), target.cursorValue)
        XCTAssertNil(try value(unknown))
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertEqual(try sleep.loadManifest(), f.pending.manifest)
        XCTAssertTrue(try f.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        let reopened = try FileOutbox(directory: outbox.directoryURL)
        XCTAssertEqual(try reopened.directFinalizationRecordReady(receiverIdentity: binding)?.itemIDs, [olderSleepID])
        XCTAssertTrue(try reopened.hasUncheckedDirectAcknowledgment(itemID: olderSleepID, receiverBindingID: binding))
        XCTAssertTrue(try reopened.uploadablePendingItems(for: binding).isEmpty)
    }

    func testMixedLegacyRecoveryUsesSurvivingStepsPayloadBeforeRetiringIt() async throws {
        try await assertMixedLegacyRecovery(stepsPayloadSurvives: true)
    }

    func testMixedLegacyRecoveryCannotInferStepsProvenanceAfterPayloadIsGone() async throws {
        try await assertMixedLegacyRecovery(stepsPayloadSurvives: false)
    }

    func testMixedLegacyRecoveryDoesNotTrustCorruptedSurvivingStepsPayload() async throws {
        try await assertMixedLegacyRecovery(stepsPayloadSurvives: true, corruptStepsPayload: true)
    }

    private func assertMixedLegacyRecovery(
        stepsPayloadSurvives: Bool, corruptStepsPayload: Bool = false
    ) async throws {
        let binding = "receiver-a"
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: "mixed-source", cursorKind: "mixed-anchor", cursorValue: "accepted"
        )
        let bytes = try stepsPayload()
        let f = try DirectSleepFinalizationFixture(checkpoint: checkpoint, leadingPayload: bytes)
        defer { f.remove() }
        let steps = try XCTUnwrap(f.previousItem)
        let target = f.descriptor
        let directory = f.outbox.directoryURL
        let sleepItem = try XCTUnwrap(f.outbox.pendingItem(id: target.itemID))
        try f.sleep.saveManifest(f.pending.manifest)
        // Publish the same receipt shape as the old writer, without invoking
        // the current writer's retirement path before the cold owner opens it.
        let journal = directory.appendingPathComponent(".enqueue-transaction")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        var transactions = try XCTUnwrap(object["transactions"] as? [[String: Any]])
        XCTAssertEqual(transactions.count, 1)
        XCTAssertNil(transactions[0]["directSleepCheckedItemIDs"])
        XCTAssertNil(transactions[0]["directSleepCleanupIntent"])
        transactions[0]["directAcknowledgedItemIDs"] = [steps.id, target.itemID].sorted()
        object["transactions"] = transactions
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: journal, options: .atomic)
        try FileManager.default.removeItem(at: sleepItem.fileURL)
        if !stepsPayloadSurvives {
            try FileManager.default.removeItem(at: steps.fileURL)
        } else if corruptStepsPayload {
            try Data("{}".utf8).write(to: steps.fileURL)
        }
        let stepsProven = stepsPayloadSurvives && !corruptStepsPayload
        let outbox = try FileOutbox(directory: directory)
        let cursor = try FileSyncCursorStore(fileURL: f.root.appendingPathComponent("cursors.json"))
        let sleep = try FileSleepSyncManifestStore(fileURL: f.root.appendingPathComponent("sleep.json"))
        let finalizer = OutboxDeliveryCursorFinalizer(
            outbox: outbox, cursorStore: cursor, pendingGenerationStore: f.background
        )
        let stale = try await finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: "generation-other", sleepStore: sleep, validate: {}
        )
        XCTAssertFalse(stale)
        XCTAssertEqual(try sleep.loadPendingTransition(), f.pending)
        let finished = try await finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: target.receiverGeneration, sleepStore: sleep, validate: {}
        )
        XCTAssertTrue(finished, "Sleep's own scoped cleanup must progress in both cases.")
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertEqual(try sleep.loadManifest(), f.pending.manifest)
        let reopened = try FileOutbox(directory: directory)
        XCTAssertTrue(try reopened.uploadablePendingItems(for: binding).isEmpty)
        let value = try cursor.cursorValue(
            receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
        )
        XCTAssertEqual(value, stepsProven ? checkpoint.cursorValue : nil)
        XCTAssertEqual(
            try f.background.loadPendingObserverTypeCodeGenerations(), stepsProven ? [:] : f.generations
        )
        if stepsProven {
            XCTAssertNil(try reopened.directFinalizationRecordReady(receiverIdentity: binding))
        } else {
            XCTAssertTrue(try reopened.hasUncheckedDirectAcknowledgment(itemID: steps.id, receiverBindingID: binding))
            XCTAssertTrue(try reopened.hasDirectAcknowledgmentWithSleepChecked(
                itemID: target.itemID, receiverIdentity: binding
            ))
        }
    }

    private func stepsPayload() throws -> Data {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return try HealthBridgeBatchEncoder().encode(StepCountSyncBatchFactory.makeAnchoredStepBatch(
            changes: HealthKitAnchoredStepChanges(
                stepSamples: [HealthKitStepSampleSummary(
                    uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000186")),
                    start: start, end: start.addingTimeInterval(60), count: 18
                )],
                deletedStepSamples: [], anchorCursorValue: "steps-anchor",
                windowStart: start, windowEnd: start.addingTimeInterval(3600)
            ),
            generatedAt: start.addingTimeInterval(3600)
        ))
    }

    private func assertScopedSleepRecovery(legacyAcknowledgedSleep: Bool) async throws {
        let earlier = try DirectSleepFinalizationFixture()
        defer { earlier.remove() }
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "receiver-a", sourceKey: "synthetic-source",
            cursorKind: "synthetic-anchor", cursorValue: "next-checkpoint"
        )
        let f = try DirectSleepFinalizationFixture(checkpoint: checkpoint, leadingPayload: earlier.pending.payload)
        defer { f.remove() }
        let a = try XCTUnwrap(f.previousItem)
        let b = f.descriptor
        let binding = b.receiverBindingID
        let generation = b.receiverGeneration
        let directory = f.outbox.directoryURL
        let journal = directory.appendingPathComponent(".enqueue-transaction")
        let manifest = f.root.appendingPathComponent("sleep.json")
        let cursorStore = try FileSyncCursorStore(fileURL: f.root.appendingPathComponent("cursors.json"))
        func cursorValue() throws -> String? {
            try cursorStore.cursorValue(
                receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
            )
        }
        try cursorStore.saveCursorValue(
            "old-checkpoint", receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
        )
        // The old writer omits both Sleep fields; A's payload is retired, but no Sleep check exists.
        XCTAssertNil(try f.outbox.recordDirectUploadAccepted(itemID: a.id, receiverIdentity: binding))
        if legacyAcknowledgedSleep {
            XCTAssertNotNil(try f.outbox.recordDirectUploadAccepted(itemID: b.itemID, receiverIdentity: binding))
        }
        let legacyJournal = try Data(contentsOf: journal)
        let writer = try FileOutbox(directory: directory)
        let finalizer = OutboxDeliveryCursorFinalizer(
            outbox: writer, cursorStore: cursorStore, pendingGenerationStore: f.background
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.fileURL.path))
        XCTAssertEqual(try writer.acceptedFinalizationHold()?.reason, .proofMissing)
        XCTAssertTrue(try writer.hasUncheckedDirectAcknowledgment(itemID: a.id, receiverBindingID: binding))

        // Even the old ACK cannot prove a not-yet-committed Sleep transition.
        let uncommitted = try await finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: generation, sleepStore: f.sleep, validate: {}
        )
        XCTAssertFalse(uncommitted)
        XCTAssertEqual(try f.sleep.loadPendingTransition(), f.pending)
        XCTAssertEqual(try Data(contentsOf: journal), legacyJournal)
        try f.sleep.saveManifest(f.pending.manifest)
        if legacyAcknowledgedSleep {
            let wrongItem = try await finalizer.recoverDirectSleepAcknowledgment(
                itemID: a.id, receiverBindingID: binding, receiverGeneration: generation,
                sleepStore: f.sleep, validate: {}
            )
            XCTAssertFalse(wrongItem, "A's callback cannot claim B's journal, even with B's manifest committed.")
        } else {
            let withoutBReceipt = try await finalizer.finalizeDirectAcknowledgments(
                receiverBindingID: binding, receiverGeneration: generation, sleepStore: f.sleep, validate: {}
            )
            XCTAssertFalse(withoutBReceipt, "A's legacy receipt cannot authorize B's cleanup.")
            try f.sleep.saveManifest(f.initial)
        }
        XCTAssertEqual(try f.sleep.loadPendingTransition(), f.pending)
        XCTAssertEqual(try Data(contentsOf: journal), legacyJournal)
        let interrupted = try FileSleepSyncManifestStore(
            fileURL: manifest,
            fileManager: JournalRemovalFault(f.root.appendingPathComponent("sleep.json.pending"), afterUnlink: false)
        )
        var newAcceptances: [String] = []
        do {
            if legacyAcknowledgedSleep {
                _ = try await finalizer.finalizeDirectAcknowledgments(
                    receiverBindingID: binding, receiverGeneration: generation, sleepStore: interrupted, validate: {}
                )
            } else {
                _ = try await finalizer.recordDirectReceiverAcceptanceForSync(
                    descriptor: b, sleepStore: interrupted, validate: {},
                    onNewAcceptance: { newAcceptances.append(b.itemID) }
                )
            }
            XCTFail("Expected B's item-scoped intent to persist before interruption.")
            return
        } catch JournalRemovalFault.Interruption.stop {}
        XCTAssertEqual(newAcceptances, legacyAcknowledgedSleep ? [] : [b.itemID])

        let reopened = try FileOutbox(directory: directory)
        let sleep = try FileSleepSyncManifestStore(fileURL: manifest)
        let recovered = OutboxDeliveryCursorFinalizer(
            outbox: reopened, cursorStore: cursorStore, pendingGenerationStore: f.background
        )
        XCTAssertTrue(try reopened.hasDirectSleepCleanupIntent(
            itemID: b.itemID, receiverBindingID: binding, receiverGeneration: generation
        ))
        XCTAssertTrue(try reopened.uploadablePendingItems(for: binding).isEmpty)
        let wrongItemAfterRestart = try await recovered.recoverDirectSleepAcknowledgment(
            itemID: a.id, receiverBindingID: binding, receiverGeneration: generation,
            sleepStore: sleep, validate: {}
        )
        XCTAssertFalse(wrongItemAfterRestart)
        XCTAssertEqual(try reopened.acceptedFinalizationHold()?.reason, .proofMissing,
                       "B's scoped intent cannot cover A's missing proof.")
        XCTAssertEqual(try sleep.loadPendingTransition(), f.pending)
        let cleaned = try await recovered.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: generation, sleepStore: sleep, validate: {}
        )
        XCTAssertTrue(cleaned, "B's cleanup is independently recoverable after reopening.")
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertEqual(try sleep.loadManifest(), f.pending.manifest)
        XCTAssertTrue(try reopened.pendingItems().isEmpty)
        XCTAssertTrue(try reopened.hasDirectAcknowledgmentWithSleepChecked(itemID: b.itemID, receiverIdentity: binding))
        XCTAssertTrue(try reopened.hasUncheckedDirectAcknowledgment(itemID: a.id, receiverBindingID: binding))
        XCTAssertEqual(try reopened.acceptedFinalizationHold()?.reason, .proofMissing)
        XCTAssertEqual(try cursorValue(), "old-checkpoint")
        XCTAssertEqual(try f.background.loadPendingObserverTypeCodeGenerations(), f.generations)
        let withoutAuthority = try await recovered.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: generation, sleepStore: sleep, validate: {}
        )
        XCTAssertFalse(withoutAuthority, "B's checked ACK does not establish A's check.")
        XCTAssertEqual(try cursorValue(), "old-checkpoint")
        XCTAssertEqual(try f.background.loadPendingObserverTypeCodeGenerations(), f.generations)

        // A must supply its own exact pending transition and committed manifest.
        let aPending = earlier.pending.assigningOutboxItemID(a.id)
        try sleep.savePendingTransition(aPending)
        try sleep.saveManifest(aPending.manifest)
        let aChecked = try await recovered.recoverDirectSleepAcknowledgment(
            itemID: a.id, receiverBindingID: binding, receiverGeneration: generation, sleepStore: sleep, validate: {}
        )
        XCTAssertTrue(aChecked)
        XCTAssertNil(try reopened.acceptedFinalizationHold())
        let replay = try await recovered.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: generation, sleepStore: sleep, validate: {}
        )
        XCTAssertFalse(replay)
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertEqual(try cursorValue(), checkpoint.cursorValue)
        XCTAssertTrue(try f.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testLegacyMissingJournalWithoutCleanupIntentRetainsAcceptedOwnership() async throws {
        let f = try DirectSleepFinalizationFixture()
        defer { f.remove() }
        let d = f.descriptor
        let manifestURL = f.root.appendingPathComponent("sleep.json")
        let record = try XCTUnwrap(f.outbox.recordDirectUploadAccepted(
            itemID: d.itemID, receiverIdentity: d.receiverBindingID
        ))
        try f.sleep.saveManifest(f.pending.manifest)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("sleep.json.pending"))

        let outbox = try FileOutbox(directory: f.outbox.directoryURL)
        let sleep = try FileSleepSyncManifestStore(fileURL: manifestURL)
        let recovered = OutboxDeliveryCursorFinalizer(
            outbox: outbox, cursorStore: try FileSyncCursorStore(fileURL: f.root.appendingPathComponent("cursors.json")),
            pendingGenerationStore: f.background
        )
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertFalse(try outbox.retirePlainDirectReceiptsForConnectionTransition(receiverBindingID: d.receiverBindingID))
        let journal = outbox.directoryURL.appendingPathComponent(".enqueue-transaction")
        let before = try Data(contentsOf: journal)
        let hold = try XCTUnwrap(outbox.acceptedFinalizationHold())
        XCTAssertEqual(hold.reason, .proofMissing)
        XCTAssertEqual(hold.affectedTypeCodes, ["sleep_analysis"])
        XCTAssertEqual(try Data(contentsOf: journal), before)
        let finished = try await recovered.finalizeDirectAcknowledgments(
            receiverBindingID: d.receiverBindingID, receiverGeneration: d.receiverGeneration,
            sleepStore: sleep, validate: {}
        )
        XCTAssertFalse(finished, "A manifest and an absent journal do not bind this unchecked ACK to a transition.")
        XCTAssertEqual(try outbox.directFinalizationRecordReady(receiverIdentity: d.receiverBindingID), record)
        XCTAssertEqual(try f.background.loadPendingObserverTypeCodeGenerations(), f.generations)
        XCTAssertEqual(try sleep.loadManifest(), f.pending.manifest)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
    }

    func testIndependentStepsAndWorkoutReceiptsFinalizeWhileSleepProofIsMissing() throws {
        let f = try DirectSleepFinalizationFixture()
        defer { f.remove() }
        let binding = f.descriptor.receiverBindingID
        let outbox = f.outbox
        XCTAssertNotNil(try outbox.recordDirectUploadAccepted(itemID: f.descriptor.itemID, receiverIdentity: binding))
        try f.sleep.clearPendingTransition(id: f.pending.id)
        let cursors = try FileSyncCursorStore(fileURL: f.root.appendingPathComponent("metric-cursors.json"))
        let finalizer = OutboxDeliveryCursorFinalizer(outbox: outbox, cursorStore: cursors)
        for kind in [StepCountSyncBatchFactory.anchoredCursorKind, WorkoutSyncBatchFactory.anchoredCursorKind] {
            let checkpoint = FileOutboxCursorCheckpoint(
                receiverIdentity: binding, sourceKey: "synthetic-source", cursorKind: kind, cursorValue: "next"
            )
            let item = try XCTUnwrap(outbox.enqueueSequence(
                [Data("{}".utf8)], receiverIdentity: binding, cursorCheckpoint: checkpoint
            ).first)
            XCTAssertNotNil(try outbox.recordDirectUploadAccepted(itemID: item.id, receiverIdentity: binding))
            XCTAssertEqual(try outbox.acceptedFinalizationHold()?.affectedTypeCodes, ["sleep_analysis"])
            XCTAssertTrue(try finalizer.finalizeDirectAcknowledgments(receiverBindingID: binding))
            XCTAssertEqual(try cursors.cursorValue(
                receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: kind
            ), "next")
        }
        XCTAssertEqual(try outbox.acceptedFinalizationHold()?.reason, .proofMissing)
        XCTAssertEqual(try f.background.loadPendingObserverTypeCodeGenerations(), f.generations)
    }

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
            XCTAssertEqual(try outbox.acceptedFinalizationHold()?.reason, .cleanupPending)
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
            XCTAssertNil(try outbox.acceptedFinalizationHold())
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

    func testMismatchedDirectSleepOwnershipCannotWriteAndMatchingReplayCan() async throws {
        let fixture = try DirectSleepFinalizationFixture()
        defer { fixture.remove() }
        let pending = fixture.pending
        let binding = pending.receiverBindingID
        let generation = pending.connectionGeneration
        let manifest = pending.manifest
        let wrongManifest = SleepSyncManifest(
            schemaVersion: manifest.schemaVersion, receiverSettingsGeneration: "superseded-generation",
            historyDepth: manifest.historyDepth, historyStartDate: manifest.historyStartDate,
            sourceKey: manifest.sourceKey, baselineResetEpoch: manifest.baselineResetEpoch,
            identityNamespace: manifest.identityNamespace, nextRevisionSequence: manifest.nextRevisionSequence,
            anchorCursorValue: manifest.anchorCursorValue, activeChildSamples: manifest.activeChildSamples,
            publishedSessions: manifest.publishedSessions, baselineResetPending: manifest.baselineResetPending
        )
        let wrongBinding = "different-receiver"
        let cases: [(label: String, journalBinding: String, generation: String, manifest: SleepSyncManifest,
                     descriptorBinding: String, rejectionEpoch: UInt64?)] = [
            ("journal binding", wrongBinding, generation, manifest, binding, nil),
            ("journal generation", binding, "superseded-generation", manifest, binding, nil),
            ("manifest generation", binding, generation, wrongManifest, binding, nil),
            ("FIFO owner", wrongBinding, generation, manifest, wrongBinding, nil),
            ("rejected journal", binding, generation, manifest, binding, 57),
        ]
        for input in cases {
            let journal = SleepSyncPendingTransition(
                id: pending.id, payload: pending.payload, manifest: input.manifest,
                receiverBindingID: input.journalBinding, connectionGeneration: input.generation,
                outboxItemID: pending.outboxItemID, rejectedMinimumResetEpoch: input.rejectionEpoch
            )
            try fixture.sleep.savePendingTransition(journal)
            let revision = try fixture.sleep.revisionForSync()
            let descriptor = DirectUploadCompletionDescriptor(
                itemID: fixture.descriptor.itemID, receiverGeneration: generation,
                receiverBindingID: input.descriptorBinding
            )
            var acknowledgments = 0
            do {
                _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
                    descriptor: descriptor, sleepStore: fixture.sleep, validate: {},
                    onNewAcceptance: { acknowledgments += 1 }
                )
                XCTFail("Unexpected acceptance for \(input.label)")
            } catch OutboxDeliveryCoordinatorError.ownershipMismatch {
                XCTAssertEqual(input.descriptorBinding, binding, input.label)
            } catch ReceiverOutboxIdentityError.oldestItemBelongsToDifferentReceiver {
                XCTAssertNotEqual(input.descriptorBinding, binding, input.label)
            }
            let sleep = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
            let outbox = try FileOutbox(directory: fixture.outbox.directoryURL)
            XCTAssertEqual(acknowledgments, 0, input.label)
            XCTAssertEqual(try sleep.revisionForSync(), revision, input.label)
            XCTAssertEqual(try sleep.loadManifest(), fixture.initial, input.label)
            XCTAssertEqual(try sleep.loadPendingTransition(), journal, input.label)
            let items = try outbox.pendingItems()
            XCTAssertEqual(items.map(\.id), [descriptor.itemID], input.label)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(items.first).fileURL), pending.payload, input.label)
            XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: binding), input.label)
            XCTAssertFalse(try outbox.hasPendingDirectSleepCleanup(), input.label)
            XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations, input.label)
        }

        try fixture.sleep.savePendingTransition(pending)
        let finalized = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
            descriptor: fixture.descriptor, sleepStore: fixture.sleep, validate: {}
        )
        XCTAssertTrue(finalized)
        XCTAssertEqual(try fixture.sleep.loadManifest(), manifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
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

    func testEqualBytesCannotTakeAnotherPendingItemsAssignedJournal() async throws {
        let fixture = try DirectSleepFinalizationFixture()
        defer { fixture.remove() }
        let descriptor = fixture.descriptor
        let other = try fixture.outbox.enqueue(fixture.pending.payload, receiverIdentity: descriptor.receiverBindingID)
        let journal = fixture.pending.assigningOutboxItemID(other.id)
        try fixture.sleep.savePendingTransition(journal)
        var acknowledgments = 0
        do {
            _ = try await fixture.finalizer.recordDirectReceiverAcceptanceForSync(
                descriptor: descriptor, sleepStore: fixture.sleep, validate: {},
                onNewAcceptance: { acknowledgments += 1 }
            )
            XCTFail("Matching bytes cannot transfer an existing FIFO item's Sleep journal.")
        } catch OutboxDeliveryCoordinatorError.ownershipMismatch {}

        let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
        let sleep = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        XCTAssertEqual(acknowledgments, 0)
        XCTAssertEqual(try sleep.loadPendingTransition(), journal)
        XCTAssertEqual(try sleep.loadManifest(), fixture.initial)
        XCTAssertEqual(try reopened.pendingItems().map(\.id), [descriptor.itemID, other.id])
        XCTAssertNil(try reopened.directFinalizationRecordReady(receiverIdentity: descriptor.receiverBindingID))
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
    let nextItem: FileOutboxItem?
    let previousItem: FileOutboxItem?

    init(
        checkpoint: FileOutboxCursorCheckpoint? = nil, nextPayload: Data? = nil, leadingPayload: Data? = nil,
        leadingTransactions: [(Data, FileOutboxCursorCheckpoint)] = []
    ) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.markPendingObserverTypeCodes(["sleep_analysis"])
        generations = try background.loadPendingObserverTypeCodeGenerations()
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        for (payload, checkpoint) in leadingTransactions {
            _ = try outbox.enqueueSequence(
                [payload], receiverIdentity: checkpoint.receiverIdentity, cursorCheckpoint: checkpoint
            )
        }
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
        let items = try outbox.enqueueSequence(
            (leadingPayload.map { [$0] } ?? []) + [payload] + (nextPayload.map { [$0] } ?? []),
            receiverIdentity: "receiver-a",
            cursorCheckpoint: checkpoint, pendingGenerationRetirements: generations
        )
        let item = try XCTUnwrap(items.dropFirst(leadingPayload == nil ? 0 : 1).first)
        previousItem = leadingPayload == nil ? nil : items.first
        nextItem = nextPayload == nil ? nil : items.last
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

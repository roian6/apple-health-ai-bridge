import CryptoKit
import XCTest
@testable import HealthBridgeCompanionCore

final class FileOutboxTests: XCTestCase {
    func testReceiverBoundEnqueueIfAbsentReusesCrashWindowPayload() throws {
        let directory = temporaryOutboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        let payload = Data("sleep-transition".utf8)

        let first = try outbox.enqueueIfAbsent(
            payload,
            receiverIdentity: "receiver-a"
        )
        let recovered = try outbox.enqueueIfAbsent(
            payload,
            receiverIdentity: "receiver-a"
        )
        let differentReceiver = try outbox.enqueueIfAbsent(
            payload,
            receiverIdentity: "receiver-b"
        )

        XCTAssertTrue(first.wasInserted)
        XCTAssertFalse(recovered.wasInserted)
        XCTAssertEqual(recovered.item.id, first.item.id)
        XCTAssertTrue(differentReceiver.wasInserted)
        XCTAssertEqual(try outbox.pendingItems().count, 2)
    }

    func testSequenceEnqueueCommitsEveryPayloadInFifoOrder() throws {
        let directory = temporaryOutboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        let payloads = ["one", "two", "three"].map { Data($0.utf8) }

        let items = try outbox.enqueueSequence(
            payloads,
            receiverIdentity: "receiver-a"
        )
        let pending = try outbox.pendingItems()

        XCTAssertEqual(items.map(\.id), pending.map(\.id))
        XCTAssertEqual(
            try pending.map { try Data(contentsOf: $0.fileURL) },
            payloads
        )
        XCTAssertEqual(pending.map(\.receiverIdentity), Array(repeating: "receiver-a", count: 3))
    }

    func testFullyStagedSequenceRecoversAllItemsAfterCrashWindow() throws {
        let directory = temporaryOutboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloads = [Data("one".utf8), Data("two".utf8)]
        let interrupted = try FileOutbox(directory: directory)
        try interrupted.stageEnqueueSequenceForTesting(
            payloads,
            receiverIdentity: "receiver-a",
            stagedPayloadCount: payloads.count
        )

        let recovered = try FileOutbox(directory: directory)
        let pending = try recovered.pendingItems()

        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(
            try pending.map { try Data(contentsOf: $0.fileURL) },
            payloads
        )
        XCTAssertEqual(pending.map(\.receiverIdentity), ["receiver-a", "receiver-a"])
    }

    func testCursorCheckpointSurvivesRelaunchAndBlocksUploadUntilAcknowledged() throws {
        let directory = temporaryOutboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "receiver-a",
            sourceKey: "apple_health.phone.installation",
            cursorKind: "healthkit_anchored_quantity:energy",
            cursorValue: "anchor-v2",
            coreLaneUploadProof: .steps
        )
        let initial = try FileOutbox(directory: directory)
        _ = try initial.enqueueSequence(
            [Data("one".utf8), Data("two".utf8)],
            receiverIdentity: "receiver-a",
            cursorCheckpoint: checkpoint
        )

        let relaunched = try FileOutbox(directory: directory)
        XCTAssertEqual(try relaunched.pendingCursorCheckpoint(), checkpoint)
        XCTAssertThrowsError(
            try relaunched.uploadablePendingItems(for: "receiver-a")
        ) { error in
            XCTAssertEqual(
                error as? FileOutboxCursorCheckpointError,
                .pendingCommit
            )
        }

        try relaunched.acknowledgeCursorCheckpoint(checkpoint)

        XCTAssertNil(try relaunched.pendingCursorCheckpoint())
        XCTAssertEqual(
            try relaunched.uploadablePendingItems(for: "receiver-a").count,
            2
        )
    }

    func testCursorCheckpointCannotBeAcknowledgedWithoutCommittedPayload() throws {
        let directory = temporaryOutboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "receiver-a",
            sourceKey: "apple_health.phone.installation",
            cursorKind: "healthkit_anchored_quantity:energy",
            cursorValue: "anchor-v3"
        )
        let outbox = try FileOutbox(directory: directory)
        let items = try outbox.enqueueSequence(
            [Data("one".utf8)],
            receiverIdentity: "receiver-a",
            cursorCheckpoint: checkpoint
        )
        try FileManager.default.removeItem(at: try XCTUnwrap(items.first).fileURL)

        XCTAssertThrowsError(try outbox.acknowledgeCursorCheckpoint(checkpoint)) { error in
            XCTAssertEqual(
                error as? FileOutboxCursorCheckpointError,
                .pendingCommit
            )
        }
    }

    func testPartiallyStagedSequenceRollsBackAllItemsAfterCrashWindow() throws {
        let directory = temporaryOutboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloads = [Data("one".utf8), Data("two".utf8)]
        let interrupted = try FileOutbox(directory: directory)
        try interrupted.stageEnqueueSequenceForTesting(
            payloads,
            receiverIdentity: "receiver-a",
            stagedPayloadCount: 1
        )

        let recovered = try FileOutbox(directory: directory)
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        XCTAssertTrue(try recovered.pendingItems().isEmpty)
        XCTAssertFalse(children.contains { $0.pathExtension == "staged" })
        XCTAssertFalse(children.contains { $0.lastPathComponent == ".enqueue-transaction" })
    }

    func testDurablePayloadAccountingStopsAfterPartialOrUninspectableEnqueue() {
        XCTAssertEqual(
            DurablePayloadEnqueueAccounting.durableItemCount(
                initialItemIDs: ["old"],
                finalItemIDs: ["old", "new"],
                successfulEnqueueCount: 1,
                enqueueWasAttempted: true
            ),
            1
        )
        XCTAssertEqual(
            DurablePayloadEnqueueAccounting.durableItemCount(
                initialItemIDs: ["old"],
                finalItemIDs: nil,
                successfulEnqueueCount: 0,
                enqueueWasAttempted: true
            ),
            1
        )
        XCTAssertEqual(
            DurablePayloadEnqueueAccounting.durableItemCount(
                initialItemIDs: ["old"],
                finalItemIDs: nil,
                successfulEnqueueCount: 0,
                enqueueWasAttempted: false
            ),
            0
        )
    }

    func testUnreadableManifestCanBeDurablyClearedAndReopened() throws {
        let directory = temporaryOutboxDirectory()
        let outbox = try FileOutbox(directory: directory)
        _ = try outbox.enqueue(
            Data("private-payload".utf8),
            receiverIdentity: "synthetic-receiver-identity"
        )
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent(".fifo-sequence"),
            options: [.atomic]
        )
        XCTAssertThrowsError(try FileOutbox(directory: directory))

        try FileOutbox.beginDestructiveRecovery(directory: directory)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".clear-intent").path
            )
        )
        let recovery = try FileOutbox.completeDestructiveRecovery(directory: directory)

        XCTAssertEqual(recovery.removedPayloadCount, 1)
        XCTAssertTrue(try recovery.outbox.pendingItems().isEmpty)
        XCTAssertFalse(recovery.outbox.clearIntentIsActive)
        XCTAssertTrue(try FileOutbox(directory: directory).pendingItems().isEmpty)
    }

    func testLegacyMigrationPreservesFileAgeAcrossRebootCounterReset() throws {
        let directory = temporaryOutboxDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preRebootURL = directory.appendingPathComponent(
            "99999999999999999999-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json"
        )
        let postRebootURL = directory.appendingPathComponent(
            "00000000000000000001-11111111-2222-3333-4444-555555555555.json"
        )
        try Data("pre-reboot".utf8).write(to: preRebootURL)
        try Data("post-reboot".utf8).write(to: postRebootURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: preRebootURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: postRebootURL.path
        )

        let outbox = try FileOutbox(directory: directory)

        XCTAssertEqual(
            try outbox.pendingItems().map {
                try String(decoding: Data(contentsOf: $0.fileURL), as: UTF8.self)
            },
            ["pre-reboot", "post-reboot"]
        )
    }

    func testMultipleProcessRestartsPreservePersistentMonotonicOrder() throws {
        let directory = temporaryOutboxDirectory()

        let first = try FileOutbox(directory: directory).enqueue(
            Data("first".utf8), receiverIdentity: "synthetic-receiver-identity"
        )
        let second = try FileOutbox(directory: directory).enqueue(
            Data("second".utf8), receiverIdentity: "synthetic-receiver-identity"
        )
        let restarted = try FileOutbox(directory: directory)
        let third = try restarted.enqueue(
            Data("third".utf8), receiverIdentity: "synthetic-receiver-identity"
        )

        XCTAssertTrue(first.id.hasPrefix("00000000000000000001-"))
        XCTAssertTrue(second.id.hasPrefix("00000000000000000002-"))
        XCTAssertTrue(third.id.hasPrefix("00000000000000000003-"))
        XCTAssertEqual(
            try restarted.pendingItems().map {
                try String(decoding: Data(contentsOf: $0.fileURL), as: UTF8.self)
            },
            ["first", "second", "third"]
        )
    }

    func testLegacyMigrationIsDeterministicAndIdempotent() throws {
        let directory = temporaryOutboxDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyPayloads = [
            ("99999999999999999999-aaaaaaaa.json", "first", 1_000.0),
            ("00000000000000000001-bbbbbbbb.json", "second", 2_000.0),
            ("00000000000000000002-cccccccc.json", "third", 3_000.0),
        ]
        for (filename, contents, timestamp) in legacyPayloads {
            let fileURL = directory.appendingPathComponent(filename)
            try Data(contents.utf8).write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: timestamp)],
                ofItemAtPath: fileURL.path
            )
        }

        let firstLoad = try FileOutbox(directory: directory)
        let firstIDs = try firstLoad.pendingItems().map(\.id)
        let secondIDs = try FileOutbox(directory: directory).pendingItems().map(\.id)

        XCTAssertEqual(firstIDs, secondIDs)
        XCTAssertEqual(
            try firstLoad.pendingItems().map {
                try String(decoding: Data(contentsOf: $0.fileURL), as: UTF8.self)
            },
            ["first", "second", "third"]
        )
    }

    func testSequencePersistenceFailureCannotPublishAmbiguouslyOrderedPayload() throws {
        let directory = temporaryOutboxDirectory()
        let outbox = try FileOutbox(directory: directory)
        let sequenceURL = directory.appendingPathComponent(".fifo-sequence")
        try FileManager.default.removeItem(at: sequenceURL)
        try FileManager.default.createDirectory(at: sequenceURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try outbox.enqueueForTesting(Data("must-not-publish".utf8)))
        XCTAssertTrue(try payloadFileURLs(in: directory).isEmpty)
    }

    func testVersionOneManifestMigratesToReceiverScopedVersionTwo() throws {
        let directory = temporaryOutboxDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let itemID = "00000000000000000001-00000000-0000-0000-0000-000000000001"
        let payloadURL = directory.appendingPathComponent(itemID).appendingPathExtension("json")
        try Data("legacy-private-health-payload".utf8).write(to: payloadURL)
        let sequenceURL = directory.appendingPathComponent(".fifo-sequence")
        let legacyManifest: [String: Any] = [
            "version": 1,
            "nextSequence": 2,
            "entries": [["sequence": 1, "id": itemID]],
        ]
        try JSONSerialization.data(withJSONObject: legacyManifest).write(to: sequenceURL)

        let migrated = try FileOutbox(directory: directory)
        let pending = try migrated.pendingItems()
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sequenceURL))
                as? [String: Any]
        )

        XCTAssertEqual(persisted["version"] as? Int, 3)
        XCTAssertEqual(pending.map(\.id), [itemID])
        XCTAssertNil(pending[0].receiverIdentity)
    }

    func testLegacyUnscopedOutboxItemsRemainQuarantinedAcrossRestart() throws {
        let directory = temporaryOutboxDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let itemID = "00000000000000000001-10000000-0000-0000-0000-000000000001"
        try Data("legacy-private-health-payload".utf8).write(
            to: directory.appendingPathComponent(itemID).appendingPathExtension("json")
        )
        let first = try FileOutbox(directory: directory)
        XCTAssertNil(try XCTUnwrap(first.pendingItem(id: itemID)).receiverIdentity)

        let restarted = try FileOutbox(directory: directory)
        XCTAssertNil(try XCTUnwrap(restarted.pendingItem(id: itemID)).receiverIdentity)
        XCTAssertThrowsError(
            try restarted.uploadablePendingItems(
                for: "00000000-0000-0000-0000-00000000000B"
            )
        ) { error in
            XCTAssertEqual(error as? ReceiverOutboxIdentityError, .unknownReceiverIdentity)
        }
    }

    func testV2CredentialHashesMigrateMatchingItemsAndQuarantineOthers() throws {
        let directory = temporaryOutboxDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let itemA = "00000000000000000001-11111111-1111-1111-1111-111111111111"
        let itemB = "00000000000000000002-22222222-2222-2222-2222-222222222222"
        for itemID in [itemA, itemB] {
            try Data("private-health-payload".utf8).write(
                to: directory.appendingPathComponent(itemID).appendingPathExtension("json")
            )
        }
        let urlA = "https://a.example/v1/batches"
        let tokenA = "synthetic-token-a"
        let hashA = legacyReceiverIdentity(receiverURLString: urlA, bearerToken: tokenA)
        let hashB = legacyReceiverIdentity(
            receiverURLString: "https://b.example/v1/batches",
            bearerToken: "synthetic-token-b"
        )
        let manifest: [String: Any] = [
            "version": 2,
            "nextSequence": 3,
            "entries": [
                ["sequence": 1, "id": itemA, "receiverIdentity": hashA],
                ["sequence": 2, "id": itemB, "receiverIdentity": hashB],
            ],
        ]
        let sequenceURL = directory.appendingPathComponent(".fifo-sequence")
        try JSONSerialization.data(withJSONObject: manifest).write(to: sequenceURL)
        let outbox = try FileOutbox(directory: directory)
        let bindingID = "00000000-0000-0000-0000-00000000000a"

        XCTAssertEqual(
            try outbox.migrateLegacyHashedReceiverIdentities(
                currentReceiverURLString: urlA,
                currentBearerToken: tokenA,
                currentBindingID: bindingID
            ),
            2
        )
        XCTAssertEqual(try outbox.pendingItems().map(\.receiverIdentity), [bindingID, nil])
        XCTAssertEqual(try outbox.uploadablePendingItems(for: bindingID).map(\.id), [itemA])

        let persistedData = try Data(contentsOf: sequenceURL)
        let persistedText = String(decoding: persistedData, as: UTF8.self)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        XCTAssertEqual(persisted["version"] as? Int, 3)
        XCTAssertFalse(persistedText.contains(hashA))
        XCTAssertFalse(persistedText.contains(hashB))
        XCTAssertFalse(persistedText.contains(tokenA))
        XCTAssertEqual(
            try FileOutbox(directory: directory).pendingItems().map(\.receiverIdentity),
            [bindingID, nil]
        )
    }

    func testLegacyHashesRemainUntouchedWithoutTrustedCurrentIdentity() throws {
        let directory = temporaryOutboxDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let itemID = "00000000000000000001-11111111-1111-1111-1111-111111111111"
        try Data("private-health-payload".utf8).write(
            to: directory.appendingPathComponent(itemID).appendingPathExtension("json")
        )
        let legacyHash = legacyReceiverIdentity(
            receiverURLString: "https://a.example/v1/batches",
            bearerToken: "synthetic-token-a"
        )
        let manifest: [String: Any] = [
            "version": 2,
            "nextSequence": 2,
            "entries": [
                ["sequence": 1, "id": itemID, "receiverIdentity": legacyHash],
            ],
        ]
        let sequenceURL = directory.appendingPathComponent(".fifo-sequence")
        try JSONSerialization.data(withJSONObject: manifest).write(to: sequenceURL)
        let outbox = try FileOutbox(directory: directory)

        XCTAssertEqual(
            try outbox.migrateLegacyHashedReceiverIdentities(
                currentReceiverURLString: nil,
                currentBearerToken: nil,
                currentBindingID: nil
            ),
            0
        )
        XCTAssertEqual(try outbox.pendingItems().first?.receiverIdentity, legacyHash)
        XCTAssertTrue(String(decoding: try Data(contentsOf: sequenceURL), as: UTF8.self).contains(legacyHash))
    }

    func testOutboxScopesQueuedPayloadsToReceiverIdentityAcrossRestart() throws {
        let directory = temporaryOutboxDirectory()
        let first = try FileOutbox(directory: directory)
        let receiverA = "00000000-0000-0000-0000-00000000000A"
        let receiverB = "00000000-0000-0000-0000-00000000000B"
        let item = try first.enqueue(Data("private-health-payload".utf8), receiverIdentity: receiverA)

        let restarted = try FileOutbox(directory: directory)

        XCTAssertEqual(try restarted.uploadablePendingItems(for: receiverA).map(\.id), [item.id])
        XCTAssertThrowsError(try restarted.uploadablePendingItems(for: receiverB)) { error in
            XCTAssertEqual(
                error as? ReceiverOutboxIdentityError,
                .oldestItemBelongsToDifferentReceiver
            )
        }
        XCTAssertNotEqual(receiverA, receiverB)
        XCTAssertFalse(receiverA.contains("synthetic-token-a"))
    }

    func testFileOutboxPersistsPendingPayloadsUntilMarkedUploaded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeOutboxTests")
            .appendingPathComponent(UUID().uuidString)
        let outbox = try FileOutbox(directory: directory)
        let payload = Data(#"{"schema_id":"health_bridge.batch.v1"}"#.utf8)

        let item = try outbox.enqueueForTesting(payload)
        let pending = try outbox.pendingItems()

        XCTAssertEqual(pending.map(\.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: pending[0].fileURL), payload)
        XCTAssertTrue(try backupExclusionValue(for: directory))
        XCTAssertTrue(try backupExclusionValue(for: pending[0].fileURL))
        XCTAssertTrue(
            try backupExclusionValue(for: directory.appendingPathComponent(".fifo-sequence"))
        )

        try outbox.markUploaded(item)

        XCTAssertTrue(try outbox.pendingItems().isEmpty)
    }

    func testFlushUploadsPendingPayloadsAndStopsAtFirstFailureToPreserveFIFO() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeOutboxTests")
            .appendingPathComponent(UUID().uuidString)
        let outbox = try FileOutbox(directory: directory)
        let first = try outbox.enqueueForTesting(Data("first".utf8))
        let second = try outbox.enqueueForTesting(Data("second".utf8))
        let third = try outbox.enqueueForTesting(Data("third".utf8))
        var uploaded: [String] = []

        let summary = try await outbox.flushPendingForTesting { item, data in
            uploaded.append(String(data: data, encoding: .utf8) ?? "")
            if item.id == second.id {
                throw ReceiverClientError.unsuccessfulStatusCode(statusCode: 503, responseBody: Data("maintenance".utf8))
            }
        }

        XCTAssertEqual(uploaded, ["first", "second"])
        XCTAssertEqual(summary.attemptedCount, 2)
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.failedItemIDs, [second.id])
        XCTAssertEqual(summary.failedDescriptions, ["Receiver returned HTTP 503."])
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [second.id, third.id])

        _ = try await outbox.flushPendingForTesting { _, _ in }
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path))
    }

    func testClearIntentStopsFlushBeforeNextQueuedUpload() async throws {
        let directory = temporaryOutboxDirectory()
        let receiverIdentity = "00000000-0000-0000-0000-00000000000A"
        let outbox = try FileOutbox(directory: directory)
        let first = try outbox.enqueue(Data("first".utf8), receiverIdentity: receiverIdentity)
        let second = try outbox.enqueue(Data("second".utf8), receiverIdentity: receiverIdentity)
        var uploaded: [String] = []

        do {
            _ = try await outbox.flushPending(receiverIdentity: receiverIdentity) {
                item, _ in
                uploaded.append(item.id)
                try outbox.beginClearIntent()
            }
            XCTFail("Expected the durable clear intent to stop the next upload")
        } catch {
            XCTAssertEqual(error as? FileOutboxClearIntentError, .clearInProgress)
        }

        XCTAssertEqual(uploaded, [first.id])
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [second.id])
        XCTAssertTrue(outbox.clearIntentIsActive)
    }

    func testDurableClearIntentBlocksAdmissionAcrossRestartUntilFinished() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeOutboxClearIntentTests")
            .appendingPathComponent(UUID().uuidString)
        let receiverIdentity = "00000000-0000-0000-0000-00000000000A"
        let first = try FileOutbox(directory: directory)
        let queued = try first.enqueue(
            Data("private-health-payload".utf8),
            receiverIdentity: receiverIdentity
        )

        try first.beginClearIntent()

        XCTAssertTrue(first.clearIntentIsActive)
        XCTAssertThrowsError(
            try first.enqueue(Data("late".utf8), receiverIdentity: receiverIdentity)
        )
        XCTAssertThrowsError(try first.uploadablePendingItems(for: receiverIdentity))

        let restarted = try FileOutbox(directory: directory)
        XCTAssertTrue(restarted.clearIntentIsActive)
        XCTAssertEqual(try restarted.clearPendingWhileIntentIsActive(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queued.fileURL.path))
        XCTAssertTrue(restarted.clearIntentIsActive)

        try restarted.finishClearIntent()

        XCTAssertFalse(restarted.clearIntentIsActive)
        XCTAssertTrue(try restarted.pendingItems().isEmpty)
        XCTAssertNoThrow(
            try restarted.enqueue(Data("new".utf8), receiverIdentity: receiverIdentity)
        )
    }

    func testClearPendingRemovesQueuedPayloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeOutboxTests")
            .appendingPathComponent(UUID().uuidString)
        let outbox = try FileOutbox(directory: directory)
        let first = try outbox.enqueueForTesting(Data("first".utf8))
        let second = try outbox.enqueueForTesting(Data("second".utf8))

        let removedCount = try outbox.clearPending()

        XCTAssertEqual(removedCount, 2)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    func testPendingItemLookupUsesSafeOutboxID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeOutboxTests")
            .appendingPathComponent(UUID().uuidString)
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueueForTesting(Data("payload".utf8))

        XCTAssertEqual(try outbox.pendingItem(id: item.id), item)
        XCTAssertNil(try outbox.pendingItem(id: "missing"))
        XCTAssertNil(try outbox.pendingItem(id: "../\(item.id)"))
        XCTAssertEqual(outbox.directoryURL.lastPathComponent, directory.lastPathComponent)
    }

    func testFileOutboxHardensPreExistingPayloadsOnInit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeOutboxTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyPayloadURL = directory.appendingPathComponent("legacy-payload.json")
        try Data("legacy".utf8).write(to: legacyPayloadURL, options: [.atomic])

        let outbox = try FileOutbox(directory: directory)

        XCTAssertEqual(try outbox.pendingItems().map(\.fileURL).map(\.lastPathComponent), [legacyPayloadURL.lastPathComponent])
        XCTAssertTrue(try backupExclusionValue(for: directory))
        XCTAssertTrue(try backupExclusionValue(for: legacyPayloadURL))
    }

    func testFileSyncCursorStorePersistsCursorValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeCursorTests")
            .appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("cursors.json")
        let store = try FileSyncCursorStore(fileURL: fileURL)

        XCTAssertNil(try store.cursorValue(
            receiverBindingID: "receiver-a",
            sourceKey: "apple_health.phone",
            cursorKind: "foreground_daily_steps_sync"
        ))

        try store.saveCursorValue(
            "2026-06-08T14:10:25Z",
            receiverBindingID: "receiver-a",
            sourceKey: "apple_health.phone",
            cursorKind: "foreground_daily_steps_sync"
        )

        XCTAssertNil(try store.cursorValue(
            receiverBindingID: "receiver-b",
            sourceKey: "apple_health.phone",
            cursorKind: "foreground_daily_steps_sync"
        ))
        XCTAssertTrue(try backupExclusionValue(for: directory))
        XCTAssertTrue(try backupExclusionValue(for: fileURL))

        let reloaded = try FileSyncCursorStore(fileURL: fileURL)
        XCTAssertEqual(
            try reloaded.cursorValue(
                receiverBindingID: "receiver-a",
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_daily_steps_sync"
            ),
            "2026-06-08T14:10:25Z"
        )
        try reloaded.validateReadableAndWritable()
        try reloaded.resetAll()
        XCTAssertNil(try reloaded.cursorValue(
            receiverBindingID: "receiver-a",
            sourceKey: "apple_health.phone",
            cursorKind: "foreground_daily_steps_sync"
        ))
    }

    func testFileSyncCursorStoreRejectsUnreadableStateUntilExplicitReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeCursorTests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("cursors.json")
        try Data("not-json".utf8).write(to: fileURL)

        XCTAssertThrowsError(try FileSyncCursorStore(fileURL: fileURL)) { error in
            XCTAssertEqual(error as? FileSyncCursorStoreError, .invalidData)
        }

        let store = try FileSyncCursorStore.replaceWithEmptyStore(fileURL: fileURL)
        XCTAssertNoThrow(try store.validateReadableAndWritable())
        XCTAssertNil(try store.cursorValue(
            receiverBindingID: "receiver-a",
            sourceKey: "apple_health.phone",
            cursorKind: "foreground_daily_steps_sync"
        ))
    }

    func testFileSyncCursorStoreDropsLegacyUnscopedValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeCursorTests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("cursors.json")
        let legacy = [
            "apple_health.phone#healthkit_steps_anchor": "legacy-anchor",
            "receiver-a#apple_health.phone#foreground_daily_steps_sync": "unversioned",
        ]
        try JSONEncoder().encode(legacy).write(to: fileURL)

        let store = try FileSyncCursorStore(fileURL: fileURL)

        XCTAssertNil(try store.cursorValue(
            receiverBindingID: "receiver-a",
            sourceKey: "apple_health.phone",
            cursorKind: "foreground_daily_steps_sync"
        ))
        try store.saveCursorValue(
            "scoped",
            receiverBindingID: "receiver-a",
            sourceKey: "apple_health.phone",
            cursorKind: "foreground_daily_steps_sync"
        )
        let reloaded = try FileSyncCursorStore(fileURL: fileURL)
        XCTAssertEqual(
            try reloaded.cursorValue(
                receiverBindingID: "receiver-a",
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_daily_steps_sync"
            ),
            "scoped"
        )
    }

    func testFileSyncCursorStoreHardensPreExistingCursorFileOnInit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeCursorTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("cursors.json")
        try Data("{}".utf8).write(to: fileURL, options: [.atomic])

        _ = try FileSyncCursorStore(fileURL: fileURL)

        XCTAssertTrue(try backupExclusionValue(for: directory))
        XCTAssertTrue(try backupExclusionValue(for: fileURL))
    }

    func testReceiverSettingsStorePersistsURLAndTokenThroughSeparateStores() throws {
        let suiteName = "HealthBridgeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = InMemoryReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertEqual(store.receiverURLString, "http://127.0.0.1:8765/v1/batches")
        XCTAssertEqual(try store.loadBearerToken(), "")
        XCTAssertEqual(store.receiverSettingsGeneration, 0)
        XCTAssertEqual(store.receiverSettingsGenerationToken, "g0")

        try store.save(receiverURLString: "https://phone.tailnet.example/v1/batches", bearerToken: "secret-token")

        let reloaded = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        XCTAssertEqual(reloaded.receiverURLString, "https://phone.tailnet.example/v1/batches")
        XCTAssertEqual(try reloaded.loadBearerToken(), "secret-token")
        XCTAssertEqual(reloaded.receiverSettingsGeneration, 1)
        XCTAssertEqual(reloaded.receiverSettingsGenerationToken, "g1")

        try reloaded.save(receiverURLString: "https://phone.tailnet.example/v1/batches", bearerToken: "secret-token")
        XCTAssertEqual(reloaded.receiverSettingsGeneration, 1)
        XCTAssertEqual(reloaded.receiverSettingsGenerationToken, "g1")

        try reloaded.save(receiverURLString: "https://phone.tailnet.example/v1/batches", bearerToken: "changed-token")
        XCTAssertEqual(reloaded.receiverSettingsGeneration, 2)
        XCTAssertEqual(reloaded.receiverSettingsGenerationToken, "g2")
    }

    func testReceiverSettingsStorePreservesPreviousConnectionWhenTokenSaveFails() throws {
        let suiteName = "HealthBridgeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ToggleFailingReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try store.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        tokenStore.shouldFail = true

        XCTAssertThrowsError(
            try store.save(
                receiverURLString: "https://new.example/v1/batches",
                bearerToken: "new-synthetic-token"
            )
        )

        XCTAssertEqual(store.receiverURLString, "https://old.example/v1/batches")
        XCTAssertEqual(try store.loadBearerToken(), "old-synthetic-token")
        XCTAssertEqual(store.receiverSettingsGeneration, 1)
    }

    func testReceiverSettingsStoreClearRemovesURLAndTokenAndAdvancesGeneration() throws {
        let suiteName = "HealthBridgeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = InMemoryReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try store.save(receiverURLString: "https://phone.tailnet.example/v1/batches", bearerToken: "secret-token")
        XCTAssertEqual(store.receiverSettingsGeneration, 1)

        try store.clearReceiverSettings()

        XCTAssertEqual(store.receiverURLString, ReceiverSettingsStore.defaultReceiverURLString)
        XCTAssertEqual(try store.loadBearerToken(), "")
        XCTAssertEqual(store.receiverSettingsGeneration, 2)
        XCTAssertEqual(store.receiverSettingsGenerationToken, "g2")

        try store.clearReceiverSettings()
        XCTAssertEqual(store.receiverSettingsGeneration, 2)
    }

    func testReceiverSettingsStoreRejectsStaleGenerationForPromotionAndClear() throws {
        let suiteName = "HealthBridgeGenerationGuardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: InMemoryReceiverTokenStore()
        )
        try store.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let staleGeneration = store.receiverSettingsGenerationToken
        _ = try store.invalidateReceiverSettingsGeneration()

        XCTAssertThrowsError(
            try store.save(
                receiverURLString: "https://late.example/v1/batches",
                bearerToken: "late-synthetic-token",
                expectedGeneration: staleGeneration
            )
        ) { error in
            XCTAssertEqual(error as? ReceiverSettingsGenerationError, .staleGeneration)
        }
        XCTAssertThrowsError(
            try store.clearReceiverSettings(expectedGeneration: staleGeneration)
        ) { error in
            XCTAssertEqual(error as? ReceiverSettingsGenerationError, .staleGeneration)
        }
        XCTAssertEqual(store.receiverURLString, "https://old.example/v1/batches")
        XCTAssertEqual(try store.loadBearerToken(), "old-synthetic-token")
    }

    func testKeychainTokenDecoderRejectsMissingEmptyAndMalformedData() throws {
        XCTAssertThrowsError(try KeychainReceiverTokenStore.decodeTokenData(nil))
        XCTAssertThrowsError(try KeychainReceiverTokenStore.decodeTokenData(Data()))
        XCTAssertThrowsError(try KeychainReceiverTokenStore.decodeTokenData(Data([0xFF])))
        XCTAssertEqual(
            try KeychainReceiverTokenStore.decodeTokenData(Data("synthetic-token".utf8)),
            "synthetic-token"
        )
    }

    func testReceiverSettingsStoreUsesAtomicRecordWhenUserDefaultsMirrorsAreTorn() throws {
        let suiteName = "HealthBridgeAtomicSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ToggleFailingReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try store.save(
            receiverURLString: "https://atomic.example/v1/batches",
            bearerToken: "atomic-synthetic-token"
        )
        let bindingID = try XCTUnwrap(store.receiverBindingID)

        defaults.set("https://torn.example/v1/batches", forKey: "receiverURLString")
        defaults.set(999, forKey: "receiverSettingsGeneration")
        let reloaded = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertEqual(reloaded.receiverURLString, "https://atomic.example/v1/batches")
        XCTAssertEqual(try reloaded.loadBearerToken(), "atomic-synthetic-token")
        XCTAssertEqual(reloaded.receiverSettingsGeneration, 1)
        XCTAssertEqual(reloaded.receiverBindingID, bindingID)
        try reloaded.save(
            receiverURLString: "https://atomic.example/v1/batches",
            bearerToken: "atomic-synthetic-token"
        )
        XCTAssertEqual(reloaded.receiverBindingID, bindingID)
        let stableGeneration = reloaded.receiverSettingsGenerationToken
        try reloaded.save(
            receiverURLString: "https://atomic.example/v1/batches",
            bearerToken: "atomic-synthetic-token",
            rotateBindingID: true
        )
        let pairingBindingID = try XCTUnwrap(reloaded.receiverBindingID)
        XCTAssertNotEqual(pairingBindingID, bindingID)
        XCTAssertNotEqual(reloaded.receiverSettingsGenerationToken, stableGeneration)
        try reloaded.save(
            receiverURLString: "https://atomic.example/v1/batches",
            bearerToken: "rotated-synthetic-token"
        )
        XCTAssertNotEqual(reloaded.receiverBindingID, pairingBindingID)
        XCTAssertFalse(tokenStore.savedToken.contains("rotated-synthetic-token"))
        XCTAssertFalse(tokenStore.savedToken.contains("atomic.example"))
    }

    func testReceiverSettingsStoreRequiresRepairForUnverifiableLegacyTuple() throws {
        let suiteName = "HealthBridgeLegacySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://legacy.example/v1/batches", forKey: "receiverURLString")
        defaults.set(7, forKey: "receiverSettingsGeneration")
        let tokenStore = ToggleFailingReceiverTokenStore()
        try tokenStore.saveToken("legacy-synthetic-token")
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertNil(store.receiverBindingID)
        XCTAssertThrowsError(try store.ensureAtomicConnectionRecord()) { error in
            XCTAssertEqual(
                error as? ReceiverSettingsRecordError,
                .legacyRecordRequiresRepair
            )
        }
        XCTAssertNil(store.receiverBindingID)

        try store.resetInvalidConnectionRecord()

        XCTAssertNil(try store.ensureAtomicConnectionRecord())
        XCTAssertEqual(store.receiverURLString, ReceiverSettingsStore.defaultReceiverURLString)
        XCTAssertEqual(try store.loadBearerToken(), "")
        XCTAssertNil(store.receiverBindingID)
        XCTAssertNotEqual(store.receiverSettingsGeneration, 7)
    }

    func testReceiverSettingsStoreRefusesToMutateUnverifiableLegacyTuple() throws {
        let suiteName = "HealthBridgeLegacyMutationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://legacy.example/v1/batches", forKey: "receiverURLString")
        defaults.set(7, forKey: "receiverSettingsGeneration")
        let tokenStore = ToggleFailingReceiverTokenStore()
        try tokenStore.saveToken("legacy-synthetic-token")
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertThrowsError(try store.invalidateReceiverSettingsGeneration()) { error in
            XCTAssertEqual(
                error as? ReceiverSettingsRecordError,
                .legacyRecordRequiresRepair
            )
        }
        XCTAssertThrowsError(
            try store.save(
                receiverURLString: "https://replacement.example/v1/batches",
                bearerToken: "replacement-synthetic-token"
            )
        ) { error in
            XCTAssertEqual(
                error as? ReceiverSettingsRecordError,
                .legacyRecordRequiresRepair
            )
        }
        XCTAssertEqual(tokenStore.savedToken, "legacy-synthetic-token")
        XCTAssertEqual(defaults.string(forKey: "receiverURLString"), "https://legacy.example/v1/batches")
        XCTAssertEqual(defaults.integer(forKey: "receiverSettingsGeneration"), 7)
        XCTAssertNil(store.receiverBindingID)
    }

    func testConnectionRecordRecoveryPolicyClassifiesOnlyConfirmedUnreadableStatesAsDestructive() {
        XCTAssertTrue(
            ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(
                ReceiverSettingsRecordError.invalidRecord
            )
        )
        XCTAssertTrue(
            ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(
                ReceiverSettingsRecordError.legacyRecordRequiresRepair
            )
        )
        XCTAssertTrue(
            ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(
                KeychainReceiverTokenStoreError.invalidData
            )
        )
        XCTAssertFalse(
            ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(
                KeychainReceiverTokenStoreError.unavailable
            )
        )
    }

    func testOutboxAdmissionPolicyRequiresExactBindingOrConfirmedEmptyUnpairedState() {
        XCTAssertTrue(
            ReceiverOutboxAdmissionPolicy.isReady(
                pendingReceiverIdentities: ["binding-a", "binding-a"],
                currentBindingID: "binding-a",
                hasBearerToken: true
            )
        )
        XCTAssertTrue(
            ReceiverOutboxAdmissionPolicy.isReady(
                pendingReceiverIdentities: [],
                currentBindingID: nil,
                hasBearerToken: false
            )
        )
        XCTAssertFalse(
            ReceiverOutboxAdmissionPolicy.isReady(
                pendingReceiverIdentities: [nil],
                currentBindingID: "binding-a",
                hasBearerToken: true
            )
        )
        XCTAssertFalse(
            ReceiverOutboxAdmissionPolicy.isReady(
                pendingReceiverIdentities: ["binding-b"],
                currentBindingID: "binding-a",
                hasBearerToken: true
            )
        )
        XCTAssertFalse(
            ReceiverOutboxAdmissionPolicy.isReady(
                pendingReceiverIdentities: [nil],
                currentBindingID: nil,
                hasBearerToken: false
            )
        )
        XCTAssertFalse(
            ReceiverOutboxAdmissionPolicy.isReady(
                pendingReceiverIdentities: [],
                currentBindingID: nil,
                hasBearerToken: true
            )
        )
    }

    func testConnectionTransitionRequiresTrustedEmptyOutbox() {
        XCTAssertTrue(
            ReceiverConnectionTransitionPolicy.canBegin(
                outboxIdentityAdmissionReady: true,
                pendingItemCount: 0,
                clearIntentIsActive: false
            )
        )
        XCTAssertFalse(
            ReceiverConnectionTransitionPolicy.canBegin(
                outboxIdentityAdmissionReady: false,
                pendingItemCount: 0,
                clearIntentIsActive: false
            )
        )
        XCTAssertFalse(
            ReceiverConnectionTransitionPolicy.canBegin(
                outboxIdentityAdmissionReady: true,
                pendingItemCount: 1,
                clearIntentIsActive: false
            )
        )
        XCTAssertFalse(
            ReceiverConnectionTransitionPolicy.canBegin(
                outboxIdentityAdmissionReady: true,
                pendingItemCount: 0,
                clearIntentIsActive: true
            )
        )
    }

    func testPrivateResetResolvesTerminalIntentForCurrentReceiver() throws {
        let suiteName = "HealthBridgeTerminalResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ToggleFailingReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try store.save(
            receiverURLString: "https://receiver.example/v1/batches",
            bearerToken: "hb_current",
            expectedGeneration: store.receiverSettingsGenerationToken
        )
        let cancelledGeneration = store.receiverSettingsGenerationToken
        try store.beginTerminalCancellationIntent(expectedGeneration: cancelledGeneration)

        try store.resolveTerminalCancellationForPrivateReset()

        XCTAssertNil(store.terminalCancellationExpectedGeneration)
        XCTAssertEqual(store.receiverURLString, ReceiverSettingsStore.defaultReceiverURLString)
        XCTAssertEqual(try store.loadBearerToken(), "")
        XCTAssertNotEqual(store.receiverSettingsGenerationToken, cancelledGeneration)
    }

    func testPrivateResetDropsStaleTerminalIntentWithoutClearingNewerReceiver() throws {
        let suiteName = "HealthBridgeStaleTerminalResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ToggleFailingReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try store.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "hb_old",
            expectedGeneration: store.receiverSettingsGenerationToken
        )
        try store.beginTerminalCancellationIntent(
            expectedGeneration: store.receiverSettingsGenerationToken
        )
        try store.save(
            receiverURLString: "https://new.example/v1/batches",
            bearerToken: "hb_new",
            expectedGeneration: store.receiverSettingsGenerationToken
        )
        let replacementGeneration = store.receiverSettingsGenerationToken

        try store.resolveTerminalCancellationForPrivateReset()

        XCTAssertNil(store.terminalCancellationExpectedGeneration)
        XCTAssertEqual(store.receiverURLString, "https://new.example/v1/batches")
        XCTAssertEqual(try store.loadBearerToken(), "hb_new")
        XCTAssertEqual(store.receiverSettingsGenerationToken, replacementGeneration)
    }

    func testReceiverSettingsStoreRejectsTornLegacyTuplesWithoutMigrating() throws {
        do {
            let suiteName = "HealthBridgeTokenOnlyLegacySettingsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let tokenStore = ToggleFailingReceiverTokenStore()
            try tokenStore.saveToken("legacy-synthetic-token")
            let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

            XCTAssertThrowsError(try store.ensureAtomicConnectionRecord()) { error in
                XCTAssertEqual(error as? ReceiverSettingsRecordError, .invalidRecord)
            }
            XCTAssertNil(store.receiverBindingID)
            XCTAssertEqual(tokenStore.savedToken, "legacy-synthetic-token")
        }

        do {
            let suiteName = "HealthBridgeURLOnlyLegacySettingsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set("https://legacy.example/v1/batches", forKey: "receiverURLString")
            let tokenStore = ToggleFailingReceiverTokenStore()
            let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

            XCTAssertThrowsError(try store.ensureAtomicConnectionRecord()) { error in
                XCTAssertEqual(error as? ReceiverSettingsRecordError, .invalidRecord)
            }
            XCTAssertNil(store.receiverBindingID)
            XCTAssertEqual(tokenStore.savedToken, "")
        }
    }

    func testReceiverSettingsStoreDoesNotMutateWhenExistingTokenReadFails() throws {
        let suiteName = "HealthBridgeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ToggleFailingReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try store.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        tokenStore.shouldFailLoad = true

        XCTAssertThrowsError(
            try store.save(
                receiverURLString: "https://new.example/v1/batches",
                bearerToken: "new-synthetic-token"
            )
        )
        XCTAssertThrowsError(try store.clearReceiverSettings())

        tokenStore.shouldFailLoad = false
        XCTAssertEqual(store.receiverURLString, "https://old.example/v1/batches")
        XCTAssertEqual(try store.loadBearerToken(), "old-synthetic-token")
        XCTAssertEqual(store.receiverSettingsGeneration, 1)
    }

    func testReceiverSettingsStoreCanResetConfirmedInvalidAtomicRecord() throws {
        let suiteName = "HealthBridgeMalformedSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(8, forKey: "receiverSettingsGeneration")
        let tokenStore = ToggleFailingReceiverTokenStore()
        try tokenStore.saveToken("health-bridge-connection-v1:not-valid-base64")
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertThrowsError(try store.ensureAtomicConnectionRecord())

        try store.resetInvalidConnectionRecord()

        XCTAssertNil(try store.ensureAtomicConnectionRecord())
        XCTAssertEqual(store.receiverURLString, ReceiverSettingsStore.defaultReceiverURLString)
        XCTAssertEqual(try store.loadBearerToken(), "")
        XCTAssertNil(store.receiverBindingID)
        XCTAssertNotEqual(store.receiverSettingsGeneration, 8)
        XCTAssertGreaterThan(store.receiverSettingsGeneration, 0)
        XCTAssertLessThanOrEqual(store.receiverSettingsGeneration, UInt64(Int.max))
    }

    func testReceiverSettingsStoreCanResetTornLegacyConnectionTuples() throws {
        for (legacyURL, legacyToken): (String?, String) in [
            ("https://url-only.example/v1/batches", ""),
            (nil, "token-only-synthetic-token"),
        ] {
            let suiteName = "HealthBridgeTornLegacySettingsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            if let legacyURL {
                defaults.set(legacyURL, forKey: "receiverURLString")
            }
            let tokenStore = ToggleFailingReceiverTokenStore()
            try tokenStore.saveToken(legacyToken)
            let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

            XCTAssertThrowsError(try store.ensureAtomicConnectionRecord())
            try store.resetInvalidConnectionRecord()

            XCTAssertNil(try store.ensureAtomicConnectionRecord())
            XCTAssertEqual(
                store.receiverURLString,
                ReceiverSettingsStore.defaultReceiverURLString
            )
            XCTAssertEqual(try store.loadBearerToken(), "")
            XCTAssertNil(store.receiverBindingID)
        }
    }

    func testReceiverSettingsStoreCanResetInvalidKeychainData() throws {
        let suiteName = "HealthBridgeInvalidKeychainSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://legacy.example/v1/batches", forKey: "receiverURLString")
        defaults.set(9, forKey: "receiverSettingsGeneration")
        let tokenStore = InvalidDataThenWritableReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertThrowsError(try store.ensureAtomicConnectionRecord()) { error in
            XCTAssertEqual(error as? KeychainReceiverTokenStoreError, .invalidData)
        }

        try store.resetInvalidConnectionRecord()

        XCTAssertNil(try store.ensureAtomicConnectionRecord())
        XCTAssertEqual(store.receiverURLString, ReceiverSettingsStore.defaultReceiverURLString)
        XCTAssertEqual(try store.loadBearerToken(), "")
        XCTAssertNil(store.receiverBindingID)
        XCTAssertNotEqual(store.receiverSettingsGeneration, 9)
    }

    func testReceiverSettingsStoreRefusesDestructiveResetForValidRecord() throws {
        let suiteName = "HealthBridgeValidSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ToggleFailingReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try store.save(
            receiverURLString: "https://valid.example/v1/batches",
            bearerToken: "synthetic-valid-token"
        )

        XCTAssertThrowsError(try store.resetInvalidConnectionRecord()) { error in
            XCTAssertEqual(
                error as? ReceiverSettingsRecordError,
                .destructiveResetNotRequired
            )
        }
        XCTAssertEqual(try store.loadBearerToken(), "synthetic-valid-token")
    }

    func testReceiverSettingsStoreDoesNotResetTransientlyUnreadableRecord() throws {
        let suiteName = "HealthBridgeTransientSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ToggleFailingReceiverTokenStore()
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try store.save(
            receiverURLString: "https://valid.example/v1/batches",
            bearerToken: "synthetic-valid-token"
        )
        let savedRecord = tokenStore.savedToken
        tokenStore.shouldFailLoad = true

        XCTAssertThrowsError(try store.resetInvalidConnectionRecord())

        tokenStore.shouldFailLoad = false
        XCTAssertEqual(tokenStore.savedToken, savedRecord)
        XCTAssertEqual(try store.loadBearerToken(), "synthetic-valid-token")
    }

    func testSleepResetEpochStoreUsesClockFloorAfterDurableCounterLoss() throws {
        let firstStore = SleepResetEpochStore(
            tokenStore: InMemoryReceiverTokenStore(),
            epochFloorProvider: { 1_000 }
        )
        let priorEpoch = try firstStore.reserveEpoch()
        let recoveredStore = SleepResetEpochStore(
            tokenStore: InMemoryReceiverTokenStore(),
            epochFloorProvider: { 2_000 }
        )

        XCTAssertEqual(priorEpoch, 1_000)
        XCTAssertEqual(try recoveredStore.reserveEpoch(), 2_000)
        XCTAssertGreaterThan(try recoveredStore.reserveEpoch(), priorEpoch)
    }

    func testSleepResetEpochStoreReservesMonotonicEpochAboveManifestFloor() throws {
        let tokenStore = InMemoryReceiverTokenStore()
        let store = SleepResetEpochStore(
            tokenStore: tokenStore,
            epochFloorProvider: { 1 }
        )

        XCTAssertEqual(try store.reserveEpoch(), 1)
        XCTAssertEqual(try store.reserveEpoch(), 2)
        XCTAssertEqual(try store.reserveEpoch(after: 40), 41)
        XCTAssertEqual(try store.reserveEpoch(after: 3), 42)
    }
}

private func legacyReceiverIdentity(
    receiverURLString: String,
    bearerToken: String
) -> String {
    let material = Data("\(receiverURLString)\u{0}\(bearerToken)".utf8)
    return SHA256.hash(data: material)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func temporaryOutboxDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("HealthBridgeOutboxTests")
        .appendingPathComponent(UUID().uuidString)
}

private func payloadFileURLs(in directory: URL) throws -> [URL] {
    try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
}

private func backupExclusionValue(for url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    return values.isExcludedFromBackup == true
}

extension FileOutbox {
    func enqueueForTesting(_ payload: Data) throws -> FileOutboxItem {
        try enqueue(payload, receiverIdentity: "synthetic-receiver-identity")
    }

    func flushPendingForTesting(
        upload: (FileOutboxItem, Data) async throws -> Void
    ) async throws -> FileOutboxFlushSummary {
        try await flushPending(
            receiverIdentity: "synthetic-receiver-identity",
            upload: upload
        )
    }
}

private enum SyntheticTokenStoreError: Error {
    case loadFailed
    case saveFailed
}

private final class ToggleFailingReceiverTokenStore: ReceiverTokenStoring {
    var shouldFail = false
    var shouldFailLoad = false
    private(set) var savedToken = ""

    func loadToken() throws -> String {
        if shouldFailLoad {
            throw SyntheticTokenStoreError.loadFailed
        }
        return savedToken
    }

    func saveToken(_ token: String) throws {
        if shouldFail {
            throw SyntheticTokenStoreError.saveFailed
        }
        savedToken = token
    }
}

private final class InvalidDataThenWritableReceiverTokenStore: ReceiverTokenStoring {
    private var containsInvalidData = true
    private var savedToken = ""

    func loadToken() throws -> String {
        if containsInvalidData {
            throw KeychainReceiverTokenStoreError.invalidData
        }
        return savedToken
    }

    func saveToken(_ token: String) throws {
        containsInvalidData = false
        savedToken = token
    }
}

private final class InMemoryReceiverTokenStore: ReceiverTokenStoring {
    private var token = ""

    func loadToken() throws -> String {
        token
    }

    func saveToken(_ token: String) throws {
        self.token = token
    }
}

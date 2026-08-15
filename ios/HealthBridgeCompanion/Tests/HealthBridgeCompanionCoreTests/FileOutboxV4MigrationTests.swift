import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class FileOutboxV4MigrationTests: XCTestCase {
    func testReaderAcceptsMailboxBoundV4WithoutChangingPayloadOrEnvelopeBytes() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let id = "00000000000000000001-synthetic"
        let payload = Data(#"{"schema_id":"health_bridge.batch.v1","synthetic":true}"#.utf8)
        let envelope = Data(#"{"schema_id":"health_bridge.delivery.envelope.v1","synthetic":true}"#.utf8)
        let payloadURL = directory.appendingPathComponent(id).appendingPathExtension("json")
        let envelopeURL = directory.appendingPathComponent(id).appendingPathExtension("hbe")
        try payload.write(to: payloadURL, options: [.atomic])
        try envelope.write(to: envelopeURL, options: [.atomic])
        let manifest: [String: Any] = [
            "entries": [[
                "id": id,
                "mailboxBinding": [
                    "envelopeFilename": envelopeURL.lastPathComponent,
                    "envelopeSHA256": outboxSHA256(envelope),
                    "payloadSHA256": outboxSHA256(payload),
                ],
                "receiverIdentity": "synthetic-binding-v1",
                "sequence": 1,
            ]],
            "nextSequence": 2,
            "version": 4,
        ]
        let manifestBytes = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )
        try manifestBytes.write(
            to: directory.appendingPathComponent(".fifo-sequence"),
            options: [.atomic]
        )

        XCTAssertNoThrow(
            try FileOutbox(directory: directory),
            "the new reader must accept a structurally valid mailbox-bound v4 manifest"
        )
        XCTAssertEqual(try Data(contentsOf: payloadURL), payload)
        XCTAssertEqual(try Data(contentsOf: envelopeURL), envelope)
        XCTAssertEqual(
            try FileOutbox(directory: directory).mailboxBinding(for: id),
            FileOutboxMailboxBindingV1(
                payloadSHA256: outboxSHA256(payload),
                envelopeSHA256: outboxSHA256(envelope),
                envelopeFilename: envelopeURL.lastPathComponent
            )
        )
    }

    func testDirectOnlyEnqueueRetainsV3Manifest() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        _ = try outbox.enqueue(
            Data("synthetic-direct-payload".utf8),
            receiverIdentity: "synthetic-binding-v1"
        )
        let bytes = try Data(
            contentsOf: directory.appendingPathComponent(".fifo-sequence")
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )

        XCTAssertEqual(manifest["version"] as? Int, 3)
        XCTAssertEqual(try outbox.downgradeReadiness(), .ready)
    }

    func testMailboxFinalizationBindsOriginalBytesOnceAndIsIdempotent() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data([0xFF, 0x00, 0x7B, 0x01, 0x7D])
        let envelope = Data([0x00, 0xFE, 0x10, 0x20, 0x30])
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")

        let first = try outbox.finalizeMailboxEnvelope(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: outboxSHA256(payload)
        )
        let second = try outbox.finalizeMailboxEnvelope(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: outboxSHA256(payload)
        )
        let restarted = try FileOutbox(directory: directory)
        let artifacts = try envelopeArtifacts(in: directory)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try restarted.mailboxBinding(for: item.id), first)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(artifacts.first)), envelope)
        XCTAssertEqual(first.payloadSHA256, outboxSHA256(payload))
        XCTAssertEqual(first.envelopeSHA256, outboxSHA256(envelope))
        XCTAssertEqual(try restarted.downgradeReadiness(), .hold(.v4Manifest))
    }

    func testInterruptedFinalizationRecoversToZeroOrOneImmutableBindingAtEveryBoundary()
        throws {
        let payload = Data([0xFF, 0x01, 0x02, 0x03])
        let envelope = Data([0xFE, 0x04, 0x05, 0x06])
        for boundary in FileOutboxEnvelopeFinalizationBoundary.allCases {
            let directory = fileOutboxV4TemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let initial = try FileOutbox(directory: directory)
            let item = try initial.enqueue(payload, receiverIdentity: "synthetic-binding-v1")
            _ = try initial.finalizeMailboxEnvelopeForTesting(
                itemID: item.id,
                envelope: envelope,
                expectedPayloadSHA256: outboxSHA256(payload),
                through: boundary
            )

            let restarted = try FileOutbox(directory: directory)
            let binding = try restarted.mailboxBinding(for: item.id)
            let artifacts = try envelopeArtifacts(in: directory)
            XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
            if boundary == .intentPersisted {
                XCTAssertNil(binding)
                XCTAssertTrue(artifacts.isEmpty)
                XCTAssertEqual(try restarted.downgradeReadiness(), .ready)
            } else {
                XCTAssertNotNil(binding)
                XCTAssertEqual(artifacts.count, 1)
                XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(artifacts.first)), envelope)
                XCTAssertEqual(binding?.payloadSHA256, outboxSHA256(payload))
                XCTAssertEqual(binding?.envelopeSHA256, outboxSHA256(envelope))
                XCTAssertEqual(try restarted.downgradeReadiness(), .hold(.v4Manifest))
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(".mailbox-envelope-intent").path
                )
            )
        }
    }

    func testPreexistingFinalizationIntentCannotBeOverwrittenByAnotherWriter() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("synthetic-concurrent-payload".utf8)
        let firstEnvelope = Data("synthetic-first-envelope".utf8)
        let secondEnvelope = Data("synthetic-second-envelope".utf8)
        let firstWriter = try FileOutbox(directory: directory)
        let item = try firstWriter.enqueue(
            payload,
            receiverIdentity: "synthetic-binding-v1"
        )
        let secondWriter = try FileOutbox(directory: directory)
        _ = try firstWriter.finalizeMailboxEnvelopeForTesting(
            itemID: item.id,
            envelope: firstEnvelope,
            expectedPayloadSHA256: outboxSHA256(payload),
            through: .intentPersisted
        )
        let intentURL = directory.appendingPathComponent(".mailbox-envelope-intent")
        let originalIntent = try Data(contentsOf: intentURL)

        XCTAssertThrowsError(
            try secondWriter.finalizeMailboxEnvelope(
                itemID: item.id,
                envelope: secondEnvelope,
                expectedPayloadSHA256: outboxSHA256(payload)
            )
        ) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .finalizationConflict)
        }
        XCTAssertEqual(try Data(contentsOf: intentURL), originalIntent)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)

        let restarted = try FileOutbox(directory: directory)
        XCTAssertNil(try restarted.mailboxBinding(for: item.id))
        XCTAssertTrue(try envelopeArtifacts(in: directory).isEmpty)
        XCTAssertEqual(try restarted.downgradeReadiness(), .ready)
    }

    func testWrongDigestDifferentEnvelopeAndMultipleArtifactsAreExplicitConflicts() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("synthetic-payload".utf8)
        let envelope = Data("synthetic-envelope".utf8)
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")

        XCTAssertThrowsError(
            try outbox.finalizeMailboxEnvelope(
                itemID: item.id,
                envelope: envelope,
                expectedPayloadSHA256: String(repeating: "0", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .payloadDigestMismatch)
        }
        let binding = try outbox.finalizeMailboxEnvelope(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: outboxSHA256(payload)
        )
        XCTAssertThrowsError(
            try outbox.finalizeMailboxEnvelope(
                itemID: item.id,
                envelope: Data("different-envelope".utf8),
                expectedPayloadSHA256: outboxSHA256(payload)
            )
        ) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .finalizationConflict)
        }
        let extra = directory.appendingPathComponent("extra").appendingPathExtension("hbe")
        try Data("conflict".utf8).write(to: extra)
        XCTAssertThrowsError(try FileOutbox(directory: directory)) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .finalizationConflict)
        }
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(binding.envelopeSHA256, outboxSHA256(envelope))
        XCTAssertEqual(try FileOutbox.downgradeReadiness(directory: directory), .hold(.v4Manifest))
    }

    func testMailboxArtifactsHoldEveryDestructivePathWithoutDeletion() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("synthetic-payload".utf8)
        let envelope = Data("synthetic-envelope".utf8)
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")
        _ = try outbox.finalizeMailboxEnvelope(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: outboxSHA256(payload)
        )
        let envelopeURL = try XCTUnwrap(try envelopeArtifacts(in: directory).first)

        XCTAssertThrowsError(try outbox.markUploaded(item)) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .mailboxArtifactsRequireHold)
        }
        XCTAssertThrowsError(try outbox.clearPending()) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .mailboxArtifactsRequireHold)
        }
        try FileOutbox.beginDestructiveRecovery(directory: directory)
        XCTAssertThrowsError(try FileOutbox.completeDestructiveRecovery(directory: directory)) {
            error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .mailboxArtifactsRequireHold)
        }
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(try Data(contentsOf: envelopeURL), envelope)
    }

    func testClearIntentBlocksMailboxStateMutations() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("synthetic-payload".utf8)
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")
        try FileOutbox.beginDestructiveRecovery(directory: directory)

        XCTAssertThrowsError(
            try outbox.finalizeMailboxEnvelope(
                itemID: item.id,
                envelope: Data("synthetic-envelope".utf8),
                expectedPayloadSHA256: outboxSHA256(payload)
            )
        ) { error in
            XCTAssertEqual(error as? FileOutboxClearIntentError, .clearInProgress)
        }
        XCTAssertThrowsError(
            try outbox.compareAndSetDeliveryState(
                itemID: item.id,
                expected: nil,
                updated: .stable(.collected, ownership: nil)
            )
        ) { error in
            XCTAssertEqual(error as? FileOutboxClearIntentError, .clearInProgress)
        }

        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertTrue(try envelopeArtifacts(in: directory).isEmpty)
        XCTAssertNil(try outbox.deliveryState(for: item.id))
    }

    func testTerminalResetRequestBlocksAdmissionWithoutCommittingDeletion() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("synthetic-payload".utf8)
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")

        try FileOutbox.beginTerminalResetRequest(directory: directory)

        XCTAssertTrue(outbox.terminalResetRequestIsActive)
        XCTAssertFalse(outbox.clearIntentIsActive)
        XCTAssertThrowsError(
            try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")
        ) { error in
            XCTAssertEqual(error as? FileOutboxClearIntentError, .clearInProgress)
        }
        XCTAssertThrowsError(
            try FileOutbox.completeConfirmedTerminalReset(directory: directory)
        ) { error in
            XCTAssertEqual(error as? FileOutboxClearIntentError, .clearIntentRequired)
        }

        let reopened = try FileOutbox(directory: directory)
        XCTAssertTrue(reopened.terminalResetRequestIsActive)
        XCTAssertFalse(reopened.clearIntentIsActive)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(try reopened.pendingItems().count, 1)
    }

    func testConfirmedTerminalResetDeletesMailboxArtifactsOnlyWithDurableIntent() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("synthetic-payload".utf8)
        let envelope = Data("synthetic-envelope".utf8)
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")
        _ = try outbox.finalizeMailboxEnvelope(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: outboxSHA256(payload)
        )

        XCTAssertThrowsError(
            try FileOutbox.completeConfirmedTerminalReset(directory: directory)
        ) { error in
            XCTAssertEqual(error as? FileOutboxClearIntentError, .clearIntentRequired)
        }
        XCTAssertEqual(try outbox.pendingItems().count, 1)
        XCTAssertEqual(try envelopeArtifacts(in: directory).count, 1)

        try FileOutbox.beginDestructiveRecovery(directory: directory)
        let recovery = try FileOutbox.completeConfirmedTerminalReset(directory: directory)

        XCTAssertEqual(recovery.removedPayloadCount, 1)
        XCTAssertEqual(try recovery.outbox.pendingItems().count, 0)
        XCTAssertFalse(recovery.outbox.clearIntentIsActive)
        XCTAssertTrue(try envelopeArtifacts(in: directory).isEmpty)
        XCTAssertEqual(try recovery.outbox.downgradeReadiness(), .ready)
    }

    func testDowngradeReadinessHoldsForIntentEnvelopeAndV4AndOldReaderRejects() throws {
        let intentDirectory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: intentDirectory) }
        let payload = Data("synthetic-payload".utf8)
        let envelope = Data("synthetic-envelope".utf8)
        let outbox = try FileOutbox(directory: intentDirectory)
        let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")
        _ = try outbox.finalizeMailboxEnvelopeForTesting(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: outboxSHA256(payload),
            through: .intentPersisted
        )
        XCTAssertEqual(
            try FileOutbox.downgradeReadiness(directory: intentDirectory),
            .hold(.finalizationIntent)
        )
        XCTAssertThrowsError(
            try FileOutbox.assertReadableByLegacyV3Reader(directory: intentDirectory)
        )

        let envelopeDirectory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: envelopeDirectory) }
        try FileManager.default.createDirectory(
            at: envelopeDirectory,
            withIntermediateDirectories: true
        )
        try envelope.write(
            to: envelopeDirectory.appendingPathComponent("orphan.hbe"),
            options: [.atomic]
        )
        XCTAssertEqual(
            try FileOutbox.downgradeReadiness(directory: envelopeDirectory),
            .hold(.envelopeArtifact)
        )

        _ = try FileOutbox(directory: intentDirectory)
        let recovered = try FileOutbox(directory: intentDirectory)
        _ = try recovered.finalizeMailboxEnvelope(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: outboxSHA256(payload)
        )
        XCTAssertEqual(try recovered.downgradeReadiness(), .hold(.v4Manifest))
        XCTAssertThrowsError(
            try FileOutbox.assertReadableByLegacyV3Reader(directory: intentDirectory)
        ) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .legacyReaderCannotOpen)
        }
    }

    func testV3MissingReceiverIdentityDecodesSafelyWithoutRaisingVersion() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let id = "00000000000000000001-legacy"
        let payload = Data("legacy-direct".utf8)
        try payload.write(
            to: directory.appendingPathComponent(id).appendingPathExtension("json")
        )
        let manifest = Data(
            #"{"entries":[{"id":"00000000000000000001-legacy","sequence":1}],"nextSequence":2,"version":3}"#.utf8
        )
        try manifest.write(to: directory.appendingPathComponent(".fifo-sequence"))

        let outbox = try FileOutbox(directory: directory)

        XCTAssertEqual(try outbox.pendingItems().count, 1)
        XCTAssertNil(try outbox.pendingItems().first?.receiverIdentity)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(outbox.pendingItems().first?.fileURL)), payload)
        XCTAssertEqual(try outbox.downgradeReadiness(), .ready)
        XCTAssertNoThrow(try FileOutbox.assertReadableByLegacyV3Reader(directory: directory))
    }

    func testCursorCheckpointAndPayloadRemainUnchangedAcrossV4Restart() throws {
        let directory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("synthetic-checkpoint-payload".utf8)
        let envelope = Data("synthetic-checkpoint-envelope".utf8)
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "synthetic-binding-v1",
            sourceKey: "synthetic-source",
            cursorKind: "synthetic-cursor-kind",
            cursorValue: "synthetic-cursor-value"
        )
        let outbox = try FileOutbox(directory: directory)
        let item = try XCTUnwrap(
            outbox.enqueueSequence(
                [payload],
                receiverIdentity: "synthetic-binding-v1",
                cursorCheckpoint: checkpoint
            ).first
        )
        _ = try outbox.finalizeMailboxEnvelope(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: outboxSHA256(payload)
        )

        let restarted = try FileOutbox(directory: directory)

        XCTAssertEqual(try restarted.pendingCursorCheckpoint(), checkpoint)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(try restarted.pendingItems().first?.receiverIdentity, "synthetic-binding-v1")
    }

    func testMalformedVersionDigestFilenameAndIntentAreRejectedWithoutDeletion() throws {
        for mutation in ["version", "digest", "filename"] {
            let directory = fileOutboxV4TemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let id = "00000000000000000001-synthetic"
            let payload = Data("synthetic-payload".utf8)
            let envelope = Data("synthetic-envelope".utf8)
            let payloadURL = directory.appendingPathComponent(id).appendingPathExtension("json")
            let envelopeURL = directory.appendingPathComponent(id).appendingPathExtension("hbe")
            try payload.write(to: payloadURL)
            try envelope.write(to: envelopeURL)
            var binding: [String: Any] = [
                "envelopeFilename": envelopeURL.lastPathComponent,
                "envelopeSHA256": outboxSHA256(envelope),
                "payloadSHA256": outboxSHA256(payload),
            ]
            var version = 4
            if mutation == "version" { version = 5 }
            if mutation == "digest" { binding["payloadSHA256"] = "NOT-A-DIGEST" }
            if mutation == "filename" { binding["envelopeFilename"] = "../escape.hbe" }
            let manifest: [String: Any] = [
                "entries": [[
                    "id": id,
                    "mailboxBinding": binding,
                    "receiverIdentity": "synthetic-binding-v1",
                    "sequence": 1,
                ]],
                "nextSequence": 2,
                "version": version,
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent(".fifo-sequence"))

            XCTAssertThrowsError(try FileOutbox(directory: directory))
            XCTAssertEqual(try Data(contentsOf: payloadURL), payload)
            XCTAssertEqual(try Data(contentsOf: envelopeURL), envelope)
        }

        let intentDirectory = fileOutboxV4TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: intentDirectory) }
        let outbox = try FileOutbox(directory: intentDirectory)
        let item = try outbox.enqueue(
            Data("synthetic-payload".utf8),
            receiverIdentity: "synthetic-binding-v1"
        )
        let malformedIntent = Data(
            #"{"envelopeFilename":"wrong.hbe","envelopeSHA256":"invalid","itemID":"WRONG","payloadSHA256":"invalid","stagedFilename":"wrong.staged","version":1}"#.utf8
        )
        try malformedIntent.write(
            to: intentDirectory.appendingPathComponent(".mailbox-envelope-intent")
        )
        XCTAssertThrowsError(try FileOutbox(directory: intentDirectory)) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .invalidFinalizationIntent)
        }
        XCTAssertEqual(
            try Data(contentsOf: item.fileURL),
            Data("synthetic-payload".utf8)
        )
    }
}

private func fileOutboxV4TemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("FileOutboxV4MigrationTests")
        .appendingPathComponent(UUID().uuidString)
}

private func envelopeArtifacts(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "hbe" }
}

private func outboxSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

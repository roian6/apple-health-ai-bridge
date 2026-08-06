import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class Todo9MigrationQADriverTests: XCTestCase {
    func testSyntheticLegacyProjectionRestartDriver() throws {
        let suiteName = "Todo9MigrationQADriverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyObject: [String: Any] = [
            "bearerToken": "synthetic-legacy-token",
            "bindingID": "synthetic-legacy-binding",
            "generation": 27,
            "receiverURLString": "https://synthetic.example/v1/batches",
            "version": 1,
        ]
        let legacyJSON = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]
        )
        let legacyRaw = "health-bridge-connection-v1:" + legacyJSON.base64EncodedString()
        let tokenStore = Todo9QATokenStore(initialToken: legacyRaw)
        let backupStore = Todo9QATokenStore()
        let initialStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )
        XCTAssertEqual(try initialStore.ensureAtomicConnectionRecord(), "synthetic-legacy-binding")
        let restartedStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )
        let record = try XCTUnwrap(restartedStore.currentConnectionRecordV2())

        let directory = todo9QATemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data([0xFF, 0x00, 0x7B, 0x01, 0x7D])
        let envelope = Data([0xFE, 0x10, 0x20, 0x30, 0x40])
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "synthetic-legacy-binding",
            sourceKey: "synthetic-source",
            cursorKind: "synthetic-cursor-kind",
            cursorValue: "synthetic-cursor-value"
        )
        let outbox = try FileOutbox(directory: directory)
        let item = try XCTUnwrap(
            outbox.enqueueSequence(
                [payload],
                receiverIdentity: "synthetic-legacy-binding",
                cursorCheckpoint: checkpoint
            ).first
        )
        let binding = try outbox.finalizeMailboxEnvelope(
            itemID: item.id,
            envelope: envelope,
            expectedPayloadSHA256: todo9QASHA256(payload)
        )
        let restartedOutbox = try FileOutbox(directory: directory)
        let envelopeURL = directory.appendingPathComponent(binding.envelopeFilename)

        let restartedBearerToken = try restartedStore.loadBearerToken()
        let connectionFieldsEqual = record.localScope
            == ReceiverLocalConnectionScopeV1(
                generation: 27,
                bindingID: "synthetic-legacy-binding"
            )
            && record.mailboxIdentity == .unavailable(.notProvisionedByLegacyHTTPPairing)
            && record.activation == .paired(activeTransport: .directHTTP)
            && restartedStore.receiverURLString == "https://synthetic.example/v1/batches"
            && restartedBearerToken == "synthetic-legacy-token"
        let primaryBytesPreserved = tokenStore.savedToken == legacyRaw
        let backupAbsentBeforeCutover = backupStore.savedToken.isEmpty
        let cursorEqual = try restartedOutbox.pendingCursorCheckpoint() == checkpoint
        let payloadHash = todo9QASHA256(try Data(contentsOf: item.fileURL))
        let envelopeHash = todo9QASHA256(try Data(contentsOf: envelopeURL))
        let downgradeHolds = try restartedOutbox.downgradeReadiness() == .hold(.v4Manifest)

        XCTAssertTrue(connectionFieldsEqual)
        XCTAssertTrue(primaryBytesPreserved)
        XCTAssertTrue(backupAbsentBeforeCutover)
        XCTAssertTrue(cursorEqual)
        XCTAssertEqual(payloadHash, todo9QASHA256(payload))
        XCTAssertEqual(envelopeHash, todo9QASHA256(envelope))
        XCTAssertTrue(downgradeHolds)
        print(
            "TASK9_PROJECTION_QA connection_fields_equal=\(connectionFieldsEqual) "
                + "primary_bytes_preserved=\(primaryBytesPreserved) "
                + "backup_absent_before_cutover=\(backupAbsentBeforeCutover) "
                + "cursor_equal=\(cursorEqual) "
                + "payload_sha256=\(payloadHash) envelope_sha256=\(envelopeHash) "
                + "downgrade_hold=\(downgradeHolds)"
        )
    }

    func testInterruptedFailureAndOldReaderDriver() throws {
        let payload = Data([0xFF, 0x01, 0x02])
        let envelope = Data([0xFE, 0x03, 0x04])
        var zeroBindings = 0
        var oneBindings = 0
        for boundary in FileOutboxEnvelopeFinalizationBoundary.allCases {
            let directory = todo9QATemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let outbox = try FileOutbox(directory: directory)
            let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding")
            _ = try outbox.finalizeMailboxEnvelopeForTesting(
                itemID: item.id,
                envelope: envelope,
                expectedPayloadSHA256: todo9QASHA256(payload),
                through: boundary
            )
            let restarted = try FileOutbox(directory: directory)
            let binding = try restarted.mailboxBinding(for: item.id)
            let envelopeCount = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "hbe" }.count
            XCTAssertTrue((binding == nil && envelopeCount == 0) || (binding != nil && envelopeCount == 1))
            XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
            if binding == nil { zeroBindings += 1 } else { oneBindings += 1 }
        }

        let conflictDirectory = todo9QATemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: conflictDirectory) }
        let conflictOutbox = try FileOutbox(directory: conflictDirectory)
        let conflictItem = try conflictOutbox.enqueue(
            payload,
            receiverIdentity: "synthetic-binding"
        )
        _ = try conflictOutbox.finalizeMailboxEnvelope(
            itemID: conflictItem.id,
            envelope: envelope,
            expectedPayloadSHA256: todo9QASHA256(payload)
        )
        var conflictHeld = false
        XCTAssertThrowsError(
            try conflictOutbox.finalizeMailboxEnvelope(
                itemID: conflictItem.id,
                envelope: Data("different".utf8),
                expectedPayloadSHA256: todo9QASHA256(payload)
            )
        ) { error in
            conflictHeld = error as? FileOutboxMailboxError == .finalizationConflict
        }
        var oldReaderRejected = false
        XCTAssertThrowsError(
            try FileOutbox.assertReadableByLegacyV3Reader(directory: conflictDirectory)
        ) { error in
            oldReaderRejected = error as? FileOutboxMailboxError == .legacyReaderCannotOpen
        }
        var destructiveHeld = false
        XCTAssertThrowsError(try conflictOutbox.clearPending()) { error in
            destructiveHeld = error as? FileOutboxMailboxError == .mailboxArtifactsRequireHold
        }

        XCTAssertEqual(zeroBindings, 1)
        XCTAssertEqual(oneBindings, 3)
        XCTAssertTrue(conflictHeld)
        XCTAssertTrue(oldReaderRejected)
        XCTAssertTrue(destructiveHeld)
        print(
            "TASK9_FAILURE_QA boundaries=4 zero_bindings=\(zeroBindings) "
                + "one_bindings=\(oneBindings) conflict_hold=\(conflictHeld) "
                + "old_reader_reject=\(oldReaderRejected) destructive_hold=\(destructiveHeld)"
        )
    }
}

private final class Todo9QATokenStore: ReceiverTokenStoring {
    private(set) var savedToken: String

    init(initialToken: String = "") {
        savedToken = initialToken
    }

    func loadToken() throws -> String {
        savedToken
    }

    func saveToken(_ token: String) throws {
        savedToken = token
    }
}

private func todo9QATemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("Todo9MigrationQADriverTests")
        .appendingPathComponent(UUID().uuidString)
}

private func todo9QASHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

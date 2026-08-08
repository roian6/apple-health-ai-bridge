import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class Todo9LegacyStatePinTests: XCTestCase {
    func testPinsExactAtomicV1ConnectionRecordBytes() throws {
        let suiteName = "Todo9LegacyStatePinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let jsonBytes = try JSONSerialization.data(
            withJSONObject: [
                "bearerToken": "synthetic-v1-token",
                "bindingID": "synthetic-v1-binding",
                "generation": 1,
                "receiverURLString": "https://synthetic.example/v1/batches",
                "version": 1,
            ],
            options: [.sortedKeys]
        )
        let legacyRaw = "health-bridge-connection-v1:" + jsonBytes.base64EncodedString()
        let tokenStore = Todo9CapturingTokenStore(initialToken: legacyRaw)
        let backupStore = Todo9CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        let rawRecord = Data(legacyRaw.utf8)
        let prefix = "health-bridge-connection-v1:"
        XCTAssertTrue(legacyRaw.hasPrefix(prefix))
        let encoded = String(legacyRaw.dropFirst(prefix.count))
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: encoded)), jsonBytes)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: jsonBytes) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "bearerToken", "bindingID", "generation", "receiverURLString", "version",
        ])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["generation"] as? Int, 1)
        XCTAssertEqual(
            object["receiverURLString"] as? String,
            "https://synthetic.example/v1/batches"
        )
        XCTAssertEqual(object["bearerToken"] as? String, "synthetic-v1-token")
        XCTAssertEqual(object["bindingID"] as? String, "synthetic-v1-binding")
        XCTAssertEqual(try store.ensureAtomicConnectionRecord(), "synthetic-v1-binding")
        XCTAssertEqual(store.receiverSettingsGenerationToken, "g1")
        XCTAssertEqual(store.receiverBindingID, "synthetic-v1-binding")
        XCTAssertEqual(tokenStore.savedToken, legacyRaw)
        XCTAssertTrue(backupStore.savedToken.isEmpty)

        print(
            "TASK9_PIN_V1 record_sha256=\(sha256(rawRecord)) "
                + "json_sha256=\(sha256(jsonBytes)) byte_count=\(rawRecord.count)"
        )
    }

    func testPinsExactDirectOnlyV3ManifestAndPayloadBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Todo9LegacyStatePinTests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(#"{"schema_id":"health_bridge.batch.v1","synthetic":true}"#.utf8)
        let outbox = try FileOutbox(directory: directory)

        let item = try outbox.enqueue(payload, receiverIdentity: "synthetic-binding-v1")
        let persistedPayload = try Data(contentsOf: item.fileURL)
        let manifestBytes = try Data(
            contentsOf: directory.appendingPathComponent(".fifo-sequence")
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any]
        )

        XCTAssertEqual(manifest["version"] as? Int, 3)
        XCTAssertEqual(persistedPayload, payload)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [item.id])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).contains { $0.pathExtension != "json" && !$0.lastPathComponent.hasPrefix(".") }
        )
        print(
            "TASK9_PIN_V3 payload_sha256=\(sha256(persistedPayload)) "
                + "manifest_sha256=\(sha256(manifestBytes)) "
                + "payload_byte_count=\(persistedPayload.count)"
        )
    }
}

private final class Todo9CapturingTokenStore: ReceiverTokenStoring {
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

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HealthBridgeCompanionCore

final class Todo7SwiftCharacterizationTests: XCTestCase {
    override func tearDown() {
        Todo7URLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSyntheticBatchBytesStayIdenticalAcrossEncoderOutboxForegroundAndBackgroundPlan() async throws {
        let expectedBody = Data(Self.expectedBatchJSON.utf8)
        let encodedBody = try HealthBridgeBatchEncoder().encode(Self.syntheticBatch)
        XCTAssertEqual(encodedBody, expectedBody)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-7-swift-characterization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(encodedBody, receiverIdentity: "binding-current")
        let persistedBody = try Data(contentsOf: item.fileURL)
        XCTAssertEqual(persistedBody, expectedBody)

        let receiverURL = try XCTUnwrap(
            URL(string: "https://receiver.example.test/v1/batches")
        )
        let plans = try BackgroundOutboxUploadPlanner.plan(
            pendingItems: try outbox.pendingItems(),
            receiverURL: receiverURL,
            bearerToken: "synthetic-current-token",
            receiverGeneration: "g2",
            receiverBindingID: "binding-current",
            alreadyScheduledItemIDs: []
        )
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plan.itemID, item.id)
        XCTAssertEqual(try Data(contentsOf: plan.fileURL), expectedBody)
        XCTAssertNil(plan.request.httpBody)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Todo7URLProtocol.self]
        let client = ReceiverClient(session: URLSession(configuration: configuration))
        Todo7URLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.httpBodyStream?.todo7ReadAllData(), expectedBody)
            return Todo7URLProtocolResponse(
                response: HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body: Data("{}".utf8)
            )
        }

        let result = try await client.upload(
            encodedBody,
            to: receiverURL,
            bearerToken: "synthetic-current-token"
        )
        XCTAssertEqual(result.statusCode, 202)
        XCTAssertEqual(encodedBody, persistedBody)
        print("TODO7_BYTE_SHA256=\(Self.sha256Hex(encodedBody)) byte_count=\(encodedBody.count)")
    }

    func testPairingDecodeAndCredentialReplacementRotateLocalGenerationAndBinding() throws {
        let legacyMaterial = try ReceiverPairingMaterial.decode(Self.legacyPairingJSON)
        guard case .legacy(let legacy) = legacyMaterial else {
            return XCTFail("Expected legacy v1 pairing material")
        }

        let suiteName = "Todo7SwiftCharacterization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = Todo7MemoryReceiverTokenStore()
        let settings = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try settings.save(
            receiverURLString: legacy.receiverURLString,
            bearerToken: legacy.bearerToken
        )
        let legacyGeneration = settings.receiverSettingsGenerationToken
        let legacyBinding = try XCTUnwrap(settings.receiverBindingID)

        let invitationMaterial = try ReceiverPairingMaterial.decode(Self.invitationPairingJSON)
        guard case .invitation(let invitation) = invitationMaterial else {
            return XCTFail("Expected invitation v2 pairing material")
        }
        XCTAssertEqual(invitation.invitationSecret, "hbi_synthetic_replacement")
        try settings.save(
            receiverURLString: invitation.receiverURLString,
            bearerToken: "synthetic-redeemed-device-credential"
        )
        let currentGeneration = settings.receiverSettingsGenerationToken
        let currentBinding = try XCTUnwrap(settings.receiverBindingID)

        XCTAssertEqual(legacyGeneration, "g1")
        XCTAssertEqual(currentGeneration, "g2")
        XCTAssertNotEqual(currentBinding, legacyBinding)
        XCTAssertEqual(try settings.loadBearerToken(), "synthetic-redeemed-device-credential")

        try settings.save(
            receiverURLString: invitation.receiverURLString,
            bearerToken: "synthetic-redeemed-device-credential"
        )
        XCTAssertEqual(settings.receiverSettingsGenerationToken, currentGeneration)
        XCTAssertEqual(settings.receiverBindingID, currentBinding)
        print(
            "TODO7_REPLACEMENT legacy_generation=\(legacyGeneration) "
                + "current_generation=\(currentGeneration) binding_rotated=\(legacyBinding != currentBinding)"
        )
    }

    func testDirectCompletionRequiresCurrentLocalGenerationAndBinding() {
        XCTAssertTrue(
            BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(
                error: nil,
                httpStatusCode: 202,
                taskReceiverGeneration: "g2",
                currentReceiverGeneration: "g2",
                taskReceiverBindingID: "binding-current",
                currentReceiverBindingID: "binding-current"
            )
        )
        XCTAssertFalse(
            BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(
                error: nil,
                httpStatusCode: 202,
                taskReceiverGeneration: "g1",
                currentReceiverGeneration: "g2",
                taskReceiverBindingID: "binding-current",
                currentReceiverBindingID: "binding-current"
            )
        )
        XCTAssertFalse(
            BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(
                error: nil,
                httpStatusCode: 202,
                taskReceiverGeneration: "g2",
                currentReceiverGeneration: "g2",
                taskReceiverBindingID: "binding-stale",
                currentReceiverBindingID: "binding-current"
            )
        )
        print("TODO7_COMPLETION current=true stale_generation=false stale_binding=false")
    }

    private static let expectedBatchJSON = #"{"deleted_records":[],"export_window":{"end_time":"2026-07-20T00:00:00Z","start_time":"2026-07-19T00:00:00Z"},"generated_at":"2026-07-20T00:00:01Z","health_types":[{"aliases":["HKQuantityTypeIdentifierStepCount"],"category":"activity","default_unit":"count","display_name":"Steps","sensitivity":"low","type_code":"steps"}],"samples":[{"client_record_id":"synthetic-step-sample","end_time":"2026-07-20T00:00:00Z","metadata":{"aggregation":"synthetic_daily_sum"},"source_key":"apple_health.synthetic","start_time":"2026-07-19T00:00:00Z","type_code":"steps","unit":"count","value":42}],"schema_id":"health_bridge.batch.v1","schema_version":"1.0.0","sleep_sessions":[],"sources":[{"bundle_id":"com.example.synthetic","device_model":"Synthetic iPhone","kind":"phone","name":"Synthetic Apple Health","source_key":"apple_health.synthetic"}],"sync":{"cursors":[{"cursor_kind":"anchored_object_query","cursor_value":"synthetic-cursor-7","source_key":"apple_health.synthetic"}],"sync_window":{"end_time":"2026-07-20T00:00:00Z","start_time":"2026-07-19T00:00:00Z"}},"workouts":[]}"#

    private static let syntheticBatch = HealthBridgeBatchV1(
        generatedAt: "2026-07-20T00:00:01Z",
        exportWindow: HealthBridgeTimeWindow(
            startTime: "2026-07-19T00:00:00Z",
            endTime: "2026-07-20T00:00:00Z"
        ),
        sources: [
            HealthBridgeSource(
                sourceKey: "apple_health.synthetic",
                name: "Synthetic Apple Health",
                kind: .phone,
                bundleID: "com.example.synthetic",
                deviceModel: "Synthetic iPhone"
            )
        ],
        healthTypes: [.steps],
        samples: [
            HealthBridgeSample(
                clientRecordID: "synthetic-step-sample",
                sourceKey: "apple_health.synthetic",
                typeCode: "steps",
                startTime: "2026-07-19T00:00:00Z",
                endTime: "2026-07-20T00:00:00Z",
                value: 42,
                unit: "count",
                metadata: ["aggregation": "synthetic_daily_sum"]
            )
        ],
        workouts: [],
        sleepSessions: [],
        deletedRecords: [],
        sync: HealthBridgeSyncContext(
            syncWindow: HealthBridgeTimeWindow(
                startTime: "2026-07-19T00:00:00Z",
                endTime: "2026-07-20T00:00:00Z"
            ),
            cursors: [
                HealthBridgeSyncCursor(
                    sourceKey: "apple_health.synthetic",
                    cursorKind: "anchored_object_query",
                    cursorValue: "synthetic-cursor-7"
                )
            ]
        )
    )

    private static let legacyPairingJSON = #"{"schema_id":"health_bridge.receiver_pairing.v1","schema_version":"1.0.0","label":"synthetic-v1","receiver_url":"https://receiver-v1.example.test/v1/batches","bearer_token":"synthetic-legacy-token","token_prefix":"synthetic_","created_at":"2026-07-20T00:00:00Z","warning":"Synthetic fixture only."}"#

    private static let invitationPairingJSON = #"{"schema_id":"health_bridge.receiver_pairing_invitation.v2","schema_version":"2.0.0","label":"synthetic-v2","receiver_url":"https://receiver-v2.example.test/v1/batches","redeem_url":"https://receiver-v2.example.test/v1/pairing/redeem","invitation_secret":"hbi_synthetic_replacement","expires_at":"2026-07-21T00:00:00Z"}"#

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct Todo7URLProtocolResponse {
    let response: HTTPURLResponse
    let body: Data
}

private final class Todo7URLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> Todo7URLProtocolResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handled = try XCTUnwrap(Self.requestHandler)(request)
            client?.urlProtocol(self, didReceive: handled.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: handled.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class Todo7MemoryReceiverTokenStore: ReceiverTokenStoring {
    private var token = ""

    func loadToken() throws -> String { token }
    func saveToken(_ token: String) throws { self.token = token }
}

private extension InputStream {
    func todo7ReadAllData() -> Data {
        open()
        defer { close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

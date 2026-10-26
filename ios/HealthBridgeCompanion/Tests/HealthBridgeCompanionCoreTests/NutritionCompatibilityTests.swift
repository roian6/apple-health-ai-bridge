import CryptoKit
import Foundation
import XCTest
#if canImport(HealthBridgeCompanion)
@testable import HealthBridgeCompanion
#else
@testable import HealthBridgeCompanionCore
#endif

final class NutritionCompatibilityTests: XCTestCase {
    func testMailboxCapabilitiesGoldenPrimitivesAndUnknownFieldTamper() throws {
        struct Golden: Decodable { let document_utf8: String; let public_key_hex: String }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf:
            root.appendingPathComponent("tests/fixtures/mailbox_receiver_capabilities_v1.synthetic.json")))
        let document = Data(golden.document_utf8.utf8)
        XCTAssertLessThanOrEqual(document.count, 8_192)
        guard case .object(var fields) = try DeliveryProtocolV1.decodeMetadata(document),
              case .string(let signatureText)? = fields.removeValue(forKey: "signature"),
              case .object(var capabilities)? = fields["capabilities"] else {
            return XCTFail("Invalid synthetic golden")
        }
        var keyBytes = Data()
        var index = golden.public_key_hex.startIndex
        while index < golden.public_key_hex.endIndex {
            let end = golden.public_key_hex.index(index, offsetBy: 2)
            keyBytes.append(try XCTUnwrap(UInt8(golden.public_key_hex[index..<end], radix: 16)))
            index = end
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        let base64 = signatureText.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let signature = try XCTUnwrap(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
        let domain = Data("health-bridge/mailbox/v1/receiver-capabilities/signature\0".utf8)
        XCTAssertTrue(key.isValidSignature(signature, for: domain + (try DeliveryProtocolV1.encodeMetadata(.object(fields)))))
        XCTAssertEqual(NutritionSupport.decode(try DeliveryProtocolV1.encodeMetadata(.object(capabilities))), .supported)
        capabilities["future_synthetic"] = .object(["enabled": .bool(false)])
        fields["capabilities"] = .object(capabilities)
        XCTAssertFalse(key.isValidSignature(signature, for: domain + (try DeliveryProtocolV1.encodeMetadata(.object(fields)))))
    }

    @MainActor
    func testNutritionPayloadCodecDoesNotOccupyMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root)
        _ = try outbox.enqueue(
            JSONEncoder().encode(makeBatch(types: [.weight, nutrition], samples: [])),
            receiverIdentity: "synthetic"
        )
        let observation = NutritionCodecProbe()
        outbox.observeNutritionCodec = { observation.record() }

        try await outbox.prepareNutritionCompatibility()
        let eligible = try outbox.nutritionCompatibleItems(for: "synthetic", support: .unknown)

        XCTAssertFalse(eligible.isEmpty)
        XCTAssertFalse(observation.values.isEmpty)
        XCTAssertTrue(observation.values.allSatisfy { !$0 })
    }

    @MainActor
    func testCancelledNutritionPreparationCannotPublishPlan() async throws {
        try await assertNutritionPreparationRejects(.cancel)
    }

    @MainActor
    func testPreparedSelectionCannotCreateProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root)
        let original = try outbox.enqueue(
            JSONEncoder().encode(makeBatch(types: [.weight, nutrition], samples: [])),
            receiverIdentity: "synthetic"
        )
        try await outbox.prepareNutritionCompatibility()
        let before = try Data(contentsOf: root.appendingPathComponent(".fifo-sequence"))

        let selected = try outbox.preparedNutritionItems(for: "synthetic", support: .unknown)

        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(try outbox.pendingItems(), [original])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".fifo-sequence")), before)
    }

    @MainActor
    func testChangedNutritionPayloadCannotPublishPlan() async throws {
        try await assertNutritionPreparationRejects(.payload)
    }

    @MainActor
    func testResetDuringNutritionPreparationCannotPublishPlan() async throws {
        try await assertNutritionPreparationRejects(.reset)
    }

    @MainActor
    func testChangedNutritionOwnerCannotPublishPlan() async throws {
        try await assertNutritionPreparationRejects(.owner)
    }

    @MainActor
    private func assertNutritionPreparationRejects(_ change: NutritionPreparationChange) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root)
        let bytes = try JSONEncoder().encode(makeBatch(types: [.weight, nutrition], samples: []))
        let original = try outbox.enqueue(bytes, receiverIdentity: "synthetic")
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        outbox.observeNutritionCodec = { probe.record() }
        var currentOwner = true
        let preparation = Task { @MainActor in
            try await outbox.prepareNutritionCompatibility {
                guard currentOwner else { throw CancellationError() }
            }
        }
        await fulfillment(of: [probe.entered], timeout: 5)

        switch change {
        case .cancel: preparation.cancel()
        case .payload: try (bytes + Data(" ".utf8)).write(to: original.fileURL, options: .atomic)
        case .reset: try outbox.beginClearIntent()
        case .owner: currentOwner = false
        }
        probe.release()
        let result = await preparation.result

        guard case .failure(let error) = result else { return XCTFail("Stale preparation succeeded") }
        switch change {
        case .reset: XCTAssertEqual(error as? FileOutboxClearIntentError, .clearInProgress)
        case .cancel, .payload, .owner: XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertTrue(outbox.preparedNutritionPayloads.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map(\.lastPathComponent),
            [original.fileURL.lastPathComponent]
        )
    }

    func testCapabilityRequiresBothSchemasAndJSONBoolean() {
        // Given malformed or unrelated discovery responses.
        let bodies = [
            #"{"nutrition_supported":true}"#,
            #"{"schema_id":"future","batch_schema_id":"health_bridge.batch.v1","nutrition_supported":true}"#,
            #"{"schema_id":"health_bridge.receiver_capabilities.v1","batch_schema_id":"future","nutrition_supported":true}"#,
            #"{"schema_id":"health_bridge.receiver_capabilities.v1","batch_schema_id":"health_bridge.batch.v1","nutrition_supported":1}"#,
            #"{"schema_id":"health_bridge.receiver_capabilities.v1","batch_schema_id":"health_bridge.batch.v1","nutrition_supported":"true"}"#
        ]
        // When decoded, none becomes support evidence.
        let results = bodies.map { NutritionSupport.decode(Data($0.utf8)) }
        // Then fail closed for every invalid response.
        XCTAssertEqual(results, Array(repeating: .unknown, count: bodies.count))
        XCTAssertEqual(NutritionSupport.decode(Data("""
        {"schema_id":"health_bridge.receiver_capabilities.v1",
         "batch_schema_id":"health_bridge.batch.v1","nutrition_supported":false}
        """.utf8)), .unsupported)
    }

    func testCatalogOnlyNutritionIsWithheldWithoutDroppingSupportedCatalog() throws {
        let batch = makeBatch(types: [.weight, nutrition], samples: [])

        let projection = try XCTUnwrap(NutritionCompatibility.supportedProjection(batch))

        XCTAssertFalse(NutritionCompatibility.permits(batch, support: .unknown))
        XCTAssertFalse(NutritionCompatibility.permits(batch, support: .unsupported))
        XCTAssertTrue(NutritionCompatibility.permits(batch, support: .supported))
        XCTAssertEqual(projection.healthTypes.map(\.typeCode), ["weight"])
        XCTAssertTrue(projection.samples.isEmpty)
        XCTAssertTrue(projection.sync.cursors.isEmpty)
    }

    func testFutureNutritionDoesNotInheritFiveTypeCapability() {
        let future = HealthBridgeHealthType(
            typeCode: "dietary_future", displayName: "Synthetic", category: .nutrition,
            defaultUnit: "g", sensitivity: .moderate, aliases: []
        )

        let allowed = NutritionCompatibility.permits(makeBatch(types: [future], samples: []), support: .supported)

        XCTAssertFalse(allowed)
    }

    @MainActor
    func testHeldOriginalSurvivesProjectionACKAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root)
        let payload = try JSONEncoder().encode(makeBatch(types: [.weight, nutrition], samples: []))
        let original = try outbox.enqueue(payload, receiverIdentity: "synthetic")
        try await outbox.prepareNutritionCompatibility()
        let eligible = try outbox.nutritionCompatibleItems(for: "synthetic", support: .unknown)
        let projection = try XCTUnwrap(eligible.first)
        XCTAssertNotEqual(projection.id, original.id)

        try outbox.markUploaded(projection)
        let reopened = try FileOutbox(directory: root)
        try await reopened.prepareNutritionCompatibility()
        let retry = try reopened.nutritionCompatibleItems(for: "synthetic", support: .unknown)

        XCTAssertTrue(retry.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original.fileURL), payload)
        XCTAssertEqual(try reopened.nutritionCompatibleItems(for: "synthetic", support: .supported).map(\.id), [original.id])
        XCTAssertThrowsError(try reopened.nutritionCompatibleItems(for: "replacement", support: .supported))
    }

    @MainActor
    func testSupportedCheckpointCanFinalizePastHeldNutrition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        let dietaryCheckpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "synthetic", sourceKey: "phone", cursorKind: "dietary_protein", cursorValue: "held"
        )
        _ = try outbox.enqueueSequence(
            [JSONEncoder().encode(makeBatch(types: [nutrition], samples: []))],
            receiverIdentity: "synthetic", cursorCheckpoint: dietaryCheckpoint
        )
        let supported = try XCTUnwrap(outbox.enqueueSequence(
            [JSONEncoder().encode(makeBatch(types: [.weight], samples: []))], receiverIdentity: "synthetic",
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: "synthetic", sourceKey: "phone", cursorKind: "weight", cursorValue: "delivered"
            )
        ).first)
        let finalizer = OutboxDeliveryCursorFinalizer(outbox: outbox, cursorStore: cursors)
        let probe = NutritionCodecProbe()
        outbox.observeNutritionCodec = { probe.record() }
        try await outbox.prepareNutritionCompatibility()
        let codecCount = probe.values.count

        _ = try finalizer.recordDirectReceiverAcceptance(itemID: supported.id, receiverBindingID: "synthetic")

        XCTAssertEqual(probe.values.count, codecCount)
        XCTAssertEqual(try cursors.cursorValue(receiverBindingID: "synthetic", sourceKey: "phone", cursorKind: "weight"), "delivered")
        XCTAssertNil(try cursors.cursorValue(receiverBindingID: "synthetic", sourceKey: "phone", cursorKind: "dietary_protein"))
        XCTAssertEqual(try outbox.pendingItems().count, 1)
    }

    @MainActor
    func testFreshBackgroundCompletionFinalizesSupportedCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        let held = try XCTUnwrap(outbox.enqueueSequence(
            [JSONEncoder().encode(makeBatch(types: [nutrition], samples: []))],
            receiverIdentity: "synthetic",
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: "synthetic", sourceKey: "phone",
                cursorKind: "dietary_protein", cursorValue: "held"
            )
        ).first)
        let supported = try XCTUnwrap(outbox.enqueueSequence(
            [JSONEncoder().encode(makeBatch(types: [.weight], samples: [], cursorKind: "weight"))],
            receiverIdentity: "synthetic",
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: "synthetic", sourceKey: "phone",
                cursorKind: "weight", cursorValue: "delivered"
            )
        ).first)
        let callbackOutbox = try FileOutbox(directory: outbox.directoryURL)
        let finalizer = OutboxDeliveryCursorFinalizer(outbox: callbackOutbox, cursorStore: cursors)
        let probe = NutritionCodecProbe()
        callbackOutbox.observeNutritionCodec = { probe.record() }

        let outcome = try await DirectUploadFinalizer.finishForSync(
            descriptor: DirectUploadCompletionDescriptor(
                itemID: supported.id, receiverGeneration: "generation", receiverBindingID: "synthetic"
            ),
            completion: BackgroundUploadTaskCompletion(
                statusCode: 202, hadTransportError: false, sleepMinimumResetEpoch: nil
            ),
            currentReceiverGeneration: "generation", currentReceiverBindingID: "synthetic",
            validate: { try callbackOutbox.requireUploadAdmission() },
            recoverSleepBaseline: { _, _ in XCTFail("Unexpected reset recovery") },
            retire: { itemID, binding in
                let finalized = try await finalizer.recordDirectReceiverAcceptanceForSync(
                    itemID: itemID, receiverBindingID: binding,
                    validate: { try callbackOutbox.requireUploadAdmission() }
                )
                XCTAssertTrue(finalized)
            }
        )

        XCTAssertEqual(outcome, .retired)
        XCTAssertFalse(probe.values.isEmpty)
        XCTAssertTrue(probe.values.allSatisfy { !$0 })
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: "synthetic", sourceKey: "phone", cursorKind: "weight"
        ), "delivered")
        XCTAssertNil(try cursors.cursorValue(
            receiverBindingID: "synthetic", sourceKey: "phone", cursorKind: "dietary_protein"
        ))
        XCTAssertEqual(try callbackOutbox.pendingItems().map(\.id), [held.id])
    }

    @MainActor
    func testAcknowledgedSupportedCheckpointRecoversAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        let held = try XCTUnwrap(outbox.enqueueSequence(
            [JSONEncoder().encode(makeBatch(types: [nutrition], samples: []))],
            receiverIdentity: "synthetic",
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: "synthetic", sourceKey: "phone",
                cursorKind: "dietary_protein", cursorValue: "held"
            )
        ).first)
        let supported = try XCTUnwrap(outbox.enqueueSequence(
            [JSONEncoder().encode(makeBatch(types: [.weight], samples: [], cursorKind: "weight"))],
            receiverIdentity: "synthetic",
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: "synthetic", sourceKey: "phone",
                cursorKind: "weight", cursorValue: "delivered"
            )
        ).first)
        let callbackOutbox = try FileOutbox(directory: outbox.directoryURL)
        XCTAssertNil(try callbackOutbox.recordDirectUploadAccepted(
            itemID: supported.id, receiverIdentity: "synthetic"
        ))
        XCTAssertNil(try callbackOutbox.pendingItem(id: supported.id))
        let reopened = try FileOutbox(directory: outbox.directoryURL)
        try await reopened.prepareNutritionCompatibility()
        let finalizer = OutboxDeliveryCursorFinalizer(outbox: reopened, cursorStore: cursors)

        let finalized = try finalizer.finalizeDirectAcknowledgments(receiverBindingID: "synthetic")

        XCTAssertTrue(finalized)
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: "synthetic", sourceKey: "phone", cursorKind: "weight"
        ), "delivered")
        XCTAssertNil(try cursors.cursorValue(
            receiverBindingID: "synthetic", sourceKey: "phone", cursorKind: "dietary_protein"
        ))
        XCTAssertEqual(try reopened.pendingItems().map(\.id), [held.id])
        XCTAssertFalse(try finalizer.finalizeDirectAcknowledgments(receiverBindingID: "synthetic"))
    }

    private var nutrition: HealthBridgeHealthType {
        HealthBridgeHealthType(
            typeCode: "dietary_protein", displayName: "Protein", category: .nutrition,
            defaultUnit: "g", sensitivity: .moderate, aliases: []
        )
    }

    private func makeBatch(
        types: [HealthBridgeHealthType], samples: [HealthBridgeSample],
        cursorKind: String = "dietary_protein"
    ) -> HealthBridgeBatchV1 {
        let window = HealthBridgeTimeWindow(startTime: "2026-10-01T00:00:00Z", endTime: "2026-10-02T00:00:00Z")
        return HealthBridgeBatchV1(
            generatedAt: window.endTime, exportWindow: window, sources: [], healthTypes: types,
            samples: samples, workouts: [], sleepSessions: [], deletedRecords: [],
            sync: HealthBridgeSyncContext(syncWindow: window, cursors: [
                HealthBridgeSyncCursor(sourceKey: "phone", cursorKind: cursorKind, cursorValue: "unsent")
            ])
        )
    }
}

private enum NutritionPreparationChange { case cancel, payload, reset, owner }

final class NutritionCodecProbe: @unchecked Sendable {
    let entered = XCTestExpectation(description: "nutrition codec entered")
    private let lock = NSLock()
    private let unblock = DispatchSemaphore(value: 0)
    private let blocking: Bool
    private var observations: [Bool] = []
    private var expired = false
    var values: [Bool] { lock.withLock { observations } }
    var watchdogExpired: Bool { lock.withLock { expired } }
    init(blocking: Bool = false) { self.blocking = blocking }
    func record() {
        let first = lock.withLock {
            observations.append(Thread.isMainThread)
            return observations.count == 1
        }
        guard first else { return }
        entered.fulfill()
        if blocking && unblock.wait(timeout: .now() + 10) != .success {
            lock.withLock { expired = true }
        }
    }
    func release() { unblock.signal() }
}

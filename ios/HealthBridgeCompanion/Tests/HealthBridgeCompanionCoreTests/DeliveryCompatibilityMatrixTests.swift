import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class DeliveryCompatibilityMatrixTests: XCTestCase {
    func testEncoderOutboxDirectHTTPAndDeliveryPlaintextUseOneExactBuffer() throws {
        let vector = try DeliveryProtocolV1TestSupport.fixture("swift")
        let expected = try DeliveryProtocolV1TestSupport.data(vector.plaintext)
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: expected)
        let encoder = Task11EncoderProbe()
        let encoded = try encoder.encode(batch)
        XCTAssertEqual(encoded, expected)
        XCTAssertEqual(encoder.invocationCount, 1)

        let directDirectory = try task11TemporaryDirectory("direct")
        let mailboxDirectory = try task11TemporaryDirectory("mailbox")
        defer {
            try? FileManager.default.removeItem(at: directDirectory)
            try? FileManager.default.removeItem(at: mailboxDirectory)
        }
        let directOutbox = try FileOutbox(directory: directDirectory)
        let mailboxOutbox = try FileOutbox(directory: mailboxDirectory)
        let directItem = try directOutbox.enqueue(
            encoded,
            receiverIdentity: "synthetic-direct-binding"
        )
        let mailboxItem = try mailboxOutbox.enqueue(
            encoded,
            receiverIdentity: "synthetic-mailbox-binding"
        )

        var directBody: Data?
        let transport: any DeliveryTransport = DirectHTTPTransport(
            receiverURL: try XCTUnwrap(
                URL(string: "https://receiver.example.test/v1/batches")
            ),
            bearerToken: "synthetic-direct-token",
            receiverGeneration: "g2",
            receiverBindingID: "synthetic-direct-binding",
            alreadyScheduledItemIDs: [],
            schedule: { plan in directBody = try Data(contentsOf: plan.fileURL) }
        )
        let directResult = try transport.deliver(
            DeliveryTransportInput(item: directItem)
        )
        XCTAssertEqual(directResult, .published)
        XCTAssertEqual(directBody, encoded)
        XCTAssertEqual(encoder.invocationCount, 1)

        let envelope = try DeliveryProtocolV1.sealDelivery(
            try Data(contentsOf: mailboxItem.fileURL),
            context: DeliveryProtocolV1TestSupport.envelopeSeal("swift")
        )
        let binding = try mailboxOutbox.finalizeMailboxEnvelope(
            itemID: mailboxItem.id,
            envelope: envelope,
            expectedPayloadSHA256: vector.payloadSHA256
        )
        let finalizedEnvelope = try Data(
            contentsOf: mailboxDirectory.appendingPathComponent(binding.envelopeFilename)
        )
        let opened = try DeliveryProtocolV1.openDelivery(
            finalizedEnvelope,
            context: DeliveryProtocolV1TestSupport.envelopeOpen("swift")
        )
        let persisted = try Data(contentsOf: mailboxItem.fileURL)
        XCTAssertEqual(persisted, encoded)
        XCTAssertEqual(opened.plaintext, persisted)
        XCTAssertEqual(opened.payloadSHA256, vector.payloadSHA256)
        XCTAssertEqual(encoder.invocationCount, 1)
        XCTAssertThrowsError(try mailboxOutbox.markUploaded(mailboxItem)) { error in
            XCTAssertEqual(error as? FileOutboxMailboxError, .mailboxArtifactsRequireHold)
        }
        print(
            "TASK11_EXACT_BYTES row=swift_encoder_file_outbox_direct_http_exact_bytes "
                + "mailbox_row=swift_file_outbox_delivery_plaintext_exact_bytes "
                + "payload_sha256=\(persisted.sha256Hex) byte_count=\(persisted.count) "
                + "post_enqueue_encoder_invocations=\(encoder.invocationCount - 1) "
                + "direct_finalization=markUploaded mailbox_finalization=committed_ack_only"
        )
    }
}

private final class Task11EncoderProbe {
    private(set) var invocationCount = 0

    func encode(_ batch: HealthBridgeBatchV1) throws -> Data {
        invocationCount += 1
        return try HealthBridgeBatchEncoder().encode(batch)
    }
}

private func task11TemporaryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("task-11-compatibility-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

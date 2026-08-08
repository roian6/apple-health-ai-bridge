import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class DeliveryProtocolV1VectorProducerTests: XCTestCase {
    func testSwiftSignatureInputsMatchPythonGoldenPreimages() throws {
        let fixture = try DeliveryProtocolV1TestSupport.fixture("swift")
        let envelope = try DeliveryProtocolV1TestSupport.data(fixture.envelope)
        let ack = try DeliveryProtocolV1TestSupport.data(fixture.ack)
        guard case var .object(envelopeFields) = try DeliveryProtocolV1.decodeMetadata(envelope),
              case var .object(ackFields) = try DeliveryProtocolV1.decodeMetadata(ack) else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        envelopeFields.removeValue(forKey: "signature")
        ackFields.removeValue(forKey: "signature")
        let envelopePreimage = try DeliveryProtocolV1.signaturePreimage(
            DeliveryProtocolV1.deliverySignature,
            envelopeFields
        )
        let ackPreimage = try DeliveryProtocolV1.signaturePreimage(
            DeliveryProtocolV1.ackSignature,
            ackFields
        )
        let sender = try DeliveryProtocolV1TestSupport.signingKey("health-bridge/swift/sender-signing")
        let receiver = try DeliveryProtocolV1TestSupport.signingKey("health-bridge/swift/receiver-signing")

        XCTAssertEqual(sender.rawRepresentation.sha256Hex, "69095e87908860d6f7c838ee52d557fa67a86b71342d76a13d2001807cefd4dc")
        XCTAssertEqual(envelopePreimage.sha256Hex, "751d61b672e0664946195c7b6085fac534c79dceff75d8edf0c4aadc24f468c8")
        XCTAssertEqual(receiver.rawRepresentation.sha256Hex, "6faf92ab9158455558e3937483e99047a73602ee8539c5ffd29c634f111a9e27")
        XCTAssertEqual(ackPreimage.sha256Hex, "1a6ca929e69116da43e5716f34ec9bbab9c1a4f5745f676bc5d1ee9f7b1e6abf")
        XCTAssertTrue(sender.publicKey.isValidSignature(try sender.signature(for: envelopePreimage), for: envelopePreimage))
        XCTAssertTrue(receiver.publicKey.isValidSignature(try receiver.signature(for: ackPreimage), for: ackPreimage))
    }

    func testSwiftProducerMatchesOrWritesPublicFixture() throws {
        let origin = "swift"
        let plaintext = try DeliveryProtocolV1TestSupport.swiftPersistedBatchBytes()
        let entropy = try DeliveryProtocolV1TestSupport.vectorEntropy(origin)
        let envelope = try DeliveryProtocolV1.sealDeliveryForVector(
            plaintext,
            context: DeliveryProtocolV1TestSupport.envelopeSeal(origin),
            ephemeralPrivateKey: entropy.0,
            nonce: entropy.1
        )
        let receipt = DeliveryProtocolV1TestSupport.receipt(plaintext)
        let ack = try DeliveryProtocolV1.sealAck(
            receipt,
            context: DeliveryProtocolV1TestSupport.ackSeal(origin)
        )
        let negative = try negativeVectors(envelope: envelope, ack: ack)
        let fixture: [String: Any] = [
            "v": 1,
            "kind": "delivery_protocol_v1_vectors",
            "origin": origin,
            "plaintext": DeliveryProtocolV1.b64(plaintext),
            "payload_sha256": plaintext.sha256Hex,
            "envelope": DeliveryProtocolV1.b64(envelope),
            "ack": DeliveryProtocolV1.b64(ack),
            "receipt": DeliveryProtocolV1.b64(receipt.encodedMetadata),
            "negative": negative,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        if let path = ProcessInfo.processInfo.environment["HEALTH_BRIDGE_VECTOR_OUTPUT"] {
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            let committed = try DeliveryProtocolV1TestSupport.fixture(origin)
            XCTAssertEqual(
                try DeliveryProtocolV1.unsignedMetadata(DeliveryProtocolV1TestSupport.data(committed.envelope)),
                try DeliveryProtocolV1.unsignedMetadata(envelope)
            )
            XCTAssertEqual(
                try DeliveryProtocolV1.unsignedMetadata(DeliveryProtocolV1TestSupport.data(committed.ack)),
                try DeliveryProtocolV1.unsignedMetadata(ack)
            )
            XCTAssertEqual(try DeliveryProtocolV1TestSupport.data(committed.plaintext), plaintext)
        }
    }

    private func negativeVectors(envelope: Data, ack: Data) throws -> [[String: String]] {
        var result: [[String: String]] = []
        let rows = [
            ("delivery", envelope, ["signature", "ciphertext", "nonce", "sender_signing_key_id", "receiver_agreement_key_id", "content_type"]),
            ("ack", ack, ["signature", "ciphertext", "nonce", "device_agreement_key_id", "receiver_signing_key_id", "connection_generation"]),
        ]
        for (target, encoded, names) in rows {
            guard case let .object(fields) = try DeliveryProtocolV1.decodeMetadata(encoded) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            for name in names {
                let replacement: String
                switch fields[name] {
                case let .string(value):
                    replacement = (value.first == "A" ? "B" : "A") + value.dropFirst()
                case .integer:
                    replacement = "8"
                default:
                    throw DeliveryProtocolV1Error.authenticationFailed
                }
                result.append(["target": target, "field": name, "replacement": replacement])
            }
        }
        return result
    }

}

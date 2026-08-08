import CryptoKit
import XCTest
@testable import HealthBridgeCompanionCore

final class DeliveryProtocolV1Tests: XCTestCase {
    func testHBJCS1CanonicalMetadataUsesSignedIntegersAndRejectsFloats() throws {
        let encoded = try DeliveryProtocolV1.encodeMetadata(.object([
            "z": .null,
            "a": .string("\n"),
            "n": .integer(Int64.min),
            "ok": .bool(true),
        ]))
        XCTAssertEqual(encoded, Data(#"{"a":"\u000a","n":-9223372036854775808,"ok":true,"z":null}"#.utf8))
        XCTAssertThrowsError(try DeliveryProtocolV1.decodeMetadata(Data(#"{"value":1.25}"#.utf8)))
        XCTAssertThrowsError(try DeliveryProtocolV1.decodeMetadata(Data(#"{"b":1,"a":2}"#.utf8)))
    }

    func testKeyIDBindsLowercaseAlgorithmNULAndRawPublicKey() throws {
        let publicKey = Data(0 ..< 32)
        let expected = Data(SHA256.hash(data: Data("ed25519".utf8) + Data([0]) + publicKey))
            .prefixData(16).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try DeliveryProtocolV1.keyID(algorithm: "ed25519", publicKey: publicKey), expected)
        XCTAssertThrowsError(try DeliveryProtocolV1.keyID(algorithm: "Ed25519", publicKey: publicKey))
        XCTAssertThrowsError(try DeliveryProtocolV1.keyID(algorithm: "x25519\0", publicKey: publicKey))
    }

    func testDeliveryAndAckRoundTripExactOpaqueBytes() throws {
        let fixture = try DeliveryProtocolV1TestSupport.fixture("python")
        let plaintext = try DeliveryProtocolV1TestSupport.data(fixture.plaintext)
        let entropy = try DeliveryProtocolV1TestSupport.vectorEntropy("python")
        let envelope = try DeliveryProtocolV1.sealDeliveryForVector(
            plaintext,
            context: DeliveryProtocolV1TestSupport.envelopeSeal("python"),
            ephemeralPrivateKey: entropy.0,
            nonce: entropy.1
        )
        let opened = try DeliveryProtocolV1.openDelivery(
            envelope,
            context: DeliveryProtocolV1TestSupport.envelopeOpen("python")
        )
        let receipt = DeliveryProtocolV1TestSupport.receipt(plaintext)
        let ack = try DeliveryProtocolV1.sealAck(receipt, context: DeliveryProtocolV1TestSupport.ackSeal("python"))
        XCTAssertEqual(opened.plaintext, plaintext)
        XCTAssertEqual(opened.payloadSHA256, plaintext.sha256Hex)
        XCTAssertEqual(try DeliveryProtocolV1.openAck(ack, context: DeliveryProtocolV1TestSupport.ackOpen("python")), receipt)
    }

    func testMetadataAndPayloadLimitsFailClosed() throws {
        XCTAssertThrowsError(try DeliveryProtocolV1.decodeMetadata(Data(repeating: 0x20, count: 2_097_153)))
        XCTAssertThrowsError(
            try DeliveryProtocolV1.sealDelivery(
                Data(repeating: 0x20, count: 1_048_577),
                context: DeliveryProtocolV1TestSupport.envelopeSeal("python")
            )
        )
    }
}

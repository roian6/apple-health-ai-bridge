import XCTest
@testable import HealthBridgeCompanionCore

final class DeliveryProtocolV1GoldenVectorTests: XCTestCase {
    func testPythonAndSwiftOriginVectorsMatchExactMetadataAndPlaintextBytes() throws {
        for origin in ["python", "swift"] {
            let fixture = try DeliveryProtocolV1TestSupport.fixture(origin)
            let plaintext = try DeliveryProtocolV1TestSupport.data(fixture.plaintext)
            let expectedEnvelope = try DeliveryProtocolV1TestSupport.data(fixture.envelope)
            let expectedAck = try DeliveryProtocolV1TestSupport.data(fixture.ack)
            let expectedReceipt = try DeliveryProtocolV1TestSupport.data(fixture.receipt)
            let entropy = try DeliveryProtocolV1TestSupport.vectorEntropy(origin)

            let actualEnvelope = try DeliveryProtocolV1.sealDeliveryForVector(
                plaintext,
                context: DeliveryProtocolV1TestSupport.envelopeSeal(origin),
                ephemeralPrivateKey: entropy.0,
                nonce: entropy.1
            )
            let opened = try DeliveryProtocolV1.openDelivery(
                expectedEnvelope,
                context: DeliveryProtocolV1TestSupport.envelopeOpen(origin)
            )
            let receipt = DeliveryProtocolV1TestSupport.receipt(plaintext)
            let actualAck = try DeliveryProtocolV1.sealAck(
                receipt,
                context: DeliveryProtocolV1TestSupport.ackSeal(origin)
            )

            XCTAssertEqual(fixture.origin, origin)
            XCTAssertEqual(
                try DeliveryProtocolV1.unsignedMetadata(actualEnvelope),
                try DeliveryProtocolV1.unsignedMetadata(expectedEnvelope)
            )
            XCTAssertEqual(
                try DeliveryProtocolV1.unsignedMetadata(actualAck),
                try DeliveryProtocolV1.unsignedMetadata(expectedAck)
            )
            XCTAssertEqual(
                try DeliveryProtocolV1.encodeMetadata(DeliveryProtocolV1.decodeMetadata(expectedEnvelope)),
                expectedEnvelope
            )
            XCTAssertEqual(
                try DeliveryProtocolV1.encodeMetadata(DeliveryProtocolV1.decodeMetadata(expectedAck)),
                expectedAck
            )
            XCTAssertEqual(receipt.encodedMetadata, expectedReceipt)
            XCTAssertEqual(opened.plaintext, plaintext)
            XCTAssertEqual(opened.payloadSHA256, fixture.payloadSHA256)
            XCTAssertEqual(try JSONDecoder().decode(HealthBridgeBatchV1.self, from: opened.plaintext).schemaID, "health_bridge.batch.v1")
            XCTAssertEqual(try DeliveryProtocolV1.openAck(expectedAck, context: DeliveryProtocolV1TestSupport.ackOpen(origin)), receipt)
        }
    }

    func testSwiftOriginPlaintextIsLiteralPersistedEncoderBytesIncludingFraction() throws {
        let fixture = try DeliveryProtocolV1TestSupport.fixture("swift")
        let expected = try DeliveryProtocolV1TestSupport.data(fixture.plaintext)
        let persisted = try DeliveryProtocolV1TestSupport.swiftPersistedBatchBytes()

        XCTAssertEqual(persisted, expected)
        XCTAssertTrue(String(decoding: persisted, as: UTF8.self).contains(#""value":1.25"#))
    }
}

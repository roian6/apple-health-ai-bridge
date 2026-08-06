import CryptoKit
import XCTest
@testable import HealthBridgeCompanionCore

final class DeliveryProtocolV1SecurityRegressionTests: XCTestCase {
    func testDeepCanonicalMetadataFailsClosedInsteadOfRecursingWithoutBound() throws {
        let depth = 129
        let encoded = Data((String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8)
        var value = HBJCS1Value.integer(0)
        for _ in 0 ..< depth { value = .array([value]) }

        assertAuthenticationFailure { try DeliveryProtocolV1.decodeMetadata(encoded) }
        assertAuthenticationFailure { try DeliveryProtocolV1.encodeMetadata(value) }

        let fixture = try DeliveryProtocolV1TestSupport.fixture("python")
        let envelope = try DeliveryProtocolV1TestSupport.data(fixture.envelope)
        let ack = try DeliveryProtocolV1TestSupport.data(fixture.ack)
        assertAuthenticationFailure {
            try DeliveryProtocolV1.openDelivery(
                insertingDeepUnknownField(envelope, depth: depth),
                context: DeliveryProtocolV1TestSupport.envelopeOpen("python")
            )
        }
        assertAuthenticationFailure {
            try DeliveryProtocolV1.openAck(
                insertingDeepUnknownField(ack, depth: depth),
                context: DeliveryProtocolV1TestSupport.ackOpen("python")
            )
        }
    }

    func testAuthenticatedDuplicatePayloadKeysFailAtRootAndNestedDepth() throws {
        let original = try persistedPlaintext()
        let duplicateRoot = replacing(
            original,
            needle: #"{"deleted_records""#,
            replacement: #"{"schema_id":"health_bridge.batch.v1","deleted_records""#
        )
        let duplicateNested = replacing(
            original,
            needle: #""metadata":{}"#,
            replacement: #""metadata":{"synthetic":"value","synthetic":"value"}"#
        )

        try assertPayloadInvalid(duplicateRoot)
        try assertPayloadInvalid(duplicateNested)
    }

    func testAuthenticatedUnknownFieldsAndWrongSchemaVersionFailStrictly() throws {
        let original = try persistedPlaintext()
        let unknownRoot = replacing(
            original,
            needle: #"{"deleted_records""#,
            replacement: #"{"unexpected":null,"deleted_records""#
        )
        let unknownNested = replacing(
            original,
            needle: #""client_record_id":"synthetic-sample-1""#,
            replacement: #""unexpected":"synthetic","client_record_id":"synthetic-sample-1""#
        )
        let wrongVersion = replacing(
            original,
            needle: #""schema_version":"1.0.0""#,
            replacement: #""schema_version":"2.0.0""#
        )

        try assertPayloadInvalid(unknownRoot)
        try assertPayloadInvalid(unknownNested)
        try assertPayloadInvalid(wrongVersion)
    }

    func testPayloadDigestRequiresLowercaseASCIIHex() throws {
        let receipt = DeliveryReceiptV1(
            result: .committed,
            payloadSHA256: String(repeating: "０", count: 64),
            receiptID: 9,
            datasetGeneration: 4,
            committedAtMS: 1_782_000_000_456,
            errorCode: nil
        )
        assertAuthenticationFailure {
            try DeliveryProtocolV1.sealAck(receipt, context: DeliveryProtocolV1TestSupport.ackSeal("python"))
        }
    }

    func testValidlyResignedTagAndAADMutationsReachAEADAndFailClosed() throws {
        let fixture = try DeliveryProtocolV1TestSupport.fixture("python")
        let envelope = try DeliveryProtocolV1TestSupport.data(fixture.envelope)
        guard case let .object(original) = try DeliveryProtocolV1.decodeMetadata(envelope) else {
            XCTFail("delivery fixture must be an object")
            return
        }

        var tagMutation = original
        var combined = try DeliveryProtocolV1.unb64(try DeliveryProtocolV1.string(tagMutation, "ciphertext"))
        combined[combined.index(before: combined.endIndex)] ^= 1
        tagMutation["ciphertext"] = .string(DeliveryProtocolV1.b64(combined))

        var aadMutation = original
        aadMutation["created_at_ms"] = .integer(try DeliveryProtocolV1.integer(aadMutation, "created_at_ms") + 1)

        for fields in [tagMutation, aadMutation] {
            assertAuthenticationFailure {
                try DeliveryProtocolV1.openDelivery(
                    resignDelivery(fields, origin: "python"),
                    context: DeliveryProtocolV1TestSupport.envelopeOpen("python")
                )
            }
        }
    }

    private func persistedPlaintext() throws -> Data {
        try DeliveryProtocolV1TestSupport.data(
            DeliveryProtocolV1TestSupport.fixture("swift").plaintext
        )
    }

    private func assertPayloadInvalid(_ plaintext: Data) throws {
        let entropy = try DeliveryProtocolV1TestSupport.vectorEntropy("swift")
        let envelope = try DeliveryProtocolV1.sealDeliveryForVector(
            plaintext,
            context: DeliveryProtocolV1TestSupport.envelopeSeal("swift"),
            ephemeralPrivateKey: entropy.0,
            nonce: entropy.1
        )
        XCTAssertThrowsError(
            try DeliveryProtocolV1.openDelivery(
                envelope,
                context: DeliveryProtocolV1TestSupport.envelopeOpen("swift")
            )
        ) { error in
            XCTAssertEqual(error as? DeliveryProtocolV1Error, .payloadInvalid)
        }
    }

    private func resignDelivery(_ fields: [String: HBJCS1Value], origin: String) throws -> Data {
        var unsigned = fields
        unsigned.removeValue(forKey: "signature")
        let signing = try DeliveryProtocolV1TestSupport.signingKey("health-bridge/\(origin)/sender-signing")
        let signature = try signing.signature(
            for: DeliveryProtocolV1.signaturePreimage(DeliveryProtocolV1.deliverySignature, unsigned)
        )
        unsigned["signature"] = .string(DeliveryProtocolV1.b64(signature))
        return try DeliveryProtocolV1.encodeMetadata(.object(unsigned))
    }

    private func insertingDeepUnknownField(_ encoded: Data, depth: Int) -> Data {
        let nested = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
        var result = Data("{\"probe\":\(nested),".utf8)
        result += encoded.dropFirst()
        return result
    }

    private func replacing(_ data: Data, needle: String, replacement: String) -> Data {
        guard let range = data.range(of: Data(needle.utf8)) else {
            XCTFail("synthetic fixture must contain \(needle)")
            return data
        }
        var result = data
        result.replaceSubrange(range, with: Data(replacement.utf8))
        return result
    }

    private func assertAuthenticationFailure<T>(_ operation: () throws -> T) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? DeliveryProtocolV1Error, .authenticationFailed)
        }
    }
}

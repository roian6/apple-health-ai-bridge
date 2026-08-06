import XCTest
@testable import HealthBridgeCompanionCore

final class DeliveryProtocolV1TamperTests: XCTestCase {
    func testCommittedNegativeVectorsRejectEveryPostEnvelopeMutation() throws {
        for origin in ["python", "swift"] {
            let fixture = try DeliveryProtocolV1TestSupport.fixture(origin)
            let envelope = try DeliveryProtocolV1TestSupport.data(fixture.envelope)
            let ack = try DeliveryProtocolV1TestSupport.data(fixture.ack)
            for mutation in fixture.negative {
                let source = mutation.target == "delivery" ? envelope : ack
                let mutated = try DeliveryProtocolV1.replacingMetadataString(
                    source,
                    field: mutation.field,
                    value: mutation.replacement
                )
                if mutation.target == "delivery" {
                    XCTAssertThrowsError(
                        try DeliveryProtocolV1.openDelivery(
                            mutated,
                            context: DeliveryProtocolV1TestSupport.envelopeOpen(origin)
                        ), mutation.field
                    )
                } else {
                    XCTAssertThrowsError(
                        try DeliveryProtocolV1.openAck(
                            mutated,
                            context: DeliveryProtocolV1TestSupport.ackOpen(origin)
                        ), mutation.field
                    )
                }
            }
        }
    }

    func testPersistedByteMutationCreatesDistinctFinalEnvelopeWithoutChangingVector() throws {
        let fixture = try DeliveryProtocolV1TestSupport.fixture("swift")
        let original = try DeliveryProtocolV1TestSupport.data(fixture.plaintext)
        let finalized = try DeliveryProtocolV1TestSupport.data(fixture.envelope)
        let mutatedPlaintext = original.replacingFirst(needle: Data("1.25".utf8), replacement: Data("1.250".utf8))
        let entropy = try DeliveryProtocolV1TestSupport.vectorEntropy("swift")
        let distinct = try DeliveryProtocolV1.sealDeliveryForVector(
            mutatedPlaintext,
            context: DeliveryProtocolV1TestSupport.envelopeSeal("swift"),
            ephemeralPrivateKey: entropy.0,
            nonce: entropy.1
        )
        let opened = try DeliveryProtocolV1.openDelivery(
            distinct,
            context: DeliveryProtocolV1TestSupport.envelopeOpen("swift")
        )

        XCTAssertNotEqual(distinct, finalized)
        XCTAssertNotEqual(opened.payloadSHA256, fixture.payloadSHA256)
        XCTAssertEqual(try DeliveryProtocolV1TestSupport.data(fixture.envelope), finalized)
    }

    func testDirectionSeparatedAckCannotBeOpenedAsDelivery() throws {
        let fixture = try DeliveryProtocolV1TestSupport.fixture("python")
        XCTAssertThrowsError(
            try DeliveryProtocolV1.openDelivery(
                DeliveryProtocolV1TestSupport.data(fixture.ack),
                context: DeliveryProtocolV1TestSupport.envelopeOpen("python")
            )
        )
    }
}

private extension Data {
    func replacingFirst(needle: Data, replacement: Data) -> Data {
        guard let range = range(of: needle) else { return self }
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}

import CryptoKit
import Foundation
import XCTest
#if canImport(HealthBridgeCompanion)
@testable import HealthBridgeCompanion
#else
@testable import HealthBridgeCompanionCore
#endif

struct CapabilityTestFixture {
    let key: Curve25519.Signing.PrivateKey
    let identity: MailboxConnectionIdentityV1
    let document: Data

    init() throws {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        identity = MailboxConnectionIdentityV1(
            receiverID: String(repeating: "02", count: 16), deviceID: String(repeating: "03", count: 16),
            devicePrincipal: "synthetic", deviceSigningKeyID: String(repeating: "11", count: 16),
            deviceAgreementKeyID: String(repeating: "22", count: 16),
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(algorithm: "ed25519", publicKey: key.publicKey.rawRepresentation),
            receiverAgreementKeyID: String(repeating: "33", count: 16),
            receiverSigningPublicKey: key.publicKey.rawRepresentation.base64URLEncodedString(),
            receiverAgreementPublicKey: Data(repeating: 0x44, count: 32).base64URLEncodedString(),
            opaqueBinding: Data(repeating: 0x55, count: 32).base64URLEncodedString(), connectionGeneration: 1
        )
        struct Golden: Decodable { let document_utf8: String }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        document = Data(try JSONDecoder().decode(Golden.self, from: Data(contentsOf:
            root.appendingPathComponent("tests/fixtures/mailbox_receiver_capabilities_v1.synthetic.json"))).document_utf8.utf8)
    }

    func changed(_ mutation: (inout [String: HBJCS1Value]) -> Void, resign: Bool = true) throws -> Data {
        guard case .object(var fields) = try DeliveryProtocolV1.decodeMetadata(document) else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        mutation(&fields)
        if resign {
            fields.removeValue(forKey: "signature")
            let domain = Data("health-bridge/mailbox/v1/receiver-capabilities/signature\0".utf8)
            fields["signature"] = .string(try key.signature(for: domain + DeliveryProtocolV1.encodeMetadata(.object(fields))).base64URLEncodedString())
        }
        return try DeliveryProtocolV1.encodeMetadata(.object(fields))
    }
}

final class MailboxReceiverCapabilitiesTests: XCTestCase {
    func testPythonGoldenAndUnknownFieldSignatureBinding() throws {
        let f = try CapabilityTestFixture()
        XCTAssertTrue(try MailboxReceiverCapabilities.decode(f.document, identity: f.identity).nutritionSupported)
        let tampered = try f.changed({ fields in
            guard case .object(var capabilities)? = fields["capabilities"] else { return }
            capabilities["future_synthetic"] = .object(["enabled": .bool(false)])
            fields["capabilities"] = .object(capabilities)
        }, resign: false)
        XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(tampered, identity: f.identity))
        let compatible = try f.changed { fields in
            guard case .object(var capabilities)? = fields["capabilities"] else { return }
            capabilities["future_synthetic"] = .object(["enabled": .bool(false)])
            fields["capabilities"] = .object(capabilities)
        }
        XCTAssertTrue(try MailboxReceiverCapabilities.decode(compatible, identity: f.identity).nutritionSupported)
    }

    func testRejectsSignedWrongWrapperAndRequiredFields() throws {
        let f = try CapabilityTestFixture()
        let wrong: [(String, HBJCS1Value)] = [
            ("v", .bool(true)), ("v", .integer(2)), ("kind", .string("ack")),
            ("receiver_id", .string(String(repeating: "04", count: 16))),
            ("device_id", .string(String(repeating: "04", count: 16))),
            ("connection_generation", .integer(2)), ("connection_generation", .integer(-1)),
            ("connection_generation", .bool(true)), ("receiver_signing_key_id", .string(String(repeating: "00", count: 16))),
            ("extra", .null), ("capabilities", .object([:])), ("capabilities", .null)
        ]
        for (name, value) in wrong {
            let data = try f.changed { $0[name] = value }
            XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(data, identity: f.identity), name)
        }
        for (field, value) in [("nutrition_supported", HBJCS1Value.integer(1)), ("schema_id", .string("unknown")), ("batch_schema_id", .string("unknown"))] {
            let data = try f.changed { fields in
                guard case .object(var capabilities)? = fields["capabilities"] else { return }
                capabilities[field] = value
                fields["capabilities"] = .object(capabilities)
            }
            XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(data, identity: f.identity))
        }
    }

    func testFalseDeclarationAndMalformedBounds() throws {
        let f = try CapabilityTestFixture()
        let unsupported = try f.changed { fields in
            guard case .object(var capabilities)? = fields["capabilities"] else { return }
            capabilities["nutrition_supported"] = .bool(false)
            fields["capabilities"] = .object(capabilities)
        }
        XCTAssertFalse(try MailboxReceiverCapabilities.decode(unsupported, identity: f.identity).nutritionSupported)
        for data in [Data(repeating: 0x20, count: 8193), Data("{}".utf8), Data([0xff]),
            Data(String(decoding: f.document, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":1,\"v\":1").utf8)] {
            XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(data, identity: f.identity))
        }
    }
}

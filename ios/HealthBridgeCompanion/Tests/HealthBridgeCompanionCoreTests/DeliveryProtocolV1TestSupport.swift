import CryptoKit
import Foundation
@testable import HealthBridgeCompanionCore

struct DeliveryVectorFixture: Decodable {
    struct Negative: Decodable {
        let target: String
        let field: String
        let replacement: String
    }

    let origin: String
    let plaintext: String
    let payloadSHA256: String
    let envelope: String
    let ack: String
    let receipt: String
    let negative: [Negative]

    enum CodingKeys: String, CodingKey {
        case origin, plaintext, envelope, ack, receipt, negative
        case payloadSHA256 = "payload_sha256"
    }
}

enum DeliveryProtocolV1TestSupport {
    static func fixture(_ origin: String) throws -> DeliveryVectorFixture {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = package.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/delivery_v1_\(origin).synthetic.json")
        return try JSONDecoder().decode(
            DeliveryVectorFixture.self,
            from: Data(contentsOf: url)
        )
    }

    static func data(_ encoded: String) throws -> Data {
        guard let value = Data(base64Encoded: encoded.base64URLPadded) else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return value
    }

    static func digest(_ label: String) -> Data {
        Data(SHA256.hash(data: Data(label.utf8)))
    }

    static func signingKey(_ label: String) throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: digest(label))
    }

    static func agreementKey(_ label: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: digest(label))
    }

    static func envelopeSeal(_ origin: String) throws -> DeliveryEnvelopeSealContext {
        let receiver = try agreementKey("health-bridge/\(origin)/receiver-agreement")
        return DeliveryEnvelopeSealContext(
            envelopeID: digest("health-bridge/\(origin)/envelope-id").prefixData(16),
            receiverID: digest("health-bridge/\(origin)/receiver-id").prefixData(16),
            deviceID: digest("health-bridge/\(origin)/device-id").prefixData(16),
            connectionGeneration: origin == "python" ? 7 : 8,
            createdAtMS: origin == "python" ? 1_782_000_000_123 : -1,
            receiverAgreementPublicKey: receiver.publicKey,
            senderSigningPrivateKey: try signingKey("health-bridge/\(origin)/sender-signing")
        )
    }

    static func envelopeOpen(_ origin: String) throws -> DeliveryEnvelopeOpenContext {
        let seal = try envelopeSeal(origin)
        return DeliveryEnvelopeOpenContext(
            receiverID: seal.receiverID,
            deviceID: seal.deviceID,
            connectionGeneration: seal.connectionGeneration,
            receiverAgreementPrivateKey: try agreementKey("health-bridge/\(origin)/receiver-agreement"),
            senderSigningPublicKey: try signingKey("health-bridge/\(origin)/sender-signing").publicKey
        )
    }

    static func ackSeal(_ origin: String) throws -> DeliveryAckSealContext {
        let envelope = try envelopeSeal(origin)
        return DeliveryAckSealContext(
            envelopeID: envelope.envelopeID,
            receiverID: envelope.receiverID,
            deviceID: envelope.deviceID,
            connectionGeneration: envelope.connectionGeneration,
            deviceAgreementPublicKey: try agreementKey("health-bridge/\(origin)/device-agreement").publicKey,
            receiverSigningPrivateKey: try signingKey("health-bridge/\(origin)/receiver-signing"),
            receiverAgreementPrivateKey: try agreementKey("health-bridge/\(origin)/receiver-agreement")
        )
    }

    static func ackOpen(_ origin: String) throws -> DeliveryAckOpenContext {
        let seal = try ackSeal(origin)
        return DeliveryAckOpenContext(
            envelopeID: seal.envelopeID,
            receiverID: seal.receiverID,
            deviceID: seal.deviceID,
            connectionGeneration: seal.connectionGeneration,
            deviceAgreementPrivateKey: try agreementKey("health-bridge/\(origin)/device-agreement"),
            receiverSigningPublicKey: try signingKey("health-bridge/\(origin)/receiver-signing").publicKey,
            receiverAgreementPublicKey: try agreementKey("health-bridge/\(origin)/receiver-agreement").publicKey
        )
    }

    static func receipt(_ plaintext: Data) -> DeliveryReceiptV1 {
        DeliveryReceiptV1(
            result: .committed,
            payloadSHA256: plaintext.sha256Hex,
            receiptID: 9,
            datasetGeneration: 4,
            committedAtMS: 1_782_000_000_456,
            errorCode: nil
        )
    }

    static func vectorEntropy(_ origin: String) throws -> (Curve25519.KeyAgreement.PrivateKey, Data) {
        (
            try agreementKey("health-bridge/\(origin)/ephemeral-agreement"),
            digest("health-bridge/\(origin)/delivery-nonce").prefixData(12)
        )
    }

    static func swiftPersistedBatchBytes() throws -> Data {
        let batch = HealthBridgeBatchV1(
            generatedAt: "2026-06-08T10:00:00Z",
            exportWindow: .init(startTime: "2026-06-08T00:00:00Z", endTime: "2026-06-09T00:00:00Z"),
            sources: [.init(sourceKey: "synthetic.phone.alpha", name: "Synthetic Phone", kind: .phone)],
            healthTypes: [.steps],
            samples: [.init(
                clientRecordID: "synthetic-sample-1",
                sourceKey: "synthetic.phone.alpha",
                typeCode: "steps",
                startTime: "2026-06-08T09:00:00Z",
                endTime: "2026-06-08T09:05:00Z",
                value: 1.25,
                unit: "count"
            )],
            workouts: [], sleepSessions: [], deletedRecords: [],
            sync: .init(
                syncWindow: .init(startTime: "2026-06-08T00:00:00Z", endTime: "2026-06-09T00:00:00Z"),
                cursors: []
            )
        )
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outbox = try FileOutbox(directory: temporary)
        let item = try outbox.enqueue(
            HealthBridgeBatchEncoder().encode(batch),
            receiverIdentity: "synthetic.binding"
        )
        return try Data(contentsOf: item.fileURL)
    }
}

private extension String {
    var base64URLPadded: String {
        replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toMultipleOf: 4)
    }

    func padding(toMultipleOf divisor: Int) -> String {
        self + String(repeating: "=", count: (divisor - count % divisor) % divisor)
    }
}

extension Data {
    func prefixData(_ count: Int) -> Data { Data(prefix(count)) }
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

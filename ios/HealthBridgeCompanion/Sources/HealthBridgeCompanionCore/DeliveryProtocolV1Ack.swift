import CryptoKit
import Foundation

extension DeliveryProtocolV1 {
    private static let ackFields: Set<String> = [
        "v", "kind", "ack_id", "envelope_id", "receiver_id", "device_id",
        "connection_generation", "device_agreement_key_id", "receiver_signing_key_id",
        "nonce", "ciphertext", "signature",
    ]
    private static let receiptFields: Set<String> = [
        "result", "payload_sha256", "receipt_id", "dataset_generation", "committed_at_ms", "error_code",
    ]

    static func encodeReceipt(_ receipt: DeliveryReceiptV1) -> Data {
        let optionalInteger: (Int64?) -> String = { $0.map(String.init) ?? "null" }
        let error = receipt.errorCode.map { "\"\($0.rawValue)\"" } ?? "null"
        let encoded = "{\"committed_at_ms\":\(optionalInteger(receipt.committedAtMS)),"
            + "\"dataset_generation\":\(optionalInteger(receipt.datasetGeneration)),"
            + "\"error_code\":\(error),"
            + "\"payload_sha256\":\"\(receipt.payloadSHA256)\","
            + "\"receipt_id\":\(optionalInteger(receipt.receiptID)),"
            + "\"result\":\"\(receipt.result.rawValue)\"}"
        return Data(encoded.utf8)
    }

    public static func sealAck(
        _ receipt: DeliveryReceiptV1,
        context: DeliveryAckSealContext
    ) throws -> Data {
        try validateReceipt(receipt)
        guard [context.envelopeID, context.receiverID, context.deviceID].allSatisfy({ $0.count == 16 }),
              context.connectionGeneration >= 0 else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        let plaintext = encodeReceipt(receipt)
        let ackID = Data(SHA256.hash(data: ackID + nul + context.envelopeID + plaintext)).prefixDataV1(16)
        let devicePublic = context.deviceAgreementPublicKey.rawRepresentation
        let receiverSigningPublic = context.receiverSigningPrivateKey.publicKey.rawRepresentation
        let aad: [String: HBJCS1Value] = [
            "v": .integer(1),
            "kind": .string("ack"),
            "ack_id": .string(ackID.hexV1),
            "envelope_id": .string(context.envelopeID.hexV1),
            "receiver_id": .string(context.receiverID.hexV1),
            "device_id": .string(context.deviceID.hexV1),
            "connection_generation": .integer(context.connectionGeneration),
            "device_agreement_key_id": .string(try keyID(algorithm: "x25519", publicKey: devicePublic)),
            "receiver_signing_key_id": .string(try keyID(algorithm: "ed25519", publicKey: receiverSigningPublic)),
        ]
        let secret = try context.receiverAgreementPrivateKey.sharedSecretFromKeyAgreement(
            with: context.deviceAgreementPublicKey
        )
        let saltValue = salt(ackSalt, receiverID: context.receiverID, deviceID: context.deviceID)
        let key = hkdf(secret, salt: saltValue, info: ackKey + nul + ackID, count: 32)
        let nonce = hkdf(secret, salt: saltValue, info: ackNonce + nul + ackID, count: 12)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: ackAAD + nul + (try encodeMetadata(.object(aad)))
        )
        let unsigned = aad.merging([
            "nonce": .string(b64(nonce)),
            "ciphertext": .string(b64(sealed.ciphertext + sealed.tag)),
        ]) { _, replacement in replacement }
        let signature = try context.receiverSigningPrivateKey.signature(
            for: signaturePreimage(ackSignature, unsigned)
        )
        let final = unsigned.merging(["signature": .string(b64(signature))]) { _, replacement in replacement }
        let encoded = try encodeMetadata(.object(final))
        guard encoded.count <= maxAckBytes else { throw DeliveryProtocolV1Error.authenticationFailed }
        return encoded
    }

    public static func openAck(
        _ encoded: Data,
        context: DeliveryAckOpenContext
    ) throws -> DeliveryReceiptV1 {
        do {
            let fields = try object(encoded, fields: ackFields, limit: maxAckBytes)
            let ackIDValue = try requireID(string(fields, "ack_id"))
            let envelopeID = try requireID(string(fields, "envelope_id"))
            let receiverID = try requireID(string(fields, "receiver_id"))
            let deviceID = try requireID(string(fields, "device_id"))
            let generation = try integer(fields, "connection_generation")
            let receiverSigningPublic = context.receiverSigningPublicKey.rawRepresentation
            let devicePublic = context.deviceAgreementPrivateKey.publicKey.rawRepresentation
            guard try integer(fields, "v") == 1,
                  try string(fields, "kind") == "ack",
                  envelopeID == context.envelopeID,
                  receiverID == context.receiverID,
                  deviceID == context.deviceID,
                  generation == context.connectionGeneration,
                  generation >= 0,
                  try string(fields, "device_agreement_key_id") == keyID(algorithm: "x25519", publicKey: devicePublic),
                  try string(fields, "receiver_signing_key_id") == keyID(algorithm: "ed25519", publicKey: receiverSigningPublic) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            let signature = try unb64(string(fields, "signature"), length: 64)
            var unsigned = fields
            unsigned.removeValue(forKey: "signature")
            guard context.receiverSigningPublicKey.isValidSignature(
                signature,
                for: try signaturePreimage(ackSignature, unsigned)
            ) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            let secret = try context.deviceAgreementPrivateKey.sharedSecretFromKeyAgreement(
                with: context.receiverAgreementPublicKey
            )
            let saltValue = salt(ackSalt, receiverID: receiverID, deviceID: deviceID)
            let key = hkdf(secret, salt: saltValue, info: ackKey + nul + ackIDValue, count: 32)
            let nonce = hkdf(secret, salt: saltValue, info: ackNonce + nul + ackIDValue, count: 12)
            guard try unb64(string(fields, "nonce"), length: 12) == nonce else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            let combined = try unb64(string(fields, "ciphertext"))
            guard combined.count >= 16 else { throw DeliveryProtocolV1Error.authenticationFailed }
            let aadNames = ackFields.subtracting(["nonce", "ciphertext", "signature"])
            let aad = fields.filter { aadNames.contains($0.key) }
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: combined.dropLast(16),
                tag: combined.suffix(16)
            )
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: key),
                authenticating: ackAAD + nul + (try encodeMetadata(.object(aad)))
            )
            let receipt = try decodeReceipt(plaintext)
            let recomputed = Data(SHA256.hash(data: ackID + nul + envelopeID + plaintext)).prefixDataV1(16)
            guard recomputed == ackIDValue else { throw DeliveryProtocolV1Error.authenticationFailed }
            return receipt
        } catch let error as DeliveryProtocolV1Error {
            throw error
        } catch {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
    }

    private static func validateReceipt(_ receipt: DeliveryReceiptV1) throws {
        guard isLowercaseHex(receipt.payloadSHA256, count: 64) else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        let values = [receipt.receiptID, receipt.datasetGeneration, receipt.committedAtMS]
        switch receipt.result {
        case .committed:
            guard receipt.errorCode == nil,
                  values.allSatisfy({ value in value.map { $0 >= 0 } == true }) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
        case .retryable:
            guard values.allSatisfy({ $0 == nil }),
                  [.receiverBusy, .storageUnavailable, .quotaExceeded, .internalRetry].contains(receipt.errorCode) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
        case .terminal:
            guard values.allSatisfy({ $0 == nil }), receipt.errorCode != nil,
                  ![.receiverBusy, .storageUnavailable, .quotaExceeded, .internalRetry].contains(receipt.errorCode) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
        }
    }

    private static func decodeReceipt(_ plaintext: Data) throws -> DeliveryReceiptV1 {
        let fields = try object(plaintext, fields: receiptFields, limit: maxAckBytes)
        guard let result = DeliveryReceiptV1.Result(rawValue: try string(fields, "result")) else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        let receipt = DeliveryReceiptV1(
            result: result,
            payloadSHA256: try string(fields, "payload_sha256"),
            receiptID: try optionalInteger(fields["receipt_id"]),
            datasetGeneration: try optionalInteger(fields["dataset_generation"]),
            committedAtMS: try optionalInteger(fields["committed_at_ms"]),
            errorCode: try optionalError(fields["error_code"])
        )
        try validateReceipt(receipt)
        return receipt
    }

    private static func optionalInteger(_ value: HBJCS1Value?) throws -> Int64? {
        if case .null = value { return nil }
        guard case let .integer(integer) = value else { throw DeliveryProtocolV1Error.authenticationFailed }
        return integer
    }

    private static func optionalError(_ value: HBJCS1Value?) throws -> DeliveryReceiptV1.ErrorCode? {
        if case .null = value { return nil }
        guard case let .string(string) = value, let code = DeliveryReceiptV1.ErrorCode(rawValue: string) else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return code
    }
}

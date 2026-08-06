import CryptoKit
import Foundation

extension DeliveryProtocolV1 {
    static let envelopeFields: Set<String> = [
        "v", "kind", "envelope_id", "receiver_id", "device_id", "connection_generation",
        "receiver_agreement_key_id", "sender_signing_key_id", "ephemeral_public_key", "nonce",
        "created_at_ms", "payload_sha256", "content_type", "ciphertext", "signature",
    ]

    public static func sealDelivery(
        _ plaintext: Data,
        context: DeliveryEnvelopeSealContext
    ) throws -> Data {
        try sealDeliveryForVector(
            plaintext,
            context: context,
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
            nonce: AES.GCM.Nonce().dataV1
        )
    }

    static func sealDeliveryForVector(
        _ plaintext: Data,
        context: DeliveryEnvelopeSealContext,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        nonce: Data
    ) throws -> Data {
        try sealDeliveryUsingSigner(
            plaintext,
            envelopeID: context.envelopeID,
            receiverID: context.receiverID,
            deviceID: context.deviceID,
            connectionGeneration: context.connectionGeneration,
            createdAtMS: context.createdAtMS,
            receiverAgreementPublicKey: context.receiverAgreementPublicKey,
            senderSigningPublicKey: context.senderSigningPrivateKey.publicKey,
            ephemeralPrivateKey: ephemeralPrivateKey,
            nonce: nonce,
            signer: { try context.senderSigningPrivateKey.signature(for: $0) }
        )
    }

    public static func openDelivery(
        _ encoded: Data,
        context: DeliveryEnvelopeOpenContext
    ) throws -> OpenedDeliveryV1 {
        do {
            let fields = try object(encoded, fields: envelopeFields, limit: maxEnvelopeBytes)
            let receiverID = try requireID(string(fields, "receiver_id"))
            let deviceID = try requireID(string(fields, "device_id"))
            let envelopeID = try requireID(string(fields, "envelope_id"))
            let generation = try integer(fields, "connection_generation")
            let receiverPublic = context.receiverAgreementPrivateKey.publicKey.rawRepresentation
            let senderPublic = context.senderSigningPublicKey.rawRepresentation
            guard try integer(fields, "v") == 1,
                  try string(fields, "kind") == "delivery",
                  try string(fields, "content_type") == contentType,
                  receiverID == context.receiverID,
                  deviceID == context.deviceID,
                  generation == context.connectionGeneration,
                  generation >= 0,
                  try string(fields, "receiver_agreement_key_id") == keyID(algorithm: "x25519", publicKey: receiverPublic),
                  try string(fields, "sender_signing_key_id") == keyID(algorithm: "ed25519", publicKey: senderPublic) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            _ = try integer(fields, "created_at_ms")
            let expectedDigest = try string(fields, "payload_sha256")
            guard isLowercaseHex(expectedDigest, count: 64) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            let signature = try unb64(string(fields, "signature"), length: 64)
            var unsigned = fields
            unsigned.removeValue(forKey: "signature")
            guard context.senderSigningPublicKey.isValidSignature(
                signature,
                for: try signaturePreimage(deliverySignature, unsigned)
            ) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            let ephemeral = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: unb64(string(fields, "ephemeral_public_key"), length: 32)
            )
            let nonce = try unb64(string(fields, "nonce"), length: 12)
            let combined = try unb64(string(fields, "ciphertext"))
            guard combined.count >= 16 else { throw DeliveryProtocolV1Error.authenticationFailed }
            let secret = try context.receiverAgreementPrivateKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let key = hkdf(
                secret,
                salt: salt(deliverySalt, receiverID: receiverID, deviceID: deviceID),
                info: deliveryKey + nul + envelopeID,
                count: 32
            )
            let aadNames = envelopeFields.subtracting(["ciphertext", "signature"])
            let aadFields = fields.filter { aadNames.contains($0.key) }
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: combined.dropLast(16),
                tag: combined.suffix(16)
            )
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: key),
                authenticating: deliveryAAD + nul + (try encodeMetadata(.object(aadFields)))
            )
            guard Data(SHA256.hash(data: plaintext)).hexV1 == expectedDigest else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            try validatePayload(plaintext)
            return OpenedDeliveryV1(plaintext: plaintext, payloadSHA256: expectedDigest)
        } catch let error as DeliveryProtocolV1Error {
            throw error
        } catch {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
    }

}

private extension AES.GCM.Nonce {
    var dataV1: Data { withUnsafeBytes { Data($0) } }
}

import CryptoKit
import Foundation

extension DeliveryProtocolV1 {
    static func sealDeliveryUsingSigner(
        _ plaintext: Data,
        envelopeID: Data,
        receiverID: Data,
        deviceID: Data,
        connectionGeneration: Int64,
        createdAtMS: Int64,
        receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey,
        senderSigningPublicKey: Curve25519.Signing.PublicKey,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        nonce: Data,
        signer: (Data) throws -> Data
    ) throws -> Data {
        guard plaintext.count <= maxPayloadBytes,
              [envelopeID, receiverID, deviceID].allSatisfy({ $0.count == 16 }),
              connectionGeneration >= 0,
              nonce.count == 12 else {
            throw plaintext.count > maxPayloadBytes
                ? DeliveryProtocolV1Error.payloadOversize
                : DeliveryProtocolV1Error.authenticationFailed
        }
        let receiverPublic = receiverAgreementPublicKey.rawRepresentation
        let senderPublic = senderSigningPublicKey.rawRepresentation
        let base: [String: HBJCS1Value] = [
            "v": .integer(1),
            "kind": .string("delivery"),
            "envelope_id": .string(envelopeID.hexV1),
            "receiver_id": .string(receiverID.hexV1),
            "device_id": .string(deviceID.hexV1),
            "connection_generation": .integer(connectionGeneration),
            "receiver_agreement_key_id": .string(
                try keyID(algorithm: "x25519", publicKey: receiverPublic)
            ),
            "sender_signing_key_id": .string(
                try keyID(algorithm: "ed25519", publicKey: senderPublic)
            ),
            "ephemeral_public_key": .string(
                b64(ephemeralPrivateKey.publicKey.rawRepresentation)
            ),
            "nonce": .string(b64(nonce)),
            "created_at_ms": .integer(createdAtMS),
            "payload_sha256": .string(Data(SHA256.hash(data: plaintext)).hexV1),
            "content_type": .string(contentType),
        ]
        let secret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(
            with: receiverAgreementPublicKey
        )
        let keyData = hkdf(
            secret,
            salt: salt(deliverySalt, receiverID: receiverID, deviceID: deviceID),
            info: deliveryKey + nul + envelopeID,
            count: 32
        )
        let aad = deliveryAAD + nul + (try encodeMetadata(.object(base)))
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: aad
        )
        let unsigned = base.merging([
            "ciphertext": .string(b64(sealed.ciphertext + sealed.tag)),
        ]) { _, replacement in replacement }
        let signature = try signer(signaturePreimage(deliverySignature, unsigned))
        guard signature.count == 64 else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        let final = unsigned.merging([
            "signature": .string(b64(signature)),
        ]) { _, replacement in replacement }
        let encoded = try encodeMetadata(.object(final))
        guard encoded.count <= maxEnvelopeBytes else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return encoded
    }

    public static func inspectDelivery(
        _ encoded: Data,
        senderSigningPublicKey: Curve25519.Signing.PublicKey
    ) throws -> DeliveryEnvelopeClaimsV1 {
        do {
            let fields = try object(
                encoded,
                fields: envelopeFields,
                limit: maxEnvelopeBytes
            )
            let envelopeID = try requireID(string(fields, "envelope_id"))
            let receiverID = try requireID(string(fields, "receiver_id"))
            let deviceID = try requireID(string(fields, "device_id"))
            let generation = try integer(fields, "connection_generation")
            let receiverKeyID = try string(fields, "receiver_agreement_key_id")
            let senderKeyID = try string(fields, "sender_signing_key_id")
            let payloadSHA256 = try string(fields, "payload_sha256")
            guard try integer(fields, "v") == 1,
                  try string(fields, "kind") == "delivery",
                  try string(fields, "content_type") == contentType,
                  generation >= 0,
                  isLowercaseHex(receiverKeyID, count: 32),
                  isLowercaseHex(senderKeyID, count: 32),
                  isLowercaseHex(payloadSHA256, count: 64),
                  try unb64(string(fields, "ephemeral_public_key"), length: 32).count == 32,
                  try unb64(string(fields, "nonce"), length: 12).count == 12,
                  try unb64(string(fields, "ciphertext")).count >= 16
            else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            _ = try integer(fields, "created_at_ms")
            let expectedSenderKeyID = try keyID(
                algorithm: "ed25519",
                publicKey: senderSigningPublicKey.rawRepresentation
            )
            let signature = try unb64(string(fields, "signature"), length: 64)
            var unsigned = fields
            unsigned.removeValue(forKey: "signature")
            guard senderKeyID == expectedSenderKeyID,
                  senderSigningPublicKey.isValidSignature(
                      signature,
                      for: try signaturePreimage(deliverySignature, unsigned)
                  )
            else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            return DeliveryEnvelopeClaimsV1(
                envelopeID: envelopeID,
                receiverID: receiverID,
                deviceID: deviceID,
                connectionGeneration: generation,
                receiverAgreementKeyID: receiverKeyID,
                senderSigningKeyID: senderKeyID,
                payloadSHA256: payloadSHA256
            )
        } catch let error as DeliveryProtocolV1Error {
            throw error
        } catch {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
    }
}

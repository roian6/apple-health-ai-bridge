import CryptoKit
import Foundation

public struct DeliveryAckAuthenticationContext: Sendable {
    public let receiverID: Data
    public let deviceID: Data
    public let connectionGeneration: Int64
    public let deviceAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public let receiverSigningPublicKey: Curve25519.Signing.PublicKey
    public let receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey

    public init(
        receiverID: Data,
        deviceID: Data,
        connectionGeneration: Int64,
        deviceAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        receiverSigningPublicKey: Curve25519.Signing.PublicKey,
        receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey
    ) {
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.connectionGeneration = connectionGeneration
        self.deviceAgreementPrivateKey = deviceAgreementPrivateKey
        self.receiverSigningPublicKey = receiverSigningPublicKey
        self.receiverAgreementPublicKey = receiverAgreementPublicKey
    }
}

public struct AuthenticatedDeliveryAckV1: Equatable, Sendable {
    public let ackID: Data
    public let envelopeID: Data
    public let receiverID: Data
    public let deviceID: Data
    public let connectionGeneration: Int64
    public let deviceAgreementKeyID: String
    public let receiverSigningKeyID: String
    public let receipt: DeliveryReceiptV1
}

extension DeliveryProtocolV1 {
    public static func authenticateAck(
        _ encoded: Data,
        context: DeliveryAckAuthenticationContext
    ) throws -> AuthenticatedDeliveryAckV1 {
        do {
            guard case let .object(fields) = try decodeMetadata(encoded) else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            let envelopeID = try requireID(string(fields, "envelope_id"))
            let receipt = try openAck(
                encoded,
                context: DeliveryAckOpenContext(
                    envelopeID: envelopeID,
                    receiverID: context.receiverID,
                    deviceID: context.deviceID,
                    connectionGeneration: context.connectionGeneration,
                    deviceAgreementPrivateKey: context.deviceAgreementPrivateKey,
                    receiverSigningPublicKey: context.receiverSigningPublicKey,
                    receiverAgreementPublicKey: context.receiverAgreementPublicKey
                )
            )
            return AuthenticatedDeliveryAckV1(
                ackID: try requireID(string(fields, "ack_id")),
                envelopeID: envelopeID,
                receiverID: try requireID(string(fields, "receiver_id")),
                deviceID: try requireID(string(fields, "device_id")),
                connectionGeneration: try integer(fields, "connection_generation"),
                deviceAgreementKeyID: try string(fields, "device_agreement_key_id"),
                receiverSigningKeyID: try string(fields, "receiver_signing_key_id"),
                receipt: receipt
            )
        } catch let error as DeliveryProtocolV1Error {
            throw error
        } catch {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
    }
}

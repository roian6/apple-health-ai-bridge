import CryptoKit
import Foundation

public struct DeliveryEnvelopeSealContext: Sendable {
    public let envelopeID: Data
    public let receiverID: Data
    public let deviceID: Data
    public let connectionGeneration: Int64
    public let createdAtMS: Int64
    public let receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey
    public let senderSigningPrivateKey: Curve25519.Signing.PrivateKey

    public init(
        envelopeID: Data,
        receiverID: Data,
        deviceID: Data,
        connectionGeneration: Int64,
        createdAtMS: Int64,
        receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey,
        senderSigningPrivateKey: Curve25519.Signing.PrivateKey
    ) {
        self.envelopeID = envelopeID
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.connectionGeneration = connectionGeneration
        self.createdAtMS = createdAtMS
        self.receiverAgreementPublicKey = receiverAgreementPublicKey
        self.senderSigningPrivateKey = senderSigningPrivateKey
    }
}

public struct DeliveryEnvelopeOpenContext: Sendable {
    public let receiverID: Data
    public let deviceID: Data
    public let connectionGeneration: Int64
    public let receiverAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public let senderSigningPublicKey: Curve25519.Signing.PublicKey

    public init(
        receiverID: Data,
        deviceID: Data,
        connectionGeneration: Int64,
        receiverAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        senderSigningPublicKey: Curve25519.Signing.PublicKey
    ) {
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.connectionGeneration = connectionGeneration
        self.receiverAgreementPrivateKey = receiverAgreementPrivateKey
        self.senderSigningPublicKey = senderSigningPublicKey
    }
}

public struct DeliveryAckSealContext: Sendable {
    public let envelopeID: Data
    public let receiverID: Data
    public let deviceID: Data
    public let connectionGeneration: Int64
    public let deviceAgreementPublicKey: Curve25519.KeyAgreement.PublicKey
    public let receiverSigningPrivateKey: Curve25519.Signing.PrivateKey
    public let receiverAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey

    public init(
        envelopeID: Data,
        receiverID: Data,
        deviceID: Data,
        connectionGeneration: Int64,
        deviceAgreementPublicKey: Curve25519.KeyAgreement.PublicKey,
        receiverSigningPrivateKey: Curve25519.Signing.PrivateKey,
        receiverAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        self.envelopeID = envelopeID
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.connectionGeneration = connectionGeneration
        self.deviceAgreementPublicKey = deviceAgreementPublicKey
        self.receiverSigningPrivateKey = receiverSigningPrivateKey
        self.receiverAgreementPrivateKey = receiverAgreementPrivateKey
    }
}

public struct DeliveryAckOpenContext: Sendable {
    public let envelopeID: Data
    public let receiverID: Data
    public let deviceID: Data
    public let connectionGeneration: Int64
    public let deviceAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public let receiverSigningPublicKey: Curve25519.Signing.PublicKey
    public let receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey

    public init(
        envelopeID: Data,
        receiverID: Data,
        deviceID: Data,
        connectionGeneration: Int64,
        deviceAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        receiverSigningPublicKey: Curve25519.Signing.PublicKey,
        receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey
    ) {
        self.envelopeID = envelopeID
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.connectionGeneration = connectionGeneration
        self.deviceAgreementPrivateKey = deviceAgreementPrivateKey
        self.receiverSigningPublicKey = receiverSigningPublicKey
        self.receiverAgreementPublicKey = receiverAgreementPublicKey
    }
}

public struct OpenedDeliveryV1: Equatable, Sendable {
    public let plaintext: Data
    public let payloadSHA256: String
}

public struct DeliveryEnvelopeClaimsV1: Equatable, Sendable {
    public let envelopeID: Data
    public let receiverID: Data
    public let deviceID: Data
    public let connectionGeneration: Int64
    public let receiverAgreementKeyID: String
    public let senderSigningKeyID: String
    public let payloadSHA256: String
}

public struct DeliveryReceiptV1: Equatable, Sendable {
    public enum Result: String, Sendable { case committed, retryable, terminal }
    public enum ErrorCode: String, Sendable {
        case receiverBusy = "receiver_busy"
        case storageUnavailable = "storage_unavailable"
        case quotaExceeded = "quota_exceeded"
        case internalRetry = "internal_retry"
        case payloadInvalid = "payload_invalid"
        case payloadOversize = "payload_oversize"
        case duplicateConflict = "duplicate_conflict"
        case principalMismatch = "principal_mismatch"
        case bindingMismatch = "binding_mismatch"
        case generationMismatch = "generation_mismatch"
        case keyRevoked = "key_revoked"
    }

    public let result: Result
    public let payloadSHA256: String
    public let receiptID: Int64?
    public let datasetGeneration: Int64?
    public let committedAtMS: Int64?
    public let errorCode: ErrorCode?

    public init(
        result: Result,
        payloadSHA256: String,
        receiptID: Int64?,
        datasetGeneration: Int64?,
        committedAtMS: Int64?,
        errorCode: ErrorCode?
    ) {
        self.result = result
        self.payloadSHA256 = payloadSHA256
        self.receiptID = receiptID
        self.datasetGeneration = datasetGeneration
        self.committedAtMS = committedAtMS
        self.errorCode = errorCode
    }

    public var encodedMetadata: Data { DeliveryProtocolV1.encodeReceipt(self) }
}

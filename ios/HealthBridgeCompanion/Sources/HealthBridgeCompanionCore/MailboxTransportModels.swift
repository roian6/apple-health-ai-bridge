import CryptoKit
import Foundation

public struct MailboxTransportContext: Sendable {
    public let receiverID: Data
    public let deviceID: Data
    public let receiverBindingID: String
    public let connectionGeneration: Int64
    public let receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey
    public let receiverAgreementKeyID: String
    public let deviceSigningPublicKey: Curve25519.Signing.PublicKey
    public let deviceSigningKeyID: String

    public init(
        receiverID: Data,
        deviceID: Data,
        receiverBindingID: String,
        connectionGeneration: Int64,
        receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey,
        receiverAgreementKeyID: String,
        deviceSigningPublicKey: Curve25519.Signing.PublicKey,
        deviceSigningKeyID: String
    ) {
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.receiverBindingID = receiverBindingID
        self.connectionGeneration = connectionGeneration
        self.receiverAgreementPublicKey = receiverAgreementPublicKey
        self.receiverAgreementKeyID = receiverAgreementKeyID
        self.deviceSigningPublicKey = deviceSigningPublicKey
        self.deviceSigningKeyID = deviceSigningKeyID
    }
}

public enum MailboxTransportError: Error, Equatable, Sendable {
    case itemUnavailable
    case bindingMismatch
    case envelopeConflict
    case destinationConflict
    case unsafeDestination
}

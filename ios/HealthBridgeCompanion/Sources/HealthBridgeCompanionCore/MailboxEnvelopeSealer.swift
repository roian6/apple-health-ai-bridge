import CryptoKit
import Foundation

public protocol MailboxEnvelopeSealing {
    func seal(
        _ plaintext: Data,
        envelopeID: Data,
        context: MailboxTransportContext,
        createdAtMS: Int64
    ) throws -> Data
}

public protocol MailboxSigningIdentityProviding {
    func loadOrCreate() throws -> MailboxPublicIdentity
    func sign(_ message: Data) throws -> Data
}

public struct DeliveryProtocolMailboxEnvelopeSealer: MailboxEnvelopeSealing {
    private let identityProvider: any MailboxSigningIdentityProviding

    #if !HEALTH_BRIDGE_MAILBOX_QA
    public init(keyStore: MailboxKeyStore) {
        identityProvider = keyStore
    }
    #endif

    public init(identityProvider: any MailboxSigningIdentityProviding) {
        self.identityProvider = identityProvider
    }

    public func seal(
        _ plaintext: Data,
        envelopeID: Data,
        context: MailboxTransportContext,
        createdAtMS: Int64
    ) throws -> Data {
        let identity = try identityProvider.loadOrCreate()
        guard identity.signingPublicKey == context.deviceSigningPublicKey.rawRepresentation,
              identity.signingKeyID == context.deviceSigningKeyID else {
            throw MailboxTransportError.bindingMismatch
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = AES.GCM.Nonce()
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        return try DeliveryProtocolV1.sealDeliveryUsingSigner(
            plaintext,
            envelopeID: envelopeID,
            receiverID: context.receiverID,
            deviceID: context.deviceID,
            connectionGeneration: context.connectionGeneration,
            createdAtMS: createdAtMS,
            receiverAgreementPublicKey: context.receiverAgreementPublicKey,
            senderSigningPublicKey: context.deviceSigningPublicKey,
            ephemeralPrivateKey: ephemeral,
            nonce: nonceData,
            signer: { try identityProvider.sign($0) }
        )
    }
}

import CryptoKit
import Foundation

struct ProductionMailboxComponents {
    let identity: MailboxConnectionIdentityV1
    let deviceSigningPublicKey: Curve25519.Signing.PublicKey
    let ackContext: MailboxAckContext
    let transport: MailboxTransport
    let scanner: MailboxAckScanner
    let locate: () throws -> MailboxResolvedLocatorV1

    static func make(
        settingsStore: ReceiverSettingsStore,
        outbox: FileOutbox,
        keyStore: MailboxKeyStore
    ) throws -> Self {
        guard let record = try settingsStore.currentConnectionRecordV2(),
              record.activation == .paired(activeTransport: .mailbox),
              case .available(let identity) = record.mailboxIdentity,
              let receiverID = Data(hexV1: identity.receiverID),
              receiverID.count == 16,
              let deviceID = Data(hexV1: identity.deviceID),
              deviceID.count == 16,
              identity.connectionGeneration <= UInt64(Int64.max),
              let receiverSigningData = Data(
                  strictBase64URL: identity.receiverSigningPublicKey,
                  count: 32
              ),
              let receiverAgreementData = Data(
                  strictBase64URL: identity.receiverAgreementPublicKey,
                  count: 32
              ) else {
            throw ProductionMailboxDeliveryError.inactive
        }
        let deviceIdentity = try keyStore.loadOrCreate()
        guard deviceIdentity.signingKeyID == identity.deviceSigningKeyID,
              deviceIdentity.agreementKeyID == identity.deviceAgreementKeyID else {
            throw ProductionMailboxDeliveryError.invalidIdentity
        }
        let deviceSigning = try Curve25519.Signing.PublicKey(
            rawRepresentation: deviceIdentity.signingPublicKey
        )
        let receiverSigning = try Curve25519.Signing.PublicKey(
            rawRepresentation: receiverSigningData
        )
        let receiverAgreement = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: receiverAgreementData
        )
        let ackContext = MailboxAckContext(
            receiverID: receiverID,
            deviceID: deviceID,
            receiverBindingID: identity.opaqueBinding,
            connectionGeneration: Int64(identity.connectionGeneration),
            deviceAgreementPrivateKey: try keyStore.agreementPrivateKey(),
            deviceAgreementKeyID: identity.deviceAgreementKeyID,
            receiverSigningPublicKey: receiverSigning,
            receiverSigningKeyID: identity.receiverSigningKeyID,
            receiverAgreementPublicKey: receiverAgreement,
            receiverAgreementKeyID: identity.receiverAgreementKeyID,
            deviceSigningPublicKey: deviceSigning,
            deviceSigningKeyID: identity.deviceSigningKeyID
        )
        let locate = {
            try MailboxLocatorV1.resolve(
                receiverComponent: identity.receiverID,
                deviceComponent: identity.deviceID
            )
        }
        let transport = MailboxTransport(
            outbox: outbox,
            context: MailboxTransportContext(
                receiverID: receiverID,
                deviceID: deviceID,
                receiverBindingID: identity.opaqueBinding,
                connectionGeneration: Int64(identity.connectionGeneration),
                receiverAgreementPublicKey: receiverAgreement,
                receiverAgreementKeyID: identity.receiverAgreementKeyID,
                deviceSigningPublicKey: deviceSigning,
                deviceSigningKeyID: identity.deviceSigningKeyID
            ),
            sealer: DeliveryProtocolMailboxEnvelopeSealer(keyStore: keyStore),
            locate: locate,
            publisher: FileProviderMailboxEnvelopePublisher(),
            envelopeID: { Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) }) },
            nowMilliseconds: { Int64(Date().timeIntervalSince1970 * 1_000) },
            isCancelled: {
                withUnsafeCurrentTask { task in task?.isCancelled ?? false }
            },
            observe: ProductionMailboxProviderObserver.observe
        )
        let scanner = MailboxAckScanner(
            context: ackContext,
            lookup: FileOutboxMailboxAckLookup(
                outbox: outbox,
                deviceSigningPublicKey: deviceSigning
            ),
            locate: locate,
            transientUnsafeRetryLimit: 1
        )
        return Self(
            identity: identity,
            deviceSigningPublicKey: deviceSigning,
            ackContext: ackContext,
            transport: transport,
            scanner: scanner,
            locate: locate
        )
    }
}

private enum ProductionMailboxProviderObserver {
    static func observe(_ url: URL, digest: String) throws -> Bool {
        let bytes = try MailboxRegularFileReader.read(
            url,
            maximumBytes: MailboxLayoutV1.maximumDeliveryBytes
        )
        let observed = SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
        let values = try url.resourceValues(
            forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemUploadingErrorKey,
            ]
        )
        return observed == digest
            && values.isUbiquitousItem == true
            && values.ubiquitousItemIsUploaded == true
            && values.ubiquitousItemUploadingError == nil
    }
}

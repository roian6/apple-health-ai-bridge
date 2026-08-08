import CryptoKit
import Foundation

extension MailboxQAHarness {
    func coordinator(
        fault: MailboxQAFault?
    ) throws -> OutboxDeliveryCoordinator {
        let transport = MailboxTransport(
            outbox: outbox,
            context: try transportContext(),
            sealer: DeliveryProtocolMailboxEnvelopeSealer(
                identityProvider: signer
            ),
            locate: { self.locator },
            publisher: MailboxQAPublisherFactory.publisher(fault: fault),
            envelopeID: envelopeID,
            nowMilliseconds: { Int64(Date().timeIntervalSince1970 * 1_000) },
            isCancelled: { false },
            observe: observeEnvelope
        )
        return OutboxDeliveryCoordinator(
            outbox: outbox,
            transport: transport,
            scanner: try scanner(),
            ownership: try ownership(),
            finalizer: MailboxQADurableFinalizer(
                applicationSupportRoot: applicationSupportRoot
            )
        )
    }

    func scanner() throws -> MailboxAckScanner {
        let signing = try pairing.signingPrivateKey
        let agreement = try pairing.agreementPrivateKey
        return try MailboxAckScanner(
            context: MailboxAckContext(
                receiverID: pairing.receiverID,
                deviceID: pairing.deviceID,
                receiverBindingID: pairing.receiverBindingID,
                connectionGeneration: pairing.connectionGeneration,
                deviceAgreementPrivateKey: agreement,
                deviceAgreementKeyID: DeliveryProtocolV1.keyID(
                    algorithm: "x25519",
                    publicKey: agreement.publicKey.rawRepresentation
                ),
                receiverSigningPublicKey: Curve25519.Signing.PublicKey(
                    rawRepresentation: pairing.receiverSigningPublicKey
                ),
                receiverSigningKeyID: pairing.receiverSigningKeyID,
                receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey(
                    rawRepresentation: pairing.receiverAgreementPublicKey
                ),
                receiverAgreementKeyID: pairing.receiverAgreementKeyID,
                deviceSigningPublicKey: signing.publicKey,
                deviceSigningKeyID: DeliveryProtocolV1.keyID(
                    algorithm: "ed25519",
                    publicKey: signing.publicKey.rawRepresentation
                )
            ),
            lookup: FileOutboxMailboxAckLookup(
                outbox: outbox,
                deviceSigningPublicKey: signing.publicKey
            ),
            locate: { self.locator },
            transientUnsafeRetryLimit: 1
        )
    }

    func transportContext() throws -> MailboxTransportContext {
        let signing = try pairing.signingPrivateKey
        return try MailboxTransportContext(
            receiverID: pairing.receiverID,
            deviceID: pairing.deviceID,
            receiverBindingID: pairing.receiverBindingID,
            connectionGeneration: pairing.connectionGeneration,
            receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: pairing.receiverAgreementPublicKey
            ),
            receiverAgreementKeyID: pairing.receiverAgreementKeyID,
            deviceSigningPublicKey: signing.publicKey,
            deviceSigningKeyID: DeliveryProtocolV1.keyID(
                algorithm: "ed25519",
                publicKey: signing.publicKey.rawRepresentation
            )
        )
    }

    func ownership() throws -> OutboxDeliveryOwnershipV1 {
        OutboxDeliveryOwnershipV1(
            receiverGeneration: String(pairing.connectionGeneration),
            resetEpoch: nil,
            ackContext: try scanner().context
        )
    }
}

enum MailboxQAPublisherFactory {
    static func publisher(
        fault: MailboxQAFault?
    ) -> any MailboxEnvelopePublishing {
        if fault != nil {
            return MailboxQAFaultPublisher()
        }
        #if os(iOS)
        return FileProviderMailboxEnvelopePublisher()
        #else
        return POSIXMailboxEnvelopePublisher()
        #endif
    }
}

struct MailboxQAFaultPublisher: MailboxEnvelopePublishing {
    func publish(
        _: Data,
        finalName _: String,
        locator _: MailboxResolvedLocatorV1
    ) throws -> URL {
        throw MailboxPublicationError.retryable
    }
}

enum MailboxQAProviderObserver {
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

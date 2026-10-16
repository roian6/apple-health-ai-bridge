import CryptoKit
import Foundation

public struct MailboxProviderLocation: Sendable {
    public let providerRoot: URL
    public let localRecordURL: URL

    public init(providerRoot: URL, localRecordURL: URL) {
        self.providerRoot = providerRoot
        self.localRecordURL = localRecordURL
    }
}

struct ProductionMailboxComponents {
    let identity: MailboxConnectionIdentityV1
    let receiverGeneration: String
    let deviceSigningPublicKey: Curve25519.Signing.PublicKey
    let ackContext: MailboxAckContext
    let transport: MailboxTransport
    let ackLookup: FileOutboxMailboxAckLookup
    let scanner: MailboxAckScanner
    let locate: () throws -> MailboxResolvedLocatorV1
    let makeHydrator: (URL, [String]?, Int) -> sending MailboxAckHydrator
    let coordinatorFault: OutboxDeliveryCoordinator.Fault

    func acknowledgmentHydrator(
        lane: URL, candidateFileNames: [String]? = nil, maximumWaits: Int = 100
    ) -> sending MailboxAckHydrator {
        makeHydrator(lane, candidateFileNames, maximumWaits)
    }

    static func make(
        settingsStore: ReceiverSettingsStore,
        outbox: FileOutbox,
        keyStore: MailboxKeyStore,
        providerLocation: MailboxProviderLocation? = nil,
        locate fixtureLocator: (() throws -> MailboxResolvedLocatorV1)? = nil,
        publisher fixturePublisher: (any MailboxEnvelopePublishing)? = nil,
        observe: MailboxTransport.Observe? = nil,
        makeHydrator: ((URL, [String]?, Int) -> sending MailboxAckHydrator)? = nil,
        coordinatorFault: @escaping OutboxDeliveryCoordinator.Fault = { _ in }
    ) throws -> Self {
        let receiverGeneration = settingsStore.receiverSettingsGenerationToken
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
        let locate = fixtureLocator ?? { () throws -> MailboxResolvedLocatorV1 in
            if let providerLocation {
                return try MailboxLocatorV1.resolve(
                    providerRoot: providerLocation.providerRoot,
                    containerIdentifier: HealthBridgeAppIdentity.ubiquityContainerIdentifier,
                    receiverComponent: identity.receiverID,
                    deviceComponent: identity.deviceID,
                    localRecordURL: providerLocation.localRecordURL
                )
            }
            return try MailboxLocatorV1.resolve(
                receiverComponent: identity.receiverID,
                deviceComponent: identity.deviceID
            )
        }
        let publisher: any MailboxEnvelopePublishing
        if let fixturePublisher {
            publisher = fixturePublisher
        } else if providerLocation != nil {
            publisher = POSIXMailboxEnvelopePublisher()
        } else {
            publisher = FileProviderMailboxEnvelopePublisher()
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
            publisher: publisher,
            envelopeID: { Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) }) },
            nowMilliseconds: { Int64(Date().timeIntervalSince1970 * 1_000) },
            isCancelled: {
                withUnsafeCurrentTask { task in task?.isCancelled ?? false }
                    || settingsStore.receiverSettingsGenerationToken != receiverGeneration
            },
            observe: observe ?? ProductionMailboxProviderObserver.observe
        )
        let ackLookup = FileOutboxMailboxAckLookup(
            outbox: outbox,
            deviceSigningPublicKey: deviceSigning
        )
        let scanner = MailboxAckScanner(
            context: ackContext,
            lookup: ackLookup,
            locate: locate,
            transientUnsafeRetryLimit: 1
        )
        return Self(
            identity: identity,
            receiverGeneration: receiverGeneration,
            deviceSigningPublicKey: deviceSigning,
            ackContext: ackContext,
            transport: transport,
            ackLookup: ackLookup,
            scanner: scanner,
            locate: locate,
            makeHydrator: makeHydrator ?? { lane, names, waits in
                ProductionMailboxAckHydration.make(lane: lane,
                    candidateFileNames: names, maximumWaits: waits)
            },
            coordinatorFault: coordinatorFault
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

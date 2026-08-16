import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxAckScannerFixture {
    let transport: MailboxTransportFixture
    let context: MailboxAckContext
    let lookup: FileOutboxMailboxAckLookup
    let ackLane: URL

    init(receiverBindingID: String = MailboxTransportFixture.bindingID) throws {
        transport = try MailboxTransportFixture()
        let envelope = try DeliveryProtocolV1TestSupport.data(
            DeliveryProtocolV1TestSupport.fixture("python").envelope
        )
        _ = try transport.outbox.finalizeMailboxEnvelope(
            itemID: transport.item.id,
            envelope: envelope,
            expectedPayloadSHA256: mailboxSHA256(transport.payload)
        )
        let receiverSigning = try DeliveryProtocolV1TestSupport.signingKey(
            "health-bridge/python/receiver-signing"
        )
        let deviceAgreement = try DeliveryProtocolV1TestSupport.agreementKey(
            "health-bridge/python/device-agreement"
        )
        context = MailboxAckContext(
            receiverID: transport.sealContext.receiverID,
            deviceID: transport.sealContext.deviceID,
            receiverBindingID: receiverBindingID,
            connectionGeneration: transport.sealContext.connectionGeneration,
            deviceAgreementPrivateKey: deviceAgreement,
            deviceAgreementKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "x25519",
                publicKey: deviceAgreement.publicKey.rawRepresentation
            ),
            receiverSigningPublicKey: receiverSigning.publicKey,
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "ed25519",
                publicKey: receiverSigning.publicKey.rawRepresentation
            ),
            receiverAgreementPublicKey: transport.sealContext.receiverAgreementPublicKey,
            receiverAgreementKeyID: transport.context.receiverAgreementKeyID,
            deviceSigningPublicKey: transport.context.deviceSigningPublicKey,
            deviceSigningKeyID: transport.context.deviceSigningKeyID
        )
        lookup = FileOutboxMailboxAckLookup(
            outbox: transport.outbox,
            deviceSigningPublicKey: context.deviceSigningPublicKey
        )
        ackLane = try XCTUnwrap(transport.locator.lanes[.acks])
    }

    func scanner(
        lookup selectedLookup: (any MailboxAckOutboxLookingUp)? = nil,
        transientUnsafeRetryLimit: Int = 0,
        fault: @escaping (MailboxAckScanBoundary) throws -> Void = { _ in },
        prepareCandidate: @escaping (URL) -> Bool = { _ in true }
    ) -> MailboxAckScanner {
        MailboxAckScanner(
            context: context,
            lookup: selectedLookup ?? lookup,
            locate: { self.transport.locator },
            fault: fault,
            prepareCandidate: prepareCandidate,
            transientUnsafeRetryLimit: transientUnsafeRetryLimit
        )
    }

    func pythonAck() throws -> Data {
        try DeliveryProtocolV1TestSupport.data(
            DeliveryProtocolV1TestSupport.fixture("python").ack
        )
    }

    func sealAck(
        _ receipt: DeliveryReceiptV1,
        context sealContext: DeliveryAckSealContext? = nil
    ) throws -> Data {
        try DeliveryProtocolV1.sealAck(
            receipt,
            context: sealContext ?? DeliveryProtocolV1TestSupport.ackSeal("python")
        )
    }

    @discardableResult
    func publish(
        _ bytes: Data,
        identifier: String = String(repeating: "a", count: 32)
    ) throws -> URL {
        let name = try MailboxLayoutV1.finalFileName(
            identifier: identifier,
            kind: .acknowledgment
        )
        let url = ackLane.appendingPathComponent(name)
        try bytes.write(to: url, options: [.withoutOverwriting])
        return url
    }

    func snapshotLocalState() throws -> [String: String] {
        let children = try FileManager.default.contentsOfDirectory(
            at: transport.outboxDirectory,
            includingPropertiesForKeys: nil
        )
        return try Dictionary(uniqueKeysWithValues: children.map {
            ($0.lastPathComponent, mailboxSHA256(try Data(contentsOf: $0)))
        })
    }
}

final class SpyMailboxAckLookup: MailboxAckOutboxLookingUp {
    private(set) var callCount = 0
    var result: MailboxAckLookupResult

    init(_ result: MailboxAckLookupResult) {
        self.result = result
    }

    func lookup(envelopeID _: Data) throws -> MailboxAckLookupResult {
        callCount += 1
        return result
    }
}

final class DurableMailboxAckProof: MailboxAckDurableFinalizationVerifying {
    var isDurable: Bool

    init(_ isDurable: Bool) {
        self.isDurable = isDurable
    }

    func isDurablyCommitted(_ event: MailboxAckEvent) throws -> Bool {
        isDurable && event.classification == .committed
    }
}

func committedReceipt(payload: Data) -> DeliveryReceiptV1 {
    DeliveryReceiptV1(
        result: .committed,
        payloadSHA256: mailboxSHA256(payload),
        receiptID: 9,
        datasetGeneration: 4,
        committedAtMS: 1_782_000_000_456,
        errorCode: nil
    )
}

func retryableReceipt(payload: Data) -> DeliveryReceiptV1 {
    DeliveryReceiptV1(
        result: .retryable,
        payloadSHA256: mailboxSHA256(payload),
        receiptID: nil,
        datasetGeneration: nil,
        committedAtMS: nil,
        errorCode: .receiverBusy
    )
}

func terminalReceipt(payload: Data) -> DeliveryReceiptV1 {
    DeliveryReceiptV1(
        result: .terminal,
        payloadSHA256: mailboxSHA256(payload),
        receiptID: nil,
        datasetGeneration: nil,
        committedAtMS: nil,
        errorCode: .payloadInvalid
    )
}

func alternateAckSealContext(
    _ base: DeliveryAckSealContext,
    envelopeID: Data? = nil,
    receiverID: Data? = nil,
    deviceID: Data? = nil,
    connectionGeneration: Int64? = nil,
    deviceAgreementPublicKey: Curve25519.KeyAgreement.PublicKey? = nil,
    receiverSigningPrivateKey: Curve25519.Signing.PrivateKey? = nil
) -> DeliveryAckSealContext {
    DeliveryAckSealContext(
        envelopeID: envelopeID ?? base.envelopeID,
        receiverID: receiverID ?? base.receiverID,
        deviceID: deviceID ?? base.deviceID,
        connectionGeneration: connectionGeneration ?? base.connectionGeneration,
        deviceAgreementPublicKey: deviceAgreementPublicKey
            ?? base.deviceAgreementPublicKey,
        receiverSigningPrivateKey: receiverSigningPrivateKey
            ?? base.receiverSigningPrivateKey,
        receiverAgreementPrivateKey: base.receiverAgreementPrivateKey
    )
}

func installFIFO(at url: URL) throws {
    guard mkfifo(url.path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

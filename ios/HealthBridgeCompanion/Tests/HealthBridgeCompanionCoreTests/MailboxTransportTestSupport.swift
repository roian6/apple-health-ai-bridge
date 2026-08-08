import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxTransportFixture {
    static let bindingID = "synthetic-mailbox-binding-v1"

    let root: URL
    let outboxDirectory: URL
    let providerRoot: URL
    let localRecordURL: URL
    let payload: Data
    let sealContext: DeliveryEnvelopeSealContext
    let openContext: DeliveryEnvelopeOpenContext
    let context: MailboxTransportContext
    let locator: MailboxResolvedLocatorV1
    let outbox: FileOutbox
    let item: FileOutboxItem

    init(alternateJSONSpelling: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailboxTransportTests")
            .appendingPathComponent(UUID().uuidString)
        outboxDirectory = root.appendingPathComponent("outbox")
        providerRoot = root.appendingPathComponent("provider")
        localRecordURL = root.appendingPathComponent("local/mailbox-locator-v1.json")
        try FileManager.default.createDirectory(
            at: providerRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        sealContext = try DeliveryProtocolV1TestSupport.envelopeSeal("python")
        openContext = try DeliveryProtocolV1TestSupport.envelopeOpen("python")
        let receiverKeyID = try DeliveryProtocolV1.keyID(
            algorithm: "x25519",
            publicKey: sealContext.receiverAgreementPublicKey.rawRepresentation
        )
        let senderKeyID = try DeliveryProtocolV1.keyID(
            algorithm: "ed25519",
            publicKey: sealContext.senderSigningPrivateKey.publicKey.rawRepresentation
        )
        context = MailboxTransportContext(
            receiverID: sealContext.receiverID,
            deviceID: sealContext.deviceID,
            receiverBindingID: Self.bindingID,
            connectionGeneration: sealContext.connectionGeneration,
            receiverAgreementPublicKey: sealContext.receiverAgreementPublicKey,
            receiverAgreementKeyID: receiverKeyID,
            deviceSigningPublicKey: sealContext.senderSigningPrivateKey.publicKey,
            deviceSigningKeyID: senderKeyID
        )
        locator = try MailboxLocatorV1.resolve(
            providerRoot: providerRoot,
            containerIdentifier: HealthBridgeAppIdentity.ubiquityContainerIdentifier,
            receiverComponent: sealContext.receiverID.hexV1,
            deviceComponent: sealContext.deviceID.hexV1,
            localRecordURL: localRecordURL
        )
        let fixture = try DeliveryProtocolV1TestSupport.fixture("python")
        let canonical = try DeliveryProtocolV1TestSupport.data(fixture.plaintext)
        if alternateJSONSpelling {
            payload = Data(" \n".utf8) + canonical + Data("\n ".utf8)
        } else {
            payload = canonical
        }
        outbox = try FileOutbox(directory: outboxDirectory)
        item = try outbox.enqueue(payload, receiverIdentity: Self.bindingID)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func transport(
        outbox selectedOutbox: FileOutbox? = nil,
        sealer: any MailboxEnvelopeSealing,
        publisher: any MailboxEnvelopePublishing = POSIXMailboxEnvelopePublisher(),
        locate: (() throws -> MailboxResolvedLocatorV1)? = nil,
        isCancelled: @escaping () -> Bool = { false },
        observe: @escaping (URL, String) throws -> Bool = { _, _ in false }
    ) -> MailboxTransport {
        MailboxTransport(
            outbox: selectedOutbox ?? outbox,
            context: context,
            sealer: sealer,
            locate: locate ?? { self.locator },
            publisher: publisher,
            envelopeID: { self.sealContext.envelopeID },
            nowMilliseconds: { self.sealContext.createdAtMS },
            isCancelled: isCancelled,
            observe: observe
        )
    }

    func deliveries() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: try XCTUnwrap(locator.lanes[.deliveries]),
            includingPropertiesForKeys: nil
        )
    }

    func finalizedEnvelope() throws -> (FileOutboxMailboxBindingV1, Data, URL) {
        let binding = try XCTUnwrap(try outbox.mailboxBinding(for: item.id))
        let url = outboxDirectory.appendingPathComponent(binding.envelopeFilename)
        return (binding, try Data(contentsOf: url), url)
    }
}

final class CountingMailboxEnvelopeSealer: MailboxEnvelopeSealing {
    private let sealContext: DeliveryEnvelopeSealContext
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let nonce: Data

    private(set) var sealCallCount = 0
    private(set) var nonceCallCount = 0
    private(set) var aeadCallCount = 0
    private(set) var signerCallCount = 0

    init(_ fixture: MailboxTransportFixture) throws {
        sealContext = fixture.sealContext
        let entropy = try DeliveryProtocolV1TestSupport.vectorEntropy("python")
        ephemeral = entropy.0
        nonce = entropy.1
    }

    func seal(
        _ plaintext: Data,
        envelopeID: Data,
        context: MailboxTransportContext,
        createdAtMS: Int64
    ) throws -> Data {
        sealCallCount += 1
        nonceCallCount += 1
        aeadCallCount += 1
        signerCallCount += 1
        return try DeliveryProtocolV1.sealDeliveryForVector(
            plaintext,
            context: DeliveryEnvelopeSealContext(
                envelopeID: envelopeID,
                receiverID: context.receiverID,
                deviceID: context.deviceID,
                connectionGeneration: context.connectionGeneration,
                createdAtMS: createdAtMS,
                receiverAgreementPublicKey: sealContext.receiverAgreementPublicKey,
                senderSigningPrivateKey: sealContext.senderSigningPrivateKey
            ),
            ephemeralPrivateKey: ephemeral,
            nonce: nonce
        )
    }
}

final class MailboxEncoderInvocationCounter {
    private(set) var invocationCount = 0

    func encode(_ persistedBytes: Data) -> Data {
        invocationCount += 1
        return persistedBytes
    }
}

final class PersistedPayloadReadCounter {
    private(set) var count = 0

    func read(_ url: URL) throws -> Data {
        count += 1
        return try Data(contentsOf: url)
    }
}

enum MailboxSyntheticFailure: Error {
    case injected
}

struct NeverMailboxEnvelopeSealer: MailboxEnvelopeSealing {
    func seal(
        _: Data,
        envelopeID _: Data,
        context _: MailboxTransportContext,
        createdAtMS _: Int64
    ) throws -> Data {
        XCTFail("A finalized envelope must never be sealed again.")
        throw MailboxSyntheticFailure.injected
    }
}

final class CancellationSequence {
    private let cancellationCall: Int
    private(set) var calls = 0

    init(cancellationCall: Int) {
        self.cancellationCall = cancellationCall
    }

    func check() -> Bool {
        calls += 1
        return calls == cancellationCall
    }
}

func mailboxSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

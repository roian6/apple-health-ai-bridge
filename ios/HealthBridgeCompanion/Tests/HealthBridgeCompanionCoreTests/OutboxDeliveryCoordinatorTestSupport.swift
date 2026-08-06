import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class CountingOutboxDeliveryFinalizer: OutboxDeliveryCommitFinalizing {
    private(set) var finalizeCount = 0
    var finalized = false
    var failure: Error?

    func isFinalized(_: OutboxDeliveryFinalizationContext) throws -> Bool {
        finalized
    }

    func finalize(_: OutboxDeliveryFinalizationContext) throws {
        if let failure { throw failure }
        finalizeCount += 1
        finalized = true
    }
}

final class CountingSyncCursorStore: SyncCursorStoring {
    private var values: [String: String] = [:]
    private(set) var saveCount = 0

    func cursorValue(
        receiverBindingID: String,
        sourceKey: String,
        cursorKind: String
    ) throws -> String? {
        values[key(receiverBindingID, sourceKey, cursorKind)]
    }

    func saveCursorValue(
        _ value: String,
        receiverBindingID: String,
        sourceKey: String,
        cursorKind: String
    ) throws {
        saveCount += 1
        values[key(receiverBindingID, sourceKey, cursorKind)] = value
    }

    private func key(_ receiver: String, _ source: String, _ kind: String) -> String {
        "\(receiver)#\(source)#\(kind)"
    }
}

struct OutboxDeliveryHarness {
    let fixture: MailboxTransportFixture
    let ackContext: MailboxAckContext
    let ownership: OutboxDeliveryOwnershipV1

    init() throws {
        fixture = try MailboxTransportFixture()
        let receiverSigning = try DeliveryProtocolV1TestSupport.signingKey(
            "health-bridge/python/receiver-signing"
        )
        let deviceAgreement = try DeliveryProtocolV1TestSupport.agreementKey(
            "health-bridge/python/device-agreement"
        )
        ackContext = MailboxAckContext(
            receiverID: fixture.context.receiverID,
            deviceID: fixture.context.deviceID,
            receiverBindingID: MailboxTransportFixture.bindingID,
            connectionGeneration: fixture.context.connectionGeneration,
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
            receiverAgreementPublicKey: fixture.context.receiverAgreementPublicKey,
            receiverAgreementKeyID: fixture.context.receiverAgreementKeyID,
            deviceSigningPublicKey: fixture.context.deviceSigningPublicKey,
            deviceSigningKeyID: fixture.context.deviceSigningKeyID
        )
        ownership = OutboxDeliveryOwnershipV1(
            receiverGeneration: "synthetic-receiver-generation",
            resetEpoch: 41,
            ackContext: ackContext
        )
    }

    func coordinator(
        outbox: FileOutbox? = nil,
        sealer: any MailboxEnvelopeSealing,
        publisher: any MailboxEnvelopePublishing = POSIXMailboxEnvelopePublisher(),
        locate: (() throws -> MailboxResolvedLocatorV1)? = nil,
        observed: Bool = false,
        observe: ((URL, String) throws -> Bool)? = nil,
        ownership selectedOwnership: OutboxDeliveryOwnershipV1? = nil,
        finalizer: any OutboxDeliveryCommitFinalizing,
        fault: @escaping OutboxDeliveryCoordinator.Fault = { _ in }
    ) -> OutboxDeliveryCoordinator {
        let selected = outbox ?? fixture.outbox
        let scanner = MailboxAckScanner(
            context: ackContext,
            lookup: FileOutboxMailboxAckLookup(
                outbox: selected,
                deviceSigningPublicKey: ackContext.deviceSigningPublicKey
            ),
            locate: { self.fixture.locator }
        )
        return OutboxDeliveryCoordinator(
            outbox: selected,
            transport: fixture.transport(
                outbox: selected,
                sealer: sealer,
                publisher: publisher,
                locate: locate,
                observe: observe ?? { _, _ in observed }
            ),
            scanner: scanner,
            ownership: selectedOwnership ?? ownership,
            finalizer: finalizer,
            fault: fault
        )
    }

    func publishCommittedAck() throws -> MailboxAckEvent {
        let lane = try XCTUnwrap(fixture.locator.lanes[.acks])
        let bytes = try DeliveryProtocolV1TestSupport.data(
            DeliveryProtocolV1TestSupport.fixture("python").ack
        )
        let name = try MailboxLayoutV1.finalFileName(
            identifier: String(repeating: "a", count: 32),
            kind: .acknowledgment
        )
        try bytes.write(to: lane.appendingPathComponent(name), options: [.withoutOverwriting])
        let scanner = MailboxAckScanner(
            context: ackContext,
            lookup: FileOutboxMailboxAckLookup(
                outbox: fixture.outbox,
                deviceSigningPublicKey: ackContext.deviceSigningPublicKey
            ),
            locate: { self.fixture.locator }
        )
        return try XCTUnwrap(scanner.scan().events.first)
    }

    func restart() throws -> FileOutbox {
        try FileOutbox(directory: fixture.outboxDirectory)
    }

    func alternateOwnership(
        receiverGeneration: String = "synthetic-receiver-generation",
        receiverBindingID: String = MailboxTransportFixture.bindingID,
        resetEpoch: UInt64 = 41
    ) -> OutboxDeliveryOwnershipV1 {
        let context = MailboxAckContext(
            receiverID: ackContext.receiverID,
            deviceID: ackContext.deviceID,
            receiverBindingID: receiverBindingID,
            connectionGeneration: ackContext.connectionGeneration,
            deviceAgreementPrivateKey: ackContext.deviceAgreementPrivateKey,
            deviceAgreementKeyID: ackContext.deviceAgreementKeyID,
            receiverSigningPublicKey: ackContext.receiverSigningPublicKey,
            receiverSigningKeyID: ackContext.receiverSigningKeyID,
            receiverAgreementPublicKey: ackContext.receiverAgreementPublicKey,
            receiverAgreementKeyID: ackContext.receiverAgreementKeyID,
            deviceSigningPublicKey: ackContext.deviceSigningPublicKey,
            deviceSigningKeyID: ackContext.deviceSigningKeyID
        )
        return OutboxDeliveryOwnershipV1(
            receiverGeneration: receiverGeneration,
            resetEpoch: resetEpoch,
            ackContext: context
        )
    }
}

func advanceToProviderObserved(
    _ harness: OutboxDeliveryHarness,
    sealer: any MailboxEnvelopeSealing,
    finalizer: any OutboxDeliveryCommitFinalizing
) throws -> OutboxDeliveryCoordinator {
    var outbox = harness.fixture.outbox
    var coordinator = harness.coordinator(
        outbox: outbox,
        sealer: sealer,
        finalizer: finalizer
    )
    _ = try coordinator.advance(itemID: harness.fixture.item.id)
    outbox = try harness.restart()
    coordinator = harness.coordinator(
        outbox: outbox,
        sealer: sealer,
        finalizer: finalizer
    )
    _ = try coordinator.advance(itemID: harness.fixture.item.id)
    outbox = try harness.restart()
    coordinator = harness.coordinator(
        outbox: outbox,
        sealer: NeverMailboxEnvelopeSealer(),
        finalizer: finalizer
    )
    _ = try coordinator.advance(itemID: harness.fixture.item.id)
    outbox = try harness.restart()
    coordinator = harness.coordinator(
        outbox: outbox,
        sealer: NeverMailboxEnvelopeSealer(),
        observed: true,
        finalizer: finalizer
    )
    _ = try coordinator.advance(itemID: harness.fixture.item.id)
    return coordinator
}

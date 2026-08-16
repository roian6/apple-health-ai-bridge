import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxTransportTests: XCTestCase {
    func testUsesOneExactPersistedReadWithoutEncoderOrJSONReserialization() throws {
        let fixture = try MailboxTransportFixture(alternateJSONSpelling: true)
        let encoder = MailboxEncoderInvocationCounter()
        XCTAssertEqual(encoder.encode(fixture.payload), fixture.payload)
        let reads = PersistedPayloadReadCounter()
        let input = try DeliveryTransportInput(
            item: fixture.item,
            readPersistedBytes: reads.read
        )
        let sealer = try CountingMailboxEnvelopeSealer(fixture)

        let result = try fixture.transport(sealer: sealer).deliver(input)

        let finalized = try fixture.finalizedEnvelope()
        let opened = try DeliveryProtocolV1.openDelivery(
            finalized.1,
            context: fixture.openContext
        )
        let claims = try DeliveryProtocolV1.inspectDelivery(
            finalized.1,
            senderSigningPublicKey: fixture.sealContext.senderSigningPrivateKey.publicKey
        )
        let published = try XCTUnwrap(try fixture.deliveries().first)
        XCTAssertEqual(result, .published)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(encoder.invocationCount, 1)
        XCTAssertEqual(opened.plaintext, fixture.payload)
        XCTAssertEqual(opened.payloadSHA256, mailboxSHA256(fixture.payload))
        XCTAssertEqual(finalized.0.payloadSHA256, mailboxSHA256(fixture.payload))
        XCTAssertEqual(try Data(contentsOf: published), finalized.1)
        XCTAssertEqual(
            published.lastPathComponent,
            try MailboxLayoutV1.finalFileName(
                identifier: claims.envelopeID.hexV1,
                kind: .delivery
            )
        )
        XCTAssertEqual(sealer.sealCallCount, 1)
        XCTAssertEqual(sealer.nonceCallCount, 1)
        XCTAssertEqual(sealer.aeadCallCount, 1)
        XCTAssertEqual(sealer.signerCallCount, 1)
    }

    func testFinalizesAndPublishesOneImmutableEnvelopeAcrossRestartAndRetry() throws {
        let fixture = try MailboxTransportFixture()
        let sealer = try CountingMailboxEnvelopeSealer(fixture)
        let firstInput = try DeliveryTransportInput(item: fixture.item)
        XCTAssertEqual(
            try fixture.transport(sealer: sealer).deliver(firstInput),
            .published
        )
        let first = try fixture.finalizedEnvelope()
        let firstPublication = try XCTUnwrap(try fixture.deliveries().first)
        let firstPublicationHash = mailboxSHA256(try Data(contentsOf: firstPublication))

        let restarted = try FileOutbox(directory: fixture.outboxDirectory)
        let restartedItem = try XCTUnwrap(try restarted.pendingItem(id: fixture.item.id))
        let retryInput = try DeliveryTransportInput(item: restartedItem)
        XCTAssertEqual(
            try fixture.transport(outbox: restarted, sealer: sealer).deliver(retryInput),
            .published
        )

        let publications = try fixture.deliveries()
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(mailboxSHA256(try Data(contentsOf: publications[0])), firstPublicationHash)
        XCTAssertEqual(mailboxSHA256(first.1), firstPublicationHash)
        XCTAssertFalse(publications.contains { $0.lastPathComponent.hasSuffix(".tmp") })
        XCTAssertEqual(sealer.sealCallCount, 1)
        XCTAssertEqual(sealer.nonceCallCount, 1)
        XCTAssertEqual(sealer.aeadCallCount, 1)
        XCTAssertEqual(sealer.signerCallCount, 1)
        XCTAssertNotNil(try restarted.pendingItem(id: fixture.item.id))
        XCTAssertEqual(try Data(contentsOf: fixture.item.fileURL), fixture.payload)
        XCTAssertEqual(try Data(contentsOf: first.2), first.1)
    }

    func testByteIdenticalExistingFinalIsIdempotentAndObservationIsNonterminal() throws {
        let fixture = try MailboxTransportFixture()
        let sealer = try CountingMailboxEnvelopeSealer(fixture)
        let input = try DeliveryTransportInput(item: fixture.item)
        XCTAssertEqual(
            try fixture.transport(sealer: sealer).deliver(input),
            .published
        )
        let observed = try fixture.transport(
            sealer: NeverMailboxEnvelopeSealer(),
            observe: { _, _ in true }
        ).deliver(try DeliveryTransportInput(item: try XCTUnwrap(
            try fixture.outbox.pendingItem(id: fixture.item.id)
        )))

        XCTAssertEqual(observed, .observed)
        XCTAssertEqual(try fixture.deliveries().count, 1)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
        XCTAssertNil(try fixture.outbox.pendingCursorCheckpoint())
        XCTAssertThrowsError(try fixture.outbox.markUploaded(fixture.item)) { error in
            XCTAssertEqual(
                error as? FileOutboxMailboxError,
                .mailboxArtifactsRequireHold
            )
        }
    }

    func testClearIntentRaisedDuringLocatorResolutionBlocksPublication() throws {
        let fixture = try MailboxTransportFixture()
        let sealer = try CountingMailboxEnvelopeSealer(fixture)
        let input = try DeliveryTransportInput(item: fixture.item)

        XCTAssertThrowsError(
            try fixture.transport(
                sealer: sealer,
                locate: {
                    try FileOutbox.beginTerminalResetRequest(
                        directory: fixture.outboxDirectory
                    )
                    return fixture.locator
                }
            ).deliver(input)
        ) { error in
            XCTAssertEqual(error as? FileOutboxClearIntentError, .clearInProgress)
        }

        XCTAssertTrue(fixture.outbox.terminalResetRequestIsActive)
        XCTAssertFalse(fixture.outbox.clearIntentIsActive)
        XCTAssertTrue(try fixture.deliveries().isEmpty)
        XCTAssertNotNil(try fixture.outbox.mailboxBinding(for: fixture.item.id))
    }

    func testProductionSealerUsesNonexportingMailboxKeyStoreSigningPath() throws {
        let fixture = try MailboxTransportFixture()
        let keyStore = MailboxKeyStore(
            service: repairService(),
            keychain: RepairSyntheticMailboxKeychain()
        )
        let identity = try keyStore.loadOrCreate()
        let senderPublic = try Curve25519.Signing.PublicKey(
            rawRepresentation: identity.signingPublicKey
        )
        let receiverPrivate = try DeliveryProtocolV1TestSupport.agreementKey(
            "todo14-production-receiver"
        )
        let receiverKeyID = try DeliveryProtocolV1.keyID(
            algorithm: "x25519",
            publicKey: receiverPrivate.publicKey.rawRepresentation
        )
        let context = MailboxTransportContext(
            receiverID: fixture.context.receiverID,
            deviceID: fixture.context.deviceID,
            receiverBindingID: MailboxTransportFixture.bindingID,
            connectionGeneration: 14,
            receiverAgreementPublicKey: receiverPrivate.publicKey,
            receiverAgreementKeyID: receiverKeyID,
            deviceSigningPublicKey: senderPublic,
            deviceSigningKeyID: identity.signingKeyID
        )

        let envelope = try DeliveryProtocolMailboxEnvelopeSealer(
            keyStore: keyStore
        ).seal(
            fixture.payload,
            envelopeID: fixture.sealContext.envelopeID,
            context: context,
            createdAtMS: fixture.sealContext.createdAtMS
        )
        let opened = try DeliveryProtocolV1.openDelivery(
            envelope,
            context: DeliveryEnvelopeOpenContext(
                receiverID: context.receiverID,
                deviceID: context.deviceID,
                connectionGeneration: context.connectionGeneration,
                receiverAgreementPrivateKey: receiverPrivate,
                senderSigningPublicKey: senderPublic
            )
        )

        XCTAssertEqual(opened.plaintext, fixture.payload)
        XCTAssertEqual(opened.payloadSHA256, mailboxSHA256(fixture.payload))
    }
}

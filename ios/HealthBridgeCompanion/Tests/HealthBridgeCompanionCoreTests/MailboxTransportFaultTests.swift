import Darwin
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxTransportTestsFaults: XCTestCase {
    func testDestinationWriteCloseSyncRenameAndQuotaFaultsAreRetryable() throws {
        let cases: [(MailboxPublicationBoundary, POSIXErrorCode)] = [
            (.createTemporary, .ENOSPC),
            (.writeTemporary, .EDQUOT),
            (.syncTemporary, .EIO),
            (.closeTemporary, .EIO),
            (.renameTemporary, .EIO),
            (.syncDirectory, .EIO),
        ]
        for (boundary, code) in cases {
            let fixture = try MailboxTransportFixture()
            let sealer = try CountingMailboxEnvelopeSealer(fixture)
            let publisher = POSIXMailboxEnvelopePublisher { observed in
                if observed == boundary { throw POSIXError(code) }
            }
            let result = try fixture.transport(
                sealer: sealer,
                publisher: publisher
            ).deliver(try DeliveryTransportInput(item: fixture.item))

            XCTAssertEqual(result, .retryable, "boundary=\(boundary)")
            XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
            let finalized = try fixture.finalizedEnvelope()
            XCTAssertFalse(try fixture.deliveries().contains {
                $0.lastPathComponent.hasSuffix(".tmp")
            })
            if boundary == .syncDirectory {
                XCTAssertEqual(try fixture.deliveries().count, 1)
            } else {
                XCTAssertTrue(try fixture.deliveries().isEmpty)
            }
            let restarted = try FileOutbox(directory: fixture.outboxDirectory)
            let restartedItem = try XCTUnwrap(
                try restarted.pendingItem(id: fixture.item.id)
            )
            XCTAssertEqual(
                try fixture.transport(
                    outbox: restarted,
                    sealer: NeverMailboxEnvelopeSealer()
                ).deliver(try DeliveryTransportInput(item: restartedItem)),
                .published
            )
            XCTAssertEqual(
                mailboxSHA256(try Data(contentsOf: try XCTUnwrap(
                    fixture.deliveries().first
                ))),
                mailboxSHA256(finalized.1)
            )
            XCTAssertEqual(sealer.sealCallCount, 1)
            XCTAssertEqual(sealer.nonceCallCount, 1)
            XCTAssertEqual(sealer.aeadCallCount, 1)
            XCTAssertEqual(sealer.signerCallCount, 1)
        }
    }

    func testFileProviderPublisherPublishesOnceAndReusesIdenticalFinal() throws {
        let fixture = try prefinalizedFixture()
        let finalized = try fixture.finalizedEnvelope()
        let publisher = FileProviderMailboxEnvelopePublisher()
        let transport = fixture.transport(
            sealer: NeverMailboxEnvelopeSealer(),
            publisher: publisher
        )

        XCTAssertEqual(
            try transport.deliver(try currentInput(fixture)),
            .published
        )
        let finalURL = try destinationURL(fixture, envelope: finalized.1)
        var before = stat()
        XCTAssertEqual(lstat(finalURL.path, &before), 0)
        XCTAssertEqual(try Data(contentsOf: finalURL), finalized.1)

        XCTAssertEqual(
            try transport.deliver(try currentInput(fixture)),
            .published
        )
        var after = stat()
        XCTAssertEqual(lstat(finalURL.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(try Data(contentsOf: finalURL), finalized.1)
    }

    func testFileProviderPublisherRejectsConflictingFinalEntries() throws {
        for entry in DestinationEntry.allCases {
            let fixture = try prefinalizedFixture()
            let finalized = try fixture.finalizedEnvelope()
            let finalURL = try destinationURL(fixture, envelope: finalized.1)
            try entry.install(at: finalURL, envelope: finalized.1)

            XCTAssertThrowsError(
                try fixture.transport(
                    sealer: NeverMailboxEnvelopeSealer(),
                    publisher: FileProviderMailboxEnvelopePublisher()
                ).deliver(try currentInput(fixture))
            ) { error in
                XCTAssertEqual(error as? MailboxTransportError, .destinationConflict)
            }
        }
    }

    func testExclusiveTemporaryCreationNeverOverwritesAndNeverExposesPartialFinal() throws {
        let fixture = try prefinalizedFixture()
        let finalized = try fixture.finalizedEnvelope()
        let claims = try DeliveryProtocolV1.inspectDelivery(
            finalized.1,
            senderSigningPublicKey: fixture.sealContext.senderSigningPrivateKey.publicKey
        )
        let finalName = try MailboxLayoutV1.finalFileName(
            identifier: claims.envelopeID.hexV1,
            kind: .delivery
        )
        let tempID = String(repeating: "a", count: 32)
        let deliveries = try XCTUnwrap(fixture.locator.lanes[.deliveries])
        let temp = deliveries.appendingPathComponent("\(finalName).\(tempID).tmp")
        let sentinel = Data("synthetic-existing-temp".utf8)
        try sentinel.write(to: temp)
        let publisher = POSIXMailboxEnvelopePublisher(
            temporaryIdentifier: { tempID }
        )

        let result = try fixture.transport(
            sealer: NeverMailboxEnvelopeSealer(),
            publisher: publisher
        ).deliver(try currentInput(fixture))

        XCTAssertEqual(result, .retryable)
        XCTAssertEqual(try Data(contentsOf: temp), sentinel)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: deliveries.appendingPathComponent(finalName).path
            )
        )
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
    }

    func testConflictingFinalSymlinkHardlinkAndNonregularEntriesFailClosed() throws {
        for entry in DestinationEntry.allCases {
            let fixture = try prefinalizedFixture()
            let finalized = try fixture.finalizedEnvelope()
            let finalURL = try destinationURL(fixture, envelope: finalized.1)
            try entry.install(at: finalURL, envelope: finalized.1)

            XCTAssertThrowsError(
                try fixture.transport(
                    sealer: NeverMailboxEnvelopeSealer()
                ).deliver(try currentInput(fixture))
            ) { error in
                XCTAssertEqual(error as? MailboxTransportError, .destinationConflict)
            }
            XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
            XCTAssertEqual(try Data(contentsOf: finalized.2), finalized.1)
        }
    }

    func testPathReplacementAndContainerLossDoNotPublishOrMutateLocalArtifacts() throws {
        let replaced = try prefinalizedFixture()
        let lane = try XCTUnwrap(replaced.locator.lanes[.deliveries])
        try FileManager.default.removeItem(at: lane)
        try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: false)
        XCTAssertThrowsError(
            try replaced.transport(
                sealer: NeverMailboxEnvelopeSealer()
            ).deliver(try currentInput(replaced))
        ) { error in
            XCTAssertEqual(error as? MailboxTransportError, .unsafeDestination)
        }
        XCTAssertNotNil(try replaced.outbox.pendingItem(id: replaced.item.id))

        let unavailable = try prefinalizedFixture()
        let result = try unavailable.transport(
            sealer: NeverMailboxEnvelopeSealer(),
            locate: { throw MailboxLocatorError.containerUnavailable }
        ).deliver(try currentInput(unavailable))
        XCTAssertEqual(result, .retryable)
        XCTAssertNotNil(try unavailable.outbox.pendingItem(id: unavailable.item.id))
    }

    func testPathReplacementDuringRenamePublishesOnlyToDetachedLaneAndFailsClosed() throws {
        let fixture = try MailboxTransportFixture()
        let lane = try XCTUnwrap(fixture.locator.lanes[.deliveries])
        let displaced = lane.deletingLastPathComponent()
            .appendingPathComponent("deliveries-displaced")
        let publisher = POSIXMailboxEnvelopePublisher { boundary in
            guard boundary == .renameTemporary else { return }
            try FileManager.default.moveItem(at: lane, to: displaced)
            try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(
            try fixture.transport(
                sealer: try CountingMailboxEnvelopeSealer(fixture),
                publisher: publisher
            ).deliver(try DeliveryTransportInput(item: fixture.item))
        ) { error in
            XCTAssertEqual(error as? MailboxTransportError, .unsafeDestination)
        }
        XCTAssertTrue(try fixture.deliveries().isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: displaced,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "hbd" }.count,
            1
        )
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
        _ = try fixture.finalizedEnvelope()
    }

    func testPayloadBindingMismatchDoesNotMutatePayloadOrFinalizedEnvelope() throws {
        let fixture = try prefinalizedFixture()
        let finalized = try fixture.finalizedEnvelope()
        let payloadBefore = try Data(contentsOf: fixture.item.fileURL)
        let current = try XCTUnwrap(try fixture.outbox.pendingItem(id: fixture.item.id))
        let mismatchedInput = try DeliveryTransportInput(
            item: current,
            readPersistedBytes: { _ in Data("synthetic-mismatch".utf8) }
        )

        XCTAssertThrowsError(
            try fixture.transport(
                sealer: NeverMailboxEnvelopeSealer()
            ).deliver(mismatchedInput)
        ) { error in
            XCTAssertEqual(error as? MailboxTransportError, .bindingMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.item.fileURL), payloadBefore)
        XCTAssertEqual(try Data(contentsOf: finalized.2), finalized.1)
        XCTAssertTrue(try fixture.deliveries().isEmpty)
    }

    func testLocalFinalizedEnvelopeReplacementAfterOpenFailsClosed() throws {
        let fixture = try prefinalizedFixture()
        let finalized = try fixture.finalizedEnvelope()
        let displaced = finalized.2.deletingLastPathComponent()
            .appendingPathComponent("displaced-envelope")

        XCTAssertThrowsError(
            try MailboxRegularFileReader.read(
                finalized.2,
                maximumBytes: MailboxLayoutV1.maximumDeliveryBytes,
                afterOpen: {
                    try FileManager.default.moveItem(at: finalized.2, to: displaced)
                    try finalized.1.write(to: finalized.2)
                }
            )
        ) { error in
            XCTAssertEqual(error as? MailboxTransportError, .envelopeConflict)
        }
        XCTAssertEqual(try Data(contentsOf: displaced), finalized.1)
        XCTAssertEqual(try Data(contentsOf: finalized.2), finalized.1)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
        XCTAssertTrue(try fixture.deliveries().isEmpty)
    }

    func testFinalizedEnvelopeContextConflictFailsClosedWithoutReencryption() throws {
        let fixture = try MailboxTransportFixture()
        let wrong = try DeliveryProtocolV1.sealDeliveryForVector(
            fixture.payload,
            context: DeliveryEnvelopeSealContext(
                envelopeID: fixture.sealContext.envelopeID,
                receiverID: Data(repeating: 0x7f, count: 16),
                deviceID: fixture.context.deviceID,
                connectionGeneration: fixture.context.connectionGeneration,
                createdAtMS: fixture.sealContext.createdAtMS,
                receiverAgreementPublicKey: fixture.sealContext.receiverAgreementPublicKey,
                senderSigningPrivateKey: fixture.sealContext.senderSigningPrivateKey
            ),
            ephemeralPrivateKey: DeliveryProtocolV1TestSupport.vectorEntropy("python").0,
            nonce: DeliveryProtocolV1TestSupport.vectorEntropy("python").1
        )
        _ = try fixture.outbox.finalizeMailboxEnvelope(
            itemID: fixture.item.id,
            envelope: wrong,
            expectedPayloadSHA256: mailboxSHA256(fixture.payload)
        )

        XCTAssertThrowsError(
            try fixture.transport(
                sealer: NeverMailboxEnvelopeSealer()
            ).deliver(try currentInput(fixture))
        ) { error in
            XCTAssertEqual(error as? MailboxTransportError, .bindingMismatch)
        }
        XCTAssertTrue(try fixture.deliveries().isEmpty)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: fixture.item.id))
    }
}

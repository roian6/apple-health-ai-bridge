import Darwin
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

enum DestinationEntry: CaseIterable {
    case conflictingBytes
    case symlink
    case hardlink
    case directory

    func install(at finalURL: URL, envelope: Data) throws {
        switch self {
        case .conflictingBytes:
            try Data("synthetic-conflict".utf8).write(to: finalURL)
        case .symlink:
            let target = finalURL.deletingLastPathComponent().appendingPathComponent("target")
            try envelope.write(to: target)
            try FileManager.default.createSymbolicLink(
                at: finalURL,
                withDestinationURL: target
            )
        case .hardlink:
            let source = finalURL.deletingLastPathComponent()
                .appendingPathComponent("hardlink-source")
            try envelope.write(to: source)
            guard link(source.path, finalURL.path) == 0 else {
                throw POSIXError(.EIO)
            }
        case .directory:
            try FileManager.default.createDirectory(
                at: finalURL,
                withIntermediateDirectories: false
            )
        }
    }
}

func prefinalizedFixture() throws -> MailboxTransportFixture {
    let fixture = try MailboxTransportFixture()
    let publisher = POSIXMailboxEnvelopePublisher { boundary in
        if boundary == .createTemporary { throw POSIXError(.ENOSPC) }
    }
    XCTAssertEqual(
        try fixture.transport(
            sealer: try CountingMailboxEnvelopeSealer(fixture),
            publisher: publisher
        ).deliver(try DeliveryTransportInput(item: fixture.item)),
        .retryable
    )
    return fixture
}

func currentInput(_ fixture: MailboxTransportFixture) throws -> DeliveryTransportInput {
    try DeliveryTransportInput(item: try XCTUnwrap(
        try fixture.outbox.pendingItem(id: fixture.item.id)
    ))
}

func destinationURL(
    _ fixture: MailboxTransportFixture,
    envelope: Data
) throws -> URL {
    let claims = try DeliveryProtocolV1.inspectDelivery(
        envelope,
        senderSigningPublicKey: fixture.sealContext.senderSigningPrivateKey.publicKey
    )
    let name = try MailboxLayoutV1.finalFileName(
        identifier: claims.envelopeID.hexV1,
        kind: .delivery
    )
    return try XCTUnwrap(fixture.locator.lanes[.deliveries])
        .appendingPathComponent(name)
}

import CryptoKit
import Darwin
import Foundation

public final class MailboxTransport: DeliveryTransport {
    public typealias Locate = () throws -> MailboxResolvedLocatorV1
    public typealias Observe = (URL, String) throws -> Bool

    private let outbox: FileOutbox
    private let context: MailboxTransportContext
    private let sealer: any MailboxEnvelopeSealing
    private let locate: Locate
    private let publisher: any MailboxEnvelopePublishing
    private let envelopeID: () -> Data
    private let nowMilliseconds: () -> Int64
    private let isCancelled: () -> Bool
    private let observe: Observe

    public init(
        outbox: FileOutbox,
        context: MailboxTransportContext,
        sealer: any MailboxEnvelopeSealing,
        locate: @escaping Locate
    ) {
        self.outbox = outbox
        self.context = context
        self.sealer = sealer
        self.locate = locate
        publisher = FileProviderMailboxEnvelopePublisher()
        envelopeID = Self.randomEnvelopeID
        nowMilliseconds = { Int64(Date().timeIntervalSince1970 * 1_000) }
        isCancelled = {
            withUnsafeCurrentTask { task in task?.isCancelled ?? false }
        }
        observe = { _, _ in false }
    }

    init(
        outbox: FileOutbox,
        context: MailboxTransportContext,
        sealer: any MailboxEnvelopeSealing,
        locate: @escaping Locate,
        publisher: any MailboxEnvelopePublishing,
        envelopeID: @escaping () -> Data,
        nowMilliseconds: @escaping () -> Int64,
        isCancelled: @escaping () -> Bool,
        observe: @escaping Observe
    ) {
        self.outbox = outbox
        self.context = context
        self.sealer = sealer
        self.locate = locate
        self.publisher = publisher
        self.envelopeID = envelopeID
        self.nowMilliseconds = nowMilliseconds
        self.isCancelled = isCancelled
        self.observe = observe
    }

    @discardableResult
    public func deliver(_ input: DeliveryTransportInput) throws -> DeliveryTransportResult {
        let finalized = try ensureFinalizedEnvelope(input)
        guard let published = try publish(finalized) else { return .retryable }
        return try observePublished(published)
    }

    func finalizeEnvelope(itemID: String) throws -> FileOutboxMailboxBindingV1 {
        guard let item = try outbox.pendingItem(id: itemID) else {
            throw MailboxTransportError.itemUnavailable
        }
        return try ensureFinalizedEnvelope(
            DeliveryTransportInput(item: item)
        ).binding
    }

    func publishEnvelope(itemID: String) throws -> DeliveryTransportResult {
        guard let item = try outbox.pendingItem(id: itemID),
              let binding = item.mailboxBinding else {
            throw MailboxTransportError.itemUnavailable
        }
        let finalized = try loadFinalizedEnvelope(itemID: item.id, binding: binding)
        return try publish(finalized) == nil ? .retryable : .published
    }

    func observeEnvelope(itemID: String) throws -> DeliveryTransportResult {
        try checkCancellation()
        try validateContext()
        guard let item = try outbox.pendingItem(id: itemID),
              item.receiverIdentity == context.receiverBindingID,
              let binding = item.mailboxBinding else {
            throw MailboxTransportError.itemUnavailable
        }
        let finalized = try loadFinalizedEnvelope(itemID: item.id, binding: binding)
        guard let locator = try resolvedLocator(),
              let lane = locator.lanes[.deliveries] else {
            return .retryable
        }
        let published = MailboxPublishedEnvelope(
            finalized: finalized,
            url: lane.appendingPathComponent(try finalName(for: finalized))
        )
        do {
            let bytes = try MailboxRegularFileReader.read(
                published.url,
                maximumBytes: MailboxLayoutV1.maximumDeliveryBytes
            )
            guard Self.sha256(bytes) == finalized.binding.envelopeSHA256 else {
                throw MailboxTransportError.destinationConflict
            }
        } catch let error as MailboxTransportError {
            throw error
        } catch {
            return .retryable
        }
        return try observePublished(published)
    }

    func validateOwnership(_ ownership: OutboxDeliveryOwnershipV1) throws {
        try validateContext()
        guard ownership.receiverID == context.receiverID,
              ownership.deviceID == context.deviceID,
              ownership.receiverBindingID == context.receiverBindingID,
              ownership.connectionGeneration == context.connectionGeneration,
              ownership.receiverAgreementKeyID == context.receiverAgreementKeyID,
              ownership.deviceSigningKeyID == context.deviceSigningKeyID else {
            throw MailboxTransportError.bindingMismatch
        }
    }

    func finalizedEnvelopeID(itemID: String) throws -> Data {
        guard let item = try outbox.pendingItem(id: itemID),
              item.receiverIdentity == context.receiverBindingID,
              let binding = item.mailboxBinding else {
            throw MailboxTransportError.itemUnavailable
        }
        return try loadFinalizedEnvelope(
            itemID: item.id,
            binding: binding
        ).claims.envelopeID
    }

    private func ensureFinalizedEnvelope(
        _ input: DeliveryTransportInput
    ) throws -> FinalizedEnvelope {
        try checkCancellation()
        try validateContext()
        guard let item = try outbox.pendingItem(id: input.item.id),
              item.fileURL.standardizedFileURL == input.item.fileURL.standardizedFileURL,
              item.receiverIdentity == context.receiverBindingID,
              input.item.receiverIdentity == context.receiverBindingID else {
            throw MailboxTransportError.itemUnavailable
        }
        let payloadDigest = Self.sha256(input.persistedBytes)
        let finalized: FinalizedEnvelope
        if let binding = item.mailboxBinding {
            guard binding.payloadSHA256 == payloadDigest else {
                throw MailboxTransportError.bindingMismatch
            }
            finalized = try loadFinalizedEnvelope(itemID: item.id, binding: binding)
        } else {
            try checkCancellation()
            let generatedEnvelope = try sealer.seal(
                input.persistedBytes,
                envelopeID: envelopeID(),
                context: context,
                createdAtMS: nowMilliseconds()
            )
            try checkCancellation()
            let claims = try validatedClaims(
                generatedEnvelope,
                expectedPayloadSHA256: payloadDigest
            )
            let binding = try outbox.finalizeMailboxEnvelope(
                itemID: item.id,
                envelope: generatedEnvelope,
                expectedPayloadSHA256: payloadDigest
            )
            try checkCancellation()
            finalized = try loadFinalizedEnvelope(itemID: item.id, binding: binding)
            guard finalized.bytes == generatedEnvelope,
                  finalized.claims == claims else {
                throw MailboxTransportError.envelopeConflict
            }
        }

        return finalized
    }

    private func publish(_ finalized: FinalizedEnvelope) throws -> MailboxPublishedEnvelope? {
        try checkCancellation()
        guard let locator = try resolvedLocator() else { return nil }
        let publishedURL: URL
        do {
            publishedURL = try publisher.publish(
                finalized.bytes,
                finalName: try finalName(for: finalized),
                locator: locator
            )
        } catch let error as MailboxPublicationError {
            switch error {
            case .retryable:
                return nil
            case .conflict:
                throw MailboxTransportError.destinationConflict
            case .unsafeDestination:
                throw MailboxTransportError.unsafeDestination
            }
        }
        try checkCancellation()
        return MailboxPublishedEnvelope(finalized: finalized, url: publishedURL)
    }

    private func observePublished(
        _ published: MailboxPublishedEnvelope
    ) throws -> DeliveryTransportResult {
        try checkCancellation()
        do {
            let wasObserved = try observe(
                published.url,
                published.finalized.binding.envelopeSHA256
            )
            try checkCancellation()
            return wasObserved ? .observed : .published
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .retryable
        }
    }

    private func resolvedLocator() throws -> MailboxResolvedLocatorV1? {
        do {
            return try locate()
        } catch let error as MailboxLocatorError {
            switch error {
            case .containerUnavailable, .storageFailure:
                return nil
            default:
                throw MailboxTransportError.unsafeDestination
            }
        }
    }

    private func finalName(for finalized: FinalizedEnvelope) throws -> String {
        try MailboxLayoutV1.finalFileName(
            identifier: finalized.claims.envelopeID.hexV1,
            kind: .delivery
        )
    }

    private func loadFinalizedEnvelope(
        itemID: String,
        binding: FileOutboxMailboxBindingV1
    ) throws -> FinalizedEnvelope {
        guard binding.envelopeFilename == "\(itemID).hbe" else {
            throw MailboxTransportError.envelopeConflict
        }
        let url = outbox.directoryURL.appendingPathComponent(binding.envelopeFilename)
        let bytes = try MailboxRegularFileReader.read(
            url,
            maximumBytes: MailboxLayoutV1.maximumDeliveryBytes
        )
        guard Self.sha256(bytes) == binding.envelopeSHA256 else {
            throw MailboxTransportError.envelopeConflict
        }
        let claims = try validatedClaims(
            bytes,
            expectedPayloadSHA256: binding.payloadSHA256
        )
        return FinalizedEnvelope(binding: binding, bytes: bytes, claims: claims)
    }

    private func validatedClaims(
        _ envelope: Data,
        expectedPayloadSHA256: String
    ) throws -> DeliveryEnvelopeClaimsV1 {
        let claims: DeliveryEnvelopeClaimsV1
        do {
            claims = try DeliveryProtocolV1.inspectDelivery(
                envelope,
                senderSigningPublicKey: context.deviceSigningPublicKey
            )
        } catch {
            throw MailboxTransportError.envelopeConflict
        }
        guard claims.receiverID == context.receiverID,
              claims.deviceID == context.deviceID,
              claims.connectionGeneration == context.connectionGeneration,
              claims.receiverAgreementKeyID == context.receiverAgreementKeyID,
              claims.senderSigningKeyID == context.deviceSigningKeyID,
              claims.payloadSHA256 == expectedPayloadSHA256 else {
            throw MailboxTransportError.bindingMismatch
        }
        return claims
    }

    private func validateContext() throws {
        guard context.receiverID.count == 16,
              context.deviceID.count == 16,
              !context.receiverBindingID.isEmpty,
              context.connectionGeneration >= 0,
              try DeliveryProtocolV1.keyID(
                  algorithm: "x25519",
                  publicKey: context.receiverAgreementPublicKey.rawRepresentation
              ) == context.receiverAgreementKeyID,
              try DeliveryProtocolV1.keyID(
                  algorithm: "ed25519",
                  publicKey: context.deviceSigningPublicKey.rawRepresentation
              ) == context.deviceSigningKeyID else {
            throw MailboxTransportError.bindingMismatch
        }
    }

    private func checkCancellation() throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomEnvelopeID() -> Data {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private struct FinalizedEnvelope {
    let binding: FileOutboxMailboxBindingV1
    let bytes: Data
    let claims: DeliveryEnvelopeClaimsV1
}

private struct MailboxPublishedEnvelope {
    let finalized: FinalizedEnvelope
    let url: URL
}

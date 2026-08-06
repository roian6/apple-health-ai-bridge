import Foundation

public final class OutboxDeliveryCoordinator: MailboxAckDurableFinalizationVerifying {
    public enum Boundary: Equatable, Sendable {
        case beforeStateWrite(OutboxDeliveryPhase)
        case afterStateWrite(OutboxDeliveryPhase)
        case afterEnvelopeFinalization
        case beforeProgressFinalization
        case afterProgressFinalization
        case payloadRetired
        case envelopeRetired
        case beforeAckDeletion
        case afterAckDeletion
    }

    public typealias Fault = (Boundary) throws -> Void

    let outbox: FileOutbox
    let transport: MailboxTransport
    let scanner: MailboxAckScanner
    let ownership: OutboxDeliveryOwnershipV1
    let finalizer: any OutboxDeliveryCommitFinalizing
    let fault: Fault

    public init(
        outbox: FileOutbox,
        transport: MailboxTransport,
        scanner: MailboxAckScanner,
        ownership: OutboxDeliveryOwnershipV1,
        finalizer: any OutboxDeliveryCommitFinalizing,
        fault: @escaping Fault = { _ in }
    ) {
        self.outbox = outbox
        self.transport = transport
        self.scanner = scanner
        self.ownership = ownership
        self.finalizer = finalizer
        self.fault = fault
    }

    public func state(itemID: String) throws -> FileOutboxDeliveryStateV1? {
        try outbox.deliveryState(for: itemID)
    }

    @discardableResult
    public func advance(itemID: String) throws -> FileOutboxDeliveryStateV1 {
        try validateCurrentOwnership()
        if try state(itemID: itemID) == nil {
            return try ownedState(itemID: itemID)
        }
        let current = try ownedState(itemID: itemID)
        switch current.phase {
        case .collected:
            _ = try transport.finalizeEnvelope(itemID: itemID)
            try fault(.afterEnvelopeFinalization)
            guard let encrypted = try state(itemID: itemID),
                  encrypted.phase == .encrypted,
                  encrypted.ownership == ownership else {
                throw OutboxDeliveryCoordinatorError.invalidState
            }
            try fault(.afterStateWrite(.encrypted))
            return encrypted
        case .encrypted:
            return try publish(itemID: itemID, current: current)
        case .published:
            return try observe(itemID: itemID, current: current)
        case .providerObserved, .ackVerified, .committedFinalized, .terminalFailure:
            return current
        case .retryableFailure:
            return try resume(itemID: itemID, current: current)
        }
    }

    public func handleDirectHTTPSuccess(
        _ descriptor: DirectUploadCompletionDescriptor
    ) throws -> OutboxDeliveryHTTPCallbackDisposition {
        guard try state(itemID: descriptor.itemID) != nil else {
            return .notMailboxOwned
        }
        return .ignoredMailboxOwned
    }

    func ownedState(itemID: String) throws -> FileOutboxDeliveryStateV1 {
        guard let item = try outbox.pendingItem(id: itemID)
            ?? outbox.mailboxBoundItemsForAckScanning().first(where: { $0.id == itemID })
        else {
            throw OutboxDeliveryCoordinatorError.itemUnavailable
        }
        guard item.receiverIdentity == ownership.receiverBindingID else {
            throw OutboxDeliveryCoordinatorError.ownershipMismatch
        }
        guard let current = item.deliveryState else {
            return try persist(
                itemID: itemID,
                expected: nil,
                updated: .stable(.collected, ownership: ownership)
            )
        }
        if current.ownership == nil {
            if current.phase == .encrypted {
                _ = try transport.finalizedEnvelopeID(itemID: itemID)
            }
            return try persist(
                itemID: itemID,
                expected: current,
                updated: current.assigning(ownership)
            )
        }
        guard current.ownership == ownership else {
            throw OutboxDeliveryCoordinatorError.ownershipMismatch
        }
        return current
    }

    func validateCurrentOwnership() throws {
        try transport.validateOwnership(ownership)
        let context = scanner.context
        guard ownership.receiverID == context.receiverID,
              ownership.deviceID == context.deviceID,
              ownership.receiverBindingID == context.receiverBindingID,
              ownership.connectionGeneration == context.connectionGeneration,
              ownership.deviceAgreementKeyID == context.deviceAgreementKeyID,
              ownership.deviceSigningKeyID == context.deviceSigningKeyID,
              ownership.receiverAgreementKeyID == context.receiverAgreementKeyID,
              ownership.receiverSigningKeyID == context.receiverSigningKeyID else {
            throw OutboxDeliveryCoordinatorError.ownershipMismatch
        }
    }

    private func publish(
        itemID: String,
        current: FileOutboxDeliveryStateV1
    ) throws -> FileOutboxDeliveryStateV1 {
        switch try transport.publishEnvelope(itemID: itemID) {
        case .published:
            return try persist(
                itemID: itemID,
                expected: current,
                updated: .stable(.published, ownership: ownership)
            )
        case .retryable:
            return try persist(
                itemID: itemID,
                expected: current,
                updated: .retryable(
                    from: .encrypted,
                    ownership: ownership,
                    code: .publicationRetry
                )
            )
        case .collected, .observed, .committed, .terminal:
            throw OutboxDeliveryCoordinatorError.invalidTransition
        }
    }

    private func observe(
        itemID: String,
        current: FileOutboxDeliveryStateV1
    ) throws -> FileOutboxDeliveryStateV1 {
        switch try transport.observeEnvelope(itemID: itemID) {
        case .observed:
            return try persist(
                itemID: itemID,
                expected: current,
                updated: .stable(.providerObserved, ownership: ownership)
            )
        case .published:
            return current
        case .retryable:
            return try persist(
                itemID: itemID,
                expected: current,
                updated: .retryable(
                    from: .published,
                    ownership: ownership,
                    code: .observationRetry
                )
            )
        case .collected, .committed, .terminal:
            throw OutboxDeliveryCoordinatorError.invalidTransition
        }
    }

    private func resume(
        itemID: String,
        current: FileOutboxDeliveryStateV1
    ) throws -> FileOutboxDeliveryStateV1 {
        switch current.retryFrom {
        case .encrypted:
            return try publish(itemID: itemID, current: current)
        case .published:
            return try observe(itemID: itemID, current: current)
        case .providerObserved:
            return try persist(
                itemID: itemID,
                expected: current,
                updated: .stable(.providerObserved, ownership: ownership)
            )
        case .collected, .ackVerified, .committedFinalized,
             .retryableFailure, .terminalFailure, nil:
            throw OutboxDeliveryCoordinatorError.invalidState
        }
    }

    func persist(
        itemID: String,
        expected: FileOutboxDeliveryStateV1?,
        updated: FileOutboxDeliveryStateV1
    ) throws -> FileOutboxDeliveryStateV1 {
        try fault(.beforeStateWrite(updated.phase))
        let persisted = try outbox.compareAndSetDeliveryState(
            itemID: itemID,
            expected: expected,
            updated: updated
        )
        try fault(.afterStateWrite(updated.phase))
        return persisted
    }
}

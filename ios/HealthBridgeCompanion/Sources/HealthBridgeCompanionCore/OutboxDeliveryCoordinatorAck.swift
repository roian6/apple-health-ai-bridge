import Foundation

extension OutboxDeliveryCoordinator {
    public func consume(
        _ event: MailboxAckEvent,
        itemID: String
    ) throws -> OutboxDeliveryAckDisposition {
        try validateCurrentOwnership()
        let current = try ownedState(itemID: itemID)
        if let proof = current.committedReceipt, proof.matches(event) {
            return .duplicateIdentical
        }
        guard current.phase == .providerObserved,
              let item = try outbox.pendingItem(id: itemID),
              let binding = item.mailboxBinding,
              binding.payloadSHA256 == event.receipt.payloadSHA256,
              try transport.finalizedEnvelopeID(itemID: itemID) == event.handle.envelopeID else {
            return .rejected
        }
        switch event.classification {
        case .committed:
            guard let receipt = OutboxDeliveryCommittedReceiptV1(event: event) else {
                return .rejected
            }
            let verified = FileOutboxDeliveryStateV1.committed(
                phase: .ackVerified,
                ownership: ownership,
                receipt: receipt
            )
            _ = try persist(itemID: itemID, expected: current, updated: verified)
            return .ackVerified
        case .retryableNack:
            guard event.receipt.result == .retryable else { return .rejected }
            let retryable = FileOutboxDeliveryStateV1.retryable(
                from: .providerObserved,
                ownership: ownership,
                code: OutboxDeliveryFailureCode(event.receipt.errorCode)
            )
            _ = try persist(itemID: itemID, expected: current, updated: retryable)
            return .retryableFailure
        case .terminalNack:
            guard event.receipt.result == .terminal else { return .rejected }
            let terminal = FileOutboxDeliveryStateV1.terminal(
                ownership: ownership,
                code: OutboxDeliveryFailureCode(event.receipt.errorCode)
            )
            _ = try persist(itemID: itemID, expected: current, updated: terminal)
            return .terminalHold
        case .duplicateIdentical, .conflict:
            return .rejected
        }
    }

    @discardableResult
    public func finalizeCommitted(itemID: String) throws -> FileOutboxDeliveryStateV1 {
        try validateCurrentOwnership()
        let current = try ownedState(itemID: itemID)
        if current.phase == .committedFinalized { return current }
        guard current.phase == .ackVerified,
              let receipt = current.committedReceipt else {
            throw OutboxDeliveryCoordinatorError.commitProofRequired
        }
        let context = OutboxDeliveryFinalizationContext(
            itemID: itemID,
            ownership: ownership
        )
        if try !finalizer.isFinalized(context) {
            try fault(.beforeProgressFinalization)
            try finalizer.finalize(context)
            try fault(.afterProgressFinalization)
        }
        guard try finalizer.isFinalized(context) else {
            throw OutboxDeliveryCoordinatorError.finalizationIncomplete
        }
        let committed = FileOutboxDeliveryStateV1.committed(
            phase: .committedFinalized,
            ownership: ownership,
            receipt: receipt
        )
        try fault(.beforeStateWrite(.committedFinalized))
        return try outbox.finalizeCommittedMailboxDelivery(
            itemID: itemID,
            expected: current,
            committed: committed,
            fault: { boundary in
                switch boundary {
                case .statePersisted:
                    try self.fault(.afterStateWrite(.committedFinalized))
                case .payloadRetired:
                    try self.fault(.payloadRetired)
                case .envelopeRetired:
                    try self.fault(.envelopeRetired)
                }
            }
        )
    }

    public func deleteAcknowledgment(
        for event: MailboxAckEvent,
        itemID: String
    ) throws {
        try validateCurrentOwnership()
        let current = try ownedState(itemID: itemID)
        guard current.phase == .committedFinalized,
              current.committedReceipt?.matches(event) == true else {
            throw OutboxDeliveryCoordinatorError.commitProofRequired
        }
        try fault(.beforeAckDeletion)
        try scanner.deleteAcknowledgment(for: event, durableFinalization: self)
        try fault(.afterAckDeletion)
    }

    public func isDurablyCommitted(_ event: MailboxAckEvent) throws -> Bool {
        try validateCurrentOwnership()
        return try outbox.mailboxBoundItemsForAckScanning().contains { item in
            guard let state = item.deliveryState else { return false }
            return state.phase == .committedFinalized
                && state.ownership == ownership
                && state.committedReceipt?.matches(event) == true
        }
    }
}

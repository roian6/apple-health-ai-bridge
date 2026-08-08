import Foundation

public enum OutboxDeliveryPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case collected
    case encrypted
    case published
    case providerObserved
    case ackVerified
    case committedFinalized
    case retryableFailure
    case terminalFailure
}

public enum OutboxDeliveryFailureCode: String, Codable, Equatable, Sendable {
    case publicationRetry, observationRetry
    case receiverBusy, storageUnavailable, quotaExceeded, internalRetry
    case payloadInvalid, payloadOversize, duplicateConflict
    case principalMismatch, bindingMismatch, generationMismatch, keyRevoked

    init(_ errorCode: DeliveryReceiptV1.ErrorCode?) {
        switch errorCode {
        case .receiverBusy:
            self = .receiverBusy
        case .storageUnavailable:
            self = .storageUnavailable
        case .quotaExceeded:
            self = .quotaExceeded
        case .internalRetry:
            self = .internalRetry
        case .payloadInvalid:
            self = .payloadInvalid
        case .payloadOversize:
            self = .payloadOversize
        case .duplicateConflict:
            self = .duplicateConflict
        case .principalMismatch:
            self = .principalMismatch
        case .bindingMismatch:
            self = .bindingMismatch
        case .generationMismatch:
            self = .generationMismatch
        case .keyRevoked:
            self = .keyRevoked
        case nil:
            self = .internalRetry
        }
    }
}

public struct OutboxDeliveryOwnershipV1: Codable, Equatable, Sendable {
    public let receiverGeneration: String
    public let receiverBindingID: String
    public let connectionGeneration: Int64
    public let receiverID: Data
    public let deviceID: Data
    public let deviceAgreementKeyID: String
    public let deviceSigningKeyID: String
    public let receiverAgreementKeyID: String
    public let receiverSigningKeyID: String
    public let resetEpoch: UInt64?

    public init(
        receiverGeneration: String,
        resetEpoch: UInt64?,
        ackContext: MailboxAckContext
    ) {
        self.receiverGeneration = receiverGeneration
        receiverBindingID = ackContext.receiverBindingID
        connectionGeneration = ackContext.connectionGeneration
        receiverID = ackContext.receiverID
        deviceID = ackContext.deviceID
        deviceAgreementKeyID = ackContext.deviceAgreementKeyID
        deviceSigningKeyID = ackContext.deviceSigningKeyID
        receiverAgreementKeyID = ackContext.receiverAgreementKeyID
        receiverSigningKeyID = ackContext.receiverSigningKeyID
        self.resetEpoch = resetEpoch
    }

    var isStructurallyValid: Bool {
        let boundedStrings = [
            receiverGeneration,
            receiverBindingID,
            deviceAgreementKeyID,
            deviceSigningKeyID,
            receiverAgreementKeyID,
            receiverSigningKeyID,
        ]
        return receiverID.count == 16
            && deviceID.count == 16
            && connectionGeneration >= 0
            && boundedStrings.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }
}

public struct OutboxDeliveryCommittedReceiptV1: Codable, Equatable, Sendable {
    public let envelopeID: Data
    public let payloadSHA256: String
    public let receiptID: Int64
    public let datasetGeneration: Int64
    public let committedAtMS: Int64

    init?(event: MailboxAckEvent) {
        guard event.classification == .committed,
              event.receipt.result == .committed,
              let receiptID = event.receipt.receiptID,
              let datasetGeneration = event.receipt.datasetGeneration,
              let committedAtMS = event.receipt.committedAtMS,
              event.receipt.errorCode == nil else {
            return nil
        }
        envelopeID = event.handle.envelopeID
        payloadSHA256 = event.receipt.payloadSHA256
        self.receiptID = receiptID
        self.datasetGeneration = datasetGeneration
        self.committedAtMS = committedAtMS
    }

    func matches(_ event: MailboxAckEvent) -> Bool {
        envelopeID == event.handle.envelopeID
            && payloadSHA256 == event.receipt.payloadSHA256
            && receiptID == event.receipt.receiptID
            && datasetGeneration == event.receipt.datasetGeneration
            && committedAtMS == event.receipt.committedAtMS
            && event.receipt.result == .committed
            && event.receipt.errorCode == nil
    }
}

public struct FileOutboxDeliveryStateV1: Codable, Equatable, Sendable {
    public let version: Int
    public let phase: OutboxDeliveryPhase
    public let ownership: OutboxDeliveryOwnershipV1?
    public let retryFrom: OutboxDeliveryPhase?
    public let failureCode: OutboxDeliveryFailureCode?
    public let committedReceipt: OutboxDeliveryCommittedReceiptV1?

    static let currentVersion = 1

    static func stable(
        _ phase: OutboxDeliveryPhase,
        ownership: OutboxDeliveryOwnershipV1?
    ) -> Self {
        Self(
            version: currentVersion,
            phase: phase,
            ownership: ownership,
            retryFrom: nil,
            failureCode: nil,
            committedReceipt: nil
        )
    }

    static func retryable(
        from phase: OutboxDeliveryPhase,
        ownership: OutboxDeliveryOwnershipV1,
        code: OutboxDeliveryFailureCode
    ) -> Self {
        Self(
            version: currentVersion,
            phase: .retryableFailure,
            ownership: ownership,
            retryFrom: phase,
            failureCode: code,
            committedReceipt: nil
        )
    }

    static func terminal(
        ownership: OutboxDeliveryOwnershipV1,
        code: OutboxDeliveryFailureCode
    ) -> Self {
        Self(
            version: currentVersion,
            phase: .terminalFailure,
            ownership: ownership,
            retryFrom: nil,
            failureCode: code,
            committedReceipt: nil
        )
    }

    static func committed(
        phase: OutboxDeliveryPhase,
        ownership: OutboxDeliveryOwnershipV1,
        receipt: OutboxDeliveryCommittedReceiptV1
    ) -> Self {
        Self(
            version: currentVersion,
            phase: phase,
            ownership: ownership,
            retryFrom: nil,
            failureCode: nil,
            committedReceipt: receipt
        )
    }

    func assigning(_ ownership: OutboxDeliveryOwnershipV1) -> Self {
        Self(
            version: version,
            phase: phase,
            ownership: ownership,
            retryFrom: retryFrom,
            failureCode: failureCode,
            committedReceipt: committedReceipt
        )
    }

    var isStructurallyValid: Bool {
        guard version == Self.currentVersion,
              ownership?.isStructurallyValid != false else {
            return false
        }
        switch phase {
        case .collected, .encrypted, .published, .providerObserved:
            return retryFrom == nil && failureCode == nil && committedReceipt == nil
        case .ackVerified, .committedFinalized:
            return ownership != nil
                && retryFrom == nil
                && failureCode == nil
                && committedReceipt != nil
        case .retryableFailure:
            return ownership != nil
                && retryFrom.map(Self.isRetrySource) == true
                && failureCode != nil
                && committedReceipt == nil
        case .terminalFailure:
            return ownership != nil
                && retryFrom == nil
                && failureCode != nil
                && committedReceipt == nil
        }
    }

    private static func isRetrySource(_ phase: OutboxDeliveryPhase) -> Bool {
        [.encrypted, .published, .providerObserved].contains(phase)
    }
}

public enum OutboxDeliveryAckDisposition: Equatable, Sendable {
    case ackVerified, retryableFailure, terminalHold
    case duplicateIdentical, rejected
}

public enum OutboxDeliveryHTTPCallbackDisposition: Equatable, Sendable {
    case ignoredMailboxOwned
    case notMailboxOwned
}

public enum OutboxDeliveryCoordinatorError: Error, Equatable, Sendable {
    case itemUnavailable
    case ownershipMismatch
    case invalidState
    case invalidTransition
    case commitProofRequired
    case finalizationIncomplete
}

public struct OutboxDeliveryFinalizationContext: Equatable, Sendable {
    public let itemID: String
    public let ownership: OutboxDeliveryOwnershipV1

    public init(itemID: String, ownership: OutboxDeliveryOwnershipV1) {
        self.itemID = itemID
        self.ownership = ownership
    }
}

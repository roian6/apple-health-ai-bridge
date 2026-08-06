import CryptoKit
import Foundation

public struct MailboxAckContext: Sendable {
    public let receiverID: Data
    public let deviceID: Data
    public let receiverBindingID: String
    public let connectionGeneration: Int64
    public let deviceAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public let deviceAgreementKeyID: String
    public let receiverSigningPublicKey: Curve25519.Signing.PublicKey
    public let receiverSigningKeyID: String
    public let receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey
    public let receiverAgreementKeyID: String
    public let deviceSigningPublicKey: Curve25519.Signing.PublicKey
    public let deviceSigningKeyID: String

    public init(
        receiverID: Data,
        deviceID: Data,
        receiverBindingID: String,
        connectionGeneration: Int64,
        deviceAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        deviceAgreementKeyID: String,
        receiverSigningPublicKey: Curve25519.Signing.PublicKey,
        receiverSigningKeyID: String,
        receiverAgreementPublicKey: Curve25519.KeyAgreement.PublicKey,
        receiverAgreementKeyID: String,
        deviceSigningPublicKey: Curve25519.Signing.PublicKey,
        deviceSigningKeyID: String
    ) {
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.receiverBindingID = receiverBindingID
        self.connectionGeneration = connectionGeneration
        self.deviceAgreementPrivateKey = deviceAgreementPrivateKey
        self.deviceAgreementKeyID = deviceAgreementKeyID
        self.receiverSigningPublicKey = receiverSigningPublicKey
        self.receiverSigningKeyID = receiverSigningKeyID
        self.receiverAgreementPublicKey = receiverAgreementPublicKey
        self.receiverAgreementKeyID = receiverAgreementKeyID
        self.deviceSigningPublicKey = deviceSigningPublicKey
        self.deviceSigningKeyID = deviceSigningKeyID
    }
}

public struct MailboxAckOutboxRecord: Equatable, Sendable {
    public let envelopeID: Data
    public let payloadSHA256: String
    public let receiverID: Data
    public let deviceID: Data
    public let receiverBindingID: String
    public let connectionGeneration: Int64
    public let receiverAgreementKeyID: String
    public let deviceSigningKeyID: String

    public init(
        envelopeID: Data,
        payloadSHA256: String,
        receiverID: Data,
        deviceID: Data,
        receiverBindingID: String,
        connectionGeneration: Int64,
        receiverAgreementKeyID: String,
        deviceSigningKeyID: String
    ) {
        self.envelopeID = envelopeID
        self.payloadSHA256 = payloadSHA256
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.receiverBindingID = receiverBindingID
        self.connectionGeneration = connectionGeneration
        self.receiverAgreementKeyID = receiverAgreementKeyID
        self.deviceSigningKeyID = deviceSigningKeyID
    }
}

public enum MailboxAckLookupResult: Equatable, Sendable {
    case active(MailboxAckOutboxRecord)
    case stale
    case unknown
    case conflict
}

public protocol MailboxAckOutboxLookingUp {
    func lookup(envelopeID: Data) throws -> MailboxAckLookupResult
}

public enum MailboxAckClassification: String, Equatable, Sendable {
    case committed
    case retryableNack
    case terminalNack
    case duplicateIdentical
    case conflict
}

public enum MailboxAckQuarantineReason: String, Equatable, Hashable, Sendable {
    case invalidName
    case unsafeEntry
    case oversize
    case authenticationFailed
    case unknownEnvelope
    case stale
    case bindingConflict
}

public struct MailboxAckQuarantineSummary: Equatable, Sendable {
    public private(set) var records: [MailboxAckQuarantineReason] = []
    public private(set) var suppressedCount = 0

    mutating func append(_ reason: MailboxAckQuarantineReason) {
        if records.count < 1_000 {
            records.append(reason)
        } else {
            suppressedCount += 1
        }
    }
}

struct MailboxAckFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

struct MailboxAckDeletionHandle: Sendable {
    let fileName: String
    let acknowledgmentSHA256: String
    let identity: MailboxAckFileIdentity
    let envelopeID: Data
}

public struct MailboxAckEvent: Equatable, Sendable {
    public let classification: MailboxAckClassification
    public let receipt: DeliveryReceiptV1
    let handle: MailboxAckDeletionHandle

    public var envelopeID: Data { handle.envelopeID }

    init(
        classification: MailboxAckClassification,
        receipt: DeliveryReceiptV1,
        handle: MailboxAckDeletionHandle
    ) {
        self.classification = classification
        self.receipt = receipt
        self.handle = handle
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.classification == rhs.classification
            && lhs.receipt == rhs.receipt
            && lhs.handle.envelopeID == rhs.handle.envelopeID
            && lhs.handle.acknowledgmentSHA256 == rhs.handle.acknowledgmentSHA256
    }
}

public struct MailboxAckScanReport: Equatable, Sendable {
    public let events: [MailboxAckEvent]
    public let quarantine: MailboxAckQuarantineSummary
    public let scannedFinalCount: Int
    public let scannedByteCount: Int64
    public let ignoredTemporaryCount: Int
}

public protocol MailboxAckDurableFinalizationVerifying {
    func isDurablyCommitted(_ event: MailboxAckEvent) throws -> Bool
}

public enum MailboxAckScannerError: Error, Equatable, Sendable {
    case invalidContext
    case unsafeMailbox
    case durableFinalizationRequired
    case acknowledgmentChanged
    case acknowledgmentConflict
}

enum MailboxAckScanBoundary: Equatable {
    case laneOpened
    case beforeCandidateOpen
    case afterCandidateOpen
    case beforeDeletionRevalidation
    case beforeUnlink
}

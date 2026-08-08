import CryptoKit
import Darwin
import Foundation

public final class MailboxAckScanner {
    public static let maximumScanFiles = 10_000
    public static let maximumScanBytes: Int64 = 2 * 1024 * 1024 * 1024
    typealias Locate = () throws -> MailboxResolvedLocatorV1
    typealias Fault = (MailboxAckScanBoundary) throws -> Void

    let context: MailboxAckContext
    let lookup: any MailboxAckOutboxLookingUp
    let locate: Locate
    let fault: Fault
    let transientUnsafeRetryLimit: Int
    public init(
        context: MailboxAckContext,
        lookup: any MailboxAckOutboxLookingUp,
        locate: @escaping () throws -> MailboxResolvedLocatorV1,
        transientUnsafeRetryLimit: Int = 0
    ) {
        self.context = context
        self.lookup = lookup
        self.locate = locate
        fault = { _ in }
        self.transientUnsafeRetryLimit = transientUnsafeRetryLimit
    }

    init(
        context: MailboxAckContext,
        lookup: any MailboxAckOutboxLookingUp,
        locate: @escaping Locate,
        fault: @escaping Fault,
        transientUnsafeRetryLimit: Int = 0
    ) {
        self.context = context
        self.lookup = lookup
        self.locate = locate
        self.fault = fault
        self.transientUnsafeRetryLimit = transientUnsafeRetryLimit
    }
    public func scan() throws -> MailboxAckScanReport {
        guard 0 ... 1 ~= transientUnsafeRetryLimit else {
            throw MailboxAckScannerError.invalidContext
        }
        var remainingRetries = transientUnsafeRetryLimit
        while true {
            do {
                return try scanOnce()
            } catch MailboxAckScannerError.unsafeMailbox
                where remainingRetries > 0 {
                remainingRetries -= 1
            }
        }
    }

    private func scanOnce() throws -> MailboxAckScanReport {
        try validateContext()
        let locator = try resolvedLocator()
        guard let lane = locator.lanes[.acks] else {
            throw MailboxAckScannerError.unsafeMailbox
        }
        try revalidate(locator)
        let directory: Int32
        do {
            directory = try MailboxAckFileReader.openDirectory(lane)
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }
        try revalidate(locator)
        defer { _ = close(directory) }
        try runFault(.laneOpened)
        try revalidate(locator)
        let enumeration: MailboxAckLaneEnumeration
        do {
            enumeration = try MailboxAckFileReader.enumerate(
                directory: directory,
                maximumNames: Self.maximumScanFiles
            )
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }

        var quarantine = MailboxAckQuarantineSummary()
        for _ in 0 ..< enumeration.invalidNameCount {
            quarantine.append(.invalidName)
        }
        var candidates: [MailboxAckCandidate] = []
        var scannedFinalCount = 0
        var scannedByteCount: Int64 = 0
        for name in enumeration.finalNames {
            try revalidate(locator)
            try runFault(.beforeCandidateOpen)
            let snapshot: MailboxAckFileSnapshot
            do {
                snapshot = try MailboxAckFileReader.read(
                    directory: directory,
                    name: name,
                    maximumBytes: MailboxLayoutV1.maximumMetadataBytes,
                    afterOpen: { try self.runFault(.afterCandidateOpen) }
                )
            } catch let error as MailboxAckFileError {
                switch error {
                case .unsafeEntry:
                    quarantine.append(.unsafeEntry)
                    continue
                case .oversize:
                    quarantine.append(.oversize)
                    continue
                case .replaced, .unavailable:
                    throw MailboxAckScannerError.unsafeMailbox
                }
            }
            try revalidate(locator)
            guard scannedByteCount <= Self.maximumScanBytes - snapshot.identity.size else {
                break
            }
            scannedFinalCount += 1
            scannedByteCount += snapshot.identity.size
            guard let candidate = try candidate(
                bytes: snapshot.bytes,
                identity: snapshot.identity,
                fileName: name,
                quarantine: &quarantine
            ) else {
                continue
            }
            candidates.append(candidate)
        }
        try revalidate(locator)
        return MailboxAckScanReport(
            events: MailboxAckClassifier.classify(candidates),
            quarantine: quarantine,
            scannedFinalCount: scannedFinalCount,
            scannedByteCount: scannedByteCount,
            ignoredTemporaryCount: enumeration.ignoredTemporaryCount
        )
    }
    private func candidate(
        bytes: Data,
        identity: MailboxAckFileIdentity,
        fileName: String,
        quarantine: inout MailboxAckQuarantineSummary
    ) throws -> MailboxAckCandidate? {
        let authenticated: AuthenticatedDeliveryAckV1
        do {
            authenticated = try DeliveryProtocolV1.authenticateAck(
                bytes,
                context: DeliveryAckAuthenticationContext(
                    receiverID: context.receiverID,
                    deviceID: context.deviceID,
                    connectionGeneration: context.connectionGeneration,
                    deviceAgreementPrivateKey: context.deviceAgreementPrivateKey,
                    receiverSigningPublicKey: context.receiverSigningPublicKey,
                    receiverAgreementPublicKey: context.receiverAgreementPublicKey
                )
            )
        } catch {
            quarantine.append(.authenticationFailed)
            return nil
        }
        let result: MailboxAckLookupResult
        do {
            result = try lookup.lookup(envelopeID: authenticated.envelopeID)
        } catch {
            quarantine.append(.bindingConflict)
            return makeCandidate(
                authenticated,
                bytes: bytes,
                identity: identity,
                fileName: fileName,
                classification: .conflict
            )
        }
        switch result {
        case let .active(record):
            guard matches(record, authenticated: authenticated) else {
                quarantine.append(.bindingConflict)
                return makeCandidate(
                    authenticated,
                    bytes: bytes,
                    identity: identity,
                    fileName: fileName,
                    classification: .conflict
                )
            }
            return makeCandidate(
                authenticated,
                bytes: bytes,
                identity: identity,
                fileName: fileName,
                classification: classification(authenticated.receipt)
            )
        case .stale:
            quarantine.append(.stale)
            return nil
        case .unknown:
            quarantine.append(.unknownEnvelope)
            return nil
        case .conflict:
            quarantine.append(.bindingConflict)
            return makeCandidate(
                authenticated,
                bytes: bytes,
                identity: identity,
                fileName: fileName,
                classification: .conflict
            )
        }
    }

    private func matches(
        _ record: MailboxAckOutboxRecord,
        authenticated: AuthenticatedDeliveryAckV1
    ) -> Bool {
        record.envelopeID == authenticated.envelopeID
            && record.payloadSHA256 == authenticated.receipt.payloadSHA256
            && record.receiverID == context.receiverID
            && record.deviceID == context.deviceID
            && record.receiverBindingID == context.receiverBindingID
            && record.connectionGeneration == context.connectionGeneration
            && record.receiverAgreementKeyID == context.receiverAgreementKeyID
            && record.deviceSigningKeyID == context.deviceSigningKeyID
            && authenticated.deviceAgreementKeyID == context.deviceAgreementKeyID
            && authenticated.receiverSigningKeyID == context.receiverSigningKeyID
    }
    private func validateContext() throws {
        guard context.receiverID.count == 16,
              context.deviceID.count == 16,
              !context.receiverBindingID.isEmpty,
              context.connectionGeneration >= 0,
              try keyID("x25519", context.deviceAgreementPrivateKey.publicKey.rawRepresentation)
                  == context.deviceAgreementKeyID,
              try keyID("ed25519", context.receiverSigningPublicKey.rawRepresentation)
                  == context.receiverSigningKeyID,
              try keyID("x25519", context.receiverAgreementPublicKey.rawRepresentation)
                  == context.receiverAgreementKeyID,
              try keyID("ed25519", context.deviceSigningPublicKey.rawRepresentation)
                  == context.deviceSigningKeyID else {
            throw MailboxAckScannerError.invalidContext
        }
    }

    private func keyID(_ algorithm: String, _ key: Data) throws -> String {
        try DeliveryProtocolV1.keyID(algorithm: algorithm, publicKey: key)
    }

}

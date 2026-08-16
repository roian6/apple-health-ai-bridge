import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ReceiverUploadResult: Equatable, Sendable {
    public let statusCode: Int
    public let responseBody: Data

    public init(statusCode: Int, responseBody: Data) {
        self.statusCode = statusCode
        self.responseBody = responseBody
    }
}

public enum ReceiverClientError: Error, Equatable, LocalizedError {
    case emptyBearerToken
    case nonHTTPResponse
    case sleepBaselineResetEpochConflict(minimumResetEpoch: UInt64)
    case unsuccessfulStatusCode(statusCode: Int, responseBody: Data)

    public var errorDescription: String? {
        switch self {
        case .emptyBearerToken:
            "Bearer token is empty."
        case .nonHTTPResponse:
            "Receiver returned a non-HTTP response."
        case .sleepBaselineResetEpochConflict(let minimumResetEpoch):
            "Receiver requires a Sleep reset epoch above \(minimumResetEpoch)."
        case .unsuccessfulStatusCode(let statusCode, _):
            "Receiver returned HTTP \(statusCode)."
        }
    }
}

private struct SleepBaselineEpochConflictResponse: Decodable {
    let error: String
    let minimumResetEpoch: UInt64

    enum CodingKeys: String, CodingKey {
        case error
        case minimumResetEpoch = "minimum_reset_epoch"
    }
}

public enum ReceiverIncomingPairingDecision: Equatable, Sendable {
    case importIncoming
    case resumeMatchingPending
    case rejectDifferentPending
}

public enum ReceiverIncomingPairingPolicy {
    public static func decision(
        hasPendingPairing: Bool,
        matchesPendingInvitation: Bool
    ) -> ReceiverIncomingPairingDecision {
        guard hasPendingPairing else { return .importIncoming }
        return matchesPendingInvitation ? .resumeMatchingPending : .rejectDifferentPending
    }
}

public struct ReceiverPairingCredential: Equatable, Sendable {
    public static let supportedSchemaID = "health_bridge.receiver_pairing_completion.v1"
    public static let supportedSchemaVersion = "1.0.0"

    public let label: String
    public let receiverURLString: String
    public let bearerToken: String
    public let tokenPrefix: String
    public let mailboxIdentity: MailboxConnectionIdentityV1?
}

public enum ReceiverPairingRedeemError: Error, Equatable, LocalizedError {
    case nonHTTPResponse
    case invitationInvalid
    case unsuccessfulStatusCode(Int)
    case invalidResponse
    case mismatchedReceiverURL
    case emptyBearerToken

    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "Pairing server returned a non-HTTP response."
        case .invitationInvalid:
            return "Pairing invitation is invalid, expired, or already used."
        case .unsuccessfulStatusCode(let statusCode):
            return "Pairing invitation could not be redeemed (HTTP \(statusCode))."
        case .invalidResponse:
            return "Pairing server returned an invalid credential response."
        case .mismatchedReceiverURL:
            return "Pairing server returned credentials for a different receiver."
        case .emptyBearerToken:
            return "Pairing server returned an empty device credential."
        }
    }

    public var diagnosticCode: String {
        switch self {
        case .nonHTTPResponse:
            "pairing_redeem_non_http_response"
        case .invitationInvalid:
            "pairing_redeem_invitation_invalid"
        case .unsuccessfulStatusCode(let statusCode) where (100...599).contains(statusCode):
            "pairing_redeem_http_\(statusCode)"
        case .unsuccessfulStatusCode:
            "pairing_redeem_http_error"
        case .invalidResponse:
            "pairing_redeem_invalid_response"
        case .mismatchedReceiverURL:
            "pairing_redeem_receiver_url_mismatch"
        case .emptyBearerToken:
            "pairing_redeem_empty_device_credential"
        }
    }
}

public struct TerminalRequestLifecycleSnapshot: Equatable, Sendable {
    public let requestIsActive: Bool
    public let publicationIsSuppressed: Bool
    public let payloadAdmissionIsOpen: Bool

    public init(
        requestIsActive: Bool,
        publicationIsSuppressed: Bool,
        payloadAdmissionIsOpen: Bool
    ) {
        self.requestIsActive = requestIsActive
        self.publicationIsSuppressed = publicationIsSuppressed
        self.payloadAdmissionIsOpen = payloadAdmissionIsOpen
    }

    public var admitsUserAction: Bool {
        !requestIsActive && !publicationIsSuppressed
    }

    public var admitsPayloadAction: Bool {
        admitsUserAction && payloadAdmissionIsOpen
    }
}

public enum ReceiverConnectionTerminalBarrierError: Error, Equatable, Sendable {
    case backgroundPayloadCancellationNotFinalized
}

public enum ReceiverPairingCommitBarrierError: String, CaseIterable, Error, Sendable {
    case cancelled = "pairing_commit_cancelled"
    case generationInvalidationFailed = "pairing_commit_generation_failed"
    case backgroundPayloadCancellationNotFinalized = "pairing_commit_background_cleanup_pending"
    case outboxUnavailable = "pairing_commit_outbox_unavailable"
    case outboxUnreadable = "pairing_commit_outbox_unreadable"
    case outboxIdentityAdmissionNotReady = "pairing_commit_outbox_identity_not_ready"
    case outboxNotEmpty = "pairing_commit_outbox_not_empty"
    case outboxClearIntentActive = "pairing_commit_outbox_clear_pending"
}

@MainActor
public final class ReceiverConnectionTerminalBarrier {
    private var transitionIsActive = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var admissionIsOpen: Bool {
        !transitionIsActive
    }

    public func perform<Result>(
        closeAdmission: @MainActor () -> Void,
        invalidateGeneration: @MainActor () throws -> String,
        cancelAndAwaitPairing: @MainActor () async -> Void,
        cancelAndAwaitForegroundPayloads: @MainActor () async -> Void,
        drainBackgroundPayloads: @MainActor () async -> Bool,
        commit: @MainActor (String) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        await acquireTransition()
        defer { releaseTransition() }
        try Task.checkCancellation()

        closeAdmission()
        let expectedGeneration = try invalidateGeneration()
        await cancelAndAwaitPairing()
        await cancelAndAwaitForegroundPayloads()
        guard await drainBackgroundPayloads() else {
            throw ReceiverConnectionTerminalBarrierError
                .backgroundPayloadCancellationNotFinalized
        }
        try Task.checkCancellation()
        return try await commit(expectedGeneration)
    }

    public func performRecovery<Result>(
        closeAdmission: @MainActor () -> Void,
        prepareRecovery: @MainActor () throws -> Void = {},
        cancelAndAwaitPairing: @MainActor () async -> Void,
        cancelAndAwaitForegroundPayloads: @MainActor () async -> Void,
        drainBackgroundPayloads: @MainActor () async -> Bool,
        commit: @MainActor () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        await acquireTransition()
        defer { releaseTransition() }
        try Task.checkCancellation()

        closeAdmission()
        try prepareRecovery()
        await cancelAndAwaitPairing()
        await cancelAndAwaitForegroundPayloads()
        guard await drainBackgroundPayloads() else {
            throw ReceiverConnectionTerminalBarrierError
                .backgroundPayloadCancellationNotFinalized
        }
        try Task.checkCancellation()
        return try await commit()
    }

    private func acquireTransition() async {
        if !transitionIsActive {
            transitionIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            transitionWaiters.append(continuation)
        }
    }

    private func releaseTransition() {
        guard !transitionWaiters.isEmpty else {
            transitionIsActive = false
            return
        }
        transitionWaiters.removeFirst().resume()
    }

    public func allowsPostResponseMutation(
        capturedGeneration: String,
        currentGeneration: String
    ) -> Bool {
        admissionIsOpen && capturedGeneration == currentGeneration
    }
}

public enum ReceiverRedirectPolicy {
    public static func allowsRedirect(from originalURL: URL, to redirectedURL: URL) -> Bool {
        origin(of: originalURL) == origin(of: redirectedURL)
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host):\(url.port ?? defaultPort)"
    }
}

private final class ReceiverURLSessionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = response.url ?? task.originalRequest?.url,
              let redirectedURL = request.url,
              ReceiverRedirectPolicy.allowsRedirect(
                  from: originalURL,
                  to: redirectedURL
              )
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public final class ReceiverClient: @unchecked Sendable {
    private static let healthCheckTimeout: TimeInterval = 5
    private static let pairingRedeemTimeout: TimeInterval = 15
    private static let uploadStallTimeout: TimeInterval = 120
    private static let uploadResourceTimeout: TimeInterval = 3_600
    private let session: URLSession

    public static func foregroundSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Self.uploadStallTimeout
        configuration.timeoutIntervalForResource = Self.uploadResourceTimeout
        return configuration
    }

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(
            configuration: Self.foregroundSessionConfiguration(),
            delegate: ReceiverURLSessionRedirectDelegate(),
            delegateQueue: nil
        )
    }

    public static func healthURL(forBatchURL batchURL: URL) -> URL {
        guard var components = URLComponents(url: batchURL, resolvingAgainstBaseURL: false) else {
            return batchURL
        }
        components.path = "/health"
        components.query = nil
        components.fragment = nil
        return components.url ?? batchURL
    }

    public func healthCheck(forBatchURL batchURL: URL) async throws -> ReceiverUploadResult {
        let healthURL = Self.healthURL(forBatchURL: batchURL)
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = Self.healthCheckTimeout
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReceiverClientError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ReceiverClientError.unsuccessfulStatusCode(statusCode: httpResponse.statusCode, responseBody: data)
        }
        return ReceiverUploadResult(statusCode: httpResponse.statusCode, responseBody: data)
    }

    public func redeem(
        pendingPairing: ReceiverPendingPairing,
        mailboxPublicIdentity: MailboxPublicIdentity? = nil
    ) async throws -> ReceiverPairingCredential {
        guard let redeemURL = URL(string: pendingPairing.redeemURLString),
              let expectedReceiverURL = URL(string: pendingPairing.receiverURLString),
              ["http", "https"].contains(redeemURL.scheme?.lowercased() ?? ""),
              ["http", "https"].contains(expectedReceiverURL.scheme?.lowercased() ?? ""),
              redeemURL.host != nil,
              expectedReceiverURL.host != nil,
              Self.origin(of: redeemURL) == Self.origin(of: expectedReceiverURL)
        else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let mailboxRequested: Bool
        switch (pendingPairing.transport, mailboxPublicIdentity) {
        case (.direct, nil):
            mailboxRequested = false
        case (.mailbox, .some):
            mailboxRequested = true
        default:
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let body = try JSONEncoder().encode(
            PairingRedeemRequest(
                invitationSecret: pendingPairing.invitationSecret,
                invitationCode: pendingPairing.invitationCode,
                installationID: pendingPairing.installationID,
                deviceCredential: pendingPairing.deviceCredential,
                platform: pendingPairing.platform,
                deviceSigningPublicKey: mailboxPublicIdentity?
                    .signingPublicKey.base64URLEncodedString(),
                deviceAgreementPublicKey: mailboxPublicIdentity?
                    .agreementPublicKey.base64URLEncodedString()
            )
        )
        var request = URLRequest(url: redeemURL)
        request.timeoutInterval = Self.pairingRedeemTimeout
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReceiverPairingRedeemError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 400,
               let payload = try? JSONDecoder().decode(PairingErrorPayload.self, from: data),
               payload.error == "pairing_invitation_invalid" {
                throw ReceiverPairingRedeemError.invitationInvalid
            }
            throw ReceiverPairingRedeemError.unsuccessfulStatusCode(httpResponse.statusCode)
        }
        let payload: PairingCompletionPayload
        do {
            payload = try JSONDecoder().decode(PairingCompletionPayload.self, from: data)
        } catch {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        guard payload.schemaID == ReceiverPairingCredential.supportedSchemaID,
              payload.schemaVersion == ReceiverPairingCredential.supportedSchemaVersion,
              let returnedReceiverURL = URL(string: payload.receiverURL),
              ["http", "https"].contains(returnedReceiverURL.scheme?.lowercased() ?? ""),
              returnedReceiverURL.host != nil
        else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        guard returnedReceiverURL.absoluteString == expectedReceiverURL.absoluteString else {
            throw ReceiverPairingRedeemError.mismatchedReceiverURL
        }
        let token = pendingPairing.deviceCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ReceiverPairingRedeemError.emptyBearerToken
        }
        let mailboxIdentity = try Self.mailboxConnectionIdentity(
            payload: payload,
            pendingPairing: pendingPairing,
            deviceIdentity: mailboxPublicIdentity,
            required: mailboxRequested
        )
        return ReceiverPairingCredential(
            label: payload.label,
            receiverURLString: payload.receiverURL,
            bearerToken: token,
            tokenPrefix: String(token.prefix(11)),
            mailboxIdentity: mailboxIdentity
        )
    }

    private static func mailboxConnectionIdentity(
        payload: PairingCompletionPayload,
        pendingPairing: ReceiverPendingPairing,
        deviceIdentity: MailboxPublicIdentity?,
        required: Bool
    ) throws -> MailboxConnectionIdentityV1? {
        let fieldsAreAbsent = payload.mailboxProtocolVersion == nil
            && payload.mailboxReceiverID == nil
            && payload.mailboxDeviceID == nil
            && payload.mailboxReceiverBindingID == nil
            && payload.mailboxConnectionGeneration == nil
            && payload.mailboxReceiverSigningPublicKey == nil
            && payload.mailboxReceiverAgreementPublicKey == nil
            && payload.mailboxReceiverSigningKeyID == nil
            && payload.mailboxReceiverAgreementKeyID == nil
        if !required {
            guard fieldsAreAbsent else {
                throw ReceiverPairingRedeemError.invalidResponse
            }
            return nil
        }
        guard let deviceIdentity,
              payload.mailboxProtocolVersion == 1,
              let receiverIDString = payload.mailboxReceiverID,
              let receiverID = Data(hexV1: receiverIDString),
              receiverID.count == 16,
              receiverID.hexV1 == receiverIDString,
              let deviceIDString = payload.mailboxDeviceID,
              let deviceID = Data(hexV1: deviceIDString),
              deviceID.count == 16,
              deviceID.hexV1 == deviceIDString,
              let binding = payload.mailboxReceiverBindingID,
              Data(strictBase64URL: binding, count: 32) != nil,
              let generation = payload.mailboxConnectionGeneration,
              generation > 0,
              let receiverSigningEncoded = payload.mailboxReceiverSigningPublicKey,
              let receiverSigning = Data(
                  strictBase64URL: receiverSigningEncoded,
                  count: 32
              ),
              let receiverAgreementEncoded = payload.mailboxReceiverAgreementPublicKey,
              let receiverAgreement = Data(
                  strictBase64URL: receiverAgreementEncoded,
                  count: 32
              ),
              let receiverSigningKeyID = payload.mailboxReceiverSigningKeyID,
              mailboxKeyIdentifier(
                  algorithm: "ed25519",
                  publicKey: receiverSigning
              ) == receiverSigningKeyID,
              let receiverAgreementKeyID = payload.mailboxReceiverAgreementKeyID,
              mailboxKeyIdentifier(
                  algorithm: "x25519",
                  publicKey: receiverAgreement
              ) == receiverAgreementKeyID else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let installationMaterial = Data(
            "health-bridge-pairing:installation:\(pendingPairing.installationID)".utf8
        )
        let installationHash = Data(SHA256.hash(data: installationMaterial)).hexV1
        return MailboxConnectionIdentityV1(
            receiverID: receiverIDString,
            deviceID: deviceIDString,
            devicePrincipal: "installation:\(installationHash)",
            deviceSigningKeyID: deviceIdentity.signingKeyID,
            deviceAgreementKeyID: deviceIdentity.agreementKeyID,
            receiverSigningKeyID: receiverSigningKeyID,
            receiverAgreementKeyID: receiverAgreementKeyID,
            receiverSigningPublicKey: receiverSigningEncoded,
            receiverAgreementPublicKey: receiverAgreementEncoded,
            opaqueBinding: binding,
            connectionGeneration: UInt64(generation)
        )
    }

    private static func origin(of url: URL) -> String {
        let port = url.port.map(String.init) ?? ""
        return "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(port)"
    }

    public func upload(_ batchData: Data, to url: URL, bearerToken: String) async throws -> ReceiverUploadResult {
        let trimmedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw ReceiverClientError.emptyBearerToken
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.uploadStallTimeout
        request.httpMethod = "POST"
        request.httpBody = batchData
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReceiverClientError.nonHTTPResponse
        }
        if httpResponse.statusCode == 409,
           let conflict = try? JSONDecoder().decode(
               SleepBaselineEpochConflictResponse.self,
               from: data
           ),
           conflict.error == "sleep_baseline_reset_epoch_conflict" {
            throw ReceiverClientError.sleepBaselineResetEpochConflict(
                minimumResetEpoch: conflict.minimumResetEpoch
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ReceiverClientError.unsuccessfulStatusCode(statusCode: httpResponse.statusCode, responseBody: data)
        }
        return ReceiverUploadResult(statusCode: httpResponse.statusCode, responseBody: data)
    }
}

public enum ReceiverPairingCancellationOutcome: Equatable, Sendable {
    case completed
    case committedCleanupPending
}

@MainActor
public final class ReceiverPairingCoordinator {
    private let client: ReceiverClient
    private let stateStore: ReceiverPairingStateStore
    private let settingsStore: ReceiverSettingsStore
    private let mailboxKeyStore: MailboxKeyStore

    public init(
        client: ReceiverClient,
        stateStore: ReceiverPairingStateStore,
        settingsStore: ReceiverSettingsStore,
        mailboxKeyStore: MailboxKeyStore = MailboxKeyStore(
            service: HealthBridgeAppIdentity.mailboxKeychainServiceName
        )
    ) {
        self.client = client
        self.stateStore = stateStore
        self.settingsStore = settingsStore
        self.mailboxKeyStore = mailboxKeyStore
    }

    public func pair(
        invitation: ReceiverPairingInvitation,
        expectedGeneration: String? = nil
    ) async throws -> ReceiverPairingCredential {
        let expectedGeneration = expectedGeneration ?? settingsStore.receiverSettingsGenerationToken
        return try await complete(
            stateStore.stage(invitation: invitation),
            expectedGeneration: expectedGeneration
        )
    }

    public func pair(
        manualPairing: ReceiverManualPairing,
        expectedGeneration: String? = nil
    ) async throws -> ReceiverPairingCredential {
        let expectedGeneration = expectedGeneration ?? settingsStore.receiverSettingsGenerationToken
        return try await complete(
            stateStore.stage(manualPairing: manualPairing),
            expectedGeneration: expectedGeneration
        )
    }

    public func resumePendingPairing(
        expectedGeneration: String? = nil
    ) async throws -> ReceiverPairingCredential? {
        let expectedGeneration = expectedGeneration ?? settingsStore.receiverSettingsGenerationToken
        if try finishPendingCancellationIfNeeded(expectedGeneration: expectedGeneration) {
            return nil
        }
        guard let pending = try stateStore.loadPending() else { return nil }
        return try await complete(
            pending,
            expectedGeneration: expectedGeneration
        )
    }

    public func hasPendingPairing() throws -> Bool {
        try stateStore.loadPending() != nil
            || stateStore.hasPendingCancellation()
            || settingsStore.terminalCancellationExpectedGeneration != nil
    }

    public func hasPendingCancellationRecovery() throws -> Bool {
        try stateStore.hasPendingCancellation()
            || settingsStore.terminalCancellationExpectedGeneration != nil
    }

    public func pendingPairingMatches(_ invitation: ReceiverPairingInvitation) throws -> Bool {
        guard let pending = try stateStore.loadPending() else { return false }
        return pending.matches(
            receiverURLString: invitation.receiverURLString,
            redeemURLString: invitation.redeemURLString,
            invitationSecret: invitation.invitationSecret,
            invitationCode: nil,
            transport: invitation.transport
        )
    }

    public func beginPendingCancellation(
        expectedGeneration: String? = nil
    ) throws {
        let expectedGeneration = expectedGeneration ?? settingsStore.receiverSettingsGenerationToken
        guard settingsStore.receiverSettingsGenerationToken == expectedGeneration else {
            throw ReceiverSettingsGenerationError.staleGeneration
        }
        var durableMarkerWritten = false
        var firstPersistenceError: Error?
        do {
            try settingsStore.beginTerminalCancellationIntent(
                expectedGeneration: expectedGeneration
            )
            durableMarkerWritten = true
        } catch {
            firstPersistenceError = error
        }
        do {
            try stateStore.beginPendingCancellation(
                expectedGeneration: expectedGeneration
            )
            durableMarkerWritten = true
        } catch {
            if firstPersistenceError == nil {
                firstPersistenceError = error
            }
        }
        guard durableMarkerWritten else {
            throw firstPersistenceError ?? ReceiverSettingsRecordError.persistenceFailed
        }
    }

    @discardableResult
    public func cancelPendingPairing(
        expectedGeneration: String? = nil
    ) throws -> ReceiverPairingCancellationOutcome {
        let expectedGeneration = expectedGeneration ?? settingsStore.receiverSettingsGenerationToken
        try beginPendingCancellation(expectedGeneration: expectedGeneration)
        do {
            _ = try finishPendingCancellationIfNeeded(
                expectedGeneration: expectedGeneration
            )
            return .completed
        } catch {
            if (try? settingsStore.receiverSettingsAreCleared()) == true {
                return .committedCleanupPending
            }
            throw error
        }
    }

    @discardableResult
    public func finishPendingCancellationIfNeeded(
        expectedGeneration: String? = nil
    ) throws -> Bool {
        let hasCancellationMarker = try stateStore.hasPendingCancellation()
        let terminalIntentGeneration = settingsStore.terminalCancellationExpectedGeneration
        guard hasCancellationMarker || terminalIntentGeneration != nil else { return false }
        let markerGeneration = hasCancellationMarker
            ? try stateStore.pendingCancellationExpectedGeneration()
            : nil
        guard let cancellationGeneration = markerGeneration ?? terminalIntentGeneration else {
            throw ReceiverPairingStateError.legacyCancellationRequiresRetry
        }
        let receiverSettingsWereCleared = try settingsStore.receiverSettingsAreCleared()
        let currentGeneration = settingsStore.receiverSettingsGenerationToken
        if cancellationGeneration != currentGeneration {
            try stateStore.clearPending()
            if hasCancellationMarker {
                try stateStore.finishPendingCancellation()
            }
            if terminalIntentGeneration != nil {
                if receiverSettingsWereCleared {
                    try settingsStore
                        .finishTerminalCancellationIntentAfterCommittedReceiverClear()
                } else {
                    try settingsStore.finishTerminalCancellationIntent()
                }
            }
            return true
        }
        let expectedGeneration = expectedGeneration ?? cancellationGeneration
        try settingsStore.clearReceiverSettings(expectedGeneration: expectedGeneration)
        try stateStore.clearPending()
        if hasCancellationMarker {
            try stateStore.finishPendingCancellation()
        }
        if terminalIntentGeneration != nil {
            if receiverSettingsWereCleared {
                try settingsStore.finishTerminalCancellationIntentAfterCommittedReceiverClear()
            } else {
                try settingsStore.finishTerminalCancellationIntent()
            }
        }
        return true
    }

    private func complete(
        _ pending: ReceiverPendingPairing,
        expectedGeneration: String
    ) async throws -> ReceiverPairingCredential {
        let credential: ReceiverPairingCredential
        do {
            let mailboxIdentity: MailboxPublicIdentity?
            if pending.transport == .mailbox {
                do {
                    mailboxIdentity = try mailboxKeyStore.loadOrCreate()
                } catch let error as MailboxKeyStoreError {
                    throw ReceiverPairingPreflightError.mailboxKey(
                        MailboxKeyPairingPreflightFailure(error)
                    )
                }
            } else {
                mailboxIdentity = nil
            }
            if let mailboxIdentity {
                credential = try await client.redeem(
                    pendingPairing: pending,
                    mailboxPublicIdentity: mailboxIdentity
                )
            } else {
                credential = try await client.redeem(pendingPairing: pending)
            }
        } catch let error as ReceiverPairingRedeemError {
            if error == .invitationInvalid,
               settingsStore.receiverSettingsGenerationToken == expectedGeneration {
                try? stateStore.clearPending()
            }
            throw error
        }
        try Task.checkCancellation()
        if let mailboxIdentity = credential.mailboxIdentity {
            try settingsStore.saveMailboxPairing(
                receiverURLString: credential.receiverURLString,
                bearerToken: credential.bearerToken,
                mailboxIdentity: mailboxIdentity,
                expectedGeneration: expectedGeneration
            )
        } else {
            try settingsStore.save(
                receiverURLString: credential.receiverURLString,
                bearerToken: credential.bearerToken,
                expectedGeneration: expectedGeneration,
                rotateBindingID: true
            )
        }
        try stateStore.clearPending()
        return credential
    }
}

private struct PairingRedeemRequest: Encodable {
    let invitationSecret: String?
    let invitationCode: String?
    let installationID: String
    let deviceCredential: String
    let platform: String
    let deviceSigningPublicKey: String?
    let deviceAgreementPublicKey: String?

    enum CodingKeys: String, CodingKey {
        case invitationSecret = "invitation_secret"
        case invitationCode = "invitation_code"
        case installationID = "installation_id"
        case deviceCredential = "device_credential"
        case platform
        case deviceSigningPublicKey = "device_signing_public_key"
        case deviceAgreementPublicKey = "device_agreement_public_key"
    }
}

private struct PairingErrorPayload: Decodable {
    let error: String
}

private struct PairingCompletionPayload: Decodable {
    let schemaID: String
    let schemaVersion: String
    let label: String
    let receiverURL: String
    let mailboxProtocolVersion: Int?
    let mailboxReceiverID: String?
    let mailboxDeviceID: String?
    let mailboxReceiverBindingID: String?
    let mailboxConnectionGeneration: Int?
    let mailboxReceiverSigningPublicKey: String?
    let mailboxReceiverAgreementPublicKey: String?
    let mailboxReceiverSigningKeyID: String?
    let mailboxReceiverAgreementKeyID: String?

    enum CodingKeys: String, CodingKey {
        case schemaID = "schema_id"
        case schemaVersion = "schema_version"
        case label
        case receiverURL = "receiver_url"
        case mailboxProtocolVersion = "mailbox_protocol_version"
        case mailboxReceiverID = "mailbox_receiver_id"
        case mailboxDeviceID = "mailbox_device_id"
        case mailboxReceiverBindingID = "mailbox_receiver_binding_id"
        case mailboxConnectionGeneration = "mailbox_connection_generation"
        case mailboxReceiverSigningPublicKey = "mailbox_receiver_signing_public_key"
        case mailboxReceiverAgreementPublicKey = "mailbox_receiver_agreement_public_key"
        case mailboxReceiverSigningKeyID = "mailbox_receiver_signing_key_id"
        case mailboxReceiverAgreementKeyID = "mailbox_receiver_agreement_key_id"
    }
}

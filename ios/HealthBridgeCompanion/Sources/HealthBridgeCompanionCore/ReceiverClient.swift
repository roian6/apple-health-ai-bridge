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
    private let ownsSession: Bool

    public static func foregroundSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Self.uploadStallTimeout
        configuration.timeoutIntervalForResource = Self.uploadResourceTimeout
        return configuration
    }

    public init(session: URLSession? = nil) {
        ownsSession = session == nil
        self.session = session ?? URLSession(
            configuration: Self.foregroundSessionConfiguration(),
            delegate: ReceiverURLSessionRedirectDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        if ownsSession {
            session.invalidateAndCancel()
        }
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

    public func nutritionSupport(forBatchURL batchURL: URL, bearerToken: String) async -> NutritionSupport {
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              var components = URLComponents(url: batchURL, resolvingAgainstBaseURL: false) else {
            return .unknown
        }
        components.path = "/v1/capabilities"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return .unknown }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = Self.healthCheckTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                  http.statusCode == 200, http.url == url,
                  http.value(forHTTPHeaderField: "Content-Type") == "application/json",
                  http.value(forHTTPHeaderField: "Cache-Control") == "no-store" else { return .unknown }
            return NutritionSupport.decode(data)
        } catch {
            // A failed fresh probe must never inherit an earlier success.
            return .unknown
        }
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

// Operations only; pending state, authentication and commit remain coordinator-owned.
// Merely constructing this dependency performs no provider or filesystem access.
@MainActor
public struct NativeMailboxPairingIO {
    public let resolve: (MailboxBootstrapDescriptor) throws -> URL
    public let publish: (URL, Data) throws -> Void
    public let read: (URL) throws -> Data?
    public let hydrate: (URL) throws -> Void
    public let wait: () async throws -> Void

    public init(
        resolve: @escaping (MailboxBootstrapDescriptor) throws -> URL,
        publish: @escaping (URL, Data) throws -> Void,
        read: @escaping (URL) throws -> Data?,
        hydrate: @escaping (URL) throws -> Void,
        wait: @escaping () async throws -> Void
    ) {
        self.resolve = resolve
        self.publish = publish
        self.read = read
        self.hydrate = hydrate
        self.wait = wait
    }
}

@MainActor
public final class ReceiverPairingCoordinator {
    private let client: ReceiverClient
    private let stateStore: ReceiverPairingStateStore
    private let settingsStore: ReceiverSettingsStore
    private let mailboxKeyStore: MailboxKeyStore
    private let nativeMailboxIO: NativeMailboxPairingIO?

    public init(
        client: ReceiverClient,
        stateStore: ReceiverPairingStateStore,
        settingsStore: ReceiverSettingsStore,
        mailboxKeyStore: MailboxKeyStore = MailboxKeyStore(
            service: HealthBridgeAppIdentity.mailboxKeychainServiceName
        ),
        nativeMailboxIO: NativeMailboxPairingIO? = nil
    ) {
        self.client = client
        self.stateStore = stateStore
        self.settingsStore = settingsStore
        self.mailboxKeyStore = mailboxKeyStore
        self.nativeMailboxIO = nativeMailboxIO
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
        if let pending = try stateStore.loadPending(), pending.mailboxBootstrap != nil {
            let cancelling = try stateStore.hasPendingCancellation()
            if pending.nativeCancellationConfirmed || cancelling || settingsStore.terminalCancellationExpectedGeneration != nil {
                try await resumeNativeCancellation(pending)
                return nil
            }
        }
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
            transport: invitation.transport,
            mailboxBootstrap: invitation.mailboxBootstrap,
            expiresAt: invitation.mailboxBootstrap == nil ? nil : invitation.expiresAt
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
        if let pending = try stateStore.loadPending(), pending.mailboxBootstrap != nil,
           pending.publicationMayHaveOccurred, !pending.nativeCancellationConfirmed {
            return .committedCleanupPending
        }
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
        if let pending = try stateStore.loadPending(), pending.mailboxBootstrap != nil,
           hasCancellationMarker || terminalIntentGeneration != nil || pending.nativeCancellationConfirmed {
            guard !pending.publicationMayHaveOccurred || pending.nativeCancellationConfirmed else {
                throw ReceiverPairingStateError.nativeCancellationRequiresReceipt
            }
            let confirmed: ReceiverPendingPairing
            if pending.nativeCancellationConfirmed { confirmed = pending }
            else { confirmed = try stateStore.confirmNativeCancellation(pending) }
            try finishNativeCancellation(confirmed)
            return true
        }
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
        if pending.mailboxBootstrap != nil {
            return try await completeNative(pending, expectedGeneration: expectedGeneration)
        }
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

    private func completeNative(_ initial: ReceiverPendingPairing, expectedGeneration: String) async throws -> ReceiverPairingCredential {
        var pending = initial
        try Task.checkCancellation()
        guard try stateStore.loadPending() == pending, try !stateStore.hasPendingCancellation(),
              settingsStore.terminalCancellationExpectedGeneration == nil, !pending.nativeCancellationConfirmed else {
            throw CancellationError()
        }
        if pending.sealedRequest == nil {
            try settingsStore.requireNativePairingAdmission(expectedGeneration: expectedGeneration)
            try requireUnexpiredNativeInvitation(pending)
            let request = try NativeMailboxPairing.seal(pending, keys: mailboxKeyStore)
            pending = try stateStore.saveNativeRequest(request, for: pending, generation: expectedGeneration)
        }
        if !pending.publicationMayHaveOccurred { try requireUnexpiredNativeInvitation(pending) }
        let device = try NativeMailboxPairing.verifyRequest(pending, keys: mailboxKeyStore)
        let identity = try NativeMailboxPairing.identity(pending, device: device)
        try requireNativeAuthority(pending, identity: identity)
        guard let descriptor = pending.mailboxBootstrap, let request = pending.sealedRequest,
              let generation = pending.nativeExpectedGeneration else { throw ReceiverPairingRedeemError.invalidResponse }
        let io = nativeMailboxIO ?? NativeMailboxPairingIO.live()
        try requireNativeAuthority(pending, identity: identity)
        let directory = try io.resolve(descriptor)
        try requireNativeAuthority(pending, identity: identity)
        // A crash, cancelled Task, or provider error after this write is ambiguous.
        // Only a request-bound cancellation receipt may retire that authority.
        pending = try stateStore.markNativePublication(pending)
        try requireNativeAuthority(pending, identity: identity)
        try io.publish(directory.appendingPathComponent("request.hbp"), request)
        try requireNativeAuthority(pending, identity: identity)
        let response = try await nativeResponse("completion.hbp", directory: directory, io: io) {
            try self.requireNativeAuthority(pending, identity: identity)
        }
        let credential = try NativeMailboxPairing.openCompletion(response, pending: pending, keys: mailboxKeyStore)
        guard credential.mailboxIdentity == identity else { throw ReceiverPairingRedeemError.invalidResponse }
        try requireNativeAuthority(pending, identity: identity)
        try settingsStore.saveNativeMailboxPairing(identity, expectedGeneration: generation)
        try stateStore.clearCommittedNativePending(pending)
        return credential
    }

    private func requireUnexpiredNativeInvitation(_ pending: ReceiverPendingPairing) throws {
        guard let expiresAt = pending.expiresAt, let expiry = ISO8601DateFormatter().date(from: expiresAt), expiry > Date() else {
            throw ReceiverPairingRedeemError.invitationInvalid
        }
    }

    private func requireNativeAuthority(_ pending: ReceiverPendingPairing, identity: MailboxConnectionIdentityV1) throws {
        try Task.checkCancellation()
        guard try stateStore.loadPending() == pending, try !stateStore.hasPendingCancellation(),
              settingsStore.terminalCancellationExpectedGeneration == nil, !pending.nativeCancellationConfirmed,
              let generation = pending.nativeExpectedGeneration else { throw CancellationError() }
        try settingsStore.requireNativePairingAuthority(identity, generation: generation)
    }

    private func resumeNativeCancellation(_ pending: ReceiverPendingPairing) async throws {
        try requireNativeCancellationAuthority(pending)
        if pending.nativeCancellationConfirmed || !pending.publicationMayHaveOccurred {
            let confirmed: ReceiverPendingPairing
            if pending.nativeCancellationConfirmed { confirmed = pending }
            else { confirmed = try stateStore.confirmNativeCancellation(pending) }
            try finishNativeCancellation(confirmed)
            return
        }
        guard let descriptor = pending.mailboxBootstrap, let request = pending.sealedRequest else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let cancel = try NativeMailboxPairing.cancellation(pending, keys: mailboxKeyStore)
        let io = nativeMailboxIO ?? NativeMailboxPairingIO.live()
        let directory = try io.resolve(descriptor)
        try requireNativeCancellationAuthority(pending)
        // Publish intent first: if the original provider effect never completed,
        // the receiver must see cancellation when the exact request arrives.
        try io.publish(directory.appendingPathComponent("cancel.hbp"), cancel)
        try requireNativeCancellationAuthority(pending)
        try io.publish(directory.appendingPathComponent("request.hbp"), request)
        try requireNativeCancellationAuthority(pending)
        let response = try await nativeResponse("cancelled.hbp", directory: directory, io: io) {
            try self.requireNativeCancellationAuthority(pending)
        }
        try NativeMailboxPairing.verifyCancellationReceipt(response, pending: pending)
        try requireNativeCancellationAuthority(pending)
        let confirmed = try stateStore.confirmNativeCancellation(pending)
        try finishNativeCancellation(confirmed)
    }

    private func requireNativeCancellationAuthority(_ pending: ReceiverPendingPairing) throws {
        try Task.checkCancellation()
        let cancelling = try stateStore.hasPendingCancellation()
        guard try stateStore.loadPending() == pending,
              pending.nativeCancellationConfirmed || cancelling
                || settingsStore.terminalCancellationExpectedGeneration != nil else { throw CancellationError() }
    }

    private func finishNativeCancellation(_ pending: ReceiverPendingPairing) throws {
        guard pending.nativeCancellationConfirmed, try stateStore.loadPending() == pending else { throw CancellationError() }
        if pending.publicationMayHaveOccurred, let generation = pending.nativeExpectedGeneration {
            let device = try NativeMailboxPairing.verifyRequest(pending, keys: mailboxKeyStore)
            let identity = try NativeMailboxPairing.identity(pending, device: device)
            try settingsStore.clearCancelledNativePairing(identity, generation: generation)
        }
        // Confirmed lives in the pending record until all other markers are gone.
        // A partial cleanup cannot enter HTTP cancellation or activate completion.
        try settingsStore.finishTerminalCancellationIntent()
        try stateStore.finishPendingCancellation()
        try stateStore.clearPending()
    }

    private func nativeResponse(
        _ name: String, directory: URL, io: NativeMailboxPairingIO, requireAuthority: () throws -> Void
    ) async throws -> Data {
        let url = directory.appendingPathComponent(name)
        for attempt in 0..<15 {
            try requireAuthority()
            try io.hydrate(url)
            try requireAuthority()
            let bytes = try io.read(url)
            try requireAuthority()
            if let bytes {
                guard !bytes.isEmpty, bytes.count <= NativeMailboxPairing.maximumBytes else {
                    throw ReceiverPairingRedeemError.invalidResponse
                }
                return bytes
            }
            if attempt < 14 {
                try await io.wait()
                try requireAuthority()
            }
        }
        throw MailboxLocatorError.storageFailure
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

extension NativeMailboxPairingIO {
    static func live() -> NativeMailboxPairingIO {
        var locator: MailboxPairingLocatorV1?
        @MainActor func checked(_ url: URL) throws -> MailboxPairingLocatorV1 {
            guard let locator else { throw MailboxLocatorError.containerUnavailable }
            try MailboxLocatorV1.requirePairingFile(url, locator: locator)
            return locator
        }
        return NativeMailboxPairingIO(resolve: { descriptor in
            #if !HEALTH_BRIDGE_MAILBOX_QA
            let resolved = try MailboxLocatorV1.resolvePairing(invitationID: descriptor.invitationID)
            locator = resolved
            return resolved.directory
            #else
            throw MailboxLocatorError.containerUnavailable
            #endif
        }, publish: { url, bytes in
            try FileProviderMailboxEnvelopePublisher().publishPairing(bytes, to: url, locator: checked(url))
        }, read: { url in
            let locator = try checked(url)
            guard try MailboxLocatorV1.pairingFileExists(url, locator: locator) else { return nil }
            #if os(iOS)
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return nil }
            #endif
            let bytes = try MailboxRegularFileReader.read(url, maximumBytes: 65_536) {
                try MailboxLocatorV1.revalidatePairing(locator)
            }
            try MailboxLocatorV1.revalidatePairing(locator)
            return bytes
        }, hydrate: { url in
            let locator = try checked(url)
            if try MailboxLocatorV1.pairingFileExists(url, locator: locator) {
                #if os(iOS)
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                #endif
            }
            try MailboxLocatorV1.revalidatePairing(locator)
        }, wait: { try await Task.sleep(for: .seconds(1)) })
    }
}

// Native enrollment wire belongs to the existing pairing coordinator. Kept in
// this target member so both the package and the App compile the same codec.
private enum NativeMailboxPairing {
    static let maximumBytes = 65_536
    private static let domain = "health-bridge/mailbox-pairing/v1/"
    private static let requestFields: Set<String> = [
        "v", "kind", "invitation_id", "sender_signing_public_key", "ephemeral_public_key", "nonce", "ciphertext", "signature",
    ]
    private static let completionFields: Set<String> = [
        "v", "kind", "invitation_id", "sender_signing_public_key", "request_sha256", "nonce", "ciphertext", "signature",
    ]
    private static let cancellationFields: Set<String> = [
        "v", "kind", "invitation_id", "request_sha256", "sender_signing_public_key", "signature",
    ]

    static func activeIdentity(_ keys: MailboxKeyStore) throws -> MailboxPublicIdentity {
        // A persisted request must never initialize replacement keys on replay.
        _ = try keys.agreementPrivateKey()
        return try keys.loadOrCreate()
    }

    static func seal(_ pending: ReceiverPendingPairing, keys: MailboxKeyStore) throws -> Data {
        try pending.validateNativeState()
        guard let bootstrap = pending.mailboxBootstrap, let secret = pending.invitationSecret else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try exchange(ephemeral, peer: bytes(bootstrap.receiverAgreementPublicKey, count: 32))
        let identity = try keys.loadOrCreate()
        let nonce = AES.GCM.Nonce()
        var envelope: [String: HBJCS1Value] = [
            "v": .integer(1), "kind": .string("request"), "invitation_id": .string(bootstrap.invitationID),
            "sender_signing_public_key": .string(identity.signingPublicKey.base64URLEncodedString()),
            "ephemeral_public_key": .string(ephemeral.publicKey.rawRepresentation.base64URLEncodedString()),
            "nonce": .string(nonce.withUnsafeBytes { Data($0) }.base64URLEncodedString()),
        ]
        let plaintext: [String: HBJCS1Value] = [
            "invitation_secret": .string(secret), "installation_id": .string(pending.installationID),
            "device_credential": .string(pending.deviceCredential), "platform": .string("ios"),
            "device_signing_public_key": .string(identity.signingPublicKey.base64URLEncodedString()),
            "device_agreement_public_key": .string(identity.agreementPublicKey.base64URLEncodedString()),
        ]
        let sealed = try AES.GCM.seal(canonical(plaintext),
            using: derive(shared, salt: invitationBytes(bootstrap), purpose: "request/key"), nonce: nonce,
            authenticating: prefixed("request/aad\0", fields: envelope))
        envelope["ciphertext"] = .string((sealed.ciphertext + sealed.tag).base64URLEncodedString())
        envelope["signature"] = .string(try keys.sign(prefixed("request/signature\0", fields: envelope)).base64URLEncodedString())
        return try bounded(canonical(envelope))
    }

    static func verifyRequest(_ pending: ReceiverPendingPairing, keys: MailboxKeyStore) throws -> MailboxPublicIdentity {
        guard let request = pending.sealedRequest, let bootstrap = pending.mailboxBootstrap else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let identity = try activeIdentity(keys)
        var fields = try object(request, keys: requestFields)
        guard fields["v"] == .integer(1), fields["kind"] == .string("request"),
              fields["invitation_id"] == .string(bootstrap.invitationID),
              fields["sender_signing_public_key"] == .string(identity.signingPublicKey.base64URLEncodedString()) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        _ = try bytes(string(fields, "ephemeral_public_key"), count: 32)
        _ = try bytes(string(fields, "nonce"), count: 12)
        guard try bytes(string(fields, "ciphertext")).count >= 16 else { throw ReceiverPairingRedeemError.invalidResponse }
        let signature = try bytes(string(fields, "signature"), count: 64)
        fields.removeValue(forKey: "signature")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.signingPublicKey)
        guard try publicKey.isValidSignature(signature, for: prefixed("request/signature\0", fields: fields)) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        return identity
    }

    static func identity(_ pending: ReceiverPendingPairing, device: MailboxPublicIdentity) throws -> MailboxConnectionIdentityV1 {
        guard let bootstrap = pending.mailboxBootstrap else { throw ReceiverPairingRedeemError.invalidResponse }
        let signing = try bytes(bootstrap.receiverSigningPublicKey, count: 32)
        let agreement = try bytes(bootstrap.receiverAgreementPublicKey, count: 32)
        let installation = hash(Data("health-bridge-pairing:installation:\(pending.installationID)".utf8))
        let receiverID = hash(Data("health-bridge/mailbox/v1/receiver-id\0".utf8) + signing).prefixDataV1(16)
        let deviceID = hash(Data("health-bridge/mailbox/v1/device-id\0".utf8) + installation).prefixDataV1(16)
        let binding = hash(Data("health-bridge/mailbox/v1/connection-binding\0".utf8)
            + receiverID + deviceID + device.signingPublicKey + device.agreementPublicKey + signing + agreement)
        return MailboxConnectionIdentityV1(
            receiverID: receiverID.hexV1, deviceID: deviceID.hexV1,
            devicePrincipal: "installation:" + installation.hexV1,
            deviceSigningKeyID: device.signingKeyID, deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(algorithm: "ed25519", publicKey: signing),
            receiverAgreementKeyID: try DeliveryProtocolV1.keyID(algorithm: "x25519", publicKey: agreement),
            receiverSigningPublicKey: bootstrap.receiverSigningPublicKey,
            receiverAgreementPublicKey: bootstrap.receiverAgreementPublicKey,
            opaqueBinding: binding.base64URLEncodedString(), connectionGeneration: 1)
    }

    static func openCompletion(_ encoded: Data, pending: ReceiverPendingPairing, keys: MailboxKeyStore) throws -> ReceiverPairingCredential {
        let device = try verifyRequest(pending, keys: keys)
        let expected = try identity(pending, device: device)
        guard let request = pending.sealedRequest, let bootstrap = pending.mailboxBootstrap else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        var fields = try authenticatedReceiverMessage(encoded, kind: "completion", fields: completionFields, pending: pending)
        let ciphertext = try bytes(string(fields, "ciphertext"))
        let nonce = try bytes(string(fields, "nonce"), count: 12)
        fields.removeValue(forKey: "ciphertext")
        guard ciphertext.count >= 16 else { throw ReceiverPairingRedeemError.invalidResponse }
        // Fetch local material outside the peer-crypto error boundary.
        let privateKey = try keys.agreementPrivateKey()
        let shared = try exchange(privateKey, peer: bytes(bootstrap.receiverAgreementPublicKey, count: 32))
        let salt = try invitationBytes(bootstrap) + hash(request)
        let nonceKey = derive(shared, salt: salt, purpose: "completion/nonce")
        guard nonce == nonceKey.withUnsafeBytes({ Data($0.prefix(12)) }) else { throw ReceiverPairingRedeemError.invalidResponse }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            plaintext = try AES.GCM.open(box, using: derive(shared, salt: salt, purpose: "completion/key"),
                authenticating: prefixed("completion/aad\0", fields: fields))
        } catch { throw ReceiverPairingRedeemError.invalidResponse }
        let payload = try object(plaintext, keys: [
            "schema_id", "schema_version", "label", "receiver_url", "mailbox_protocol_version", "mailbox_receiver_id",
            "mailbox_device_id", "mailbox_receiver_binding_id", "mailbox_connection_generation",
            "mailbox_receiver_signing_public_key", "mailbox_receiver_agreement_public_key",
            "mailbox_receiver_signing_key_id", "mailbox_receiver_agreement_key_id",
        ])
        guard payload["schema_id"] == .string(ReceiverPairingCredential.supportedSchemaID),
              payload["schema_version"] == .string(ReceiverPairingCredential.supportedSchemaVersion),
              payload["receiver_url"] == .null, payload["mailbox_protocol_version"] == .integer(1),
              payload["mailbox_connection_generation"] == .integer(1),
              payload["mailbox_receiver_id"] == .string(expected.receiverID),
              payload["mailbox_device_id"] == .string(expected.deviceID),
              payload["mailbox_receiver_binding_id"] == .string(expected.opaqueBinding),
              payload["mailbox_receiver_signing_public_key"] == .string(expected.receiverSigningPublicKey),
              payload["mailbox_receiver_agreement_public_key"] == .string(expected.receiverAgreementPublicKey),
              payload["mailbox_receiver_signing_key_id"] == .string(expected.receiverSigningKeyID),
              payload["mailbox_receiver_agreement_key_id"] == .string(expected.receiverAgreementKeyID) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        return ReceiverPairingCredential(label: try string(payload, "label"), receiverURLString: "",
            bearerToken: "", tokenPrefix: "", mailboxIdentity: expected)
    }

    static func cancellation(_ pending: ReceiverPendingPairing, keys: MailboxKeyStore) throws -> Data {
        let device = try verifyRequest(pending, keys: keys)
        guard let request = pending.sealedRequest, let bootstrap = pending.mailboxBootstrap else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        var fields: [String: HBJCS1Value] = ["v": .integer(1), "kind": .string("cancel"),
            "invitation_id": .string(bootstrap.invitationID), "request_sha256": .string(hash(request).hexV1),
            "sender_signing_public_key": .string(device.signingPublicKey.base64URLEncodedString())]
        fields["signature"] = .string(try keys.sign(prefixed("cancel/signature\0", fields: fields)).base64URLEncodedString())
        return try bounded(canonical(fields))
    }

    static func verifyCancellationReceipt(_ encoded: Data, pending: ReceiverPendingPairing) throws {
        _ = try authenticatedReceiverMessage(encoded, kind: "cancelled", fields: cancellationFields, pending: pending)
    }

    private static func authenticatedReceiverMessage(
        _ encoded: Data, kind: String, fields required: Set<String>, pending: ReceiverPendingPairing
    ) throws -> [String: HBJCS1Value] {
        guard let request = pending.sealedRequest, let bootstrap = pending.mailboxBootstrap else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        var fields = try object(encoded, keys: required)
        guard fields["v"] == .integer(1), fields["kind"] == .string(kind),
              fields["invitation_id"] == .string(bootstrap.invitationID),
              fields["request_sha256"] == .string(hash(request).hexV1),
              fields["sender_signing_public_key"] == .string(bootstrap.receiverSigningPublicKey) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let signature = try bytes(string(fields, "signature"), count: 64)
        fields.removeValue(forKey: "signature")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: bytes(bootstrap.receiverSigningPublicKey, count: 32))
        guard try publicKey.isValidSignature(signature, for: prefixed(kind + "/signature\0", fields: fields)) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        return fields
    }

    private static func exchange(_ key: Curve25519.KeyAgreement.PrivateKey, peer: Data) throws -> SharedSecret {
        do { return try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)) }
        catch { throw ReceiverPairingRedeemError.invalidResponse }
    }
    private static func derive(_ shared: SharedSecret, salt: Data, purpose: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data((domain + purpose).utf8), outputByteCount: 32)
    }
    private static func invitationBytes(_ bootstrap: MailboxBootstrapDescriptor) throws -> Data {
        guard let bytes = Data(hexV1: bootstrap.invitationID), bytes.count == 16,
              bytes.hexV1 == bootstrap.invitationID else { throw ReceiverPairingRedeemError.invalidResponse }
        return bytes
    }
    private static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func canonical(_ fields: [String: HBJCS1Value]) throws -> Data {
        try DeliveryProtocolV1.encodeMetadata(.object(fields))
    }
    private static func prefixed(_ purpose: String, fields: [String: HBJCS1Value]) throws -> Data {
        try Data((domain + purpose).utf8) + canonical(fields)
    }
    private static func bounded(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ReceiverPairingRedeemError.invalidResponse }
        return data
    }
    private static func object(_ encoded: Data, keys: Set<String>) throws -> [String: HBJCS1Value] {
        guard case .object(let fields) = try DeliveryProtocolV1.decodeMetadata(bounded(encoded)), Set(fields.keys) == keys else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        return fields
    }
    private static func string(_ fields: [String: HBJCS1Value], _ name: String) throws -> String {
        guard case .string(let value) = fields[name] else { throw ReceiverPairingRedeemError.invalidResponse }
        return value
    }
    private static func bytes(_ text: String, count: Int? = nil) throws -> Data {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw ReceiverPairingRedeemError.invalidResponse }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), bytes.base64URLEncodedString() == text else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        if let count, bytes.count != count { throw ReceiverPairingRedeemError.invalidResponse }
        return bytes
    }
}

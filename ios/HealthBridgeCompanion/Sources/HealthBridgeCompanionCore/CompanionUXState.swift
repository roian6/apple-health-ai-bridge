import Foundation

public struct CompanionSetupSnapshot: Equatable, Sendable {
    public let receiverURLString: String
    public let hasBearerToken: Bool
    public let healthPermissionsRequested: Bool
    public let isSyncing: Bool
    public let statusIsError: Bool
    public let pendingOutboxCount: Int

    public init(
        receiverURLString: String,
        hasBearerToken: Bool,
        healthPermissionsRequested: Bool,
        isSyncing: Bool,
        statusIsError: Bool,
        pendingOutboxCount: Int
    ) {
        self.receiverURLString = receiverURLString
        self.hasBearerToken = hasBearerToken
        self.healthPermissionsRequested = healthPermissionsRequested
        self.isSyncing = isSyncing
        self.statusIsError = statusIsError
        self.pendingOutboxCount = pendingOutboxCount
    }

    public var hasCompleteReceiverSettings: Bool {
        URL(string: receiverURLString) != nil && hasBearerToken
    }
}

public enum CompanionSetupState: Equatable, Sendable {
    case unpaired
    case pairedNeedsHealthPermission
    case ready
    case syncing
    case degraded

    public static func evaluate(_ snapshot: CompanionSetupSnapshot) -> CompanionSetupState {
        guard snapshot.hasCompleteReceiverSettings else {
            return .unpaired
        }
        if snapshot.isSyncing {
            return .syncing
        }
        guard snapshot.healthPermissionsRequested else {
            return .pairedNeedsHealthPermission
        }
        if snapshot.statusIsError || snapshot.pendingOutboxCount > 0 {
            return .degraded
        }
        return .ready
    }

    public var title: String {
        switch self {
        case .unpaired:
            return "Connect Health Bridge"
        case .pairedNeedsHealthPermission:
            return "Allow Apple Health access"
        case .ready:
            return "Ready to sync"
        case .syncing:
            return "Syncing"
        case .degraded:
            return "Sync failed"
        }
    }

    public var primaryActionTitle: String {
        switch self {
        case .unpaired:
            return "Connect Health Bridge"
        case .pairedNeedsHealthPermission:
            return "Allow Health access"
        case .ready:
            return "Sync Now"
        case .syncing:
            return "Syncing..."
        case .degraded:
            return "Sync Now"
        }
    }
}

public struct CompanionSyncNowCompletionSummary: Equatable, Sendable {
    public let message: String
    public let isError: Bool

    public init(message: String, isError: Bool) {
        self.message = message
        self.isError = isError
    }
}

public enum CompanionSyncNowCompletion {
    public static func summary(
        pendingOutboxCount: Int
    ) -> CompanionSyncNowCompletionSummary {
        CompanionSyncNowCompletionSummary(
            message: "Sync complete. Queued uploads: \(pendingOutboxCount).",
            isError: false
        )
    }
}

public enum CompanionPrimaryStatusMessage {
    public static func sanitized(from rawMessage: String, isError: Bool) -> String {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let message = trimmed.lowercased()
        if message.contains("sync complete") {
            return "Sync complete"
        }
        if message.contains("starting sync") || message.contains("starting apple health") {
            return "Sync started"
        }
        if message.contains("reading ") || message.contains("uploading ") || message.contains("running best-effort background") {
            return "Sync in progress"
        }
        if message.contains("recorded") && message.contains("anchor cursor") {
            return "Sync progress saved"
        }
        if message.contains("returned no") || message.contains("nothing sent") {
            return "No new data to send"
        }
        if message.contains("checking local bridge") || message.contains("checking connection") || message.contains("sending receiver test") {
            return "Checking connection"
        }
        if message.contains("connection check passed")
            || message.contains("connection verified")
            || message.contains("local bridge verified")
            || message.contains("connected to local bridge")
            || message.contains("saved local bridge")
            || message.contains("receiver accepted test")
        {
            return "Health Bridge connected"
        }
        if message.contains("opening apple health permissions") {
            return "Opening Apple Health permissions"
        }
        if message.contains("apple health reports these permissions were already reviewed")
            || message.contains("permissions already reviewed")
        {
            return "Permissions already reviewed. Change them in Health > profile picture > Privacy > Apps > Health Bridge."
        }
        if message.contains("apple health permission request completed") || message.contains("apple health read permission request completed") || message.contains("apple health permission screen completed") {
            return "Apple Health access updated"
        }
        if message.contains("health_data_unavailable") || message.contains("healthdataunavailable") {
            return "Apple Health data is not available on this device. Use a real iPhone with Health enabled."
        }
        if message.contains("permission_denied") || message.contains("authorization_denied") || message.contains("not authorized") {
            return "Apple Health access was denied. Review permissions in the Health app, then retry."
        }
        if message.contains("protected_data_unavailable") || message.contains("device_locked") || message.contains("protected data") {
            return "Apple Health data is locked. Unlock this iPhone, then retry."
        }
        if message.contains("empty_read_type_set") {
            return "No supported Apple Health data types are available to request on this device."
        }
        if message.contains("receiverclienterror") || message.contains("http ") || message.contains("http_") || message.contains("status code") {
            if message.contains("queued upload") {
                let diagnostic = diagnosticCode(from: trimmed)
                return "Queued upload failed\(diagnostic). Reconnect from setup link or retry after the server is back."
            }
            if message.contains("missing_key") || message.contains("empty bearer") || message.contains("code=0") || message.contains("receiverclienterror 0") {
                return "Connection key missing. Reconnect from setup link."
            }
            if message.contains("http_401") || message.contains("http 401") {
                return "Connection key was rejected (HTTP 401). Reconnect from a fresh setup link."
            }
            if message.contains("http_403") || message.contains("http 403") {
                return "Connection was refused (HTTP 403). Reconnect from setup link or check server access."
            }
            if message.contains("non_http_response") || message.contains("non-http") || message.contains("code=1") {
                return "Server response was not valid HTTP. Check Health Bridge, then retry."
            }
            if message.contains("http_") || message.contains("code=2") {
                let diagnostic = diagnosticCode(from: trimmed)
                return "Sync failed: Health Bridge returned an error\(diagnostic). Check the server, then retry."
            }
        }
        if message.contains("bridge url is invalid") || message.contains("unsupported url") || message.contains("code=-1002") {
            let diagnostic = diagnosticCode(from: trimmed)
            return "Bridge URL is invalid\(diagnostic). Reconnect from setup link or check manual URL."
        }
        if isLocalNetworkPairingFailure(message) {
            let diagnostic = diagnosticCode(from: trimmed)
            return "Pairing could not reach Health Bridge\(diagnostic). Allow Local Network access, check Wi-Fi or VPN routing, make sure the server is running, then retry."
        }
        if isServerReachabilityFailure(message) {
            let diagnostic = diagnosticCode(from: trimmed)
            if message.contains("queued upload") || message.contains("outbox") {
                return "Queued upload failed: Health Bridge is not reachable\(diagnostic). Start the server, then retry."
            }
            return "Sync failed: Health Bridge is not reachable\(diagnostic). Start the server, then retry."
        }
        if message.contains("status code") || message.contains("bad gateway") || message.contains("http 5") || message.contains("http 4") {
            let diagnostic = diagnosticCode(from: trimmed)
            return "Sync failed: Health Bridge returned an error\(diagnostic). Check the server, then retry."
        }
        if message.contains("queued upload") && (message.contains("failed") || message.contains("did not finish")) {
            let diagnostic = diagnosticCode(from: trimmed)
            return "Queued upload failed\(diagnostic). Reconnect from setup link or retry after the server is back."
        }
        if message.contains("cleared") && message.contains("queued upload") {
            return "Cleared queued uploads. Only unsent local retry data was removed."
        }
        if message.contains("queued uploads sent") {
            return trimmed
        }
        if message.contains("cancelled") && message.contains("queued uploads") {
            return "Sync cancelled. Already queued uploads are kept for retry."
        }
        if message.contains("disconnected") {
            if message.contains("queued uploads: 0") {
                return "Disconnected from server. Reconnect before syncing again."
            }
            if message.contains("queued uploads:") {
                return "Disconnected from server. Queued uploads remain on this iPhone; reconnect from setup link to retry them."
            }
            return "Disconnected"
        }
        if isError {
            if message.contains("healthkit") || message.contains("apple health") {
                let category = syncCategory(from: message)
                return "Apple Health \(category) sync failed. Review permissions or unlock this iPhone, then retry."
            }
            if message.contains("bridge") || message.contains("receiver") || message.contains("url") || message.contains("setup link") {
                return "Connection needs attention"
            }
            return "Something needs attention"
        }
        return "Ready"
    }

    private static func diagnosticCode(from rawMessage: String) -> String {
        let nsRange = NSRange(rawMessage.startIndex..<rawMessage.endIndex, in: rawMessage)
        let patterns = [
            #"domain=([^|]+)\|\s*code=(-?\d+)"#,
            #"([A-Za-z]+ErrorDomain)\s*[/ ]\s*(-?\d+)"#,
            #"HTTP\s*(\d{3})"#,
            #"status code\s*(\d{3})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: rawMessage, options: [], range: nsRange)
            else { continue }
            if match.numberOfRanges >= 3,
               let domainRange = Range(match.range(at: 1), in: rawMessage),
               let codeRange = Range(match.range(at: 2), in: rawMessage) {
                let domain = rawMessage[domainRange].trimmingCharacters(in: .whitespacesAndNewlines)
                let code = rawMessage[codeRange].trimmingCharacters(in: .whitespacesAndNewlines)
                return " (\(domain) \(code))"
            }
            if match.numberOfRanges >= 2,
               let codeRange = Range(match.range(at: 1), in: rawMessage) {
                let code = rawMessage[codeRange].trimmingCharacters(in: .whitespacesAndNewlines)
                return " (HTTP \(code))"
            }
        }
        return ""
    }

    private static func isServerReachabilityFailure(_ message: String) -> Bool {
        let failureMarkers = [
            "could not connect to the server",
            "connection refused",
            "connection reset",
            "network connection was lost",
            "request timed out",
            "timed out",
            "not connected to the internet",
            "cannot find host",
            "cannot connect",
            "nsurlerrordomain",
            "code=-1004",
            "code=-1001",
            "code=-1005",
            "code=-1009",
            "offline",
        ]
        return failureMarkers.contains { message.contains($0) }
    }

    private static func isLocalNetworkPairingFailure(_ message: String) -> Bool {
        let isPairingMessage = message.contains("pairing")
            || message.contains("setup link")
            || message.contains("invitation")
        return isPairingMessage && isServerReachabilityFailure(message)
    }

    private static func syncCategory(from message: String) -> String {
        if message.contains("step") { return "Step Count" }
        if message.contains("workout") { return "Workout" }
        if message.contains("sleep") { return "Sleep" }
        if message.contains("optional") || message.contains("quantity") || message.contains("sample") { return "data" }
        return "Health data"
    }
}

public enum CompanionAutomaticSyncCoveragePresentation {
    public static let primarySummary =
        "Supported Apple Health data. iOS decides background timing."

    public static func detail(
        runtimeAvailableQuantityTypeCount: Int,
        activeObserverQueryCount: Int,
        backgroundDeliveryEnabledCount: Int,
        backgroundDeliveryFailureCount: Int
    ) -> String {
        let querySentence = activeObserverQueryCount > 0
            ? "\(activeObserverQueryCount) observer queries are active"
            : "Observer queries start with Automatic Sync"
        let registrationSentence: String
        if backgroundDeliveryEnabledCount + backgroundDeliveryFailureCount > 0 {
            registrationSentence = "background delivery enabled for \(backgroundDeliveryEnabledCount) type(s), \(backgroundDeliveryFailureCount) failed"
        } else {
            registrationSentence = "background delivery registration is pending"
        }
        return "Steps, workouts, sleep, and \(runtimeAvailableQuantityTypeCount) runtime-available supported quantity types are in scope. \(querySentence); \(registrationSentence). Apple Health does not reveal read-permission status."
    }
}

public struct CompanionStatusLane: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let detail: String
    public let needsAttention: Bool

    public init(
        id: String,
        title: String,
        state: String,
        detail: String,
        needsAttention: Bool
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.needsAttention = needsAttention
    }
}

public enum CompanionStatusLaneBuilder {
    public static func lanes(
        snapshot: CompanionSetupSnapshot,
        backgroundSyncEnabled: Bool
    ) -> [CompanionStatusLane] {
        [
            receiverLane(snapshot: snapshot),
            healthAccessLane(snapshot: snapshot),
            outboxLane(snapshot: snapshot),
            automaticSyncLane(backgroundSyncEnabled: backgroundSyncEnabled),
        ]
    }

    private static func receiverLane(snapshot: CompanionSetupSnapshot) -> CompanionStatusLane {
        CompanionStatusLane(
            id: "receiver",
            title: "Connection",
            state: snapshot.hasCompleteReceiverSettings ? "Connected" : "Setup needed",
            detail: snapshot.hasCompleteReceiverSettings
                ? "Health Bridge connection is saved on this iPhone."
                : "Open or paste a private setup link before syncing.",
            needsAttention: !snapshot.hasCompleteReceiverSettings
        )
    }

    private static func healthAccessLane(snapshot: CompanionSetupSnapshot) -> CompanionStatusLane {
        CompanionStatusLane(
            id: "healthAccess",
            title: "Health access",
            state: snapshot.healthPermissionsRequested ? "Requested" : "Not requested",
            detail: snapshot.healthPermissionsRequested
                ? "Read-only access was requested for every supported Apple Health type currently available on this iPhone."
                : "Request read-only access for every supported Apple Health type currently available after pairing.",
            needsAttention: snapshot.hasCompleteReceiverSettings && !snapshot.healthPermissionsRequested
        )
    }

    private static func outboxLane(snapshot: CompanionSetupSnapshot) -> CompanionStatusLane {
        CompanionStatusLane(
            id: "outbox",
            title: "Queued uploads",
            state: snapshot.pendingOutboxCount == 0 ? "Clear" : "Pending",
            detail: snapshot.pendingOutboxCount == 0
                ? "No unsent uploads are waiting."
                : "\(snapshot.pendingOutboxCount) queued upload(s) are waiting.",
            needsAttention: snapshot.pendingOutboxCount > 0
        )
    }

    private static func automaticSyncLane(backgroundSyncEnabled: Bool) -> CompanionStatusLane {
        CompanionStatusLane(
            id: "automaticSync",
            title: "Automatic sync",
            state: backgroundSyncEnabled ? "Best-effort on" : "Manual",
            detail: backgroundSyncEnabled
                ? "Every supported Apple Health type currently available on this iPhone is included. iOS decides background timing; Sync Now performs an immediate catch-up."
                : "Use Sync Now whenever you want to update; background sync is optional.",
            needsAttention: false
        )
    }
}

public enum CompanionSyncNowStep: Equatable, Sendable {
    case checkReceiverReachability
    case flushPendingOutboxBeforeSync
    case syncAnchoredSteps
    case syncDailyActivityAggregates
    case syncAnchoredWorkouts
    case syncSleep
    case syncSupportedQuantityMetrics
}

public enum CompanionSyncNowPlan {
    public static let defaultSteps: [CompanionSyncNowStep] = [
        .checkReceiverReachability,
        .flushPendingOutboxBeforeSync,
        .syncAnchoredSteps,
        .syncDailyActivityAggregates,
        .syncAnchoredWorkouts,
        .syncSleep,
        .syncSupportedQuantityMetrics,
    ]
}

public enum CompanionPayloadNetworkAttemptPolicy {
    public static func shouldAttemptNetworkForNewPayload(
        hasPendingOutbox: Bool
    ) -> Bool {
        !hasPendingOutbox
    }

    public static func shouldAttemptNetworkForQueuedPayload(
        isFIFOHead: Bool
    ) -> Bool {
        isFIFOHead
    }
}

public final class CompanionHealthPermissionRequestStore {
    private enum Key {
        static let completedRuntimeTypeCodes =
            "healthBridge.companion.completedRuntimeHealthTypeCodes.v2"
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public var wasRequested: Bool {
        !requestedRuntimeTypeCodes.isEmpty
    }

    public var requestedRuntimeTypeCodes: [String] {
        Self.normalizedTypeCodes(
            userDefaults.stringArray(forKey: Key.completedRuntimeTypeCodes) ?? []
        )
    }

    @discardableResult
    public func invalidateIfRuntimeCoverageChanged(
        currentRuntimeTypeCodes: [String]
    ) -> Bool {
        guard wasRequested else { return false }
        guard requestedRuntimeTypeCodes
            != Self.normalizedTypeCodes(currentRuntimeTypeCodes) else {
            return false
        }
        userDefaults.removeObject(forKey: Key.completedRuntimeTypeCodes)
        return true
    }

    public func recordCompletedRequest(runtimeTypeCodes: [String]) {
        let normalizedTypeCodes = Self.normalizedTypeCodes(runtimeTypeCodes)
        guard !normalizedTypeCodes.isEmpty else {
            userDefaults.removeObject(forKey: Key.completedRuntimeTypeCodes)
            return
        }
        userDefaults.set(
            normalizedTypeCodes,
            forKey: Key.completedRuntimeTypeCodes
        )
    }

    private static func normalizedTypeCodes(_ typeCodes: [String]) -> [String] {
        Array(Set(typeCodes)).sorted()
    }
}

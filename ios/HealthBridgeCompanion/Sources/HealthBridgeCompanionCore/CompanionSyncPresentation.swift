public struct CompanionSyncPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case recoveryRequired
        case pairing
        case pendingPairing
        case connectionRequired
        case unpaired
        case permissionRequestNeeded
        case syncing
        case directQueued
        case mailboxConfirmationWaiting
        case needsAttention
        case ready
    }

    public enum Tone: Equatable, Sendable {
        case neutral
        case active
        case attention
        case error
    }

    public let phase: Phase
    public let title: String
    public let detail: String
    public let symbol: String
    public let tone: Tone

    public init(
        snapshot: CompanionSetupSnapshot,
        canSendConnectionTest: Bool,
        isPairing: Bool,
        hasPendingPairing: Bool,
        hasPendingPrivateStorageRecovery: Bool,
        usesMailboxTransport: Bool
    ) {
        if hasPendingPrivateStorageRecovery {
            phase = .recoveryRequired
        } else if isPairing {
            phase = .pairing
        } else if hasPendingPairing {
            phase = .pendingPairing
        } else if !canSendConnectionTest && snapshot.pendingOutboxCount > 0 {
            phase = .connectionRequired
        } else if snapshot.isSyncing && canSendConnectionTest {
            phase = .syncing
        } else if snapshot.statusIsError {
            phase = .needsAttention
        } else if !canSendConnectionTest {
            phase = snapshot.hasCompleteReceiverSettings ? .connectionRequired : .unpaired
        } else if snapshot.pendingOutboxCount > 0 {
            phase = usesMailboxTransport ? .mailboxConfirmationWaiting : .directQueued
        } else if !snapshot.healthPermissionsRequested {
            phase = .permissionRequestNeeded
        } else {
            phase = .ready
        }

        switch phase {
        case .recoveryRequired:
            (title, detail, symbol, tone) = (
                "Recovery required",
                "Open Settings to review private sync storage recovery.",
                "exclamationmark.arrow.triangle.2.circlepath", .error
            )
        case .pairing:
            (title, detail, symbol, tone) = (
                "Connecting",
                "Finishing the connection setup for this iPhone.",
                "link", .active
            )
        case .pendingPairing:
            (title, detail, symbol, tone) = (
                "Pairing needs attention",
                "Retry or cancel the pending pairing attempt in Settings.",
                "link.badge.plus", .attention
            )
        case .connectionRequired:
            (title, detail, symbol, tone) = (
                "Connection needs attention",
                "Review the saved connection in Settings. Queued uploads stay on this iPhone.",
                "link", .attention
            )
        case .unpaired:
            (title, detail, symbol, tone) = (
                "Connect Health Bridge",
                "Connect this iPhone before syncing Apple Health data.",
                "link", .neutral
            )
        case .permissionRequestNeeded:
            (title, detail, symbol, tone) = (
                "Allow Health access",
                "Open the Apple Health permission request and choose the data you want to share.",
                "heart.text.square", .attention
            )
        case .syncing:
            (title, detail, symbol, tone) = (
                "Syncing",
                "Checking and sending allowed Apple Health data.",
                "arrow.triangle.2.circlepath", .active
            )
        case .directQueued:
            (title, detail, symbol, tone) = (
                "Waiting to send",
                "\(snapshot.pendingOutboxCount) queued upload(s) will retry when Health Bridge is reachable.",
                "clock.arrow.circlepath", .attention
            )
        case .mailboxConfirmationWaiting:
            (title, detail, symbol, tone) = (
                "Waiting for receiver confirmation",
                "\(snapshot.pendingOutboxCount) secure delivery item(s) are awaiting receiver confirmation.",
                "clock.arrow.circlepath", .attention
            )
        case .needsAttention:
            (title, detail, symbol, tone) = (
                "Needs attention",
                "Review the status and connection in Settings, then retry.",
                "exclamationmark.triangle", .error
            )
        case .ready:
            (title, detail, symbol, tone) = (
                "Ready to sync",
                "Use Sync Now to check and send allowed Apple Health data.",
                "arrow.triangle.2.circlepath", .neutral
            )
        }
    }
}

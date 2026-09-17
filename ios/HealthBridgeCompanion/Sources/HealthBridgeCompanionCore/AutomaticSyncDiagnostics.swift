import Foundation

public enum AutomaticSyncDiagnosticLane: String, Codable, Equatable, Hashable, Sendable {
    case steps
    case dailyActivity = "daily_activity"
    case workouts
    case sleep
    case quantity
    case mixed
    case noWork = "no_work"

    init(typeCode: String) {
        let canonical = GenericQuantityCoveragePolicy.canonicalTypeCode(for: typeCode)
        switch canonical {
        case HealthBridgeHealthType.steps.typeCode:
            self = .steps
        case HealthBridgeHealthType.workouts.typeCode:
            self = .workouts
        case HealthBridgeHealthType.sleepAnalysis.typeCode:
            self = .sleep
        case let typeCode where HealthBridgeBackgroundSync.dailyActivityTypeCodes.contains(typeCode):
            self = .dailyActivity
        default:
            self = .quantity
        }
    }

    var displayName: String {
        switch self {
        case .dailyActivity:
            return "daily activity"
        case .noWork:
            return "none"
        case .steps, .workouts, .sleep, .quantity, .mixed:
            return rawValue
        }
    }
}

public enum AutomaticSyncDiagnosticWakeSource: String, Codable, Equatable, Sendable {
    case healthKitObserver = "healthkit_observer"
    case observerRetry = "observer_retry"
    case backgroundAppRefresh = "bg_app_refresh"
    case launchCatchUp = "launch_catch_up"
}

public enum AutomaticSyncDiagnosticTriggerReason: String, Codable, Equatable, Sendable {
    case observerError = "observer_error"
    case observer
    case observerBatch = "observer_batch"
    case scheduledRefresh = "scheduled_refresh"
    case launchCatchUp = "launch_catch_up"
}

public enum AutomaticSyncDiagnosticAdmissionResult: String, Codable, Equatable, Sendable {
    case notReached = "not_reached"
    case prerequisitesUnavailable = "prerequisites_unavailable"
    case durableStateUnavailable = "durable_state_unavailable"
    case accepted
    case skippedAlreadyRunning = "skipped_already_running"
    case skippedDebounced = "skipped_debounced"
}

public enum AutomaticSyncDiagnosticRunOutcome: String, Codable, Equatable, Sendable {
    case accepted
    case deferred
    case skipped
    case interrupted
    case failed
    case completed
}

public enum AutomaticSyncDiagnosticFailureStage: String, Codable, Equatable, Sendable {
    case read
    case store
    case encoding
    case transport
    case unknown

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AutomaticSyncDiagnosticFailureCategory: String, Codable, Equatable, Sendable {
    case operationFailed = "operation_failed"
    case cancellation
    case unknown

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AutomaticSyncDiagnosticFailure: Codable, Equatable, Sendable {
    public let stage: AutomaticSyncDiagnosticFailureStage
    public let category: AutomaticSyncDiagnosticFailureCategory

    public init(
        stage: AutomaticSyncDiagnosticFailureStage,
        category: AutomaticSyncDiagnosticFailureCategory
    ) {
        self.stage = stage
        self.category = category
    }

    public static let unknown = AutomaticSyncDiagnosticFailure(
        stage: .unknown,
        category: .unknown
    )

    public static func classified(
        stage: AutomaticSyncDiagnosticFailureStage,
        isCancellation: Bool
    ) -> Self {
        if isCancellation {
            return AutomaticSyncDiagnosticFailure(
                stage: stage,
                category: .cancellation
            )
        }
        guard stage != .unknown else { return .unknown }
        return AutomaticSyncDiagnosticFailure(
            stage: stage,
            category: .operationFailed
        )
    }
}

public enum AutomaticSyncPendingAgeBucket: String, Codable, Equatable, Sendable {
    case none
    case unknown
    case underFifteenMinutes = "<15m"
    case fifteenMinutesToOneHour = "15m–1h"
    case oneToSixHours = "1–6h"
    case sixTo24Hours = "6–24h"
    case oneToThreeDays = "1–3d"
    case overThreeDays = ">3d"

    static func bucket(for age: TimeInterval) -> Self {
        switch max(0, age) {
        case ..<900: return .underFifteenMinutes
        case ..<3_600: return .fifteenMinutesToOneHour
        case ..<21_600: return .oneToSixHours
        case ..<86_400: return .sixTo24Hours
        case ..<259_200: return .oneToThreeDays
        default: return .overThreeDays
        }
    }
}

public enum AutomaticSyncObserverCompletionLatencyBucket: String, Codable, Equatable, Sendable {
    case pending
    case notApplicable = "not_applicable"
    case underOneSecond = "<1s"
    case oneToFiveSeconds = "1–5s"
    case fiveToThirtySeconds = "5–30s"
    case thirtyTo120Seconds = "30–120s"
    case over120Seconds = ">120s"

    static func bucket(for latency: TimeInterval) -> Self {
        switch max(0, latency) {
        case ..<1: return .underOneSecond
        case ..<5: return .oneToFiveSeconds
        case ..<30: return .fiveToThirtySeconds
        case ..<120: return .thirtyTo120Seconds
        default: return .over120Seconds
        }
    }
}

public struct AutomaticSyncPendingSnapshot: Equatable, Sendable {
    public let pendingLaneCount: Int
    public let oldestPendingLane: AutomaticSyncDiagnosticLane?
    public let oldestPendingLaneAgeBucket: AutomaticSyncPendingAgeBucket
    public var recovery: BackgroundObserverPendingDiagnostic? = nil

    static let empty = AutomaticSyncPendingSnapshot(
        pendingLaneCount: 0,
        oldestPendingLane: nil,
        oldestPendingLaneAgeBucket: .none
    )
}

@MainActor
public enum AutomaticSyncObserverEventAdmission {
    case continueProcessing
    case complete(AutomaticSyncDiagnosticDraft?)
    case deferAcknowledgement(AutomaticSyncDiagnosticDraft?)
}

@MainActor
enum AutomaticSyncObserverEventLifecycle {
    static func process(
        startedAt: Date,
        now: () -> Date = Date.init,
        admissionHandler: () async -> AutomaticSyncObserverEventAdmission,
        eventHandler: () async -> AutomaticSyncDiagnosticDraft?,
        acknowledge: () -> Void,
        persistDiagnostic: (AutomaticSyncDiagnosticDraft, TimeInterval) -> Void
    ) async {
        let admission = await admissionHandler()
        let diagnostic: AutomaticSyncDiagnosticDraft?
        let completionLatency: TimeInterval
        switch admission {
        case .continueProcessing:
            completionLatency = now().timeIntervalSince(startedAt)
            acknowledge()
            diagnostic = await eventHandler()
        case .complete(let admittedDiagnostic):
            diagnostic = admittedDiagnostic
            completionLatency = now().timeIntervalSince(startedAt)
            acknowledge()
        case .deferAcknowledgement(let admittedDiagnostic):
            diagnostic = admittedDiagnostic
            completionLatency = now().timeIntervalSince(startedAt)
        }
        guard let diagnostic else { return }
        persistDiagnostic(diagnostic, completionLatency)
    }
}

public struct AutomaticSyncDiagnosticRecord: Codable, Equatable, Sendable {
    public var causalChain: AutomaticSyncCausalChain?
    public let runID: UUID
    public let wakeSource: AutomaticSyncDiagnosticWakeSource
    public let triggerReason: AutomaticSyncDiagnosticTriggerReason
    public let triggerLane: AutomaticSyncDiagnosticLane?
    public let admissionResult: AutomaticSyncDiagnosticAdmissionResult
    public let selectedLane: AutomaticSyncDiagnosticLane
    public let pendingLaneCount: Int
    public let oldestPendingLane: AutomaticSyncDiagnosticLane?
    public let oldestPendingLaneAgeBucket: AutomaticSyncPendingAgeBucket
    public let runOutcome: AutomaticSyncDiagnosticRunOutcome
    public let observerCompletionLatencyBucket: AutomaticSyncObserverCompletionLatencyBucket
    public let failure: AutomaticSyncDiagnosticFailure?
    public let remainingPendingLaneCount: Int

    public init(
        runID: UUID,
        wakeSource: AutomaticSyncDiagnosticWakeSource,
        triggerReason: AutomaticSyncDiagnosticTriggerReason,
        triggerLane: AutomaticSyncDiagnosticLane?,
        admissionResult: AutomaticSyncDiagnosticAdmissionResult,
        selectedLane: AutomaticSyncDiagnosticLane,
        pendingLaneCount: Int,
        oldestPendingLane: AutomaticSyncDiagnosticLane?,
        oldestPendingLaneAgeBucket: AutomaticSyncPendingAgeBucket,
        runOutcome: AutomaticSyncDiagnosticRunOutcome,
        observerCompletionLatencyBucket: AutomaticSyncObserverCompletionLatencyBucket,
        failure: AutomaticSyncDiagnosticFailure? = nil,
        remainingPendingLaneCount: Int,
        causalChain: AutomaticSyncCausalChain? = nil
    ) {
        self.causalChain = causalChain
        self.runID = runID
        self.wakeSource = wakeSource
        self.triggerReason = triggerReason
        self.triggerLane = triggerLane
        self.admissionResult = admissionResult
        self.selectedLane = selectedLane
        self.pendingLaneCount = pendingLaneCount
        self.oldestPendingLane = oldestPendingLane
        self.oldestPendingLaneAgeBucket = oldestPendingLaneAgeBucket
        self.runOutcome = runOutcome
        self.observerCompletionLatencyBucket = observerCompletionLatencyBucket
        self.failure = failure
        self.remainingPendingLaneCount = remainingPendingLaneCount
    }

    public var latestLaneSummary: String {
        let trigger = triggerLane.map { "\(triggerReason.rawValue)/\($0.displayName)" }
            ?? triggerReason.rawValue
        let oldest = oldestPendingLane.map {
            let observedAge = oldestPendingLaneAgeBucket == .unknown
                ? "observed pending age unknown"
                : "observed pending \(oldestPendingLaneAgeBucket.rawValue)"
            return "\($0.displayName) (\(observedAge))"
        } ?? "none"
        let failureSummary = failure.map {
            "; failure=\($0.stage.rawValue)/\($0.category.rawValue)"
        } ?? ""
        return "trigger=\(trigger); admission=\(admissionResult.rawValue); "
            + "selected=\(selectedLane.displayName); pending=\(pendingLaneCount); "
            + "oldest=\(oldest); outcome=\(runOutcome.rawValue); "
            + "remaining=\(remainingPendingLaneCount); observer completion="
            + observerCompletionLatencyBucket.rawValue
            + failureSummary
            + (causalChain.map { chain in
                "; chain=v\(chain.version)" + (chain.truncated ? "/truncated" : "")
                    + (chain.observerFailureRetention.map { "; observer_retention=\($0.rawValue)" } ?? "")
                    + (chain.initialRecoveryPending.map { "; recovery_initial=\($0.durableState.rawValue)/\($0.lanes.count)" } ?? "")
                    + (chain.remainingRecoveryPending.map { "; recovery_remaining=\($0.durableState.rawValue)/\($0.lanes.count)" } ?? "")
                    + "; lanes=" + chain.lanes.map { lane in
                        "\(lane.lane.rawValue):\(lane.attempted ? "attempted" : "selected")"
                            + "/\(lane.query.rawValue)/\(lane.newestSampleAge.rawValue)"
                            + "/\(lane.outbox.rawValue)/\(lane.delivery.rawValue)"
                    }.joined(separator: " -> ")
            } ?? "")
    }

    func replacingRunOutcome(
        _ outcome: AutomaticSyncDiagnosticRunOutcome
    ) -> Self {
        AutomaticSyncDiagnosticRecord(
            runID: runID,
            wakeSource: wakeSource,
            triggerReason: triggerReason,
            triggerLane: triggerLane,
            admissionResult: admissionResult,
            selectedLane: selectedLane,
            pendingLaneCount: pendingLaneCount,
            oldestPendingLane: oldestPendingLane,
            oldestPendingLaneAgeBucket: oldestPendingLaneAgeBucket,
            runOutcome: outcome,
            observerCompletionLatencyBucket: observerCompletionLatencyBucket,
            failure: failure,
            remainingPendingLaneCount: remainingPendingLaneCount,
            causalChain: causalChain
        )
    }

    func replacingObserverCompletionLatency(
        _ bucket: AutomaticSyncObserverCompletionLatencyBucket
    ) -> Self {
        AutomaticSyncDiagnosticRecord(
            runID: runID,
            wakeSource: wakeSource,
            triggerReason: triggerReason,
            triggerLane: triggerLane,
            admissionResult: admissionResult,
            selectedLane: selectedLane,
            pendingLaneCount: pendingLaneCount,
            oldestPendingLane: oldestPendingLane,
            oldestPendingLaneAgeBucket: oldestPendingLaneAgeBucket,
            runOutcome: runOutcome,
            observerCompletionLatencyBucket: bucket,
            failure: failure,
            remainingPendingLaneCount: remainingPendingLaneCount,
            causalChain: causalChain
        )
    }
}

import Foundation

public final class AutomaticSyncDiagnosticDraft {
    private let wakeSource: AutomaticSyncDiagnosticWakeSource
    private let triggerReason: AutomaticSyncDiagnosticTriggerReason
    private let triggerLane: AutomaticSyncDiagnosticLane?
    private var admissionResult: AutomaticSyncDiagnosticAdmissionResult = .notReached
    private var selectedLane: AutomaticSyncDiagnosticLane = .noWork
    private var pendingSnapshot: AutomaticSyncPendingSnapshot = .empty
    private var runOutcome: AutomaticSyncDiagnosticRunOutcome = .interrupted
    private var observerCompletionLatencyBucket: AutomaticSyncObserverCompletionLatencyBucket
    private var remainingPendingLaneCount = 0

    public init(reason: AutomaticSyncReason) {
        switch reason {
        case .observer(let typeCode):
            wakeSource = .healthKitObserver
            triggerReason = .observer
            triggerLane = AutomaticSyncDiagnosticLane(typeCode: typeCode)
            observerCompletionLatencyBucket = .pending
        case .observerBatch(let typeCodes):
            wakeSource = .observerRetry
            triggerReason = .observerBatch
            triggerLane = Self.triggerLane(for: typeCodes)
            observerCompletionLatencyBucket = .notApplicable
        case .scheduledRefresh:
            wakeSource = .backgroundAppRefresh
            triggerReason = .scheduledRefresh
            triggerLane = nil
            observerCompletionLatencyBucket = .notApplicable
        case .launchCatchUp:
            wakeSource = .launchCatchUp
            triggerReason = .launchCatchUp
            triggerLane = nil
            observerCompletionLatencyBucket = .notApplicable
        }
    }

    public func notePrerequisitesUnavailable() {
        admissionResult = .prerequisitesUnavailable
        runOutcome = .skipped
    }

    public func noteDurableStateUnavailable() {
        admissionResult = .durableStateUnavailable
        runOutcome = .skipped
    }

    public func notePending(_ snapshot: AutomaticSyncPendingSnapshot) {
        pendingSnapshot = snapshot
        remainingPendingLaneCount = snapshot.pendingLaneCount
    }

    public func noteAdmission(_ admission: BackgroundSyncRunAdmission) {
        if admission.shouldRun {
            admissionResult = .accepted
            return
        }
        switch admission.skipReason {
        case .alreadyRunning:
            admissionResult = .skippedAlreadyRunning
        case .debounced:
            admissionResult = .skippedDebounced
        case nil:
            admissionResult = .notReached
        }
        runOutcome = .skipped
    }

    public func noteSelection(_ lane: BackgroundSyncWorkLane?) {
        selectedLane = AutomaticSyncDiagnosticLane(workLane: lane)
    }

    public func noteCompletion(
        _ outcome: AutomaticSyncDiagnosticRunOutcome
    ) {
        runOutcome = outcome
    }

    public func noteCompletion(
        _ outcome: AutomaticSyncDiagnosticRunOutcome,
        remainingPendingSnapshot: AutomaticSyncPendingSnapshot
    ) {
        runOutcome = outcome
        remainingPendingLaneCount = remainingPendingSnapshot.pendingLaneCount
    }

    public var record: AutomaticSyncDiagnosticRecord {
        AutomaticSyncDiagnosticRecord(
            wakeSource: wakeSource,
            triggerReason: triggerReason,
            triggerLane: triggerLane,
            admissionResult: admissionResult,
            selectedLane: selectedLane,
            pendingLaneCount: pendingSnapshot.pendingLaneCount,
            oldestPendingLane: pendingSnapshot.oldestPendingLane,
            oldestPendingLaneAgeBucket: pendingSnapshot.oldestPendingLaneAgeBucket,
            runOutcome: runOutcome,
            observerCompletionLatencyBucket: observerCompletionLatencyBucket,
            remainingPendingLaneCount: remainingPendingLaneCount
        )
    }

    private static func triggerLane(
        for typeCodes: [String]
    ) -> AutomaticSyncDiagnosticLane? {
        let lanes = Set(typeCodes.map { AutomaticSyncDiagnosticLane(typeCode: $0) })
        if lanes.count > 1 { return .mixed }
        return lanes.first
    }
}

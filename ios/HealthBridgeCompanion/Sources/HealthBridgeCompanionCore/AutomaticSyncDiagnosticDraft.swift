import Foundation

public final class AutomaticSyncDiagnosticDraft {
    public let runID: UUID
    private var causalChain = AutomaticSyncCausalChain(lanes: [])
    private var activeLaneIndex: Int?
    private var queryStarted = false
    private let wakeSource: AutomaticSyncDiagnosticWakeSource
    private let triggerReason: AutomaticSyncDiagnosticTriggerReason
    private let triggerLane: AutomaticSyncDiagnosticLane?
    private var admissionResult: AutomaticSyncDiagnosticAdmissionResult = .notReached
    private var selectedLane: AutomaticSyncDiagnosticLane = .noWork
    private var pendingSnapshot: AutomaticSyncPendingSnapshot = .empty
    private var runOutcome: AutomaticSyncDiagnosticRunOutcome = .interrupted
    private var observerCompletionLatencyBucket: AutomaticSyncObserverCompletionLatencyBucket
    private var failure: AutomaticSyncDiagnosticFailure?
    private var remainingPendingLaneCount = 0
    private var pendingTypeCodesForDeferredPersistence: [String]?
    private var remainingPendingTypeCodesForDeferredPersistence: [String]?

    public init(
        reason: AutomaticSyncReason,
        runID: UUID = UUID()
    ) {
        self.runID = runID
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

    public init(
        observerFailureLane: BackgroundRecoveryLane, runID: UUID,
        completionLatency: TimeInterval, durableState: BackgroundRecoveryDurableState
    ) {
        self.runID = runID
        wakeSource = .healthKitObserver
        triggerReason = .observerError
        triggerLane = AutomaticSyncDiagnosticLane(rawValue: observerFailureLane.rawValue)
        observerCompletionLatencyBucket = .bucket(for: completionLatency)
        causalChain.observerFailureRetention = durableState
    }

    public func notePrerequisitesUnavailable() {
        admissionResult = .prerequisitesUnavailable
        runOutcome = .skipped
    }

    public func noteDurableStateUnavailable() {
        if admissionResult == .accepted {
            // The gate admitted this run, but its accepted marker could not be persisted.
            causalChain.durableAdmission = .failed
        } else {
            admissionResult = .durableStateUnavailable
        }
        runOutcome = .skipped
        failure = AutomaticSyncDiagnosticFailure(
            stage: .store,
            category: .operationFailed
        )
    }

    public func notePending(_ snapshot: AutomaticSyncPendingSnapshot) {
        pendingSnapshot = snapshot
        remainingPendingLaneCount = snapshot.pendingLaneCount
        if let recovery = snapshot.recovery {
            causalChain.initialRecoveryPending = recovery
            causalChain.remainingRecoveryPending = recovery
        }
    }

    func notePendingForDeferredPersistence(
        typeCodes: [String], recovery: BackgroundObserverPendingDiagnostic? = nil
    ) {
        pendingTypeCodesForDeferredPersistence = typeCodes
        if let recovery {
            causalChain.initialRecoveryPending = recovery
            causalChain.remainingRecoveryPending = recovery
        }
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

    public func notePlan(_ lanes: [BackgroundSyncWorkLane]) {
        let previous = causalChain
        causalChain = AutomaticSyncCausalChain(lanes: lanes.map {
            AutomaticSyncLaneEvidence(lane: AutomaticSyncDiagnosticLane(workLane: $0))
        }, durableAdmission: causalChain.durableAdmission)
        causalChain.observerFailureRetention = previous.observerFailureRetention
        causalChain.initialRecoveryPending = previous.initialRecoveryPending
        causalChain.remainingRecoveryPending = previous.remainingRecoveryPending
        activeLaneIndex = nil
    }

    public func noteAttempt(_ lane: BackgroundSyncWorkLane) {
        activeLaneIndex = causalChain.lanes.firstIndex {
            !$0.attempted && $0.lane == AutomaticSyncDiagnosticLane(workLane: lane)
        }
        queryStarted = false
        if let activeLaneIndex { causalChain.lanes[activeLaneIndex].attempted = true }
    }

    public func noteQueryStarted() { queryStarted = true }

    public func noteQuery(_ outcome: AutomaticSyncQueryOutcome, newestSampleAge: TimeInterval?, now: Date = Date()) {
        guard let activeLaneIndex else { return }
        queryStarted = false
        causalChain.lanes[activeLaneIndex].noteQuery(outcome, newestSampleAge: newestSampleAge, now: now)
    }

    public func noteQueued(itemIDs: [UUID], complete: Bool, now: Date = Date()) {
        guard let activeLaneIndex else { return }
        causalChain.lanes[activeLaneIndex].noteQueued(itemIDs: itemIDs, complete: complete, now: now)
        causalChain.truncated = causalChain.truncated || causalChain.lanes[activeLaneIndex].truncated
    }

    public func noteDelivery(_ outcome: AutomaticSyncDeliveryOutcome, now: Date = Date()) {
        guard let activeLaneIndex else { return }
        causalChain.lanes[activeLaneIndex].noteDelivery(outcome, now: now)
    }

    public func noteDelivery(itemID: UUID, outcome: AutomaticSyncDeliveryOutcome, now: Date = Date()) {
        causalChain.noteDelivery(itemID: itemID, outcome: outcome, now: now)
    }

    public func noteLaneFailure(_ failure: AutomaticSyncDiagnosticFailure) {
        guard let activeLaneIndex else { return }
        let cancelled = failure.category == .cancellation
        if queryStarted {
            noteQuery(cancelled ? .cancelled : .failed, newestSampleAge: nil)
        }
        if failure.stage == .transport {
            noteDelivery(cancelled ? .cancelled : .failed)
        } else if failure.stage == .store, causalChain.lanes[activeLaneIndex].outbox == .notRun {
            causalChain.lanes[activeLaneIndex].outbox = .failed
        }
    }

    public func checkpoint(using store: AutomaticSyncDiagnosticStore) {
        // Observer diagnostics remain memory-only until HealthKit acknowledgement.
        guard !defersPersistenceUntilObserverAcknowledgement else { return }
        _ = store.recordFinal(record)
    }

    /// Called only after the settings-store accepted-marker write succeeds.
    public func noteRunAccepted() {
        causalChain.durableAdmission = .persisted
        runOutcome = .accepted
    }

    public func noteCompletion(
        _ outcome: AutomaticSyncDiagnosticRunOutcome
    ) {
        runOutcome = outcome
        defaultUnknownFailureIfNeeded(for: outcome)
    }

    public func noteCompletion(
        _ outcome: AutomaticSyncDiagnosticRunOutcome,
        remainingPendingSnapshot: AutomaticSyncPendingSnapshot
    ) {
        runOutcome = outcome
        remainingPendingLaneCount = remainingPendingSnapshot.pendingLaneCount
        if let recovery = remainingPendingSnapshot.recovery { causalChain.remainingRecoveryPending = recovery }
        defaultUnknownFailureIfNeeded(for: outcome)
    }

    func noteCompletionForDeferredPersistence(
        _ outcome: AutomaticSyncDiagnosticRunOutcome,
        remainingPendingTypeCodes: [String],
        recovery: BackgroundObserverPendingDiagnostic? = nil
    ) {
        runOutcome = outcome
        remainingPendingTypeCodesForDeferredPersistence = remainingPendingTypeCodes
        if let recovery { causalChain.remainingRecoveryPending = recovery }
        defaultUnknownFailureIfNeeded(for: outcome)
    }

    public func noteFailure(_ failure: AutomaticSyncDiagnosticFailure) {
        self.failure = failure
        noteLaneFailure(failure)
    }

    func prepareDeferredPendingSnapshots(
        using store: AutomaticSyncDiagnosticStore
    ) {
        let remainingRecovery = causalChain.remainingRecoveryPending
        if let pendingTypeCodesForDeferredPersistence {
            notePending(
                store.pendingSnapshot(
                    pendingTypeCodes: pendingTypeCodesForDeferredPersistence,
                    recovery: causalChain.initialRecoveryPending
                )
            )
        }
        if let remainingPendingTypeCodesForDeferredPersistence {
            remainingPendingLaneCount = store.pendingSnapshot(
                pendingTypeCodes: remainingPendingTypeCodesForDeferredPersistence,
                recovery: remainingRecovery
            ).pendingLaneCount
            causalChain.remainingRecoveryPending = remainingRecovery
        }
    }

    func noteObserverCompletionLatency(_ latency: TimeInterval) {
        guard wakeSource == .healthKitObserver else { return }
        observerCompletionLatencyBucket = .bucket(for: latency)
    }

    var defersPersistenceUntilObserverAcknowledgement: Bool {
        wakeSource == .healthKitObserver && observerCompletionLatencyBucket == .pending
    }

    public var record: AutomaticSyncDiagnosticRecord {
        AutomaticSyncDiagnosticRecord(
            runID: runID,
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
            failure: failure,
            remainingPendingLaneCount: remainingPendingLaneCount,
            causalChain: causalChain
        )
    }

    private func defaultUnknownFailureIfNeeded(
        for outcome: AutomaticSyncDiagnosticRunOutcome
    ) {
        guard outcome == .failed, failure == nil else { return }
        failure = .unknown
    }

    private static func triggerLane(
        for typeCodes: [String]
    ) -> AutomaticSyncDiagnosticLane? {
        let lanes = Set(typeCodes.map { AutomaticSyncDiagnosticLane(typeCode: $0) })
        if lanes.count > 1 { return .mixed }
        return lanes.first
    }
}

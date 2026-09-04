import Foundation

public enum BackgroundQuantitySyncStatus: Equatable, Sendable {
    case noWork
    case succeeded(typeCodes: [String])
    case failed(typeCodes: [String])

    public var summaryFragment: String? {
        switch self {
        case .noWork:
            return nil
        case .succeeded(let typeCodes):
            return "quantities=ok(\(Self.typeCodeList(typeCodes)))"
        case .failed(let typeCodes):
            return "quantities=failed(\(Self.typeCodeList(typeCodes)))"
        }
    }

    public var isFailure: Bool {
        switch self {
        case .failed:
            return true
        case .noWork, .succeeded:
            return false
        }
    }

    private static func typeCodeList(_ typeCodes: [String]) -> String {
        let normalized = Array(Set(typeCodes)).sorted()
        return normalized.isEmpty ? "none" : normalized.joined(separator: ",")
    }
}

public struct BackgroundDeliveryRegistrationPlan: Equatable, Sendable {
    public let observedHealthTypes: [HealthBridgeHealthType]

    public init(observedHealthTypes: [HealthBridgeHealthType]) {
        self.observedHealthTypes = observedHealthTypes
    }
}

public enum AutomaticSyncReason: Equatable, Sendable {
    case observer(typeCode: String)
    case observerBatch(typeCodes: [String])
    case scheduledRefresh
    case launchCatchUp

    public var observerTypeCodes: [String] {
        switch self {
        case .observer(let typeCode):
            return [typeCode]
        case .observerBatch(let typeCodes):
            return typeCodes
        case .scheduledRefresh, .launchCatchUp:
            return []
        }
    }
}

public enum BackgroundSyncWorkLane: Equatable, Sendable {
    case steps
    case dailyActivity
    case workouts
    case sleep
    case quantity(typeCode: String)

    public var id: String {
        switch self {
        case .steps:
            return "steps"
        case .dailyActivity:
            return "daily_activity"
        case .workouts:
            return "workouts"
        case .sleep:
            return "sleep"
        case .quantity(let typeCode):
            return "quantity:\(typeCode)"
        }
    }
}

public struct BackgroundSyncWorkPlan: Equatable, Sendable {
    public let lane: BackgroundSyncWorkLane?
    public let coveredObserverTypeCodes: [String]
    public let nextScheduledLaneID: String?

    public init(
        lane: BackgroundSyncWorkLane?,
        coveredObserverTypeCodes: [String],
        nextScheduledLaneID: String?
    ) {
        self.lane = lane
        self.coveredObserverTypeCodes = coveredObserverTypeCodes
        self.nextScheduledLaneID = nextScheduledLaneID
    }
}

public enum HealthBridgeSyncExecutionMode: Equatable, Sendable {
    case foreground
    case automatic

    public var shouldRequestReadAuthorization: Bool {
        self == .foreground
    }

    public var cursorlessFallbackDays: Int? {
        self == .automatic ? 1 : nil
    }

    public func shouldPersistSharedProgress(hadUsableCursor: Bool) -> Bool {
        self == .foreground || hadUsableCursor
    }
}

public struct AutomaticQuantitySyncPlan: Equatable, Sendable {
    public let typeCodes: [String]
    public let fallbackHistoryDepth: HealthHistoryDepth

    public init(typeCodes: [String], fallbackHistoryDepth: HealthHistoryDepth) {
        self.typeCodes = typeCodes
        self.fallbackHistoryDepth = fallbackHistoryDepth
    }
}

public enum HealthBridgeBackgroundSync {
    public static var appRefreshIdentifier: String {
        HealthBridgeAppIdentity.appRefreshIdentifier
    }
    public static let defaultMinimumInterval: TimeInterval = 15 * 60
    public static let defaultRunDebounceInterval: TimeInterval = 10 * 60
    public static let defaultObservedHealthTypes: [HealthBridgeHealthType] = [.steps, .workouts, .sleepAnalysis]
    public static let dailyActivityTypeCodes = [
        "basal_energy",
        "distance_walking_running",
        "energy",
        "exercise_time",
        "flights_climbed",
        "stand_time",
        "steps",
    ]

    public static var supportedAutomaticQuantityTypeCodes: [String] {
        GenericQuantityCoveragePolicy.supportedQuantityEntries().map(\.typeCode)
    }

    public static var supportedUnifiedReadTypeCodes: [String] {
        Array(Set(
            HealthBridgeHealthType.dedicatedSyncTypes.map(\.typeCode)
                + supportedAutomaticQuantityTypeCodes
        )).sorted()
    }

    public static func automaticQuantitySyncPlan(
        availableTypeCodes: [String],
        observedTypeCodes: [String],
        reason: AutomaticSyncReason
    ) -> AutomaticQuantitySyncPlan {
        let supported = Set(supportedAutomaticQuantityTypeCodes)
        let available = Set(
            GenericQuantityCoveragePolicy.canonicalTypeCodes(for: availableTypeCodes)
                .filter { supported.contains($0) }
        )
        let observed = Set(
            GenericQuantityCoveragePolicy.canonicalTypeCodes(for: observedTypeCodes)
                .filter { available.contains($0) }
        )

        let selected: Set<String>
        switch reason {
        case .observer, .observerBatch:
            let trigger = Set(
                GenericQuantityCoveragePolicy.canonicalTypeCodes(for: reason.observerTypeCodes)
                    .filter { available.contains($0) }
            )
            selected = observed.union(trigger)
        case .scheduledRefresh, .launchCatchUp:
            selected = available
        }
        return AutomaticQuantitySyncPlan(
            typeCodes: selected.sorted(),
            fallbackHistoryDepth: .lastDays(1)
        )
    }

    public static func workPlan(
        reason: AutomaticSyncReason,
        availableQuantityTypeCodes: [String],
        pendingObserverTypeCodes: [String],
        continuationLaneID: String?
    ) -> BackgroundSyncWorkPlan {
        let availableQuantityTypeCodeSet = Set(
            GenericQuantityCoveragePolicy.canonicalSupportedTypeCodes(
                availableQuantityTypeCodes
            )
        )
        let scheduledLanes = scheduledWorkLanes(
            availableQuantityTypeCodes: Array(availableQuantityTypeCodeSet)
        )
        let normalizedPendingTypeCodes = GenericQuantityCoveragePolicy
            .canonicalTypeCodes(for: pendingObserverTypeCodes)

        switch reason {
        case .observer:
            let triggerTypeCodes = GenericQuantityCoveragePolicy.canonicalTypeCodes(
                for: reason.observerTypeCodes
            )
            let selectedLane = scheduledLanes.first { candidate in
                triggerTypeCodes.contains { typeCode in
                    workLane(
                        for: typeCode,
                        availableQuantityTypeCodeSet: availableQuantityTypeCodeSet
                    ) == candidate
                }
            }
            let coveredTypeCodes = triggerTypeCodes.filter { typeCode in
                guard let mappedLane = workLane(
                    for: typeCode,
                    availableQuantityTypeCodeSet: availableQuantityTypeCodeSet
                ) else {
                    return false
                }
                return mappedLane == selectedLane
            }
            return BackgroundSyncWorkPlan(
                lane: selectedLane,
                coveredObserverTypeCodes: coveredTypeCodes,
                nextScheduledLaneID: nil
            )
        case .observerBatch:
            let triggerTypeCodes = GenericQuantityCoveragePolicy.canonicalTypeCodes(
                for: reason.observerTypeCodes
            )
            let dirtyTypeCodes = GenericQuantityCoveragePolicy.canonicalTypeCodes(
                for: triggerTypeCodes + normalizedPendingTypeCodes
            )
            return circularDirtyWorkPlan(
                scheduledLanes: scheduledLanes,
                dirtyTypeCodes: dirtyTypeCodes,
                availableQuantityTypeCodeSet: availableQuantityTypeCodeSet,
                continuationLaneID: continuationLaneID
            ) ?? BackgroundSyncWorkPlan(
                lane: nil,
                coveredObserverTypeCodes: [],
                nextScheduledLaneID: nil
            )
        case .scheduledRefresh, .launchCatchUp:
            let continuationIndex = continuationLaneID.flatMap { laneID in
                scheduledLanes.firstIndex { $0.id == laneID }
            } ?? scheduledLanes.startIndex
            let continuationLane = scheduledLanes[continuationIndex]
            if let dirtyPlan = circularDirtyWorkPlan(
                scheduledLanes: scheduledLanes,
                dirtyTypeCodes: normalizedPendingTypeCodes,
                availableQuantityTypeCodeSet: availableQuantityTypeCodeSet,
                continuationLaneID: continuationLaneID
            ) {
                return dirtyPlan
            }
            let nextIndex = scheduledLanes.index(after: continuationIndex)
            let nextLane = nextIndex == scheduledLanes.endIndex
                ? scheduledLanes[scheduledLanes.startIndex]
                : scheduledLanes[nextIndex]
            return BackgroundSyncWorkPlan(
                lane: continuationLane,
                coveredObserverTypeCodes: [],
                nextScheduledLaneID: nextLane.id
            )
        }
    }

    private static func circularDirtyWorkPlan(
        scheduledLanes: [BackgroundSyncWorkLane],
        dirtyTypeCodes: [String],
        availableQuantityTypeCodeSet: Set<String>,
        continuationLaneID: String?
    ) -> BackgroundSyncWorkPlan? {
        let continuationIndex = continuationLaneID.flatMap { laneID in
            scheduledLanes.firstIndex { $0.id == laneID }
        } ?? scheduledLanes.startIndex

        for offset in scheduledLanes.indices {
            let candidateIndex = (continuationIndex + offset) % scheduledLanes.count
            let candidateLane = scheduledLanes[candidateIndex]
            let coveredTypeCodes = dirtyTypeCodes.filter { typeCode in
                workLane(
                    for: typeCode,
                    availableQuantityTypeCodeSet: availableQuantityTypeCodeSet
                ) == candidateLane
            }
            guard !coveredTypeCodes.isEmpty else { continue }

            let successorIndex = (candidateIndex + 1) % scheduledLanes.count
            return BackgroundSyncWorkPlan(
                lane: candidateLane,
                coveredObserverTypeCodes: coveredTypeCodes,
                nextScheduledLaneID: scheduledLanes[successorIndex].id
            )
        }
        return nil
    }

    public static var observedHealthTypes: [HealthBridgeHealthType] {
        defaultObservedHealthTypes
    }

    public static var allKnownBackgroundDeliveryHealthTypes: [HealthBridgeHealthType] {
        appendUnique(
            defaultObservedHealthTypes,
            automaticQuantityHealthTypes(typeCodes: supportedAutomaticQuantityTypeCodes)
        )
    }

    public static func observedHealthTypes(
        automaticQuantityTypeCodes: [String]
    ) -> [HealthBridgeHealthType] {
        appendUnique(
            defaultObservedHealthTypes,
            automaticQuantityHealthTypes(typeCodes: automaticQuantityTypeCodes)
        )
    }

    public static func backgroundDeliveryRegistrationPlan(
        automaticQuantityTypeCodes: [String]
    ) -> BackgroundDeliveryRegistrationPlan {
        BackgroundDeliveryRegistrationPlan(
            observedHealthTypes: observedHealthTypes(
                automaticQuantityTypeCodes: automaticQuantityTypeCodes
            )
        )
    }

    public static func refreshSummary(
        succeeded: Bool,
        stepsSucceeded: Bool,
        dailyActivitySucceeded: Bool,
        workoutsSucceeded: Bool,
        sleepSucceeded: Bool,
        pendingOutboxCount: Int,
        quantityStatus: BackgroundQuantitySyncStatus = .noWork
    ) -> String {
        var laneParts = [
            "steps=\(stepsSucceeded ? "ok" : "failed")",
            "daily_activity=\(dailyActivitySucceeded ? "ok" : "failed")",
            "workouts=\(workoutsSucceeded ? "ok" : "failed")",
            "sleep=\(sleepSucceeded ? "ok" : "failed")",
        ]
        if let quantityFragment = quantityStatus.summaryFragment {
            laneParts.append(quantityFragment)
        }
        laneParts.append("pending_outbox=\(pendingOutboxCount)")
        return "Background refresh \(succeeded ? "completed" : "finished with errors"): "
            + laneParts.joined(separator: ", ")
            + "."
    }

    public static func nextEarliestBeginDate(
        enabled: Bool,
        now: Date = Date(),
        minimumInterval: TimeInterval = defaultMinimumInterval
    ) -> Date? {
        guard enabled else { return nil }
        return now.addingTimeInterval(minimumInterval)
    }

    private static func automaticQuantityHealthTypes(
        typeCodes: [String]
    ) -> [HealthBridgeHealthType] {
        GenericQuantityCoveragePolicy.coveragePlan(availableTypeCodes: typeCodes)
            .availableEntries
            .map(HealthKitTypeCatalog.healthType(from:))
    }

    private static func scheduledWorkLanes(
        availableQuantityTypeCodes: [String]
    ) -> [BackgroundSyncWorkLane] {
        [
            .steps,
            .dailyActivity,
            .workouts,
            .sleep,
        ] + availableQuantityTypeCodes.sorted().map {
            .quantity(typeCode: $0)
        }
    }

    private static func workLane(
        for typeCode: String,
        availableQuantityTypeCodeSet: Set<String>
    ) -> BackgroundSyncWorkLane? {
        switch typeCode {
        case HealthBridgeHealthType.steps.typeCode:
            return .steps
        case HealthBridgeHealthType.workouts.typeCode:
            return .workouts
        case HealthBridgeHealthType.sleepAnalysis.typeCode:
            return .sleep
        default:
            if dailyActivityTypeCodes.contains(typeCode) {
                return .dailyActivity
            }
            guard availableQuantityTypeCodeSet.contains(typeCode) else {
                return nil
            }
            return .quantity(typeCode: typeCode)
        }
    }

    private static func appendUnique(
        _ base: [HealthBridgeHealthType],
        _ additions: [HealthBridgeHealthType]
    ) -> [HealthBridgeHealthType] {
        var seen = Set(base.map(\.typeCode))
        var result = base
        for healthType in additions where !seen.contains(healthType.typeCode) {
            result.append(healthType)
            seen.insert(healthType.typeCode)
        }
        return result
    }
}

public enum BackgroundSyncRunSkipReason: Equatable, Sendable {
    case alreadyRunning
    case debounced

    public var userDescription: String {
        switch self {
        case .alreadyRunning:
            return "another background refresh is already running"
        case .debounced:
            return "a background refresh already ran recently"
        }
    }
}

public struct BackgroundSyncRunAdmission: Equatable, Sendable {
    public let shouldRun: Bool
    public let startedAt: Date?
    public let skipReason: BackgroundSyncRunSkipReason?

    public static func accepted(startedAt: Date) -> BackgroundSyncRunAdmission {
        BackgroundSyncRunAdmission(shouldRun: true, startedAt: startedAt, skipReason: nil)
    }

    public static func skipped(_ reason: BackgroundSyncRunSkipReason) -> BackgroundSyncRunAdmission {
        BackgroundSyncRunAdmission(shouldRun: false, startedAt: nil, skipReason: reason)
    }
}

public enum BackgroundSyncRunCompletion: Equatable, Sendable {
    case succeeded
    case interrupted
}

public actor BackgroundSyncRunGate {
    private let minimumSpacing: TimeInterval
    private var isRunning = false
    private var mostRecentStartedAt: Date?
    private var pendingObserverTypeCodes: Set<String> = []
    private var activeObserverTypeCodes: Set<String> = []

    public init(minimumSpacing: TimeInterval = HealthBridgeBackgroundSync.defaultRunDebounceInterval) {
        self.minimumSpacing = minimumSpacing
    }

    public func beginRun(now: Date = Date()) -> BackgroundSyncRunAdmission {
        beginRun(reason: .scheduledRefresh, now: now)
    }

    public func beginRun(
        reason: AutomaticSyncReason,
        now: Date = Date()
    ) -> BackgroundSyncRunAdmission {
        let observerTypeCodes = GenericQuantityCoveragePolicy.canonicalTypeCodes(
            for: reason.observerTypeCodes
        )
        if isRunning {
            pendingObserverTypeCodes.formUnion(observerTypeCodes)
            return .skipped(.alreadyRunning)
        }

        if let mostRecentStartedAt,
           now.timeIntervalSince(mostRecentStartedAt) < minimumSpacing {
            pendingObserverTypeCodes.formUnion(observerTypeCodes)
            return .skipped(.debounced)
        }

        isRunning = true
        mostRecentStartedAt = now
        activeObserverTypeCodes = Set(observerTypeCodes)
        pendingObserverTypeCodes.subtract(observerTypeCodes)
        return .accepted(startedAt: now)
    }

    @discardableResult
    public func finishRun(_ completion: BackgroundSyncRunCompletion) -> [String] {
        isRunning = false
        let preservingPendingObserverTypeCodes = completion == .interrupted
        if preservingPendingObserverTypeCodes {
            pendingObserverTypeCodes.formUnion(activeObserverTypeCodes)
        }
        activeObserverTypeCodes.removeAll()
        let pending = pendingObserverTypeCodes.sorted()
        if !preservingPendingObserverTypeCodes {
            pendingObserverTypeCodes.removeAll()
        }
        return pending
    }

    public func finishBoundedRun(
        completedObserverTypeCodes: [String]
    ) -> [String] {
        isRunning = false
        let completedTypeCodes = Set(
            GenericQuantityCoveragePolicy.canonicalTypeCodes(
                for: completedObserverTypeCodes
            )
        )
        pendingObserverTypeCodes.formUnion(
            activeObserverTypeCodes.subtracting(completedTypeCodes)
        )
        activeObserverTypeCodes.removeAll()
        return pendingObserverTypeCodes.sorted()
    }

    public func pendingObserverTypeCodesSnapshot() -> [String] {
        pendingObserverTypeCodes.sorted()
    }

    public func hasActiveRun() -> Bool {
        isRunning
    }

    public func retainObserverTypeCodes(_ typeCodes: [String]) {
        pendingObserverTypeCodes.formUnion(
            GenericQuantityCoveragePolicy.canonicalTypeCodes(for: typeCodes)
        )
    }

    public func remainingSpacing(now: Date = Date()) -> TimeInterval {
        guard let mostRecentStartedAt else { return 0 }
        return max(0, minimumSpacing - now.timeIntervalSince(mostRecentStartedAt))
    }
}

public enum BackgroundUploadCancellationPolicy {
    public static func canBeginDirectTransfer(
        cancellationWasFullyFinalized: Bool,
        hasPendingUploadTasks: Bool
    ) -> Bool {
        cancellationWasFullyFinalized && !hasPendingUploadTasks
    }
}

public enum BackgroundUploadCancellationCertificationPolicy {
    public static func canCertifyFullyFinalized(
        barrierFinalized: Bool,
        eventCycleFinalized: Bool,
        finalTaskSetIsEmpty: Bool,
        finalCoordinatorIsIdle: Bool,
        coordinatorGenerationIsStable: Bool,
        introducedTaskAfterWait: Bool
    ) -> Bool {
        barrierFinalized
            && eventCycleFinalized
            && finalTaskSetIsEmpty
            && finalCoordinatorIsIdle
            && coordinatorGenerationIsStable
            && !introducedTaskAfterWait
    }
}

public enum AutomaticSyncPayloadGenerationPolicy {
    public static func shouldGenerateNewPayloads(
        trustedPendingOutboxCount: Int?
    ) -> Bool {
        trustedPendingOutboxCount == 0
    }

    public static func shouldStopQuantityLoop(
        isAutomaticSync: Bool,
        hasDurablyQueuedPayload: Bool
    ) -> Bool {
        isAutomaticSync && hasDurablyQueuedPayload
    }

    public static func didCreateDurableFIFOHead(
        pendingBefore: Int?,
        pendingAfter: Int?
    ) -> Bool {
        guard let pendingBefore, let pendingAfter else { return false }
        return pendingAfter > pendingBefore
    }
}

public enum AutomaticSyncMailboxReconciliationPoint: Equatable, Sendable {
    case beforePayloadGeneration
    case afterDurableEnqueue
}

public enum AutomaticSyncMailboxDeliveryPhase: Equatable, Sendable {
    case advanceOrReconcileFIFOHead
    case publishFIFOHead
}

public enum AutomaticSyncBackgroundOpportunityPolicy {
    public static func deliveryPhase(
        usesMailboxTransport: Bool,
        at point: AutomaticSyncMailboxReconciliationPoint
    ) -> AutomaticSyncMailboxDeliveryPhase? {
        guard usesMailboxTransport else { return nil }
        switch point {
        case .beforePayloadGeneration:
            return .advanceOrReconcileFIFOHead
        case .afterDurableEnqueue:
            return .publishFIFOHead
        }
    }
}

public enum AutomaticSyncMailboxReconciliationResult: Equatable, Sendable {
    case completed(pendingCount: Int)
    case terminalHold(pendingCount: Int)
    case failed
    case cancelled

    public var lifecycleOutcome: BackgroundSyncRunOutcome {
        switch self {
        case .completed:
            return .completed
        case .terminalHold, .failed, .cancelled:
            return .interrupted
        }
    }

    public var lifecycleSucceeded: Bool {
        if case .completed = self { return true }
        return false
    }

    public var isTerminalHold: Bool {
        if case .terminalHold = self { return true }
        return false
    }

    public var shouldScheduleRetry: Bool {
        switch self {
        case .completed, .failed:
            return true
        case .terminalHold, .cancelled:
            return false
        }
    }

    public var pendingCount: Int? {
        switch self {
        case .completed(let pendingCount), .terminalHold(let pendingCount):
            return pendingCount
        case .failed, .cancelled:
            return nil
        }
    }
}

@MainActor
public enum AutomaticSyncDisableCoordinator {
    public static func disable(
        publishDisabled: () -> Void,
        stopObserverDelivery: () -> Void,
        persistDisabled: () throws -> Void,
        cancelForegroundPayloads: () async -> Void,
        cancelBackgroundPayloads: () async -> Void
    ) async throws {
        publishDisabled()
        stopObserverDelivery()
        let persistenceResult = Result { try persistDisabled() }
        await cancelForegroundPayloads()
        await cancelBackgroundPayloads()
        try persistenceResult.get()
    }
}

public enum BackgroundSyncRunOutcome: String, Equatable, Sendable {
    case accepted
    case skipped
    case interrupted
    case completed
}

public struct BackgroundSyncLastRun: Equatable {
    public let startedAt: String
    public let finishedAt: String?
    public let outcome: BackgroundSyncRunOutcome
    public let succeeded: Bool
    public let summary: String

    public init(
        startedAt: String,
        finishedAt: String?,
        succeeded: Bool,
        summary: String,
        outcome: BackgroundSyncRunOutcome = .completed
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.succeeded = succeeded
        self.summary = summary
    }

    public var userVisibleSummary: String {
        switch outcome {
        case .accepted:
            return "Last background sync started but did not finish."
        case .skipped:
            return "Last background sync was skipped."
        case .interrupted:
            return "Last background sync was interrupted."
        case .completed:
            return succeeded
                ? "Last background sync completed."
                : "Last background sync did not complete."
        }
    }
}

public struct BackgroundDeliveryRegistrationStatus: Equatable {
    public let attemptedAt: String
    public let succeeded: Bool
    public let summary: String

    public init(attemptedAt: String, succeeded: Bool, summary: String) {
        self.attemptedAt = attemptedAt
        self.succeeded = succeeded
        self.summary = summary
    }
}

public struct BackgroundTaskScheduleStatus: Equatable {
    public let attemptedAt: String
    public let status: String
    public let summary: String

    public init(attemptedAt: String, status: String, summary: String) {
        self.attemptedAt = attemptedAt
        self.status = status
        self.summary = summary
    }
}

public struct BackgroundWakeEvent: Equatable {
    public let enteredAt: String
    public let source: String
    public let summary: String

    public init(enteredAt: String, source: String, summary: String) {
        self.enteredAt = enteredAt
        self.source = source
        self.summary = summary
    }
}

public enum BackgroundSyncSettingsStoreError: Error, Equatable {
    case persistenceFailed
}

public protocol BackgroundSyncDisableIntentStoring: AnyObject {
    var isDisableIntentPending: Bool { get }
    func markDisableIntentPending() throws
    func clearDisableIntent() throws
}

public final class FileBackgroundSyncDisableIntentStore: BackgroundSyncDisableIntentStoring {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public convenience init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.init(
            fileURL: applicationSupport
                .appendingPathComponent("HealthBridgeCompanion", isDirectory: true)
                .appendingPathComponent("automatic-sync-disable-intent", isDirectory: false),
            fileManager: fileManager
        )
    }

    public var isDisableIntentPending: Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    public func markDisableIntentPending() throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("disabled\n".utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func clearDisableIntent() throws {
        guard isDisableIntentPending else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

private final class EphemeralBackgroundSyncDisableIntentStore:
    BackgroundSyncDisableIntentStoring
{
    private var pending = false

    var isDisableIntentPending: Bool { pending }

    func markDisableIntentPending() {
        pending = true
    }

    func clearDisableIntent() {
        pending = false
    }
}

public protocol BackgroundObserverDirtinessStoring: AnyObject {
    func loadGenerations() throws -> [String: Int]
    func saveGenerations(_ generations: [String: Int]) throws
}

public final class FileBackgroundObserverDirtinessStore:
    BackgroundObserverDirtinessStoring
{
    private struct Snapshot: Codable {
        let version: Int
        let generations: [String: Int]
    }

    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public convenience init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.init(
            fileURL: applicationSupport
                .appendingPathComponent("HealthBridgeCompanion", isDirectory: true)
                .appendingPathComponent("observer-dirtiness.json", isDirectory: false),
            fileManager: fileManager
        )
    }

    public func loadGenerations() throws -> [String: Int] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let snapshot = try JSONDecoder().decode(
            Snapshot.self,
            from: Data(contentsOf: fileURL)
        )
        guard snapshot.version == 1 else {
            throw BackgroundSyncSettingsStoreError.persistenceFailed
        }
        return snapshot.generations
    }

    public func saveGenerations(_ generations: [String: Int]) throws {
        if generations.isEmpty {
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Snapshot(version: 1, generations: generations)
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableFileURL = fileURL
        try mutableFileURL.setResourceValues(resourceValues)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}

private final class UserDefaultsBackgroundObserverDirtinessStore:
    BackgroundObserverDirtinessStoring
{
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults, key: String) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadGenerations() throws -> [String: Int] {
        let persisted = userDefaults.dictionary(forKey: key) ?? [:]
        var generations: [String: Int] = [:]
        for (typeCode, rawGeneration) in persisted {
            if let generation = rawGeneration as? Int {
                generations[typeCode] = generation
            } else if let generation = rawGeneration as? NSNumber {
                generations[typeCode] = generation.intValue
            }
        }
        return generations
    }

    func saveGenerations(_ generations: [String: Int]) throws {
        if generations.isEmpty {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(generations, forKey: key)
        }
        guard userDefaults.synchronize() else {
            throw BackgroundSyncSettingsStoreError.persistenceFailed
        }
    }
}

public final class BackgroundSyncSettingsStore {
    private enum Key {
        static let isEnabled = "healthBridge.backgroundSync.enabled"
        static let lastStartedAt = "healthBridge.backgroundSync.lastStartedAt"
        static let lastFinishedAt = "healthBridge.backgroundSync.lastFinishedAt"
        static let lastOutcome = "healthBridge.backgroundSync.lastOutcome"
        static let lastSucceeded = "healthBridge.backgroundSync.lastSucceeded"
        static let lastSummary = "healthBridge.backgroundSync.lastSummary"
        static let lastSelectedLane = "healthBridge.backgroundSync.lastSelectedLane"
        static let lastSkippedStartedAt =
            "healthBridge.backgroundSync.lastSkippedStartedAt"
        static let lastSkippedFinishedAt =
            "healthBridge.backgroundSync.lastSkippedFinishedAt"
        static let lastSkippedSummary =
            "healthBridge.backgroundSync.lastSkippedSummary"
        static let lastRegistrationAttemptedAt = "healthBridge.backgroundDelivery.lastRegistrationAttemptedAt"
        static let lastRegistrationSucceeded = "healthBridge.backgroundDelivery.lastRegistrationSucceeded"
        static let lastRegistrationSummary = "healthBridge.backgroundDelivery.lastRegistrationSummary"
        static let lastTaskScheduleAttemptedAt = "healthBridge.bgTask.lastScheduleAttemptedAt"
        static let lastTaskScheduleStatus = "healthBridge.bgTask.lastScheduleStatus"
        static let lastTaskScheduleSummary = "healthBridge.bgTask.lastScheduleSummary"
        static let lastWakeEnteredAt = "healthBridge.backgroundWake.lastEnteredAt"
        static let lastWakeSource = "healthBridge.backgroundWake.lastSource"
        static let lastWakeSummary = "healthBridge.backgroundWake.lastSummary"
        static let pendingObserverTypeCodeGenerations =
            "healthBridge.backgroundSync.pendingObserverTypeCodeGenerations"
        static let nextScheduledWorkLaneID =
            "healthBridge.backgroundSync.nextScheduledWorkLaneID"
        static let mailboxAckScanCheckpoint =
            "healthBridge.backgroundSync.mailboxAckScanCheckpoint"
        static let mailboxAckScanCheckpointGeneration =
            "healthBridge.backgroundSync.mailboxAckScanCheckpointGeneration"
    }

    private let userDefaults: UserDefaults
    private let disableIntentStore: any BackgroundSyncDisableIntentStoring
    private let observerDirtinessStore: any BackgroundObserverDirtinessStoring
    private let observerDirtinessUsesUserDefaults: Bool
    private let dateFormatter: ISO8601DateFormatter

    public convenience init() {
        self.init(
            userDefaults: .standard,
            disableIntentStore: FileBackgroundSyncDisableIntentStore(),
            observerDirtinessStore: FileBackgroundObserverDirtinessStore()
        )
    }

    public init(
        userDefaults: UserDefaults,
        disableIntentStore: (any BackgroundSyncDisableIntentStoring)? = nil,
        observerDirtinessStore: (any BackgroundObserverDirtinessStoring)? = nil
    ) {
        self.userDefaults = userDefaults
        self.disableIntentStore = disableIntentStore
            ?? EphemeralBackgroundSyncDisableIntentStore()
        if let observerDirtinessStore {
            self.observerDirtinessStore = observerDirtinessStore
            self.observerDirtinessUsesUserDefaults = false
        } else {
            self.observerDirtinessStore = UserDefaultsBackgroundObserverDirtinessStore(
                userDefaults: userDefaults,
                key: Key.pendingObserverTypeCodeGenerations
            )
            self.observerDirtinessUsesUserDefaults = true
        }
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime]
        self.dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    }

    public var isEnabled: Bool {
        !disableIntentStore.isDisableIntentPending
            && userDefaults.bool(forKey: Key.isEnabled)
    }

    public var lastRun: BackgroundSyncLastRun? {
        guard
            let startedAt = userDefaults.string(forKey: Key.lastStartedAt),
            let summary = userDefaults.string(forKey: Key.lastSummary)
        else {
            return nil
        }
        let outcome = userDefaults.string(forKey: Key.lastOutcome)
            .flatMap(BackgroundSyncRunOutcome.init(rawValue:))
            ?? .completed
        return BackgroundSyncLastRun(
            startedAt: startedAt,
            finishedAt: userDefaults.string(forKey: Key.lastFinishedAt),
            succeeded: userDefaults.bool(forKey: Key.lastSucceeded),
            summary: summary,
            outcome: outcome
        )
    }

    var lastSelectedLane: AutomaticSyncDiagnosticLane? {
        userDefaults.string(forKey: Key.lastSelectedLane)
            .flatMap(AutomaticSyncDiagnosticLane.init(rawValue:))
    }

    public var lastRegistration: BackgroundDeliveryRegistrationStatus? {
        guard
            let attemptedAt = userDefaults.string(forKey: Key.lastRegistrationAttemptedAt),
            let summary = userDefaults.string(forKey: Key.lastRegistrationSummary)
        else {
            return nil
        }
        return BackgroundDeliveryRegistrationStatus(
            attemptedAt: attemptedAt,
            succeeded: userDefaults.bool(forKey: Key.lastRegistrationSucceeded),
            summary: summary
        )
    }

    public var lastSkippedRun: BackgroundSyncLastRun? {
        guard
            let startedAt = userDefaults.string(forKey: Key.lastSkippedStartedAt),
            let finishedAt = userDefaults.string(forKey: Key.lastSkippedFinishedAt),
            let summary = userDefaults.string(forKey: Key.lastSkippedSummary)
        else {
            return nil
        }
        return BackgroundSyncLastRun(
            startedAt: startedAt,
            finishedAt: finishedAt,
            succeeded: false,
            summary: summary,
            outcome: .skipped
        )
    }

    public var lastTaskSchedule: BackgroundTaskScheduleStatus? {
        guard
            let attemptedAt = userDefaults.string(forKey: Key.lastTaskScheduleAttemptedAt),
            let status = userDefaults.string(forKey: Key.lastTaskScheduleStatus),
            let summary = userDefaults.string(forKey: Key.lastTaskScheduleSummary)
        else {
            return nil
        }
        return BackgroundTaskScheduleStatus(
            attemptedAt: attemptedAt,
            status: status,
            summary: summary
        )
    }

    public var lastWakeEvent: BackgroundWakeEvent? {
        guard
            let enteredAt = userDefaults.string(forKey: Key.lastWakeEnteredAt),
            let source = userDefaults.string(forKey: Key.lastWakeSource),
            let summary = userDefaults.string(forKey: Key.lastWakeSummary)
        else {
            return nil
        }
        return BackgroundWakeEvent(
            enteredAt: enteredAt,
            source: source,
            summary: summary
        )
    }

    public func loadPendingObserverTypeCodeGenerations() throws -> [String: Int] {
        var persisted = try observerDirtinessStore.loadGenerations()
        if !observerDirtinessUsesUserDefaults {
            let legacyStore = UserDefaultsBackgroundObserverDirtinessStore(
                userDefaults: userDefaults,
                key: Key.pendingObserverTypeCodeGenerations
            )
            for (typeCode, generation) in try legacyStore.loadGenerations() {
                persisted[typeCode] = max(generation, persisted[typeCode] ?? 0)
            }
        }
        var normalized: [String: Int] = [:]
        for (typeCode, generation) in persisted {
            guard generation > 0 else { continue }
            let canonicalTypeCode = GenericQuantityCoveragePolicy.canonicalTypeCode(
                for: typeCode
            )
            normalized[canonicalTypeCode] = max(
                generation,
                normalized[canonicalTypeCode] ?? 0
            )
        }
        return normalized
    }

    public var pendingObserverTypeCodeGenerations: [String: Int] {
        (try? loadPendingObserverTypeCodeGenerations())
            ?? Dictionary(
                uniqueKeysWithValues: HealthBridgeBackgroundSync
                    .supportedAutomaticQuantityTypeCodes
                    .map { ($0, Int.max) }
            )
    }

    public var pendingObserverTypeCodes: [String] {
        pendingObserverTypeCodeGenerations.keys.sorted()
    }

    public var nextScheduledWorkLaneID: String? {
        userDefaults.string(forKey: Key.nextScheduledWorkLaneID)
    }

    public func persistNextScheduledWorkLaneID(_ laneID: String?) throws {
        if let laneID, !laneID.isEmpty {
            userDefaults.set(laneID, forKey: Key.nextScheduledWorkLaneID)
        } else {
            userDefaults.removeObject(forKey: Key.nextScheduledWorkLaneID)
        }
        guard userDefaults.synchronize() else {
            throw BackgroundSyncSettingsStoreError.persistenceFailed
        }
    }

    public func resetScheduledWorkContinuation() throws {
        try persistNextScheduledWorkLaneID(nil)
    }

    public func mailboxAckScanCheckpoint(
        receiverGeneration: String
    ) -> String? {
        guard userDefaults.string(forKey: Key.mailboxAckScanCheckpointGeneration)
            == receiverGeneration else {
            return nil
        }
        return userDefaults.string(forKey: Key.mailboxAckScanCheckpoint)
    }

    public func persistMailboxAckScanCheckpoint(
        _ checkpoint: String,
        receiverGeneration: String
    ) throws {
        userDefaults.set(checkpoint, forKey: Key.mailboxAckScanCheckpoint)
        userDefaults.set(
            receiverGeneration,
            forKey: Key.mailboxAckScanCheckpointGeneration
        )
        guard userDefaults.synchronize() else {
            throw BackgroundSyncSettingsStoreError.persistenceFailed
        }
    }

    public func markPendingObserverTypeCodes(_ typeCodes: [String]) throws {
        var generations = try loadPendingObserverTypeCodeGenerations()
        for typeCode in GenericQuantityCoveragePolicy.canonicalTypeCodes(for: typeCodes) {
            let current = generations[typeCode] ?? 0
            generations[typeCode] = current == Int.max ? Int.max : current + 1
        }
        try savePendingObserverTypeCodeGenerations(generations)
    }

    public func clearPendingObserverTypeCodes(
        matching expectedGenerations: [String: Int],
        typeCodes: [String]
    ) throws {
        var generations = try loadPendingObserverTypeCodeGenerations()
        for typeCode in GenericQuantityCoveragePolicy.canonicalTypeCodes(for: typeCodes) {
            guard let expectedGeneration = expectedGenerations[typeCode],
                  generations[typeCode] == expectedGeneration else {
                continue
            }
            generations.removeValue(forKey: typeCode)
        }
        try savePendingObserverTypeCodeGenerations(generations)
    }

    private func savePendingObserverTypeCodeGenerations(
        _ generations: [String: Int]
    ) throws {
        try observerDirtinessStore.saveGenerations(generations)
        guard !observerDirtinessUsesUserDefaults else { return }
        userDefaults.removeObject(forKey: Key.pendingObserverTypeCodeGenerations)
        _ = userDefaults.synchronize()
    }

    public func resetPendingObserverDirtiness() throws {
        try savePendingObserverTypeCodeGenerations([:])
    }

    public func setEnabled(_ enabled: Bool) {
        try? setEnabledDurably(enabled)
    }

    public func setEnabledDurably(_ enabled: Bool) throws {
        if !enabled {
            let markerPersisted: Bool
            do {
                try disableIntentStore.markDisableIntentPending()
                markerPersisted = true
            } catch {
                markerPersisted = false
            }
            userDefaults.set(false, forKey: Key.isEnabled)
            let preferencePersisted = userDefaults.synchronize()
            guard markerPersisted || preferencePersisted else {
                throw BackgroundSyncSettingsStoreError.persistenceFailed
            }
            return
        }

        userDefaults.set(true, forKey: Key.isEnabled)
        guard userDefaults.synchronize() else {
            userDefaults.set(false, forKey: Key.isEnabled)
            throw BackgroundSyncSettingsStoreError.persistenceFailed
        }
        do {
            try disableIntentStore.clearDisableIntent()
        } catch {
            userDefaults.set(false, forKey: Key.isEnabled)
            _ = userDefaults.synchronize()
            throw BackgroundSyncSettingsStoreError.persistenceFailed
        }
    }

    public func recordRunLifecycle(
        startedAt: Date,
        finishedAt: Date?,
        outcome: BackgroundSyncRunOutcome,
        succeeded: Bool,
        summary: String
    ) throws {
        try recordRunLifecycle(
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            succeeded: succeeded,
            summary: summary,
            selectedLane: nil
        )
    }

    func recordRunLifecycle(
        startedAt: Date,
        finishedAt: Date?,
        outcome: BackgroundSyncRunOutcome,
        succeeded: Bool,
        summary: String,
        selectedLane: AutomaticSyncDiagnosticLane?
    ) throws {
        if outcome == .skipped {
            let finishedAt = finishedAt ?? startedAt
            userDefaults.set(
                dateFormatter.string(from: startedAt),
                forKey: Key.lastSkippedStartedAt
            )
            userDefaults.set(
                dateFormatter.string(from: finishedAt),
                forKey: Key.lastSkippedFinishedAt
            )
            userDefaults.set(summary, forKey: Key.lastSkippedSummary)
            guard userDefaults.synchronize() else {
                throw BackgroundSyncSettingsStoreError.persistenceFailed
            }
            return
        }
        userDefaults.set(dateFormatter.string(from: startedAt), forKey: Key.lastStartedAt)
        if let finishedAt {
            userDefaults.set(
                dateFormatter.string(from: finishedAt),
                forKey: Key.lastFinishedAt
            )
        } else {
            userDefaults.removeObject(forKey: Key.lastFinishedAt)
        }
        userDefaults.set(outcome.rawValue, forKey: Key.lastOutcome)
        userDefaults.set(
            outcome == .completed && succeeded,
            forKey: Key.lastSucceeded
        )
        userDefaults.set(summary, forKey: Key.lastSummary)
        if outcome == .accepted, let selectedLane {
            userDefaults.set(selectedLane.rawValue, forKey: Key.lastSelectedLane)
        } else {
            userDefaults.removeObject(forKey: Key.lastSelectedLane)
        }
        guard userDefaults.synchronize() else {
            throw BackgroundSyncSettingsStoreError.persistenceFailed
        }
    }

    public func recordRun(startedAt: Date, finishedAt: Date, succeeded: Bool, summary: String) {
        try? recordRunLifecycle(
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: .completed,
            succeeded: succeeded,
            summary: summary
        )
    }

    public func recordRegistration(at attemptedAt: Date, succeeded: Bool, summary: String) {
        userDefaults.set(dateFormatter.string(from: attemptedAt), forKey: Key.lastRegistrationAttemptedAt)
        userDefaults.set(succeeded, forKey: Key.lastRegistrationSucceeded)
        userDefaults.set(summary, forKey: Key.lastRegistrationSummary)
    }

    public func recordTaskSchedule(at attemptedAt: Date, status: String, summary: String) {
        userDefaults.set(dateFormatter.string(from: attemptedAt), forKey: Key.lastTaskScheduleAttemptedAt)
        userDefaults.set(status, forKey: Key.lastTaskScheduleStatus)
        userDefaults.set(summary, forKey: Key.lastTaskScheduleSummary)
    }

    public func recordWakeEvent(at enteredAt: Date, source: String, summary: String) {
        userDefaults.set(dateFormatter.string(from: enteredAt), forKey: Key.lastWakeEnteredAt)
        userDefaults.set(source, forKey: Key.lastWakeSource)
        userDefaults.set(summary, forKey: Key.lastWakeSummary)
    }

    public func shouldRunForegroundCatchUp(
        now: Date = Date(),
        minimumInterval: TimeInterval = HealthBridgeBackgroundSync.defaultMinimumInterval
    ) -> Bool {
        guard isEnabled else { return false }
        if !pendingObserverTypeCodeGenerations.isEmpty {
            return true
        }
        if userDefaults.object(forKey: Key.lastSucceeded) != nil,
           !userDefaults.bool(forKey: Key.lastSucceeded) {
            return true
        }
        guard let lastFinishedAt = userDefaults.string(forKey: Key.lastFinishedAt),
              let finishedAt = dateFormatter.date(from: lastFinishedAt)
        else {
            return true
        }
        return now.timeIntervalSince(finishedAt) >= minimumInterval
    }
}

public final class QuantityObservationStore {
    private enum Key {
        // Preserve the original key so existing installations keep their observed-type history.
        static let observedTypeCodes = "healthBridge.optionalQuantity.foregroundConfirmedTypeCodes"
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public var observedTypeCodes: [String] {
        GenericQuantityCoveragePolicy.canonicalTypeCodes(
            for: userDefaults.stringArray(forKey: Key.observedTypeCodes) ?? []
        )
    }

    public func markObserved(typeCodes: [String]) {
        let updated = Array(
            Set(observedTypeCodes).union(
                GenericQuantityCoveragePolicy.canonicalTypeCodes(for: typeCodes)
            )
        ).sorted()
        userDefaults.set(updated, forKey: Key.observedTypeCodes)
    }
}

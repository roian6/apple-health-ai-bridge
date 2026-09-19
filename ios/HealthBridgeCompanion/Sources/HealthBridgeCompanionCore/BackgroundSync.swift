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
    case manualSync

    public var observerTypeCodes: [String] {
        switch self {
        case .observer(let typeCode):
            return [typeCode]
        case .observerBatch(let typeCodes):
            return typeCodes
        case .scheduledRefresh, .launchCatchUp, .manualSync:
            return []
        }
    }
}

public struct AutomaticSyncTypeResult: Equatable, Sendable {
    fileprivate enum Disposition: Equatable, Sendable {
        case noPayload
        case retryableReadFailure
        case payloadEnqueued
        case blocked
    }

    fileprivate let disposition: Disposition
    fileprivate let coveredGenerations: [String: Int]?

    public static let noPayload = Self(disposition: .noPayload, coveredGenerations: nil)
    public static let retryableReadFailure = Self(
        disposition: .retryableReadFailure,
        coveredGenerations: nil
    )
    public static let payloadEnqueued = Self(
        disposition: .payloadEnqueued,
        coveredGenerations: nil
    )
    public static let blocked = Self(disposition: .blocked, coveredGenerations: nil)

    public static func noPayloadCovering(
        _ generations: [String: Int]
    ) -> Self {
        Self(disposition: .noPayload, coveredGenerations: generations)
    }

    public static func retryableReadFailureCovering(
        _ generations: [String: Int]
    ) -> Self {
        Self(disposition: .retryableReadFailure, coveredGenerations: generations)
    }
}

public final class AutomaticSyncEngine: @unchecked Sendable {
    public typealias CancelOwner = @Sendable () -> Void
    public typealias FinishOwner = @MainActor @Sendable () -> Void
    public typealias StartOwner = @MainActor @Sendable (
        _ cancelOwner: @escaping CancelOwner
    ) -> FinishOwner

    public struct Opportunity: Equatable, Sendable {
        public let reason: AutomaticSyncReason
        public let diagnosticRunID: UUID
        public let bootstrapBeforeRun: Bool

        fileprivate init(
            reason: AutomaticSyncReason,
            diagnosticRunID: UUID,
            bootstrapBeforeRun: Bool
        ) {
            self.reason = reason
            self.diagnosticRunID = diagnosticRunID
            self.bootstrapBeforeRun = bootstrapBeforeRun
        }

        fileprivate func coalescing(_ newer: Self) -> Self {
            let existingTypeCodes = reason.observerTypeCodes
            let newerTypeCodes = newer.reason.observerTypeCodes
            let coalescedReason: AutomaticSyncReason
            let coalescedRunID: UUID
            if !existingTypeCodes.isEmpty, newerTypeCodes.isEmpty {
                coalescedReason = newer.reason
                coalescedRunID = newer.diagnosticRunID
            } else if existingTypeCodes.isEmpty || newerTypeCodes.isEmpty {
                coalescedReason = reason
                coalescedRunID = diagnosticRunID
            } else {
                coalescedReason = .observerBatch(
                    typeCodes: Array(Set(existingTypeCodes + newerTypeCodes)).sorted()
                )
                coalescedRunID = diagnosticRunID
            }
            return Self(
                reason: coalescedReason,
                diagnosticRunID: coalescedRunID,
                bootstrapBeforeRun: bootstrapBeforeRun || newer.bootstrapBeforeRun
            )
        }
    }

    public typealias ProcessType = @MainActor @Sendable (
        _ typeCode: String,
        _ pendingGenerations: [String: Int]
    ) async throws -> AutomaticSyncTypeResult
    public typealias ProcessPendingTypes = @MainActor @Sendable () async throws -> Bool
    public typealias PerformOpportunity = @MainActor @Sendable (
        _ opportunity: Opportunity,
        _ processPendingTypes: @escaping ProcessPendingTypes
    ) async throws -> Void

    private let pendingStore: BackgroundSyncSettingsStore
    private let processType: ProcessType
    private let performOpportunity: PerformOpportunity
    private let startOwner: StartOwner
    @MainActor private var activeTask: Task<Result<Void, Error>, Never>?
    @MainActor private var trailingOpportunity: Opportunity?

    @MainActor
    private final class OwnerCompletion {
        private var finishOwner: FinishOwner?

        func install(_ finishOwner: @escaping FinishOwner) {
            self.finishOwner = finishOwner
        }

        func finish() {
            let finishOwner = finishOwner
            self.finishOwner = nil
            finishOwner?()
        }
    }

    private final class FollowerResultWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<Void, Error>?, Never>?
        private var result: Result<Void, Error>?
        private var isCancelled = false

        func wait() async -> Result<Void, Error>? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else if isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func complete(_ result: Result<Void, Error>) {
            lock.lock()
            guard !isCancelled, self.result == nil else {
                lock.unlock()
                return
            }
            let continuation = continuation
            self.continuation = nil
            if continuation == nil {
                self.result = result
            }
            lock.unlock()
            continuation?.resume(returning: result)
        }

        func cancel() {
            lock.lock()
            guard !isCancelled, result == nil else {
                lock.unlock()
                return
            }
            isCancelled = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    public init(
        pendingStore: BackgroundSyncSettingsStore,
        processType: @escaping ProcessType,
        performOpportunity: PerformOpportunity? = nil,
        startOwner: StartOwner? = nil
    ) {
        self.pendingStore = pendingStore
        self.processType = processType
        self.performOpportunity = performOpportunity ?? { _, processPendingTypes in
            _ = try await processPendingTypes()
        }
        self.startOwner = startOwner ?? { _ in {} }
    }

    @MainActor
    public func requestRun() async throws {
        let typeCodes = try pendingStore
            .loadPendingObserverTypeCodeGenerations().keys.sorted()
        try await requestRun(reason: .observerBatch(typeCodes: typeCodes))
    }

    @MainActor
    public func requestRun(
        reason: AutomaticSyncReason,
        diagnosticRunID: UUID = UUID(),
        bootstrapBeforeRun: Bool = false
    ) async throws {
        let request = requestRunTask(for: Opportunity(
            reason: reason,
            diagnosticRunID: diagnosticRunID,
            bootstrapBeforeRun: bootstrapBeforeRun
        ))
        guard request.ownsTask else {
            let waiter = FollowerResultWaiter()
            Task { @MainActor in
                waiter.complete(await request.task.value)
            }
            let result = await withTaskCancellationHandler {
                await waiter.wait()
            } onCancel: {
                waiter.cancel()
            }
            try Task.checkCancellation()
            guard let result else { throw CancellationError() }
            try result.get()
            return
        }
        let result = await withTaskCancellationHandler {
            await request.task.value
        } onCancel: {
            request.task.cancel()
        }
        try result.get()
    }

    @MainActor
    public func requestRunWithoutWaiting(
        reason: AutomaticSyncReason,
        diagnosticRunID: UUID
    ) {
        _ = requestRunTask(for: Opportunity(
            reason: reason,
            diagnosticRunID: diagnosticRunID,
            bootstrapBeforeRun: false
        ))
    }

    @MainActor
    public func cancelActiveOwner() {
        trailingOpportunity = nil
        activeTask?.cancel()
    }

    @MainActor
    public func cancelAndWait() async {
        trailingOpportunity = nil
        guard let activeTask else { return }
        activeTask.cancel()
        _ = await activeTask.value
    }

    @MainActor
    private func requestRunTask(
        for opportunity: Opportunity
    ) -> (task: Task<Result<Void, Error>, Never>, ownsTask: Bool) {
        if let activeTask {
            trailingOpportunity = trailingOpportunity?.coalescing(opportunity) ?? opportunity
            return (activeTask, false)
        }
        trailingOpportunity = nil
        let ownerCompletion = OwnerCompletion()
        let task = Task { @MainActor [weak self] () -> Result<Void, Error> in
            defer { ownerCompletion.finish() }
            guard let self else { return .success(()) }
            let result: Result<Void, Error>
            do {
                try await self.performSingleOpportunity(opportunity)
                if !Task.isCancelled, let trailingOpportunity = self.trailingOpportunity {
                    self.trailingOpportunity = nil
                    try await self.performSingleOpportunity(trailingOpportunity)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self.activeTask = nil
            self.trailingOpportunity = nil
            return result
        }
        activeTask = task
        ownerCompletion.install(startOwner {
            task.cancel()
        })
        return (task, true)
    }

    @MainActor
    private func performSingleOpportunity(_ opportunity: Opportunity) async throws {
        try await performOpportunity(opportunity) { [weak self] in
            guard let self else { return false }
            return try await self.processStableSnapshot()
        }
    }

    @MainActor
    private func processStableSnapshot() async throws -> Bool {
        let snapshot = try pendingStore.loadPendingObserverTypeCodeGenerations()
        var handled: Set<String> = []
        for typeCode in snapshot.keys.sorted() where !handled.contains(typeCode) {
            try Task.checkCancellation()
            guard let generation = snapshot[typeCode] else { continue }
            let result = try await processType(typeCode, snapshot)
            let coveredGenerations = (result.coveredGenerations ?? [typeCode: generation])
                .filter { snapshot[$0.key] == $0.value }
            handled.formUnion(coveredGenerations.keys)
            switch result.disposition {
            case .noPayload:
                try pendingStore.clearPendingObserverTypeCodes(
                    matching: coveredGenerations,
                    typeCodes: coveredGenerations.keys.sorted()
                )
            case .retryableReadFailure:
                continue
            case .payloadEnqueued:
                continue
            case .blocked:
                return false
            }
        }
        return true
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

    public var shouldAttemptInlineDirectDelivery: Bool {
        true
    }

    public func shouldPersistSharedProgress(hadUsableCursor: Bool) -> Bool {
        self == .foreground || hadUsableCursor
    }
}

public enum HealthBridgeBackgroundSync {
    public static var appRefreshIdentifier: String {
        HealthBridgeAppIdentity.appRefreshIdentifier
    }
    public static let defaultMinimumInterval: TimeInterval = 15 * 60
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
    private final class WakeEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let userDefaults: UserDefaults
        private let dateFormatter: ISO8601DateFormatter

        init(userDefaults: UserDefaults) {
            self.userDefaults = userDefaults
            self.dateFormatter = ISO8601DateFormatter()
            self.dateFormatter.formatOptions = [.withInternetDateTime]
            self.dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        }

        func record(at enteredAt: Date, source: String, summary: String) {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(
                dateFormatter.string(from: enteredAt),
                forKey: Key.lastWakeEnteredAt
            )
            userDefaults.set(source, forKey: Key.lastWakeSource)
            userDefaults.set(summary, forKey: Key.lastWakeSummary)
            _ = userDefaults.synchronize()
        }
    }

    private enum Key {
        static let isEnabled = "healthBridge.backgroundSync.enabled"
        static let lastStartedAt = "healthBridge.backgroundSync.lastStartedAt"
        static let lastFinishedAt = "healthBridge.backgroundSync.lastFinishedAt"
        static let lastOutcome = "healthBridge.backgroundSync.lastOutcome"
        static let lastSucceeded = "healthBridge.backgroundSync.lastSucceeded"
        static let lastSummary = "healthBridge.backgroundSync.lastSummary"
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
    private let wakeEventRecorder: WakeEventRecorder

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
        self.wakeEventRecorder = WakeEventRecorder(userDefaults: userDefaults)
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
        (try? loadPendingObserverTypeCodeGenerations()) ?? [:]
    }

    public var pendingObserverTypeCodes: [String] {
        pendingObserverTypeCodeGenerations.keys.sorted()
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
        wakeEventRecorder.record(at: enteredAt, source: source, summary: summary)
    }

    public func healthKitObserverEntryHandler() -> @Sendable (String, UUID) -> Void {
        let recorder = wakeEventRecorder
        return { typeCode, runID in
            recorder.record(
                at: Date(),
                source: "healthkit_observer",
                summary: "HealthKit observer closure entered; type=\(typeCode); run_id=\(runID.uuidString.lowercased())."
            )
        }
    }

    public func shouldRunForegroundCatchUp() -> Bool {
        return isEnabled && !pendingObserverTypeCodeGenerations.isEmpty
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

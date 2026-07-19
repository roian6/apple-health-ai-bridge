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
        let observerTypeCodes = reason.observerTypeCodes
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

    public func pendingObserverTypeCodesSnapshot() -> [String] {
        pendingObserverTypeCodes.sorted()
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

public struct BackgroundSyncLastRun: Equatable {
    public let startedAt: String
    public let finishedAt: String
    public let succeeded: Bool
    public let summary: String

    public init(startedAt: String, finishedAt: String, succeeded: Bool, summary: String) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.succeeded = succeeded
        self.summary = summary
    }

    public var userVisibleSummary: String {
        succeeded
            ? "Last background sync completed."
            : "Last background sync did not complete."
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
        static let lastSucceeded = "healthBridge.backgroundSync.lastSucceeded"
        static let lastSummary = "healthBridge.backgroundSync.lastSummary"
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
            let finishedAt = userDefaults.string(forKey: Key.lastFinishedAt),
            let summary = userDefaults.string(forKey: Key.lastSummary)
        else {
            return nil
        }
        return BackgroundSyncLastRun(
            startedAt: startedAt,
            finishedAt: finishedAt,
            succeeded: userDefaults.bool(forKey: Key.lastSucceeded),
            summary: summary
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

    public func recordRun(startedAt: Date, finishedAt: Date, succeeded: Bool, summary: String) {
        userDefaults.set(dateFormatter.string(from: startedAt), forKey: Key.lastStartedAt)
        userDefaults.set(dateFormatter.string(from: finishedAt), forKey: Key.lastFinishedAt)
        userDefaults.set(succeeded, forKey: Key.lastSucceeded)
        userDefaults.set(summary, forKey: Key.lastSummary)
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

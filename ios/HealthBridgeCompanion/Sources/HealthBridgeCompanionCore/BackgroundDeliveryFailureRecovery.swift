import Foundation

public enum BackgroundRecoveryLane: String, Codable, CaseIterable, Sendable {
    case steps, dailyActivity = "daily_activity", workouts, sleep, quantity

    public init(typeCode: String) {
        switch AutomaticSyncDiagnosticLane(typeCode: typeCode) {
        case .steps: self = .steps
        case .dailyActivity: self = .dailyActivity
        case .workouts: self = .workouts
        case .sleep: self = .sleep
        default: self = .quantity
        }
    }
}

public struct BackgroundRegistrationRetry: Codable, Equatable, Sendable {
    public var attemptCount: Int
    // Application retry deadline, never a HealthKit sample timestamp.
    public var nextEligibleAt: Date
}

public struct BackgroundDeliveryRecoverySnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var observerGenerations: [BackgroundRecoveryLane: Int] = [:]
    public var observerRecoveryOffered = false
    public var registrations: [BackgroundRecoveryLane: BackgroundRegistrationRetry] = [:]
    public init() {}
}

public protocol BackgroundDeliveryRecoveryStoring: AnyObject {
    func load() throws -> BackgroundDeliveryRecoverySnapshot
    func save(_ snapshot: BackgroundDeliveryRecoverySnapshot) throws
}

public final class FileBackgroundDeliveryRecoveryStore: BackgroundDeliveryRecoveryStoring {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(fileURL: base.appendingPathComponent("HealthBridgeCompanion/background-delivery-recovery.json"))
    }

    public func load() throws -> BackgroundDeliveryRecoverySnapshot {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch CocoaError.fileReadNoSuchFile { return .init() }
        guard data.count <= 4_096 else { throw BackgroundSyncSettingsStoreError.persistenceFailed }
        let snapshot = try JSONDecoder().decode(BackgroundDeliveryRecoverySnapshot.self, from: data)
        guard snapshot.version == 1,
              snapshot.observerGenerations.values.allSatisfy({ $0 > 0 }),
              snapshot.registrations.values.allSatisfy({
                  (1...5).contains($0.attemptCount) && $0.nextEligibleAt.timeIntervalSince1970.isFinite
              }) else { throw BackgroundSyncSettingsStoreError.persistenceFailed }
        return snapshot
    }

    public func save(_ snapshot: BackgroundDeliveryRecoverySnapshot) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try url.setResourceValues(values)
        #if os(iOS)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}

// The HealthKit callback calls this before even enqueuing MainActor recovery.
public final class BackgroundObserverAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    public init(_ completion: @escaping () -> Void) { self.completion = completion }
    public func call() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }

}

public enum BackgroundObserverFailureResult: Equatable, Sendable {
    case retained(lane: BackgroundRecoveryLane, localRecoveryEligible: Bool)
    case durableStateUnavailable(lane: BackgroundRecoveryLane)
    case ignored
}

public enum BackgroundRecoveryDurableState: String, Codable, Sendable {
    case available, unavailable
}

/// A set of five coarse lanes, never optional HealthKit identifiers or errors.
/// Unavailable with no known lanes is unknown backlog, not evidence of no work.
public struct BackgroundObserverPendingDiagnostic: Codable, Equatable, Sendable {
    public let lanes: Set<BackgroundRecoveryLane>
    public let durableState: BackgroundRecoveryDurableState
}

public struct BackgroundObserverFailureHandoff {
    public let result: BackgroundObserverFailureResult
    public let diagnostic: AutomaticSyncDiagnosticDraft

    public var localRecoveryEligible: Bool {
        if case .retained(_, let eligible) = result { return eligible }
        return false
    }
}

public struct BackgroundObserverRecoveryAdmission: Equatable, Sendable {
    let generation: UInt64?
    let lanes: [BackgroundRecoveryLane: Int]
}

public struct BackgroundRegistrationAttempt: Equatable, Sendable {
    public let typeCode: String
    let generation: UInt64
    let attemptCount: Int
}

public struct BackgroundDeliveryRecoveryReadback: Equatable, Sendable {
    public let failedRegistrationLanes: [BackgroundRecoveryLane]
    public let exhaustedRegistrationLaneCount: Int
    public let pendingObserverLaneCount: Int
    public let durableStateUnavailable: Bool

    public var summary: String {
        let lanes = failedRegistrationLanes.map(\.rawValue).joined(separator: ",")
        return "registration_pending_lanes=\(failedRegistrationLanes.count) [\(lanes)]; exhausted=\(exhaustedRegistrationLaneCount); observer_pending_lanes=\(pendingObserverLaneCount); durable_state=\(durableStateUnavailable ? "unavailable" : "available")"
    }
}

@MainActor
public final class BackgroundDeliveryFailureRecovery {
    public static let maximumRegistrationAttempts = 5
    public static let initialRetryInterval: TimeInterval = 60
    public static let maximumRetryInterval: TimeInterval = 15 * 60
    private let store: any BackgroundDeliveryRecoveryStoring
    private let now: () -> Date
    private var snapshot: BackgroundDeliveryRecoverySnapshot?
    private var generation: UInt64?
    private var inFlight: [String: BackgroundRegistrationAttempt] = [:]
    private var successfulTypes: Set<String> = []
    private var completedObserverTypes: Set<String> = []
    private var durableStateUnavailable = false
    // Diagnostic-only uncertainty, bounded by the five coarse lanes. Never admits work.
    private var unretainedObserverLanes: Set<BackgroundRecoveryLane> = []

    public init(store: any BackgroundDeliveryRecoveryStoring, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func activate(generation: UInt64) {
        guard self.generation != generation else { return }
        self.generation = generation
        inFlight = [:]
        successfulTypes = []
        failedTypes = []
        completedObserverTypes = []
        do { snapshot = try store.load(); durableStateUnavailable = false }
        catch { snapshot = nil; durableStateUnavailable = true }
    }

    public func stop() {
        generation = nil
        inFlight = [:]
    }

    public var readback: BackgroundDeliveryRecoveryReadback {
        let registrations = snapshot?.registrations ?? [:]
        return .init(
            failedRegistrationLanes: BackgroundRecoveryLane.allCases.filter { registrations[$0] != nil },
            exhaustedRegistrationLaneCount: registrations.values.filter { $0.attemptCount >= Self.maximumRegistrationAttempts }.count,
            pendingObserverLaneCount: max(observerPendingDiagnostic.lanes.count, durableStateUnavailable ? 1 : 0),
            durableStateUnavailable: observerPendingDiagnostic.durableState == .unavailable
        )
    }

    public var nextRegistrationRetryAt: Date? {
        guard generation != nil, !durableStateUnavailable else { return nil }
        return snapshot?.registrations.filter { lane, retry in
            retry.attemptCount < Self.maximumRegistrationAttempts
                && registrationTypeCodes.contains { BackgroundRecoveryLane(typeCode: $0) == lane && !successfulTypes.contains($0) }
        }.values.map(\.nextEligibleAt).min()
    }

    public func processObserverFailure(
        typeCode: String, generation: UInt64, acknowledge: () -> Void
    ) -> BackgroundObserverFailureResult {
        defer { acknowledge() }
        guard self.generation == generation else { return .ignored }
        let lane = BackgroundRecoveryLane(typeCode: typeCode)
        do {
            var next = try loadedSnapshot()
            let previous = next.observerGenerations[lane] ?? 0
            next.observerGenerations[lane] = previous == Int.max ? Int.max : previous + 1
            let eligible = !next.observerRecoveryOffered
            next.observerRecoveryOffered = true
            try persist(next)
            unretainedObserverLanes.remove(lane)
            completedObserverTypes = completedObserverTypes.filter { BackgroundRecoveryLane(typeCode: $0) != lane }
            return .retained(lane: lane, localRecoveryEligible: eligible)
        } catch {
            durableStateUnavailable = true
            unretainedObserverLanes.insert(lane)
            return .durableStateUnavailable(lane: lane)
        }
    }

    /// Retains the coarse failure token before acknowledging HealthKit. The
    /// draft is the one local opportunity's identity, not another retry record.
    public func observerFailureHandoff(
        typeCode: String, generation: UInt64, runID: UUID,
        completionLatency: TimeInterval, acknowledge: () -> Void
    ) -> BackgroundObserverFailureHandoff? {
        let result = processObserverFailure(typeCode: typeCode, generation: generation, acknowledge: acknowledge)
        let lane: BackgroundRecoveryLane
        let state: BackgroundRecoveryDurableState
        switch result {
        case .ignored: return nil
        case .retained(let retainedLane, _): lane = retainedLane; state = .available
        case .durableStateUnavailable(let unavailableLane): lane = unavailableLane; state = .unavailable
        }
        let draft = AutomaticSyncDiagnosticDraft(
            observerFailureLane: lane, runID: runID,
            completionLatency: completionLatency, durableState: state
        )
        if state == .unavailable { draft.noteDurableStateUnavailable() }
        else { draft.noteCompletion(.deferred) }
        return .init(result: result, diagnostic: draft)
    }

    public var observerPendingDiagnostic: BackgroundObserverPendingDiagnostic {
        .init(
            lanes: Set(snapshot?.observerGenerations.keys.map { $0 } ?? []).union(unretainedObserverLanes),
            durableState: durableStateUnavailable || !unretainedObserverLanes.isEmpty ? .unavailable : .available
        )
    }

    public func noteDiagnosticPending(
        _ draft: AutomaticSyncDiagnosticDraft, settingsTypeCodes: [String],
        using store: AutomaticSyncDiagnosticStore, initial: Bool, now: Date = Date()
    ) {
        let recovery = observerPendingDiagnostic
        if draft.defersPersistenceUntilObserverAcknowledgement {
            if initial {
                draft.notePendingForDeferredPersistence(typeCodes: settingsTypeCodes, recovery: recovery)
            } else {
                draft.noteCompletionForDeferredPersistence(draft.record.runOutcome,
                    remainingPendingTypeCodes: settingsTypeCodes, recovery: recovery)
            }
        } else {
            let pending = store.pendingSnapshot(pendingTypeCodes: settingsTypeCodes, now: now, recovery: recovery)
            if initial { draft.notePending(pending) }
            else { draft.noteCompletion(draft.record.runOutcome, remainingPendingSnapshot: pending) }
        }
    }

    public func observerGenerationSnapshot() throws -> BackgroundObserverRecoveryAdmission {
        .init(generation: generation, lanes: try loadedSnapshot().observerGenerations)
    }

    // Expansion is runtime-only. Optional type codes never enter the recovery file.
    public func pendingObserverTypeCodes(availableTypeCodes: [String]) throws -> [String] {
        let lanes = try loadedSnapshot().observerGenerations
        return GenericQuantityCoveragePolicy.canonicalTypeCodes(for: availableTypeCodes).filter {
            lanes[BackgroundRecoveryLane(typeCode: $0)] != nil && !completedObserverTypes.contains($0)
        }
    }

    public func completeObserverWork(
        typeCodes: [String], matching expected: BackgroundObserverRecoveryAdmission, availableTypeCodes: [String]
    ) throws {
        guard generation != nil, generation == expected.generation else { return }
        var next = try loadedSnapshot()
        var completed = completedObserverTypes
        for code in typeCodes {
            let lane = BackgroundRecoveryLane(typeCode: code)
            guard let expectedGeneration = expected.lanes[lane],
                  next.observerGenerations[lane] == expectedGeneration else { continue }
            completed.insert(code)
            let laneTypes = availableTypeCodes.filter { BackgroundRecoveryLane(typeCode: $0) == lane }
            if !laneTypes.isEmpty && laneTypes.allSatisfy({ completed.contains($0) }) {
                next.observerGenerations.removeValue(forKey: lane)
            }
        }
        if next.observerGenerations.isEmpty { next.observerRecoveryOffered = false }
        if next != snapshot { try persist(next) }
        completedObserverTypes = completed
    }

    public func claimRegistrations(typeCodes: [String], generation: UInt64) throws -> [BackgroundRegistrationAttempt] {
        guard self.generation == generation else { return [] }
        var next = try loadedSnapshot()
        let time = now()
        let codes = GenericQuantityCoveragePolicy.canonicalTypeCodes(for: typeCodes)
        registrationTypeCodes = Set(codes)
        var attempts: [BackgroundRegistrationAttempt] = []
        for lane in BackgroundRecoveryLane.allCases {
            let pending = codes.filter { BackgroundRecoveryLane(typeCode: $0) == lane && !successfulTypes.contains($0) }
            guard !pending.isEmpty else { continue }
            let previous = next.registrations[lane]
            if let previous {
                guard previous.attemptCount < Self.maximumRegistrationAttempts,
                      time >= previous.nextEligibleAt else { continue }
            }
            let count = (previous?.attemptCount ?? 0) + 1
            let interval = min(Self.maximumRetryInterval, Self.initialRetryInterval * pow(2, Double(count - 1)))
            next.registrations[lane] = .init(attemptCount: count, nextEligibleAt: time.addingTimeInterval(interval))
            attempts += pending.map { .init(typeCode: $0, generation: generation, attemptCount: count) }
        }
        guard !attempts.isEmpty else { return [] }
        // A crash, missing callback or lifecycle restart cannot bypass this reservation.
        try persist(next)
        for attempt in attempts { inFlight[attempt.typeCode] = attempt }
        return attempts.sorted { $0.typeCode < $1.typeCode }
    }

    @discardableResult
    public func completeRegistration(_ attempt: BackgroundRegistrationAttempt, succeeded: Bool) throws -> Bool {
        guard generation == attempt.generation, inFlight[attempt.typeCode] == attempt else { return false }
        inFlight.removeValue(forKey: attempt.typeCode)
        if succeeded { successfulTypes.insert(attempt.typeCode) }
        let lane = BackgroundRecoveryLane(typeCode: attempt.typeCode)
        let hasOutstanding = inFlight.keys.contains { BackgroundRecoveryLane(typeCode: $0) == lane }
        // Failed types remain eligible; successes in a mixed cohort cannot clear its failure.
        if !succeeded { failedTypes.insert(attempt.typeCode) }
        else { failedTypes.remove(attempt.typeCode) }
        guard !hasOutstanding, !failedTypes.contains(where: { BackgroundRecoveryLane(typeCode: $0) == lane }) else { return true }
        var next = try loadedSnapshot()
        next.registrations.removeValue(forKey: lane)
        try persist(next)
        return true
    }

    private var failedTypes: Set<String> = []
    private var registrationTypeCodes: Set<String> = []

    private func loadedSnapshot() throws -> BackgroundDeliveryRecoverySnapshot {
        if let snapshot { return snapshot }
        do {
            let loaded = try store.load()
            snapshot = loaded
            durableStateUnavailable = false
            return loaded
        } catch {
            durableStateUnavailable = true
            throw error
        }
    }

    private func persist(_ next: BackgroundDeliveryRecoverySnapshot) throws {
        do {
            try store.save(next)
            snapshot = next
            durableStateUnavailable = false
        } catch {
            durableStateUnavailable = true
            throw error
        }
    }
}

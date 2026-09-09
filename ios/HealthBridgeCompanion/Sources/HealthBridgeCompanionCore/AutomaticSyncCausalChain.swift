import Foundation

public enum AutomaticSyncQueryOutcome: String, Codable, CaseIterable, Sendable {
    case records, noRecords = "no_records", failed, cancelled, notRun = "not_run"
}

public enum AutomaticSyncOutboxDisposition: String, Codable, Sendable {
    case notRun = "not_run", notNeeded = "not_needed", queued, partial, failed, unknown
}

public enum AutomaticSyncDeliveryOutcome: String, Codable, CaseIterable, Sendable {
    case notRun = "not_run", accepted, mailboxAckPending = "mailbox_ack_pending", failed, cancelled, unknown
    case rejected, retired
}

/// Local-only evidence. Times are 15-minute *operation* buckets, never HealthKit timestamps.
/// FIFO references are existing random item UUIDs, never payload-derived identifiers or hashes.
public struct AutomaticSyncLaneEvidence: Codable, Equatable, Sendable {
    public static let maximumPendingItems = 64
    public let lane: AutomaticSyncDiagnosticLane
    public var attempted = false
    public var query: AutomaticSyncQueryOutcome = .notRun
    public var queryTimeBucket: Int?
    public var newestSampleAge: AutomaticSyncPendingAgeBucket = .unknown
    public var outbox: AutomaticSyncOutboxDisposition = .notRun
    public var delivery: AutomaticSyncDeliveryOutcome = .notRun
    public var deliveryTimeBucket: Int?
    public var pendingItems: [UUID] = []
    public var truncated = false

    public init(lane: AutomaticSyncDiagnosticLane) { self.lane = lane }

    public mutating func noteQuery(_ outcome: AutomaticSyncQueryOutcome, newestSampleAge: TimeInterval?, now: Date) {
        query = outcome
        queryTimeBucket = Self.timeBucket(now)
        self.newestSampleAge = newestSampleAge.flatMap {
            $0.isFinite && $0 >= 0 ? AutomaticSyncPendingAgeBucket.bucket(for: $0) : nil
        } ?? .unknown
    }

    public mutating func noteDelivery(_ outcome: AutomaticSyncDeliveryOutcome, now: Date) {
        delivery = outcome
        deliveryTimeBucket = Self.timeBucket(now)
        if outcome == .accepted, outbox == .notRun { outbox = .notNeeded }
        if outcome == .rejected || outcome == .retired { outbox = .failed }
    }

    public mutating func noteQueued(itemIDs: [UUID], complete: Bool, now: Date) {
        let items = pendingItems + itemIDs.filter { !pendingItems.contains($0) }
        truncated = truncated || items.count > Self.maximumPendingItems
        pendingItems = Array(items.prefix(Self.maximumPendingItems))
        outbox = complete && !itemIDs.isEmpty && !truncated ? .queued : .partial
        delivery = .notRun
        deliveryTimeBucket = Self.timeBucket(now)
    }

    @discardableResult
    mutating func noteDelivery(itemID: UUID, outcome: AutomaticSyncDeliveryOutcome, now: Date) -> Bool {
        guard pendingItems.contains(itemID) else { return false }
        if outcome == .accepted {
            pendingItems.removeAll { $0 == itemID }
            if !pendingItems.isEmpty || truncated || outbox != .queued { return true }
        }
        noteDelivery(outcome, now: now)
        return true
    }

    static func timeBucket(_ date: Date) -> Int? {
        let value = floor(date.timeIntervalSince1970 / 900)
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }
}

/// Outcome of the settings-store accepted-marker write, not the in-memory run gate.
public enum AutomaticSyncDurableAdmission: String, Codable, Sendable {
    case unknown, persisted, failed
}

public struct AutomaticSyncCausalChain: Codable, Equatable, Sendable {
    public var version = 2
    public var durableAdmission: AutomaticSyncDurableAdmission
    public var observerFailureRetention: BackgroundRecoveryDurableState?
    public var initialRecoveryPending: BackgroundObserverPendingDiagnostic?
    public var remainingRecoveryPending: BackgroundObserverPendingDiagnostic?
    public var lanes: [AutomaticSyncLaneEvidence]
    public var truncated: Bool

    public init(lanes: [AutomaticSyncLaneEvidence], truncated: Bool = false,
                durableAdmission: AutomaticSyncDurableAdmission = .unknown) {
        self.durableAdmission = durableAdmission
        self.lanes = Array(lanes.prefix(BackgroundSyncWorkPlan.maximumLaneAttempts))
        self.truncated = truncated || lanes.count > BackgroundSyncWorkPlan.maximumLaneAttempts
        bound()
    }

    private enum CodingKeys: String, CodingKey {
        case version, durableAdmission, lanes, truncated
        case observerFailureRetention, initialRecoveryPending, remainingRecoveryPending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        observerFailureRetention = try? container.decode(BackgroundRecoveryDurableState.self, forKey: .observerFailureRetention)
        initialRecoveryPending = try? container.decode(BackgroundObserverPendingDiagnostic.self, forKey: .initialRecoveryPending)
        remainingRecoveryPending = try? container.decode(BackgroundObserverPendingDiagnostic.self, forKey: .remainingRecoveryPending)
        // Legacy, malformed and future marker values retain the run but cannot prove durability.
        durableAdmission = (try? container.decode(AutomaticSyncDurableAdmission.self, forKey: .durableAdmission)) ?? .unknown
        // Unknown/future evidence is not success and cannot discard the legacy run envelope.
        if let decoded = try? container.decode([AutomaticSyncLaneEvidence].self, forKey: .lanes) {
            lanes = decoded
            truncated = (try? container.decode(Bool.self, forKey: .truncated)) ?? true
        } else {
            lanes = []
            truncated = true
        }
        bound()
    }

    public func encode(to encoder: Encoder) throws {
        var bounded = self
        bounded.bound()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bounded.version, forKey: .version)
        try container.encode(bounded.durableAdmission, forKey: .durableAdmission)
        try container.encodeIfPresent(bounded.observerFailureRetention, forKey: .observerFailureRetention)
        try container.encodeIfPresent(bounded.initialRecoveryPending, forKey: .initialRecoveryPending)
        try container.encodeIfPresent(bounded.remainingRecoveryPending, forKey: .remainingRecoveryPending)
        try container.encode(bounded.lanes, forKey: .lanes)
        try container.encode(bounded.truncated, forKey: .truncated)
    }

    private mutating func bound() {
        truncated = truncated || lanes.count > BackgroundSyncWorkPlan.maximumLaneAttempts
        lanes = Array(lanes.prefix(BackgroundSyncWorkPlan.maximumLaneAttempts))
        for index in lanes.indices {
            if lanes[index].pendingItems.count > AutomaticSyncLaneEvidence.maximumPendingItems {
                lanes[index].pendingItems = Array(lanes[index].pendingItems.prefix(AutomaticSyncLaneEvidence.maximumPendingItems))
                lanes[index].truncated = true
            }
            truncated = truncated || lanes[index].truncated
        }
    }

    @discardableResult
    mutating func noteDelivery(itemID: UUID, outcome: AutomaticSyncDeliveryOutcome, now: Date) -> Bool {
        var matched = false
        for index in lanes.indices {
            if lanes[index].noteDelivery(itemID: itemID, outcome: outcome, now: now) { matched = true }
        }
        return matched
    }

    /// A final run snapshot must not resurrect FIFO references already accepted by a late callback.
    mutating func mergeDelivery(from previous: Self) {
        guard version == previous.version else { return }
        // A stale final snapshot must not erase an already recorded marker outcome.
        if durableAdmission == .unknown { durableAdmission = previous.durableAdmission }
        for index in lanes.indices where previous.lanes.indices.contains(index) {
            let old = previous.lanes[index]
            guard lanes[index].lane == old.lane,
                  lanes[index].queryTimeBucket == old.queryTimeBucket else { continue }
            if old.delivery == .rejected || old.delivery == .retired {
                lanes[index].outbox = .failed
                lanes[index].delivery = old.delivery
                lanes[index].deliveryTimeBucket = old.deliveryTimeBucket
            } else if old.delivery == .accepted {
                lanes[index].delivery = old.delivery
                lanes[index].deliveryTimeBucket = old.deliveryTimeBucket
                lanes[index].pendingItems = []
            } else if old.outbox == .queued, lanes[index].outbox == .queued {
                lanes[index].pendingItems = lanes[index].pendingItems.filter { old.pendingItems.contains($0) }
                if old.delivery != .notRun {
                    lanes[index].delivery = old.delivery
                    lanes[index].deliveryTimeBucket = old.deliveryTimeBucket
                }
            }
        }
    }
}

public enum CoreFreshnessReleaseDecision: String, Equatable, Sendable { case hold = "HOLD", pass = "PASS" }

public enum CoreLaneSourceFreshnessRequirement: Equatable, Sendable {
    case queryCompletionOnly
    case newestSample(maximumAge: TimeInterval)
}

/// A pure evidence gate, not a product release threshold. Callers must supply approved age limits.
/// Receiver totals and an empty outbox deliberately are not inputs.
public enum CoreFreshnessReleasePolicy {
    public static let requiredLanes: Set<AutomaticSyncDiagnosticLane> = [.sleep, .dailyActivity, .steps, .workouts]

    public static func evaluate(
        records: [AutomaticSyncDiagnosticRecord],
        now: Date,
        maximumQueryAge: TimeInterval,
        maximumDeliveryAge: TimeInterval,
        sourceFreshnessRequirements: [AutomaticSyncDiagnosticLane: CoreLaneSourceFreshnessRequirement]
    ) -> CoreFreshnessReleaseDecision {
        guard maximumQueryAge.isFinite, maximumQueryAge >= 0,
              maximumDeliveryAge.isFinite, maximumDeliveryAge >= 0,
              Set(sourceFreshnessRequirements.keys) == requiredLanes,
              AutomaticSyncLaneEvidence.timeBucket(now) != nil else { return .hold }
        var fresh = Set<AutomaticSyncDiagnosticLane>()
        for record in records {
            guard record.admissionResult == .accepted,
                  let chain = record.causalChain, chain.version == 2, !chain.truncated,
                  chain.durableAdmission == .persisted,
                  chain.lanes.count <= BackgroundSyncWorkPlan.maximumLaneAttempts else { continue }
            for lane in chain.lanes where requiredLanes.contains(lane.lane) {
                guard let sourceRequirement = sourceFreshnessRequirements[lane.lane],
                      !lane.truncated, lane.attempted,
                      lane.query == .records || lane.query == .noRecords,
                      sourceIsFresh(lane, requirement: sourceRequirement),
                      recent(lane.queryTimeBucket, now: now, limit: maximumQueryAge),
                      recent(lane.deliveryTimeBucket, now: now, limit: maximumDeliveryAge),
                      lane.delivery == .accepted,
                      lane.pendingItems.isEmpty else { continue }
                fresh.insert(lane.lane)
            }
        }
        return fresh == requiredLanes ? .pass : .hold
    }

    private static func sourceIsFresh(
        _ lane: AutomaticSyncLaneEvidence,
        requirement: CoreLaneSourceFreshnessRequirement
    ) -> Bool {
        switch requirement {
        case .queryCompletionOnly:
            return lane.query == .records || lane.query == .noRecords
        case .newestSample(let maximumAge):
            guard lane.query == .records, maximumAge.isFinite, maximumAge >= 0 else {
                return false
            }
            return lane.newestSampleAge.isConservativelyWithin(maximumAge)
        }
    }

    private static func recent(_ bucket: Int?, now: Date, limit: TimeInterval) -> Bool {
        guard let bucket, bucket >= 0 else { return false }
        // Use the oldest possible age in the bucket; rounding can HOLD, never create a false PASS.
        let age = now.timeIntervalSince1970 - Double(bucket) * 900
        return age.isFinite && age >= 0 && age <= limit
    }
}

private extension AutomaticSyncPendingAgeBucket {
    func isConservativelyWithin(_ maximumAge: TimeInterval) -> Bool {
        let exclusiveUpperBound: TimeInterval
        switch self {
        case .underFifteenMinutes: exclusiveUpperBound = 900
        case .fifteenMinutesToOneHour: exclusiveUpperBound = 3_600
        case .oneToSixHours: exclusiveUpperBound = 21_600
        case .sixTo24Hours: exclusiveUpperBound = 86_400
        case .oneToThreeDays: exclusiveUpperBound = 259_200
        case .none, .unknown, .overThreeDays: return false
        }
        return exclusiveUpperBound <= maximumAge
    }
}

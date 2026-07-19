#if canImport(HealthKit)
import Foundation
import HealthKit

public enum HealthKitStepCountReaderError: Error, Equatable {
    case healthDataUnavailable
    case stepCountTypeUnavailable
    case invalidWindow
    case anchorUnavailable
}

public enum HealthKitAnchorCursorCodecError: Error, Equatable, LocalizedError {
    case invalidBase64
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidBase64:
            "HealthKit anchor cursor was not valid base64."
        case .decodeFailed:
            "HealthKit anchor cursor could not be decoded."
        }
    }
}

public enum HealthKitAnchorCursorCodec {
    public static func encode(_ anchor: HKQueryAnchor) throws -> String {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        )
        return data.base64EncodedString()
    }

    public static func decode(_ cursorValue: String) throws -> HKQueryAnchor {
        guard let data = Data(base64Encoded: cursorValue) else {
            throw HealthKitAnchorCursorCodecError.invalidBase64
        }
        do {
            guard let anchor = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: HKQueryAnchor.self,
                from: data
            ) else {
                throw HealthKitAnchorCursorCodecError.decodeFailed
            }
            return anchor
        } catch let error as HealthKitAnchorCursorCodecError {
            throw error
        } catch {
            throw HealthKitAnchorCursorCodecError.decodeFailed
        }
    }

    public static func decodeOptional(_ cursorValue: String?) throws -> HKQueryAnchor? {
        guard let cursorValue, !cursorValue.isEmpty else { return nil }
        return try decode(cursorValue)
    }
}

private final class HealthKitQueryContinuationState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var query: HKQuery?
    private var finished = false

    func installAndExecute(
        continuation: CheckedContinuation<Value, Error>,
        query: HKQuery,
        healthStore: HKHealthStore
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.query = query
        healthStore.execute(query)
        lock.unlock()
    }

    func resume(with result: sending Result<Value, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        query = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel(healthStore: HKHealthStore) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        let query = query
        self.continuation = nil
        self.query = nil
        lock.unlock()
        if let query {
            healthStore.stop(query)
        }
        continuation?.resume(throwing: CancellationError())
    }
}

func executeCancellableHealthKitQuery<Value>(
    healthStore: HKHealthStore,
    makeQuery: (_ completion: @escaping @Sendable (sending Result<Value, Error>) -> Void) -> HKQuery
) async throws -> Value {
    let state = HealthKitQueryContinuationState<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let query = makeQuery { result in
                state.resume(with: result)
            }
            state.installAndExecute(
                continuation: continuation,
                query: query,
                healthStore: healthStore
            )
        }
    } onCancel: {
        state.cancel(healthStore: healthStore)
    }
}

public final class HealthKitStepCountReader: @unchecked Sendable {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    public init(healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.healthStore = healthStore
        self.calendar = calendar
    }

    public func readDailyStepCounts(start: Date, end: Date) async throws -> [DailyStepCount] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitStepCountReaderError.healthDataUnavailable
        }
        guard start < end else {
            throw HealthKitStepCountReaderError.invalidWindow
        }
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            throw HealthKitStepCountReaderError.stepCountTypeUnavailable
        }

        let anchorDate = calendar.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let interval = DateComponents(day: 1)

        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                guard let results else {
                    completion(.success([]))
                    return
                }

                var dailyCounts: [DailyStepCount] = []
                results.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let count = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    dailyCounts.append(
                        DailyStepCount(
                            dayStart: statistics.startDate,
                            dayEnd: min(statistics.endDate, end),
                            count: count
                        )
                    )
                }
                completion(.success(dailyCounts))
            }

            return query
        }
    }

    public func readAnchoredStepChanges(
        anchorCursorValue: String?,
        predicateStart: Date?,
        receivedAt: Date = Date()
    ) async throws -> HealthKitAnchoredStepChanges {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitStepCountReaderError.healthDataUnavailable
        }
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            throw HealthKitStepCountReaderError.stepCountTypeUnavailable
        }

        let anchor = try HealthKitAnchorCursorCodec.decodeOptional(anchorCursorValue)
        let predicate = predicateStart.map {
            HKQuery.predicateForSamples(withStart: $0, end: nil, options: [.strictStartDate])
        }

        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKAnchoredObjectQuery(
                type: stepType,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                guard let newAnchor else {
                    completion(.failure(HealthKitStepCountReaderError.anchorUnavailable))
                    return
                }

                do {
                    let newAnchorCursorValue = try HealthKitAnchorCursorCodec.encode(newAnchor)
                    let stepSamples = ((samples as? [HKQuantitySample]) ?? [])
                        .map { stepSampleSummary(for: $0) }
                    let deletedStepSamples = (deletedObjects ?? []).map {
                        HealthKitDeletedStepSample(uuid: $0.uuid, deletedAt: receivedAt)
                    }
                    completion(.success(
                        HealthKitAnchoredStepChanges(
                            stepSamples: stepSamples,
                            deletedStepSamples: deletedStepSamples,
                            anchorCursorValue: newAnchorCursorValue,
                            windowStart: anchoredStepWindowStart(
                                stepSamples: stepSamples,
                                deletedStepSamples: deletedStepSamples,
                                predicateStart: predicateStart,
                                receivedAt: receivedAt
                            ),
                            windowEnd: receivedAt
                        )
                    ))
                } catch {
                    completion(.failure(error))
                }
            }

            return query
        }
    }
}

private func stepSampleSummary(for sample: HKQuantitySample) -> HealthKitStepSampleSummary {
    HealthKitStepSampleSummary(
        uuid: sample.uuid,
        start: sample.startDate,
        end: sample.endDate,
        count: sample.quantity.doubleValue(for: .count()),
        provenance: HealthKitSampleProvenance(sample: sample)
    )
}

private func anchoredStepWindowStart(
    stepSamples: [HealthKitStepSampleSummary],
    deletedStepSamples: [HealthKitDeletedStepSample],
    predicateStart: Date?,
    receivedAt: Date
) -> Date {
    let candidates = stepSamples.map(\.start) + deletedStepSamples.map(\.deletedAt) + [predicateStart ?? receivedAt]
    return candidates.min() ?? receivedAt
}

public enum HealthKitWorkoutReaderError: Error, Equatable {
    case healthDataUnavailable
    case invalidWindow
    case anchorUnavailable
}

public final class HealthKitWorkoutReader: @unchecked Sendable {
    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public func readWorkouts(start: Date, end: Date) async throws -> [HealthKitWorkoutSummary] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitWorkoutReaderError.healthDataUnavailable
        }
        guard start < end else {
            throw HealthKitWorkoutReaderError.invalidWindow
        }

        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                let workouts = (samples as? [HKWorkout]) ?? []
                let summaries = workouts.map { workoutSummary(for: $0) }
                completion(.success(summaries))
            }

            return query
        }
    }

    public func readAnchoredWorkoutChanges(
        anchorCursorValue: String?,
        predicateStart: Date?,
        receivedAt: Date = Date()
    ) async throws -> HealthKitAnchoredWorkoutChanges {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitWorkoutReaderError.healthDataUnavailable
        }

        let workoutType = HKObjectType.workoutType()
        let anchor = try HealthKitAnchorCursorCodec.decodeOptional(anchorCursorValue)
        let predicate = predicateStart.map {
            HKQuery.predicateForSamples(withStart: $0, end: nil, options: [.strictStartDate])
        }

        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKAnchoredObjectQuery(
                type: workoutType,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                guard let newAnchor else {
                    completion(.failure(HealthKitWorkoutReaderError.anchorUnavailable))
                    return
                }

                do {
                    let newAnchorCursorValue = try HealthKitAnchorCursorCodec.encode(newAnchor)
                    let workouts = ((samples as? [HKWorkout]) ?? []).map { workoutSummary(for: $0) }
                    let deletedWorkouts = (deletedObjects ?? []).map {
                        HealthKitDeletedWorkout(uuid: $0.uuid, deletedAt: receivedAt)
                    }
                    completion(.success(
                        HealthKitAnchoredWorkoutChanges(
                            workouts: workouts,
                            deletedWorkouts: deletedWorkouts,
                            anchorCursorValue: newAnchorCursorValue,
                            windowStart: anchoredWorkoutWindowStart(
                                workouts: workouts,
                                deletedWorkouts: deletedWorkouts,
                                predicateStart: predicateStart,
                                receivedAt: receivedAt
                            ),
                            windowEnd: receivedAt
                        )
                    ))
                } catch {
                    completion(.failure(error))
                }
            }

            return query
        }
    }
}

private func workoutSummary(for workout: HKWorkout) -> HealthKitWorkoutSummary {
    HealthKitWorkoutSummary(
        uuid: workout.uuid,
        workoutType: workoutTypeString(for: workout.workoutActivityType),
        start: workout.startDate,
        end: workout.endDate,
        durationSeconds: max(0, Int(workout.duration.rounded())),
        activeEnergyKcal: activeEnergyKcal(for: workout),
        distanceMeters: workout.totalDistance?.doubleValue(for: .meter())
    )
}

private func anchoredWorkoutWindowStart(
    workouts: [HealthKitWorkoutSummary],
    deletedWorkouts: [HealthKitDeletedWorkout],
    predicateStart: Date?,
    receivedAt: Date
) -> Date {
    let candidates = workouts.map(\.start) + deletedWorkouts.map(\.deletedAt) + [predicateStart ?? receivedAt]
    return candidates.min() ?? receivedAt
}

private func activeEnergyKcal(for workout: HKWorkout) -> Double? {
    guard let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
        return nil
    }
    if #available(iOS 18.0, *) {
        return workout.statistics(for: activeEnergyType)?.sumQuantity()?.doubleValue(for: .kilocalorie())
    } else {
        return workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
    }
}

private func workoutTypeString(for activityType: HKWorkoutActivityType) -> String {
    switch activityType {
    case .running:
        return "running"
    case .walking:
        return "walking"
    case .cycling:
        return "cycling"
    case .swimming:
        return "swimming"
    case .hiking:
        return "hiking"
    case .yoga:
        return "yoga"
    case .traditionalStrengthTraining:
        return "traditional_strength_training"
    case .functionalStrengthTraining:
        return "functional_strength_training"
    case .highIntensityIntervalTraining:
        return "hiit"
    case .rowing:
        return "rowing"
    case .elliptical:
        return "elliptical"
    case .pilates:
        return "pilates"
    case .coreTraining:
        return "core_training"
    case .dance:
        return "dance"
    case .mindAndBody:
        return "mind_and_body"
    default:
        return "other"
    }
}

public enum HealthKitSleepReaderError: Error, Equatable {
    case healthDataUnavailable
    case sleepAnalysisTypeUnavailable
    case invalidWindow
    case anchorUnavailable
}

public final class HealthKitSleepReader: @unchecked Sendable {
    public static let boundaryExpansionSeconds: TimeInterval = 36 * 60 * 60

    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public func readSleepSessions(start: Date, end: Date) async throws -> [HealthKitSleepSessionSummary] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSleepReaderError.healthDataUnavailable
        }
        guard start < end else {
            throw HealthKitSleepReaderError.invalidWindow
        }
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitSleepReaderError.sleepAnalysisTypeUnavailable
        }

        let queryStart = start.addingTimeInterval(-Self.boundaryExpansionSeconds)
        let predicate = HKQuery.predicateForSamples(withStart: queryStart, end: end, options: [])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                let intervals = ((samples as? [HKCategorySample]) ?? [])
                    .compactMap { sleepIntervalCandidate(for: $0) }
                let sessions = sleepSessions(from: intervals)
                    .filter { $0.end > start && $0.start < end }
                completion(.success(sessions))
            }
            return query
        }
    }

    public func readAnchoredSleepChanges(
        anchorCursorValue: String?,
        historyStartDate: Date?,
        receivedAt: Date = Date()
    ) async throws -> HealthKitAnchoredSleepChanges {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSleepReaderError.healthDataUnavailable
        }
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitSleepReaderError.sleepAnalysisTypeUnavailable
        }
        let anchor = try HealthKitAnchorCursorCodec.decodeOptional(anchorCursorValue)
        let predicate = historyStartDate.map {
            HKQuery.predicateForSamples(
                withStart: $0.addingTimeInterval(-Self.boundaryExpansionSeconds),
                end: nil,
                options: []
            )
        }

        return try await executeCancellableHealthKitQuery(healthStore: healthStore) { completion in
            let query = HKAnchoredObjectQuery(
                type: sleepType,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let newAnchor else {
                    completion(.failure(HealthKitSleepReaderError.anchorUnavailable))
                    return
                }

                do {
                    let cursorValue = try HealthKitAnchorCursorCodec.encode(newAnchor)
                    let addedSamples = ((samples as? [HKCategorySample]) ?? [])
                        .compactMap { sleepChildSample(for: $0) }
                    let deletedSamples = (deletedObjects ?? []).map {
                        HealthKitDeletedSleepSample(
                            uuid: $0.uuid,
                            deletedAt: receivedAt
                        )
                    }
                    completion(.success(HealthKitAnchoredSleepChanges(
                        addedSamples: addedSamples,
                        deletedSamples: deletedSamples,
                        anchorCursorValue: cursorValue,
                        receivedAt: receivedAt
                    )))
                } catch {
                    completion(.failure(error))
                }
            }
            return query
        }
    }
}

private struct HealthKitSleepIntervalCandidate {
    let uuid: UUID
    let stage: String
    let start: Date
    let end: Date
}

private func sleepChildSample(for sample: HKCategorySample) -> HealthKitSleepChildSample? {
    guard let stage = sleepStageString(for: sample.value), sample.startDate < sample.endDate else {
        return nil
    }
    return HealthKitSleepChildSample(
        uuid: sample.uuid,
        stage: stage,
        start: sample.startDate,
        end: sample.endDate
    )
}

private func sleepIntervalCandidate(for sample: HKCategorySample) -> HealthKitSleepIntervalCandidate? {
    guard let stage = sleepStageString(for: sample.value), sample.startDate < sample.endDate else {
        return nil
    }
    return HealthKitSleepIntervalCandidate(
        uuid: sample.uuid,
        stage: stage,
        start: sample.startDate,
        end: sample.endDate
    )
}

private func sleepStageString(for value: Int) -> String? {
    if value == HKCategoryValueSleepAnalysis.inBed.rawValue {
        return "in_bed"
    }
    if #available(iOS 16.0, macOS 13.0, watchOS 9.0, *) {
        switch value {
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            return "awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            return "core"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return "deep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return "rem"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            return "core"
        default:
            break
        }
    }
    return nil
}

private func sleepSessions(from intervals: [HealthKitSleepIntervalCandidate]) -> [HealthKitSleepSessionSummary] {
    let sorted = intervals.sorted { lhs, rhs in
        if lhs.start == rhs.start {
            return lhs.uuid.uuidString < rhs.uuid.uuidString
        }
        return lhs.start < rhs.start
    }
    var sessions: [HealthKitSleepSessionSummary] = []
    var current: [HealthKitSleepIntervalCandidate] = []
    var currentEnd: Date?
    let maxGapSeconds: TimeInterval = 30 * 60

    func flushCurrent() {
        guard let first = current.first else { return }
        let start = current.map(\.start).min() ?? first.start
        let end = current.map(\.end).max() ?? first.end
        sessions.append(
            HealthKitSleepSessionSummary(
                uuid: first.uuid,
                start: start,
                end: end,
                stageIntervals: current.map {
                    HealthKitSleepStageSummary(stage: $0.stage, start: $0.start, end: $0.end)
                }
            )
        )
        current.removeAll()
        currentEnd = nil
    }

    for interval in sorted {
        if let end = currentEnd, interval.start.timeIntervalSince(end) > maxGapSeconds {
            flushCurrent()
        }
        current.append(interval)
        if currentEnd == nil || interval.end > currentEnd! {
            currentEnd = interval.end
        }
    }
    flushCurrent()
    return sessions
}
#endif

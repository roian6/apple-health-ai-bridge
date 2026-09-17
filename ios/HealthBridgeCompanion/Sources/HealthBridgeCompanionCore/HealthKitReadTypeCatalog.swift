#if canImport(HealthKit)
import HealthKit

public enum HealthKitReadTypeCatalog {
    public static func objectTypes(for healthTypes: [HealthBridgeHealthType]) -> Set<HKObjectType> {
        Set(healthTypes.compactMap { objectType(for: $0.typeCode) })
    }

    public static func sampleTypes(for healthTypes: [HealthBridgeHealthType]) -> [HKSampleType] {
        healthTypes.compactMap { objectType(for: $0.typeCode) as? HKSampleType }
    }

    public static func objectTypes(forTypeCodes typeCodes: [String]) -> [HKObjectType] {
        Array(Set(typeCodes))
            .compactMap(objectType(for:))
            .sorted { $0.identifier < $1.identifier }
    }

    public static func availableTypeCodes(forTypeCodes typeCodes: [String]) -> [String] {
        typeCodes
            .filter { objectType(for: $0) != nil }
            .sorted()
    }

    public static func sampleTypes(forTypeCodes typeCodes: [String]) -> [HKSampleType] {
        objectTypes(forTypeCodes: typeCodes).compactMap { $0 as? HKSampleType }
    }

    private static func objectType(for typeCode: String) -> HKObjectType? {
        guard let entry = HealthKitTypeCatalog.entry(for: typeCode) else {
            return nil
        }
        switch entry.objectKind {
        case .quantity:
            return HealthKitQuantitySampleMapper.quantityType(for: entry)
        case .category:
            return categoryType(for: entry)
        case .workout:
            return HKObjectType.workoutType()
        }
    }

    private static func categoryType(for entry: HealthKitTypeCatalogEntry) -> HKCategoryType? {
        switch entry.typeCode {
        case "sleep_analysis":
            return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        default:
            return nil
        }
    }
}

public enum HealthKitAuthorizationError: Error, Equatable {
    case healthDataUnavailable
    case emptyReadTypeSet
}

public final class HealthStoreAuthorizer {
    private let healthStoreProvider: () -> HKHealthStore

    public init(healthStore: HKHealthStore? = nil) {
        if let healthStore {
            healthStoreProvider = { healthStore }
        } else {
            healthStoreProvider = { HKHealthStore() }
        }
    }

    public func requestReadAuthorization(healthTypes: [HealthBridgeHealthType]) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitAuthorizationError.healthDataUnavailable
        }
        let readTypes = HealthKitReadTypeCatalog.objectTypes(for: healthTypes)
        guard !readTypes.isEmpty else {
            throw HealthKitAuthorizationError.emptyReadTypeSet
        }
        try await healthStoreProvider().requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes)
    }

    public func requestReadAuthorization(typeCodes: [String]) async throws {
        let readTypes = try readTypesForAuthorization(typeCodes: typeCodes)
        try await healthStoreProvider().requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes)
    }

    public func requestStatusForReadAuthorization(typeCodes: [String]) async throws -> HKAuthorizationRequestStatus {
        let readTypes = try readTypesForAuthorization(typeCodes: typeCodes)
        return try await healthStoreProvider().statusForAuthorizationRequest(toShare: Set<HKSampleType>(), read: readTypes)
    }

    private func readTypesForAuthorization(typeCodes: [String]) throws -> Set<HKObjectType> {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitAuthorizationError.healthDataUnavailable
        }
        let readTypes = Set(HealthKitReadTypeCatalog.objectTypes(forTypeCodes: typeCodes))
        guard !readTypes.isEmpty else {
            throw HealthKitAuthorizationError.emptyReadTypeSet
        }
        return readTypes
    }
}

@MainActor
public final class HealthKitBackgroundDeliveryCoordinator {
    private let healthStore: HKHealthStore
    private var activeObserverQueries: [HKObserverQuery] = []
    private var callbackGeneration: UInt64 = 0
    private let recovery: BackgroundDeliveryFailureRecovery
    private var registrationTypes: [String: HKSampleType] = [:]
    private var registrationRetryTask: Task<Void, Never>?
    private var registrationHandler: @MainActor (String, Bool) -> Void = { _, _ in }
    private var recoveryReadbackHandler: @MainActor (BackgroundDeliveryRecoveryReadback) -> Void = { _ in }
    private var isCurrent: @MainActor () -> Bool = { false }

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        recovery: BackgroundDeliveryFailureRecovery
    ) {
        self.healthStore = healthStore
        self.recovery = recovery
    }

    public var activeObserverCount: Int {
        activeObserverQueries.count
    }

    public func start(
        healthTypes: [HealthBridgeHealthType] = HealthBridgeBackgroundSync.observedHealthTypes,
        registrationHandler: @escaping @MainActor (_ typeCode: String, _ succeeded: Bool) -> Void = { _, _ in },
        recoveryReadbackHandler: @escaping @MainActor (BackgroundDeliveryRecoveryReadback) -> Void = { _ in },
        isCurrent: @escaping @MainActor () -> Bool,
        observerAdmissionHandler: @escaping @MainActor (_ typeCode: String, _ runID: UUID) async -> AutomaticSyncObserverEventAdmission,
        observerCompletionHandler: @escaping @MainActor (AutomaticSyncDiagnosticDraft, TimeInterval) -> Void = { _, _ in },
        eventHandler: @escaping @MainActor (_ typeCode: String, _ runID: UUID) async -> AutomaticSyncDiagnosticDraft?
    ) {
        callbackGeneration &+= 1
        let expectedCallbackGeneration = callbackGeneration
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        self.registrationHandler = registrationHandler
        self.recoveryReadbackHandler = recoveryReadbackHandler
        self.isCurrent = isCurrent
        registrationTypes = [:]
        stopActiveObserverQueries()
        guard HKHealthStore.isHealthDataAvailable(), isCurrent() else { return }
        recovery.activate(generation: expectedCallbackGeneration)

        for healthType in healthTypes {
            guard let sampleType = HealthKitReadTypeCatalog.sampleTypes(for: [healthType]).first else {
                continue
            }
            registrationTypes[healthType.typeCode] = sampleType
            let observer = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                let completion = BackgroundObserverAcknowledgement(completionHandler)
                let observerStartedAt = Date()
                guard error == nil else {
                    let completionLatency = Date().timeIntervalSince(observerStartedAt)
                    let runID = UUID()
                    Task { @MainActor [weak self] in
                        guard let self, self.callbackGeneration == expectedCallbackGeneration,
                              self.isCurrent() else {
                            completion.call()
                            return
                        }
                        await AutomaticSyncObserverEventLifecycle.process(
                            startedAt: observerStartedAt,
                            admissionHandler: {
                                await observerAdmissionHandler(
                                    healthType.typeCode,
                                    runID
                                )
                            },
                            eventHandler: {
                                let diagnostic = AutomaticSyncDiagnosticDraft(
                                    observerFailureLane: BackgroundRecoveryLane(
                                        typeCode: healthType.typeCode
                                    ),
                                    runID: runID,
                                    completionLatency: completionLatency,
                                    durableState: .available
                                )
                                diagnostic.noteCompletion(.deferred)
                                self.recoveryReadbackHandler(self.recovery.readback)
                                _ = await eventHandler(healthType.typeCode, runID)
                                return diagnostic
                            },
                            acknowledge: completion.call,
                            persistDiagnostic: observerCompletionHandler
                        )
                    }
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, self.callbackGeneration == expectedCallbackGeneration,
                          self.isCurrent() else {
                        completion.call()
                        return
                    }
                    let runID = UUID()
                    await AutomaticSyncObserverEventLifecycle.process(
                        startedAt: observerStartedAt,
                        admissionHandler: {
                            await observerAdmissionHandler(healthType.typeCode, runID)
                        },
                        eventHandler: {
                            await eventHandler(healthType.typeCode, runID)
                        },
                        acknowledge: completion.call,
                        persistDiagnostic: observerCompletionHandler
                    )
                }
            }
            healthStore.execute(observer)
            activeObserverQueries.append(observer)
        }
        reconcileRegistrations()
    }

    public func reconcileRegistrations() {
        guard isCurrent() else { return }
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        let expectedGeneration = callbackGeneration
        do {
            let attempts = try recovery.claimRegistrations(
                typeCodes: Array(registrationTypes.keys), generation: expectedGeneration
            )
            for attempt in attempts {
                guard let sampleType = registrationTypes[attempt.typeCode] else { continue }
                healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { succeeded, error in
                    let enabled = succeeded && error == nil
                    Task { @MainActor [weak self] in
                        guard let self, self.callbackGeneration == expectedGeneration,
                              self.isCurrent() else { return }
                        do {
                            guard try self.recovery.completeRegistration(attempt, succeeded: enabled) else { return }
                        } catch {
                            self.recoveryReadbackHandler(self.recovery.readback)
                            return
                        }
                        self.registrationHandler(attempt.typeCode, enabled)
                        self.recoveryReadbackHandler(self.recovery.readback)
                        self.scheduleRegistrationRetry()
                    }
                }
            }
        } catch {
            recoveryReadbackHandler(recovery.readback)
            return
        }
        recoveryReadbackHandler(recovery.readback)
        scheduleRegistrationRetry()
    }

    private func scheduleRegistrationRetry() {
        guard registrationRetryTask == nil, isCurrent(),
              let deadline = recovery.nextRegistrationRetryAt else { return }
        let expectedGeneration = callbackGeneration
        registrationRetryTask = Task { @MainActor [weak self] in
            do {
                let delay = min(BackgroundDeliveryFailureRecovery.maximumRetryInterval, max(0, deadline.timeIntervalSinceNow))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
            } catch { return } // Cancellation is the stop/connection fence, not a retry failure.
            guard let self, self.callbackGeneration == expectedGeneration,
                  self.isCurrent() else { return }
            self.registrationRetryTask = nil
            self.reconcileRegistrations()
        }
    }

    public func stop(
        healthTypes: [HealthBridgeHealthType] = HealthBridgeBackgroundSync.observedHealthTypes
    ) {
        callbackGeneration &+= 1
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        isCurrent = { false }
        registrationTypes = [:]
        recovery.stop()
        guard HKHealthStore.isHealthDataAvailable() else {
            activeObserverQueries.removeAll()
            return
        }
        stopActiveObserverQueries()

        let sampleTypes = HealthKitReadTypeCatalog.sampleTypes(for: healthTypes)
        for sampleType in sampleTypes {
            healthStore.disableBackgroundDelivery(for: sampleType) { _, _ in }
        }
    }

    private func stopActiveObserverQueries() {
        for query in activeObserverQueries {
            healthStore.stop(query)
        }
        activeObserverQueries.removeAll()
    }
}
#endif

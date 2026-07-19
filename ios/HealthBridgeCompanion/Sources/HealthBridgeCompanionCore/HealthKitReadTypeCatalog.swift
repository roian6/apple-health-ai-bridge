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

private final class HealthKitObserverCompletion: @unchecked Sendable {
    private let completionHandler: () -> Void

    init(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
    }

    func call() {
        completionHandler()
    }
}

@MainActor
public final class HealthKitBackgroundDeliveryCoordinator {
    private let healthStore: HKHealthStore
    private var activeObserverQueries: [HKObserverQuery] = []
    private var callbackGeneration: UInt64 = 0

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public var activeObserverCount: Int {
        activeObserverQueries.count
    }

    public func start(
        healthTypes: [HealthBridgeHealthType] = HealthBridgeBackgroundSync.observedHealthTypes,
        registrationHandler: @escaping @MainActor (_ typeIdentifier: String, _ succeeded: Bool, _ errorDescription: String?) -> Void = { _, _, _ in },
        eventHandler: @escaping @MainActor (_ typeCode: String) async -> Void
    ) {
        callbackGeneration &+= 1
        let expectedCallbackGeneration = callbackGeneration
        guard HKHealthStore.isHealthDataAvailable() else {
            stopActiveObserverQueries()
            registrationHandler("healthkit", false, "Health data is unavailable on this device.")
            return
        }
        stopActiveObserverQueries()

        for healthType in healthTypes {
            guard let sampleType = HealthKitReadTypeCatalog.sampleTypes(for: [healthType]).first else {
                continue
            }
            let observer = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                guard error == nil else {
                    completionHandler()
                    return
                }
                let completion = HealthKitObserverCompletion(completionHandler)
                Task { @MainActor [weak self] in
                    guard self?.callbackGeneration == expectedCallbackGeneration else {
                        completion.call()
                        return
                    }
                    await eventHandler(healthType.typeCode)
                    completion.call()
                }
            }
            healthStore.execute(observer)
            activeObserverQueries.append(observer)
            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { succeeded, error in
                let typeIdentifier = sampleType.identifier
                let errorDescription = error.map { String(describing: $0) }
                Task { @MainActor [weak self] in
                    guard self?.callbackGeneration == expectedCallbackGeneration else { return }
                    registrationHandler(typeIdentifier, succeeded, errorDescription)
                }
            }
        }
    }

    public func stop(
        healthTypes: [HealthBridgeHealthType] = HealthBridgeBackgroundSync.observedHealthTypes
    ) {
        callbackGeneration &+= 1
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

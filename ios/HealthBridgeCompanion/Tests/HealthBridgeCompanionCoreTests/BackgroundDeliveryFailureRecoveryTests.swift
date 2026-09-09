import XCTest
@testable import HealthBridgeCompanionCore

final class BackgroundDeliveryFailureRecoveryTests: XCTestCase {
    @MainActor
    func testObserverFailurePersistsBeforeAcknowledgementAndOffersOnlyOneRecovery() async throws {
        let store = RecoveryMemoryStore()
        let recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 7)
        var acknowledgements = 0
        store.beforeSave = { XCTAssertEqual(acknowledgements, 0) }
        let result = recovery.processObserverFailure(
            typeCode: "heart_rate", generation: 7,
            acknowledge: { acknowledgements += 1 }
        )
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(result, .retained(lane: .quantity, localRecoveryEligible: true))
        XCTAssertEqual(store.snapshot.observerGenerations[.quantity], 1)
        store.beforeSave = nil
        for _ in 0..<100 {
            XCTAssertEqual(recovery.processObserverFailure(
                typeCode: "oxygen_saturation", generation: 7, acknowledge: {}
            ), .retained(lane: .quantity, localRecoveryEligible: false))
        }
        XCTAssertEqual(store.snapshot.observerGenerations.count, 1)
    }

    @MainActor
    func testUnavailableDurableStateIsExplicitAndStaleCallbacksOnlyAcknowledge() async {
        let store = RecoveryMemoryStore()
        let recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 1)
        store.failSave = true
        var acknowledgements = 0
        XCTAssertEqual(recovery.processObserverFailure(
            typeCode: "sleep_analysis", generation: 1,
            acknowledge: { acknowledgements += 1 }
        ), .durableStateUnavailable(lane: .sleep))
        XCTAssertEqual(acknowledgements, 1)
        recovery.stop()
        XCTAssertEqual(recovery.processObserverFailure(
            typeCode: "sleep_analysis", generation: 1,
            acknowledge: { acknowledgements += 1 }
        ), .ignored)
        XCTAssertEqual(acknowledgements, 2)
        XCTAssertEqual(store.saveCount, 1)
    }

    @MainActor
    func testRegistrationRetriesOnlyFailedRuntimeTypesAtDeterministicDeadline() async throws {
        let store = RecoveryMemoryStore()
        var now = Date(timeIntervalSince1970: 1_000)
        let recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
        recovery.activate(generation: 3)
        let initial = try recovery.claimRegistrations(typeCodes: ["heart_rate", "oxygen_saturation", "sleep_analysis"], generation: 3)
        XCTAssertEqual(initial.map(\.typeCode), ["heart_rate", "oxygen_saturation", "sleep_analysis"])
        XCTAssertTrue(try recovery.claimRegistrations(typeCodes: initial.map(\.typeCode), generation: 3).isEmpty)
        for attempt in initial {
            try recovery.completeRegistration(attempt, succeeded: attempt.typeCode != "heart_rate")
            try recovery.completeRegistration(attempt, succeeded: false) // duplicate ignored
        }
        XCTAssertEqual(recovery.readback.failedRegistrationLanes, [.quantity])
        now = now.addingTimeInterval(59)
        XCTAssertTrue(try recovery.claimRegistrations(typeCodes: initial.map(\.typeCode), generation: 3).isEmpty)
        now = now.addingTimeInterval(1)
        let retry = try recovery.claimRegistrations(typeCodes: initial.map(\.typeCode), generation: 3)
        XCTAssertEqual(retry.map(\.typeCode), ["heart_rate"])
        XCTAssertEqual(store.snapshot.registrations[.quantity]?.attemptCount, 2)
        XCTAssertEqual(store.snapshot.registrations[.quantity]?.nextEligibleAt, now.addingTimeInterval(120))
        try recovery.completeRegistration(try XCTUnwrap(retry.first), succeeded: true)
        XCTAssertTrue(recovery.readback.failedRegistrationLanes.isEmpty)
    }

    @MainActor
    func testReloadHonorsBackoffAndExhaustionWithoutPersistingOptionalTypes() async throws {
        let store = RecoveryMemoryStore()
        var now = Date(timeIntervalSince1970: 2_000)
        var recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
        recovery.activate(generation: 1)
        var attempts = try recovery.claimRegistrations(typeCodes: ["heart_rate"], generation: 1)
        for count in 1...BackgroundDeliveryFailureRecovery.maximumRegistrationAttempts {
            XCTAssertEqual(attempts.count, 1)
            try recovery.completeRegistration(try XCTUnwrap(attempts.first), succeeded: false)
            recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
            recovery.activate(generation: UInt64(count + 1))
            let healthyAttempts = try recovery.claimRegistrations(typeCodes: ["heart_rate", "sleep_analysis"], generation: UInt64(count + 1))
            XCTAssertTrue(healthyAttempts.allSatisfy { $0.typeCode == "sleep_analysis" })
            for healthy in healthyAttempts { try recovery.completeRegistration(healthy, succeeded: true) }
            now = try XCTUnwrap(store.snapshot.registrations[.quantity]?.nextEligibleAt)
            attempts = try recovery.claimRegistrations(typeCodes: ["heart_rate"], generation: UInt64(count + 1))
        }
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertEqual(recovery.readback.exhaustedRegistrationLaneCount, 1)
        let data = try JSONEncoder().encode(store.snapshot)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("heart_rate"))
        XCTAssertFalse(text.contains("sleep_analysis"))
        XCTAssertLessThan(data.count, 2_048)
    }

    @MainActor
    func testReservationFailureAndGenerationFencesPreventExternalAttempts() async throws {
        let store = RecoveryMemoryStore()
        let recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 4)
        store.failSave = true
        XCTAssertThrowsError(try recovery.claimRegistrations(typeCodes: ["steps"], generation: 4))
        store.failSave = false
        let attempt = try XCTUnwrap(recovery.claimRegistrations(typeCodes: ["steps"], generation: 4).first)
        recovery.stop()
        XCTAssertTrue(try recovery.claimRegistrations(typeCodes: ["steps"], generation: 4).isEmpty)
        recovery.activate(generation: 5)
        try recovery.completeRegistration(attempt, succeeded: true)
        XCTAssertNotNil(store.snapshot.registrations[.steps])
        XCTAssertTrue(try recovery.claimRegistrations(typeCodes: ["steps"], generation: 4).isEmpty)
    }


    @MainActor
    func testObserverCoarseWorkSurvivesReloadAndClearsOnlyMatchingCompletedGeneration() async throws {
        let store = RecoveryMemoryStore()
        var recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 1)
        _ = recovery.processObserverFailure(typeCode: "heart_rate", generation: 1, acknowledge: {})
        recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 2)
        let available = ["steps", "heart_rate", "oxygen_saturation"]
        let admitted = try recovery.observerGenerationSnapshot()
        XCTAssertEqual(try recovery.pendingObserverTypeCodes(availableTypeCodes: available), ["heart_rate", "oxygen_saturation"])
        try recovery.completeObserverWork(typeCodes: ["heart_rate"], matching: admitted, availableTypeCodes: available)
        XCTAssertEqual(try recovery.pendingObserverTypeCodes(availableTypeCodes: available), ["oxygen_saturation"])
        XCTAssertEqual(recovery.processObserverFailure(typeCode: "oxygen_saturation", generation: 2, acknowledge: {}), .retained(lane: .quantity, localRecoveryEligible: false))
        try recovery.completeObserverWork(typeCodes: ["oxygen_saturation"], matching: admitted, availableTypeCodes: available)
        XCTAssertEqual(recovery.readback.pendingObserverLaneCount, 1)
        let fresh = try recovery.observerGenerationSnapshot()
        try recovery.completeObserverWork(typeCodes: ["heart_rate", "oxygen_saturation"], matching: fresh, availableTypeCodes: available)
        XCTAssertEqual(recovery.readback.pendingObserverLaneCount, 0)
    }

    @MainActor
    func testMissingCallbacksConsumePersistedBudgetAndLateSuccessCannotClearNewAttempt() async throws {
        let store = RecoveryMemoryStore()
        var now = Date(timeIntervalSince1970: 3_000)
        let recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
        recovery.activate(generation: 1)
        let old = try XCTUnwrap(recovery.claimRegistrations(typeCodes: ["sleep_analysis"], generation: 1).first)
        now = now.addingTimeInterval(60)
        let newer = try XCTUnwrap(recovery.claimRegistrations(typeCodes: ["sleep_analysis"], generation: 1).first)
        try recovery.completeRegistration(old, succeeded: true)
        XCTAssertEqual(store.snapshot.registrations[.sleep]?.attemptCount, 2)
        try recovery.completeRegistration(newer, succeeded: true)
        XCTAssertNil(store.snapshot.registrations[.sleep])
    }

    @MainActor
    func testEveryCoarseLaneBackoffIsCappedAndDuplicateReconciliationDoesNoIO() async throws {
        let store = RecoveryMemoryStore()
        var now = Date(timeIntervalSince1970: 4_000)
        let recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
        recovery.activate(generation: 9)
        let codes = ["steps", "active_energy", HealthBridgeHealthType.workouts.typeCode, "sleep_analysis", "body_mass"]
        let delays: [TimeInterval] = [60, 120, 240, 480, 900]
        for delay in delays {
            let attempts = try recovery.claimRegistrations(typeCodes: codes, generation: 9)
            XCTAssertEqual(attempts.count, 5)
            XCTAssertEqual(store.snapshot.registrations.count, 5)
            XCTAssertTrue(store.snapshot.registrations.values.allSatisfy { $0.nextEligibleAt == now.addingTimeInterval(delay) })
            for attempt in attempts { try recovery.completeRegistration(attempt, succeeded: false) }
            let saves = store.saveCount
            for _ in 0..<100 {
                XCTAssertTrue(try recovery.claimRegistrations(typeCodes: codes + codes, generation: 9).isEmpty)
            }
            XCTAssertEqual(store.saveCount, saves)
            now = now.addingTimeInterval(delay)
        }
        XCTAssertNil(recovery.nextRegistrationRetryAt)
        XCTAssertEqual(recovery.readback.exhaustedRegistrationLaneCount, 5)
        recovery.stop()
        XCTAssertNil(recovery.nextRegistrationRetryAt)
        recovery.activate(generation: 10)
        XCTAssertTrue(try recovery.claimRegistrations(typeCodes: codes, generation: 10).isEmpty)
    }

    @MainActor
    func testOldConnectionCannotRetireObserverWorkOrReofferLocalRecovery() async throws {
        let store = RecoveryMemoryStore()
        let recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 1)
        _ = recovery.processObserverFailure(typeCode: "sleep_analysis", generation: 1, acknowledge: {})
        let old = try recovery.observerGenerationSnapshot()
        recovery.stop()
        recovery.activate(generation: 2)
        try recovery.completeObserverWork(typeCodes: ["sleep_analysis"], matching: old, availableTypeCodes: ["sleep_analysis"])
        XCTAssertEqual(recovery.readback.pendingObserverLaneCount, 1)
        XCTAssertEqual(recovery.processObserverFailure(typeCode: "sleep_analysis", generation: 2, acknowledge: {}), .retained(lane: .sleep, localRecoveryEligible: false))
        XCTAssertEqual(recovery.processObserverFailure(typeCode: "steps", generation: 1, acknowledge: {}), .ignored)
    }

    @MainActor
    func testCoarseObserverWorkUsesExistingBoundedPlannerAndRetainsFailedAndUnattemptedWork() async throws {
        let store = RecoveryMemoryStore()
        let now = Date(timeIntervalSince1970: 5_000)
        let recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
        recovery.activate(generation: 1)
        _ = recovery.processObserverFailure(typeCode: "sleep_analysis", generation: 1, acknowledge: {})
        _ = recovery.processObserverFailure(typeCode: "heart_rate", generation: 1, acknowledge: {})
        let available = ["sleep_analysis", "heart_rate", "oxygen_saturation"]
        let pending = try recovery.pendingObserverTypeCodes(availableTypeCodes: available)
        let admission = try recovery.observerGenerationSnapshot()
        let plan = HealthBridgeBackgroundSync.workPlan(
            reason: .launchCatchUp,
            availableQuantityTypeCodes: ["heart_rate", "oxygen_saturation"],
            pendingObserverTypeCodes: pending,
            continuationLaneID: nil,
            coreLaneLastSuccess: Dictionary(uniqueKeysWithValues: HealthBridgeBackgroundSync.coreWorkLanes.map { ($0.id, now) }),
            now: now
        )
        XCTAssertLessThanOrEqual(plan.attempts.count, BackgroundSyncWorkPlan.maximumLaneAttempts)
        var entered: [BackgroundSyncWorkLane] = []
        let completed = try await BackgroundSyncWorkExecutor.execute(
            plan: plan,
            prepare: { _ in },
            runLane: { lane in entered.append(lane); return lane == .sleep },
            didComplete: { attempt in
                try recovery.completeObserverWork(typeCodes: attempt.coveredObserverTypeCodes, matching: admission, availableTypeCodes: available)
            }
        )
        XCTAssertEqual(completed.map(\.lane), [.sleep])
        XCTAssertEqual(entered.count, 2)
        XCTAssertEqual(try recovery.pendingObserverTypeCodes(availableTypeCodes: available), ["heart_rate", "oxygen_saturation"])
        XCTAssertEqual(store.snapshot.observerGenerations.count, 1)
    }

    @MainActor
    func testRealFileRoundTripCorruptionAndPrivacyBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let store = FileBackgroundDeliveryRecoveryStore(fileURL: url)
        let recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 1)
        _ = recovery.processObserverFailure(typeCode: "heart_rate", generation: 1, acknowledge: {})
        _ = try recovery.claimRegistrations(typeCodes: ["oxygen_saturation"], generation: 1)
        let loaded = try FileBackgroundDeliveryRecoveryStore(fileURL: url).load()
        XCTAssertEqual(loaded.observerGenerations, [.quantity: 1])
        XCTAssertEqual(loaded.registrations.count, 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["heart_rate", "oxygen_saturation", "error", "identifier", "token", "cursor", "endpoint", "payload"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("damaged".utf8).write(to: url)
        let damaged = BackgroundDeliveryFailureRecovery(store: FileBackgroundDeliveryRecoveryStore(fileURL: url))
        damaged.activate(generation: 2)
        XCTAssertTrue(damaged.readback.durableStateUnavailable)
        XCTAssertThrowsError(try damaged.claimRegistrations(typeCodes: ["steps"], generation: 2))
        XCTAssertEqual(damaged.processObserverFailure(typeCode: "sleep_analysis", generation: 2, acknowledge: {}), .durableStateUnavailable(lane: .sleep))
    }
}

private final class RecoveryMemoryStore: BackgroundDeliveryRecoveryStoring {
    var snapshot = BackgroundDeliveryRecoverySnapshot()
    var failSave = false
    var saveCount = 0
    var beforeSave: (() -> Void)?
    func load() throws -> BackgroundDeliveryRecoverySnapshot { snapshot }
    func save(_ snapshot: BackgroundDeliveryRecoverySnapshot) throws {
        saveCount += 1
        beforeSave?()
        if failSave { throw BackgroundSyncSettingsStoreError.persistenceFailed }
        self.snapshot = snapshot
    }
}

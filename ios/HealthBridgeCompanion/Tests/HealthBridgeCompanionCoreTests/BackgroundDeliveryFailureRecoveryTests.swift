import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class BackgroundDeliveryFailureRecoveryTests: XCTestCase {
    @MainActor
    func testRegistrationRetriesOnlyFailedRuntimeTypesAtDeterministicDeadline() throws {
        let store = RecoveryMemoryStore()
        var now = Date(timeIntervalSince1970: 1_000)
        let recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
        recovery.activate(generation: 3)
        let initial = try recovery.claimRegistrations(
            typeCodes: ["heart_rate", "oxygen_saturation", "sleep_analysis"],
            generation: 3
        )
        XCTAssertEqual(
            initial.map(\.typeCode),
            ["heart_rate", "oxygen_saturation", "sleep_analysis"]
        )
        for attempt in initial {
            try recovery.completeRegistration(
                attempt,
                succeeded: attempt.typeCode != "heart_rate"
            )
        }
        XCTAssertEqual(recovery.readback.failedRegistrationLanes, [.quantity])
        now = now.addingTimeInterval(60)
        let retry = try recovery.claimRegistrations(
            typeCodes: initial.map(\.typeCode),
            generation: 3
        )
        XCTAssertEqual(retry.map(\.typeCode), ["heart_rate"])
        XCTAssertEqual(store.snapshot.registrations[.quantity]?.attemptCount, 2)
        try recovery.completeRegistration(try XCTUnwrap(retry.first), succeeded: true)
        XCTAssertTrue(recovery.readback.failedRegistrationLanes.isEmpty)
    }

    @MainActor
    func testReloadHonorsBackoffAndExhaustionWithoutPersistingTypeCodes() throws {
        let store = RecoveryMemoryStore()
        var now = Date(timeIntervalSince1970: 2_000)
        var recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
        recovery.activate(generation: 1)
        var attempts = try recovery.claimRegistrations(
            typeCodes: ["heart_rate"],
            generation: 1
        )
        for count in 1...BackgroundDeliveryFailureRecovery.maximumRegistrationAttempts {
            XCTAssertEqual(attempts.count, 1)
            try recovery.completeRegistration(
                try XCTUnwrap(attempts.first),
                succeeded: false
            )
            recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
            recovery.activate(generation: UInt64(count + 1))
            now = try XCTUnwrap(
                store.snapshot.registrations[.quantity]?.nextEligibleAt
            )
            attempts = try recovery.claimRegistrations(
                typeCodes: ["heart_rate"],
                generation: UInt64(count + 1)
            )
        }
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertEqual(recovery.readback.exhaustedRegistrationLaneCount, 1)
        let text = String(decoding: try JSONEncoder().encode(store.snapshot), as: UTF8.self)
        XCTAssertFalse(text.contains("heart_rate"))
    }

    @MainActor
    func testReservationFailureAndGenerationFencesPreventExternalAttempts() throws {
        let store = RecoveryMemoryStore()
        let recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 4)
        store.failSave = true
        XCTAssertThrowsError(
            try recovery.claimRegistrations(typeCodes: ["steps"], generation: 4)
        )
        store.failSave = false
        let attempt = try XCTUnwrap(
            recovery.claimRegistrations(typeCodes: ["steps"], generation: 4).first
        )
        recovery.stop()
        recovery.activate(generation: 5)
        try recovery.completeRegistration(attempt, succeeded: true)
        XCTAssertNotNil(store.snapshot.registrations[.steps])
        XCTAssertTrue(
            try recovery.claimRegistrations(typeCodes: ["steps"], generation: 4).isEmpty
        )
    }

    @MainActor
    func testMissingCallbackBudgetAndLateSuccessCannotClearNewAttempt() throws {
        let store = RecoveryMemoryStore()
        var now = Date(timeIntervalSince1970: 3_000)
        let recovery = BackgroundDeliveryFailureRecovery(store: store, now: { now })
        recovery.activate(generation: 1)
        let old = try XCTUnwrap(
            recovery.claimRegistrations(
                typeCodes: ["sleep_analysis"],
                generation: 1
            ).first
        )
        now = now.addingTimeInterval(60)
        let newer = try XCTUnwrap(
            recovery.claimRegistrations(
                typeCodes: ["sleep_analysis"],
                generation: 1
            ).first
        )
        try recovery.completeRegistration(old, succeeded: true)
        XCTAssertEqual(store.snapshot.registrations[.sleep]?.attemptCount, 2)
        try recovery.completeRegistration(newer, succeeded: true)
        XCTAssertNil(store.snapshot.registrations[.sleep])
    }

    @MainActor
    func testRealFileRoundTripCorruptionAndPrivacyBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let store = FileBackgroundDeliveryRecoveryStore(fileURL: url)
        let recovery = BackgroundDeliveryFailureRecovery(store: store)
        recovery.activate(generation: 1)
        _ = try recovery.claimRegistrations(
            typeCodes: ["oxygen_saturation"],
            generation: 1
        )
        let loaded = try FileBackgroundDeliveryRecoveryStore(fileURL: url).load()
        XCTAssertEqual(loaded.registrations.count, 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in [
            "oxygen_saturation", "error", "identifier", "token", "cursor",
            "endpoint", "payload",
        ] {
            XCTAssertFalse(text.contains(forbidden))
        }
        try Data("damaged".utf8).write(to: url)
        let damaged = BackgroundDeliveryFailureRecovery(
            store: FileBackgroundDeliveryRecoveryStore(fileURL: url)
        )
        damaged.activate(generation: 2)
        XCTAssertTrue(damaged.readback.durableStateUnavailable)
        XCTAssertThrowsError(
            try damaged.claimRegistrations(typeCodes: ["steps"], generation: 2)
        )
    }
}

private final class RecoveryMemoryStore: BackgroundDeliveryRecoveryStoring {
    var snapshot = BackgroundDeliveryRecoverySnapshot()
    var failSave = false

    func load() throws -> BackgroundDeliveryRecoverySnapshot { snapshot }

    func save(_ snapshot: BackgroundDeliveryRecoverySnapshot) throws {
        if failSave { throw BackgroundSyncSettingsStoreError.persistenceFailed }
        self.snapshot = snapshot
    }
}

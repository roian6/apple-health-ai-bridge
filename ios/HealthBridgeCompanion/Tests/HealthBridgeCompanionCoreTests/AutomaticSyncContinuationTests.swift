import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class AutomaticSyncContinuationTests: XCTestCase {
    @MainActor
    func testInterruptedMixedOpportunitiesReachLaterTypesEvenAfterObserverRetiresSuccessor() async throws {
        for retireSuccessor in [false, true] {
            let suiteName = "AutomaticSyncContinuationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName + ".json")
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: file)
            }
            let dirtiness = FileBackgroundObserverDirtinessStore(fileURL: file)
            let store = BackgroundSyncSettingsStore(userDefaults: defaults, observerDirtinessStore: dirtiness)
            try store.markPendingObserverTypeCodes(["basal_energy", "heart_rate", "sleep_analysis", "workouts"])

            var mixedAttempts: [String] = []
            let engine = AutomaticSyncEngine(
                pendingStore: store,
                processType: { typeCode, _ in
                    if retireSuccessor, typeCode == "heart_rate" {
                        return .noPayload
                    }
                    mixedAttempts.append(typeCode)
                    withUnsafeCurrentTask { $0?.cancel() }
                    // The early lane cannot prove progress. Other lanes can finish
                    // their current operation but get no time for another type.
                    return typeCode == "basal_energy" ? .blocked : .noPayload
                }
            )
            try await engine.requestRun(reason: .scheduledRefresh)
            let afterFirstExpiry = try dirtiness.loadGenerations()
            XCTAssertEqual(afterFirstExpiry, ["basal_energy": 1, "heart_rate": 1, "sleep_analysis": 1, "workouts": 1])

            if retireSuccessor {
                try await engine.requestRun(reason: .observer(typeCode: "heart_rate"))
                XCTAssertEqual(try dirtiness.loadGenerations(), ["basal_energy": 1, "sleep_analysis": 1, "workouts": 1])
            }
            let laterOpportunities: [AutomaticSyncReason] = retireSuccessor
                ? [.launchCatchUp, .scheduledRefresh]
                : [.launchCatchUp, .scheduledRefresh, .launchCatchUp]
            for opportunity in laterOpportunities {
                do {
                    try await engine.requestRun(reason: opportunity)
                } catch is CancellationError {
                    // A completed lane retires its generation before the check.
                }
            }

            let expectedAttempts = retireSuccessor
                ? ["basal_energy", "sleep_analysis", "workouts"]
                : ["basal_energy", "heart_rate", "sleep_analysis", "workouts"]
            XCTAssertEqual(mixedAttempts, expectedAttempts, "Observer retired saved successor: \(retireSuccessor)")
            XCTAssertEqual(try dirtiness.loadGenerations(), ["basal_energy": 1])
        }
    }
}

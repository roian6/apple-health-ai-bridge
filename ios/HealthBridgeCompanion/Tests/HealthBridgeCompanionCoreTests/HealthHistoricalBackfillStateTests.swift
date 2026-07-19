import XCTest
@testable import HealthBridgeCompanionCore

final class HealthHistoricalBackfillStateTests: XCTestCase {
    func testStoreDefaultsToEmptyBackfillState() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(store.state.selectedTypeCodes, [])
        XCTAssertEqual(store.state.completedTypeCodes, [])
        XCTAssertEqual(store.state.olderThanCursorsByTypeCode, [:])
        XCTAssertFalse(store.state.isComplete)
    }

    func testStorePersistsStartedCompletedAndOlderThanProgress() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.start(typeCodes: ["weight", "heart_rate", "weight"], historyDepth: .allAvailable)
        store.saveOlderThanCursor(date("2026-05-01T00:00:00Z"), for: "weight")
        store.markCompleted("heart_rate")

        let reloaded = HealthHistoricalBackfillStateStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.state.selectedTypeCodes, ["heart_rate", "weight"])
        XCTAssertEqual(reloaded.state.completedTypeCodes, ["heart_rate"])
        XCTAssertEqual(reloaded.state.olderThanCursorsByTypeCode, [
            "weight": date("2026-05-01T00:00:00Z"),
        ])
        XCTAssertEqual(reloaded.incompleteTypeCodes, ["weight"])
    }

    func testCompletedBackfillIsReportedOnlyWhenEverySelectedTypeCompleted() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.start(typeCodes: ["weight", "height"], historyDepth: .lastDays(90))
        store.markCompleted("weight")
        XCTAssertFalse(store.state.isComplete)

        store.markCompleted("height")
        XCTAssertTrue(store.state.isComplete)
        XCTAssertEqual(store.incompleteTypeCodes, [])
    }

    func testResetClearsBackfillProgressWithoutTouchingOtherDefaults() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("receiver-url", forKey: "unrelated.receiver.setting")

        store.start(typeCodes: ["weight"], historyDepth: .allAvailable)
        store.saveOlderThanCursor(date("2026-05-01T00:00:00Z"), for: "weight")
        store.reset()

        XCTAssertEqual(store.state.selectedTypeCodes, [])
        XCTAssertEqual(defaults.string(forKey: "unrelated.receiver.setting"), "receiver-url")
    }

    func testSparseAllAvailableBackfillPolicyCanonicalizesAndFiltersSelection() {
        XCTAssertEqual(
            HealthHistoricalBackfillPolicy.sparseAllAvailableTypeCodes(
                selectedTypeCodes: ["heart_rate", "body_mass", "weight", "active_energy", "height"],
                historyDepth: .allAvailable
            ),
            ["height", "weight"]
        )

        XCTAssertEqual(
            HealthHistoricalBackfillPolicy.sparseAllAvailableTypeCodes(
                selectedTypeCodes: ["weight", "height"],
                historyDepth: .lastDays(90)
            ),
            []
        )
    }

    func testPresentationSummarizesHistoricalProgressWithoutValues() {
        let state = HealthHistoricalBackfillState(
            selectedTypeCodes: ["weight", "height", "body_fat_percentage"],
            completedTypeCodes: ["weight"],
            olderThanCursorsByTypeCode: [:],
            historyDepth: .allAvailable
        )

        XCTAssertEqual(
            HealthHistoricalBackfillPresentation.summary(state: state),
            "Additional history sync progress: 1/3 selected item(s) complete. 2 item(s) remaining. No sample values are shown."
        )

        let complete = HealthHistoricalBackfillState(
            selectedTypeCodes: ["weight", "height"],
            completedTypeCodes: ["weight", "height"],
            olderThanCursorsByTypeCode: [:],
            historyDepth: .allAvailable
        )

        XCTAssertEqual(
            HealthHistoricalBackfillPresentation.summary(state: complete),
            "Additional history sync complete for 2 selected item(s). No sample values are shown."
        )
    }

    private func makeStore() throws -> (
        store: HealthHistoricalBackfillStateStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "HealthHistoricalBackfillStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (HealthHistoricalBackfillStateStore(userDefaults: defaults), defaults, suiteName)
    }

    private func date(_ isoString: String) -> Date {
        ISO8601DateFormatter().date(from: isoString)!
    }
}

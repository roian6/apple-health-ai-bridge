import XCTest
@testable import HealthBridgeCompanionCore

final class HealthHistoryDepthPolicyTests: XCTestCase {
    func testAllAvailableHasNoLowerBound() {
        let now = date("2026-06-20T06:00:00Z")
        let calendar = utcCalendar()

        XCTAssertNil(HealthHistoryDepth.allAvailable.lowerBoundDate(now: now, calendar: calendar))
    }

    func testLastDaysStartsAtStartOfLocalDay() throws {
        let now = date("2026-06-20T06:00:00Z")
        let calendar = utcCalendar()

        let lowerBound = try XCTUnwrap(HealthHistoryDepth.lastDays(30).lowerBoundDate(now: now, calendar: calendar))

        XCTAssertEqual(lowerBound, date("2026-05-21T00:00:00Z"))
    }

    func testSinceDateReturnsTheRequestedDate() throws {
        let since = date("2026-03-01T12:34:56Z")
        let now = date("2026-06-20T06:00:00Z")

        let lowerBound = try XCTUnwrap(HealthHistoryDepth.sinceDate(since).lowerBoundDate(now: now, calendar: utcCalendar()))

        XCTAssertEqual(lowerBound, since)
    }

    func testSelectionStoreDefaultsToAllAvailableHistory() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(store.historyDepth, .allAvailable)
    }

    func testSelectionStorePersistsHistoryDepth() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.saveHistoryDepth(.lastDays(90))

        let reloaded = HealthHistoryDepthSelectionStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.historyDepth, .lastDays(90))
    }

    func testInvalidLastDaysFallsBackToAllAvailable() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.saveHistoryDepth(.lastDays(0))

        let reloaded = HealthHistoryDepthSelectionStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.historyDepth, .allAvailable)
    }

    func testPresentationRowsExposeSimpleHistoryChoices() {
        let rows = HealthHistoryDepthPresentation.optionRows(selected: .allAvailable)

        XCTAssertEqual(rows.map(\.id), ["all_available", "last_365_days", "last_180_days", "last_90_days", "last_30_days"])
        XCTAssertEqual(rows.first?.title, "All")
        XCTAssertEqual(rows.first?.detail, "Widest available range; high-volume data stays bounded.")
        XCTAssertEqual(rows.first?.historyDepth, .allAvailable)
        XCTAssertEqual(rows.first?.isSelected, true)
        XCTAssertEqual(rows[1].historyDepth, .lastDays(365))
        XCTAssertEqual(rows[2].historyDepth, .lastDays(180))
        XCTAssertEqual(rows[3].historyDepth, .lastDays(90))
        XCTAssertEqual(rows[4].historyDepth, .lastDays(30))
    }

    func testPresentationCanResolveChoiceIDsAndFallbackSafely() {
        XCTAssertEqual(HealthHistoryDepthPresentation.historyDepth(forOptionID: "all_available"), .allAvailable)
        XCTAssertEqual(HealthHistoryDepthPresentation.historyDepth(forOptionID: "last_365_days"), .lastDays(365))
        XCTAssertEqual(HealthHistoryDepthPresentation.historyDepth(forOptionID: "last_180_days"), .lastDays(180))
        XCTAssertEqual(HealthHistoryDepthPresentation.historyDepth(forOptionID: "last_90_days"), .lastDays(90))
        XCTAssertEqual(HealthHistoryDepthPresentation.historyDepth(forOptionID: "last_30_days"), .lastDays(30))
        XCTAssertEqual(HealthHistoryDepthPresentation.historyDepth(forOptionID: "unknown"), .allAvailable)
    }

    func testPresentationSummaryExplainsTypeAwareBoundsWithoutMedicalClaims() {
        let allSummary = HealthHistoryDepthPresentation.summary(selected: .allAvailable)

        XCTAssertEqual(allSummary, "All")
        XCTAssertFalse(allSummary.localizedCaseInsensitiveContains("diagnosis"))

        let recentSummary = HealthHistoryDepthPresentation.summary(selected: .lastDays(30))
        XCTAssertEqual(recentSummary, "Last 30 days")
        XCTAssertFalse(recentSummary.localizedCaseInsensitiveContains("diagnosis"))
    }

    private func makeStore() throws -> (
        store: HealthHistoryDepthSelectionStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "HealthHistoryDepthPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (HealthHistoryDepthSelectionStore(userDefaults: defaults), defaults, suiteName)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ isoString: String) -> Date {
        ISO8601DateFormatter().date(from: isoString)!
    }
}

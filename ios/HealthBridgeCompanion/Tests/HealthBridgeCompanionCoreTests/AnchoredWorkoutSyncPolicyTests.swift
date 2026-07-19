import XCTest
@testable import HealthBridgeCompanionCore

final class AnchoredWorkoutSyncPolicyTests: XCTestCase {
    func testQueryPlanUsesStoredBootstrapStartOnlyWhenAnchorIsMissing() throws {
        let calendar = utcCalendar()
        let now = try date("2026-06-15T12:00:00Z")

        let plan = AnchoredWorkoutSyncPolicy.queryPlan(
            anchorCursorValue: nil,
            storedBootstrapStartValue: "2026-03-01T00:00:00Z",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(plan.queryStart, try date("2026-03-01T00:00:00Z"))
        XCTAssertEqual(plan.bootstrapStartToPersist, try date("2026-03-01T00:00:00Z"))
    }

    func testQueryPlanStopsApplyingBootstrapPredicateAfterAnchorExists() throws {
        let calendar = utcCalendar()
        let now = try date("2026-06-15T12:00:00Z")

        let plan = AnchoredWorkoutSyncPolicy.queryPlan(
            anchorCursorValue: "existing-anchor",
            storedBootstrapStartValue: "2026-03-01T00:00:00Z",
            now: now,
            calendar: calendar
        )

        XCTAssertNil(plan.queryStart)
        XCTAssertNil(plan.bootstrapStartToPersist)
    }

    func testQueryPlanCreatesBoundedBootstrapStartWhenAnchorIsMissing() throws {
        let calendar = utcCalendar()
        let now = try date("2026-06-15T12:00:00Z")

        let plan = AnchoredWorkoutSyncPolicy.queryPlan(
            anchorCursorValue: nil,
            storedBootstrapStartValue: nil,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(plan.queryStart, try date("2026-03-17T00:00:00Z"))
        XCTAssertEqual(plan.bootstrapStartToPersist, try date("2026-03-17T00:00:00Z"))
    }

    func testQueryPlanAllowsOneDayAutomaticBootstrap() throws {
        let calendar = utcCalendar()
        let now = try date("2026-06-15T12:00:00Z")

        let plan = AnchoredWorkoutSyncPolicy.queryPlan(
            anchorCursorValue: nil,
            storedBootstrapStartValue: "2026-03-01T00:00:00Z",
            bootstrapLookbackDays: 1,
            clampStoredBootstrapToLookback: true,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(plan.queryStart, try date("2026-06-14T00:00:00Z"))
        XCTAssertEqual(plan.bootstrapStartToPersist, try date("2026-06-14T00:00:00Z"))
    }

    func testQueryPlanKeepsLegacyAnchorUnboundedWhenBootstrapStartIsMissing() throws {
        let calendar = utcCalendar()
        let now = try date("2026-06-15T12:00:00Z")

        let plan = AnchoredWorkoutSyncPolicy.queryPlan(
            anchorCursorValue: "legacy-anchor",
            storedBootstrapStartValue: nil,
            now: now,
            calendar: calendar
        )

        XCTAssertNil(plan.queryStart)
        XCTAssertNil(plan.bootstrapStartToPersist)
    }
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}

private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return try XCTUnwrap(formatter.date(from: string))
}

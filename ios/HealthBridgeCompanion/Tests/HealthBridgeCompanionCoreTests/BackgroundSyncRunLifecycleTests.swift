import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class BackgroundSyncRunLifecycleTests: XCTestCase {
    func testAcceptedMarkerHasNoFinishTimeBeforeLongAwait() throws {
        let suiteName = "BackgroundSyncAcceptedLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        let startedAt = Date(timeIntervalSince1970: 1_786_406_400)

        try store.recordRunLifecycle(
            startedAt: startedAt,
            finishedAt: nil,
            outcome: .accepted,
            succeeded: false,
            summary: "Background refresh accepted."
        )

        let accepted = try XCTUnwrap(
            BackgroundSyncSettingsStore(userDefaults: defaults).lastRun
        )
        XCTAssertEqual(accepted.startedAt, "2026-08-11T00:00:00Z")
        XCTAssertNil(accepted.finishedAt)
        XCTAssertEqual(accepted.outcome, .accepted)
        XCTAssertFalse(accepted.succeeded)
    }

    func testLifecycleOutcomesRemainDistinctAcrossReload() throws {
        let suiteName = "BackgroundSyncTerminalLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let startedAt = Date(timeIntervalSince1970: 1_786_406_400)
        let finishedAt = startedAt.addingTimeInterval(30)

        for (outcome, succeeded) in [
            (BackgroundSyncRunOutcome.interrupted, false),
            (.completed, true),
        ] {
            let store = BackgroundSyncSettingsStore(userDefaults: defaults)
            try store.recordRunLifecycle(
                startedAt: startedAt,
                finishedAt: finishedAt,
                outcome: outcome,
                succeeded: succeeded,
                summary: "Synthetic lifecycle outcome."
            )

            let reloaded = try XCTUnwrap(
                BackgroundSyncSettingsStore(userDefaults: defaults).lastRun
            )
            XCTAssertEqual(reloaded.outcome, outcome)
            XCTAssertEqual(reloaded.finishedAt, "2026-08-11T00:00:30Z")
            XCTAssertEqual(reloaded.succeeded, succeeded)
        }
    }

    func testSkippedWakeDoesNotOverwriteAnAcceptedRunMarker() throws {
        let suiteName = "BackgroundSyncConcurrentLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        let acceptedAt = Date(timeIntervalSince1970: 1_786_406_400)

        try store.recordRunLifecycle(
            startedAt: acceptedAt,
            finishedAt: nil,
            outcome: .accepted,
            succeeded: false,
            summary: "Background refresh accepted."
        )
        try store.recordRunLifecycle(
            startedAt: acceptedAt.addingTimeInterval(1),
            finishedAt: acceptedAt.addingTimeInterval(1),
            outcome: .skipped,
            succeeded: false,
            summary: "Background refresh skipped because another run is active."
        )

        let reloaded = BackgroundSyncSettingsStore(userDefaults: defaults)
        XCTAssertEqual(try XCTUnwrap(reloaded.lastRun).outcome, .accepted)
        XCTAssertEqual(try XCTUnwrap(reloaded.lastSkippedRun).outcome, .skipped)
    }

    func testLegacyCompletedRecordLoadsAsCompletedOutcome() throws {
        let suiteName = "BackgroundSyncLegacyLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)

        store.recordRun(
            startedAt: Date(timeIntervalSince1970: 1_786_406_400),
            finishedAt: Date(timeIntervalSince1970: 1_786_406_430),
            succeeded: false,
            summary: "Synthetic legacy completion."
        )

        let reloaded = try XCTUnwrap(
            BackgroundSyncSettingsStore(userDefaults: defaults).lastRun
        )
        XCTAssertEqual(reloaded.outcome, .completed)
        XCTAssertNotNil(reloaded.finishedAt)
    }
}

#if HEALTH_BRIDGE_STANDALONE_TEST
extension BackgroundSyncRunLifecycleTests {
    static let allTests = [
        ("testAcceptedMarkerHasNoFinishTimeBeforeLongAwait", testAcceptedMarkerHasNoFinishTimeBeforeLongAwait),
        ("testLifecycleOutcomesRemainDistinctAcrossReload", testLifecycleOutcomesRemainDistinctAcrossReload),
        ("testSkippedWakeDoesNotOverwriteAnAcceptedRunMarker", testSkippedWakeDoesNotOverwriteAnAcceptedRunMarker),
        ("testLegacyCompletedRecordLoadsAsCompletedOutcome", testLegacyCompletedRecordLoadsAsCompletedOutcome),
    ]
}

@main
enum BackgroundSyncLifecycleStandaloneTestRunner {
    static func main() {
        XCTMain([
            testCase(BackgroundSyncRunLifecycleTests.allTests),
        ])
    }
}
#endif

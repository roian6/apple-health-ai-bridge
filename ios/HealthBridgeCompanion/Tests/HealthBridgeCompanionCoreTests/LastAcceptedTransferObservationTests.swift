import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class LastAcceptedTransferObservationTests: XCTestCase {
    func testMissingRecordLoadsUnknown() throws {
        let (defaults, _) = try makeDefaults()

        XCTAssertNil(LastAcceptedTransferObservationStore(userDefaults: defaults)
            .load(bindingID: "binding-a", generation: "generation-a"))
    }

    func testObservationLoadsAfterStoreAndDefaultsRecreation() throws {
        let (defaults, suiteName) = try makeDefaults()
        let observation = LastAcceptedTransferObservation(
            bindingID: "binding-a",
            generation: "generation-a",
            observedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            evidenceKind: .directResponse
        )
        LastAcceptedTransferObservationStore(userDefaults: defaults).record(observation)

        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reloaded = LastAcceptedTransferObservationStore(userDefaults: reloadedDefaults)
        XCTAssertEqual(
            reloaded.load(bindingID: "binding-a", generation: "generation-a"),
            observation
        )
    }

    func testChangedBindingOrGenerationCannotLoadObservation() throws {
        let (defaults, _) = try makeDefaults()
        let store = LastAcceptedTransferObservationStore(userDefaults: defaults)
        store.record(LastAcceptedTransferObservation(
            bindingID: "binding-a",
            generation: "generation-a",
            observedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            evidenceKind: .mailboxCommit
        ))

        XCTAssertNil(store.load(bindingID: "binding-b", generation: "generation-a"))
        XCTAssertNil(store.load(bindingID: "binding-a", generation: "generation-b"))
        XCTAssertNotNil(store.load(bindingID: "binding-a", generation: "generation-a"))
    }

    func testRecordingReplacesSoleRecordRatherThanRetainingScopes() throws {
        let (defaults, _) = try makeDefaults()
        let store = LastAcceptedTransferObservationStore(userDefaults: defaults)
        store.record(LastAcceptedTransferObservation(
            bindingID: "binding-a",
            generation: "generation-a",
            observedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            evidenceKind: .directResponse
        ))
        let latest = LastAcceptedTransferObservation(
            bindingID: "binding-b",
            generation: "generation-b",
            observedAt: Date(timeIntervalSinceReferenceDate: 234_567),
            evidenceKind: .mailboxCommit
        )

        store.record(latest)

        let reloaded = LastAcceptedTransferObservationStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.load(bindingID: "binding-b", generation: "generation-b"), latest)
        XCTAssertNil(reloaded.load(bindingID: "binding-a", generation: "generation-a"))
    }

    func testVersionOneStoredFormatLoadsIndependentFixture() throws {
        let (defaults, _) = try makeDefaults()
        defaults.set(Data(versionOneFixture.utf8), forKey: storageKey)

        let loaded = LastAcceptedTransferObservationStore(userDefaults: defaults)
            .load(bindingID: "binding-a", generation: "generation-a")

        XCTAssertEqual(loaded, LastAcceptedTransferObservation(
            bindingID: "binding-a",
            generation: "generation-a",
            observedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            evidenceKind: .mailboxCommit
        ))
    }

    func testMalformedAndUnsupportedRecordsLoadUnknown() throws {
        let (defaults, _) = try makeDefaults()
        let invalidRecords = [
            "not JSON",
            "{}",
            versionOneFixture.replacingOccurrences(of: "\"version\":1,", with: ""),
            versionOneFixture.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            versionOneFixture.replacingOccurrences(of: "mailboxCommit", with: "futureEvidence"),
            versionOneFixture.replacingOccurrences(of: "\"observedAt\":123456,", with: ""),
            versionOneFixture.replacingOccurrences(of: "123456", with: "\"invalid-date\""),
        ]

        for invalidRecord in invalidRecords {
            defaults.set(Data(invalidRecord.utf8), forKey: storageKey)
            XCTAssertNil(LastAcceptedTransferObservationStore(userDefaults: defaults)
                .load(bindingID: "binding-a", generation: "generation-a"))
        }
        defaults.set(42, forKey: storageKey)
        XCTAssertNil(LastAcceptedTransferObservationStore(userDefaults: defaults)
            .load(bindingID: "binding-a", generation: "generation-a"))
    }

    func testClearRemovesObservationWithoutChangingOtherSettings() throws {
        let (defaults, _) = try makeDefaults()
        defaults.set(true, forKey: "unrelated.synthetic.setting")
        let store = LastAcceptedTransferObservationStore(userDefaults: defaults)
        store.record(LastAcceptedTransferObservation(
            bindingID: "binding-a",
            generation: "generation-a",
            observedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            evidenceKind: .directResponse
        ))

        store.clear()
        store.clear()

        XCTAssertNil(LastAcceptedTransferObservationStore(userDefaults: defaults)
            .load(bindingID: "binding-a", generation: "generation-a"))
        XCTAssertTrue(defaults.bool(forKey: "unrelated.synthetic.setting"))
    }

    private let storageKey = "healthBridge.lastAcceptedTransferObservation"
    // Independent v1 compatibility fixture, also used to exercise invalid storage.
    private let versionOneFixture = """
    {"version":1,"observation":{"bindingID":"binding-a","generation":"generation-a",\
    "observedAt":123456,"evidenceKind":"mailboxCommit"}}
    """

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "LastAcceptedTransferObservationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return (defaults, suiteName)
    }
}

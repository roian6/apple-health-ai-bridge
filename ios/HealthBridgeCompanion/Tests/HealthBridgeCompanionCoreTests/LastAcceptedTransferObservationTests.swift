import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class LastAcceptedTransferObservationTests: XCTestCase {
    func testMissingRecordLoadsUnknown() throws {
        let (defaults, _) = try makeDefaults()

        XCTAssertNil(makeStore(defaults)
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
        makeStore(defaults).record(observation)

        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reloaded = makeStore(reloadedDefaults)
        XCTAssertEqual(
            reloaded.load(bindingID: "binding-a", generation: "generation-a"),
            observation
        )
    }

    func testChangedBindingOrGenerationCannotLoadObservation() throws {
        let (defaults, _) = try makeDefaults()
        let store = makeStore(defaults)
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
        let store = makeStore(defaults)
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

        let reloaded = makeStore(defaults)
        XCTAssertEqual(reloaded.load(bindingID: "binding-b", generation: "generation-b"), latest)
        XCTAssertNil(reloaded.load(bindingID: "binding-a", generation: "generation-a"))
    }

    func testVersionOneStoredFormatLoadsIndependentFixture() throws {
        let (defaults, _) = try makeDefaults()
        defaults.set(Data(versionOneFixture.utf8), forKey: storageKey)

        let loaded = makeStore(defaults)
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
            XCTAssertNil(makeStore(defaults)
                .load(bindingID: "binding-a", generation: "generation-a"))
        }
        defaults.set(42, forKey: storageKey)
        XCTAssertNil(makeStore(defaults)
            .load(bindingID: "binding-a", generation: "generation-a"))
    }

    func testClearMasksReplayedLegacyDefaultsAndAllowsNewSameScopeEvidence() throws {
        let (defaults, _) = try makeDefaults()
        defaults.set(true, forKey: "unrelated.synthetic.setting")
        let store = makeStore(defaults)
        let oldBytes = Data(versionOneFixture.utf8)
        defaults.set(oldBytes, forKey: storageKey)
        XCTAssertNotNil(store.load(bindingID: "binding-a", generation: "generation-a"))

        try store.clear()
        try store.clear()

        XCTAssertNil(defaults.data(forKey: storageKey))
        defaults.set(oldBytes, forKey: storageKey) // Model an interrupted defaults flush.
        let reopened = makeStore(defaults)
        XCTAssertNil(reopened.load(bindingID: "binding-a", generation: "generation-a"))
        XCTAssertTrue(defaults.bool(forKey: "unrelated.synthetic.setting"))

        let new = LastAcceptedTransferObservation(
            bindingID: "binding-a", generation: "generation-a",
            observedAt: Date(timeIntervalSinceReferenceDate: 234_567), evidenceKind: .directResponse
        )
        reopened.record(new)
        XCTAssertEqual(makeStore(defaults).load(bindingID: "binding-a", generation: "generation-a"), new)
    }

    private let resetEpochDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    private let storageKey = "healthBridge.lastAcceptedTransferObservation"
    // Independent v1 compatibility fixture, also used to exercise invalid storage.
    private let versionOneFixture = """
    {"version":1,"observation":{"bindingID":"binding-a","generation":"generation-a",\
    "observedAt":123456,"evidenceKind":"mailboxCommit"}}
    """

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "LastAcceptedTransferObservationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let resetEpochDirectory = self.resetEpochDirectory
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            if FileManager.default.fileExists(atPath: resetEpochDirectory.path) {
                try FileManager.default.removeItem(at: resetEpochDirectory)
            }
        }
        return (defaults, suiteName)
    }

    private func makeStore(_ defaults: UserDefaults) -> LastAcceptedTransferObservationStore {
        LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: resetEpochDirectory.appendingPathComponent("epoch")
        )
    }
}

import XCTest
@testable import HealthBridgeCompanionCore

private final class FailingAcceptedMarkerDefaults: UserDefaults {
    override func synchronize() -> Bool { false }
}

final class AutomaticSyncCausalDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_100)
    private let core: [AutomaticSyncDiagnosticLane] = [.sleep, .dailyActivity, .steps, .workouts]

    private func item(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private func evidence(_ lane: AutomaticSyncDiagnosticLane) -> AutomaticSyncLaneEvidence {
        var evidence = AutomaticSyncLaneEvidence(lane: lane)
        evidence.attempted = true
        evidence.noteQuery(.records, newestSampleAge: 60, now: now)
        evidence.noteDelivery(.accepted, now: now)
        return evidence
    }

    private func record(_ lanes: [AutomaticSyncLaneEvidence], truncated: Bool = false) -> AutomaticSyncDiagnosticRecord {
        let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
        draft.noteAdmission()
        var record = draft.record
        record.causalChain = AutomaticSyncCausalChain(lanes: lanes, truncated: truncated, durableAdmission: .persisted)
        return record
    }

    private func gate(
        _ records: [AutomaticSyncDiagnosticRecord],
        at date: Date? = nil,
        requirements: [AutomaticSyncDiagnosticLane: CoreLaneSourceFreshnessRequirement]? = nil
    ) -> CoreFreshnessReleaseDecision {
        let sourceRequirements = requirements ?? Dictionary(
            uniqueKeysWithValues: core.map { ($0, .newestSample(maximumAge: 3_600)) }
        )
        return CoreFreshnessReleasePolicy.evaluate(records: records, now: date ?? now,
            maximumQueryAge: 3_600, maximumDeliveryAge: 3_600,
            sourceFreshnessRequirements: sourceRequirements)
    }

    private func durableAdmissionJSON(_ record: AutomaticSyncDiagnosticRecord) throws -> String? {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        return (json["causalChain"] as? [String: Any])?["durableAdmission"] as? String
    }

    private func withDurableAdmission(_ value: Any?, in record: AutomaticSyncDiagnosticRecord) throws -> AutomaticSyncDiagnosticRecord {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        var chain = try XCTUnwrap(json["causalChain"] as? [String: Any])
        chain["durableAdmission"] = value
        json["causalChain"] = chain
        return try JSONDecoder().decode(AutomaticSyncDiagnosticRecord.self,
            from: JSONSerialization.data(withJSONObject: json))
    }

    func testDurableAdmissionFailedMarkerPreservesGateAcceptanceAndHolds() throws {
        let suite = "FailedDurableAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(FailingAcceptedMarkerDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BackgroundSyncSettingsStore(userDefaults: defaults)
        let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
        draft.noteAdmission()
        XCTAssertThrowsError(try settings.recordRunLifecycle(startedAt: now, finishedAt: nil,
            outcome: .accepted, succeeded: false, summary: "Synthetic marker"))
        draft.noteDurableStateUnavailable()
        XCTAssertEqual(draft.record.admissionResult, .accepted)
        XCTAssertEqual(try durableAdmissionJSON(draft.record), "failed")
        XCTAssertEqual(draft.record.failure?.stage, .store)
        XCTAssertEqual(draft.record.runOutcome, .skipped)
        var otherwiseFresh = draft.record
        otherwiseFresh.causalChain?.lanes = core.map(evidence)
        XCTAssertEqual(gate([otherwiseFresh]), .hold)
    }

    func testDurableAdmissionPersistedMarkerIsRequiredForPass() throws {
        let fresh = record(core.map(evidence))
        for state in ["unknown", "failed", "future_value"] {
            let decoded = try withDurableAdmission(state, in: fresh)
            XCTAssertEqual(gate([decoded]), .hold, state)
            XCTAssertEqual(try durableAdmissionJSON(decoded), state == "future_value" ? "unknown" : state)
        }
        let persisted = try withDurableAdmission("persisted", in: fresh)
        XCTAssertEqual(try durableAdmissionJSON(persisted), "persisted")
        XCTAssertEqual(gate([persisted]), .pass)
    }

    func testDurableAdmissionLegacyNestedFieldKeepsStoredRecordAndHolds() throws {
        let current = record(core.map(evidence))
        for value: Any? in [nil, NSNull(), 42] {
            let legacy = try withDurableAdmission(value, in: current)
            XCTAssertEqual(legacy.runID, current.runID)
            XCTAssertEqual(legacy.causalChain?.lanes, current.causalChain?.lanes)
            XCTAssertEqual(try durableAdmissionJSON(legacy), "unknown")
            XCTAssertEqual(gate([legacy]), .hold)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("diagnostics.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var chain = try XCTUnwrap(json["causalChain"] as? [String: Any])
        chain.removeValue(forKey: "durableAdmission")
        json["causalChain"] = chain
        try JSONSerialization.data(withJSONObject: ["version": 1, "records": [json],
            "pendingSinceBucketByLane": [String: Int]()]).write(to: url)
        let history = AutomaticSyncDiagnosticStore(fileURL: url).history
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.runID, current.runID)
        XCTAssertEqual(gate(history), .hold)
    }

    func testDurableAdmissionSuccessfulWriteSurvivesPlanningAndRestart() throws {
        let suite = "DurableAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BackgroundSyncSettingsStore(userDefaults: defaults)
        let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
        draft.noteAdmission()
        XCTAssertEqual(try durableAdmissionJSON(draft.record), "unknown")
        var gateOnly = draft.record
        gateOnly.causalChain?.lanes = core.map(evidence)
        XCTAssertEqual(gate([gateOnly]), .hold)
        try settings.recordRunLifecycle(startedAt: now, finishedAt: nil,
            outcome: .accepted, succeeded: false, summary: "Synthetic marker")
        draft.noteRunAccepted()
        draft.notePlan([.sleep, .dailyActivity, .steps, .workouts])
        XCTAssertEqual(try durableAdmissionJSON(draft.record), "persisted")
        XCTAssertEqual(BackgroundSyncSettingsStore(userDefaults: defaults).lastRun?.outcome, .accepted)
        for lane in core {
            draft.noteAttempt(lane)
            draft.noteQuery(.records, newestSampleAge: 60, now: now)
            draft.noteDelivery(.accepted, now: now)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.json")
        XCTAssertTrue(AutomaticSyncDiagnosticStore(fileURL: url).recordAccepted(draft.record))
        let history = AutomaticSyncDiagnosticStore(fileURL: url).history
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(gate(history), .pass)
    }

    func testDurableAdmissionFinalMergePreservesKnownMarkerOutcomes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.json")
        let store = AutomaticSyncDiagnosticStore(fileURL: url)
        for state in ["failed", "persisted"] {
            let original = record(core.map(evidence))
            XCTAssertTrue(store.recordAccepted(try withDurableAdmission(state, in: original)))
            let restarted = AutomaticSyncDiagnosticStore(fileURL: url)
            XCTAssertTrue(restarted.recordFinal(try withDurableAdmission(nil, in: original)))
            let final = try XCTUnwrap(restarted.latestRecord)
            XCTAssertEqual(try durableAdmissionJSON(final), state)
            XCTAssertEqual(final.runID, original.runID)
            XCTAssertEqual(gate([final]), state == "persisted" ? .pass : .hold)
        }
    }

    func testLegacyJSONDecodesWithoutInventingCausalEvidence() throws {
        let current = record(core.map(evidence))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        json.removeValue(forKey: "causalChain")
        let legacy = try JSONDecoder().decode(AutomaticSyncDiagnosticRecord.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.causalChain)
        XCTAssertEqual(gate([legacy]), .hold)
        XCTAssertEqual(gate([current]), .pass)
    }

    func testUnknownAdmissionCannotPassFromOtherwiseFreshEvidence() {
        var unadmitted = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh).record
        unadmitted.causalChain = AutomaticSyncCausalChain(lanes: core.map(evidence), durableAdmission: .persisted)
        XCTAssertEqual(gate([unadmitted]), .hold)
    }

    func testEveryMissingOrStaleCoreLaneHoldsAndOptionalCannotSubstitute() {
        XCTAssertEqual(CoreFreshnessReleasePolicy.requiredLanes, Set(core))
        for missing in core {
            var lanes = core.filter { $0 != missing }.map(evidence)
            lanes.append(evidence(.quantity))
            XCTAssertEqual(gate([record(lanes)]), .hold, missing.rawValue)
            var stale = evidence(missing)
            stale.noteQuery(.records, newestSampleAge: 60, now: now.addingTimeInterval(-7_200))
            lanes[lanes.count - 1] = stale
            XCTAssertEqual(gate([record(lanes)]), .hold, missing.rawValue)
            stale = evidence(missing)
            stale.noteDelivery(.accepted, now: now.addingTimeInterval(-7_200))
            lanes[lanes.count - 1] = stale
            XCTAssertEqual(gate([record(lanes)]), .hold, missing.rawValue)
        }
        XCTAssertEqual(gate([record([evidence(.quantity)])]), .hold)
        XCTAssertEqual(gate([]), .hold)
        XCTAssertEqual(gate([record(core.map(evidence), truncated: true)]), .hold)
        XCTAssertEqual(gate([record(core.map(evidence))], at: now.addingTimeInterval(7_200)), .hold)
    }

    func testRecentQueryAndACKCannotHideStaleOrMissingSourceSample() {
        var stale = evidence(.sleep)
        stale.noteQuery(.records, newestSampleAge: 259_200, now: now)
        XCTAssertEqual(gate([record([stale] + core.dropFirst().map(evidence))]), .hold)

        var missing = evidence(.sleep)
        missing.noteQuery(.noRecords, newestSampleAge: nil, now: now)
        XCTAssertEqual(gate([record([missing] + core.dropFirst().map(evidence))]), .hold)
    }

    func testQueryCompletionOnlyMustBeExplicitForEveryCoreLane() {
        let noRecordLanes = core.map { lane -> AutomaticSyncLaneEvidence in
            var result = evidence(lane)
            result.noteQuery(.noRecords, newestSampleAge: nil, now: now)
            return result
        }
        var requirements = Dictionary(
            uniqueKeysWithValues: core.map { ($0, CoreLaneSourceFreshnessRequirement.queryCompletionOnly) }
        )
        XCTAssertEqual(gate([record(noRecordLanes)], requirements: requirements), .pass)
        requirements.removeValue(forKey: .workouts)
        XCTAssertEqual(gate([record(noRecordLanes)], requirements: requirements), .hold)
    }

    func testEveryQueryAndDeliveryStateIsConservative() {
        for query in AutomaticSyncQueryOutcome.allCases {
            for delivery in AutomaticSyncDeliveryOutcome.allCases {
                var lane = evidence(.sleep)
                lane.noteQuery(
                    query,
                    newestSampleAge: query == .records ? 60 : nil,
                    now: now
                )
                lane.noteDelivery(delivery, now: now)
                let pass = query == .records && delivery == .accepted
                XCTAssertEqual(gate([record([lane] + core.dropFirst().map(evidence))]), pass ? .pass : .hold,
                    "\(query.rawValue)/\(delivery.rawValue)")
            }
        }
        var queued = evidence(.sleep)
        queued.noteQueued(itemIDs: [item(1), item(2)], complete: true, now: now)
        XCTAssertEqual(gate([record([queued] + core.dropFirst().map(evidence))]), .hold)
        queued.noteQueued(itemIDs: [item(1)], complete: false, now: now)
        XCTAssertEqual(gate([record([queued] + core.dropFirst().map(evidence))]), .hold)
    }

    func testOrderedSelectionAttemptAndPrivacySerialization() throws {
        let draft = AutomaticSyncDiagnosticDraft(reason: .observer(typeCode: "heart_rate"))
        draft.notePlan([.sleep, .steps, .quantity, .workouts, .dailyActivity])
        draft.noteAttempt(.sleep)
        draft.noteQuery(.records, newestSampleAge: 9_000, now: now)
        draft.noteQueued(itemIDs: (1...100).map(item), complete: true, now: now)
        let chain = try XCTUnwrap(draft.record.causalChain)
        XCTAssertEqual(chain.lanes.first?.lane, .sleep)
        XCTAssertEqual(chain.lanes.first?.attempted, true)
        XCTAssertEqual(chain.lanes.first?.query, .records)
        XCTAssertEqual(chain.lanes[0].newestSampleAge, .oneToSixHours)
        XCTAssertTrue(chain.truncated)
        XCTAssertLessThanOrEqual(chain.lanes[0].pendingItems.count, AutomaticSyncLaneEvidence.maximumPendingItems)
        let data = try JSONEncoder().encode(draft.record)
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["heart_rate", "private_optional_identifier", "payload", "anchor", "cursor", "sourceKey", "deviceID", "receiverIdentity", "http", "SHA", "1800000100"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
        XCTAssertLessThan(data.count, 8_192)
        XCTAssertEqual(try JSONDecoder().decode(AutomaticSyncDiagnosticRecord.self, from: data), draft.record)
        XCTAssertEqual(gate([draft.record]), .hold)
    }

    func testRestartLateAcceptanceAndFinalizationCannotRegressDelivery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.json")
        let store = AutomaticSyncDiagnosticStore(fileURL: url)
        let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
        draft.notePlan([.sleep])
        draft.noteAttempt(.sleep)
        draft.noteQuery(.records, newestSampleAge: 60, now: now)
        draft.noteQueued(itemIDs: [item(7), item(8)], complete: true, now: now)
        XCTAssertTrue(store.recordFinal(draft.record))
        let restarted = AutomaticSyncDiagnosticStore(fileURL: url)
        XCTAssertTrue(restarted.noteDelivery(itemID: item(7), outcome: .mailboxAckPending, now: now))
        XCTAssertEqual(restarted.latestRecord?.causalChain?.lanes.first?.delivery, .mailboxAckPending)
        XCTAssertTrue(restarted.noteDelivery(itemID: item(7), outcome: .accepted, now: now))
        XCTAssertNotEqual(restarted.latestRecord?.causalChain?.lanes.first?.delivery, .accepted)
        XCTAssertTrue(restarted.noteDelivery(itemID: item(8), outcome: .accepted, now: now))
        XCTAssertEqual(restarted.latestRecord?.causalChain?.lanes.first?.delivery, .accepted)
        XCTAssertTrue(restarted.recordFinal(draft.record))
        XCTAssertEqual(restarted.latestRecord?.causalChain?.lanes.first?.delivery, .accepted)
        XCTAssertEqual(restarted.latestRecord?.runID, draft.runID)
        XCTAssertFalse(restarted.noteDelivery(itemID: item(999), outcome: .accepted, now: now))
    }

    func testTerminalDispositionCannotRemainDurablyQueuedEvidence() {
        for raw in ["rejected", "retired"] {
            guard let outcome = AutomaticSyncDeliveryOutcome(rawValue: raw) else {
                XCTFail("Missing terminal disposition: \(raw)")
                continue
            }
            var lane = evidence(.sleep)
            lane.noteQueued(itemIDs: [item(1)], complete: true, now: now)
            lane.noteDelivery(itemID: item(1), outcome: outcome, now: now)
            XCTAssertEqual(gate([record([lane] + core.dropFirst().map(evidence))]), .hold)
            XCTAssertNotEqual(lane.outbox, .queued)
        }
    }

    func testBoundedStoreEvictionUnknownJSONAndFailOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.json")
        let store = AutomaticSyncDiagnosticStore(fileURL: url, maximumRecordCount: 10_000)
        for _ in 0..<40 { XCTAssertTrue(store.recordFinal(record(core.map(evidence)))) }
        XCTAssertEqual(store.history.count, AutomaticSyncDiagnosticStore.maximumRecordCount)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, AutomaticSyncDiagnosticStore.maximumStorageBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let encoded = String(decoding: try JSONEncoder().encode(record(core.map(evidence))), as: UTF8.self)
        let unknown = encoded.replacingOccurrences(of: "\"query\":\"records\"", with: "\"query\":\"future_unknown\"")
        let decoded = try JSONDecoder().decode(AutomaticSyncDiagnosticRecord.self, from: Data(unknown.utf8))
        XCTAssertEqual(gate([decoded]), .hold)
        XCTAssertTrue(decoded.causalChain?.truncated == true)
        try Data(repeating: 0, count: AutomaticSyncDiagnosticStore.maximumStorageBytes + 1).write(to: url)
        XCTAssertTrue(store.history.isEmpty)
        let blocked = AutomaticSyncDiagnosticStore(fileURL: url.appendingPathComponent("child"))
        XCTAssertFalse(blocked.recordFinal(record(core.map(evidence))))
    }

    func testDraftSeparatesNotRunQueryFailureCancellationAndPostQueryFailure() throws {
        for stage in [AutomaticSyncDiagnosticFailureStage.read, .store, .transport] {
            let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
            draft.notePlan([.sleep, .steps])
            draft.noteAttempt(.sleep)
            draft.noteLaneFailure(.classified(stage: stage, isCancellation: false))
            XCTAssertEqual(draft.record.causalChain?.lanes[0].query, .notRun)
            draft.noteQueryStarted()
            draft.noteLaneFailure(.classified(stage: .read, isCancellation: false))
            XCTAssertEqual(draft.record.causalChain?.lanes[0].query, .failed)
            draft.noteQueryStarted()
            draft.noteLaneFailure(.classified(stage: .read, isCancellation: true))
            XCTAssertEqual(draft.record.causalChain?.lanes[0].query, .cancelled)
            draft.noteQuery(.noRecords, newestSampleAge: nil, now: now)
            draft.noteLaneFailure(.classified(stage: .transport, isCancellation: false))
            XCTAssertEqual(draft.record.causalChain?.lanes[0].query, .noRecords)
            XCTAssertEqual(draft.record.causalChain?.lanes[0].delivery, .failed)
            XCTAssertEqual(draft.record.causalChain?.lanes[1].query, .notRun)
        }
    }

    func testUnknownVersionAndMalformedOrTruncatedEvidenceHolds() throws {
        var valid = record(core.map(evidence))
        valid.causalChain?.version = 999
        XCTAssertEqual(gate([valid]), .hold)
        valid = record(core.map(evidence))
        valid.causalChain?.lanes[0].queryTimeBucket = nil
        XCTAssertEqual(gate([valid]), .hold)
        valid = record(core.map(evidence))
        valid.causalChain?.lanes[0].queryTimeBucket = Int(now.timeIntervalSince1970 / 900) + 1
        XCTAssertEqual(gate([valid]), .hold)
        XCTAssertEqual(CoreFreshnessReleasePolicy.evaluate(records: [record(core.map(evidence))], now: now,
            maximumQueryAge: .nan, maximumDeliveryAge: 3_600,
            sourceFreshnessRequirements: Dictionary(
                uniqueKeysWithValues: core.map { ($0, .newestSample(maximumAge: 3_600)) }
            )), .hold)
    }
}

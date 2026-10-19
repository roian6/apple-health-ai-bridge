import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class DailyProjectionRepairTests: XCTestCase {
    func testPartialWindowRetainsACKedMissingDayAcrossACKRestartAndStrictlyNewerCoverage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try fixture.queue([(fixture.a, 6), (fixture.b, 6)])
        XCTAssertNil(try fixture.repairStart())
        try fixture.accept(seed)
        try fixture.noteEmpty(start: fixture.a, end: fixture.b)
        XCTAssertEqual(try fixture.repairStart(), fixture.a)

        let partial = try fixture.queue([(fixture.a, 7)])
        XCTAssertTrue(partial.retirements.isEmpty)
        XCTAssertEqual(try fixture.repairStart(), fixture.a)
        try fixture.accept(partial)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        try fixture.reopen()
        XCTAssertEqual(try fixture.repairStart(), fixture.b)

        let equal = try fixture.queue([(fixture.b, 9)], order: partial.order, start: fixture.b)
        XCTAssertTrue(equal.retirements.isEmpty)
        try fixture.accept(equal)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        let older = try fixture.queue([(fixture.b, 9)], order: seed.order, start: fixture.b)
        try fixture.accept(older)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)

        let recovered = try fixture.queue([(fixture.b, 9)], start: fixture.b)
        XCTAssertEqual(recovered.retirements, [fixture.type: 1])
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        XCTAssertThrowsError(try fixture.outbox.recordDirectUploadAccepted(
            itemID: recovered.item.id, receiverIdentity: "unrelated-receiver"
        ))
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        try fixture.accept(recovered)
        try fixture.reopen()
        XCTAssertNil(try fixture.repairStart())
        try fixture.note(try fixture.batch([], start: fixture.b), order: partial.order, start: fixture.b)
        XCTAssertNil(try fixture.repairStart(), "An older empty observation cannot reopen newer ACKed coverage.")
        try fixture.note(try fixture.batch([], start: fixture.b), order: recovered.order, start: fixture.b)
        XCTAssertNil(try fixture.repairStart(), "Equal-order unknown cannot replace an ACKed completed observation.")
    }

    func testOnlyACKedCompletedZeroBecomesKnownNotBlankIncompleteOpenOrUnacceptedDays() throws {
        for mode in ["zero", "blank", "incomplete", "open", "unaccepted"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let values: [(Date, Double)] = mode == "blank" ? [(fixture.a, 6)] : [(fixture.a, 6), (fixture.b, 0)]
            let seed = try fixture.queue(
                values, end: mode == "open" ? fixture.b.addingTimeInterval(3600) : fixture.end,
                incompleteDay: mode == "incomplete" ? fixture.b : nil
            )
            if mode != "unaccepted" { try fixture.accept(seed) }
            let order = try fixture.outbox.reserveDailyProjectionObservation()
            let batch = try fixture.batch([(fixture.a, 7)])
            try fixture.note(batch, order: order)
            XCTAssertEqual(try fixture.repairStart(), mode == "zero" ? fixture.b : nil, mode)
        }
    }

    func testCompletedEvidenceIsIsolatedByReceiverSourceTypeAndCompletedWindow() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.accept(fixture.queue([(fixture.a, 6), (fixture.b, 6)]))
        let otherSource = HealthBridgeSource(sourceKey: "synthetic.other", name: "Synthetic", kind: .phone)
        for (receiver, source, type, end) in [
            ("other-receiver", fixture.source, fixture.type, fixture.end),
            (fixture.receiver, otherSource, fixture.type, fixture.end),
            (fixture.receiver, fixture.source, "energy", fixture.end),
            (fixture.receiver, fixture.source, fixture.type, fixture.b),
        ] {
            let order = try fixture.outbox.reserveDailyProjectionObservation()
            let batch = try fixture.batch([(fixture.a, 7)], type: type, source: source, end: end)
            _ = try XCTUnwrap(
                GenericQuantityCoveragePolicy.canonicalTypeCode(for: type) == type
                    && HealthKitTypeCatalog.entry(for: type) != nil
                    && batch.sources.map(\.sourceKey) == [source.sourceKey]
                    && batch.samples.count == 1
                    && batch.samples.allSatisfy({ $0.typeCode == type && $0.sourceKey == source.sourceKey })
                    ? true : nil,
                "SETUP: isolation requires supported canonical samples matching the requested source and type."
            )
            try fixture.note(batch, order: order, receiver: receiver, type: type, end: end)
            XCTAssertNil(try fixture.outbox.projectionRepairStart(
                receiverBindingID: receiver, sourceKey: source.sourceKey, typeCodes: [type]
            ))
        }
        XCTAssertNil(try fixture.repairStart())
        let partial = try fixture.queue([(fixture.a, 7)])
        try fixture.accept(partial)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
    }

    func testIncompleteOrOpenReplacementCannotRetireMissingCompletedDayBeforeRealNewZeroACK() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.accept(fixture.queue([(fixture.a, 6), (fixture.b, 6)]))
        let incomplete = try fixture.queue([(fixture.a, 7), (fixture.b, 0)], incompleteDay: fixture.b)
        XCTAssertTrue(incomplete.retirements.isEmpty)
        try fixture.accept(incomplete)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        let open = try fixture.queue([(fixture.a, 7), (fixture.b, 0)], end: fixture.b.addingTimeInterval(3600))
        XCTAssertTrue(open.retirements.isEmpty)
        try fixture.accept(open)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        let zero = try fixture.queue([(fixture.b, 0)], start: fixture.b)
        XCTAssertEqual(zero.retirements, [fixture.type: 1])
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        try fixture.accept(zero)
        XCTAssertNil(try fixture.repairStart())
    }

    func testLegacyOptionalFieldAbsencePreservesActualFIFOReservationAndRepairs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.accept(fixture.queue([(fixture.a, 6), (fixture.b, 6)]))
        try fixture.noteEmpty(start: fixture.b, end: fixture.end)
        let pending = try fixture.queue([(fixture.a, 7)], end: fixture.b)
        var legacy = try fixture.manifest()
        legacy.removeValue(forKey: "projectionCompleted")
        try fixture.writeManifest(legacy)

        try fixture.reopen()
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [pending.item.id])
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        XCTAssertEqual(try Data(contentsOf: pending.item.fileURL), pending.bytes)
        XCTAssertEqual(try fixture.manifest() as NSDictionary, legacy as NSDictionary)
        let next = try fixture.outbox.reserveDailyProjectionObservation()
        XCTAssertEqual(next.namespace, pending.order.namespace)
        XCTAssertGreaterThan(next.sequence, pending.order.sequence)
        try fixture.accept(pending)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        let partial = try fixture.queue([(fixture.a, 7)])
        try fixture.accept(partial)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)

        let historyOnly = try Fixture()
        defer { historyOnly.remove() }
        try historyOnly.accept(historyOnly.queue([(historyOnly.a, 6), (historyOnly.b, 6)]))
        var old = try historyOnly.manifest()
        old.removeValue(forKey: "projectionCompleted")
        try historyOnly.writeManifest(old)
        try historyOnly.reopen()
        try historyOnly.accept(historyOnly.queue([(historyOnly.a, 7)]))
        XCTAssertNil(try historyOnly.repairStart(), "A legacy history floor cannot prove that B was completed.")
    }

    func testDSTMissingDayUsesExactBoundariesDeduplicatesAndKeepsFullUInt64Fences() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.outbox.reserveDailyProjectionObservation()
        var manifest = try fixture.manifest()
        manifest["nextSequence"] = NSNumber(value: UInt64.max - 8)
        try fixture.writeManifest(manifest)
        try fixture.reopen()
        let seed = try fixture.queue([(fixture.a, 6), (fixture.b, 0)])
        XCTAssertEqual(seed.order.sequence, UInt64.max - 8)
        try fixture.accept(seed)
        let partial = try fixture.queue([(fixture.a, 7)])
        try fixture.note(try fixture.batch([(fixture.a, 7)]), order: partial.order)
        try fixture.accept(partial)
        let key = fixture.receiver + "\n" + fixture.source.sourceKey + "\n" + fixture.type
        let repairs = try XCTUnwrap((try fixture.manifest()["projectionRepairs"] as? [String: [[String: Any]]])?[key])
        XCTAssertEqual(repairs.count, 1)
        let repair = try XCTUnwrap(repairs.first)
        let start = try XCTUnwrap(repair["start"] as? Double)
        let end = try XCTUnwrap(repair["end"] as? Double)
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: start), fixture.b)
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: end), fixture.end)
        XCTAssertEqual(end - start, 23 * 3600)
        XCTAssertEqual((repair["sequence"] as? NSNumber)?.uint64Value, partial.order.sequence)
        let recovered = try fixture.queue([(fixture.b, 9)], start: fixture.b)
        try fixture.accept(recovered)
        XCTAssertNil(try fixture.repairStart())
        XCTAssertEqual(try fixture.outbox.reserveDailyProjectionObservation().sequence, UInt64.max - 2)
        XCTAssertEqual(try fixture.outbox.reserveDailyProjectionObservation().sequence, UInt64.max - 1)
        XCTAssertThrowsError(try fixture.outbox.reserveDailyProjectionObservation())
    }

    func testAllEmptyUnknownWindowRemainsConservativeWithoutInventingKnownDays() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.noteEmpty(start: fixture.a, end: fixture.end)
        XCTAssertEqual(try fixture.repairStart(), fixture.a)
        try fixture.reopen()
        XCTAssertEqual(try fixture.repairStart(), fixture.a)
        let aOnly = try fixture.queue([(fixture.a, 6)])
        try fixture.accept(aOnly)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        let bOnly = try fixture.queue([(fixture.b, 0)], start: fixture.b)
        XCTAssertEqual(try fixture.repairStart(), fixture.b)
        try fixture.accept(bOnly)
        XCTAssertNil(try fixture.repairStart())
    }

    private final class Fixture {
        let directory: URL
        var outbox: FileOutbox
        let receiver = "synthetic-receiver"
        let source = HealthBridgeAppleHealthSource.phone
        let type = "basal_energy"
        let calendar: Calendar
        let a: Date
        let b: Date
        let end: Date

        struct Delivery {
            let item: FileOutboxItem
            let order: DailyProjectionObservationOrder
            let retirements: [String: Int]
            let bytes: Data
        }

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            var local = Calendar(identifier: .gregorian)
            local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
            let first = try XCTUnwrap(local.date(from: DateComponents(year: 2024, month: 3, day: 9)))
            let second = try XCTUnwrap(local.date(byAdding: .day, value: 1, to: first))
            let last = try XCTUnwrap(local.date(byAdding: .day, value: 1, to: second))
            directory = root
            outbox = try FileOutbox(directory: root)
            calendar = local
            a = first
            b = second
            end = last
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
        func reopen() throws { outbox = try FileOutbox(directory: directory) }

        func batch(
            _ values: [(Date, Double)], type: String? = nil, source: HealthBridgeSource? = nil,
            start: Date? = nil, end: Date? = nil, incompleteDay: Date? = nil
        ) throws -> HealthBridgeBatchV1 {
            let actualType = type ?? self.type
            let actualSource = source ?? self.source
            let aggregates = try values.map { day, value in
                HealthKitDailyActivityAggregate(
                    typeCode: actualType, dayStart: day,
                    dayEnd: try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day)),
                    value: value, isComplete: day != incompleteDay,
                    timeZoneIdentifier: calendar.timeZone.identifier
                )
            }
            let batch = try XCTUnwrap(DailyActivityAggregateSyncBatchFactory.makeDailyActivityAggregateBatch(
                aggregates: aggregates, typeCodes: [actualType], windowStart: start ?? a,
                windowEnd: end ?? self.end, generatedAt: end ?? self.end
            ))
            return HealthBridgeBatchV1(
                generatedAt: batch.generatedAt, exportWindow: batch.exportWindow, sources: [actualSource],
                healthTypes: batch.healthTypes, samples: batch.samples.map { sample in
                    HealthBridgeSample(
                        clientRecordID: sample.clientRecordID, sourceKey: actualSource.sourceKey,
                        typeCode: sample.typeCode, startTime: sample.startTime, endTime: sample.endTime,
                        value: sample.value, unit: sample.unit, metadata: sample.metadata
                    )
                }, workouts: [], sleepSessions: [], deletedRecords: [], sync: batch.sync
            )
        }

        func note(
            _ batch: HealthBridgeBatchV1, order: DailyProjectionObservationOrder,
            receiver: String? = nil, type: String? = nil, start: Date? = nil, end: Date? = nil
        ) throws {
            try outbox.noteProjectionStatisticsWindow(
                batch: batch, order: order, receiverBindingID: receiver ?? self.receiver,
                typeCodes: [type ?? self.type], start: start ?? a, end: end ?? self.end, calendar: calendar
            )
        }

        func noteEmpty(start: Date, end: Date) throws {
            let order = try outbox.reserveDailyProjectionObservation()
            try note(try batch([], start: start, end: end), order: order, start: start, end: end)
        }

        func queue(
            _ values: [(Date, Double)], order: DailyProjectionObservationOrder? = nil,
            start: Date? = nil, end: Date? = nil, incompleteDay: Date? = nil
        ) throws -> Delivery {
            let reserved = try order ?? outbox.reserveDailyProjectionObservation()
            let batch = try batch(values, start: start, end: end, incompleteDay: incompleteDay)
            try note(batch, order: reserved, start: start, end: end)
            let observed = try DailyProjectionObservation(
                order: reserved, typeCode: type, statisticsWindow: batch.exportWindow
            ).appending(to: batch)
            let retirements = try outbox.projectionRetirementsCovered(
                [type: 1], batch: observed, order: reserved, receiverBindingID: receiver
            )
            let bytes = try JSONEncoder().encode(observed)
            let item = try XCTUnwrap(outbox.enqueueSequence(
                [bytes], receiverIdentity: receiver, pendingGenerationRetirements: retirements
            ).first)
            return Delivery(item: item, order: reserved, retirements: retirements, bytes: bytes)
        }

        func accept(_ delivery: Delivery) throws {
            if let record = try outbox.recordDirectUploadAccepted(itemID: delivery.item.id, receiverIdentity: receiver) {
                try outbox.acknowledgeFinalizationRecord(record)
            }
        }

        func repairStart() throws -> Date? {
            try outbox.projectionRepairStart(receiverBindingID: receiver, sourceKey: source.sourceKey, typeCodes: [type])
        }

        func manifest() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(".fifo-sequence"))) as? [String: Any])
        }

        func writeManifest(_ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent(".fifo-sequence"), options: .atomic)
        }
    }
}

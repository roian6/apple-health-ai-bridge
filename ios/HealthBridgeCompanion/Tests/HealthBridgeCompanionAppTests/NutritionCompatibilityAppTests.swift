import Foundation
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class NutritionCompatibilityAppTests: XCTestCase {
    func testDirectNutritionPreparationAllowsMainActor() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        _ = try fixture.enqueueMixed()
        let vm = try await fixture.makeViewModel()
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        fixture.outbox.observeNutritionCodec = { probe.record() }

        let sync = Task { @MainActor in await vm.syncSupportedQuantityMetrics() }
        await fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertFalse(probe.values.isEmpty)
        XCTAssertTrue(probe.values.allSatisfy { !$0 })
        probe.release()
        await sync.value

        XCTAssertEqual(fixture.receiver.records.count, 2)
        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertTrue(probe.values.allSatisfy { !$0 })
    }

    func testMailboxNutritionPreparationAllowsMainActor() async throws {
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let original = try fixture.base.enqueueMixed()
        fixture.base.receiver.capability = .legacy
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        fixture.base.outbox.observeNutritionCodec = { probe.record() }

        let publish = Task { @MainActor in try await fixture.delivery().publishPendingFIFOHead() }
        await fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertFalse(probe.values.isEmpty)
        XCTAssertTrue(probe.values.allSatisfy { !$0 })
        probe.release()
        _ = try await publish.value

        XCTAssertNil(try fixture.base.outbox.pendingItem(id: original.id)?.mailboxBinding)
        XCTAssertTrue(try fixture.base.outbox.pendingItems().contains {
            $0.id != original.id && $0.deliveryState?.phase == .providerObserved
        })
        XCTAssertFalse(probe.watchdogExpired)
    }

    func testBackgroundNutritionPreparationHonorsAdmissionAfterWorker() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let original = try fixture.enqueueMixed()
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        fixture.outbox.observeNutritionCodec = { probe.record() }
        let uploader = BackgroundURLSessionOutboxUploader()
        var admitted = true

        let schedule = Task { @MainActor in
            try await uploader.schedulePendingUploads(
                outbox: fixture.outbox,
                receiverURL: XCTUnwrap(URL(string: fixture.settings.receiverURLString)),
                bearerToken: fixture.settings.loadBearerToken(),
                receiverGeneration: fixture.settings.receiverSettingsGenerationToken,
                receiverBindingID: XCTUnwrap(fixture.settings.receiverBindingID),
                isUploadAllowed: { admitted }
            )
        }
        await fulfillment(of: [probe.entered], timeout: 5)
        admitted = false
        probe.release()
        let result = await schedule.result

        guard case .failure(let error) = result else { return XCTFail("Closed admission scheduled work") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(probe.values.isEmpty)
        XCTAssertTrue(probe.values.allSatisfy { !$0 })
        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertTrue(fixture.outbox.preparedNutritionPayloads.isEmpty)
        XCTAssertEqual(try fixture.outbox.pendingItems(), [original])
    }

    func testDirectNutritionReplacementDuringWorkerCannotDeliver() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let original = try fixture.enqueueMixed()
        let vm = try await fixture.makeViewModel()
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        fixture.outbox.observeNutritionCodec = { probe.record() }

        let sync = Task { @MainActor in await vm.syncSupportedQuantityMetrics() }
        await fulfillment(of: [probe.entered], timeout: 5)
        let before = try fixture.outbox.pendingItems()
        try fixture.settings.save(
            receiverURLString: "http://127.0.0.1:8766/v1/batches", bearerToken: "synthetic-replacement"
        )
        probe.release()
        await sync.value

        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertTrue(fixture.receiver.records.isEmpty)
        XCTAssertTrue(fixture.outbox.preparedNutritionPayloads.isEmpty)
        XCTAssertEqual(try fixture.outbox.pendingItems(), before)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: original.id))
    }

    func testLegacyReceiverWithholdsNutritionWhileWeightSyncs() async throws {
        // Given a legacy Receiver, not a version-string guess.
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.receiver.capability = .legacy
        let vm = try await fixture.makeViewModel()
        // When the real App quantity lane runs.
        await vm.syncSupportedQuantityMetrics()
        // Then supported records arrive without dietary catalogs, reads, or anchors.
        XCTAssertEqual(fixture.receiver.records.map(\.typeCode), ["weight"])
        XCTAssertFalse(fixture.reads.contains("dietary_protein"))
        XCTAssertNil(try fixture.cursor("dietary_protein"))
        XCTAssertEqual(try fixture.cursor("weight"), fixture.anchor)
        XCTAssertTrue(fixture.receiver.batches.allSatisfy { !NutritionCompatibility.containsNutrition($0) })
        XCTAssertFalse(vm.nutritionNotice.isEmpty)
    }

    func testUnknownOfflineRetainsDurableWorkWithoutClaimingDelivery() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let original = try fixture.enqueueMixed()
        let bytes = try Data(contentsOf: original.fileURL)
        fixture.receiver.capability = .offline
        let vm = try await fixture.makeViewModel()

        await vm.syncSupportedQuantityMetrics()

        XCTAssertTrue(fixture.receiver.records.isEmpty)
        XCTAssertNil(try fixture.cursor("dietary_protein"))
        XCTAssertNil(try fixture.cursor("weight"))
        XCTAssertEqual(try Data(contentsOf: original.fileURL), bytes)
        XCTAssertFalse(try fixture.outbox.pendingItems().isEmpty)
    }

    func testMixedDurableRetryUpgradePreservesAnchorAndDeduplicates() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let original = try fixture.enqueueMixed()
        let bytes = try Data(contentsOf: original.fileURL)
        fixture.receiver.capability = .unsupported
        let vm = try await fixture.makeViewModel()
        await vm.syncSupportedQuantityMetrics()
        XCTAssertNil(try fixture.cursor("dietary_protein"))
        XCTAssertEqual(try Data(contentsOf: original.fileURL), bytes)
        XCTAssertTrue(fixture.receiver.batches.allSatisfy { !NutritionCompatibility.containsNutrition($0) })
        let priorWeightIDs = Set(fixture.receiver.records.filter { $0.typeCode == "weight" }.map(\.clientRecordID))
        let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
        let before = try reopened.pendingItems().map(\.id)
        try await reopened.prepareNutritionCompatibility()
        _ = try reopened.nutritionCompatibleItems(
            for: XCTUnwrap(fixture.settings.receiverBindingID), support: .unknown
        )
        XCTAssertEqual(try reopened.pendingItems().map(\.id), before)
        fixture.receiver.capability = .supported

        await vm.syncSupportedQuantityMetrics()

        XCTAssertEqual(try fixture.cursor("dietary_protein"), fixture.anchor)
        XCTAssertFalse(try fixture.outbox.pendingItems().contains { $0.id == original.id })
        XCTAssertEqual(fixture.receiver.records.filter { $0.typeCode == "dietary_protein" }.map(\.value), [12])
        XCTAssertEqual(Set(fixture.receiver.records.filter { $0.typeCode == "weight" }.map(\.clientRecordID)), priorWeightIDs)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
    }

    func testFailedACKRetriesStableNutritionIdentity() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.receiver.status = 500
        let vm = try await fixture.makeViewModel()
        await vm.syncSupportedQuantityMetrics()
        XCTAssertNil(try fixture.cursor("dietary_protein"))
        let pending = try fixture.outbox.pendingItems()
        XCTAssertFalse(pending.isEmpty)
        fixture.receiver.status = 202

        await vm.syncSupportedQuantityMetrics()

        XCTAssertEqual(try fixture.cursor("dietary_protein"), fixture.anchor)
        XCTAssertEqual(fixture.receiver.records.filter { $0.typeCode == "dietary_protein" }.map(\.value), [12])
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
    }

    func testReplacementDoesNotInheritSupportedCapability() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.makeViewModel()
        await first.syncSupportedQuantityMetrics()
        let count = fixture.receiver.records.count
        try fixture.settings.save(receiverURLString: "http://127.0.0.1:8766/v1/batches",
                                  bearerToken: "synthetic-replacement")
        fixture.receiver.capability = .malformed
        fixture.reads = []
        let replacement = try await fixture.makeViewModel()

        await replacement.syncSupportedQuantityMetrics()

        XCTAssertFalse(fixture.reads.contains("dietary_protein"))
        XCTAssertNil(try fixture.cursor("dietary_protein"))
        XCTAssertEqual(fixture.receiver.records.count, count)
        XCTAssertEqual(fixture.receiver.credentials.last, "Bearer synthetic-replacement")
    }

    func testNoObservedNutritionIsNotZeroWhileSupportedSyncContinues() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.values = ["weight": 70]
        let vm = try await fixture.makeViewModel()

        await vm.syncSupportedQuantityMetrics()

        XCTAssertTrue(fixture.reads.contains("dietary_protein"))
        XCTAssertNil(try fixture.cursor("dietary_protein"))
        XCTAssertEqual(fixture.receiver.records.map(\.typeCode), ["weight"])
        XCTAssertFalse(vm.nutritionNotice.isEmpty)
    }

    func testRealZeroNutritionRemainsAnObservedRecord() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.values = ["weight": 70, "dietary_protein": 0]
        let vm = try await fixture.makeViewModel()

        await vm.syncSupportedQuantityMetrics()

        XCTAssertEqual(fixture.receiver.records.filter { $0.typeCode == "dietary_protein" }.map(\.value), [0])
        XCTAssertEqual(try fixture.cursor("dietary_protein"), fixture.anchor)
        XCTAssertNil(try fixture.cursor("dietary_fiber"))
        XCTAssertEqual(fixture.receiver.records.filter { $0.typeCode == "weight" }.map(\.value), [70])
    }

    func testMailboxLegacyMixedUpgradeAuthenticatedACKAndDeduplication() async throws {
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let original = try fixture.base.enqueueMixed()
        let bytes = try Data(contentsOf: original.fileURL)
        fixture.base.receiver.capability = .legacy
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let projection = try XCTUnwrap(fixture.base.outbox.pendingItems().first { $0.id != original.id })
        XCTAssertEqual(projection.deliveryState?.phase, .providerObserved)
        let supported = try fixture.receiveAndAcknowledge(projection)
        XCTAssertFalse(NutritionCompatibility.containsNutrition(supported))
        let oldACK = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(oldACK.finalizedCount, 1)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        XCTAssertEqual(try Data(contentsOf: original.fileURL), bytes)
        fixture.base.receiver.capability = .supported

        _ = try await fixture.delivery().publishPendingFIFOHead()
        _ = try fixture.receiveAndAcknowledge(original)
        let upgraded = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)

        XCTAssertEqual(upgraded.finalizedCount, 1)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertEqual(fixture.base.receiver.records.count, 2)
        XCTAssertEqual(fixture.base.receiver.records.filter { $0.typeCode == "dietary_protein" }.map(\.value), [12])
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
    }

    func testMailboxUnknownProbeNeverPublishesNutrition() async throws {
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let original = try fixture.base.enqueueMixed()
        fixture.base.receiver.capability = .offline

        _ = try await fixture.delivery().publishPendingFIFOHead()

        XCTAssertNil(try fixture.base.outbox.pendingItem(id: original.id)?.mailboxBinding)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        let projected = try XCTUnwrap(fixture.base.outbox.pendingItems().first { $0.id != original.id })
        XCTAssertEqual(projected.deliveryState?.phase, .providerObserved)
        XCTAssertTrue(fixture.base.receiver.records.isEmpty)
    }
}

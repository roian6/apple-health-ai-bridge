import Foundation
import HealthKit
import SwiftUI
import UIKit
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class NutritionCompatibilityAppTests: XCTestCase {
    func testDiscreteActivityRawACKRetiresGenerationWithoutDailyStatistics() async throws {
        for value: Double? in [nil, 0, 7] {
            let fixture = try NutritionFixture()
            defer { fixture.cleanup() }
            fixture.values = value.map { ["uv_exposure": $0] } ?? [:]
            let store = BackgroundSyncSettingsStore(userDefaults: fixture.defaults)
            try store.setEnabledDurably(true)
            CompanionHealthPermissionRequestStore(userDefaults: fixture.defaults).recordCompletedRequest(
                runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                    forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
                )
            )
            var dailyReads = 0
            let vm = try await fixture.makeViewModel(
                eligibleTypeCodes: ["uv_exposure"],
                readDailyActivityAggregates: { types, start, _, calendar in
                    dailyReads += 1
                    for entry in HealthKitGenericQuantityReader.readableQuantityEntries(for: types) {
                        let type = try XCTUnwrap(HealthKitQuantitySampleMapper.quantityType(for: entry))
                        _ = try HealthKitGenericQuantityReader.dailyActivityStatisticsQuery(
                            quantityType: type, predicate: nil,
                            anchorDate: calendar.startOfDay(for: start), interval: DateComponents(day: 1)
                        )
                    }
                    return []
                }
            )
            XCTAssertTrue(vm.automaticSyncRuntimeIsReady)
            let coordinator = HealthKitBackgroundDeliveryCoordinator(
                healthDataAvailable: { false },
                executeQuery: { _ in XCTFail("Unexpected HealthKit observer query") },
                stopQuery: { _ in }, enableDelivery: { _, completion in completion(false, nil) },
                disableDelivery: { _ in }
            )
            let runtime = HealthBridgeCompanionApplicationRuntime(
                viewModel: vm, automaticSyncPlatform: AutomaticSyncRuntime.Platform(
                    scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
                    setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in {} },
                    healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
                )
            )
            try store.markPendingObserverTypeCodes(["uv_exposure"])
            XCTAssertNotNil(try store.loadPendingObserverTypeCodeGenerations()["uv_exposure"])

            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["uv_exposure"]))
            await runtime.automaticSyncRuntime.cancelAndWait()
            await vm.waitForBootstrapAndForegroundWork()

            XCTAssertEqual(fixture.reads, ["uv_exposure"])
            XCTAssertEqual(dailyReads, 0, "A supported discrete metric must not enter the daily-sum reader")
            XCTAssertFalse(vm.statusIsError)
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
            let automaticCursor = try fixture.cursors.cursorValue(
                receiverBindingID: XCTUnwrap(fixture.settings.receiverBindingID),
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "uv_exposure")
            )
            XCTAssertNil(try fixture.cursor("uv_exposure"), "Automatic fallback must not claim the shared cursor")
            if let value {
                XCTAssertEqual(fixture.receiver.records.count, 1)
                let sample = try XCTUnwrap(fixture.receiver.records.first)
                XCTAssertEqual(sample.typeCode, "uv_exposure")
                XCTAssertEqual(sample.value, value)
                XCTAssertEqual(sample.metadata["sample_kind"], "raw_quantity")
                XCTAssertEqual(automaticCursor, fixture.anchor)
                XCTAssertNil(try store.loadPendingObserverTypeCodeGenerations()["uv_exposure"])
            } else {
                XCTAssertTrue(fixture.receiver.records.isEmpty, "Unknown data must not become an invented zero")
                XCTAssertNil(automaticCursor)
                XCTAssertNil(try store.loadPendingObserverTypeCodeGenerations()["uv_exposure"])
            }
            XCTAssertTrue(fixture.receiver.batches.flatMap(\.samples).allSatisfy {
                $0.metadata["sample_kind"] == "raw_quantity"
            })
        }
    }

    func testNativeURLFreeCapabilitiesCollectAndPublishNutrition() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        XCTAssertEqual(fixture.base.settings.receiverURLString, "")
        XCTAssertEqual(try fixture.base.settings.loadBearerToken(), "")
        let generation = fixture.base.settings.receiverSettingsGenerationToken
        let vm = try await fixture.base.makeViewModel(mailbox: fixture)

        await vm.syncSupportedQuantityMetrics()

        XCTAssertTrue(fixture.base.reads.contains("dietary_protein"), "Valid native declaration must admit the real reader")
        let items = try fixture.base.outbox.pendingItems()
        XCTAssertFalse(items.isEmpty, "Real collection must durably enqueue work")
        var receivedNutrition = false
        for item in items {
            _ = try await fixture.delivery().publishPendingFIFOHead()
            let batch = try fixture.receiveAndAcknowledge(item)
            receivedNutrition = receivedNutrition || NutritionCompatibility.containsNutrition(batch)
            _ = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        }
        XCTAssertTrue(receivedNutrition, "Nutrition must reach the actual mailbox transport")
        XCTAssertTrue(fixture.base.receiver.credentials.isEmpty, "Native discovery must not issue HTTP capability requests")
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertEqual(fixture.base.settings.receiverSettingsGenerationToken, generation)
    }

    func testNativeMissingOrInvalidCapabilitiesRetainDirtyNutritionAndQueryLaterWeight() async throws {
        for invalid in [false, true] {
            let fixture = try NutritionMailboxFixture(nativePairing: true)
            defer { fixture.base.cleanup() }
            if invalid { try fixture.writeCapabilities(tamperUnknownField: true) }
            let store = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
            try store.setEnabledDurably(true)
            CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
                runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                    forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
                )
            )
            let vm = try await fixture.base.makeViewModel(
                mailbox: fixture, eligibleTypeCodes: ["dietary_protein", "weight"]
            )
            XCTAssertTrue(vm.automaticSyncRuntimeIsReady, "Real native bootstrap must establish automatic admission")
            let coordinator = HealthKitBackgroundDeliveryCoordinator(
                healthDataAvailable: { false },
                executeQuery: { _ in XCTFail("Unexpected HealthKit observer query") },
                stopQuery: { _ in }, enableDelivery: { _, completion in completion(false, nil) },
                disableDelivery: { _ in }
            )
            // The real engine and bootstrap own readiness and traversal; no seeded cursor/proof.
            let runtime = HealthBridgeCompanionApplicationRuntime(
                viewModel: vm, automaticSyncPlatform: AutomaticSyncRuntime.Platform(
                    scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
                    setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in {} },
                    healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
                )
            )
            try store.markPendingObserverTypeCodes(["dietary_protein", "weight"])
            let original = try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"]
            XCTAssertNotNil(original)
            await runtime.automaticSyncRuntime.runAutomaticSync(
                reason: .observerBatch(typeCodes: ["dietary_protein", "weight"])
            )
            await runtime.automaticSyncRuntime.cancelAndWait()
            await vm.waitForBootstrapAndForegroundWork()
            XCTAssertFalse(fixture.base.reads.contains("dietary_protein"))
            XCTAssertTrue(fixture.base.reads.contains("weight"), "Held nutrition must not stop the later real query")
            XCTAssertEqual(try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"], original)
            XCTAssertNil(try fixture.base.cursor("dietary_protein"))
            let supported = try XCTUnwrap(fixture.base.outbox.pendingItems().first)
            let received = try fixture.receiveAndAcknowledge(supported)
            XCTAssertEqual(received.samples.map(\.typeCode), ["weight"])
            let ack = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
            XCTAssertEqual(ack.finalizedCount, 1)
            XCTAssertNil(try fixture.base.outbox.pendingItem(id: supported.id))
            XCTAssertEqual(try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"], original)
        }
    }

    func testNativeInvalidCapabilitiesDoNotBlockExistingAuthenticatedACK() async throws {
        // Existing HTTP-paired Mailbox connection: publish before capability discovery fails.
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let original = try fixture.base.enqueueMixed()
        try fixture.writeCapabilities()
        let delivery = fixture.delivery()
        _ = try await delivery.publishPendingFIFOHead()
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        _ = try fixture.receiveAndAcknowledge(original)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        try fixture.writeCapabilities(tamperUnknownField: true)
        fixture.base.receiver.capability = .offline
        let result = try await delivery.reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(result.finalizedCount, 1)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: original.id))
        let remaining = try fixture.base.outbox.pendingItems()
        XCTAssertTrue(remaining.isEmpty, "An already published original must not create a second supported delivery")
    }

    func testCapabilityTokenFailureDoesNotReportQuantitySyncSuccess() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let vm = try await fixture.makeViewModel()
        vm.statusIsError = false
        // Generation, binding and URL reads succeed; the bearer-token read fails.
        fixture.tokenStore.loadsBeforeFailure = 3

        await vm.syncSupportedQuantityMetrics()

        XCTAssertEqual(fixture.tokenStore.failedLoads, 1)
        XCTAssertTrue(vm.statusIsError)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(fixture.receiver.records.isEmpty)
        XCTAssertNil(try fixture.cursor("weight"))
        vm.statusIsError = false
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await vm.syncSupportedQuantityMetrics()
        }
        await cancelled.value
        XCTAssertFalse(vm.statusIsError)
        XCTAssertTrue(fixture.reads.isEmpty)
    }

    func testMissingCapabilityFileDoesNotBlockPublishedMailboxACK() async throws {
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let original = try fixture.base.enqueueMixed()
        let delivery = fixture.delivery()
        _ = try await delivery.publishPendingFIFOHead()
        _ = try fixture.receiveAndAcknowledge(original)
        try fixture.removeCapabilities()
        let phase = try await delivery.pendingFIFOHeadBackgroundPhase()
        XCTAssertEqual(phase, .reconcileFIFOHeadAcknowledgment)
        let result = try await delivery.reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(result.finalizedCount, 1)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: original.id))
        let remaining = try fixture.base.outbox.pendingItems()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(fixture.base.receiver.records.count, 2)
        XCTAssertTrue(fixture.base.receiver.credentials.isEmpty)
    }

    func testStoppedSyncDoesNotDuplicateNutritionNotice() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.receiver.capability = .legacy
        let vm = try await fixture.makeViewModel()
        await vm.syncSupportedQuantityMetrics()
        let notice = vm.nutritionNotice
        XCTAssertFalse(notice.isEmpty)

        vm.statusIsError = true
        vm.statusMessage = "Synthetic failure"
        vm.statusMessage = "Sync stopped: \(vm.statusMessage)"
        vm.statusMessage = "Retry stopped: \(vm.statusMessage)"

        for style in [UIUserInterfaceStyle.light, .dark] {
            let appeared = expectation(description: "Production status view appeared")
            let host = UIHostingController(rootView: ContentView(viewModel: vm).onAppear { appeared.fulfill() })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            await fulfillment(of: [appeared], timeout: 5)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "nutrition-stopped-\(style == .light ? "light" : "dark")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(vm.statusMessage, "Retry stopped: Sync stopped: Synthetic failure")
        XCTAssertEqual(
            vm.displayStatusMessage,
            CompanionPrimaryStatusMessage.sanitized(from: vm.statusMessage, isError: true) + " " + notice
        )
        XCTAssertEqual(vm.displayStatusMessage.components(separatedBy: notice).count, 2)
        XCTAssertFalse(try XCTUnwrap(vm.activityLogMessages.last).contains(notice))
    }

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
        try fixture.removeCapabilities()
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
        let original = try fixture.enqueueMixed(workoutEnergy: 10)
        fixture.values["weight"] = 71
        let update = try XCTUnwrap(NutritionCompatibility.supportedProjection(fixture.mixedBatch(workoutEnergy: 20)))
        _ = try fixture.outbox.enqueue(
            JSONEncoder().encode(update), receiverIdentity: XCTUnwrap(fixture.settings.receiverBindingID)
        )
        let bytes = try Data(contentsOf: original.fileURL)
        fixture.receiver.capability = .unsupported
        let vm = try await fixture.makeViewModel()
        await vm.syncSupportedQuantityMetrics()
        XCTAssertNil(try fixture.cursor("dietary_protein"))
        XCTAssertEqual(try Data(contentsOf: original.fileURL), bytes)
        XCTAssertTrue(fixture.receiver.batches.allSatisfy { !NutritionCompatibility.containsNutrition($0) })
        XCTAssertEqual(fixture.receiver.workouts.map(\.energyKcal), [20])
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
        XCTAssertEqual(fixture.receiver.workouts.map(\.energyKcal), [20])
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
        let original = try fixture.base.enqueueMixed(workoutEnergy: 10)
        let update = try XCTUnwrap(NutritionCompatibility.supportedProjection(fixture.base.mixedBatch(workoutEnergy: 20)))
        let newer = try fixture.base.outbox.enqueue(
            JSONEncoder().encode(update), receiverIdentity: XCTUnwrap(fixture.base.settings.receiverBindingID)
        )
        let bytes = try Data(contentsOf: original.fileURL)
        fixture.base.receiver.capability = .legacy
        try fixture.removeCapabilities()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let projection = try XCTUnwrap(fixture.base.outbox.pendingItems().first { $0.deliveryState?.phase == .providerObserved })
        XCTAssertEqual(projection.deliveryState?.phase, .providerObserved)
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: newer.id)?.mailboxBinding)
        let supported = try fixture.receiveAndAcknowledge(projection)
        XCTAssertFalse(NutritionCompatibility.containsNutrition(supported))
        let oldACK = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(oldACK.finalizedCount, 1)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        XCTAssertEqual(try Data(contentsOf: original.fileURL), bytes)
        _ = try await fixture.delivery().publishPendingFIFOHead()
        _ = try fixture.receiveAndAcknowledge(newer)
        let supportedUpdate = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(supportedUpdate.finalizedCount, 1)
        XCTAssertEqual(fixture.base.receiver.workouts.map(\.energyKcal), [20])
        fixture.base.receiver.capability = .supported
        try fixture.writeCapabilities()

        _ = try await fixture.delivery().publishPendingFIFOHead()
        let remainder = try XCTUnwrap(fixture.base.outbox.pendingItems().first { $0.deliveryState?.phase == .providerObserved })
        XCTAssertNotEqual(remainder.id, original.id)
        let nutrition = try fixture.receiveAndAcknowledge(remainder)
        XCTAssertTrue(nutrition.workouts.isEmpty)
        let upgraded = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)

        XCTAssertEqual(upgraded.finalizedCount, 1)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertEqual(fixture.base.receiver.records.count, 2)
        XCTAssertEqual(fixture.base.receiver.records.filter { $0.typeCode == "dietary_protein" }.map(\.value), [12])
        XCTAssertEqual(fixture.base.receiver.workouts.map(\.energyKcal), [20])
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
    }

    func testMailboxUnknownProbeNeverPublishesNutrition() async throws {
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let original = try fixture.base.enqueueMixed()
        fixture.base.receiver.capability = .offline
        try fixture.removeCapabilities()

        _ = try await fixture.delivery().publishPendingFIFOHead()

        XCTAssertNil(try fixture.base.outbox.pendingItem(id: original.id)?.mailboxBinding)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        let projected = try XCTUnwrap(fixture.base.outbox.pendingItems().first { $0.id != original.id })
        XCTAssertEqual(projected.deliveryState?.phase, .providerObserved)
        XCTAssertTrue(fixture.base.receiver.records.isEmpty)
    }
}

extension NutritionCompatibilityAppTests {
    private func nativeAutomaticRuntime(_ fixture: NutritionMailboxFixture) async throws -> HealthBridgeCompanionApplicationRuntime {
        let store = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
        try store.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes)
        )
        let vm = try await fixture.base.makeViewModel(mailbox: fixture, eligibleTypeCodes: ["dietary_protein"])
        XCTAssertTrue(vm.automaticSyncRuntimeIsReady)
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false }, executeQuery: { _ in XCTFail("Unexpected observer query") },
            stopQuery: { _ in }, enableDelivery: { _, completion in completion(false, nil) }, disableDelivery: { _ in }
        )
        return HealthBridgeCompanionApplicationRuntime(viewModel: vm, automaticSyncPlatform: AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {}, setUploadAdmission: { _ in },
            beginBackgroundOwner: { _ in {} }, healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
        ))
    }

    func testNativeNutritionOnlyDirtyGenerationResumesWithoutNewObserverAndClearsAfterACK() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        fixture.base.values = ["dietary_protein": 12]
        let runtime = try await nativeAutomaticRuntime(fixture)
        let store = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
        try store.markPendingObserverTypeCodes(["dietary_protein"])
        let originalDirty = try XCTUnwrap(store.loadPendingObserverTypeCodeGenerations()["dietary_protein"])
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["dietary_protein"]))
        XCTAssertEqual(try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"], originalDirty)
        XCTAssertTrue(fixture.base.reads.isEmpty)
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
        let generation = fixture.base.settings.receiverSettingsGenerationToken
        try fixture.writeCapabilities()
        // No new observer event, record, pairing or dirty generation is introduced.
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        await runtime.automaticSyncRuntime.cancelAndWait()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
        XCTAssertEqual(fixture.base.settings.receiverSettingsGenerationToken, generation)
        XCTAssertTrue(fixture.base.reads.contains("dietary_protein"))
        XCTAssertEqual(try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"], originalDirty)
        let pending = try XCTUnwrap(fixture.base.outbox.pendingItems().first)
        let checkpoint = try XCTUnwrap(fixture.base.outbox.pendingCursorCheckpoint())
        XCTAssertNil(try fixture.base.cursors.cursorValue(receiverBindingID: checkpoint.receiverIdentity,
            sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind))
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let batch = try fixture.receiveAndAcknowledge(pending)
        XCTAssertTrue(NutritionCompatibility.containsNutrition(batch))
        let result = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(result.finalizedCount, 1)
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: pending.id))
        XCTAssertNil(try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"])
        XCTAssertEqual(try fixture.base.cursors.cursorValue(receiverBindingID: checkpoint.receiverIdentity,
            sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind), fixture.base.anchor)
    }

    func testNativeCapabilityReadCancellationAndReplacementCannotCollect() async throws {
        for replace in [false, true] {
            let fixture = try NutritionMailboxFixture(nativePairing: true)
            defer { fixture.base.cleanup() }
            try fixture.writeCapabilities()
            let probe = NutritionCodecProbe(blocking: true)
            defer { probe.release() }
            fixture.capabilityReadIO.readBytes = { url in
                probe.record()
                return try MailboxRegularFileReader.read(url, maximumBytes: 8192)
            }
            let vm = try await fixture.base.makeViewModel(mailbox: fixture)
            let sync = Task { @MainActor in await vm.syncSupportedQuantityMetrics() }
            await fulfillment(of: [probe.entered], timeout: 5)
            XCTAssertFalse(probe.watchdogExpired)
            XCTAssertTrue(probe.values.allSatisfy { !$0 })
            if replace { _ = try fixture.base.settings.invalidateReceiverSettingsGeneration() }
            else { sync.cancel() }
            probe.release()
            await sync.value
            XCTAssertTrue(fixture.base.reads.isEmpty)
            XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
            XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        }
    }
}

extension NutritionCompatibilityAppTests {
    func testNativeAutomaticOffDuringCapabilityReadRetainsDirtyWork() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        fixture.capabilityReadIO.readBytes = { url in
            probe.record()
            return try MailboxRegularFileReader.read(url, maximumBytes: 8192)
        }
        let runtime = try await nativeAutomaticRuntime(fixture)
        let store = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
        try store.markPendingObserverTypeCodes(["dietary_protein"])
        let dirty = try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"]
        let sync = Task { @MainActor in
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["dietary_protein"]))
        }
        await fulfillment(of: [probe.entered], timeout: 5)
        runtime.viewModel.requestBackgroundSyncEnabled(false)
        probe.release()
        await sync.value
        await runtime.viewModel.waitForAutomaticSyncDisableCleanup()
        XCTAssertFalse(runtime.viewModel.backgroundSyncEnabled)
        XCTAssertTrue(fixture.base.reads.isEmpty)
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"], dirty)
        XCTAssertFalse(probe.watchdogExpired)
    }
}

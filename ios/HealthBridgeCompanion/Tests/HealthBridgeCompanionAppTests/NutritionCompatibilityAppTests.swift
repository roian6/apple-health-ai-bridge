import Foundation
import HealthKit
import SwiftUI
import UIKit
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class NutritionCompatibilityAppTests: XCTestCase {
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
            XCTAssertFalse(fixture.base.reads.contains("dietary_protein"))
            XCTAssertTrue(fixture.base.reads.contains("weight"), "Held nutrition must not stop the later real query")
            XCTAssertEqual(try store.loadPendingObserverTypeCodeGenerations()["dietary_protein"], original)
            XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        }
    }

    func testNativeInvalidCapabilitiesDoNotBlockExistingAuthenticatedACK() async throws {
        // Existing HTTP-paired Mailbox connection: publish before capability discovery fails.
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let original = try fixture.base.enqueueMixed()
        let delivery = fixture.delivery()
        _ = try await delivery.publishPendingFIFOHead()
        _ = try fixture.receiveAndAcknowledge(original)
        try fixture.writeCapabilities(tamperUnknownField: true)
        fixture.base.receiver.capability = .offline
        let result = try await delivery.reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(result.finalizedCount, 1)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
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

    func testCapabilityTokenFailureDoesNotBlockPublishedMailboxACK() async throws {
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let original = try fixture.base.enqueueMixed()
        let delivery = fixture.delivery()
        _ = try await delivery.publishPendingFIFOHead()
        _ = try fixture.receiveAndAcknowledge(original)
        // Five metadata reads and two five-read validations precede the token.
        fixture.base.tokenStore.loadsBeforeFailure = 15
        do {
            let phase = try await delivery.pendingFIFOHeadBackgroundPhase()
            XCTAssertEqual(phase, .reconcileFIFOHeadAcknowledgment)
        } catch {
            XCTFail("Capability token failure blocked ACK phase selection: \(error)")
        }
        XCTAssertEqual(fixture.base.tokenStore.failedLoads, 1)
        fixture.base.tokenStore.loadsBeforeFailure = 15

        do {
            let result = try await delivery.reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
            XCTAssertEqual(result.finalizedCount, 1)
        } catch {
            XCTFail("Capability token failure blocked authenticated ACK finalization: \(error)")
        }

        XCTAssertEqual(fixture.base.tokenStore.failedLoads, 2)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
        XCTAssertEqual(fixture.base.receiver.records.count, 2)
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

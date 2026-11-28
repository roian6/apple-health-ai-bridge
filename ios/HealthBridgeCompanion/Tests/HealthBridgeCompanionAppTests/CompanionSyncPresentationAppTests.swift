import Foundation
import HealthKit
import os
import SwiftUI
import Vision
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class CompanionSyncPresentationAppTests: XCTestCase {
    func testHealthAuthorizationNoticesKeepOpeningStateUntilRequestFinishes() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        // The Sync card is visible during a repeat permission request.
        viewModel.healthPermissionsRequested = true

        for (state, notice, requesting, isError, expected) in [
            ("pending", "Opening Apple Health permissions...", true, false, "opening apple health permissions"),
            ("finished", "Apple Health permission request completed.", false, false, "access request finished"),
            ("error", "Apple Health permission failed.", false, true, "apple health permission failed"),
        ] {
            viewModel.healthPermissionNotice = notice
            viewModel.isRequestingHealthPermissions = requesting
            viewModel.healthPermissionNoticeIsError = isError

            let scope = try await renderedText(
                NavigationStack { DataScopeView(viewModel: viewModel) }, name: "health-data-\(state)"
            )
            let home = try await renderedText(ContentView(viewModel: viewModel), name: "sync-card-\(state)")
            XCTAssertTrue(scope.contains(expected), "Health Data \(state): \(scope)")
            XCTAssertTrue(home.contains(expected), "Sync card \(state): \(home)")
            if requesting {
                XCTAssertFalse(scope.contains("request finished"), scope)
                XCTAssertFalse(home.contains("request finished"), home)
            }
        }
    }

    func testDirectQueueWithAutomaticSyncOffTellsUserToTapSyncNow() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let item = try fixture.enqueueMixed()
        let viewModel = try await fixture.makeViewModel(
            readAnchoredStepChanges: { _, _, _ in throw CocoaError(.featureUnsupported) }
        )
        let runtime = HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel, automaticSyncPlatform: .init(beginBackgroundOwner: { _ in {} })
        )
        viewModel.healthPermissionsRequested = true

        await viewModel.checkConnection()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertFalse(viewModel.backgroundSyncEnabled)
        XCTAssertTrue(fixture.receiver.batches.isEmpty)
        XCTAssertEqual(viewModel.syncPresentation.phase, .directQueued)
        XCTAssertTrue(viewModel.syncPresentation.detail.contains("Sync Now"), viewModel.syncPresentation.detail)

        await runtime.viewModel.performPrimaryAction()

        XCTAssertNil(try fixture.outbox.pendingItem(id: item.id))
        XCTAssertEqual(Set(fixture.receiver.records.map(\.typeCode)), ["weight", "dietary_protein"])
    }

    func testMailboxSeparatesUnpublishedQueueFromPublishedFIFOHead() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        try BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults).setEnabledDurably(true)
        let head = try fixture.base.enqueueMixed()
        let tail = try fixture.base.enqueueMixed(workoutEnergy: 20)
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        viewModel.healthPermissionsRequested = true
        let queue = try fixture.base.outbox.pendingItems()
        XCTAssertEqual(queue.map(\.id), [head.id, tail.id])
        XCTAssertTrue(queue.allSatisfy { $0.deliveryState == nil })
        XCTAssertEqual(viewModel.syncPresentation.phase, .mailboxQueued)
        XCTAssertFalse(viewModel.syncPresentation.title.contains("receiver confirmation"), viewModel.syncPresentation.title)
        XCTAssertTrue(viewModel.syncPresentation.detail.contains("queued"), viewModel.syncPresentation.detail)

        viewModel.runForegroundMailboxReconciliationIfNeeded()
        await viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(try fixture.base.outbox.pendingItem(id: head.id)?.deliveryState?.phase, .providerObserved)
        let unpublishedTail = try XCTUnwrap(fixture.base.outbox.pendingItem(id: tail.id))
        XCTAssertEqual(unpublishedTail.deliveryState?.phase, .collected)
        XCTAssertNil(unpublishedTail.deliveryState?.ownership)
        XCTAssertNil(unpublishedTail.mailboxBinding)
        XCTAssertEqual(viewModel.syncPresentation.phase, .mailboxConfirmationWaiting)
        XCTAssertTrue(viewModel.syncPresentation.detail.contains("A published upload"), viewModel.syncPresentation.detail)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testHeldNutritionDoesNotLogACompletedUpload() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(
            changes: HealthKitAnchoredQuantityChanges(
                typeCode: "dietary_protein",
                samples: [HealthKitQuantitySampleSummary(
                    uuid: UUID(), typeCode: "dietary_protein", start: now,
                    end: now.addingTimeInterval(60), value: 12
                )],
                deletedSamples: [], anchorCursorValue: fixture.anchor,
                windowStart: now, windowEnd: now.addingTimeInterval(60)
            ), generatedAt: now
        ).first)
        let item = try fixture.outbox.enqueue(
            JSONEncoder().encode(batch), receiverIdentity: XCTUnwrap(fixture.settings.receiverBindingID)
        )
        fixture.receiver.capability = .unsupported
        // Stop at the next lane so this witness only observes the manual queue flush.
        let viewModel = try await fixture.makeViewModel(
            readAnchoredStepChanges: { _, _, _ in throw CocoaError(.featureUnsupported) }
        )

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertTrue(fixture.receiver.batches.isEmpty)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: item.id))
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
        XCTAssertFalse(viewModel.activityLogMessages.contains { $0.hasSuffix("Queued uploads sent") })
        XCTAssertTrue(viewModel.activityLogMessages.contains {
            $0.hasSuffix("Nothing was sent. Uploads are still queued.")
        }, "\(viewModel.activityLogMessages)")

        fixture.receiver.capability = .supported
        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertEqual(fixture.receiver.batches.count, 1)
        XCTAssertNil(try fixture.outbox.pendingItem(id: item.id))
        XCTAssertTrue(viewModel.activityLogMessages.contains { $0.hasSuffix("Queued uploads sent") })
    }

    private func renderedText<Screen: View>(_ screen: Screen, name: String) async throws -> String {
        let appeared = expectation(description: "\(name) appeared")
        let host = UIHostingController(rootView: screen.onAppear { appeared.fulfill() })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let previousKey = scene.keyWindow
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKey?.makeKey()
        }
        await fulfillment(of: [appeared], timeout: 5)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return try XCTUnwrap(request.results)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .lowercased()
    }

    func testConnectionCheckDoesNotInventAcceptedTransfer() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()

        await viewModel.checkConnection()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(viewModel.syncPresentation.phase, .permissionRequestNeeded)
    }

    func testCursorOnlyTransferRecordsAcceptanceWithoutHealthSamples() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.values = [:]
        let viewModel = try await fixture.makeViewModel()
        await viewModel.syncSupportedQuantityMetrics()

        XCTAssertTrue(fixture.receiver.records.isEmpty)
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation?.evidenceKind, .directResponse)
    }

    func testFailedUploadDoesNotInventAcceptedTransfer() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.receiver.status = 503
        let viewModel = try await fixture.makeViewModel()

        await viewModel.syncSupportedQuantityMetrics()

        XCTAssertTrue(fixture.receiver.records.isEmpty)
        XCTAssertFalse(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testAcceptedDirectTransferSurvivesEmptyCheckAndViewModelRecreation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.defaults)
        try background.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let viewModel = try await fixture.makeViewModel(eligibleTypeCodes: ["weight"])
        await viewModel.syncSupportedQuantityMetrics()
        let accepted = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(accepted.evidenceKind, .directResponse)
        XCTAssertEqual(Set(fixture.receiver.records.map(\.typeCode)), ["weight", "dietary_protein"])
        let observation = LastAcceptedTransferObservation(
            bindingID: accepted.bindingID, generation: accepted.generation,
            observedAt: Date(timeIntervalSinceReferenceDate: 123_456), evidenceKind: .directResponse
        )
        fixture.acceptedTransferStore.record(observation)
        let batches = fixture.receiver.batches
        let reads = fixture.reads.count
        fixture.values = [:]
        try background.markPendingObserverTypeCodes(["weight"])
        let generations = try background.loadPendingObserverTypeCodeGenerations()

        let result = await viewModel.processAutomaticSyncType("weight", pendingGenerations: generations)

        XCTAssertEqual(result, .noPayloadCovering(generations))
        XCTAssertEqual(fixture.reads.count, reads + 1)
        XCTAssertEqual(fixture.reads.last, "weight")
        XCTAssertEqual(fixture.receiver.batches.count, batches.count)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.cursor("weight"), fixture.anchor)
        XCTAssertEqual(try fixture.cursor("dietary_protein"), fixture.anchor)
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation, observation)

        let reopened = try await fixture.makeViewModel()

        XCTAssertEqual(reopened.lastAcceptedTransferObservation, observation)
    }

    func testConnectionReplacementHidesPreviousAcceptedTransfer() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        await viewModel.syncSupportedQuantityMetrics()
        _ = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        viewModel.receiverURLString = "http://127.0.0.1:8766/v1/batches"
        viewModel.bearerToken = "synthetic-replacement"

        await viewModel.saveReceiverSettings()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testMailboxPublicationRemainsUnconfirmed() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        fixture.base.values = ["weight": 70]
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        await viewModel.syncSupportedQuantityMetrics()

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertTrue(try fixture.base.outbox.pendingItems().contains {
            $0.deliveryState?.phase == .providerObserved
        })
        XCTAssertEqual(viewModel.syncPresentation.phase, .mailboxConfirmationWaiting)
        XCTAssertNil(viewModel.activityMailboxFailureMessage)
        XCTAssertEqual(viewModel.activityStatusDetail, viewModel.syncPresentation.detail)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testMailboxActivityReflectsDurablePublicationWhenProviderLookupFails() async throws {
        for reconcileInForeground in [false, true] {
            for failurePhase: OutboxDeliveryPhase in [.encrypted, .published] {
                let fixture = try NutritionMailboxFixture(nativePairing: true)
                defer { fixture.base.cleanup() }
                try fixture.writeCapabilities()
                try BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults).setEnabledDurably(true)
                CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
                    runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                        forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
                    )
                )
                let item = try fixture.base.enqueueMixed()
                let outbox = fixture.base.outbox
                var lookupFailed = false
                fixture.beforeTransportLocate = {
                    if try outbox.pendingItem(id: item.id)?.deliveryState?.phase == failurePhase {
                        lookupFailed = true
                        throw MailboxLocatorError.symbolicLink
                    }
                }
                let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)
                XCTAssertTrue(viewModel.automaticSyncRuntimeIsReady)
                XCTAssertEqual(viewModel.syncPresentation.phase, .mailboxQueued)

                if reconcileInForeground {
                    viewModel.runForegroundMailboxReconciliationIfNeeded()
                } else {
                    viewModel.schedulePendingBackgroundOutboxUploadsIfAllowed()
                }
                await viewModel.waitForBootstrapAndForegroundWork()

                let context = "foreground=\(reconcileInForeground), failurePhase=\(failurePhase)"
                XCTAssertTrue(lookupFailed, context)
                XCTAssertEqual(try outbox.pendingItems().map(\.id), [item.id], context)
                XCTAssertEqual(try outbox.pendingItem(id: item.id)?.deliveryState?.phase, failurePhase, context)
                XCTAssertEqual(viewModel.syncPresentation.phase,
                               failurePhase == .published ? .mailboxConfirmationWaiting : .mailboxQueued, context)
                let diagnostic = try XCTUnwrap(viewModel.activityMailboxFailureMessage, context)
                XCTAssertTrue(diagnostic.hasPrefix("Mailbox ACK diagnostics failed: "), context)
                XCTAssertFalse(diagnostic.contains(fixture.base.root.path), context)
                XCTAssertEqual(viewModel.activityStatusDetail, diagnostic, context)
                XCTAssertNil(viewModel.lastAcceptedTransferObservation, context)
                XCTAssertNil(try fixture.base.cursor("dietary_protein"), context)
            }
        }
    }

    func testScheduledMailboxPassRetainsReconciliationFailureUntilMatchingCommit() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
        try background.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let bindingID = fixture.identity.opaqueBinding
        let headType = "dietary_protein"
        let tailType = "weight"
        try background.markPendingObserverTypeCodes([headType, tailType])
        let debt = try background.loadPendingObserverTypeCodeGenerations()
        let headGeneration = try XCTUnwrap(debt[headType])
        let tailGeneration = try XCTUnwrap(debt[tailType])
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: bindingID, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: headType),
            cursorValue: fixture.base.anchor
        )
        let outbox = fixture.base.outbox
        let head = try XCTUnwrap(outbox.enqueueSequence(
            [JSONEncoder().encode(fixture.base.mixedBatch())], receiverIdentity: bindingID,
            cursorCheckpoint: checkpoint, pendingGenerationRetirements: [headType: headGeneration]
        ).first)
        let tail = try XCTUnwrap(outbox.enqueueSequence(
            [JSONEncoder().encode(fixture.base.mixedBatch(workoutEnergy: 20))], receiverIdentity: bindingID,
            pendingGenerationRetirements: [tailType: tailGeneration]
        ).first)
        fixture.beforeTransportLocate = {
            if try outbox.pendingItem(id: head.id)?.deliveryState?.phase == .published {
                throw MailboxLocatorError.symbolicLink
            }
        }
        do {
            _ = try await fixture.delivery().publishPendingFIFOHeadWithOwnership()
            XCTFail("Expected the provider lookup to fail after durable publication")
        } catch let error as ProductionMailboxItemDeliveryError {
            XCTAssertEqual(error.phase, .initialAdvance)
            XCTAssertEqual(error.itemID, head.id)
        }
        let published = try XCTUnwrap(outbox.pendingItem(id: head.id))
        XCTAssertEqual(published.deliveryState?.phase, .published)
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture, eligibleTypeCodes: [])
        XCTAssertTrue(viewModel.automaticSyncRuntimeIsReady)
        viewModel.runForegroundMailboxReconciliationIfNeeded()
        await viewModel.waitForBootstrapAndForegroundWork()
        let failure = try XCTUnwrap(viewModel.activityMailboxFailureMessage)
        XCTAssertTrue(failure.contains("phase=initial_advance"))

        fixture.beforeTransportLocate = nil
        let envelopeID = try fixture.components().transport.finalizedEnvelopeID(itemID: head.id)
        let ackName = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .acknowledgment)
        let ackURL = try XCTUnwrap(fixture.locator.lanes[.acks]).appendingPathComponent(ackName)
        try Data("unverifiable synthetic receipt".utf8).write(to: ackURL, options: .atomic)
        let inspectedHeadCandidate = OSAllocatedUnfairLock(initialState: false)
        fixture.prepareAckCandidate = { url in
            if url.lastPathComponent == ackName {
                inspectedHeadCandidate.withLock { $0 = true }
            }
            return MailboxAckScanner.prepareCandidateForBoundedRead(url)
        }
        // Drive the scheduled opportunity on the already bootstrapped model, without
        // activating a foreground catch-up or re-running bootstrap's outbox scheduler.
        let runtime = AutomaticSyncRuntime(
            viewModel: viewModel, platform: .init(beginBackgroundOwner: { _ in {} })
        )
        await runtime.runAutomaticSync(reason: .scheduledRefresh)

        XCTAssertTrue(inspectedHeadCandidate.withLock { $0 }, "The scheduled pass must reach ACK reconciliation")
        let run = try XCTUnwrap(background.lastRun)
        XCTAssertNotNil(run.finishedAt)
        XCTAssertEqual(run.outcome, .interrupted)
        XCTAssertEqual(viewModel.activityMailboxFailureMessage, failure)
        XCTAssertEqual(viewModel.activityStatusDetail, failure)
        XCTAssertEqual(viewModel.syncPresentation.phase, .mailboxConfirmationWaiting)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [head.id, tail.id])
        let waiting = try XCTUnwrap(outbox.pendingItem(id: head.id))
        XCTAssertEqual(waiting.deliveryState?.phase, .providerObserved)
        XCTAssertEqual(waiting.mailboxBinding, published.mailboxBinding)
        XCTAssertNil(try outbox.pendingItem(id: tail.id)?.mailboxBinding)
        XCTAssertEqual(try outbox.pendingCursorCheckpoint(), checkpoint)
        XCTAssertNil(try fixture.base.cursor(headType))
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), debt)

        _ = try fixture.receiveAndAcknowledge(waiting)
        await runtime.runAutomaticSync(reason: .scheduledRefresh)

        XCTAssertNil(viewModel.activityMailboxFailureMessage)
        let observation = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(observation.evidenceKind, .mailboxCommit)
        XCTAssertEqual(observation.bindingID, bindingID)
        XCTAssertEqual(observation.generation, fixture.base.settings.receiverSettingsGenerationToken)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [tail.id])
        XCTAssertNil(try outbox.pendingCursorCheckpoint())
        XCTAssertEqual(try fixture.base.cursor(headType), fixture.base.anchor)
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), [tailType: tailGeneration])
    }

    func testScheduledMailboxCommitDoesNotClearAnotherItemsManualFailure() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
        try background.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let outbox = fixture.base.outbox
        let bindingID = fixture.identity.opaqueBinding
        let head = try outbox.enqueue(JSONEncoder().encode(fixture.base.mixedBatch()), receiverIdentity: bindingID)
        let tail = try outbox.enqueue(
            JSONEncoder().encode(fixture.base.mixedBatch(workoutEnergy: 20)), receiverIdentity: bindingID
        )
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let waitingHead = try XCTUnwrap(outbox.pendingItem(id: head.id))
        XCTAssertEqual(waitingHead.deliveryState?.phase, .providerObserved)
        XCTAssertNil(try outbox.pendingItem(id: tail.id)?.mailboxBinding)

        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture, eligibleTypeCodes: [])
        XCTAssertTrue(viewModel.automaticSyncRuntimeIsReady)
        XCTAssertNil(viewModel.activityMailboxFailureMessage)
        fixture.beforeTransportLocate = {
            if try outbox.pendingItem(id: tail.id)?.deliveryState?.phase == .published {
                throw MailboxLocatorError.symbolicLink
            }
        }
        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        await viewModel.waitForBootstrapAndForegroundWork()

        let failure = try XCTUnwrap(viewModel.activityMailboxFailureMessage)
        XCTAssertTrue(failure.contains("phase=initial_advance"))
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [head.id, tail.id])
        let failedTail = try XCTUnwrap(outbox.pendingItem(id: tail.id))
        XCTAssertEqual(failedTail.deliveryState?.phase, .published)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)

        fixture.beforeTransportLocate = nil
        _ = try fixture.receiveAndAcknowledge(waitingHead)
        let runtime = AutomaticSyncRuntime(
            viewModel: viewModel, platform: .init(beginBackgroundOwner: { _ in {} })
        )
        fixture.ackScanFault = { boundary in
            if boundary == .beforeCandidateOpen { throw MailboxAckScannerError.unsafeMailbox }
        }
        await runtime.runAutomaticSync(reason: .scheduledRefresh)

        let headFailure = try XCTUnwrap(viewModel.activityMailboxFailureMessage)
        XCTAssertTrue(headFailure.contains("phase=scan_ack"))
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [head.id, tail.id])
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)

        fixture.ackScanFault = { _ in }
        await runtime.runAutomaticSync(reason: .scheduledRefresh)

        let headAcceptance = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(headAcceptance.evidenceKind, .mailboxCommit)
        XCTAssertEqual(headAcceptance.bindingID, bindingID)
        XCTAssertEqual(headAcceptance.generation, fixture.base.settings.receiverSettingsGenerationToken)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [tail.id])
        let waitingTail = try XCTUnwrap(outbox.pendingItem(id: tail.id))
        XCTAssertEqual(waitingTail.deliveryState?.phase, .providerObserved)
        XCTAssertEqual(waitingTail.mailboxBinding, failedTail.mailboxBinding)
        XCTAssertEqual(viewModel.activityMailboxFailureMessage, failure,
                       "A committed, but B has only been observed by the provider")

        let previousAcceptance = LastAcceptedTransferObservation(
            bindingID: bindingID, generation: headAcceptance.generation,
            observedAt: Date(timeIntervalSinceReferenceDate: 234_567), evidenceKind: .mailboxCommit
        )
        fixture.base.acceptedTransferStore.record(previousAcceptance)
        _ = try fixture.receiveAndAcknowledge(waitingTail)
        await runtime.runAutomaticSync(reason: .scheduledRefresh)

        XCTAssertNil(viewModel.activityMailboxFailureMessage)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        let tailAcceptance = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertNotEqual(tailAcceptance, previousAcceptance)
        XCTAssertEqual(tailAcceptance.evidenceKind, .mailboxCommit)
        XCTAssertEqual(tailAcceptance.bindingID, bindingID)
        XCTAssertEqual(tailAcceptance.generation, headAcceptance.generation)
    }

    func testFailedMailboxReconciliationClearsOnlyResolvedPhaseSelection() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        try BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults).setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let outbox = fixture.base.outbox
        // Exercise delivery and diagnostics without introducing two copies of
        // the same nutrition cursor transaction ahead of the intended fault.
        let binding = fixture.identity.opaqueBinding
        let head = try outbox.enqueue(JSONEncoder().encode(fixture.base.mixedBatch()), receiverIdentity: binding)
        let tail = try outbox.enqueue(
            JSONEncoder().encode(fixture.base.mixedBatch(workoutEnergy: 20)), receiverIdentity: binding
        )
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let waitingHead = try XCTUnwrap(outbox.pendingItem(id: head.id))
        XCTAssertEqual(waitingHead.deliveryState?.phase, .providerObserved)
        let vm = try await fixture.base.makeViewModel(mailbox: fixture, eligibleTypeCodes: [])
        XCTAssertTrue(vm.automaticSyncRuntimeIsReady)

        fixture.beforeTransportLocate = {
            if try outbox.pendingItem(id: tail.id)?.deliveryState?.phase == .published {
                throw MailboxLocatorError.symbolicLink
            }
        }
        await vm.performManualSyncOpportunity(processPendingTypes: { false })
        await vm.waitForBootstrapAndForegroundWork()
        let tailFailure = try XCTUnwrap(vm.activityMailboxFailureMessage)
        XCTAssertTrue(tailFailure.contains("phase=initial_advance"))
        XCTAssertEqual(try outbox.pendingItem(id: tail.id)?.deliveryState?.phase, .published)
        fixture.beforeTransportLocate = nil

        fixture.beforeDeliveryComponents = { throw MailboxLocatorError.symbolicLink }
        vm.noteSceneLeftActive()
        vm.runForegroundMailboxReconciliationIfNeeded()
        await vm.waitForBootstrapAndForegroundWork()
        let selectionFailure = try XCTUnwrap(vm.activityMailboxFailureMessage)
        XCTAssertTrue(selectionFailure.contains("error=mailbox_delivery_failed"))
        XCTAssertNotEqual(selectionFailure, tailFailure)

        _ = try fixture.receiveAndAcknowledge(waitingHead)
        fixture.beforeDeliveryComponents = nil
        fixture.ackScanFault = { boundary in
            if boundary == .beforeCandidateOpen { throw MailboxAckScannerError.unsafeMailbox }
        }
        vm.noteSceneLeftActive()
        vm.runForegroundMailboxReconciliationIfNeeded()
        await vm.waitForBootstrapAndForegroundWork()
        XCTAssertTrue(vm.activityMailboxFailureMessage?.contains("phase=scan_ack") == true)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [head.id, tail.id])
        XCTAssertNil(vm.lastAcceptedTransferObservation)

        // Manual delivery can resolve the head's item failure but does not select
        // the background phase. The preceding failed reconcile must retire that diagnostic.
        fixture.ackScanFault = { _ in }
        await vm.performManualSyncOpportunity(processPendingTypes: { false })
        XCTAssertEqual(try outbox.deliveryState(for: head.id)?.phase, .committedFinalized)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [tail.id])
        XCTAssertEqual(vm.activityMailboxFailureMessage, tailFailure)
    }

    func testAuthenticatedMailboxCommitRecordsAcceptedTransfer() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        _ = try fixture.base.enqueueMixed()
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        let pending = try XCTUnwrap(fixture.base.outbox.pendingItems().first {
            $0.deliveryState?.phase == .providerObserved
        })
        _ = try fixture.receiveAndAcknowledge(pending)
        let ackLane = try XCTUnwrap(fixture.locator.lanes[.acks])
        let ackURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: ackLane, includingPropertiesForKeys: nil
        ).first)
        let ackBytes = try Data(contentsOf: ackURL)

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        let observation = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(observation.evidenceKind, .mailboxCommit)
        XCTAssertEqual(observation.bindingID, fixture.identity.opaqueBinding)
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: pending.id))
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        let retained = LastAcceptedTransferObservation(
            bindingID: observation.bindingID, generation: observation.generation,
            observedAt: Date(timeIntervalSinceReferenceDate: 234_567), evidenceKind: .mailboxCommit
        )
        fixture.base.acceptedTransferStore.record(retained)
        let batches = fixture.base.receiver.batches.count

        // Replay the exact signed receipt after retirement, alongside new work
        // that has no ACK and therefore cannot earn another observation.
        try ackBytes.write(to: ackURL, options: .atomic)
        let next = try fixture.base.enqueueMixed(workoutEnergy: 20)
        let replayViewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        XCTAssertEqual(try fixture.components().scanner.scan().events.count, 1)

        await replayViewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertEqual(replayViewModel.lastAcceptedTransferObservation, retained)
        XCTAssertEqual(try fixture.base.outbox.pendingItems().map(\.id), [next.id])
        XCTAssertEqual(try fixture.base.outbox.pendingItem(id: next.id)?.deliveryState?.phase, .providerObserved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ackURL.path))
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertEqual(fixture.base.receiver.batches.count, batches)
    }

    func testMailboxArtifactCleanupRecoveryRequiresExactCommittedProof() async throws {
        try await checkMailboxArtifactCleanupRecovery(manualOnly: false)
    }

    func testManualMailboxItemFailureRetriesEmptyFIFOUsingOnlyMatchingReceipt() async throws {
        try await checkMailboxArtifactCleanupRecovery(manualOnly: true)
    }

    private func checkMailboxArtifactCleanupRecovery(manualOnly: Bool) async throws {
        let files = MailboxEnvelopeRemovalFailure()
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let suite = fixture.base.suite + ".receipt-count"
        let defaults = try XCTUnwrap(ForegroundSleepCommitDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        fixture.base.acceptedTransferStore = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.base.acceptedTransferResetEpochURL
        )
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
        try background.setEnabledDurably(!manualOnly)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let outbox = fixture.base.outbox
        let bindingID = fixture.identity.opaqueBinding
        let unrelated = try outbox.enqueue(JSONEncoder().encode(fixture.base.mixedBatch()), receiverIdentity: bindingID)
        _ = try await fixture.delivery().publishPendingFIFOHead()
        _ = try fixture.receiveAndAcknowledge(unrelated)
        let viewModel = try await fixture.base.makeViewModel(
            mailbox: fixture, eligibleTypeCodes: [],
            readAnchoredStepChanges: { _, _, _ in throw CocoaError(.featureUnsupported) },
            reopenStorage: true, outboxFileManager: files
        )
        XCTAssertEqual(viewModel.automaticSyncRuntimeIsReady, !manualOnly)
        let runtime = AutomaticSyncRuntime(
            viewModel: viewModel, platform: .init(beginBackgroundOwner: { _ in {} })
        )
        func runOpportunity() async {
            if manualOnly {
                await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
            } else {
                await runtime.runAutomaticSync(reason: .scheduledRefresh)
            }
        }
        await runOpportunity()
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        let unrelatedAcceptance = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(defaults.commitWrites, 1)
        let manifestURL = outbox.directoryURL.appendingPathComponent(".fifo-sequence")
        let unrelatedOnly = try Data(contentsOf: manifestURL)

        let failed = try fixture.base.enqueueMixed(workoutEnergy: 20)
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let published = try XCTUnwrap(outbox.pendingItem(id: failed.id))
        _ = try fixture.receiveAndAcknowledge(published)
        let providerAck: URL?
        if manualOnly {
            let envelopeID = try fixture.components().transport.finalizedEnvelopeID(itemID: published.id)
            let name = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .acknowledgment)
            providerAck = try XCTUnwrap(fixture.locator.lanes[.acks]).appendingPathComponent(name)
        } else {
            providerAck = nil
        }
        let binding = try XCTUnwrap(published.mailboxBinding)
        let envelope = outbox.directoryURL.appendingPathComponent(binding.envelopeFilename)
        let receiptCount = fixture.base.receiver.batches.count
        files.rejectNextRemoval = envelope
        await runOpportunity()

        XCTAssertEqual(files.rejectedRemoval, envelope)
        let failure = try XCTUnwrap(viewModel.activityMailboxFailureMessage)
        XCTAssertTrue(failure.contains("phase=consume_ack"))
        XCTAssertEqual(viewModel.pendingOutboxCount, 0)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        let failedItemAcceptance = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertNotEqual(failedItemAcceptance, unrelatedAcceptance)
        XCTAssertEqual(failedItemAcceptance.bindingID, bindingID)
        XCTAssertEqual(failedItemAcceptance.generation, fixture.base.settings.receiverSettingsGenerationToken)
        XCTAssertEqual(failedItemAcceptance.evidenceKind, .mailboxCommit)
        XCTAssertEqual(defaults.commitWrites, 2, "Unlink failure must not hide a new durable commit")

        let reopened = try FileOutbox(directory: outbox.directoryURL)
        XCTAssertTrue(try reopened.pendingItems().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
        let committed = try XCTUnwrap(reopened.deliveryState(for: failed.id))
        XCTAssertEqual(committed.phase, .committedFinalized)
        XCTAssertEqual(committed.ownership?.receiverBindingID, bindingID)
        XCTAssertEqual(committed.ownership?.receiverGeneration, fixture.base.settings.receiverSettingsGenerationToken)
        XCTAssertEqual(committed.committedReceipt?.payloadSHA256, binding.payloadSHA256)
        let repaired = try Data(contentsOf: manifestURL)
        if let providerAck {
            // Recovery must use the local receipt, not a replay of the provider ACK.
            // Replay cleanup would run its own full scan to revalidate before unlinking.
            try FileManager.default.removeItem(at: providerAck)
        }
        var fullScanCount = 0
        fixture.ackScanFault = { boundary in
            if boundary == .laneOpened { fullScanCount += 1 }
        }

        // An older local snapshot contains an authentic commit for the same receiver,
        // but not for the failed item. The FIFO is empty in both snapshots.
        try unrelatedOnly.write(to: manifestURL, options: .atomic)
        XCTAssertNil(try reopened.deliveryState(for: failed.id))
        XCTAssertEqual(try reopened.deliveryState(for: unrelated.id)?.phase, .committedFinalized)
        await runOpportunity()
        XCTAssertEqual(viewModel.activityMailboxFailureMessage, failure)
        if manualOnly {
            XCTAssertEqual(fullScanCount, 1, "The unrelated receipt must be a no-op after actually retrying")
        }

        try repaired.write(to: manifestURL, options: .atomic)
        await runOpportunity()
        if manualOnly {
            XCTAssertEqual(fullScanCount, 2, "The matching receipt must be checked by manual delivery")
        }
        XCTAssertNil(viewModel.activityMailboxFailureMessage)
        XCTAssertTrue(try reopened.pendingItems().isEmpty)
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation, failedItemAcceptance)
        XCTAssertEqual(defaults.commitWrites, 2, "Recovery must not record the same commit again")
        XCTAssertEqual(fixture.base.receiver.batches.count, receiptCount)
    }

    func testManualMailboxPostRenameHardeningFailurePreservesAcceptanceAcrossReopen() async throws {
        try await checkManualMailboxCommitWithHardeningFailure(replaceGeneration: false)
    }

    func testManualMailboxPostRenameHardeningFailureDoesNotCreditReplacementGeneration() async throws {
        try await checkManualMailboxCommitWithHardeningFailure(replaceGeneration: true)
    }

    private func checkManualMailboxCommitWithHardeningFailure(replaceGeneration: Bool) async throws {
        let files = MailboxEnvelopeRemovalFailure()
        let fixture = try NutritionMailboxFixture(nativePairing: true, outboxFileManager: files)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        try BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults).setEnabledDurably(false)
        let suite = fixture.base.suite + ".post-rename-observation"
        let defaults = try XCTUnwrap(ForegroundSleepCommitDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let observations = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.base.acceptedTransferResetEpochURL
        )
        fixture.base.acceptedTransferStore = observations
        let outbox = fixture.base.outbox
        let settings = fixture.base.settings
        let generation = settings.receiverSettingsGenerationToken
        let bindingID = fixture.identity.opaqueBinding
        let item = try fixture.base.enqueueMixed()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let head = try XCTUnwrap(outbox.pendingItem(id: item.id))
        let binding = try XCTUnwrap(head.mailboxBinding)
        let owner = try XCTUnwrap(head.deliveryState?.ownership)
        XCTAssertEqual(head.deliveryState?.phase, .providerObserved)
        _ = try fixture.receiveAndAcknowledge(head)
        let components = fixture.components()
        let event = try XCTUnwrap(components.scanner.scan().events.first)
        let receipt = try XCTUnwrap(OutboxDeliveryCommittedReceiptV1(event: event))
        var deniedCollection: [[String]] = []
        let viewModel = try await fixture.base.makeViewModel(
            mailbox: fixture, eligibleTypeCodes: [],
            readAnchoredStepChanges: replaceGeneration ? nil : { @MainActor @Sendable _, _, _ in
                XCTFail("Mailbox fixture must not reach the Steps reader")
                throw CocoaError(.featureUnsupported)
            },
            requestReadAuthorization: { types in
                guard !replaceGeneration else { return }
                deniedCollection.append(types)
                throw CocoaError(.featureUnsupported)
            }
        )
        let ackLane = try XCTUnwrap(fixture.locator.lanes[.acks])
        let ackURL = ackLane.appendingPathComponent(try MailboxLayoutV1.finalFileName(
            identifier: event.envelopeID.hexV1, kind: .acknowledgment
        ))
        let deliveries = try XCTUnwrap(fixture.locator.lanes[.deliveries])
        let sent = try FileManager.default.contentsOfDirectory(atPath: deliveries.path).sorted()
        let receiverCount = fixture.base.receiver.batches.count
        let credentials = fixture.base.receiver.credentials
        let httpRequests = fixture.base.receiver.httpRequests
        let localEnvelope = outbox.directoryURL.appendingPathComponent(binding.envelopeFilename)
        var persistedAtFault: FileOutboxDeliveryStateV1?
        var replacement: String?
        files.rejectManifestHardening = { path in
            guard path == outbox.directoryURL.appendingPathComponent(".fifo-sequence").path else { return false }
            // This read opens the on-disk manifest, without reconciliation or hardening.
            let state = try outbox.mailboxBoundItemsForAckScanning().first { $0.id == item.id }?.deliveryState
            guard state?.phase == .committedFinalized else { return false }
            persistedAtFault = state
            XCTAssertTrue(FileManager.default.fileExists(atPath: localEnvelope.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL.path))
            if replaceGeneration {
                replacement = try settings.invalidateReceiverSettingsGeneration(expectedGeneration: generation)
            }
            return true
        }
        defer { files.rejectManifestHardening = nil }

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertTrue(files.didRejectManifestHardening)
        XCTAssertEqual(persistedAtFault?.committedReceipt, receipt)
        XCTAssertEqual(persistedAtFault?.ownership, owner)
        XCTAssertEqual(owner.receiverBindingID, bindingID)
        XCTAssertEqual(owner.receiverGeneration, generation)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ackURL.path), "Hardening error must interrupt normal ACK cleanup")
        let expectedWrites = replaceGeneration ? 0 : 1
        XCTAssertEqual(defaults.commitWrites, expectedWrites)
        let observation = viewModel.lastAcceptedTransferObservation
        if replaceGeneration {
            let newGeneration = try XCTUnwrap(replacement)
            XCTAssertNotEqual(newGeneration, generation)
            XCTAssertEqual(settings.receiverSettingsGenerationToken, newGeneration)
            XCTAssertEqual(settings.receiverBindingID, bindingID)
            XCTAssertNil(observation)
            XCTAssertNil(observations.load(bindingID: bindingID, generation: generation))
            XCTAssertNil(observations.load(bindingID: bindingID, generation: newGeneration))
        } else {
            XCTAssertTrue(deniedCollection.isEmpty, "The failed delivery must stop before HealthKit collection")
            XCTAssertTrue(viewModel.statusIsError)
            XCTAssertTrue(viewModel.activityMailboxFailureMessage?.contains("phase=consume_ack") == true)
            XCTAssertEqual(observation?.bindingID, bindingID)
            XCTAssertEqual(observation?.generation, generation)
            XCTAssertEqual(observation?.evidenceKind, .mailboxCommit)
        }
        let reopened = try FileOutbox(directory: outbox.directoryURL)
        XCTAssertEqual(try reopened.deliveryState(for: item.id), persistedAtFault)
        XCTAssertTrue(try reopened.pendingItems().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localEnvelope.path))
        if !replaceGeneration {
            await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
            XCTAssertFalse(FileManager.default.fileExists(atPath: ackURL.path))
            XCTAssertEqual(viewModel.lastAcceptedTransferObservation, observation)
            XCTAssertEqual(deniedCollection, [["steps"]])
            try assertNoMailboxFixtureStepsProgress(fixture)
            XCTAssertEqual(fixture.base.receiver.httpRequests, httpRequests)
        }
        XCTAssertEqual(defaults.commitWrites, expectedWrites, "Reopen and replay are not new commits")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: deliveries.path).sorted(), sent)
        XCTAssertEqual(fixture.base.receiver.batches.count, receiverCount)
        XCTAssertEqual(fixture.base.receiver.credentials, credentials)
    }

    func testManualMailboxCancellationBeforeAtomicCommitDoesNotRecordAcceptance() async throws {
        try await checkMailboxCancellationAtCommit(.beforeCommit)
    }

    func testManualMailboxCancellationAfterAtomicCommitPreservesAcceptance() async throws {
        try await checkMailboxCancellationAtCommit(.committedManual)
    }

    func testBoundedMailboxCancellationAfterAtomicCommitPreservesAcceptance() async throws {
        try await checkMailboxCancellationAtCommit(.committedBounded)
    }

    func testBoundedMailboxCancellationAndCleanupFailurePreserveDurableAcceptance() async throws {
        try await checkMailboxCancellationAtCommit(.cancelledWithCleanupError)
    }

    func testCancelledMailboxCommitDoesNotCreditAuthoritativeReplacement() async throws {
        try await checkMailboxCancellationAtCommit(.replacedAfterCommit)
    }

    private func checkMailboxCancellationAtCommit(_ scenario: MailboxCommitCancellation) async throws {
        let files = MailboxEnvelopeRemovalFailure()
        let fixture = try NutritionMailboxFixture(nativePairing: true, outboxFileManager: files)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let bounded = scenario == .committedBounded || scenario == .cancelledWithCleanupError
        try BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults).setEnabledDurably(bounded)
        if bounded {
            CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
                runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                    forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
                )
            )
        }
        let suite = fixture.base.suite + ".commit-cancellation"
        let defaults = try XCTUnwrap(ForegroundSleepCommitDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let observations = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.base.acceptedTransferResetEpochURL
        )
        fixture.base.acceptedTransferStore = observations
        let outbox = fixture.base.outbox
        let settings = fixture.base.settings
        let generation = settings.receiverSettingsGenerationToken
        let bindingID = fixture.identity.opaqueBinding
        let item = try fixture.base.enqueueMixed()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let head = try XCTUnwrap(outbox.pendingItem(id: item.id))
        XCTAssertEqual(head.deliveryState?.phase, .providerObserved)
        let owner = try XCTUnwrap(head.deliveryState?.ownership)
        _ = try fixture.receiveAndAcknowledge(head)
        let event = try XCTUnwrap(fixture.components().scanner.scan().events.first)
        let receipt = try XCTUnwrap(OutboxDeliveryCommittedReceiptV1(event: event))
        let vm = try await fixture.base.makeViewModel(
            mailbox: fixture, eligibleTypeCodes: [],
            requestReadAuthorization: { _ in throw CocoaError(.featureUnsupported) }
        )
        XCTAssertNil(vm.lastAcceptedTransferObservation)
        let phase: OutboxDeliveryPhase = scenario == .beforeCommit ? .ackVerified : .committedFinalized
        var cancelledAt: FileOutboxDeliveryStateV1?
        files.rejectManifestHardening = { path in
            guard cancelledAt == nil,
                  path == outbox.directoryURL.appendingPathComponent(".fifo-sequence").path,
                  let state = try outbox.mailboxBoundItemsForAckScanning().first(where: { $0.id == item.id })?.deliveryState,
                  state.phase == phase else { return false }
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL.path))
            cancelledAt = state
            if scenario == .replacedAfterCommit {
                _ = try settings.invalidateReceiverSettingsGeneration(expectedGeneration: generation)
            }
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            if scenario == .beforeCommit { try Task.checkCancellation() }
            return scenario == .cancelledWithCleanupError
        }
        defer { files.rejectManifestHardening = nil }

        if bounded {
            XCTAssertTrue(vm.automaticSyncRuntimeIsReady)
            vm.noteSceneLeftActive()
            vm.runForegroundMailboxReconciliationIfNeeded()
            await vm.waitForBootstrapAndForegroundWork()
        } else {
            let sync = Task { @MainActor in
                await vm.performManualSyncOpportunity(processPendingTypes: { false })
            }
            await sync.value
            XCTAssertTrue(sync.isCancelled)
        }

        let boundary = try XCTUnwrap(cancelledAt)
        XCTAssertEqual(boundary.committedReceipt, receipt)
        XCTAssertEqual(boundary.ownership, owner)
        let reopened = try FileOutbox(directory: outbox.directoryURL)
        XCTAssertEqual(try reopened.deliveryState(for: item.id), boundary)
        let observation = vm.lastAcceptedTransferObservation
        switch scenario {
        case .beforeCommit:
            XCTAssertEqual(try reopened.pendingItems().map(\.id), [item.id])
            XCTAssertNil(try fixture.base.cursor("dietary_protein"))
            XCTAssertNil(observation)
            XCTAssertEqual(defaults.commitWrites, 0)
        case .replacedAfterCommit:
            let replacementBinding = try XCTUnwrap(settings.receiverBindingID)
            let replacementGeneration = settings.receiverSettingsGenerationToken
            XCTAssertEqual(replacementBinding, bindingID)
            XCTAssertNotEqual(replacementGeneration, generation)
            XCTAssertNil(observations.load(bindingID: bindingID, generation: generation))
            XCTAssertNil(observations.load(bindingID: replacementBinding, generation: replacementGeneration))
            XCTAssertNil(observation)
            XCTAssertEqual(defaults.commitWrites, 0)
        case .committedManual, .committedBounded, .cancelledWithCleanupError:
            if scenario == .cancelledWithCleanupError {
                XCTAssertTrue(files.didRejectManifestHardening)
            } else {
                XCTAssertTrue(try reopened.pendingItems().isEmpty)
            }
            XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
            XCTAssertEqual(observation?.evidenceKind, .mailboxCommit)
            XCTAssertEqual(observation?.bindingID, bindingID)
            XCTAssertEqual(observation?.generation, generation)
            XCTAssertEqual(defaults.commitWrites, 1)
            await vm.performManualSyncOpportunity(processPendingTypes: { false })
            XCTAssertEqual(vm.lastAcceptedTransferObservation, observation)
            XCTAssertEqual(defaults.commitWrites, 1, "Ordinary replay cannot earn new acceptance credit")
        }
    }

    func testManualMailboxTwoNewCommitsRecordOneLatestTransferObservation() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        try BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults).setEnabledDurably(false)
        let suite = fixture.base.suite + ".two-commit-observation"
        let defaults = try XCTUnwrap(ForegroundSleepCommitDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        fixture.base.acceptedTransferStore = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.base.acceptedTransferResetEpochURL
        )
        let outbox = fixture.base.outbox
        let bindingID = fixture.identity.opaqueBinding
        let items = try [20.0, 30.0].map { energy in
            try outbox.enqueue(
                JSONEncoder().encode(fixture.base.mixedBatch(workoutEnergy: energy)), receiverIdentity: bindingID
            )
        }
        _ = try await fixture.delivery().deliverPending()
        for item in items {
            let head = try XCTUnwrap(outbox.pendingItem(id: item.id))
            XCTAssertEqual(head.deliveryState?.phase, .providerObserved)
            _ = try fixture.receiveAndAcknowledge(head)
        }
        var deniedCollection: [[String]] = []
        let viewModel = try await fixture.base.makeViewModel(
            mailbox: fixture, eligibleTypeCodes: [],
            readAnchoredStepChanges: { _, _, _ in
                XCTFail("Mailbox fixture must not reach the Steps reader")
                throw CocoaError(.featureUnsupported)
            },
            requestReadAuthorization: { types in
                deniedCollection.append(types)
                throw CocoaError(.featureUnsupported)
            }
        )
        XCTAssertEqual(defaults.commitWrites, 0)
        let receiverCount = fixture.base.receiver.batches.count
        let httpRequests = fixture.base.receiver.httpRequests
        let deliveries = try XCTUnwrap(fixture.locator.lanes[.deliveries])
        let sent = try FileManager.default.contentsOfDirectory(atPath: deliveries.path).sorted()

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        let reopened = try FileOutbox(directory: outbox.directoryURL)
        for item in items {
            XCTAssertEqual(try reopened.deliveryState(for: item.id)?.phase, .committedFinalized)
        }
        XCTAssertTrue(try reopened.pendingItems().isEmpty)
        XCTAssertEqual(defaults.commitWrites, 1, "The VM records the latest observation, not per-item accounting")
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation?.evidenceKind, .mailboxCommit)
        XCTAssertEqual(deniedCollection, [["steps"]], "The successful flush reached the next lane")
        try assertNoMailboxFixtureStepsProgress(fixture)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: deliveries.path).sorted(), sent)
        XCTAssertEqual(fixture.base.receiver.batches.count, receiverCount)
        XCTAssertEqual(fixture.base.receiver.httpRequests, httpRequests)
    }

    private func assertNoMailboxFixtureStepsProgress(_ fixture: NutritionMailboxFixture) throws {
        let cursors = try FileSyncCursorStore(fileURL: fixture.base.cursors.fileURL)
        for kind in [
            AnchoredStepSyncPolicy.bootstrapStartCursorKind,
            StepCountSyncBatchFactory.anchoredCursorKind,
            GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "steps"),
        ] {
            XCTAssertNil(try cursors.cursorValue(
                receiverBindingID: fixture.identity.opaqueBinding,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: kind
            ))
        }
        XCTAssertTrue(fixture.base.reads.isEmpty, "No later quantity lane should run")
    }

    func testManualMailboxScanFailureRequiresSuccessfulFullScanEvenWithEmptyFIFO() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
        try background.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let item = try fixture.base.enqueueMixed()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let pending = try XCTUnwrap(fixture.base.outbox.pendingItem(id: item.id))
        _ = try fixture.receiveAndAcknowledge(pending)
        let viewModel = try await fixture.base.makeViewModel(
            mailbox: fixture, eligibleTypeCodes: [],
            readAnchoredStepChanges: { _, _, _ in throw CocoaError(.featureUnsupported) }
        )
        var rejectFullScan = true
        var fullScanOpened = false
        fixture.ackScanFault = { boundary in
            guard boundary == .laneOpened else { return }
            fullScanOpened = true
            if rejectFullScan { throw MailboxAckScannerError.unsafeMailbox }
        }
        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        await viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertTrue(fullScanOpened)
        let failure = try XCTUnwrap(viewModel.activityMailboxFailureMessage)
        XCTAssertTrue(failure.contains("phase=scan_ack"))
        XCTAssertEqual(try fixture.base.outbox.pendingItems().map(\.id), [item.id])
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)

        fullScanOpened = false
        let runtime = AutomaticSyncRuntime(
            viewModel: viewModel, platform: .init(beginBackgroundOwner: { _ in {} })
        )
        await runtime.runAutomaticSync(reason: .scheduledRefresh)
        XCTAssertFalse(fullScanOpened, "The successful exact-head ACK is not a full scan retry")
        XCTAssertEqual(viewModel.activityMailboxFailureMessage, failure)
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
        let acceptance = try XCTUnwrap(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(acceptance.evidenceKind, .mailboxCommit)

        rejectFullScan = false
        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        await viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertTrue(fullScanOpened, "Retry must execute the full scan even with an empty FIFO")
        XCTAssertNil(viewModel.activityMailboxFailureMessage)
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation, acceptance)
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
    }

    func testMailboxCommitRecordsAcceptedTransferWhenScanCheckpointWriteFails() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let suite = fixture.base.suite + ".checkpoint-fault"
        let defaults = try XCTUnwrap(ScanCheckpointRejectingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let item = try fixture.base.enqueueMixed()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let pending = try XCTUnwrap(fixture.base.outbox.pendingItem(id: item.id))
        XCTAssertEqual(pending.deliveryState?.phase, .providerObserved)
        let vm = try await fixture.base.makeViewModel(
            mailbox: fixture, backgroundSyncStore: background, eligibleTypeCodes: []
        )
        XCTAssertTrue(vm.automaticSyncRuntimeIsReady)
        XCTAssertNil(vm.lastAcceptedTransferObservation)
        let generation = fixture.base.settings.receiverSettingsGenerationToken
        XCTAssertNil(background.mailboxAckScanCheckpoint(receiverGeneration: generation))
        _ = try fixture.receiveAndAcknowledge(pending)
        // Simulate the ACK becoming readable between the exact probe and the bounded scan.
        let skipExactProbe = OSAllocatedUnfairLock(initialState: true)
        fixture.prepareAckCandidate = { url in
            let first = skipExactProbe.withLock { pending in
                defer { pending = false }
                return pending
            }
            if first { return false }
            return MailboxAckScanner.prepareCandidateForBoundedRead(url)
        }
        defaults.rejectScanCheckpoint = true

        vm.runForegroundMailboxReconciliationIfNeeded()
        await vm.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(defaults.rejectedSynchronizations, 1)
        XCTAssertTrue(vm.backgroundSyncStatus.contains("mailbox reconciliation failed"))
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: item.id))
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        let observation = try XCTUnwrap(vm.lastAcceptedTransferObservation)
        XCTAssertEqual(observation.evidenceKind, .mailboxCommit)
        XCTAssertEqual(observation.bindingID, fixture.identity.opaqueBinding)
        let failure = try XCTUnwrap(vm.activityMailboxFailureMessage)
        let rejectedCheckpoint = try XCTUnwrap(defaults.rejectedCheckpoint)
        XCTAssertNil(background.mailboxAckScanCheckpoint(receiverGeneration: generation))

        defaults.rejectScanCheckpoint = false
        vm.schedulePendingBackgroundOutboxUploadsIfAllowed()
        await vm.waitForBootstrapAndForegroundWork()
        XCTAssertEqual(vm.activityMailboxFailureMessage, failure, "Publication is not a checkpoint retry")
        XCTAssertNil(background.mailboxAckScanCheckpoint(receiverGeneration: generation))

        let runtime = AutomaticSyncRuntime(
            viewModel: vm, platform: .init(beginBackgroundOwner: { _ in {} })
        )
        let competingCheckpoint = "synthetic-different-scan-position"
        try background.persistMailboxAckScanCheckpoint(competingCheckpoint, receiverGeneration: generation)
        await runtime.runAutomaticSync(reason: .scheduledRefresh)
        XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), competingCheckpoint)
        XCTAssertEqual(vm.activityMailboxFailureMessage, failure, "A retry must not overwrite a changed scan position")

        defaults.removeObject(forKey: ScanCheckpointRejectingDefaults.checkpointKey)
        await runtime.runAutomaticSync(reason: .scheduledRefresh)
        XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), rejectedCheckpoint)
        XCTAssertNil(vm.activityMailboxFailureMessage)
        XCTAssertEqual(vm.lastAcceptedTransferObservation, observation)
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
    }

    func testMailboxFreshScanCheckpointSupersedesStoredFailedCheckpoint() async throws {
        try await checkStoredMailboxCheckpointRecovery(.freshScan)
    }

    func testMailboxStoredCheckpointRetriesExactValueWithoutNewScanToken() async throws {
        try await checkStoredMailboxCheckpointRecovery(.noNewToken)
    }

    func testMailboxStoredCheckpointRetryLeavesConflictingPositionAlone() async throws {
        try await checkStoredMailboxCheckpointRecovery(.conflictingPosition)
    }

    func testMailboxStoredCheckpointRetryCannotCrossReceiverGeneration() async throws {
        try await checkStoredMailboxCheckpointRecovery(.newGeneration)
    }

    func testManualSyncNowRetriesPendingMailboxCheckpointWithAutomaticSyncOffAndEmptyFIFO() async throws {
        try await checkStoredMailboxCheckpointRecovery(.manualRetry)
    }

    func testManualSyncNowFullScanCannotClearConflictingMailboxCheckpoint() async throws {
        try await checkStoredMailboxCheckpointRecovery(.manualConflict)
    }

    private func checkStoredMailboxCheckpointRecovery(_ recovery: StoredMailboxCheckpointRecovery) async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let suite = fixture.base.suite + ".stored-checkpoint-fault"
        let defaults = try XCTUnwrap(ScanCheckpointRejectingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let background = BackgroundSyncSettingsStore(userDefaults: defaults)
        fixture.base.acceptedTransferStore = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.base.acceptedTransferResetEpochURL
        )
        try background.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: fixture.base.defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let outbox = fixture.base.outbox
        let item = try fixture.base.enqueueMixed()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let head = try XCTUnwrap(outbox.pendingItem(id: item.id))
        XCTAssertEqual(head.deliveryState?.phase, .providerObserved)
        let vm = try await fixture.base.makeViewModel(
            mailbox: fixture, backgroundSyncStore: background, eligibleTypeCodes: []
        )
        let generation = fixture.base.settings.receiverSettingsGenerationToken
        XCTAssertTrue(vm.automaticSyncRuntimeIsReady)
        XCTAssertNil(background.mailboxAckScanCheckpoint(receiverGeneration: generation))
        _ = try fixture.receiveAndAcknowledge(head)
        let skipExactProbe = OSAllocatedUnfairLock(initialState: true)
        fixture.prepareAckCandidate = { url in
            let skip = skipExactProbe.withLock { pending in
                defer { pending = false }
                return pending
            }
            return !skip && MailboxAckScanner.prepareCandidateForBoundedRead(url)
        }
        defaults.rejectScanCheckpoint = true
        defaults.storeRejectedCheckpoint = true

        func reconcile() async {
            vm.noteSceneLeftActive()
            vm.runForegroundMailboxReconciliationIfNeeded()
            await vm.waitForBootstrapAndForegroundWork()
        }
        await reconcile()

        let b = try XCTUnwrap(defaults.rejectedCheckpoint, "The bounded scan must attempt a checkpoint write")
        XCTAssertEqual(defaults.rejectedSynchronizations, 1)
        XCTAssertEqual(defaults.checkpointWrites, [b])
        XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), b)
        let failure = try XCTUnwrap(vm.activityMailboxFailureMessage)
        XCTAssertTrue(vm.backgroundSyncStatus.contains("mailbox reconciliation failed"))
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try outbox.deliveryState(for: item.id)?.phase, .committedFinalized)
        XCTAssertEqual(defaults.commitWrites, 1)
        let observation = try XCTUnwrap(vm.lastAcceptedTransferObservation)
        XCTAssertEqual(observation.evidenceKind, .mailboxCommit)
        let receiverBatchCount = fixture.base.receiver.batches.count
        XCTAssertEqual(receiverBatchCount, 1)
        defaults.rejectScanCheckpoint = false
        fixture.prepareAckCandidate = MailboxAckScanner.prepareCandidateForBoundedRead

        switch recovery {
        case .freshScan:
            let waiting = try fixture.base.enqueueMixed(workoutEnergy: 20)
            _ = try await fixture.delivery().publishPendingFIFOHead()
            XCTAssertEqual(try outbox.pendingItem(id: waiting.id)?.deliveryState?.phase, .providerObserved)
            let lane = try XCTUnwrap(fixture.locator.lanes[.acks])
            for index in 0 ... ProductionMailboxDelivery.backgroundAcknowledgmentFileLimit {
                try Data().write(to: lane.appendingPathComponent("synthetic-window-entry-\(index)"))
            }
            let window = try fixture.components().scanner.candidateWindow(
                maximumEntries: ProductionMailboxDelivery.backgroundAcknowledgmentFileLimit, afterCheckpoint: b
            )
            let c = try XCTUnwrap(window.nextCheckpoint)
            guard c != b else { return XCTFail("Fixture did not produce distinct B and C scan positions") }

            await reconcile()

            XCTAssertEqual(defaults.checkpointWrites, [b, c], "Fresh scan progress must supersede the B retry")
            XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), c)
            XCTAssertNil(vm.activityMailboxFailureMessage)
            XCTAssertEqual(try outbox.pendingItems().map(\.id), [waiting.id])
        case .noNewToken:
            // With no FIFO head the reconciliation returns no new scan token.
            await reconcile()
            XCTAssertEqual(defaults.checkpointWrites, [b, b])
            XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), b)
            XCTAssertNil(vm.activityMailboxFailureMessage)
        case .conflictingPosition:
            let competing = "synthetic-competing-checkpoint"
            try background.persistMailboxAckScanCheckpoint(competing, receiverGeneration: generation)
            await reconcile()
            XCTAssertEqual(defaults.checkpointWrites, [b, competing])
            XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), competing)
            XCTAssertEqual(vm.activityMailboxFailureMessage, failure)
        case .newGeneration:
            let replacement = try fixture.base.settings.invalidateReceiverSettingsGeneration(expectedGeneration: generation)
            XCTAssertNotEqual(replacement, generation)
            XCTAssertEqual(fixture.base.settings.receiverBindingID, fixture.identity.opaqueBinding)
            let failedStatus = vm.backgroundSyncStatus
            await reconcile()
            XCTAssertNotEqual(vm.backgroundSyncStatus, failedStatus, "The new generation must run reconciliation")
            XCTAssertEqual(defaults.checkpointWrites, [b])
            XCTAssertNil(background.mailboxAckScanCheckpoint(receiverGeneration: replacement))
            XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), b)
            XCTAssertNil(vm.activityMailboxFailureMessage)
            XCTAssertNil(vm.lastAcceptedTransferObservation)
        case .manualRetry, .manualConflict:
            let runtime = AutomaticSyncRuntime(
                viewModel: vm, platform: .init(beginBackgroundOwner: { _ in {} })
            )
            vm.installAutomaticSyncRuntime(runtime)
            vm.requestBackgroundSyncEnabled(false)
            await vm.waitForAutomaticSyncDisableCleanup()
            XCTAssertFalse(background.isEnabled)
            XCTAssertFalse(vm.automaticSyncToggleIsOn)
            XCTAssertFalse(vm.automaticSyncRuntimeIsReady)
            XCTAssertEqual(vm.pendingOutboxCount, 0)
            XCTAssertEqual(vm.activityMailboxFailureMessage, failure)

            let competing = "synthetic-competing-manual-checkpoint"
            if recovery == .manualConflict {
                try background.persistMailboxAckScanCheckpoint(competing, receiverGeneration: generation)
            }
            // No provider ACK is needed for a local checkpoint retry.
            let lane = try XCTUnwrap(fixture.locator.lanes[.acks])
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: lane.path).isEmpty)
            var fullScans = 0
            fixture.ackScanFault = { boundary in
                if boundary == .laneOpened { fullScans += 1 }
            }

            await vm.syncAllNow()

            XCTAssertEqual(fullScans, 1, "Manual Sync Now must reconcile even without a FIFO head")
            XCTAssertEqual(fixture.base.settings.receiverBindingID, observation.bindingID)
            XCTAssertEqual(fixture.base.settings.receiverSettingsGenerationToken, generation)
            XCTAssertTrue(try outbox.pendingItems().isEmpty)
            if recovery == .manualConflict {
                XCTAssertEqual(defaults.checkpointWrites, [b, competing])
                XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), competing)
                XCTAssertEqual(vm.activityMailboxFailureMessage, failure, "An unrelated scan cannot earn checkpoint credit")
            } else {
                XCTAssertEqual(defaults.checkpointWrites, [b, b])
                XCTAssertEqual(background.mailboxAckScanCheckpoint(receiverGeneration: generation), b)
                XCTAssertNil(vm.activityMailboxFailureMessage)
            }
        }
        if recovery != .newGeneration {
            XCTAssertEqual(vm.lastAcceptedTransferObservation, observation)
        }
        XCTAssertEqual(defaults.commitWrites, 1, "Checkpoint activity is not a new accepted transfer")
        XCTAssertEqual(fixture.base.receiver.batches.count, receiverBatchCount)
    }

    func testManualMailboxObservesVerifiedHeadDespiteLaterFullScanFailure() async throws {
        try await checkManualMailboxAcceptanceAcrossFullScan(.verifiedHeadScanFailure)
    }

    func testManualMailboxDoesNotAttributeVerifiedHeadAfterGenerationChangesDuringFullScan() async throws {
        try await checkManualMailboxAcceptanceAcrossFullScan(.verifiedHeadConnectionChange)
    }

    func testManualMailboxFullScanFailureWithoutVerifiedHeadDoesNotRecordAcceptance() async throws {
        try await checkManualMailboxAcceptanceAcrossFullScan(.unverifiedHeadScanFailure)
    }

    func testManualMailboxObservesVerifiedHeadExactlyOnceAfterSuccessfulFullScan() async throws {
        try await checkManualMailboxAcceptanceAcrossFullScan(.verifiedHeadScanSuccess)
    }

    func testManualMailboxObservesVerifiedHeadDespiteLaterACKHydrationFailure() async throws {
        try await checkManualMailboxAcceptanceAcrossFullScan(.verifiedHeadHydrationFailure)
    }

    func testManualMailboxDoesNotAttributeRetiredHeadAfterGenerationChangesBeforeACKHydration() async throws {
        try await checkManualMailboxAcceptanceAcrossFullScan(.verifiedHeadStaleBeforeHydration)
    }

    func testManualMailboxACKHydrationFailureWithoutVerifiedHeadDoesNotRecordAcceptance() async throws {
        try await checkManualMailboxAcceptanceAcrossFullScan(.unverifiedHeadHydrationFailure)
    }

    private func checkManualMailboxAcceptanceAcrossFullScan(_ scenario: ManualMailboxFullScan) async throws {
        let files = MailboxEnvelopeRemovalFailure()
        let fixture = try NutritionMailboxFixture(nativePairing: true, outboxFileManager: files)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let suite = fixture.base.suite + ".full-scan-observation"
        let defaults = try XCTUnwrap(ForegroundSleepCommitDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let observations = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.base.acceptedTransferResetEpochURL
        )
        fixture.base.acceptedTransferStore = observations
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.base.defaults)
        try background.setEnabledDurably(false)
        let outbox = fixture.base.outbox
        let settings = fixture.base.settings
        let generation = settings.receiverSettingsGenerationToken
        let bindingID = fixture.identity.opaqueBinding
        let item = try fixture.base.enqueueMixed()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let head = try XCTUnwrap(outbox.pendingItem(id: item.id))
        XCTAssertEqual(head.deliveryState?.phase, .providerObserved)
        let receipt: OutboxDeliveryCommittedReceiptV1?
        if scenario == .unverifiedHeadScanFailure || scenario == .unverifiedHeadHydrationFailure {
            receipt = nil
        } else {
            _ = try fixture.receiveAndAcknowledge(head)
            let components = fixture.components()
            let event = try XCTUnwrap(components.scanner.scan().events.first)
            let ownership = try XCTUnwrap(head.deliveryState?.ownership)
            let coordinator = OutboxDeliveryCoordinator(
                outbox: outbox, transport: components.transport, scanner: components.scanner,
                ownership: ownership,
                finalizer: OutboxDeliveryCursorFinalizer(outbox: outbox, cursorStore: fixture.base.cursors)
            )
            XCTAssertEqual(event.classification, .committed)
            XCTAssertEqual(try coordinator.consume(event, itemID: item.id), .ackVerified)
            let verified = try XCTUnwrap(outbox.deliveryState(for: item.id))
            XCTAssertEqual(verified.phase, .ackVerified)
            XCTAssertEqual(verified.ownership?.receiverBindingID, bindingID)
            XCTAssertEqual(verified.ownership?.receiverGeneration, generation)
            receipt = try XCTUnwrap(verified.committedReceipt)
            // Start the observed run with only the authenticated local state.
            // Avoid a replay of the provider ACK accounting for any observation.
            let ackLane = try XCTUnwrap(fixture.locator.lanes[.acks])
            let ackName = try MailboxLayoutV1.finalFileName(
                identifier: event.envelopeID.hexV1, kind: .acknowledgment
            )
            try FileManager.default.removeItem(at: ackLane.appendingPathComponent(ackName))
        }
        let vm = try await fixture.base.makeViewModel(
            mailbox: fixture, eligibleTypeCodes: [],
            readAnchoredStepChanges: { _, _, _ in throw CocoaError(.featureUnsupported) }
        )
        let runtime = AutomaticSyncRuntime(
            viewModel: vm, platform: .init(beginBackgroundOwner: { _ in {} })
        )
        vm.installAutomaticSyncRuntime(runtime)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        XCTAssertEqual(defaults.commitWrites, 0)

        var fullScans = 0
        var deliberatelyThrown = false
        var replacementGeneration: String?
        let failsHydration: Bool
        switch scenario {
        case .verifiedHeadHydrationFailure, .verifiedHeadStaleBeforeHydration, .unverifiedHeadHydrationFailure:
            failsHydration = true
            let ackLane = try XCTUnwrap(fixture.locator.lanes[.acks])
            if scenario == .unverifiedHeadHydrationFailure {
                try FileManager.default.removeItem(at: ackLane)
            } else {
                let envelope = try XCTUnwrap(head.mailboxBinding).envelopeFilename
                files.afterRemoval(of: outbox.directoryURL.appendingPathComponent(envelope)) {
                    // Retire the actual authenticated head before breaking the provider lane.
                    try FileManager.default.removeItem(at: ackLane)
                    if scenario == .verifiedHeadStaleBeforeHydration {
                        replacementGeneration = try settings.invalidateReceiverSettingsGeneration(
                            expectedGeneration: generation
                        )
                    }
                }
            }
        default:
            failsHydration = false
        }
        fixture.ackScanFault = { boundary in
            guard boundary == .laneOpened else { return }
            fullScans += 1
            if let receipt {
                let committed = try XCTUnwrap(outbox.deliveryState(for: item.id))
                XCTAssertEqual(committed.phase, .committedFinalized)
                XCTAssertEqual(committed.committedReceipt, receipt)
                XCTAssertTrue(try outbox.pendingItems().isEmpty)
                XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
            }
            if scenario == .verifiedHeadConnectionChange {
                replacementGeneration = try settings.invalidateReceiverSettingsGeneration(expectedGeneration: generation)
            }
            if scenario != .verifiedHeadScanSuccess {
                deliberatelyThrown = true
                throw MailboxAckScannerError.unsafeMailbox
            }
        }
        defer { fixture.ackScanFault = { _ in } }

        await vm.syncAllNow()

        XCTAssertEqual(fullScans, failsHydration ? 0 : 1)
        XCTAssertEqual(deliberatelyThrown, !failsHydration && scenario != .verifiedHeadScanSuccess)
        if failsHydration, let receipt {
            let committed = try XCTUnwrap(outbox.deliveryState(for: item.id))
            XCTAssertEqual(committed.phase, .committedFinalized)
            XCTAssertEqual(committed.committedReceipt, receipt)
            XCTAssertTrue(try outbox.pendingItems().isEmpty)
            XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        }
        let failurePhase = failsHydration ? "phase=hydrate_ack" : "phase=scan_ack"
        switch scenario {
        case .verifiedHeadScanFailure, .verifiedHeadScanSuccess, .verifiedHeadHydrationFailure:
            if scenario != .verifiedHeadScanSuccess {
                XCTAssertTrue(vm.statusIsError)
                XCTAssertTrue(vm.activityMailboxFailureMessage?.contains(failurePhase) == true)
            } else {
                XCTAssertNil(vm.activityMailboxFailureMessage)
            }
            XCTAssertEqual(defaults.commitWrites, 1)
            let observation = try XCTUnwrap(vm.lastAcceptedTransferObservation)
            XCTAssertEqual(observation.evidenceKind, .mailboxCommit)
            XCTAssertEqual(observation.bindingID, bindingID)
            XCTAssertEqual(observation.generation, generation)
            XCTAssertEqual(observations.load(bindingID: bindingID, generation: generation), observation)
        case .verifiedHeadConnectionChange, .verifiedHeadStaleBeforeHydration:
            let replacement = try XCTUnwrap(replacementGeneration)
            XCTAssertNotEqual(replacement, generation)
            XCTAssertEqual(settings.receiverBindingID, bindingID)
            XCTAssertEqual(settings.receiverSettingsGenerationToken, replacement)
            XCTAssertEqual(defaults.commitWrites, 0)
            XCTAssertNil(observations.load(bindingID: bindingID, generation: generation))
            XCTAssertNil(observations.load(bindingID: bindingID, generation: replacement))
            XCTAssertNil(vm.lastAcceptedTransferObservation)
        case .unverifiedHeadScanFailure, .unverifiedHeadHydrationFailure:
            XCTAssertTrue(vm.activityMailboxFailureMessage?.contains(failurePhase) == true)
            XCTAssertEqual(try outbox.pendingItem(id: item.id)?.deliveryState?.phase, .providerObserved)
            XCTAssertNil(try fixture.base.cursor("dietary_protein"))
            XCTAssertEqual(defaults.commitWrites, 0)
            XCTAssertNil(vm.lastAcceptedTransferObservation)
        }
    }

    func testBoundedACKRejectsGenerationChangeDuringExactScan() async throws {
        let fixture = try NutritionMailboxFixture()
        defer { fixture.base.cleanup() }
        let item = try fixture.base.enqueueMixed()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let head = try XCTUnwrap(fixture.base.outbox.pendingItem(id: item.id))
        XCTAssertEqual(head.deliveryState?.phase, .providerObserved)
        _ = try fixture.receiveAndAcknowledge(head)
        let settings = fixture.base.settings
        let generation = settings.receiverSettingsGenerationToken
        fixture.ackScanFault = { boundary in
            if boundary == .beforeCandidateOpen {
                _ = try settings.invalidateReceiverSettingsGeneration(expectedGeneration: generation)
            }
        }
        do {
            _ = try await fixture.delivery().reconcilePendingFIFOHeadAcknowledgment(
                afterAcknowledgmentCheckpoint: nil, onNewFinalization: { _ in XCTFail("Stale ACK finalized") }
            )
            XCTFail("Expected the superseded ACK scan to cancel")
        } catch is CancellationError {}
        XCTAssertNotEqual(settings.receiverSettingsGenerationToken, generation)
        XCTAssertEqual(settings.receiverBindingID, fixture.identity.opaqueBinding)
        XCTAssertEqual(try fixture.base.outbox.pendingItem(id: item.id), head)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
    }

    func testManualSyncContinuesToQuantitiesWhileAcceptedSleepIsHeld() async throws {
        for evidence in ManualSleepHoldEvidence.allCases {
            try await checkManualSyncWithSleepHold(evidence: evidence)
        }
    }

    private func checkManualSyncWithSleepHold(evidence: ManualSleepHoldEvidence) async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.defaults)
        try background.setEnabledDurably(false)
        try background.markPendingObserverTypeCodes(["sleep_analysis"])
        let generations = try background.loadPendingObserverTypeCodeGenerations()
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let bytes = try HealthBridgeBatchEncoder().encode(ConnectionTestBatchFactory.make(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let item = try XCTUnwrap(fixture.outbox.enqueueSequence(
            [bytes], receiverIdentity: binding, pendingGenerationRetirements: generations
        ).first)
        XCTAssertNotNil(try fixture.outbox.recordDirectUploadAccepted(itemID: item.id, receiverIdentity: binding))
        let journal = fixture.root.appendingPathComponent("sleep.json.pending")
        let damaged = Data("{".utf8)
        let sleepStore = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        switch evidence {
        case .missing:
            break
        case .malformed:
            try damaged.write(to: journal, options: .atomic)
        case .readableWithoutCommittedProof:
            let generation = fixture.settings.receiverSettingsGenerationToken
            let pendingManifest = SleepSyncBatchFactory.makeManifestReservation(
                receiverSettingsGeneration: generation, historyDepth: .lastDays(30),
                historyStartDate: nil, baselineResetEpoch: 2
            )
            try sleepStore.savePendingTransition(SleepSyncPendingTransition(
                payload: bytes, manifest: pendingManifest, receiverBindingID: binding,
                connectionGeneration: generation, outboxItemID: item.id
            ))
            try sleepStore.saveManifest(SleepSyncBatchFactory.makeManifestReservation(
                receiverSettingsGeneration: generation, historyDepth: .lastDays(30),
                historyStartDate: nil, baselineResetEpoch: 1
            ))
        case .readableWithMalformedPayload:
            let generation = fixture.settings.receiverSettingsGenerationToken
            let pendingManifest = SleepSyncBatchFactory.makeManifestReservation(
                receiverSettingsGeneration: generation, historyDepth: .lastDays(30),
                historyStartDate: nil, baselineResetEpoch: 2
            )
            try sleepStore.savePendingTransition(SleepSyncPendingTransition(
                payload: damaged, manifest: pendingManifest, receiverBindingID: binding,
                connectionGeneration: generation, outboxItemID: item.id
            ))
            try sleepStore.saveManifest(SleepSyncBatchFactory.makeManifestReservation(
                receiverSettingsGeneration: generation, historyDepth: .lastDays(30),
                historyStartDate: nil, baselineResetEpoch: 1
            ))
        }
        let vm = try await fixture.makeViewModel(
            readAnchoredStepChanges: { _, start, now in
                HealthKitAnchoredStepChanges(stepSamples: [], deletedStepSamples: [], anchorCursorValue: fixture.anchor,
                                            windowStart: start ?? now, windowEnd: now)
            },
            readAnchoredWorkoutChanges: { _, start, now in
                HealthKitAnchoredWorkoutChanges(workouts: [], deletedWorkouts: [], anchorCursorValue: fixture.anchor,
                                                windowStart: start ?? now, windowEnd: now)
            },
            readWorkoutHistory: { _, _ in [] },
            readAnchoredSleepChanges: { _, _, _ in
                XCTFail("A held Sleep lane must not read HealthKit")
                throw CocoaError(.featureUnsupported)
            },
            requestReadAuthorization: { XCTAssertNotEqual($0, ["sleep_analysis"]) },
            reopenStorage: true
        )
        await vm.performManualSyncOpportunity { false }
        XCTAssertTrue(fixture.receiver.records.contains { $0.typeCode == "weight" })
        XCTAssertFalse(fixture.receiver.batches.contains(try JSONDecoder().decode(HealthBridgeBatchV1.self, from: bytes)))
        XCTAssertTrue(try fixture.outbox.hasUncheckedDirectAcknowledgment(itemID: item.id, receiverBindingID: binding))
        if evidence == .malformed { XCTAssertEqual(try Data(contentsOf: journal), damaged) }
        if evidence == .readableWithoutCommittedProof || evidence == .readableWithMalformedPayload {
            XCTAssertNotNil(try sleepStore.loadPendingTransition())
            XCTAssertNotEqual(try sleepStore.loadPendingTransition()?.manifest, try sleepStore.loadManifest())
        }
        XCTAssertEqual(vm.statusMessage, try XCTUnwrap(vm.acceptedFinalizationRecoveryMessage))
        XCTAssertEqual(try fixture.outbox.acceptedFinalizationHold()?.reason, .proofMissing)
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), generations)
    }

    func testCurrentSleepJournalWithoutCommittedProofDefersManualSleep() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.defaults)
        try background.setEnabledDurably(false)
        try background.markPendingObserverTypeCodes(["sleep_analysis"])
        let debt = try background.loadPendingObserverTypeCodeGenerations()
        let vm = try await fixture.makeViewModel(readAnchoredSleepChanges: { _, _, now in
            HealthKitAnchoredSleepChanges(addedSamples: [], deletedSamples: [],
                                          anchorCursorValue: fixture.anchor, receivedAt: now)
        })
        fixture.receiver.status = 503
        _ = await vm.syncRecentSleepSessions(pendingGenerationRetirements: debt)
        let store = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        let pending = try XCTUnwrap(store.loadPendingTransition())
        let itemID = try XCTUnwrap(pending.outboxItemID)
        let manifest = try store.loadManifest()
        XCTAssertNotEqual(manifest, pending.manifest)
        XCTAssertNotNil(try fixture.outbox.recordDirectUploadAccepted(
            itemID: itemID, receiverIdentity: pending.receiverBindingID
        ))
        let requests = fixture.receiver.batches
        _ = await vm.syncRecentSleepSessions(deferMissingProof: true)
        XCTAssertFalse(vm.statusIsError)
        XCTAssertEqual(vm.statusMessage, try XCTUnwrap(vm.acceptedFinalizationRecoveryMessage))
        XCTAssertEqual(fixture.receiver.batches, requests)
        XCTAssertEqual(try store.loadPendingTransition(), pending)
        XCTAssertEqual(try store.loadManifest(), manifest)
        XCTAssertTrue(try fixture.outbox.hasUncheckedDirectAcknowledgment(
            itemID: itemID, receiverBindingID: pending.receiverBindingID
        ))
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), debt)
    }

    func testRetainedBackgroundCompletionOwnershipBlocksSleepReenqueue() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        var retainedItemID: String?
        var retainedGeneration: String?
        var retainedBindingID: String?
        let vm = try await fixture.makeViewModel(
            readAnchoredSleepChanges: { _, _, now in
                HealthKitAnchoredSleepChanges(
                    addedSamples: [], deletedSamples: [],
                    anchorCursorValue: fixture.anchor, receivedAt: now
                )
            },
            retainedBackgroundUploadOwnership: { itemID, generation, bindingID in
                retainedItemID = itemID
                retainedGeneration = generation
                retainedBindingID = bindingID
                return true
            }
        )
        fixture.receiver.status = 503
        let initialSucceeded = await vm.syncRecentSleepSessions()
        XCTAssertFalse(initialSucceeded)
        let store = try FileSleepSyncManifestStore(
            fileURL: fixture.root.appendingPathComponent("sleep.json")
        )
        let pending = try XCTUnwrap(store.loadPendingTransition())
        let itemID = try XCTUnwrap(pending.outboxItemID)
        let item = try XCTUnwrap(fixture.outbox.pendingItem(id: itemID))
        try fixture.outbox.markUploaded(item)
        let requests = fixture.receiver.batches

        let retrySucceeded = await vm.syncRecentSleepSessions()
        XCTAssertFalse(retrySucceeded)

        XCTAssertEqual(retainedItemID, itemID)
        XCTAssertEqual(retainedGeneration, pending.connectionGeneration)
        XCTAssertEqual(retainedBindingID, pending.receiverBindingID)
        XCTAssertEqual(fixture.receiver.batches, requests)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try store.loadPendingTransition(), pending)
        XCTAssertTrue(vm.statusIsError)
        XCTAssertTrue(vm.statusMessage.contains("Sleep upload is still owned"), vm.statusMessage)

        let automaticSucceeded = await vm.syncRecentSleepSessions(executionMode: .automatic)
        XCTAssertFalse(automaticSucceeded)
        XCTAssertEqual(fixture.receiver.batches, requests)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try store.loadPendingTransition(), pending)
    }

    func testForegroundSleepResponseAfterAutomaticDisableCommitsBeforeRetry() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        try BackgroundSyncSettingsStore(userDefaults: fixture.defaults).setEnabledDurably(true)
        let vm = try await fixture.makeViewModel(readAnchoredSleepChanges: { anchor, _, now in
            if let anchor {
                XCTAssertEqual(anchor, fixture.anchor)
                throw CocoaError(.featureUnsupported)
            }
            return HealthKitAnchoredSleepChanges(addedSamples: [], deletedSamples: [],
                                                 anchorCursorValue: fixture.anchor, receivedAt: now)
        })
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        fixture.receiver.responseProbe = probe
        let sync = Task { @MainActor in await vm.syncRecentSleepSessions() }
        await fulfillment(of: [probe.entered], timeout: 5)
        let store = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        let pending = try XCTUnwrap(store.loadPendingTransition())
        vm.requestBackgroundSyncEnabled(false)
        probe.release()
        _ = await sync.value
        await vm.waitForAutomaticSyncDisableCleanup()
        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertEqual(try store.loadManifest(), pending.manifest)
        XCTAssertNil(try store.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertNil(try fixture.outbox.directFinalizationRecordReady(receiverIdentity: pending.receiverBindingID))
        XCTAssertTrue(pending.manifest.baselineResetPending == true)
        XCTAssertEqual(
            fixture.receiver.batches,
            [try JSONDecoder().decode(HealthBridgeBatchV1.self, from: pending.payload)]
        )
    }

    func testForegroundDirectSleepRejectsSiblingOnlyAcceptance() async throws {
        try await checkForegroundDirectSleepCompletion(.siblingOnly)
    }

    func testForegroundDirectSleepRejectsTrackedACKWithPendingJournal() async throws {
        try await checkForegroundDirectSleepCompletion(.pendingJournal)
    }

    func testForegroundDirectSleepRejectsTrackedACKWithDifferentManifest() async throws {
        try await checkForegroundDirectSleepCompletion(.differentManifest)
    }

    func testForegroundDirectSleepCompletesWithTrackedACKAndFinalizedManifest() async throws {
        try await checkForegroundDirectSleepCompletion(.matching)
    }

    private func checkForegroundDirectSleepCompletion(_ input: ForegroundDirectSleepCompletionInput) async throws {
        let files = ForegroundDirectSleepCompletionFiles()
        let fixture = try NutritionFixture(outboxFileManager: files)
        defer { fixture.cleanup() }
        let anchor = fixture.anchor
        let viewModel = try await fixture.makeViewModel(readAnchoredSleepChanges: { _, _, now in
            HealthKitAnchoredSleepChanges(
                addedSamples: [HealthKitSleepChildSample(
                    uuid: UUID(), stage: "core", start: now.addingTimeInterval(-3600), end: now
                )],
                deletedSamples: [], anchorCursorValue: anchor, receivedAt: now
            )
        })
        fixture.receiver.status = 503
        let initiallyCompleted = await viewModel.syncRecentSleepSessions(executionMode: .foreground)
        XCTAssertFalse(initiallyCompleted)
        let firstRequests = fixture.receiver.batches.count
        XCTAssertEqual(firstRequests, 1)

        let store = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        let pending = try XCTUnwrap(store.loadPendingTransition())
        let trackedID = try XCTUnwrap(pending.outboxItemID)
        let tracked = try XCTUnwrap(fixture.outbox.pendingItem(id: trackedID))
        let trackedBatch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: pending.payload)
        XCTAssertFalse(trackedBatch.sleepSessions.isEmpty)
        let expectedPOST: HealthBridgeBatchV1
        let expectedManifest: SleepSyncManifest
        let expectedJournal: SleepSyncPendingTransition?
        let manifest = pending.manifest

        switch input {
        case .siblingOnly:
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let end = start.addingTimeInterval(60)
            let batch = StepCountSyncBatchFactory.makeAnchoredStepBatch(
                changes: HealthKitAnchoredStepChanges(
                    stepSamples: [HealthKitStepSampleSummary(uuid: UUID(), start: start, end: end, count: 17)],
                    deletedStepSamples: [], anchorCursorValue: anchor, windowStart: start, windowEnd: end
                ),
                generatedAt: end
            )
            let sibling = try fixture.outbox.enqueue(
                HealthBridgeBatchEncoder().encode(batch), receiverIdentity: pending.receiverBindingID
            )
            XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [trackedID, sibling.id])
            files.afterNutritionPreparation = (fixture.outbox.directoryURL, {
                // Model a tracked item disappearing after the caller's FIFO gate,
                // with matching disk state but no acceptance of that item in this flush.
                try FileManager.default.removeItem(at: tracked.fileURL)
                try store.saveManifest(manifest)
                try store.clearPendingTransition(id: pending.id)
            })
            fixture.outbox.observeNutritionCodec = { files.armNutritionBoundary() }
            expectedPOST = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: sibling.fileURL))
            expectedManifest = manifest
            expectedJournal = nil
        case .pendingJournal, .differentManifest, .matching:
            let differentManifest = SleepSyncManifest(
                receiverSettingsGeneration: manifest.receiverSettingsGeneration,
                historyDepth: manifest.historyDepth, historyStartDate: manifest.historyStartDate,
                sourceKey: manifest.sourceKey, baselineResetEpoch: manifest.baselineResetEpoch,
                identityNamespace: manifest.identityNamespace, nextRevisionSequence: manifest.nextRevisionSequence,
                anchorCursorValue: try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 41)),
                activeChildSamples: manifest.activeChildSamples, publishedSessions: manifest.publishedSessions,
                baselineResetPending: manifest.baselineResetPending
            )
            XCTAssertNotEqual(differentManifest, manifest)
            files.afterPayloadRemoval = (tracked.fileURL, {
                // Observe real Direct finalization before changing one durable input.
                XCTAssertEqual(try store.loadManifest(), manifest)
                XCTAssertNil(try store.loadPendingTransition())
                switch input {
                case .pendingJournal: try store.savePendingTransition(pending)
                case .differentManifest: try store.saveManifest(differentManifest)
                case .matching, .siblingOnly: break
                }
            })
            expectedPOST = trackedBatch
            expectedManifest = input == .differentManifest ? differentManifest : manifest
            expectedJournal = input == .pendingJournal ? pending : nil
        }

        fixture.receiver.status = 202
        let completed = await viewModel.syncRecentSleepSessions(executionMode: .foreground)

        XCTAssertTrue(files.presented, "Did not reach the Direct completion fixture boundary")
        XCTAssertEqual(Array(fixture.receiver.batches.dropFirst(firstRequests)), [expectedPOST])
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try store.loadManifest(), expectedManifest)
        XCTAssertEqual(try store.loadPendingTransition(), expectedJournal)
        XCTAssertEqual(completed, input == .matching)
        XCTAssertEqual(viewModel.statusIsError, input != .matching)
    }

    func testForegroundMailboxSleepRequiresProofForTheTrackedItem() async throws {
        for input in ForegroundSleepCompletionInput.allCases where input != .pendingJournal {
            try await checkForegroundMailboxSleepCompletion(input)
        }
    }

    func testForegroundMailboxSleepRejectsMatchingProofWithPendingJournal() async throws {
        try await checkForegroundMailboxSleepCompletion(.pendingJournal)
    }

    private func checkForegroundMailboxSleepCompletion(_ input: ForegroundSleepCompletionInput) async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        let probe = ForegroundSleepCompletionFiles(directory: fixture.base.outbox.directoryURL)
        let suite = fixture.base.suite + ".foreground-sleep-completion"
        let defaults = try XCTUnwrap(ForegroundSleepCommitDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        fixture.base.acceptedTransferStore = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.base.acceptedTransferResetEpochURL
        )
        let anchor = fixture.base.anchor
        let viewModel = try await fixture.base.makeViewModel(
            mailbox: fixture,
            readAnchoredSleepChanges: { _, _, now in
                HealthKitAnchoredSleepChanges(
                    addedSamples: [HealthKitSleepChildSample(
                        uuid: UUID(), stage: "core", start: now.addingTimeInterval(-3600), end: now
                    )],
                    deletedSamples: [], anchorCursorValue: anchor, receivedAt: now
                )
            },
            reopenStorage: true,
            outboxFileManager: probe
        )
        _ = await viewModel.syncRecentSleepSessions(executionMode: .foreground)
        let store = try FileSleepSyncManifestStore(fileURL: fixture.base.root.appendingPathComponent("sleep.json"))
        let pending = try XCTUnwrap(store.loadPendingTransition(), input.rawValue)
        let itemID = try XCTUnwrap(pending.outboxItemID, input.rawValue)
        let item = try XCTUnwrap(fixture.base.outbox.pendingItem(id: itemID), input.rawValue)
        let binding = try XCTUnwrap(item.mailboxBinding, input.rawValue)
        XCTAssertEqual(item.deliveryState?.phase, .providerObserved, input.rawValue)
        let envelopeURL = probe.directory.appendingPathComponent(binding.envelopeFilename)
        let payload = try Data(contentsOf: item.fileURL)
        let envelope = try Data(contentsOf: envelopeURL)
        _ = try fixture.receiveAndAcknowledge(item)

        defaults.afterCommit = {
            probe.afterForegroundFIFORefresh {
                let state = try XCTUnwrap(fixture.base.outbox.deliveryState(for: itemID), input.rawValue)
                XCTAssertEqual(state.phase, .committedFinalized, input.rawValue)
                XCTAssertEqual(state.ownership?.receiverGeneration, pending.connectionGeneration, input.rawValue)
                XCTAssertEqual(state.ownership?.receiverBindingID, pending.receiverBindingID, input.rawValue)
                XCTAssertEqual(state.ownership?.resetEpoch, pending.manifest.baselineResetEpoch, input.rawValue)
                XCTAssertEqual(try store.loadManifest(), pending.manifest, input.rawValue)
                XCTAssertNil(try store.loadPendingTransition(), input.rawValue)
                try probe.present(
                    input, pending: pending, store: store,
                    artifacts: (payload, envelopeURL, envelope)
                )
                // Reject invalid fixture bytes here rather than counting a
                // FileOutbox reconciliation error as proof-gate rejection.
                let visibleState = try fixture.base.outbox.deliveryState(for: itemID)
                if input == .noFinalizedProof { XCTAssertNil(visibleState) }
            }
        }
        let completed = await viewModel.syncRecentSleepSessions(executionMode: .foreground)

        XCTAssertTrue(probe.presented, "Did not reach the post-FIFO proof window: \(input.rawValue)")
        if input == .ackVerified {
            XCTAssertTrue(probe.readVerifiedArtifacts, "The real lookup did not read the ACK-verified entry")
        }
        XCTAssertEqual(completed, input == .matching, input.rawValue)
        XCTAssertEqual(viewModel.statusIsError, input != .matching, input.rawValue)
    }

    func testUnavailableObservationWriteCannotChangeDirectAcceptance() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let defaults = try XCTUnwrap(UnavailableObservationDefaults(suiteName: fixture.suite + ".unavailable"))
        fixture.acceptedTransferStore = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.acceptedTransferResetEpochURL
        )
        let viewModel = try await fixture.makeViewModel()

        await viewModel.syncSupportedQuantityMetrics()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertEqual(Set(fixture.receiver.records.map(\.typeCode)), ["weight", "dietary_protein"])
        XCTAssertEqual(try fixture.cursor("weight"), fixture.anchor)
        XCTAssertEqual(try fixture.cursor("dietary_protein"), fixture.anchor)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(defaults.rejectedWrites, fixture.receiver.batches.count)
        XCTAssertGreaterThan(defaults.rejectedWrites, 0)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
        let reopened = try await fixture.makeViewModel()
        XCTAssertNil(reopened.lastAcceptedTransferObservation)
    }

    func testUnavailableObservationWriteCannotChangeMailboxFinalization() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        try fixture.writeCapabilities()
        _ = try fixture.base.enqueueMixed()
        let defaults = try XCTUnwrap(UnavailableObservationDefaults(suiteName: fixture.base.suite + ".unavailable"))
        fixture.base.acceptedTransferStore = LastAcceptedTransferObservationStore(
            userDefaults: defaults, resetEpochURL: fixture.base.acceptedTransferResetEpochURL
        )
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)
        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        let pending = try XCTUnwrap(fixture.base.outbox.pendingItems().first {
            $0.deliveryState?.phase == .providerObserved
        })
        XCTAssertEqual(defaults.rejectedWrites, 0)
        XCTAssertNil(try fixture.base.cursor("dietary_protein"))
        _ = try fixture.receiveAndAcknowledge(pending)

        await viewModel.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertEqual(defaults.rejectedWrites, 1)
        XCTAssertEqual(Set(fixture.base.receiver.records.map(\.typeCode)), ["weight", "dietary_protein"])
        XCTAssertNil(try fixture.base.outbox.pendingItem(id: pending.id))
        XCTAssertTrue(try fixture.base.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.base.cursor("dietary_protein"), fixture.base.anchor)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testLateDirectResponseCannotReplaceCurrentConnectionObservation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        _ = try fixture.enqueueMixed()
        let viewModel = try await fixture.makeViewModel()
        let oldBinding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let probe = NutritionCodecProbe(blocking: true)
        defer { probe.release() }
        fixture.receiver.responseProbe = probe
        let sync = Task { @MainActor in
            await viewModel.performManualSyncOpportunity(processPendingTypes: { false })
        }
        await fulfillment(of: [probe.entered], timeout: 5)
        let pending = try fixture.outbox.pendingItems()
        XCTAssertFalse(pending.isEmpty)
        try fixture.settings.save(
            receiverURLString: "http://127.0.0.1:8766/v1/batches", bearerToken: "synthetic-replacement"
        )
        let current = LastAcceptedTransferObservation(
            bindingID: try XCTUnwrap(fixture.settings.receiverBindingID),
            generation: fixture.settings.receiverSettingsGenerationToken,
            observedAt: Date(timeIntervalSinceReferenceDate: 345_678), evidenceKind: .directResponse
        )
        fixture.acceptedTransferStore.record(current)
        probe.release()
        await sync.value

        XCTAssertFalse(probe.watchdogExpired)
        XCTAssertFalse(fixture.receiver.records.isEmpty)
        XCTAssertEqual(try fixture.outbox.pendingItems(), pending)
        XCTAssertNil(try fixture.cursors.cursorValue(
            receiverBindingID: oldBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "dietary_protein")
        ))
        XCTAssertEqual(viewModel.lastAcceptedTransferObservation, current)
    }
}

private enum MailboxCommitCancellation: Equatable {
    case beforeCommit, committedManual, committedBounded, cancelledWithCleanupError, replacedAfterCommit
}

private enum ManualSleepHoldEvidence: CaseIterable {
    case missing, malformed, readableWithoutCommittedProof, readableWithMalformedPayload
}

private enum ForegroundDirectSleepCompletionInput: Equatable {
    case siblingOnly, pendingJournal, differentManifest, matching
}

private final class ForegroundDirectSleepCompletionFiles: FileManager, @unchecked Sendable {
    private let nutritionPrepared = OSAllocatedUnfairLock(initialState: false)
    var afterNutritionPreparation: (directory: URL, apply: () throws -> Void)?
    var afterPayloadRemoval: (file: URL, apply: () throws -> Void)?
    private(set) var presented = false

    func armNutritionBoundary() {
        nutritionPrepared.withLock { $0 = true }
    }

    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        // The codec's revision check uses FileManager.default. The next
        // injected listing is the Direct finalizer's FIFO reconciliation.
        if let boundary = afterNutritionPreparation, url == boundary.directory,
           nutritionPrepared.withLock({ $0 }) {
            afterNutritionPreparation = nil
            try boundary.apply()
            presented = true
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    override func removeItem(at url: URL) throws {
        try super.removeItem(at: url)
        if let boundary = afterPayloadRemoval, url == boundary.file {
            afterPayloadRemoval = nil
            try boundary.apply()
            presented = true
        }
    }
}

private enum ForegroundSleepCompletionInput: String, CaseIterable {
    case matching, missingTrackedItem, noFinalizedProof, ackVerified, wrongGeneration, wrongBinding, wrongResetEpoch, pendingJournal
}

private enum StoredMailboxCheckpointRecovery: Equatable {
    case freshScan, noNewToken, conflictingPosition, newGeneration
    case manualRetry, manualConflict
}

private enum ManualMailboxFullScan: Equatable {
    case verifiedHeadScanFailure, verifiedHeadConnectionChange, unverifiedHeadScanFailure, verifiedHeadScanSuccess
    case verifiedHeadHydrationFailure, verifiedHeadStaleBeforeHydration, unverifiedHeadHydrationFailure
}

private final class ForegroundSleepCommitDefaults: UserDefaults, @unchecked Sendable {
    var afterCommit: (() -> Void)?
    private(set) var commitWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        guard defaultName == "healthBridge.lastAcceptedTransferObservation" else { return }
        commitWrites += 1
        guard let callback = afterCommit else { return }
        afterCommit = nil
        callback()
    }
}

private final class ForegroundSleepCompletionFiles: FileManager, @unchecked Sendable {
    let directory: URL
    private var remainingListings = 0
    private var afterListings: (() throws -> Void)?
    private var restoreVerifiedArtifacts: (path: String, restore: () throws -> Void)?
    private(set) var presented = false
    private(set) var readVerifiedArtifacts = false

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    func afterForegroundFIFORefresh(_ callback: @escaping () throws -> Void) {
        // After the ACK commit, the VM snapshots pendingItems and refreshes the
        // visible count. Each read lists payloads, envelopes, then FIFO payloads.
        remainingListings = 6
        afterListings = callback
    }

    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let children = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        if url == directory, let callback = afterListings {
            remainingListings -= 1
            if remainingListings == 0 {
                afterListings = nil
                try callback()
                presented = true
            }
        }
        return children
    }

    func present(
        _ input: ForegroundSleepCompletionInput,
        pending: SleepSyncPendingTransition,
        store: FileSleepSyncManifestStore,
        artifacts: (payload: Data, envelopeURL: URL, envelope: Data)
    ) throws {
        switch input {
        case .matching: return
        case .pendingJournal:
            try store.savePendingTransition(pending)
            return
        case .noFinalizedProof:
            try FileManager.default.removeItem(at: directory.appendingPathComponent(".fifo-sequence"))
            return
        case .missingTrackedItem, .ackVerified, .wrongGeneration, .wrongBinding, .wrongResetEpoch:
            break
        }
        let itemID = try XCTUnwrap(pending.outboxItemID)
        let sequenceURL = directory.appendingPathComponent(".fifo-sequence")
        let original = try Data(contentsOf: sequenceURL)
        var sequence = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var entries = try XCTUnwrap(sequence["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex { $0["id"] as? String == itemID })
        var entry = entries[index]
        var state = try XCTUnwrap(entry["deliveryState"] as? [String: Any])
        var ownership = try XCTUnwrap(state["ownership"] as? [String: Any])
        switch input {
        case .missingTrackedItem:
            // Leave another matching proof so an unscoped lookup cannot pass.
            let otherID = UUID().uuidString.lowercased()
            var binding = try XCTUnwrap(entry["mailboxBinding"] as? [String: Any])
            binding["envelopeFilename"] = "\(otherID).hbe"
            entry["id"] = otherID
            entry["mailboxBinding"] = binding
        case .ackVerified:
            state["phase"] = OutboxDeliveryPhase.ackVerified.rawValue
            let payloadURL = directory.appendingPathComponent(itemID).appendingPathExtension("json")
            try artifacts.payload.write(to: payloadURL, options: .atomic)
            try artifacts.envelope.write(to: artifacts.envelopeURL, options: .atomic)
            // A non-finalized entry must own real artifacts for FileOutbox to
            // return it. Restore after lookup validates the envelope so later
            // FIFO validation, if reached, still sees the original snapshot.
            restoreVerifiedArtifacts = (artifacts.envelopeURL.path, {
                try original.write(to: sequenceURL, options: .atomic)
                try FileManager.default.removeItem(at: payloadURL)
                try FileManager.default.removeItem(at: artifacts.envelopeURL)
            })
        case .wrongGeneration:
            ownership["receiverGeneration"] = "unrelated-generation"
        case .wrongBinding:
            let otherBinding = "unrelated-binding"
            ownership["receiverBindingID"] = otherBinding
            entry["receiverIdentity"] = otherBinding // Keep the persisted entry valid.
        case .wrongResetEpoch:
            ownership["resetEpoch"] = try XCTUnwrap(pending.manifest.baselineResetEpoch) + 1
        case .matching, .noFinalizedProof, .pendingJournal:
            return
        }
        state["ownership"] = ownership
        entry["deliveryState"] = state
        entries[index] = entry
        sequence["entries"] = entries
        try JSONSerialization.data(withJSONObject: sequence).write(to: sequenceURL, options: .atomic)
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        if let restoration = restoreVerifiedArtifacts, restoration.path == path,
           attributes[.posixPermissions] != nil {
            restoreVerifiedArtifacts = nil
            try restoration.restore()
            readVerifiedArtifacts = true
        }
    }
}

// UserDefaults.set has no error/acknowledgment channel. Model an unavailable
// metadata destination at that existing injected boundary, not in the VM.
private final class UnavailableObservationDefaults: UserDefaults, @unchecked Sendable {
    private(set) var rejectedWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        rejectedWrites += 1
    }
}

private final class MailboxEnvelopeRemovalFailure: FileManager, @unchecked Sendable {
    var rejectNextRemoval: URL?
    private(set) var rejectedRemoval: URL?
    var rejectManifestHardening: ((String) throws -> Bool)?
    private(set) var didRejectManifestHardening = false
    private var removalAction: (url: URL, perform: () throws -> Void)?

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if try rejectManifestHardening?(path) == true {
            rejectManifestHardening = nil
            didRejectManifestHardening = true
            throw CocoaError(.fileWriteNoPermission)
        }
        return try super.attributesOfItem(atPath: path)
    }

    func afterRemoval(of url: URL, perform: @escaping () throws -> Void) {
        removalAction = (url, perform)
    }

    override func removeItem(at url: URL) throws {
        if url == rejectNextRemoval {
            rejectNextRemoval = nil
            rejectedRemoval = url
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
        if let action = removalAction, action.url == url {
            removalAction = nil
            try action.perform()
        }
    }
}

private final class ScanCheckpointRejectingDefaults: UserDefaults, @unchecked Sendable {
    static let checkpointKey = "healthBridge.backgroundSync.mailboxAckScanCheckpoint"
    var rejectScanCheckpoint = false
    var storeRejectedCheckpoint = false
    private var hasRejectedCheckpointWrite = false
    private(set) var rejectedCheckpoint: String?
    private(set) var rejectedSynchronizations = 0
    private(set) var checkpointWrites: [String] = []
    private(set) var commitWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "healthBridge.lastAcceptedTransferObservation" {
            commitWrites += 1
        }
        if defaultName == Self.checkpointKey, let checkpoint = value as? String {
            checkpointWrites.append(checkpoint)
            if rejectScanCheckpoint {
                hasRejectedCheckpointWrite = true
                rejectedCheckpoint = checkpoint
                if !storeRejectedCheckpoint { return }
            }
        }
        super.set(value, forKey: defaultName)
    }

    override func synchronize() -> Bool {
        if hasRejectedCheckpointWrite {
            hasRejectedCheckpointWrite = false
            rejectedSynchronizations += 1
            return false
        }
        return super.synchronize()
    }
}

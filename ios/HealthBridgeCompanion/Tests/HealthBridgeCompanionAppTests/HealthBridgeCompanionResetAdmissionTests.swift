import Combine
import CryptoKit
import Darwin
import Foundation
import HealthKit
import UIKit
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class HealthBridgeCompanionResetAdmissionTests: XCTestCase {
    func testManualQueuedRetryWithAutomaticSyncDisabledRetiresPayload() async throws {
        try await runOnlineManualQueuedRetry(pendingSleep: false)
    }

    func testManualQueuedRetryWithAutomaticSyncDisabledCompletesSleep() async throws {
        try await runOnlineManualQueuedRetry(pendingSleep: true)
    }

    func testDirectAcceptedSleepACKAllowsIndependentTailAppend() async throws {
        try await exerciseDirectAcceptedSleepACK(.append)
    }

    func testDirectAcceptedSleepACKAllowsTailAppendDuringNutritionPreparation() async throws {
        try await exerciseDirectAcceptedSleepACK(.appendDuringNutritionPreparation)
    }

    func testDirectAcceptedSleepACKDrainsSupportedNutritionSiblingBeforeColdTail() async throws {
        try await exerciseDirectAcceptedSleepACK(.appendWithNutritionSibling)
    }

    func testDirectAcceptedSleepACKWithoutTailAppend() async throws {
        try await exerciseDirectAcceptedSleepACK(.unchanged)
    }

    func testDirectAcceptedSleepACKRejectsChangedAcceptedPayload() async throws {
        try await exerciseDirectAcceptedSleepACK(.replacePayload)
    }

    private enum DirectAcceptedSleepChange {
        case append, appendDuringNutritionPreparation, appendWithNutritionSibling, unchanged, replacePayload
    }

    private func exerciseDirectAcceptedSleepACK(_ change: DirectAcceptedSleepChange) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let date = Date(timeIntervalSince1970: 1_700_259_200)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [], anchorCursorValue: fixture.nextAnchor, receivedAt: date
            ),
            receiverSettingsGeneration: generation, historyDepth: .allAvailable, historyStartDate: nil,
            generatedAt: date
        ))
        let original = try HealthBridgeBatchEncoder().encode(transition.batch)
        let nutritionSibling = change == .appendWithNutritionSibling
        let siblingBatch: HealthBridgeBatchV1
        if nutritionSibling {
            siblingBatch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
                samples: [HealthKitQuantitySampleSummary(
                    uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000005977")),
                    typeCode: "dietary_protein", start: date, end: date.addingTimeInterval(60), value: 12
                )],
                selectedTypeCodes: ["dietary_protein"], windowStart: date, windowEnd: date.addingTimeInterval(60),
                generatedAt: date.addingTimeInterval(60)
            ))
            XCTAssertEqual(siblingBatch.samples.map(\.typeCode), ["dietary_protein"])
            XCTAssertTrue(NutritionCompatibility.containsNutrition(siblingBatch))
            XCTAssertTrue(NutritionCompatibility.permits(siblingBatch, support: .supported))
            fixture.recorder.setCapabilitySupport(true)
        } else {
            siblingBatch = ConnectionTestBatchFactory.make(now: date.addingTimeInterval(60))
        }
        let sibling = try HealthBridgeBatchEncoder().encode(siblingBatch)
        let independent = try HealthBridgeBatchEncoder().encode(
            ConnectionTestBatchFactory.make(now: date.addingTimeInterval(120))
        )
        XCTAssertEqual(Set([original, sibling, independent]).count, 3)
        let oldCheckpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: try XCTUnwrap(fixture.initialManifest.sourceKey),
            cursorKind: SleepSyncBatchFactory.anchoredCursorKind, cursorValue: fixture.nextAnchor
        )
        let nextCheckpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: oldCheckpoint.sourceKey,
            cursorKind: "synthetic-independent-checkpoint", cursorValue: "synthetic-independent-progress"
        )
        let oldItems = try fixture.outbox.enqueueSequence(
            [original, sibling], receiverIdentity: binding, cursorCheckpoint: oldCheckpoint
        )
        let head = try XCTUnwrap(oldItems.first)
        let pending = SleepSyncPendingTransition(
            payload: original, manifest: transition.manifest, receiverBindingID: binding,
            connectionGeneration: generation, outboxItemID: head.id
        )
        try fixture.sleep.savePendingTransition(pending)
        let cursorURL = fixture.root.appendingPathComponent("cursors.json")
        func reopenedCursor(_ checkpoint: FileOutboxCursorCheckpoint) throws -> String? {
            try FileSyncCursorStore(fileURL: cursorURL).cursorValue(
                receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
            )
        }
        let barrier = DirectSleepPreparationBarrier()
        defer { barrier.releasePreparation() }
        let recorder = fixture.recorder
        let appendDuringNutrition = change == .appendDuringNutritionPreparation
        let sleepURL = fixture.root.appendingPathComponent("sleep.json")
        let store = try FileSleepSyncManifestStore(fileURL: sleepURL, observeCodec: { operation in
            if !appendDuringNutrition, operation == .encodeManifest, recorder.acceptedPayloads == [original] {
                barrier.blockPreparation()
            }
        })
        let model = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { DirectSleepPreparationFixture.installationID }
            ),
            outbox: fixture.outbox, receiverClient: ReceiverClient(session: fixture.session),
            sleepManifestStore: store, scheduleDirectBackgroundUploads: { 0 },
            terminalBackgroundPayloadDrain: { true }, platformBackgroundPayloadDrain: { true },
            requestProjectionReadAuthorization: { _ in throw CocoaError(.featureUnsupported) }
        )
        await model.bootstrap()
        XCTAssertEqual(model.pendingOutboxCount, oldItems.count)
        XCTAssertTrue(recorder.payloads.isEmpty)

        var appendedItem: FileOutboxItem?
        let drivePreparation: @MainActor @Sendable () throws -> Void = {
            XCTAssertEqual(recorder.payloads, [original])
            XCTAssertEqual(recorder.acceptedPayloads, [original])
            XCTAssertEqual(try fixture.outbox.pendingItems(), oldItems)
            XCTAssertEqual(try fixture.sleep.loadPendingTransition(), pending)
            XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
            XCTAssertNil(try reopenedCursor(oldCheckpoint))
            XCTAssertNil(try reopenedCursor(nextCheckpoint))
            switch change {
            case .append, .appendDuringNutritionPreparation, .appendWithNutritionSibling:
                let appended = try XCTUnwrap(try fixture.outbox.enqueueSequence(
                    [independent], receiverIdentity: binding, cursorCheckpoint: nextCheckpoint
                ).first)
                appendedItem = appended
                XCTAssertEqual(try fixture.outbox.pendingItems().dropLast().map(\.id), oldItems.map(\.id))
                if nutritionSibling {
                    XCTAssertGreaterThan(recorder.capabilityRequestCount, 0)
                    XCTAssertEqual(model.nutritionNotice, NutritionSupport.supported.notice)
                    XCTAssertNil(fixture.outbox.preparedNutritionPayloads[appended.id])
                }
            case .unchanged:
                break
            case .replacePayload:
                try independent.write(to: head.fileURL, options: .atomic)
                XCTAssertEqual(try fixture.outbox.pendingItems(), oldItems, "The accepted ID did not change.")
                XCTAssertEqual(try Data(contentsOf: head.fileURL), independent)
            }
        }
        if appendDuringNutrition {
            let response = HeldFirstProtocolResponse()
            recorder.setHeldResponseHandler { [weak recorder] resume in
                guard recorder?.payloads == [original] else { return false }
                return response.holdFirst(resume)
            }
            fixture.outbox.observeNutritionCodec = {
                if recorder.acceptedPayloads == [original] { barrier.blockPreparation() }
            }
            let firstDrain = Task { @MainActor in
                await model.performManualSyncOpportunity(processPendingTypes: { false })
            }
            await fulfillment(of: [response.held], timeout: 5)
            XCTAssertTrue(recorder.acceptedPayloads.isEmpty)
            // Make the existing sibling take the real decode path on the next
            // preparation pass. No durable queue entry, byte, or authority changes.
            XCTAssertNotNil(fixture.outbox.preparedNutritionPayloads.removeValue(forKey: oldItems[1].id))
            // The codec cannot be entered until this response is released. Give it
            // its own wait budget instead of borrowing time from the HTTP hold.
            barrier.startDriver(action: drivePreparation)
            XCTAssertTrue(response.release())
            await firstDrain.value
        } else {
            barrier.startDriver(action: drivePreparation)
            await model.performManualSyncOpportunity(processPendingTypes: { false })
        }
        try await barrier.joinDriver()
        let observation = barrier.observation()
        _ = try XCTUnwrap(observation.entered && observation.actionBeforeRelease ? true : nil,
            "Fixture must change or inspect durable inputs after HTTP 200 and before local Sleep ACK.")

        let reopenedOutbox = try FileOutbox(directory: fixture.outbox.directoryURL)
        let reopenedSleep = try FileSleepSyncManifestStore(fileURL: sleepURL)
        if change == .replacePayload {
            XCTAssertEqual(recorder.payloads, [original])
            XCTAssertEqual(recorder.acceptedPayloads, [original])
            XCTAssertNil(try reopenedCursor(oldCheckpoint))
            XCTAssertNil(try reopenedCursor(nextCheckpoint))
            XCTAssertNil(try reopenedOutbox.directFinalizationRecordReady(receiverIdentity: binding))
            XCTAssertEqual(try reopenedOutbox.pendingItems(), oldItems)
            XCTAssertEqual(try Data(contentsOf: head.fileURL), independent)
            XCTAssertEqual(try reopenedSleep.loadManifest(), fixture.initialManifest)
            XCTAssertEqual(try reopenedSleep.loadPendingTransition(), pending)
            return
        }
        XCTAssertEqual(recorder.payloads, [original, sibling], "The first drain must not retry the original bytes.")
        XCTAssertEqual(recorder.acceptedPayloads, [original, sibling])
        let oldAfterFirstDrain = try reopenedCursor(oldCheckpoint)
        let nextAfterFirstDrain = try reopenedCursor(nextCheckpoint)
        XCTAssertEqual(oldAfterFirstDrain, oldCheckpoint.cursorValue)
        XCTAssertNil(nextAfterFirstDrain)
        XCTAssertEqual(try reopenedSleep.loadManifest(), transition.manifest)
        XCTAssertNil(try reopenedSleep.loadPendingTransition())
        if change == .append || appendDuringNutrition || nutritionSibling {
            let appended = try XCTUnwrap(appendedItem)
            let remaining = try reopenedOutbox.pendingItems()
            XCTAssertEqual(remaining, [appended], "The first drain must leave only the independent item.")
            XCTAssertEqual(try remaining.first.map { try Data(contentsOf: $0.fileURL) }, independent)
            if nutritionSibling {
                XCTAssertNil(fixture.outbox.preparedNutritionPayloads[appended.id],
                    "The first drain must not decode the unrelated appended item.")
            }

            // A missing old checkpoint is a first-drain failure, not a reason to
            // skip observing the real retry. Only let it consume this fixture's bytes.
            let seededItems = oldItems + [appended]
            let seededPayloads = [original, sibling, independent]
            guard fixture.settings.receiverBindingID == binding,
                  fixture.settings.receiverSettingsGenerationToken == generation,
                  remaining.last == appended,
                  seededItems.suffix(remaining.count).elementsEqual(remaining),
                  try zip(remaining, seededPayloads.suffix(remaining.count)).allSatisfy({
                      try Data(contentsOf: $0.0.fileURL) == $0.1
                  }) else {
                XCTFail("Retry was not safe: the remaining FIFO was not an intact suffix of the synthetic fixture.")
                return
            }
            let firstPosts = recorder.payloads
            await model.performManualSyncOpportunity(processPendingTypes: { false })
            let posts = recorder.payloads
            let originalPosts = posts.filter { $0 == original }.count
            let siblingPosts = posts.filter { $0 == sibling }.count
            let independentPosts = posts.filter { $0 == independent }.count
            let oldAfterRetry = try reopenedCursor(oldCheckpoint)
            let nextAfterRetry = try reopenedCursor(nextCheckpoint)
            let marker = nutritionSibling ? "DIRECT_SLEEP_NUTRITION_CONTINUATION"
                : (appendDuringNutrition ? "DIRECT_SLEEP_EARLY_APPEND_RETRY" : "DIRECT_SLEEP_APPEND_RETRY")
            print("\(marker) originalPOSTs=\(originalPosts) independentPOSTs=\(independentPosts) "
                + "siblingPOSTs=\(siblingPosts) firstSiblingPOSTs=\(firstPosts.filter { $0 == sibling }.count) "
                + "firstOldCommitted=\(oldAfterFirstDrain == oldCheckpoint.cursorValue) "
                + "firstNextAbsent=\(nextAfterFirstDrain == nil) "
                + "retryOldCommitted=\(oldAfterRetry == oldCheckpoint.cursorValue) "
                + "retryNextCommitted=\(nextAfterRetry == nextCheckpoint.cursorValue)")
            XCTAssertEqual(originalPosts, 1, "Original POST count after foreground retry.")
            XCTAssertEqual(siblingPosts, 1, "Sibling POST count after foreground retry.")
            XCTAssertEqual(independentPosts, 1, "Independent POST count after foreground retry.")
            XCTAssertEqual(Array(posts.dropFirst(firstPosts.count)), [independent],
                "Only the independent payload should be POSTed on the second opportunity.")
            XCTAssertEqual(posts, [original, sibling, independent])
            XCTAssertEqual(recorder.acceptedPayloads, [original, sibling, independent])
            XCTAssertEqual(oldAfterRetry, oldCheckpoint.cursorValue)
            XCTAssertEqual(nextAfterRetry, nextCheckpoint.cursorValue)
        }
        XCTAssertTrue(try FileOutbox(directory: fixture.outbox.directoryURL).pendingItems().isEmpty)
        #endif
    }

    func testAcceptedPlainResponseSurvivesUnsavedURLDraft() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires isolated test host.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        // A connection-check payload declares every type (including Sleep).
        // Use a supported, genuinely plain batch to hit the post-2xx path.
        let bytes = try HealthBridgeBatchEncoder().encode(StepCountSyncBatchFactory.makeAnchoredStepBatch(
            changes: HealthKitAnchoredStepChanges(
                stepSamples: [], deletedStepSamples: [], anchorCursorValue: "draft-test-anchor",
                windowStart: instant, windowEnd: instant.addingTimeInterval(60)
            ),
            generatedAt: instant.addingTimeInterval(60)
        ))
        _ = try fixture.outbox.enqueue(bytes, receiverIdentity: binding)
        let model = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { DirectSleepPreparationFixture.installationID }
            ),
            outbox: fixture.outbox, receiverClient: ReceiverClient(session: fixture.session),
            scheduleDirectBackgroundUploads: { 0 }, requestProjectionReadAuthorization: { _ in
                throw CocoaError(.featureUnsupported)
            }
        )
        await model.bootstrap()
        let held = HeldFirstProtocolResponse()
        fixture.recorder.setHeldResponseHandler(forPayload: bytes) { resume in held.holdFirst(resume) }
        let drain = Task { await model.performManualSyncOpportunity(processPendingTypes: { false }) }
        await fulfillment(of: [held.held], timeout: 5)
        XCTAssertEqual(fixture.recorder.payloads, [bytes], "The held response must belong to the plain upload.")
        XCTAssertNil(model.lastAcceptedTransferObservation)
        let committedURL = fixture.settings.receiverURLString
        model.receiverURLString = "https://draft.invalid/v1/batches"
        XCTAssertTrue(held.release())
        await drain.value
        XCTAssertEqual(fixture.settings.receiverURLString, committedURL)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(model.lastAcceptedTransferObservation?.bindingID, binding)
        XCTAssertEqual(model.lastAcceptedTransferObservation?.evidenceKind, .directResponse)
        model.receiverURLString = committedURL
        await model.performManualSyncOpportunity(processPendingTypes: { false })
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [bytes])
        #endif
    }

    func testReceiverReplacementRequiresOldOwnerToUnlinkRetiredPlainACKBeforeNewCheckpoint() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let oldBinding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let oldGeneration = fixture.settings.receiverSettingsGenerationToken
        let oldConnection = try fixture.settings.currentConnectionRecordV2()
        let directory = fixture.outbox.directoryURL
        let journal = directory.appendingPathComponent(".enqueue-transaction")
        let fault = SleepJournalUnlinkInterruption(journalURL: journal, afterUnlink: false)
        let date = Date(timeIntervalSince1970: 1_700_259_200)
        let oldPayload = try HealthBridgeBatchEncoder().encode(ConnectionTestBatchFactory.make(now: date))
        let oldItem = try fixture.outbox.enqueue(oldPayload, receiverIdentity: oldBinding)
        let observations = makeResetTestTransferStore(root: fixture.root, defaults: fixture.defaults)
        let cursors = try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json"))
        let sourceKey = "synthetic-replacement-source"
        let cursorKind = "synthetic-replacement-kind"
        let oldCursor = "synthetic-old-cursor"
        try cursors.saveCursorValue(oldCursor, receiverBindingID: oldBinding, sourceKey: sourceKey, cursorKind: cursorKind)
        var replacementDrainCount = 0
        var requestedFreshReadAuthorization: [[String]] = []

        func cursor(for binding: String) throws -> String? {
            try cursors.cursorValue(receiverBindingID: binding, sourceKey: sourceKey, cursorKind: cursorKind)
        }

        func open(_ outbox: FileOutbox) async throws -> HealthBridgeCompanionViewModel {
            let model = try makeViewModel(
                root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
                pairingStateStore: ReceiverPairingStateStore(
                    pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                    cancellationStore: MemoryReceiverTokenStore(),
                    installationIDGenerator: { DirectSleepPreparationFixture.installationID }
                ),
                outbox: outbox, receiverClient: ReceiverClient(session: fixture.session),
                automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                    fileURL: fixture.root.appendingPathComponent("diagnostics.json")
                ),
                readAnchoredStepChanges: { _, _, _ in
                    XCTFail("This fixture must not execute a fresh Steps read.")
                    throw CocoaError(.featureUnsupported)
                },
                scheduleDirectBackgroundUploads: { 0 },
                terminalBackgroundPayloadDrain: {
                    replacementDrainCount += 1
                    XCTAssertEqual(fixture.settings.receiverBindingID, oldBinding)
                    XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, oldGeneration)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
                    XCTAssertEqual(try? cursor(for: oldBinding), oldCursor)
                    return true
                },
                platformBackgroundPayloadDrain: { true },
                requestProjectionReadAuthorization: { types in
                    // Sync Now offers fresh Steps only after a successful FIFO flush.
                    requestedFreshReadAuthorization.append(types)
                    XCTAssertEqual(fixture.recorder.acceptedPayloads.count, 2)
                    XCTAssertTrue(try outbox.pendingItems().isEmpty)
                    throw CocoaError(.featureUnsupported)
                }
            )
            await model.bootstrap()
            return model
        }

        let writer = try await open(FileOutbox(directory: directory, fileManager: fault))
        await writer.performManualSyncOpportunity(processPendingTypes: { false })
        XCTAssertEqual(fault.interruptions, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldItem.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(fixture.recorder.payloads, [oldPayload])
        XCTAssertTrue(requestedFreshReadAuthorization.isEmpty)
        let networkInvocationsAfterOldUpload = fixture.recorder.invocationCount
        let oldObservation = try XCTUnwrap(observations.load(bindingID: oldBinding, generation: oldGeneration))

        let outbox = try FileOutbox(directory: directory, fileManager: fault)
        let oldRecord = try XCTUnwrap(outbox.directFinalizationRecordReady(receiverIdentity: oldBinding))
        XCTAssertEqual(oldRecord.itemIDs, [oldItem.id])
        XCTAssertNil(oldRecord.cursorCheckpoint)
        XCTAssertTrue(oldRecord.pendingGenerationRetirements.isEmpty)
        XCTAssertNil(try outbox.directSleepCleanupIntent(for: oldRecord))
        XCTAssertTrue(try outbox.uncheckedDirectAcknowledgmentIDs(for: oldRecord).isEmpty)
        XCTAssertTrue(try outbox.hasDirectAcknowledgmentWithSleepChecked(
            itemID: oldItem.id, receiverIdentity: oldBinding
        ))
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())

        let reopened = try await open(outbox)
        XCTAssertEqual(fault.interruptions, 2, "Bootstrap retries the journal unlink under the old binding.")
        func replaceReceiver() async {
            reopened.receiverURLString = "http://127.0.0.1:8766/v1/batches"
            reopened.bearerToken = "synthetic-plain-ack-replacement"
            await reopened.saveReceiverSettings()
        }
        await replaceReceiver()
        XCTAssertTrue(reopened.statusIsError)
        XCTAssertEqual(fault.interruptions, 3, "The replacement attempted local cleanup while still under the old authority.")
        XCTAssertEqual(replacementDrainCount, 0)
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), oldConnection)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, oldGeneration)
        XCTAssertEqual(try cursor(for: oldBinding), oldCursor)
        XCTAssertEqual(try outbox.directFinalizationRecordReady(receiverIdentity: oldBinding), oldRecord)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(fixture.recorder.payloads, [oldPayload])
        XCTAssertEqual(fixture.recorder.invocationCount, networkInvocationsAfterOldUpload)
        guard fixture.settings.receiverBindingID == oldBinding else { return }

        fault.stopInterrupting()
        await replaceReceiver()
        let newBinding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let newGeneration = fixture.settings.receiverSettingsGenerationToken
        XCTAssertNotEqual(newBinding, oldBinding)
        XCTAssertNotEqual(newGeneration, oldGeneration)
        XCTAssertEqual(replacementDrainCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: oldBinding))
        XCTAssertNil(try cursor(for: newBinding))
        XCTAssertEqual(observations.load(bindingID: oldBinding, generation: oldGeneration), oldObservation)
        XCTAssertNil(observations.load(bindingID: newBinding, generation: newGeneration))
        XCTAssertNil(reopened.lastAcceptedTransferObservation)
        XCTAssertEqual(fixture.recorder.payloads, [oldPayload], "Replacement must not resend accepted bytes.")
        XCTAssertEqual(fixture.recorder.invocationCount, networkInvocationsAfterOldUpload)
        XCTAssertTrue(requestedFreshReadAuthorization.isEmpty)
        guard newBinding != oldBinding else { return }

        let newPayload = try HealthBridgeBatchEncoder().encode(
            ConnectionTestBatchFactory.make(now: date.addingTimeInterval(60))
        )
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: newBinding, sourceKey: sourceKey, cursorKind: cursorKind, cursorValue: "synthetic-new-cursor"
        )
        let newItems = try outbox.enqueueSequence([newPayload], receiverIdentity: newBinding, cursorCheckpoint: checkpoint)
        let newItem = try XCTUnwrap(newItems.first)
        await reopened.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertEqual(try cursor(for: newBinding), checkpoint.cursorValue)
        XCTAssertNil(try cursor(for: oldBinding))
        XCTAssertNil(try outbox.pendingCursorCheckpoint())
        XCTAssertFalse(try outbox.hasDirectAcknowledgmentWithSleepChecked(itemID: newItem.id, receiverIdentity: newBinding))
        XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: oldBinding))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(fault.interruptions, 3)
        XCTAssertNil(observations.load(bindingID: oldBinding, generation: oldGeneration))
        XCTAssertEqual(observations.load(bindingID: newBinding, generation: newGeneration)?.evidenceKind, .directResponse)
        XCTAssertEqual(requestedFreshReadAuthorization, [["steps"]])
        XCTAssertEqual(fixture.recorder.payloads, [oldPayload, newPayload])
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [oldPayload, newPayload])
        #endif
    }

    func testReceiverReplacementWaitsForCheckedSleepCollectionFinalization() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let oldConnection = try fixture.settings.currentConnectionRecordV2()
        let date = Date(timeIntervalSince1970: 1_700_259_200)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [], anchorCursorValue: fixture.nextAnchor, receivedAt: date
            ),
            receiverSettingsGeneration: generation,
            historyDepth: .allAvailable, historyStartDate: nil, generatedAt: date
        ))
        let sleepPayload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let siblingPayload = try HealthBridgeBatchEncoder().encode(ConnectionTestBatchFactory.make(now: date))
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: try XCTUnwrap(fixture.initialManifest.sourceKey),
            cursorKind: SleepSyncBatchFactory.anchoredCursorKind, cursorValue: fixture.nextAnchor
        )
        let items = try fixture.outbox.enqueueSequence(
            [sleepPayload, siblingPayload], receiverIdentity: binding, cursorCheckpoint: checkpoint,
            pendingGenerationRetirements: fixture.generations
        )
        try fixture.sleep.savePendingTransition(SleepSyncPendingTransition(
            payload: sleepPayload, manifest: transition.manifest, receiverBindingID: binding,
            connectionGeneration: generation, outboxItemID: items[0].id
        ))

        func openViewModel(outbox: FileOutbox) async throws -> HealthBridgeCompanionViewModel {
            let vm = try makeViewModel(
                root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
                pairingStateStore: ReceiverPairingStateStore(
                    pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                    cancellationStore: MemoryReceiverTokenStore(),
                    installationIDGenerator: { DirectSleepPreparationFixture.installationID }
                ),
                outbox: outbox, receiverClient: ReceiverClient(session: fixture.session),
                automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                    fileURL: fixture.root.appendingPathComponent("diagnostics.json")
                ),
                scheduleDirectBackgroundUploads: { 0 },
                terminalBackgroundPayloadDrain: { true }, platformBackgroundPayloadDrain: { true },
                requestProjectionReadAuthorization: { _ in
                    XCTFail("Queued retry must not collect new data")
                    throw CocoaError(.featureUnsupported)
                }
            )
            await vm.bootstrap()
            return vm
        }

        let replacementURL = "http://127.0.0.1:8766/v1/batches"
        let replacementToken = "synthetic-checkpoint-replacement"
        func replaceReceiver(_ vm: HealthBridgeCompanionViewModel) async {
            vm.receiverURLString = replacementURL
            vm.bearerToken = replacementToken
            await vm.saveReceiverSettings()
        }

        let initial = try await openViewModel(outbox: fixture.outbox)
        let cursorURL = fixture.root.appendingPathComponent("cursors.json")
        let cursors = try FileSyncCursorStore(fileURL: cursorURL)
        func cursor(for binding: String, in store: FileSyncCursorStore) throws -> String? {
            try store.cursorValue(
                receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
            )
        }
        // Keep the cursor file readable while refusing atomic replacement of that file alone.
        guard chflags(cursorURL.path, UInt32(UF_APPEND)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = chflags(cursorURL.path, 0) }
        XCTAssertThrowsError(try cursors.saveCursorValue(
            checkpoint.cursorValue, receiverBindingID: binding,
            sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
        ))
        // Arm the sibling failure after the bodyless health check and the Sleep response status are decided.
        fixture.recorder.setBeforeResponse { [weak recorder = fixture.recorder] payload, _ in
            if payload == sleepPayload {
                recorder?.setFailedCursorKinds(["connection_test"])
            }
        }
        await initial.performManualSyncOpportunity(processPendingTypes: { false })

        XCTAssertEqual(fixture.recorder.acceptedPayloads, [sleepPayload])
        XCTAssertTrue(try fixture.outbox.hasDirectAcknowledgmentWithSleepChecked(
            itemID: items[0].id, receiverIdentity: binding
        ))
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [items[1].id])
        XCTAssertNil(try fixture.outbox.directFinalizationRecordReady(receiverIdentity: binding))
        XCTAssertNil(try cursor(for: binding, in: cursors))
        let attemptsBeforeReplacement = fixture.recorder.payloads
        XCTAssertEqual(attemptsBeforeReplacement, [sleepPayload, siblingPayload])
        await replaceReceiver(initial)
        XCTAssertEqual(fixture.recorder.payloads, attemptsBeforeReplacement, "Replacement must not POST the pending sibling")
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), oldConnection)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)

        initial.receiverURLString = fixture.settings.receiverURLString
        initial.bearerToken = try fixture.settings.loadBearerToken()
        fixture.recorder.setFailedCursorKinds([])
        await initial.performManualSyncOpportunity(processPendingTypes: { false })
        XCTAssertTrue(initial.statusIsError)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [sleepPayload, siblingPayload])
        let posts = fixture.recorder.payloads
        XCTAssertEqual(posts, [sleepPayload, siblingPayload, siblingPayload])

        let outbox = try FileOutbox(directory: fixture.outbox.directoryURL)
        let reopenedCursors = try FileSyncCursorStore(fileURL: cursorURL)
        let sleep = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        let background = BackgroundSyncSettingsStore(userDefaults: fixture.defaults)
        let observations = makeResetTestTransferStore(root: fixture.root, defaults: fixture.defaults)
        let observation = try XCTUnwrap(observations.load(bindingID: binding, generation: generation))
        let record = try XCTUnwrap(outbox.directFinalizationRecordReady(receiverIdentity: binding))
        XCTAssertEqual(record.itemIDs, items.map(\.id))
        XCTAssertEqual(record.cursorCheckpoint, checkpoint)
        XCTAssertEqual(record.eligiblePendingGenerationRetirements, fixture.generations)
        let reopened = try await openViewModel(outbox: outbox)
        XCTAssertTrue(reopened.statusMessage.contains("Private upload storage needs recovery"))
        await replaceReceiver(reopened)

        XCTAssertTrue(reopened.statusMessage.contains("code=transition_requires_empty_outbox"))
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), oldConnection)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        let activeBinding = try XCTUnwrap(fixture.settings.receiverBindingID)
        XCTAssertEqual(activeBinding, binding, "Replacement must not create a new binding before finalization")
        XCTAssertNil(try cursor(for: binding, in: reopenedCursors))
        if activeBinding != binding {
            XCTAssertNil(try cursor(for: activeBinding, in: reopenedCursors))
            XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: activeBinding))
        }
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try outbox.directFinalizationRecordReady(receiverIdentity: binding), record)
        XCTAssertNil(try outbox.directSleepCleanupIntent(for: record))
        for item in items {
            XCTAssertTrue(try outbox.hasDirectAcknowledgmentWithSleepChecked(
                itemID: item.id, receiverIdentity: binding
            ))
        }
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertEqual(try sleep.loadManifest(), transition.manifest)
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(observations.load(bindingID: binding, generation: generation), observation)
        XCTAssertEqual(fixture.recorder.payloads, posts)

        guard activeBinding == binding else { return }
        guard chflags(cursorURL.path, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        await reopened.retryPrivateStorage()
        XCTAssertEqual(try cursor(for: binding, in: reopenedCursors), checkpoint.cursorValue)
        XCTAssertTrue(try background.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: binding))
        XCTAssertEqual(observations.load(bindingID: binding, generation: generation), observation)
        XCTAssertEqual(fixture.recorder.payloads, posts, "Authorized recovery must not repost accepted payloads")

        await replaceReceiver(reopened)
        let newBinding = try XCTUnwrap(fixture.settings.receiverBindingID)
        XCTAssertNotEqual(newBinding, binding)
        XCTAssertNotEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertEqual(fixture.settings.receiverURLString, replacementURL)
        XCTAssertEqual(try fixture.settings.loadBearerToken(), replacementToken)
        XCTAssertNil(try cursor(for: newBinding, in: reopenedCursors))
        XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: newBinding))
        XCTAssertNil(reopened.lastAcceptedTransferObservation)
        XCTAssertEqual(fixture.recorder.payloads, posts)
    }

    func testManualQueuedStepsWithAutomaticSyncEnabledDoesNotReenterTransferGate() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        var reachedManualAuthorization = false
        let runtime = try await makeIssue63Runtime(
            fixture,
            requestProjectionReadAuthorization: { types in
                XCTAssertEqual(types, ["steps"])
                reachedManualAuthorization = true
                throw AutomaticStepsFaultFixture.ReadFailure.injected
            }
        )
        let generations = try fixture.admit(["steps"])
        fixture.recorder.setResponseStatusCode(500)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        let outbox = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox"))
        let queued = try XCTUnwrap(outbox.pendingItems().first)
        let payload = try Data(contentsOf: queued.fileURL)
        XCTAssertEqual(try outbox.pendingItems().count, 1)
        XCTAssertFalse(try outbox.hasPendingGenerationRetirements(generations))
        XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
        XCTAssertTrue(runtime.viewModel.automaticSyncRuntimeIsReady)
        fixture.recorder.setResponseStatusCode(200)
        let finished = expectation(description: "Manual queued Steps retry completed")
        let action = Task { @MainActor in
            await runtime.viewModel.syncAllNow()
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 10)
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        await action.value
        await runtime.viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(fixture.recorder.acceptedPayloads.first, payload)
        try assertStepsFaultCompletion(fixture)
        XCTAssertTrue(reachedManualAuthorization)
        XCTAssertFalse(runtime.viewModel.syncPresentationIsActive)
    }

    private func runOnlineManualQueuedRetry(pendingSleep: Bool) async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [],
                anchorCursorValue: fixture.nextAnchor, receivedAt: Date()),
            receiverSettingsGeneration: fixture.settings.receiverSettingsGenerationToken,
            historyDepth: .allAvailable, historyStartDate: nil
        ))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let item = try fixture.outbox.enqueueIfAbsent(payload, receiverIdentity: binding).item
        if pendingSleep {
            try fixture.sleep.savePendingTransition(SleepSyncPendingTransition(
                payload: payload, manifest: transition.manifest,
                receiverBindingID: binding,
                connectionGeneration: fixture.settings.receiverSettingsGenerationToken,
                outboxItemID: item.id
            ))
        }
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        defer { PayloadFenceURLProtocol.networkRecorder = nil }
        var reachedCollection = false
        var authorizedTypes: [String] = []
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { DirectSleepPreparationFixture.installationID }),
            outbox: fixture.outbox, receiverClient: ReceiverClient(session: fixture.session),
            sleepManifestStore: fixture.sleep,
            readAnchoredStepChanges: { _, _, _ in
                reachedCollection = true
                throw URLError(.cannotParseResponse)
            },
            scheduleDirectBackgroundUploads: { 0 },
            terminalBackgroundPayloadDrain: { true },
            platformBackgroundPayloadDrain: { true },
            requestProjectionReadAuthorization: { types in
                authorizedTypes = types
                XCTAssertEqual(fixture.recorder.acceptedPayloads, [payload])
                XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
                XCTAssertNil(try fixture.sleep.loadPendingTransition())
            }
        )
        await viewModel.bootstrap()
        XCTAssertFalse(viewModel.backgroundSyncEnabled)
        XCTAssertTrue(viewModel.canSendConnectionTest)
        XCTAssertEqual(viewModel.pendingOutboxCount, 1)
        XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false }, executeQuery: { _ in XCTFail("Synthetic readers only.") },
            stopQuery: { _ in }, enableDelivery: { _, completion in completion(false, nil) },
            disableDelivery: { _ in })
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in {} },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator)
        let runtime = HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel, automaticSyncPlatform: platform)

        await viewModel.syncAllNow()
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        await viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(fixture.recorder.acceptedPayloads, [payload])
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertEqual(try fixture.sleep.loadManifest(),
            pendingSleep ? transition.manifest : fixture.initialManifest)
        XCTAssertTrue(reachedCollection, "Manual retry must finish before the next synthetic reader runs.")
        XCTAssertEqual(authorizedTypes, ["steps"])
        XCTAssertFalse(viewModel.backgroundSyncEnabled)
        XCTAssertFalse(viewModel.syncPresentationIsActive)
    }

    func testOfflineManualPreflightMustPrecedeEnabledPendingSleepEffects() async throws {
        try await runOfflinePendingSleepPreflight(enabled: true)
    }

    func testOfflineManualPreflightWithDisabledPendingSleepHasNoEffects() async throws {
        try await runOfflinePendingSleepPreflight(enabled: false)
    }

    private func runOfflinePendingSleepPreflight(enabled: Bool) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        XCTFail("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        return
        #else
        // Given: real durable pending work, real stores, and only synthetic boundary IO.
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(enabled)
        let trace = OfflinePreflightTrace()
        OfflinePreflightURLProtocol.trace = trace
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflinePreflightURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OfflinePreflightURLProtocol.trace = nil
        }
        let finished = expectation(description: "Whole manual action completed")
        var readCount = 0
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { DirectSleepPreparationFixture.installationID }
            ),
            outbox: fixture.outbox, receiverClient: ReceiverClient(session: session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: fixture.root.appendingPathComponent("diagnostics.json")),
            sleepManifestStore: fixture.sleep,
            readAnchoredSleepChanges: { anchor, start, now in
                readCount += 1
                trace.record("reader.enter")
                XCTAssertEqual(anchor, fixture.previousAnchor)
                XCTAssertNil(start)
                trace.record("reader.return")
                return HealthKitAnchoredSleepChanges(
                    addedSamples: [], deletedSamples: [],
                    anchorCursorValue: fixture.nextAnchor, receivedAt: now
                )
            },
            automaticSyncEligibleTypeCodesForTesting: ["sleep_analysis"],
            scheduleDirectBackgroundUploads: {
                let count = try fixture.outbox.pendingItems().count
                trace.record("schedule.queue=\(count)")
                return 0
            },
            terminalBackgroundPayloadDrain: { true },
            platformBackgroundPayloadDrain: { true }
        )
        await viewModel.bootstrap()
        XCTAssertEqual(viewModel.automaticSyncRuntimeIsReady, enabled)
        XCTAssertTrue(viewModel.canSendConnectionTest)
        XCTAssertEqual(viewModel.automaticSyncSelectedEligibleTypeCodes(), ["sleep_analysis"])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("Synthetic reproduction must not execute HealthKit queries.") },
            stopQuery: { _ in }, enableDelivery: { _, completion in completion(false, nil) },
            disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in {} },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
        )
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel, automaticSyncPlatform: platform)
        trace.reset()

        // When: the actual Sync Now entry runs through the actual automatic engine.
        let action = Task { @MainActor in
            await viewModel.syncAllNow()
            trace.record("manual.finished")
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 15)
        action.cancel()
        await action.value
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        await viewModel.waitForBootstrapAndForegroundWork()

        // Then: inspect actual durable effects, not a processPendingTypes callback.
        let items = try fixture.outbox.pendingItems()
        let pending = try fixture.sleep.loadPendingTransition()
        let events = trace.events
        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertFalse(viewModel.syncPresentationIsActive)
        XCTAssertEqual(events.filter { $0 == "http.GET./health.failed" }.count, 1)
        XCTAssertFalse(events.contains { $0.hasPrefix("http.POST") })
        XCTAssertNil(pending)
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(
            events.filter { !$0.hasPrefix("schedule.queue=") },
            ["http.GET./health.failed", "manual.finished"]
        )
        XCTAssertTrue(
            events.filter { $0.hasPrefix("schedule.queue=") }.allSatisfy { $0 == "schedule.queue=0" }
        )
        XCTAssertEqual(readCount, 0, "Failed manual reachability must precede all collection in the action.")
        XCTAssertTrue(items.isEmpty, "Failed manual reachability must not leave newly enqueued work.")
        #endif
    }

    func testIssue96CancelFirstCodecCannotCommit() async throws {
        try await runIssue96SuspensionFence(.firstJournal, invalidation: .cancel)
    }

    func testIssue96ReplaceFirstCodecCannotCommit() async throws {
        try await runIssue96SuspensionFence(.firstJournal, invalidation: .replace)
    }

    func testIssue96ResetFirstCodecCannotCommit() async throws {
        try await runIssue96SuspensionFence(.firstJournal, invalidation: .reset)
    }

    func testIssue96CancelTrackedCodecRetainsUntrackedJournal() async throws {
        try await runIssue96SuspensionFence(.trackedJournal, invalidation: .cancel)
    }

    func testIssue96ReplaceTrackedCodecRetainsUntrackedJournal() async throws {
        try await runIssue96SuspensionFence(.trackedJournal, invalidation: .replace)
    }

    func testIssue96ResetTrackedCodecRetainsJournalUntilResetCommit() async throws {
        try await runIssue96SuspensionFence(.trackedJournal, invalidation: .reset)
    }

    func testIssue96ReplacePendingReplayCannotEnqueue() async throws {
        try await runIssue96SuspensionFence(.pendingReplay, invalidation: .replace)
    }

    func testIssue96ReplaceCompletionCodecPreservesEarnedACK() async throws {
        try await runIssue96SuspensionFence(.completion, invalidation: .replace)
    }

    func testIssue96MissingPayloadWithoutACKRetriesBeforeProgress() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture(
            nightCount: 3_650, childrenPerNight: 16,
            historyOrigin: Date(timeIntervalSince1970: 1_300_000_000)
        )
        defer { fixture.cleanUp() }
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(addedSamples: [], deletedSamples: [],
                anchorCursorValue: fixture.nextAnchor, receivedAt: Date()),
            receiverSettingsGeneration: fixture.settings.receiverSettingsGenerationToken,
            historyDepth: .allAvailable, historyStartDate: nil
        ))
        let pending = SleepSyncPendingTransition(
            payload: try HealthBridgeBatchEncoder().encode(transition.batch), manifest: transition.manifest,
            receiverBindingID: try XCTUnwrap(fixture.settings.receiverBindingID),
            connectionGeneration: fixture.settings.receiverSettingsGenerationToken
        )
        try fixture.sleep.savePendingTransition(pending)
        let binding = pending.receiverBindingID
        let item = try fixture.outbox.enqueue(pending.payload, receiverIdentity: binding)
        let tracked = pending.assigningOutboxItemID(item.id)
        try fixture.sleep.savePendingTransition(tracked)
        let cursorStore = try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json"))
        XCTAssertFalse(try OutboxDeliveryCursorFinalizer(outbox: fixture.outbox, cursorStore: cursorStore)
            .recordDirectReceiverAcceptance(itemID: item.id, receiverBindingID: binding))

        let reopenedOutbox = try FileOutbox(directory: fixture.outbox.directoryURL)
        let reopenedStore = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        XCTAssertTrue(try reopenedOutbox.pendingItems().isEmpty)
        XCTAssertNil(try reopenedOutbox.directFinalizationRecordReady(receiverIdentity: binding))
        XCTAssertNil(try reopenedOutbox.directSleepCleanupRecord(receiverBindingID: binding, itemID: item.id))
        XCTAssertFalse(try reopenedOutbox.hasUncheckedDirectAcknowledgment(itemID: item.id, receiverBindingID: binding))
        XCTAssertEqual(try reopenedStore.loadPendingTransition(), tracked)
        XCTAssertEqual(try reopenedStore.loadManifest(), fixture.initialManifest)
        let audit = Issue96CodecAudit(
            root: fixture.root, committed: fixture.initialManifest, recorder: fixture.recorder)
        fixture.recorder.setBeforeResponse { payload, _ in try audit.beforeACK(payload) }
        var enqueueAttempts = 0
        let runtime = try await makeIssue96CodecRuntime(
            fixture, store: reopenedStore, outbox: reopenedOutbox,
            beforeBootstrap: { model in model.observeSleepEnqueueAttemptForTesting = { enqueueAttempts += 1 } }
        )
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertEqual(enqueueAttempts, 0)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        let foreground = runtime.automaticSyncRuntime.foregroundCatchUpCompletion()
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        await foreground?()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
        XCTAssertEqual(fixture.recorder.invocationCount, 1)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [pending.payload])
        XCTAssertEqual(enqueueAttempts, 1)
        XCTAssertEqual(try reopenedStore.loadManifest(), pending.manifest)
        XCTAssertNil(try reopenedStore.loadPendingTransition())
        XCTAssertTrue(try reopenedOutbox.pendingItems().isEmpty)
        let observation = audit.observation()
        XCTAssertEqual(observation.failures, 0)
        XCTAssertEqual(observation.preACKChecks, 1)
        let retried = try XCTUnwrap(observation.pendingBeforeACK)
        XCTAssertEqual(retried.id, pending.id)
        XCTAssertNotEqual(retried.outboxItemID, item.id)
        #endif
    }

    func testIssue96FirstJournalCodecAllowsMainActor() async throws {
        try await runIssue96CodecCase(.firstJournal, blocking: true)
    }

    func testIssue96TrackedJournalCodecAllowsMainActor() async throws {
        try await runIssue96CodecCase(.trackedJournal, blocking: true)
    }

    func testIssue96ColdManifestCodecAllowsMainActor() async throws {
        try await runIssue96CodecCase(.coldManifest, blocking: true)
    }

    func testIssue96PendingReplayCodecAllowsMainActor() async throws {
        try await runIssue96CodecCase(.pendingReplay, blocking: true)
    }

    func testIssue96CompletionManifestCodecAllowsMainActor() async throws {
        try await runIssue96CodecCase(.completion, blocking: true)
    }

    func testIssue96SleepCodecPathsUnblocked() async throws {
        for scenario in [Issue96CodecCase.firstJournal, .coldManifest, .pendingReplay, .completion] {
            try await runIssue96CodecCase(scenario, blocking: false)
        }
    }

    func testIssue96SleepCodecDeliveryFailureRetainsPending() async throws {
        try await runIssue96CodecCase(.firstJournal, blocking: false, receiverStatus: 500)
    }

    func testIssue96AutomaticSleepPreparationKeepsMainActorResponsive() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let audit = Issue96CodecAudit(
            root: fixture.root, committed: fixture.initialManifest, recorder: fixture.recorder)
        fixture.recorder.setBeforeResponse { payload, _ in try audit.beforeACK(payload) }
        let barrier = DirectSleepPreparationBarrier()
        defer { barrier.releasePreparation() }
        let runtime = try await makeIssue96Runtime(fixture, barrier: barrier)
        barrier.startDriver()

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        try await barrier.joinDriver()
        await runtime.automaticSyncRuntime.cancelAndWait()

        let observation = barrier.observation()
        XCTAssertTrue(observation.entered, "Automatic sync must reach the real sleep preparation boundary.")
        XCTAssertTrue(observation.actionBeforeRelease, "MainActor must run while sleep preparation is blocked.")
        XCTAssertEqual(fixture.readAnchors, [fixture.previousAnchor])
        let committed = try XCTUnwrap(fixture.sleep.loadManifest())
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertEqual(committed.anchorCursorValue, fixture.nextAnchor)
        XCTAssertEqual(committed.publishedSessions, fixture.initialManifest.publishedSessions)
        XCTAssertEqual(committed.nextRevisionSequence, fixture.initialManifest.nextRevisionSequence)
        XCTAssertEqual(fixture.recorder.acceptedPayloads.count, 1)
        let payload = try XCTUnwrap(fixture.recorder.acceptedPayloads.first)
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: payload)
        XCTAssertTrue(batch.sleepSessions.isEmpty, "An unchanged history must not republish sleep records.")
        XCTAssertTrue(batch.deletedRecords.isEmpty)
        XCTAssertEqual(batch.sync.cursors.map(\.cursorValue), [fixture.nextAnchor])
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [payload])
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(audit.observation().failures, 0)
        XCTAssertEqual(audit.observation().preACKChecks, 1)
    }

    func testIssue96CancellationDuringSleepPreparationCannotJournalOrAdvanceAnchor() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let barrier = DirectSleepPreparationBarrier()
        defer { barrier.releasePreparation() }
        let runtime = try await makeIssue96Runtime(fixture, barrier: barrier)
        let operation = Task { @MainActor in
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        }
        barrier.startDriver { operation.cancel() }

        await operation.value
        try await barrier.joinDriver()
        await runtime.automaticSyncRuntime.cancelAndWait()

        let observation = barrier.observation()
        XCTAssertTrue(observation.entered)
        XCTAssertTrue(observation.actionBeforeRelease, "Cancellation must occur while preparation is blocked.")
        try assertIssue96PreparationWasAbandoned(fixture, runtime: runtime)
    }

    func testIssue96AutomaticSleepSnapshotInvalidationRetainsObserverGeneration() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let barrier = DirectSleepPreparationBarrier()
        defer { barrier.releasePreparation() }
        let runtime = try await makeIssue96Runtime(fixture, barrier: barrier)
        barrier.startDriver {
            let revision = try fixture.sleep.revisionForSync()
            try fixture.sleep.saveManifest(fixture.initialManifest)
            XCTAssertNotEqual(try fixture.sleep.revisionForSync(), revision)
        }

        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: ["sleep_analysis"])
        )
        try await barrier.joinDriver()
        await runtime.automaticSyncRuntime.cancelAndWait()

        XCTAssertTrue(barrier.observation().actionBeforeRelease)
        XCTAssertEqual(fixture.readAnchors, [fixture.previousAnchor])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel)?.category, .cancellation)
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertTrue(fixture.recorder.payloads.isEmpty)
    }

    func testIssue96PendingPayloadReadAllowsMainActor() async throws {
        try await runIssue96PendingPayloadRead(invalidateFIFO: false)
    }

    func testIssue96PendingPayloadReadRejectsChangedFIFO() async throws {
        try await runIssue96PendingPayloadRead(invalidateFIFO: true)
    }

    func testIssue96AutomaticSleepFIFORetirementBlocksLane() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let barrier = DirectSleepPreparationBarrier()
        defer { barrier.releasePreparation() }
        let runtime = try await makeIssue96Runtime(fixture, barrier: barrier)
        let item = try fixture.outbox.enqueue(
            Data("{\"schema_id\":\"synthetic.independent-upload\"}".utf8),
            receiverIdentity: try XCTUnwrap(fixture.settings.receiverBindingID)
        )
        barrier.startDriver { try fixture.outbox.markUploaded(item) }

        let result = await runtime.viewModel.processAutomaticSyncType(
            "sleep_analysis", pendingGenerations: fixture.generations
        )
        try await barrier.joinDriver()
        await runtime.automaticSyncRuntime.cancelAndWait()

        XCTAssertTrue(barrier.observation().actionBeforeRelease)
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel)?.category, .cancellation)
        XCTAssertTrue(runtime.viewModel.statusIsError)
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertTrue(fixture.recorder.payloads.isEmpty)
    }

    func testIssue96ConnectionChangeDuringSleepPreparationCannotJournalOrAdvanceAnchor() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let barrier = DirectSleepPreparationBarrier()
        defer { barrier.releasePreparation() }
        let runtime = try await makeIssue96Runtime(fixture, barrier: barrier)
        let previousGeneration = fixture.settings.receiverSettingsGenerationToken
        barrier.startDriver {
            try fixture.settings.save(
                receiverURLString: "http://127.0.0.1:8766/v1/batches",
                bearerToken: "synthetic-issue96-replacement-credential",
                rotateBindingID: true
            )
        }

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        try await barrier.joinDriver()
        await runtime.automaticSyncRuntime.cancelAndWait()

        let observation = barrier.observation()
        XCTAssertTrue(observation.entered)
        XCTAssertTrue(observation.actionBeforeRelease, "Connection replacement must happen before preparation completes.")
        XCTAssertNotEqual(fixture.settings.receiverSettingsGenerationToken, previousGeneration)
        try assertIssue96PreparationWasAbandoned(fixture, runtime: runtime)
    }

    func testIssue63PopulatedDailyControlsDeliverSixAndZero() async throws {
        for value in [6.0, 0.0] {
            let fixture = try AutomaticStepsFaultFixture()
            defer { fixture.cleanUp() }
            fixture.completedStepsValue = value
            let runtime = try await makeIssue63Runtime(fixture)
            _ = try fixture.admit(["steps"])

            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

            XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
            XCTAssertEqual(try fixture.acceptedSamples(kind: "daily_aggregate").map(\.value), [value])
            XCTAssertEqual(fixture.dailyRequests, [["steps"]])
            XCTAssertTrue(try fixture.pending().isEmpty)
            XCTAssertTrue(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty)
            await runtime.automaticSyncRuntime.cancelAndWait()
        }
    }

    func testIssue63EmptyStatisticsKeepsDailyObligationAcrossRelaunch() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.emptyStepsDailyRead = true
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeIssue63Runtime(fixture)
        let original = try fixture.admit(["steps"])

        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertEqual(fixture.dailyRequests, [["steps"]])
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)
        XCTAssertEqual(try fixture.pending(), original, "Empty statistics are unknown, not completed daily coverage.")
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        runtime = try await makeIssue63Runtime(fixture)
        XCTAssertEqual(try fixture.pending(), original, "The unfulfilled daily obligation must survive reopening private stores.")
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(fixture.dailyRequests, [["steps"], ["steps"]])
        XCTAssertEqual(try fixture.pending(), original)
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty, "Never synthesize zero from an empty read.")
        await runtime?.automaticSyncRuntime.cancelAndWait()
    }

    func testIssue63ObservationReservedBeforeReadAndStableAcrossRetryAndRestart() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.completedStepsValue = 6
        fixture.captureObservationOrder = true
        fixture.recorder.setFailedStepsSampleKinds(["daily_aggregate"])
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeIssue63Runtime(fixture)
        _ = try fixture.admit(["steps"])

        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(fixture.dailyRequests, [["steps"]])
        let pending = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems()
        let queued = try XCTUnwrap(pending.first, "Populated daily payload must reach the durable outbox before the injected HTTP failure.")
        let queuedBytes = try Data(contentsOf: queued.fileURL)
        let queuedBatch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: queuedBytes)
        XCTAssertEqual(queuedBatch.samples.map(\.value), [6])
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.recorder.setFailedStepsSampleKinds([])
        runtime = try await makeIssue63Runtime(fixture)
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertGreaterThanOrEqual(fixture.recorder.payloads.filter { $0 == queuedBytes }.count, 2, "Retry sends the identical persisted bytes.")
        XCTAssertTrue(fixture.recorder.acceptedPayloads.contains(queuedBytes))
        XCTAssertTrue(try fixture.pending().isEmpty)
        XCTAssertEqual(fixture.ordersBeforeRead.count, 2, "ACK retry must reuse the queued observation without another HealthKit read.")
        _ = try fixture.admit(["steps"])
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        XCTAssertEqual(fixture.ordersBeforeRead.count, 4, "Both raw and statistics readers must be reached on both owners.")
        await runtime?.automaticSyncRuntime.cancelAndWait()

        let firstRawBytes = try XCTUnwrap(fixture.recorder.acceptedPayloads.first)
        let firstRaw = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: firstRawBytes)
        let rawOrder = try issue63Observation(in: firstRaw)
        let dailyOrder = try issue63Observation(in: queuedBatch)
        let latestBytes = try XCTUnwrap(fixture.recorder.acceptedPayloads.last)
        let latest = try issue63Observation(in: JSONDecoder().decode(HealthBridgeBatchV1.self, from: latestBytes))
        XCTAssertEqual(rawOrder.namespace, dailyOrder.namespace)
        XCTAssertEqual(latest.namespace, dailyOrder.namespace, "Restart retains the durable owner namespace.")
        XCTAssertLessThan(rawOrder.sequence, dailyOrder.sequence)
        XCTAssertGreaterThan(latest.sequence, dailyOrder.sequence)
        for (index, order) in [(0, rawOrder), (1, dailyOrder), (3, latest)] {
            guard fixture.ordersBeforeRead.indices.contains(index) else {
                XCTFail("Missing before-read observation at index \(index).")
                continue
            }
            let beforeRead = try XCTUnwrap(fixture.ordersBeforeRead[index])
            XCTAssertEqual(beforeRead.observationNamespace, order.namespace)
            XCTAssertGreaterThan(beforeRead.nextSequence, order.sequence, "Order must already be reserved on disk before the injected reader is entered.")
        }
        XCTAssertFalse(rawOrder.rawIntervals.isEmpty)
        XCTAssertNotNil(dailyOrder.statisticsWindow)
    }

    func testIssue63HistoricalRawChangeExpandsStatisticsBeyondRollingOverlap() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.sampleStart = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -30, to: Date()))
        fixture.completedStepsValue = 6
        let runtime = try await makeIssue63Runtime(fixture)
        let cursors = try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json"))
        try cursors.saveCursorValue(
            HealthBridgeUTCFormatter.string(from: Date().addingTimeInterval(-60)),
            receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
        )
        _ = try fixture.admit(["steps"])

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        let acceptedRaw = try XCTUnwrap(fixture.acceptedSamples(kind: "raw_quantity").first)
        XCTAssertEqual(acceptedRaw.value, 17)
        XCTAssertEqual(try fixture.acceptedSamples(kind: "daily_aggregate").map(\.value), [6])
        let reachedStart = try XCTUnwrap(fixture.dailyWindowStarts.first)
        let affectedDay = Calendar.current.startOfDay(for: fixture.sampleStart)
        XCTAssertLessThanOrEqual(reachedStart, affectedDay, "An accepted historical raw change must not be stranded outside the three-day statistics overlap.")
        await runtime.automaticSyncRuntime.cancelAndWait()
    }

    private func issue63Observation(in batch: HealthBridgeBatchV1) throws -> Issue63ObservationWire {
        let cursor = try XCTUnwrap(batch.sync.cursors.first {
            $0.cursorKind == "daily_projection_observation:steps"
        }, "Successful raw/daily delivery lacks causal observation order and scope.")
        return try JSONDecoder().decode(Issue63ObservationWire.self, from: Data(cursor.cursorValue.utf8))
    }

    private func makeIssue63Runtime(
        _ fixture: AutomaticStepsFaultFixture,
        requestProjectionReadAuthorization: (@MainActor ([String]) async throws -> Void)? = nil
    ) async throws -> HealthBridgeCompanionApplicationRuntime {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw Issue63FixtureError.isolatedHostRequired
        #else
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        fixture.sessions.append(session)
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: defaults,
            settingsStore: fixture.makeSettingsStore(defaults: defaults),
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: fixture.pairingPendingStore,
                installationIDStore: fixture.installationStore,
                cancellationStore: fixture.pairingCancellationStore,
                installationIDGenerator: { "synthetic-issue63-installation" }
            ),
            outbox: try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")),
            receiverClient: ReceiverClient(session: session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: fixture.root.appendingPathComponent("diagnostics.json")),
            readAnchoredStepChanges: { try fixture.readRaw(anchor: $0, start: $1, receivedAt: $2) },
            automaticSyncEligibleTypeCodesForTesting: ["steps"],
            readDailyActivityAggregates: { try fixture.readDaily(types: $0, start: $1, end: $2, calendar: $3) },
            scheduleDirectBackgroundUploads: { fixture.declineBackgroundScheduling() },
            terminalBackgroundPayloadDrain: { true },
            platformBackgroundPayloadDrain: { true },
            requestProjectionReadAuthorization: requestProjectionReadAuthorization
        )
        await viewModel.bootstrap()
        XCTAssertFalse(viewModel.statusIsError, viewModel.statusMessage)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("Issue63 tests must use the injected raw/daily readers.") },
            stopQuery: { _ in }, enableDelivery: { _, completion in completion(false, nil) },
            disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in {} },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
        )
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel, automaticSyncPlatform: platform)
        #endif
    }

    func testIssue83AutomaticSingleRetryableReadMustNotReportSuccess() async throws {
        try await exerciseIssue83AutomaticReadOutcome(eligibleTypeCodes: ["steps"], failRawRead: true)
    }

    func testAutomaticRetainedDirectCursorIsCommittedBeforeNextHealthRead() async throws {
        try await exerciseRetainedDirectCursor(rejectUpload: false)
    }

    func testAutomaticRetainedDirectFailureDoesNotRecollectOrLosePendingWork() async throws {
        try await exerciseRetainedDirectCursor(rejectUpload: true)
    }

    func testAutomaticCorruptDirectFIFOBlocksDeliveryAndUnclassifiedReads() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Build the isolated App test host.")
        #else
        for corruptIndex in 0...1 {
            let fixture = try AutomaticStepsFaultFixture()
            let previousRecorder = PayloadFenceURLProtocol.networkRecorder
            addTeardownBlock { @MainActor in
                fixture.cleanUp()
                PayloadFenceURLProtocol.networkRecorder = previousRecorder
            }
            let types = ["steps", "heart_rate"]
            let runtime = try await makeStepsFaultRuntime(
                fixture, eligibleTypeCodes: types, platformBackgroundPayloadDrain: { true }
            )
            addTeardownBlock { @MainActor in
                runtime.automaticSyncRuntime.stopAdmission()
                await runtime.automaticSyncRuntime.cancelAndWait()
                await runtime.viewModel.waitForBootstrapAndForegroundWork()
            }
            await runtime.viewModel.waitForBootstrapAndForegroundWork()
            let pending = try fixture.admit(types)
            let previousConfirmation = runtime.viewModel.lastAcceptedTransferObservation
            let schedulesBeforeAttempt = fixture.declinedBackgroundSchedules
            let probe = try HealthBridgeBatchEncoder().encode(ConnectionTestBatchFactory.make(now: Date()))
            let outbox = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox"))
            let retained = try outbox.enqueueSequence(
                [probe, probe], receiverIdentity: fixture.receiverBindingID
            )
            guard retained.count == 2 else { return XCTFail("Expected two FIFO items.") }
            let corrupt = Data("invalid queued JSON".utf8)
            try corrupt.write(to: retained[corruptIndex].fileURL, options: .atomic)
            let runID = UUID()

            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh, diagnosticRunID: runID)
            await runtime.viewModel.waitForBootstrapAndForegroundWork()

            let diagnostic = try XCTUnwrap(AutomaticSyncDiagnosticStore(
                fileURL: fixture.root.appendingPathComponent("diagnostics.json")
            ).latestRecord)
            XCTAssertEqual(diagnostic.runID, runID)
            XCTAssertEqual(diagnostic.failure?.stage, .store)
            XCTAssertEqual(try outbox.pendingItems(), retained)
            XCTAssertEqual(try retained.map { try Data(contentsOf: $0.fileURL) },
                           corruptIndex == 0 ? [corrupt, probe] : [probe, corrupt])
            XCTAssertEqual(fixture.recorder.invocationCount, 0)
            XCTAssertEqual(runtime.viewModel.lastAcceptedTransferObservation, previousConfirmation)
            XCTAssertEqual(fixture.declinedBackgroundSchedules, schedulesBeforeAttempt)
            XCTAssertTrue(fixture.readEvents.isEmpty)
            XCTAssertTrue(fixture.quantityReadAnchors.isEmpty)
            XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
            XCTAssertEqual(try fixture.pending(), pending)
        }
        #endif
    }

    private func exerciseRetainedDirectCursor(rejectUpload: Bool) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Build the isolated App test host.")
        #else
        let fixture = try AutomaticStepsFaultFixture()
        let previousRecorder = PayloadFenceURLProtocol.networkRecorder
        addTeardownBlock { @MainActor in
            fixture.cleanUp()
            PayloadFenceURLProtocol.networkRecorder = previousRecorder
        }
        let runtime = try await makeStepsFaultRuntime(
            fixture, eligibleTypeCodes: ["basal_energy"],
            platformBackgroundPayloadDrain: { true }
        )
        addTeardownBlock { @MainActor in
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await runtime.viewModel.waitForBootstrapAndForegroundWork()
        }
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
        let cursorKind = GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "basal_energy")
        try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json"))
            .saveCursorValue(
                fixture.previousAnchor, receiverBindingID: fixture.receiverBindingID,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, cursorKind: cursorKind
            )
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
            samples: [HealthKitQuantitySampleSummary(
                uuid: UUID(), typeCode: "basal_energy", start: fixture.sampleStart,
                end: fixture.sampleStart.addingTimeInterval(60), value: 7
            )],
            selectedTypeCodes: ["basal_energy"], windowStart: fixture.sampleStart,
            windowEnd: fixture.sampleStart.addingTimeInterval(120),
            generatedAt: fixture.sampleStart.addingTimeInterval(120)
        ))
        let payload = try HealthBridgeBatchEncoder().encode(batch)
        let outbox = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox"))
        let retainedItems = try outbox.enqueueSequence(
            [payload], receiverIdentity: fixture.receiverBindingID,
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: fixture.receiverBindingID,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: cursorKind,
                cursorValue: fixture.currentAnchor
            )
        )
        let pending = try fixture.admit(["basal_energy"])
        let schedulesBeforeAttempt = fixture.declinedBackgroundSchedules
        if rejectUpload { fixture.recorder.setResponseStatusCode(500) }
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
        if rejectUpload {
            XCTAssertTrue(fixture.quantityReadAnchors.isEmpty)
            XCTAssertEqual(try outbox.pendingItems(), retainedItems)
            XCTAssertEqual(try fixture.pending(), pending)
            XCTAssertEqual(fixture.recorder.invocationCount, 1)
            XCTAssertEqual(fixture.declinedBackgroundSchedules, schedulesBeforeAttempt)
        } else {
            XCTAssertEqual(fixture.quantityReadAnchors, [fixture.currentAnchor])
        }
        #endif
    }

    func testIssue83AutomaticRetryableStepsThenSuccessfulBasalMustNotReportSuccess() async throws {
        try await exerciseIssue83AutomaticReadOutcome(
            eligibleTypeCodes: ["basal_energy", "steps"], failRawRead: true
        )
    }

    func testIssue83AutomaticAllSelectedReadsSucceedAndRetirePending() async throws {
        try await exerciseIssue83AutomaticReadOutcome(
            eligibleTypeCodes: ["basal_energy", "steps"], failRawRead: false
        )
    }

    private func exerciseIssue83AutomaticReadOutcome(
        eligibleTypeCodes: [String], failRawRead: Bool
    ) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Build the App host and test target with HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST.")
        #else
        let fixture = try AutomaticStepsFaultFixture(sampleStart: Date(timeIntervalSince1970: 1_700_000_000))
        let previousRecorder = PayloadFenceURLProtocol.networkRecorder
        addTeardownBlock { @MainActor in
            fixture.cleanUp()
            PayloadFenceURLProtocol.networkRecorder = previousRecorder
        }
        fixture.failRawRead = failRawRead
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { true },
            executeQuery: { _ in }, stopQuery: { _ in },
            enableDelivery: { _, _ in }, disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in },
            beginBackgroundOwner: { _ in
                fixture.ownersStarted += 1
                return { fixture.ownersFinished += 1 }
            },
            healthDataAvailable: { true }, backgroundDeliveryCoordinator: coordinator
        )
        let runtime = try await makeStepsFaultRuntime(
            fixture, eligibleTypeCodes: eligibleTypeCodes,
            automaticSyncPlatform: platform,
            platformBackgroundPayloadDrain: { fixture.platformDrains += 1; return true }
        )
        // XCTest runs teardown blocks in reverse order, keeping both owners alive until joined.
        addTeardownBlock { @MainActor in
            let foregroundCompletion = runtime.automaticSyncRuntime.foregroundCatchUpCompletion()
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await foregroundCompletion?()
            await runtime.viewModel.waitForBootstrapAndForegroundWork()
            XCTAssertFalse(runtime.viewModel.automaticSyncOwnerIsActive)
            XCTAssertEqual(coordinator.activeObserverCount, 0)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
        }
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
        let settings = BackgroundSyncSettingsStore(
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        )
        XCTAssertTrue(runtime.viewModel.automaticSyncRuntimeIsReady)
        XCTAssertEqual(runtime.viewModel.automaticSyncSelectedEligibleTypeCodes(), eligibleTypeCodes)
        XCTAssertGreaterThan(fixture.platformDrains, 0, "Bootstrap must use the injected platform drain.")
        XCTAssertTrue(fixture.readEvents.isEmpty)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertNil(settings.lastRun)
        XCTAssertTrue(try fixture.pending().isEmpty)
        let original = try fixture.admit(eligibleTypeCodes)
        // Resume at Steps using the production fairness API, before the later daily lane.
        try settings.advanceAutomaticSyncContinuation(after: eligibleTypeCodes[0], in: eligibleTypeCodes)
        let expectedOrder = ["steps"] + eligibleTypeCodes.filter { $0 != "steps" }
        XCTAssertEqual(settings.automaticSyncTypeCodesInContinuationOrder(eligibleTypeCodes), expectedOrder)
        fixture.inspectBeforeACK(eligible: eligibleTypeCodes, admitted: original, acceptedBefore: 0, opportunity: 1)
        let runID = UUID()

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh, diagnosticRunID: runID)
        await runtime.automaticSyncRuntime.waitForForegroundCatchUp()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(fixture.ownersStarted, 1)
        XCTAssertEqual(fixture.ownersFinished, 1)
        XCTAssertFalse(runtime.viewModel.automaticSyncOwnerIsActive)
        XCTAssertEqual(fixture.rawAnchors, [fixture.previousAnchor])
        // Basal Energy can finish the first pass while Steps waits for its raw ACK.
        let successfulDailyTypes = eligibleTypeCodes.filter { $0 != "steps" }
            + eligibleTypeCodes.filter { $0 == "steps" && !failRawRead }
        XCTAssertEqual(fixture.dailyRequests, successfulDailyTypes.map { [$0] })
        XCTAssertEqual(fixture.readEvents,
            ["steps.raw", failRawRead ? "steps.raw.failed" : "steps.raw.succeeded"]
                + successfulDailyTypes.flatMap { ["\($0).daily", "\($0).daily.succeeded"] })
        let raw = try fixture.acceptedSamples(kind: "raw_quantity")
        XCTAssertEqual(raw.map(\.typeCode), failRawRead ? [] : ["steps"])
        XCTAssertEqual(raw.map(\.value), failRawRead ? [] : [17])
        let daily = try fixture.acceptedSamples(kind: "daily_aggregate")
        XCTAssertEqual(daily.map(\.typeCode), successfulDailyTypes)
        XCTAssertEqual(daily.map(\.value), successfulDailyTypes.map { $0 == "steps" ? 4_321.0 : 345.0 })
        let acceptedTypes = try fixture.recorder.acceptedPayloads.flatMap {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0).samples.map(\.typeCode)
        }
        XCTAssertEqual(acceptedTypes, (failRawRead ? [] : ["steps"]) + successfulDailyTypes,
            "Anchored raw Steps must be accepted before the reentry projection.")
        let expectedUploads = successfulDailyTypes.count + (failRawRead ? 0 : 1)
        XCTAssertEqual(fixture.recorder.invocationCount, expectedUploads)
        XCTAssertEqual(fixture.recorder.acceptedPayloads.count, expectedUploads)
        XCTAssertEqual(fixture.recorder.responseInspectionCount, expectedUploads)
        XCTAssertEqual(fixture.recorder.payloads, fixture.recorder.acceptedPayloads)
        XCTAssertEqual(try fixture.stepCursor(), failRawRead ? fixture.previousAnchor : fixture.currentAnchor)
        let remaining = failRawRead ? original.filter { $0.key == "steps" } : [:]
        XCTAssertEqual(try fixture.pending(), remaining)
        XCTAssertTrue(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty)

        let diagnostic = try XCTUnwrap(AutomaticSyncDiagnosticStore(
            fileURL: fixture.root.appendingPathComponent("diagnostics.json")
        ).latestRecord)
        XCTAssertEqual(diagnostic.runID, runID)
        XCTAssertEqual(diagnostic.triggerReason, .scheduledRefresh)
        XCTAssertEqual(diagnostic.admissionResult, .accepted)
        XCTAssertEqual(diagnostic.remainingPendingLaneCount, remaining.count)
        let chain = try XCTUnwrap(diagnostic.causalChain)
        XCTAssertEqual(chain.lanes.compactMap(\.typeCode).sorted(), eligibleTypeCodes)
        XCTAssertTrue(chain.lanes.allSatisfy(\.attempted))
        let steps = try XCTUnwrap(chain.lanes.first { $0.typeCode == "steps" })
        XCTAssertEqual(steps.query, failRawRead ? .failed : .records)
        XCTAssertEqual(steps.delivery, failRawRead ? .notRun : .accepted)
        for type in successfulDailyTypes {
            let lane = try XCTUnwrap(chain.lanes.first { $0.typeCode == type })
            XCTAssertEqual(lane.query, .records)
            XCTAssertEqual(lane.delivery, .accepted)
            XCTAssertTrue(lane.pendingItems.isEmpty)
        }
        let lastRun = try XCTUnwrap(settings.lastRun)
        XCTAssertNotNil(lastRun.finishedAt)
        if failRawRead {
            XCTAssertFalse(lastRun.succeeded, "An attempted read failed and its original generation still needs retry.")
            XCTAssertNotEqual(diagnostic.runOutcome, .completed, "A later successful lane cannot make collection all-success.")
        } else {
            XCTAssertTrue(lastRun.succeeded)
            XCTAssertEqual(lastRun.outcome, .completed)
            XCTAssertEqual(diagnostic.runOutcome, .completed)
        }
        #endif
    }

    func testAutomaticSyncDefaultEligibleTypesMatchRuntimeCatalog() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        let runtime = try await makeStepsFaultRuntime(fixture)
        XCTAssertEqual(
            runtime.viewModel.automaticSyncSelectedEligibleTypeCodes(),
            HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
    }

    func testAutomaticStepsTriggerInputMatrixAcceptsRawAndFreshCompletedDay() async throws {
        for eligible in [["steps"], ["basal_energy", "steps"]] {
            let input = eligible.count == 1 ? "steps" : "steps_and_basal_energy"
            let triggers: [(String, AutomaticSyncReason, AutomaticSyncDiagnosticTriggerReason)] = [
                ("observer", .observer(typeCode: "steps"), .observer),
                ("observerBatch", .observerBatch(typeCodes: Array(eligible.reversed()) + eligible), .observerBatch),
                ("scheduledRefresh", .scheduledRefresh, .scheduledRefresh),
                ("launchCatchUp", .launchCatchUp, .launchCatchUp),
            ]
            for (trigger, reason, diagnosticReason) in triggers {
                let fixture = try AutomaticStepsFaultFixture()
                defer { fixture.cleanUp() }
                let runtime = try await makeStepsFaultRuntime(fixture, eligibleTypeCodes: eligible)
                XCTAssertEqual(runtime.viewModel.automaticSyncSelectedEligibleTypeCodes(), eligible)
                let processed = trigger == "observer" ? ["steps"] : eligible
                for opportunity in 1...2 {
                    let scenario = "\(trigger)/\(input)/opportunity_\(opportunity)"
                    fixture.completedStepsValue = opportunity == 1 ? 4_321 : 5_432
                    fixture.completedBasalEnergyValue = opportunity == 1 ? 345 : 456
                    if reason == .observer(typeCode: "steps") || diagnosticReason == .observerBatch {
                        if opportunity == 1 || diagnosticReason == .observerBatch {
                            _ = try fixture.admit(eligible)
                        } else {
                            try BackgroundSyncSettingsStore(
                                userDefaults: XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
                            ).markPendingObserverTypeCodes(["steps"])
                        }
                    } else {
                        XCTAssertTrue(try fixture.pending().isEmpty, scenario)
                    }
                    let admitted = try fixture.pending()
                    let acceptedBefore = fixture.recorder.acceptedPayloads.count
                    let inspectionsBefore = fixture.recorder.responseInspectionCount
                    let dailyReadsBefore = fixture.dailyRequests.count
                    fixture.inspectBeforeACK(
                        eligible: eligible, admitted: admitted,
                        acceptedBefore: acceptedBefore, opportunity: opportunity
                    )
                    let runID = UUID()

                    await runtime.automaticSyncRuntime.runAutomaticSync(reason: reason, diagnosticRunID: runID)

                    let diagnostic = try XCTUnwrap(AutomaticSyncDiagnosticStore(
                        fileURL: fixture.root.appendingPathComponent("diagnostics.json")
                    ).latestRecord)
                    XCTAssertEqual(diagnostic.runID, runID, scenario)
                    XCTAssertEqual(diagnostic.triggerReason, diagnosticReason, scenario)
                    XCTAssertEqual(diagnostic.admissionResult, .accepted, scenario)
                    XCTAssertNil(diagnostic.failure, scenario)
                    XCTAssertEqual(
                        Array(fixture.dailyRequests.dropFirst(dailyReadsBefore)).map { $0.joined(separator: ",") }.sorted(),
                        processed.sorted(), scenario
                    )
                    XCTAssertEqual(fixture.rawAnchors, opportunity == 1
                        ? [fixture.previousAnchor] : [fixture.previousAnchor, fixture.currentAnchor], scenario)
                    let payloads = Array(fixture.recorder.acceptedPayloads.dropFirst(acceptedBefore))
                    XCTAssertEqual(payloads.count, processed.count + (opportunity == 1 ? 1 : 0), scenario)
                    XCTAssertEqual(fixture.recorder.responseInspectionCount - inspectionsBefore, payloads.count, scenario)
                    XCTAssertEqual(fixture.recorder.payloads, fixture.recorder.acceptedPayloads, scenario)
                    let batches = try payloads.map { try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0) }
                    XCTAssertTrue(batches.allSatisfy { $0.samples.count == 1 }, scenario)
                    let samples = batches.flatMap(\.samples)
                    let raw = samples.filter { $0.metadata["sample_kind"] == "raw_quantity" }
                    let daily = samples.filter { $0.metadata["sample_kind"] == "daily_aggregate" }
                    XCTAssertEqual(raw.map(\.value), opportunity == 1 ? [17] : [], scenario)
                    XCTAssertEqual(raw.map(\.typeCode), opportunity == 1 ? ["steps"] : [], scenario)
                    XCTAssertEqual(daily.map(\.typeCode).sorted(), processed.sorted(), scenario)
                    XCTAssertEqual(raw.count + daily.count, samples.count, scenario)
                    let expected = try XCTUnwrap(fixture.completedStepsDay)
                    for sample in daily {
                        XCTAssertEqual(sample.value, sample.typeCode == "steps"
                            ? fixture.completedStepsValue : fixture.completedBasalEnergyValue, scenario)
                        XCTAssertEqual(sample.unit, sample.typeCode == "steps" ? "count" : "kcal", scenario)
                        XCTAssertEqual(sample.startTime, HealthBridgeUTCFormatter.string(from: expected.dayStart), scenario)
                        XCTAssertEqual(sample.endTime, HealthBridgeUTCFormatter.string(from: expected.dayEnd), scenario)
                        XCTAssertEqual(sample.metadata["aggregation"], "daily_sum", scenario)
                        XCTAssertEqual(sample.metadata["aggregation_completeness"], "complete", scenario)
                        XCTAssertEqual(sample.metadata["source_resolution"], "healthkit_statistics_merged_sources", scenario)
                        XCTAssertEqual(sample.metadata["calendar_day"], expected.calendarDay, scenario)
                        XCTAssertEqual(sample.metadata["time_zone_identifier"], Calendar.current.timeZone.identifier, scenario)
                        let day = try XCTUnwrap(expected.calendarDay).replacingOccurrences(of: "-", with: "")
                        let recordType = sample.typeCode == "steps" ? "steps" : "basal-energy"
                        XCTAssertEqual(sample.clientRecordID, "hk-daily-activity-\(recordType)-\(day)", scenario)
                    }
                    XCTAssertFalse(samples.contains { $0.value == 99 }, "Incomplete today must be excluded: \(scenario)")
                    let allRaw = try fixture.acceptedSamples(kind: "raw_quantity")
                    let allDaily = try fixture.acceptedSamples(kind: "daily_aggregate")
                    XCTAssertEqual(allRaw.count, 1, scenario)
                    XCTAssertTrue(Set(allRaw.map(\.clientRecordID)).isDisjoint(with: allDaily.map(\.clientRecordID)), scenario)
                    XCTAssertEqual(allDaily.filter { $0.typeCode == "steps" }.map(\.value),
                        opportunity == 1 ? [4_321] : [4_321, 5_432], scenario)
                    XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor, scenario)
                    let remaining = try fixture.pending()
                    XCTAssertEqual(remaining, trigger == "observer" ? admitted.filter { $0.key == "basal_energy" } : [:], scenario)
                    XCTAssertEqual(diagnostic.remainingPendingLaneCount, remaining.count, scenario)
                    XCTAssertTrue(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty, scenario)
                    print("ISSUE58_MATRIX \(scenario)")
                }
            }
        }
    }

    func testAutomaticStepsEmptyStatisticsPreservesUnknownObservationAndDailyObligation() async throws {
        try await exerciseAutomaticStepsUnchangedAnchor(expectMergedDaily: false)
    }

    func testCursorlessAutomaticStepsQueuesBothRepresentationsAndRetriesTheSamePayloads() async throws {
        let fixture = try AutomaticStepsFaultFixture(hasInitialAnchor: false)
        defer { fixture.cleanUp() }
        fixture.projectRawSampleDay = true
        fixture.recorder.setFailedStepsSampleKinds(["raw_quantity"])
        var runtime = try await makeStepsFaultRuntime(fixture, platformBackgroundPayloadDrain: { true })
        let pending = try fixture.admit(["steps"])
        let reason = AutomaticSyncReason.observerBatch(typeCodes: ["steps"])
        let outbox = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox"))
        let automaticCursorKind = GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "steps")

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: reason)

        let queued = try outbox.pendingItems().map { try Data(contentsOf: $0.fileURL) }
        let batches = try queued.map { try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0) }
        XCTAssertEqual(batches.flatMap(\.samples).compactMap { $0.metadata["sample_kind"] },
            ["raw_quantity", "daily_aggregate"])
        XCTAssertEqual(fixture.dailyRequests, [["steps"]])
        XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
        XCTAssertEqual(try fixture.pending(), pending)
        let repairStart = try outbox.projectionRepairStart(
            receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            typeCodes: ["steps"]
        )
        XCTAssertTrue(try outbox.hasPendingGenerationRetirements(pending),
            "The retained daily transaction must own retirement before retry. Repair start: \(String(describing: repairStart)).")
        XCTAssertNil(try fixture.stepCursor(kind: automaticCursorKind), "Enqueue alone cannot advance the anchor.")
        XCTAssertNil(try fixture.stepCursor())
        await runtime.automaticSyncRuntime.cancelAndWait()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()

        fixture.recorder.setFailedStepsSampleKinds([])
        runtime = try await makeStepsFaultRuntime(fixture, platformBackgroundPayloadDrain: { true })
        XCTAssertEqual(try fixture.pending(), pending, "Relaunch must preserve the exact dirty generation.")
        XCTAssertTrue(try outbox.hasPendingGenerationRetirements(pending),
            "Relaunch must preserve the daily transaction's retirement marker.")
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: reason)

        XCTAssertEqual(fixture.recorder.acceptedPayloads, queued, "Retry must drain the original FIFO bytes.")
        XCTAssertEqual(fixture.recorder.payloads, [try XCTUnwrap(queued.first)] + queued,
            "Only the initial rejected raw request may be repeated.")
        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.acceptedSamples(kind: "daily_aggregate").map(\.value), [4_321])
        XCTAssertEqual(fixture.rawReadStarts.count, 1)
        XCTAssertEqual(fixture.dailyRequests, [["steps"]])
        XCTAssertEqual(try fixture.pending(), [:], "The ACK for the original daily transaction must retire Steps.")
        XCTAssertNil(try outbox.projectionRepairStart(
            receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            typeCodes: ["steps"]
        ), "The same ACK must settle the completed-day projection repair.")
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.stepCursor(kind: automaticCursorKind), fixture.currentAnchor)
        XCTAssertNil(try fixture.stepCursor(), "A one-day read must not checkpoint foreground history.")
    }

    func testCursorlessAutomaticStepsResumesRawProgressAfterDailyReadFailure() async throws {
        let fixture = try AutomaticStepsFaultFixture(hasInitialAnchor: false)
        defer { fixture.cleanUp() }
        fixture.projectRawSampleDay = true
        fixture.failStepsDailyRead = true
        var runtime = try await makeStepsFaultRuntime(fixture, platformBackgroundPayloadDrain: { true })
        let pending = try fixture.admit(["steps"])
        let reason = AutomaticSyncReason.observerBatch(typeCodes: ["steps"])

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: reason)

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)
        XCTAssertEqual(try fixture.pending(), pending)
        XCTAssertEqual(fixture.rawReadStarts.count, 1)
        XCTAssertNotNil(fixture.rawReadStarts.first ?? nil)
        await runtime.automaticSyncRuntime.cancelAndWait()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()

        fixture.failStepsDailyRead = false
        runtime = try await makeStepsFaultRuntime(fixture, platformBackgroundPayloadDrain: { true })
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: reason)

        XCTAssertEqual(fixture.rawAnchors, [fixture.currentAnchor])
        XCTAssertEqual(fixture.dailyRequests, [["steps"], ["steps"]])
        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.acceptedSamples(kind: "daily_aggregate").map(\.value), [4_321])
        XCTAssertTrue(try fixture.pending().isEmpty)
        XCTAssertNil(try fixture.stepCursor())

        _ = await runtime.viewModel.syncRecentStepCounts()
        let automaticStart = try XCTUnwrap(fixture.rawReadStarts.first ?? nil)
        let foregroundStart = try XCTUnwrap(fixture.rawReadStarts.last ?? nil)
        XCTAssertLessThan(foregroundStart, automaticStart, "Foreground must still read its wider history.")
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
    }

    func testAutomaticStepsRegressionUnchangedRawAnchorDeliversMergedCompletedDay() async throws {
        try await exerciseAutomaticStepsUnchangedAnchor(expectMergedDaily: true)
    }

    func testAutomaticStepsDailyReadFailureKeepsGenerationAcrossRelaunch() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.failStepsDailyRead = true
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])

        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(fixture.dailyRequests.contains(["steps"]))
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)
        XCTAssertEqual(try fixture.pending(), original, "A raw ACK cannot cover the failed daily query.")
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.failStepsDailyRead = false
        runtime = try await makeStepsFaultRuntime(fixture)
        XCTAssertEqual(try fixture.pending(), original, "The original generation must survive reconstruction.")
        let rawReadsBeforeRetry = fixture.rawAnchors.count
        await runtime?.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: try fixture.pending().keys.sorted())
        )

        XCTAssertEqual(fixture.rawAnchors.count, rawReadsBeforeRetry + 1)
        XCTAssertEqual(fixture.rawAnchors.last, fixture.currentAnchor)
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsRawReadFailureRetriesBothRepresentations() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.failRawRead = true
        let runtime = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(fixture.rawAnchors, [fixture.previousAnchor])
        XCTAssertTrue(try fixture.acceptedSamples(kind: "raw_quantity").isEmpty)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        XCTAssertEqual(try fixture.pending(), original, "Daily availability cannot discharge a failed raw read.")

        fixture.failRawRead = false
        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: try fixture.pending().keys.sorted())
        )

        XCTAssertEqual(fixture.rawAnchors, [fixture.previousAnchor, fixture.previousAnchor])
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsDailyReadFailureDoesNotBlockOtherSelectedDailyType() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        let otherType = "basal_energy"
        XCTAssertTrue(HealthBridgeBackgroundSync.dailyActivityTypeCodes.contains(otherType))
        let entry = try XCTUnwrap(HealthKitTypeCatalog.entry(for: otherType))
        XCTAssertEqual(entry.objectKind, .quantity)
        XCTAssertEqual(entry.aggregation, .sum)
        XCTAssertEqual(entry.canonicalUnit, "kcal")
        fixture.failStepsDailyRead = true
        let runtime = try await makeStepsFaultRuntime(fixture)
        XCTAssertTrue(runtime.viewModel.automaticSyncSelectedEligibleTypeCodes().contains(otherType))
        let selected = [otherType, "steps"]
        let original = try fixture.admit(selected)

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: selected))

        XCTAssertTrue(fixture.dailyRequests.contains(["steps"]))
        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        let otherSamples = try fixture.acceptedSamples(kind: "daily_aggregate").filter { $0.typeCode == otherType }
        XCTAssertEqual(otherSamples.map(\.value), [345])
        XCTAssertEqual(otherSamples.first?.unit, "kcal")
        let retained = try fixture.pending()
        XCTAssertEqual(retained, original.filter { $0.key == "steps" })
        XCTAssertNil(retained[otherType])

        fixture.failStepsDailyRead = false
        let dailyReadsBeforeRetry = fixture.dailyRequests.count
        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: retained.keys.sorted())
        )

        XCTAssertEqual(Array(fixture.dailyRequests.dropFirst(dailyReadsBeforeRetry)), [["steps"]])
        XCTAssertEqual(try fixture.acceptedSamples(kind: "daily_aggregate").filter {
            $0.typeCode == otherType
        }.count, 1, "Retry must not broaden the retained Steps selection.")
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsRawTransportFailureKeepsGenerationAcrossRelaunch() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.setFailedStepsSampleKinds(["raw_quantity"])
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])
        let schedulesBeforeFailure = fixture.declinedBackgroundSchedules

        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertTrue(try fixture.acceptedSamples(kind: "raw_quantity").isEmpty)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        XCTAssertEqual(try fixture.pending(), original)
        XCTAssertFalse(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty)
        XCTAssertGreaterThan(fixture.declinedBackgroundSchedules, schedulesBeforeFailure)
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.recorder.setFailedStepsSampleKinds([])
        fixture.failStepsDailyRead = true
        runtime = try await makeStepsFaultRuntime(fixture)
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(fixture.dailyRequests.contains(["steps"]))
        XCTAssertEqual(try fixture.pending(), original, "Restored raw ACK must not cover an uncollected daily representation.")
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)

        fixture.failStepsDailyRead = false
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsDailyTransportFailureDoesNotRetireNewerGeneration() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.setFailedStepsSampleKinds(["daily_aggregate"])
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])
        let schedulesBeforeFailure = fixture.declinedBackgroundSchedules

        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)
        XCTAssertEqual(try fixture.pending(), original, "Queued daily data is not accepted coverage.")
        XCTAssertFalse(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty)
        XCTAssertGreaterThan(fixture.declinedBackgroundSchedules, schedulesBeforeFailure)
        let newer = try fixture.admit(["steps"])
        XCTAssertNotEqual(newer["steps"], original["steps"])
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.recorder.setFailedStepsSampleKinds([])
        fixture.failRawRead = true
        runtime = try await makeStepsFaultRuntime(fixture)
        let rawReadsBeforeRetry = fixture.rawAnchors.count
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "daily_aggregate").filter { $0.typeCode == "steps" }.count, 1)
        XCTAssertEqual(fixture.rawAnchors.count, rawReadsBeforeRetry + 1)
        XCTAssertEqual(try fixture.pending(), newer, "Older daily ACK must not retire the newer failed raw generation.")

        fixture.failRawRead = false
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        try assertStepsFaultCompletion(fixture)
    }

    func testAutomaticStepsLegacyRawRetirementKeepsDailyObligationAcrossRelaunch() async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.setFailedStepsSampleKinds(["raw_quantity"])
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeStepsFaultRuntime(fixture)
        let original = try fixture.admit(["steps"])

        // The old dispatcher invoked this unchanged public worker with its Steps marker.
        // Persist through the real enqueue path; do not edit queue/cursor state afterward.
        let queuedRaw = await runtime?.automaticSyncRuntime.viewModel.syncRecentStepCounts(
            executionMode: .automatic,
            pendingGenerationRetirements: original
        )
        XCTAssertEqual(queuedRaw, true)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        let legacyOutbox = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox"))
        XCTAssertFalse(try legacyOutbox.pendingItems().isEmpty)
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            contentsOf: legacyOutbox.directoryURL.appendingPathComponent(".enqueue-transaction")
        )) as? [String: Any])
        XCTAssertEqual(journal["version"] as? Int, 2)
        let transactions = try XCTUnwrap(journal["transactions"] as? [[String: Any]])
        XCTAssertEqual(transactions.count, 1)
        let transaction = try XCTUnwrap(transactions.first)
        XCTAssertEqual(transaction["pendingGenerationRetirements"] as? [String: Int], original)
        XCTAssertNil(transaction["stepsRawAndDailyCoverage"])
        let checkpoint = try XCTUnwrap(transaction["cursorCheckpoint"] as? [String: Any])
        XCTAssertEqual(checkpoint["cursorKind"] as? String, StepCountSyncBatchFactory.anchoredCursorKind)
        XCTAssertTrue(fixture.dailyRequests.isEmpty)
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.recorder.setFailedStepsSampleKinds([])
        fixture.failStepsDailyRead = true
        runtime = try await makeStepsFaultRuntime(fixture)
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(fixture.dailyRequests.contains(["steps"]), "An inherited raw retirement marker cannot stand for daily collection.")
        XCTAssertEqual(try fixture.pending(), original, "Legacy raw ACK must retain its unfulfilled daily Steps obligation.")
        XCTAssertTrue(try fixture.acceptedSamples(kind: "daily_aggregate").isEmpty)

        fixture.failStepsDailyRead = false
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        try assertStepsFaultCompletion(fixture)
    }

    private func makeStepsFaultRuntime(
        _ fixture: AutomaticStepsFaultFixture,
        eligibleTypeCodes: [String]? = nil,
        automaticSyncPlatform: AutomaticSyncRuntime.Platform? = nil,
        platformBackgroundPayloadDrain: (@MainActor () async -> Bool)? = nil
    ) async throws -> HealthBridgeCompanionApplicationRuntime {
        if automaticSyncPlatform != nil {
            let calendar = Calendar.current
            let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1,
                to: calendar.startOfDay(for: Date())))
            fixture.sampleStart = yesterday.addingTimeInterval(3_600)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        fixture.sessions.append(session)
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let viewModel = try makeViewModel(
            root: fixture.root,
            defaults: defaults,
            settingsStore: fixture.makeSettingsStore(defaults: defaults),
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: fixture.pairingPendingStore,
                installationIDStore: fixture.installationStore,
                cancellationStore: fixture.pairingCancellationStore,
                installationIDGenerator: { "synthetic-steps-fault-installation" }
            ),
            outbox: try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")),
            receiverClient: ReceiverClient(session: session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                fileURL: fixture.root.appendingPathComponent("diagnostics.json")
            ),
            readAnchoredStepChanges: { anchor, start, receivedAt in
                try fixture.readRaw(anchor: anchor, start: start, receivedAt: receivedAt)
            },
            automaticSyncEligibleTypeCodesForTesting: eligibleTypeCodes,
            readDailyActivityAggregates: { types, start, end, calendar in
                try fixture.readDaily(types: types, start: start, end: end, calendar: calendar)
            },
            scheduleDirectBackgroundUploads: {
                await fixture.beforeBackgroundSchedule?()
                return fixture.declineBackgroundScheduling()
            },
            platformBackgroundPayloadDrain: platformBackgroundPayloadDrain,
            readAnchoredQuantityChanges: { typeCode, anchor, start, now in
                fixture.quantityReadAnchors.append(anchor)
                return HealthKitAnchoredQuantityChanges(
                    typeCode: typeCode, samples: [], deletedSamples: [],
                    anchorCursorValue: try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 0)),
                    windowStart: start ?? now, windowEnd: now
                )
            },
            requestProjectionReadAuthorization: { types in
                XCTAssertEqual(types, ["steps"])
            }
        )
        await viewModel.bootstrap()
        return HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel, automaticSyncPlatform: automaticSyncPlatform
        )
    }

    private func assertStepsFaultCompletion(_ fixture: AutomaticStepsFaultFixture) throws {
        XCTAssertEqual(try fixture.acceptedSamples(kind: "raw_quantity").map(\.value), [17])
        let daily = try fixture.acceptedSamples(kind: "daily_aggregate").filter { $0.typeCode == "steps" }
        XCTAssertFalse(daily.isEmpty, "Completion requires an accepted merged daily Steps payload.")
        let expected = try XCTUnwrap(fixture.completedStepsDay)
        for sample in daily {
            XCTAssertEqual(sample.value, 4_321)
            XCTAssertEqual(sample.unit, "count")
            XCTAssertEqual(sample.startTime, HealthBridgeUTCFormatter.string(from: expected.dayStart))
            XCTAssertEqual(sample.endTime, HealthBridgeUTCFormatter.string(from: expected.dayEnd))
            XCTAssertEqual(sample.metadata["aggregation"], "daily_sum")
            XCTAssertEqual(sample.metadata["aggregation_completeness"], "complete")
            XCTAssertEqual(sample.metadata["source_resolution"], "healthkit_statistics_merged_sources")
            XCTAssertEqual(sample.metadata["calendar_day"], expected.calendarDay)
            XCTAssertEqual(sample.metadata["time_zone_identifier"], expected.timeZoneIdentifier)
            let day = try XCTUnwrap(expected.calendarDay).replacingOccurrences(of: "-", with: "")
            XCTAssertEqual(sample.clientRecordID, "hk-daily-activity-steps-\(day)")
        }
        XCTAssertEqual(try fixture.stepCursor(), fixture.currentAnchor)
        XCTAssertTrue(try fixture.pending().isEmpty)
        XCTAssertTrue(try FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty)
    }

    private func exerciseAutomaticStepsUnchangedAnchor(expectMergedDaily: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticStepsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AutomaticStepsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-steps-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let backgroundSyncStore = BackgroundSyncSettingsStore(userDefaults: defaults)
        try backgroundSyncStore.setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let previousAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 41))
        let currentAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 42))
        let cursorStore = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        try cursorStore.saveCursorValue(
            previousAnchor,
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        )
        CoreLaneUploadProofStore(userDefaults: defaults).markUploadedRecords(
            lane: .steps, receiverBindingID: receiverBindingID
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let recorder = PayloadFenceNetworkRecorder()
        PayloadFenceURLProtocol.networkRecorder = recorder
        defer { PayloadFenceURLProtocol.networkRecorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var rawReadCount = 0
        var dailyReadCount = 0
        var statisticsWindows: [HealthBridgeTimeWindow] = []
        var unchangedRun = false
        var expectedCompletedDay: HealthKitDailyActivityAggregate?
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { "synthetic-steps-installation" }
            ),
            outbox: outbox,
            receiverClient: ReceiverClient(session: session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                fileURL: root.appendingPathComponent("diagnostics.json")
            ),
            readAnchoredStepChanges: { anchor, predicateStart, receivedAt in
                rawReadCount += 1
                XCTAssertEqual(anchor, unchangedRun ? currentAnchor : previousAnchor)
                XCTAssertNil(predicateStart)
                let start = receivedAt.addingTimeInterval(-120)
                return HealthKitAnchoredStepChanges(
                    stepSamples: unchangedRun ? [] : [HealthKitStepSampleSummary(
                        uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000058")),
                        start: start,
                        end: receivedAt.addingTimeInterval(-60),
                        count: 17
                    )],
                    deletedStepSamples: [],
                    anchorCursorValue: currentAnchor,
                    windowStart: start,
                    windowEnd: receivedAt
                )
            },
            readDailyActivityAggregates: { typeCodes, start, end, calendar in
                dailyReadCount += 1
                statisticsWindows.append(HealthBridgeTimeWindow(
                    startTime: HealthBridgeUTCFormatter.string(from: start),
                    endTime: HealthBridgeUTCFormatter.string(from: end)
                ))
                XCTAssertEqual(typeCodes, ["steps"])
                XCTAssertEqual(calendar.timeZone, Calendar.current.timeZone)
                guard unchangedRun, expectMergedDaily else { return [] }
                let today = calendar.startOfDay(for: end)
                let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
                let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
                XCTAssertLessThanOrEqual(start, yesterday)
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "yyyy-MM-dd"
                let completedDay = HealthKitDailyActivityAggregate(
                    typeCode: "steps", dayStart: yesterday, dayEnd: today, value: 4_321,
                    calendarDay: formatter.string(from: yesterday),
                    timeZoneIdentifier: calendar.timeZone.identifier
                )
                expectedCompletedDay = completedDay
                return [completedDay, HealthKitDailyActivityAggregate(
                    typeCode: "steps", dayStart: today, dayEnd: tomorrow, value: 99,
                    isComplete: false,
                    calendarDay: formatter.string(from: today),
                    timeZoneIdentifier: calendar.timeZone.identifier
                )]
            }
        )
        await viewModel.bootstrap()
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
        XCTAssertTrue(viewModel.automaticSyncSelectedEligibleTypeCodes().contains("steps"))
        let dailyCursorBefore = try cursorStore.cursorValue(
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
        )
        try backgroundSyncStore.markPendingObserverTypeCodes(["steps"])
        let firstGeneration = try backgroundSyncStore.loadPendingObserverTypeCodeGenerations()
        XCTAssertNotNil(firstGeneration["steps"])
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        let firstBatches = try recorder.payloads.map { try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0) }
        XCTAssertEqual(firstBatches.count, 2)
        let rawBatch = try XCTUnwrap(firstBatches.first)
        XCTAssertEqual(rawBatch.samples.count, 1)
        let rawSample = try XCTUnwrap(rawBatch.samples.first)
        XCTAssertEqual(rawSample.typeCode, "steps")
        XCTAssertEqual(rawSample.value, 17)
        XCTAssertEqual(rawSample.metadata["sample_kind"], "raw_quantity")
        XCTAssertEqual(rawBatch.sync.cursors.first?.cursorKind, StepCountSyncBatchFactory.anchoredCursorKind)
        XCTAssertEqual(try cursorStore.cursorValue(
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), currentAnchor)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try backgroundSyncStore.loadPendingObserverTypeCodeGenerations(), firstGeneration)
        XCTAssertEqual(try BackgroundSyncSettingsStore(userDefaults: defaults)
            .loadPendingObserverTypeCodeGenerations(), firstGeneration)
        let unknownBatch = try XCTUnwrap(firstBatches.last)
        XCTAssertTrue(unknownBatch.samples.isEmpty)
        XCTAssertTrue(unknownBatch.deletedRecords.isEmpty)
        XCTAssertTrue(unknownBatch.workouts.isEmpty)
        XCTAssertTrue(unknownBatch.sleepSessions.isEmpty)
        XCTAssertEqual(unknownBatch.sync.cursors.map(\.cursorKind), ["daily_projection_observation:steps"])
        let rawObservation = try issue63Observation(in: rawBatch)
        let unknownObservation = try issue63Observation(in: unknownBatch)
        XCTAssertEqual(unknownObservation.typeCode, "steps")
        XCTAssertFalse(unknownObservation.namespace.isEmpty)
        XCTAssertEqual(rawObservation.namespace, unknownObservation.namespace)
        XCTAssertGreaterThan(rawObservation.sequence, 0)
        XCTAssertGreaterThan(unknownObservation.sequence, rawObservation.sequence)
        XCTAssertNil(rawObservation.statisticsWindow)
        XCTAssertEqual(rawObservation.rawIntervals.count, 1)
        let rawInterval = try XCTUnwrap(rawObservation.rawIntervals.first)
        XCTAssertEqual(rawInterval.clientRecordID, rawSample.clientRecordID)
        XCTAssertEqual(rawInterval.startTime, rawSample.startTime)
        XCTAssertEqual(rawInterval.endTime, rawSample.endTime)
        XCTAssertTrue(unknownObservation.rawIntervals.isEmpty)
        XCTAssertEqual(unknownObservation.statisticsWindow, try XCTUnwrap(statisticsWindows.first))
        XCTAssertEqual(try cursorStore.cursorValue(
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
        ), dailyCursorBefore)

        unchangedRun = true
        let dailyReadsBefore = dailyReadCount
        try backgroundSyncStore.markPendingObserverTypeCodes(["steps"])
        let secondGeneration = try backgroundSyncStore.loadPendingObserverTypeCodeGenerations()
        XCTAssertGreaterThan(try XCTUnwrap(secondGeneration["steps"]), try XCTUnwrap(firstGeneration["steps"]))
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))

        XCTAssertEqual(rawReadCount, 2)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try cursorStore.cursorValue(
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), currentAnchor)
        let laterBatches = try recorder.payloads.dropFirst(firstBatches.count).map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
        }
        if expectMergedDaily {
            XCTAssertTrue(try backgroundSyncStore.loadPendingObserverTypeCodeGenerations().isEmpty)
            XCTAssertGreaterThan(dailyReadCount, dailyReadsBefore, "An unchanged raw anchor still requires merged daily statistics.")
            XCTAssertEqual(laterBatches.count, 1, "The Steps generation must not retire without delivering its completed-day total.")
            let dailyBatch = try XCTUnwrap(laterBatches.first, "Missing accepted daily Steps payload after the unchanged raw read.")
            let completedDay = try XCTUnwrap(expectedCompletedDay)
            XCTAssertEqual(dailyBatch.samples.count, 1, "Today must not be emitted as a complete day.")
            let sample = try XCTUnwrap(dailyBatch.samples.first)
            XCTAssertEqual(sample.typeCode, "steps")
            XCTAssertEqual(sample.unit, "count")
            XCTAssertEqual(sample.value, 4_321)
            XCTAssertNotEqual(sample.value, rawSample.value)
            XCTAssertEqual(sample.startTime, HealthBridgeUTCFormatter.string(from: completedDay.dayStart))
            XCTAssertEqual(sample.endTime, HealthBridgeUTCFormatter.string(from: completedDay.dayEnd))
            XCTAssertEqual(sample.metadata["sample_kind"], "daily_aggregate")
            XCTAssertEqual(sample.metadata["aggregation"], "daily_sum")
            XCTAssertEqual(sample.metadata["aggregation_completeness"], "complete")
            XCTAssertEqual(sample.metadata["source_resolution"], "healthkit_statistics_merged_sources")
            XCTAssertEqual(sample.metadata["calendar_day"], completedDay.calendarDay)
            XCTAssertEqual(sample.metadata["time_zone_identifier"], completedDay.timeZoneIdentifier)
            XCTAssertEqual(sample.clientRecordID, "hk-daily-activity-steps-\(try XCTUnwrap(completedDay.calendarDay).replacingOccurrences(of: "-", with: ""))")
            XCTAssertEqual(dailyBatch.sync.cursors.first?.cursorKind, DailyActivityAggregateSyncPolicy.cursorKind)
            let completedObservation = try issue63Observation(in: dailyBatch)
            XCTAssertEqual(completedObservation.namespace, unknownObservation.namespace)
            XCTAssertGreaterThan(completedObservation.sequence, unknownObservation.sequence)
        } else {
            XCTAssertEqual(dailyReadCount, 2)
            XCTAssertEqual(laterBatches.count, 1)
            let laterUnknown = try XCTUnwrap(laterBatches.first)
            XCTAssertTrue(laterUnknown.samples.isEmpty)
            XCTAssertTrue(laterUnknown.deletedRecords.isEmpty)
            XCTAssertTrue(laterUnknown.workouts.isEmpty)
            XCTAssertTrue(laterUnknown.sleepSessions.isEmpty)
            XCTAssertEqual(laterUnknown.sync.cursors.map(\.cursorKind), ["daily_projection_observation:steps"])
            let laterObservation = try issue63Observation(in: laterUnknown)
            XCTAssertEqual(laterObservation.typeCode, "steps")
            XCTAssertEqual(laterObservation.namespace, unknownObservation.namespace)
            XCTAssertGreaterThan(laterObservation.sequence, unknownObservation.sequence)
            XCTAssertTrue(laterObservation.rawIntervals.isEmpty)
            XCTAssertEqual(laterObservation.statisticsWindow, try XCTUnwrap(statisticsWindows.last))
            XCTAssertEqual(try backgroundSyncStore.loadPendingObserverTypeCodeGenerations(), secondGeneration)
            XCTAssertEqual(try BackgroundSyncSettingsStore(userDefaults: defaults)
                .loadPendingObserverTypeCodeGenerations(), secondGeneration)
            XCTAssertEqual(try cursorStore.cursorValue(
                receiverBindingID: receiverBindingID,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
            ), dailyCursorBefore)
        }
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
    }

    func testDidFinishLaunchingPreparesHealthKitObserversBeforeAsyncBootstrap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdLaunchObserverPreparationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ColdLaunchObserverPreparationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        let bootstrapEntered = expectation(description: "async bootstrap entered")
        let blocker = BlockingBootstrapCleanup(
            onStart: { bootstrapEntered.fulfill() },
            onCancel: {}
        )
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox")),
            cancelInheritedLegacyUploads: { await blocker.wait() }
        )
        var observerPreparationCompleted = false
        let runtime = HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel,
            backgroundLaunchPreparation: {
                observerPreparationCompleted = true
            }
        )
        XCTAssertTrue(runtime.automaticSyncRuntime.viewModel === viewModel)
        let delegate = HealthBridgeBackgroundURLSessionAppDelegate(
            applicationRuntime: runtime
        )

        let didFinish = delegate.application(
            UIApplication.shared,
            didFinishLaunchingWithOptions: nil
        )

        XCTAssertTrue(didFinish)
        XCTAssertTrue(observerPreparationCompleted)
        let entry = await XCTWaiter.fulfillment(of: [bootstrapEntered], timeout: 2)
        XCTAssertEqual(entry, .completed)
        guard entry == .completed else {
            blocker.release()
            return
        }
        let joinedBootstrap = Task { @MainActor in
            await runtime.bootstrap()
        }
        blocker.release()
        await joinedBootstrap.value
    }

    func testApplicationRuntimeCoalescesBackgroundAndVisibleBootstrapOnOneViewModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationRuntimeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ApplicationRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        let entered = expectation(description: "application-owned bootstrap entered")
        let recorder = BootstrapInvocationRecorder()
        let blocker = BlockingBootstrapCleanup(
            onStart: {
                recorder.recordInvocation()
                entered.fulfill()
            },
            onCancel: {}
        )
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox")),
            cancelInheritedLegacyUploads: { await blocker.wait() }
        )
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
        let delegate = HealthBridgeBackgroundURLSessionAppDelegate(
            applicationRuntime: runtime
        )

        let backgroundLaunch = Task { @MainActor in
            await runtime.bootstrap()
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(entry, .completed)
        guard entry == .completed else {
            backgroundLaunch.cancel()
            return
        }
        let visibleLaunch = Task { @MainActor in
            await runtime.bootstrap()
        }
        await Task.yield()
        blocker.release()
        await backgroundLaunch.value
        await visibleLaunch.value

        XCTAssertTrue(runtime.viewModel === viewModel)
        XCTAssertTrue(delegate.applicationRuntime === runtime)
        XCTAssertEqual(recorder.invocationCount, 1)
    }

    func testAutomaticSyncOwnerPublishesOneCoarseSyncingState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticSyncOwnerUIStateTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AutomaticSyncOwnerUIStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox"))
        )
        var observedStates: [Bool] = []
        let observation = viewModel.$automaticSyncOwnerIsActive.sink {
            observedStates.append($0)
        }

        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        withExtendedLifetime(observation) {}

        XCTAssertEqual(observedStates, [false, true, false])
        XCTAssertFalse(viewModel.syncPresentationIsActive)

        let uploader = BackgroundURLSessionOutboxUploader.shared
        uploader.setAutomaticContinuationAdmissionOpen(true)
        defer { uploader.setAutomaticContinuationAdmissionOpen(false) }
        runtime.automaticSyncRuntime.stopAdmission()
        XCTAssertFalse(uploader.automaticContinuationAdmissionIsOpen)
    }

    func testStaleSleepRecoveryDoesNotBlockLaterStepsQuery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticSleepBootstrapFIFOTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AutomaticSleepBootstrapFIFOTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-sleep-fifo-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let currentGeneration = settingsStore.receiverSettingsGenerationToken
        let staleGeneration = "g0"
        XCTAssertNotEqual(currentGeneration, staleGeneration)

        let backgroundSyncStore = BackgroundSyncSettingsStore(userDefaults: defaults)
        try backgroundSyncStore.setEnabledDurably(true)
        try backgroundSyncStore.markPendingObserverTypeCodes(["sleep_analysis", "steps"])
        XCTAssertEqual(backgroundSyncStore.pendingObserverTypeCodes, ["sleep_analysis", "steps"])
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )

        let installationID = "synthetic-sleep-fifo-installation"
        let sleepSourceKey = "apple_health.phone.\(installationID)"
        let sleepStore = try FileSleepSyncManifestStore(
            fileURL: root.appendingPathComponent("sleep.json")
        )
        let staleReservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: staleGeneration,
            historyDepth: .allAvailable,
            historyStartDate: nil,
            sourceKey: sleepSourceKey,
            baselineResetEpoch: 1,
            identityNamespace: try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")
            )
        )
        let staleTransition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: staleReservation,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [],
                deletedSamples: [],
                anchorCursorValue: "synthetic-stale-sleep-anchor",
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            receiverSettingsGeneration: staleGeneration,
            historyDepth: .allAvailable,
            historyStartDate: nil,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try sleepStore.saveManifest(staleTransition.manifest)
        try sleepStore.savePendingTransition(SleepSyncPendingTransition(
            payload: try HealthBridgeBatchEncoder().encode(staleTransition.batch),
            manifest: staleTransition.manifest,
            receiverBindingID: receiverBindingID,
            connectionGeneration: staleGeneration,
            outboxItemID: "missing-synthetic-sleep-payload.json"
        ))

        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        let cursorStore = try FileSyncCursorStore(
            fileURL: root.appendingPathComponent("cursors.json")
        )
        try cursorStore.saveCursorValue(
            "synthetic-malformed-steps-anchor",
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        )
        CoreLaneUploadProofStore(userDefaults: defaults).markUploadedRecords(
            lane: .steps,
            receiverBindingID: receiverBindingID
        )
        let networkRecorder = PayloadFenceNetworkRecorder()
        networkRecorder.setBeforeResponse { payload, acceptedCount in
            guard acceptedCount == 0 else { return }
            let manifest = try JSONDecoder().decode(
                SleepSyncManifest.self, from: Data(contentsOf: root.appendingPathComponent("sleep.json")))
            let pending = try JSONDecoder().decode(
                SleepSyncPendingTransition.self,
                from: Data(contentsOf: root.appendingPathComponent("sleep.json.pending")))
            XCTAssertEqual(manifest.receiverSettingsGeneration, currentGeneration)
            XCTAssertNil(manifest.anchorCursorValue, "No durable anchor may advance before ACK.")
            XCTAssertEqual(pending.payload, payload)
            XCTAssertEqual(pending.connectionGeneration, currentGeneration)
            XCTAssertEqual(pending.receiverBindingID, receiverBindingID)
        }
        PayloadFenceURLProtocol.networkRecorder = networkRecorder
        defer { PayloadFenceURLProtocol.networkRecorder = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PayloadFenceURLProtocol.self]
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { installationID }
            ),
            outbox: outbox,
            receiverClient: ReceiverClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            readAnchoredSleepChanges: { _, _, receivedAt in
                HealthKitAnchoredSleepChanges(
                    addedSamples: [],
                    deletedSamples: [],
                    anchorCursorValue: "synthetic-bootstrap-sleep-anchor",
                    receivedAt: receivedAt
                )
            }
        )
        await viewModel.bootstrap()
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)

        await runtime.automaticSyncRuntime.runAutomaticSync(
            reason: .observerBatch(typeCodes: ["sleep_analysis", "steps"])
        )

        let replacementManifest = try XCTUnwrap(sleepStore.loadManifest())
        XCTAssertEqual(replacementManifest.receiverSettingsGeneration, currentGeneration)
        XCTAssertEqual(
            replacementManifest.anchorCursorValue,
            "synthetic-bootstrap-sleep-anchor"
        )
        XCTAssertNil(try sleepStore.loadPendingTransition())
        let acceptedBatches = try networkRecorder.acceptedPayloads.map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0)
        }
        XCTAssertTrue(acceptedBatches.contains {
            $0.sync.cursors.contains { $0.cursorValue == "synthetic-bootstrap-sleep-anchor" }
        })
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertGreaterThan(networkRecorder.invocationCount, 0)

        try backgroundSyncStore.markPendingObserverTypeCodes(["sleep_analysis", "steps"])
        var processedTypeCodes: [String] = []
        let engine = AutomaticSyncEngine(
            pendingStore: backgroundSyncStore,
            processType: { typeCode, pendingGenerations in
                processedTypeCodes.append(typeCode)
                return await viewModel.processAutomaticSyncType(
                    typeCode,
                    pendingGenerations: pendingGenerations
                )
            }
        )
        try await engine.requestRun(
            reason: .observerBatch(typeCodes: ["sleep_analysis", "steps"])
        )

        let committedManifest = try XCTUnwrap(sleepStore.loadManifest())
        XCTAssertEqual(committedManifest.receiverSettingsGeneration, currentGeneration)
        XCTAssertEqual(
            committedManifest.anchorCursorValue,
            "synthetic-bootstrap-sleep-anchor"
        )
        let currentTransition = try XCTUnwrap(sleepStore.loadPendingTransition())
        XCTAssertEqual(currentTransition.connectionGeneration, currentGeneration)
        XCTAssertEqual(
            currentTransition.manifest.receiverSettingsGeneration,
            currentGeneration
        )
        let currentOutboxItemID = try XCTUnwrap(currentTransition.outboxItemID)
        XCTAssertNotNil(try outbox.pendingItem(id: currentOutboxItemID))
        XCTAssertEqual(processedTypeCodes, ["sleep_analysis", "steps"])
        XCTAssertTrue(
            viewModel.statusMessage.hasPrefix(
                "Step sync failed: HealthKit anchor cursor was not valid base64."
            ),
            "The later Steps lane must reach its real query path while automatic Sleep finalizes receiver acceptance."
        )
    }

    func testAutomaticSyncDiagnosticStorePersistsCancellationInIOSContainers() throws {
        let manager = FileManager.default
        let applicationSupport = try XCTUnwrap(
            manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        for (label, base) in [
            ("temporary", manager.temporaryDirectory),
            ("application-support", applicationSupport),
        ] {
            let root = base
                .appendingPathComponent("HealthBridgeCompanionAppTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? manager.removeItem(at: root) }
            let store = AutomaticSyncDiagnosticStore(
                fileURL: root.appendingPathComponent("diagnostics.json")
            )
            let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
            draft.noteFailure(.classified(stage: .unknown, isCancellation: true))
            draft.noteCompletion(.interrupted)

            XCTAssertTrue(store.recordFinal(draft.record), label)
            XCTAssertEqual(store.latestRecord?.failure?.category, .cancellation, label)
        }
    }

    func testCancelledBackgroundHandlerFinalizesWithoutBootstrapOrMutatingFIFOAndCursors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "BackgroundHandlerCancellation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true }
        )
        try settings.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-cancellation-credential", rotateBindingID: true
        )
        let binding = try XCTUnwrap(settings.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 3, in: outbox, receiverBindingID: binding)
        let before = try outbox.pendingItems()
        let payloads = try before.map { try Data(contentsOf: $0.fileURL) }
        let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        try cursors.saveCursorValue("synthetic-progress", receiverBindingID: binding, sourceKey: "steps", cursorKind: "anchor")
        let background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.markPendingObserverTypeCodes(["sleep_analysis", "steps"])
        let generations = try background.loadPendingObserverTypeCodeGenerations()
        let diagnostics = AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json"))
        let viewModel = try makeViewModel(
            root: root, defaults: defaults, settingsStore: settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: outbox,
            automaticSyncDiagnosticStore: diagnostics,
            cancelInheritedLegacyUploads: {
                XCTFail("An already expired handler must not start bootstrap payload cleanup")
                return BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
            }
        )
        let entered = expectation(description: "before real background handler")
        let returned = expectation(description: "real handler returned after cancellation finalization")
        var resume: CheckedContinuation<Void, Never>?
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel)
        let task = Task { @MainActor in
            await withCheckedContinuation { resume = $0; entered.fulfill() }
            await runtime.handleBackgroundRefresh()
            XCTAssertEqual(background.lastRun?.outcome, .interrupted)
            XCTAssertEqual(diagnostics.latestRecord?.failure?.category, .cancellation)
            returned.fulfill()
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(entry, .completed)
        guard entry == .completed else { task.cancel(); return }
        task.cancel()
        resume?.resume()
        let exit = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(exit, .completed)
        guard exit == .completed else { return }
        await task.value
        XCTAssertEqual(try outbox.pendingItems(), before)
        XCTAssertEqual(try before.map { try Data(contentsOf: $0.fileURL) }, payloads)
        XCTAssertEqual(try cursors.cursorValue(receiverBindingID: binding, sourceKey: "steps", cursorKind: "anchor"), "synthetic-progress")
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), generations)
        XCTAssertNil(background.lastTaskSchedule, "Disabled automatic sync must not submit a request")
    }

    func testBlockedAutomaticOpportunityCannotRecordCompletedSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockedAutomaticOpportunityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "BlockedAutomaticOpportunityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settings.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-blocked-opportunity-credential",
            rotateBindingID: true
        )
        let background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        try background.markPendingObserverTypeCodes(["steps"])
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let diagnostics = AutomaticSyncDiagnosticStore(
            fileURL: root.appendingPathComponent("diagnostics.json")
        )
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox")),
            automaticSyncDiagnosticStore: diagnostics
        )
        await viewModel.bootstrap()
        let engine = AutomaticSyncEngine(
            pendingStore: background,
            processType: { _, _ in .blocked },
            performOpportunity: { opportunity, processPendingTypes in
                _ = await viewModel.performAutomaticSyncOpportunity(
                    opportunity: opportunity,
                    processPendingTypes: processPendingTypes
                )
            }
        )

        try await engine.requestRun(reason: .observerBatch(typeCodes: ["steps"]))

        let lastRun = try XCTUnwrap(background.lastRun)
        XCTAssertEqual(lastRun.outcome, .interrupted)
        XCTAssertFalse(lastRun.succeeded)
        XCTAssertEqual(diagnostics.latestRecord?.runOutcome, .deferred)
        XCTAssertGreaterThan(diagnostics.latestRecord?.remainingPendingLaneCount ?? 0, 0)
        XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), ["steps": 1])
    }

    func testRuntimeIneligibleGenerationRetiresWithoutBlockingLaterEligibleWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeIneligibleAutomaticTypeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "RuntimeIneligibleAutomaticTypeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settings.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-ineligible-type-credential",
            rotateBindingID: true
        )
        let unavailableTypeCode = "aaa_runtime_unavailable_quantity"
        let background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        try background.markPendingObserverTypeCodes([unavailableTypeCode, "steps"])
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(),
                installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            outbox: outbox
        )
        await viewModel.bootstrap()
        XCTAssertFalse(
            viewModel.automaticSyncSelectedEligibleTypeCodes().contains(unavailableTypeCode)
        )
        var processedTypeCodes: [String] = []
        let engine = AutomaticSyncEngine(
            pendingStore: background,
            processType: { typeCode, pendingGenerations in
                processedTypeCodes.append(typeCode)
                guard typeCode == unavailableTypeCode else { return .noPayload }
                return await viewModel.processAutomaticSyncType(
                    typeCode,
                    pendingGenerations: pendingGenerations
                )
            }
        )

        try await engine.requestRun(reason: .scheduledRefresh)

        XCTAssertEqual(processedTypeCodes, [unavailableTypeCode, "steps"])
        XCTAssertTrue(try background.loadPendingObserverTypeCodeGenerations().isEmpty)

        try background.markPendingObserverTypeCodes([unavailableTypeCode])
        let retainedGenerations = try background.loadPendingObserverTypeCodeGenerations()
        var outboxRetirements = retainedGenerations
        outboxRetirements["synthetic_group_peer"] = 1
        _ = try outbox.enqueueSequence(
            [Data("synthetic-ineligible-retirement".utf8)],
            receiverIdentity: try XCTUnwrap(settings.receiverBindingID),
            pendingGenerationRetirements: outboxRetirements
        )

        let protectedResult = await viewModel.processAutomaticSyncType(
            unavailableTypeCode,
            pendingGenerations: retainedGenerations
        )

        XCTAssertEqual(protectedResult, .payloadEnqueued)
        XCTAssertEqual(
            try background.loadPendingObserverTypeCodeGenerations(),
            retainedGenerations
        )
    }

    func testConfirmedResetDuringPairingTerminalRequestWaitsThenDeletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 36, in: outbox, receiverBindingID: receiverBindingID)

        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())

        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox
        )
        XCTAssertEqual(viewModel.pendingOutboxCount, 36)
        XCTAssertEqual(try outbox.pendingItems().count, 36)

        let resetReturned = expectation(description: "confirmed reset returned")
        var resetObservation: ResetObservation?
        var resetObservationError: Error?
        let resetObservationTask = Task { @MainActor in
            for await requestIsActive in viewModel.$terminalTransitionRequestIsActive.values {
                guard requestIsActive,
                      viewModel.terminalTransitionRequestIsActive else {
                    continue
                }
                await viewModel.clearPendingOutbox()
                do {
                    resetObservation = ResetObservation(
                        queuedItemCount: try outbox.pendingItems().count,
                        clearIntentIsActive: outbox.clearIntentIsActive
                    )
                } catch {
                    resetObservationError = error
                }
                resetReturned.fulfill()
                return
            }
        }
        await Task.yield()
        let bootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
        }
        await fulfillment(of: [resetReturned], timeout: 3)
        resetObservationTask.cancel()
        await resetObservationTask.value
        if let resetObservationError {
            throw resetObservationError
        }
        let observation = try XCTUnwrap(resetObservation)

        XCTAssertEqual(observation.queuedItemCount, 0)
        XCTAssertFalse(observation.clearIntentIsActive)

        await bootstrapTask.value
        XCTAssertNil(try pairingStateStore.loadPending())
    }

    func testConfirmedResetCancelsBlockingBootstrapCleanupBeforeWaiting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 36, in: outbox, receiverBindingID: receiverBindingID)

        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())

        let cleanupStarted = expectation(description: "bootstrap cleanup started")
        let transferStore = makeResetTestTransferStore(root: root, defaults: defaults)
        let transfer = LastAcceptedTransferObservation(
            bindingID: receiverBindingID, generation: settingsStore.receiverSettingsGenerationToken,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000), evidenceKind: .directResponse
        )
        transferStore.record(transfer)
        XCTAssertEqual(transferStore.load(bindingID: transfer.bindingID, generation: transfer.generation), transfer)
        let cleanupCancelled = expectation(description: "bootstrap cleanup cancelled")
        let blockingCleanup = BlockingBootstrapCleanup(
            onStart: { cleanupStarted.fulfill() },
            onCancel: { cleanupCancelled.fulfill() }
        )
        defer { blockingCleanup.release() }
        var cleanupInvocationCount = 0
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            cancelInheritedLegacyUploads: {
                cleanupInvocationCount += 1
                if cleanupInvocationCount == 1 {
                    return await blockingCleanup.wait()
                }
                return BackgroundUploadCancellationResult(
                    cancelledCount: 0,
                    fullyFinalized: true
                )
            }
        )

        let bootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
        }
        await fulfillment(of: [cleanupStarted], timeout: 1)

        let resetReturned = expectation(description: "confirmed reset returned")
        let resetTask = Task { @MainActor in
            await viewModel.clearPendingOutbox()
            resetReturned.fulfill()
        }
        await fulfillment(of: [cleanupCancelled, resetReturned], timeout: 1)
        blockingCleanup.release()
        await resetTask.value
        await bootstrapTask.value

        XCTAssertEqual(try outbox.pendingItems().count, 0)
        XCTAssertFalse(outbox.clearIntentIsActive)
        XCTAssertNil(try pairingStateStore.loadPending())
        XCTAssertNil(transferStore.load(bindingID: transfer.bindingID, generation: transfer.generation))
    }

    func testPendingPairingCancellationBlocksConnectionCheckDuringBootstrapCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())

        let cleanupStarted = expectation(description: "bootstrap cleanup started")
        let cleanupCancelled = expectation(description: "bootstrap cleanup cancelled")
        let blockingCleanup = BlockingBootstrapCleanup(
            releaseOnCancellation: false,
            onStart: { cleanupStarted.fulfill() },
            onCancel: { cleanupCancelled.fulfill() }
        )
        defer { blockingCleanup.release() }
        let networkRecorder = PayloadFenceNetworkRecorder()
        PayloadFenceURLProtocol.networkRecorder = networkRecorder
        defer { PayloadFenceURLProtocol.networkRecorder = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PayloadFenceURLProtocol.self]
        var cleanupInvocationCount = 0
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            receiverClient: ReceiverClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            cancelInheritedLegacyUploads: {
                cleanupInvocationCount += 1
                if cleanupInvocationCount == 1 {
                    return await blockingCleanup.wait()
                }
                return BackgroundUploadCancellationResult(
                    cancelledCount: 0,
                    fullyFinalized: true
                )
            }
        )

        let bootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
        }
        await fulfillment(of: [cleanupStarted], timeout: 1)

        let cancellationReturned = expectation(description: "pending pairing cancellation returned")
        let cancellationTask = Task { @MainActor in
            await viewModel.cancelPendingPairing()
            cancellationReturned.fulfill()
        }
        await fulfillment(of: [cleanupCancelled], timeout: 1)
        XCTAssertTrue(try pairingStateStore.hasPendingCancellation())
        XCTAssertNotNil(settingsStore.terminalCancellationExpectedGeneration)

        let originalHistoryDepth = viewModel.healthHistoryDepth
        let competingHistoryDepthOption = originalHistoryDepth == .allAvailable
            ? "last_30_days"
            : "all_available"
        viewModel.setHealthHistoryDepthOption(competingHistoryDepthOption)
        XCTAssertEqual(viewModel.healthHistoryDepth, originalHistoryDepth)

        let statusBeforeConnectionCheck = viewModel.statusMessage
        let statusErrorBeforeConnectionCheck = viewModel.statusIsError
        let settingsGenerationBeforeConnectionCheck =
            settingsStore.receiverSettingsGenerationToken
        let receiverURLBeforeConnectionCheck = settingsStore.receiverURLString
        let pendingItemsBeforeConnectionCheck = try outbox.pendingItems().count
        await viewModel.checkConnection()

        XCTAssertFalse(viewModel.backgroundRefreshSchedulingAdmissionIsOpen)
        XCTAssertEqual(networkRecorder.invocationCount, 0)
        XCTAssertFalse(viewModel.isCheckingConnection)
        XCTAssertEqual(viewModel.statusMessage, statusBeforeConnectionCheck)
        XCTAssertEqual(viewModel.statusIsError, statusErrorBeforeConnectionCheck)
        XCTAssertEqual(
            settingsStore.receiverSettingsGenerationToken,
            settingsGenerationBeforeConnectionCheck
        )
        XCTAssertEqual(settingsStore.receiverURLString, receiverURLBeforeConnectionCheck)
        XCTAssertEqual(try outbox.pendingItems().count, pendingItemsBeforeConnectionCheck)

        await viewModel.bootstrap()
        XCTAssertEqual(cleanupInvocationCount, 1)

        blockingCleanup.release()
        await fulfillment(of: [cancellationReturned], timeout: 1)
        await cancellationTask.value
        await bootstrapTask.value

        XCTAssertNil(try pairingStateStore.loadPending())
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertFalse(viewModel.hasPendingPairing)
    }

    func testPendingPairingCancellationSurvivesRelaunchWhileTerminalDrainIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())
        let cancellationGeneration = settingsStore.receiverSettingsGenerationToken

        let drainStarted = expectation(description: "terminal background drain started")
        let blockingDrain = BlockingBootstrapCleanup(
            releaseOnCancellation: false,
            onStart: { drainStarted.fulfill() },
            onCancel: {}
        )
        defer { blockingDrain.release() }
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            terminalBackgroundPayloadDrain: {
                await blockingDrain.wait().fullyFinalized
            }
        )

        let cancellationTask = Task { @MainActor in
            await viewModel.cancelPendingPairing()
        }
        await fulfillment(of: [drainStarted], timeout: 1)
        XCTAssertTrue(try pairingStateStore.hasPendingCancellation())
        XCTAssertEqual(
            settingsStore.terminalCancellationExpectedGeneration,
            cancellationGeneration
        )
        XCTAssertEqual(
            settingsStore.receiverSettingsGenerationToken,
            cancellationGeneration
        )

        let relaunchedCoordinator = ReceiverPairingCoordinator(
            client: ReceiverClient(),
            stateStore: pairingStateStore,
            settingsStore: settingsStore
        )
        let recovered = try await relaunchedCoordinator.resumePendingPairing()

        XCTAssertNil(recovered)
        XCTAssertNil(try pairingStateStore.loadPending())
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertFalse(try pairingStateStore.hasPendingCancellation())
        XCTAssertNil(settingsStore.terminalCancellationExpectedGeneration)

        cancellationTask.cancel()
        blockingDrain.release()
        await cancellationTask.value
    }

    func testBootstrapFinishesTerminalIntentAfterCommittedClearWithTrustedEmptyOutbox() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let receiverTokenStore = MemoryReceiverTokenStore()
        let preCutoverBackupStore = MemoryReceiverTokenStore()
        let pendingStore = MemoryReceiverTokenStore()
        let installationIDStore = MemoryReceiverTokenStore()
        let cancellationStore = MemoryReceiverTokenStore()
        var synchronizationCount = 0
        let synchronize = {
            synchronizationCount += 1
            return synchronizationCount == 1
        }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: receiverTokenStore,
            preCutoverBackupStore: preCutoverBackupStore,
            synchronize: synchronize
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationIDStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        let cancellationGeneration = settingsStore.receiverSettingsGenerationToken
        let coordinator = ReceiverPairingCoordinator(
            client: ReceiverClient(),
            stateStore: pairingStateStore,
            settingsStore: settingsStore
        )

        let outcome = try coordinator.cancelPendingPairing()

        XCTAssertEqual(outcome, .committedCleanupPending)
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertFalse(try pairingStateStore.hasPendingCancellation())
        XCTAssertEqual(
            settingsStore.terminalCancellationExpectedGeneration,
            cancellationGeneration
        )
        let committedGeneration = settingsStore.receiverSettingsGenerationToken
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        XCTAssertEqual(try outbox.pendingItems().count, 0)

        let relaunchedSettingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: receiverTokenStore,
            preCutoverBackupStore: preCutoverBackupStore,
            synchronize: synchronize
        )
        let relaunchedPairingStateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationIDStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        let relaunchedViewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: relaunchedSettingsStore,
            pairingStateStore: relaunchedPairingStateStore,
            outbox: outbox
        )

        await relaunchedViewModel.bootstrap()

        XCTAssertEqual(synchronizationCount, 3)
        XCTAssertNil(relaunchedSettingsStore.terminalCancellationExpectedGeneration)
        XCTAssertFalse(relaunchedViewModel.hasPendingPairing)
        XCTAssertTrue(try relaunchedSettingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(
            relaunchedSettingsStore.receiverSettingsGenerationToken,
            committedGeneration
        )
        XCTAssertEqual(try outbox.pendingItems().count, 0)
    }

    func testBootstrapRetiresCancellationAfterReceiverRemovalCommitsBeforeMirrors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let receiverTokenStore = MemoryReceiverTokenStore()
        let preCutoverBackupStore = MemoryReceiverTokenStore()
        let pendingStore = MemoryReceiverTokenStore()
        let installationIDStore = MemoryReceiverTokenStore()
        let cancellationStore = MemoryReceiverTokenStore()
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: receiverTokenStore,
            preCutoverBackupStore: preCutoverBackupStore,
            synchronize: { true }
        )
        let receiverURLString = "https://old.example/v1/batches"
        let bearerToken = "synthetic-device-credential"
        try settingsStore.save(
            receiverURLString: receiverURLString,
            bearerToken: bearerToken,
            rotateBindingID: true
        )
        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationIDStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())
        let cancellationGeneration = settingsStore.receiverSettingsGenerationToken
        let coordinator = ReceiverPairingCoordinator(
            client: ReceiverClient(),
            stateStore: pairingStateStore,
            settingsStore: settingsStore
        )
        try coordinator.beginPendingCancellation(
            expectedGeneration: cancellationGeneration
        )

        let mailboxIdentity = MailboxConnectionIdentityV1(
            receiverID: String(repeating: "1", count: 32),
            deviceID: String(repeating: "2", count: 32),
            devicePrincipal: "installation:" + String(repeating: "3", count: 64),
            deviceSigningKeyID: String(repeating: "4", count: 32),
            deviceAgreementKeyID: String(repeating: "5", count: 32),
            receiverSigningKeyID: "6c9a98e60055e4d14e5d591d6b7c1104",
            receiverAgreementKeyID: "cf09eac7ec4fb8e8acc48b7cc1ee77e5",
            receiverSigningPublicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            receiverAgreementPublicKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8",
            opaqueBinding: "Q0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0M",
            connectionGeneration: 1
        )
        let committedPairedMailboxRecord = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: try XCTUnwrap(
                    settingsStore.currentConnectionRecordV2()
                ).localScope.generation,
                bindingID: mailboxIdentity.opaqueBinding
            ),
            mailboxIdentity: .available(mailboxIdentity),
            activation: .paired(activeTransport: .mailbox),
            transportConfigurations: [
                .directHTTP(
                    activation: .inactive,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: receiverURLString,
                        bearerToken: bearerToken
                    )
                ),
                .mailbox(
                    activation: .active,
                    configuration: MailboxConnectionConfigurationV1()
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedRecord = try encoder.encode(committedPairedMailboxRecord)
        try receiverTokenStore.saveToken(
            "health-bridge-connection-v2:" + encodedRecord.base64EncodedString()
        )

        let relaunchedSettingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: receiverTokenStore,
            preCutoverBackupStore: preCutoverBackupStore,
            synchronize: { true }
        )
        let relaunchedPairingStateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationIDStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        XCTAssertEqual(try outbox.pendingItems().count, 0)
        XCTAssertEqual(
            relaunchedSettingsStore.terminalCancellationExpectedGeneration,
            cancellationGeneration
        )
        XCTAssertEqual(
            relaunchedSettingsStore.receiverSettingsGenerationToken,
            cancellationGeneration
        )
        XCTAssertEqual(
            try relaunchedPairingStateStore.pendingCancellationExpectedGeneration(),
            cancellationGeneration
        )
        XCTAssertNotNil(try relaunchedPairingStateStore.loadPending())
        XCTAssertEqual(
            try relaunchedSettingsStore.currentConnectionRecordV2(),
            committedPairedMailboxRecord
        )
        XCTAssertEqual(
            committedPairedMailboxRecord.transportConfigurations,
            [
                .directHTTP(
                    activation: .inactive,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: receiverURLString,
                        bearerToken: bearerToken
                    )
                ),
                .mailbox(
                    activation: .active,
                    configuration: MailboxConnectionConfigurationV1()
                ),
            ]
        )
        XCTAssertEqual(relaunchedSettingsStore.activeTransport, .mailbox)
        XCTAssertFalse(try relaunchedSettingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(
            relaunchedSettingsStore.receiverURLString,
            receiverURLString
        )
        XCTAssertNotEqual(
            relaunchedSettingsStore.receiverURLString,
            ReceiverSettingsStore.defaultReceiverURLString
        )
        XCTAssertEqual(try relaunchedSettingsStore.loadBearerToken(), bearerToken)
        XCTAssertEqual(
            defaults.string(forKey: "receiverURLString"),
            receiverURLString
        )

        let relaunchedViewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: relaunchedSettingsStore,
            pairingStateStore: relaunchedPairingStateStore,
            outbox: outbox
        )
        await relaunchedViewModel.bootstrap()

        XCTAssertNil(relaunchedSettingsStore.terminalCancellationExpectedGeneration)
        XCTAssertNil(try relaunchedPairingStateStore.loadPending())
        XCTAssertFalse(try relaunchedPairingStateStore.hasPendingCancellation())
        XCTAssertFalse(relaunchedViewModel.hasPendingPairing)
        XCTAssertNotEqual(
            try relaunchedSettingsStore.currentConnectionRecordV2(),
            committedPairedMailboxRecord
        )
        XCTAssertNil(relaunchedSettingsStore.activeTransport)
        XCTAssertTrue(try relaunchedSettingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(
            relaunchedSettingsStore.receiverSettingsGenerationToken,
            cancellationGeneration
        )
        XCTAssertEqual(
            relaunchedSettingsStore.receiverURLString,
            ReceiverSettingsStore.defaultReceiverURLString
        )
        XCTAssertEqual(try relaunchedSettingsStore.loadBearerToken(), "")
        XCTAssertNil(defaults.string(forKey: "receiverURLString"))
        XCTAssertEqual(try outbox.pendingItems().count, 0)
    }

    func testConfirmedResetRejectsBootstrapReadmissionWhileCancellationIsDraining() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 36, in: outbox, receiverBindingID: receiverBindingID)

        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )
        _ = try pairingStateStore.stage(invitation: syntheticInvitation())

        let cleanupStarted = expectation(description: "bootstrap cleanup started")
        let cleanupCancelled = expectation(description: "bootstrap cleanup cancelled")
        let blockingCleanup = BlockingBootstrapCleanup(
            releaseOnCancellation: false,
            onStart: { cleanupStarted.fulfill() },
            onCancel: { cleanupCancelled.fulfill() }
        )
        defer { blockingCleanup.release() }
        var cleanupInvocationCount = 0
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            cancelInheritedLegacyUploads: {
                cleanupInvocationCount += 1
                if cleanupInvocationCount == 1 {
                    return await blockingCleanup.wait()
                }
                return BackgroundUploadCancellationResult(
                    cancelledCount: 0,
                    fullyFinalized: true
                )
            }
        )

        let initialBootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
        }
        await fulfillment(of: [cleanupStarted], timeout: 1)

        let resetReturned = expectation(description: "confirmed reset returned")
        let resetTask = Task { @MainActor in
            await viewModel.clearPendingOutbox()
            resetReturned.fulfill()
        }
        await fulfillment(of: [cleanupCancelled], timeout: 1)

        let racingBootstrapReturned = expectation(
            description: "bootstrap requested during reset cancellation was rejected"
        )
        let racingBootstrapTask = Task { @MainActor in
            await viewModel.bootstrap()
            racingBootstrapReturned.fulfill()
        }
        await fulfillment(of: [racingBootstrapReturned], timeout: 0.5)

        blockingCleanup.release()
        await fulfillment(of: [resetReturned], timeout: 2)
        await resetTask.value
        await initialBootstrapTask.value
        await racingBootstrapTask.value

        XCTAssertEqual(try outbox.pendingItems().count, 0)
        XCTAssertFalse(outbox.clearIntentIsActive)
        XCTAssertNil(try pairingStateStore.loadPending())
    }

    func testConfirmedResetPersistsIntentBeforeNonCooperativeBackgroundDrain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthBridgeResetAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "HealthBridgeResetAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(),
            synchronize: { true }
        )
        try settingsStore.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-device-credential",
            rotateBindingID: true
        )
        let receiverBindingID = try XCTUnwrap(settingsStore.receiverBindingID)
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        try enqueueSyntheticItems(count: 36, in: outbox, receiverBindingID: receiverBindingID)

        let mailboxItem = try XCTUnwrap(try outbox.pendingItems().first)
        let mailboxPayload = try Data(contentsOf: mailboxItem.fileURL)
        _ = try outbox.finalizeMailboxEnvelope(
            itemID: mailboxItem.id,
            envelope: Data("synthetic-mailbox-envelope".utf8),
            expectedPayloadSHA256: SHA256.hash(data: mailboxPayload)
                .map { String(format: "%02x", $0) }
                .joined()
        )

        let pairingStateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "synthetic-installation" },
            deviceCredentialGenerator: { "synthetic-pairing-credential" }
        )

        let drainStarted = expectation(description: "background drain started")
        let blockingDrain = BlockingBootstrapCleanup(
            releaseOnCancellation: false,
            onStart: { drainStarted.fulfill() },
            onCancel: {}
        )
        defer { blockingDrain.release() }
        let viewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            terminalBackgroundPayloadDrain: {
                await blockingDrain.wait().fullyFinalized
            },
            terminalRecoveryDrainTimeoutNanoseconds: 100_000_000
        )

        let resetReturned = expectation(description: "confirmed reset returned after bounded drain")
        let resetTask = Task { @MainActor in
            await viewModel.clearPendingOutbox()
            resetReturned.fulfill()
        }
        await fulfillment(of: [drainStarted, resetReturned], timeout: 1)
        await resetTask.value

        XCTAssertEqual(try outbox.pendingItems().count, 36)
        XCTAssertTrue(outbox.terminalResetRequestIsActive)
        XCTAssertFalse(outbox.clearIntentIsActive)

        blockingDrain.release()
        let relaunchedViewModel = try makeViewModel(
            root: root,
            defaults: defaults,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            outbox: outbox,
            terminalBackgroundPayloadDrain: { true },
            terminalRecoveryDrainTimeoutNanoseconds: 100_000_000
        )
        await relaunchedViewModel.bootstrap()

        XCTAssertEqual(try outbox.pendingItems().count, 0)
        XCTAssertFalse(outbox.terminalResetRequestIsActive)
        XCTAssertFalse(outbox.clearIntentIsActive)
    }

    private func enqueueSyntheticItems(
        count: Int,
        in outbox: FileOutbox,
        receiverBindingID: String
    ) throws {
        for sequence in 0..<count {
            let payload = Data("{\"schema_id\":\"synthetic.reset-test\",\"sequence\":\(sequence)}".utf8)
            _ = try outbox.enqueue(payload, receiverIdentity: receiverBindingID)
        }
    }

    func testHTTPPendingPairingRetryStillAdvancesGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HTTPPairingRetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HTTPPairingRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true }
        )
        let state = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore()
        )
        let pending = try state.stage(invitation: syntheticInvitation())
        XCTAssertNil(pending.mailboxBootstrap)
        let recorder = PayloadFenceNetworkRecorder()
        PayloadFenceURLProtocol.networkRecorder = recorder
        defer { PayloadFenceURLProtocol.networkRecorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let viewModel = try makeViewModel(
            root: root, defaults: defaults, settingsStore: settings, pairingStateStore: state,
            outbox: FileOutbox(directory: root.appendingPathComponent("outbox")),
            receiverClient: ReceiverClient(session: session),
            cancelInheritedLegacyUploads: {
                BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
            },
            platformBackgroundPayloadDrain: { true }
        )
        let originalGeneration = settings.receiverSettingsGeneration
        await viewModel.bootstrap()
        await viewModel.waitForBootstrapAndForegroundWork()
        let firstGeneration = settings.receiverSettingsGeneration
        XCTAssertGreaterThan(firstGeneration, originalGeneration)
        XCTAssertEqual(recorder.invocationCount, 1)
        // The fixture's ordinary {"status":"ok"} body is not a pairing completion.
        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertEqual(try state.loadPending(), pending)
        await viewModel.retryPendingPairing()
        await viewModel.waitForBootstrapAndForegroundWork()
        XCTAssertGreaterThan(settings.receiverSettingsGeneration, firstGeneration)
        XCTAssertEqual(recorder.invocationCount, 2)
        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertEqual(try state.loadPending(), pending)
    }

    private func syntheticInvitation() throws -> ReceiverPairingInvitation {
        try ReceiverPairingInvitation(jsonData: Data(
            """
            {
              "schema_id": "health_bridge.receiver_pairing_invitation.v2",
              "schema_version": "2.0.0",
              "label": "Synthetic reset regression",
              "receiver_url": "http://127.0.0.1:8765/v1/batches",
              "redeem_url": "http://127.0.0.1:8765/v1/pairing/redeem",
              "invitation_secret": "synthetic-invitation-credential",
              "expires_at": "2099-01-01T00:00:00Z"
            }
            """.utf8
        ))
    }

    func testAutomaticSleepPendingSaveFailureKeepsDurablePayloadForRetry() async throws {
        try await exerciseSleepStoreFailure(.pendingSave)
    }

    func testAutomaticSleepManifestSaveFailureAfterACKRetainsRetryWork() async throws {
        try await exerciseSleepStoreFailure(.manifestSave)
    }

    func testAutomaticSleepPendingClearFailureAfterACKRetainsRetryWork() async throws {
        try await exerciseSleepStoreFailure(.pendingClear)
    }

    func testAutomaticSleepStoreCancellationRetainsPendingState() async throws {
        let fixture = try SleepStoreFaultFixture(point: .manifestSave)
        defer { fixture.cleanUp() }
        let runtime = try await makeSleepStoreFaultRuntime(fixture)
        fixture.store.failure = CancellationError()
        fixture.store.faultEnabled = true
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel)?.category, .cancellation)
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel)?.stage, .transport)
        XCTAssertEqual(try fixture.store.loadPendingTransition(), fixture.pending)
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.reservation)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(fixture.recorder.invocationCount, 1)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [fixture.pending.payload])
        XCTAssertEqual(try fixture.outbox.pendingItems().count, 1)
        XCTAssertTrue(runtime.viewModel.canSyncSleep)
        fixture.store.faultEnabled = false
        _ = await runtime.viewModel.syncRecentSleepSessions()
        XCTAssertNil(try fixture.store.loadPendingTransition())
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.pending.manifest)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [fixture.pending.payload, fixture.pending.payload])
    }

    func testAutomaticDirectExpiryDuringQuantityDeliveryRetainsLaterSleepJournal() async throws {
        try await exerciseAutomaticDirectExpiry(retainedBacklog: false)
    }

    func testUnansweredRetainedDirectTransferCannotStarveSleepAcrossOpportunities() async throws {
        try await exerciseAutomaticDirectExpiry(retainedBacklog: true)
    }

    func testControlOnlyProbeCannotBlockHealthCollection() async throws {
        try await exerciseAutomaticDirectExpiry(retainedBacklog: true, controlProbeBacklog: true)
    }

    func testNutritionCapabilityCancellationCannotStarveIndependentSleep() async throws {
        try await exerciseNutritionCapabilityCollection(support: nil, independentType: "sleep_analysis")
    }

    func testNutritionCapabilityCancellationCannotStarveIndependentQuantity() async throws {
        try await exerciseNutritionCapabilityCollection(support: nil, independentType: "heart_rate")
    }

    func testNutritionOnlyCollectionStillRequiresFreshSupportedCapabilities() async throws {
        try await exerciseNutritionCapabilityCollection(support: true, independentType: nil)
    }

    func testUnsupportedNutritionCollectionRetainsItsGenerationWithoutReading() async throws {
        try await exerciseNutritionCapabilityCollection(support: false, independentType: nil)
    }

    func testCollectionCancelsStalledBackgroundCapabilityReadWithoutReceiverReply() async throws {
        try await exerciseNutritionCapabilityCollection(
            support: nil, independentType: "heart_rate", scheduledCapabilityRead: true
        )
    }

    private func exerciseNutritionCapabilityCollection(
        support: Bool?, independentType: String?, scheduledCapabilityRead: Bool = false
    ) async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.markPendingObserverTypeCodes(["dietary_protein"])
        if independentType != "sleep_analysis" {
            try fixture.background.clearPendingObserverTypeCodes(
                matching: fixture.generations, typeCodes: ["sleep_analysis"]
            )
        }
        if let independentType, independentType != "sleep_analysis" {
            try fixture.background.markPendingObserverTypeCodes([independentType])
        }
        let generations = try fixture.background.loadPendingObserverTypeCodeGenerations()
        let recorder = fixture.recorder
        var retainedNutritionPayload: Data?
        if scheduledCapabilityRead {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
                samples: [HealthKitQuantitySampleSummary(
                    uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000174")),
                    typeCode: "dietary_protein", start: now, end: now.addingTimeInterval(60), value: 1
                )],
                selectedTypeCodes: ["dietary_protein"], windowStart: now, windowEnd: now.addingTimeInterval(60)
            ))
            let payload = try HealthBridgeBatchEncoder().encode(batch)
            retainedNutritionPayload = payload
            _ = try fixture.outbox.enqueueSequence(
                [payload], receiverIdentity: try XCTUnwrap(fixture.settings.receiverBindingID),
                pendingGenerationRetirements: ["dietary_protein": try XCTUnwrap(generations["dietary_protein"])]
            )
        }
        let schedulingStarted = scheduledCapabilityRead
            ? expectation(description: "Background capability request started") : nil
        if let schedulingStarted {
            recorder.setHeldCapabilityHandler { schedulingStarted.fulfill() }
        }
        if let support { recorder.setCapabilitySupport(support) }
        PayloadFenceURLProtocol.networkRecorder = recorder
        var nutritionReads = 0
        var independentQuantityReads = 0
        let selected = ["dietary_protein"] + (independentType.map { [$0] } ?? [])
        let client = ReceiverClient(session: fixture.session)
        let receiverURL = try XCTUnwrap(URL(string: fixture.settings.receiverURLString))
        let bearer = try fixture.settings.loadBearerToken()
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { DirectSleepPreparationFixture.installationID }
            ),
            outbox: fixture.outbox, receiverClient: client,
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                fileURL: fixture.root.appendingPathComponent("diagnostics.json")
            ),
            sleepManifestStore: fixture.sleep,
            readAnchoredSleepChanges: { anchor, _, now in
                fixture.readAnchors.append(anchor)
                return HealthKitAnchoredSleepChanges(
                    addedSamples: [HealthKitSleepChildSample(
                        uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000172")),
                        stage: "core", start: now.addingTimeInterval(-3600), end: now
                    )],
                    deletedSamples: [], anchorCursorValue: fixture.nextAnchor, receivedAt: now
                )
            },
            automaticSyncEligibleTypeCodesForTesting: selected,
            scheduleDirectBackgroundUploads: {
                if scheduledCapabilityRead {
                    _ = await client.receiverCapabilities(forBatchURL: receiverURL, bearerToken: bearer)
                    if Task.isCancelled { fixture.cancelledSchedulingCount += 1 }
                    try Task.checkCancellation()
                }
                return 0
            },
            terminalBackgroundPayloadDrain: { true }, platformBackgroundPayloadDrain: { true },
            readAnchoredQuantityChanges: { type, _, start, now in
                if NutritionCompatibility.isNutrition(type) {
                    nutritionReads += 1
                    XCTAssertEqual(support, true, "Nutrition must not read before supported capabilities.")
                    XCTAssertGreaterThan(recorder.capabilityRequestCount, 0)
                } else {
                    independentQuantityReads += 1
                    XCTAssertEqual(type, independentType)
                }
                return HealthKitAnchoredQuantityChanges(
                    typeCode: type,
                    samples: [HealthKitQuantitySampleSummary(
                        uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000173")),
                        typeCode: type, start: now.addingTimeInterval(-60), end: now, value: 1
                    )],
                    deletedSamples: [],
                    anchorCursorValue: try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 173)),
                    windowStart: start ?? now.addingTimeInterval(-60), windowEnd: now
                )
            }
        )
        await viewModel.bootstrap()
        if let schedulingStarted {
            viewModel.schedulePendingBackgroundOutboxUploadsIfAllowed()
            await fulfillment(of: [schedulingStarted], timeout: 10)
        }
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("Only synthetic readers may run.") }, stopQuery: { _ in },
            enableDelivery: { _, completion in completion(false, nil) }, disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in },
            beginBackgroundOwner: { expire in
                if support == nil { recorder.setHeldCapabilityHandler { expire() } }
                return {}
            },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
        )
        let runtime = HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel, automaticSyncPlatform: platform
        )
        // Reverse the quantity case's request order; the engine still canonicalizes it.
        let requested = independentType == "heart_rate" ? Array(selected.reversed()) : selected
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: requested))
        await runtime.automaticSyncRuntime.cancelAndWait()
        await viewModel.waitForBootstrapAndForegroundWork()
        XCTAssertGreaterThan(recorder.capabilityRequestCount, 0)
        let remaining = try fixture.background.loadPendingObserverTypeCodeGenerations()
        if let retainedNutritionPayload {
            XCTAssertEqual(fixture.cancelledSchedulingCount, 1)
            XCTAssertEqual(independentQuantityReads, 1)
            XCTAssertEqual(nutritionReads, 0)
            XCTAssertEqual(remaining, generations)
            let items = try fixture.outbox.pendingItems()
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(items.first).fileURL), retainedNutritionPayload)
            XCTAssertTrue(recorder.acceptedPayloads.isEmpty)
            return
        } else if independentType == "sleep_analysis" {
            XCTAssertEqual(fixture.readAnchors, [fixture.previousAnchor])
            XCTAssertEqual(try fixture.sleep.loadManifest()?.anchorCursorValue, fixture.nextAnchor)
            XCTAssertEqual(try fixture.sleep.loadManifest()?.activeChildSamples.count, fixture.children.count + 1)
            XCTAssertNil(try fixture.sleep.loadPendingTransition())
            XCTAssertEqual(recorder.acceptedPayloads.count, 1)
            XCTAssertEqual(remaining, ["dietary_protein": try XCTUnwrap(generations["dietary_protein"])])
        } else if independentType == "heart_rate" {
            XCTAssertEqual(independentQuantityReads, 1)
            XCTAssertTrue(fixture.readAnchors.isEmpty)
            XCTAssertEqual(recorder.acceptedPayloads.count, 1)
            let payload = try XCTUnwrap(recorder.acceptedPayloads.first)
            let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: payload)
            XCTAssertEqual(batch.samples.map(\.typeCode), ["heart_rate"])
            XCTAssertEqual(remaining, ["dietary_protein": try XCTUnwrap(generations["dietary_protein"])])
        } else if support == true {
            XCTAssertEqual(nutritionReads, 1)
            XCTAssertEqual(recorder.acceptedPayloads.count, 1)
            XCTAssertTrue(remaining.isEmpty)
        } else {
            XCTAssertEqual(recorder.acceptedPayloads.count, 0)
            XCTAssertEqual(remaining, generations)
        }
        if support != true { XCTAssertEqual(nutritionReads, 0) }
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
    }

    func testCollectionAfterConcurrentDrainStillSchedulesItsNewPayload() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let olderProbe = try HealthBridgeBatchEncoder().encode(
            ConnectionTestBatchFactory.make(now: Date(timeIntervalSince1970: 1_700_000_000))
        )
        _ = try fixture.outbox.enqueue(
            olderProbe, receiverIdentity: try XCTUnwrap(fixture.settings.receiverBindingID)
        )
        let runtime = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep)
        let viewModel = runtime.viewModel
        let responseGate = HeldFirstProtocolResponse()
        defer { _ = responseGate.release() }
        fixture.recorder.setHeldResponseHandler { responseGate.holdFirst($0) }
        fixture.recorder.setFailedCursorKinds([SleepSyncBatchFactory.anchoredCursorKind])
        let scheduledBefore = fixture.directScheduleCount
        let automaticAdmitted = expectation(description: "Automatic work waits behind the connection test")
        let runID = UUID()
        let diagnosticsURL = fixture.root.appendingPathComponent("diagnostics.json")
        // The direct runtime entry marks this synthetic observer acknowledged before collection.
        let subscription = viewModel.$automaticSyncLaneDiagnosticLine.sink { _ in
            let record = AutomaticSyncDiagnosticStore(fileURL: diagnosticsURL).latestRecord
            if record?.runID == runID, record?.runOutcome == .accepted {
                automaticAdmitted.fulfill()
            }
        }
        defer { subscription.cancel() }

        let connectionTest = Task { await viewModel.sendConnectionTestBatch() }
        await fulfillment(of: [responseGate.held], timeout: 10)
        XCTAssertEqual(try fixture.outbox.pendingItems().count, 2)
        let automatic = Task {
            await runtime.automaticSyncRuntime.runAutomaticSync(
                reason: .observer(typeCode: "sleep_analysis"), diagnosticRunID: runID
            )
        }
        await fulfillment(of: [automaticAdmitted], timeout: 10)
        XCTAssertEqual(try fixture.outbox.pendingItems().count, 2)
        XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
        XCTAssertTrue(fixture.readAnchors.isEmpty)
        XCTAssertTrue(responseGate.release(), "The matching admission must arrive with the response still held.")
        await connectionTest.value
        await automatic.value
        await runtime.automaticSyncRuntime.cancelAndWait()
        await viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(fixture.recorder.acceptedPayloads.count, 2, "Only the two connection probes were accepted.")
        XCTAssertEqual(fixture.readAnchors, [fixture.previousAnchor])
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
        let pending = try XCTUnwrap(fixture.sleep.loadPendingTransition())
        let items = try fixture.outbox.pendingItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, pending.outboxItemID)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertGreaterThan(fixture.directScheduleCount, scheduledBefore,
            "New payloads must be detected inside collection's gate, after the earlier owner drains its items.")
    }

    func testAutomaticDirectCollectionThrowSchedulesOnlyNewDurableWork() async throws {
        for enqueueBeforeThrow in [false, true] {
            let fixture = try AutomaticStepsFaultFixture()
            defer { fixture.cleanUp() }
            let runtime = try await makeStepsFaultRuntime(fixture, platformBackgroundPayloadDrain: { true })
            await runtime.viewModel.waitForBootstrapAndForegroundWork()
            let pending = try fixture.admit(["steps"])
            let outbox = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox"))
            let probe = try HealthBridgeBatchEncoder().encode(ConnectionTestBatchFactory.make(now: Date()))
            _ = try outbox.enqueue(probe, receiverIdentity: fixture.receiverBindingID)
            let scheduledBefore = fixture.declinedBackgroundSchedules

            let viewModel = runtime.viewModel
            let engine = AutomaticSyncEngine(
                pendingStore: BackgroundSyncSettingsStore(
                    userDefaults: try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
                ),
                processType: { type, generations in
                    await viewModel.processAutomaticSyncType(type, pendingGenerations: generations)
                },
                performOpportunity: { opportunity, processPendingTypes in
                    let diagnostic = await viewModel.performAutomaticSyncOpportunity(opportunity: opportunity) {
                        if enqueueBeforeThrow {
                            _ = try await processPendingTypes()
                            XCTAssertEqual(fixture.declinedBackgroundSchedules, scheduledBefore,
                                "Scheduling must wait for the collection gate to release.")
                        }
                        throw AutomaticStepsFaultFixture.ReadFailure.injected
                    }
                    XCTAssertEqual(diagnostic.record.failure?.stage, .store)
                }
            )

            try await engine.requestRun(reason: .observerBatch(typeCodes: ["steps"]))

            let items = try outbox.pendingItems()
            XCTAssertEqual(items.count, enqueueBeforeThrow ? 2 : 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(items.first).fileURL), probe)
            if enqueueBeforeThrow {
                let raw = try JSONDecoder().decode(
                    HealthBridgeBatchV1.self, from: Data(contentsOf: XCTUnwrap(items.last).fileURL)
                )
                XCTAssertEqual(raw.samples.map(\.value), [17])
            }
            XCTAssertEqual(fixture.declinedBackgroundSchedules - scheduledBefore, enqueueBeforeThrow ? 1 : 0)
            XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
            XCTAssertEqual(try fixture.pending(), pending)
            XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        }
    }

    func testConnectionTestResponseArrivingAfterReleaseDoesNotInstallAHold() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let runtime = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep)
        let responseGate = HeldFirstProtocolResponse()
        XCTAssertFalse(responseGate.release(), "No callback has arrived yet.")
        fixture.recorder.setHeldResponseHandler { resume in
            let held = responseGate.holdFirst(resume)
            XCTAssertFalse(held, "An early release must disarm the gate for this late response.")
            if held { _ = responseGate.release() } // Let the red case finish instead of hanging.
            return held
        }

        await runtime.viewModel.sendConnectionTestBatch()

        XCTAssertEqual(fixture.recorder.acceptedPayloads.count, 1)
        XCTAssertFalse(responseGate.release(), "The callback must not be retained or resumed twice.")
    }

    func testExpiredAutomaticCollectionFinishesWhileSchedulingIsSuspended() async throws {
        for expireWhileWaiting in [false, true] {
            try await exerciseExpiredAutomaticCollection(expireWhileWaiting: expireWhileWaiting)
        }
    }

    private func exerciseExpiredAutomaticCollection(expireWhileWaiting: Bool) async throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        let runtime = try await makeStepsFaultRuntime(fixture, platformBackgroundPayloadDrain: { true })
        let viewModel = runtime.viewModel
        await viewModel.waitForBootstrapAndForegroundWork()
        let pending = try fixture.admit(["steps"])
        let outbox = try FileOutbox(directory: fixture.root.appendingPathComponent("outbox"))
        let schedulesBefore = fixture.declinedBackgroundSchedules
        let schedulingEntered = expectation(description: "Independent retry reached the scheduler")
        let timing = expireWhileWaiting ? "after joining scheduler" : "before handoff"
        let ownerFinished = expectation(description: "Owner expired \(timing) finished while retry was held")
        let (release, gate) = AsyncStream<Void>.makeStream()
        var expire: AutomaticSyncEngine.CancelOwner?
        var schedulerReleased = false
        fixture.beforeBackgroundSchedule = {
            schedulingEntered.fulfill()
            if expireWhileWaiting {
                // Both tasks are on the main actor. The scheduler can only run after
                // the owner suspends in the scheduling handoff.
                XCTAssertNotNil(expire)
                expire?()
            }
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
            XCTAssertTrue(schedulerReleased, "Only the test may release the independent retry")
            XCTAssertFalse(Task.isCancelled, "Expiring the owner must not cancel the scheduler")
        }
        let engine = AutomaticSyncEngine(
            pendingStore: BackgroundSyncSettingsStore(
                userDefaults: try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
            ),
            processType: { type, generations in
                await viewModel.processAutomaticSyncType(type, pendingGenerations: generations)
            },
            performOpportunity: { opportunity, processPendingTypes in
                let diagnostic = await viewModel.performAutomaticSyncOpportunity(opportunity: opportunity) {
                    _ = try await processPendingTypes()
                    XCTAssertEqual(try outbox.pendingItems().count, 1)
                    if !expireWhileWaiting {
                        try XCTUnwrap(expire)()
                        try Task.checkCancellation()
                    }
                    throw AutomaticStepsFaultFixture.ReadFailure.injected
                }
                XCTAssertEqual(diagnostic.record.runOutcome, .interrupted)
            },
            startOwner: { cancel in
                expire = cancel
                return { ownerFinished.fulfill() }
            }
        )

        let run = Task { try await engine.requestRun(reason: .observerBatch(typeCodes: ["steps"])) }
        await fulfillment(of: [schedulingEntered, ownerFinished], timeout: 5)
        XCTAssertEqual(fixture.declinedBackgroundSchedules, schedulesBefore, timing)
        schedulerReleased = true
        gate.finish()
        try await run.value
        await viewModel.waitForBootstrapAndForegroundWork()
        XCTAssertEqual(fixture.declinedBackgroundSchedules, schedulesBefore + 1, timing)
        let items = try outbox.pendingItems()
        XCTAssertEqual(items.count, 1)
        let raw = try JSONDecoder().decode(
            HealthBridgeBatchV1.self, from: Data(contentsOf: XCTUnwrap(items.first).fileURL)
        )
        XCTAssertEqual(raw.samples.map(\.value), [17])
        XCTAssertEqual(try fixture.pending(), pending)
        XCTAssertEqual(try fixture.stepCursor(), fixture.previousAnchor)
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
    }

    func testIncompleteTransferCancellationRetainsWorkThenNextOpportunityCollectsSleep() async throws {
        try await exerciseAutomaticDirectExpiry(retainedBacklog: true, initiallyBlockedDrain: true)
    }

    func testAutomaticCollectionRecoversAfterInterruptedSleepDurableBoundaries() async throws {
        for boundary in [Issue96CodecCase.firstJournal, .trackedJournal] {
            try await runIssue96SuspensionFence(boundary, invalidation: .cancel, resumeAfterCancellation: true)
        }
    }

    private func exerciseAutomaticDirectExpiry(
        retainedBacklog: Bool, initiallyBlockedDrain: Bool = false, controlProbeBacklog: Bool = false
    ) async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.markPendingObserverTypeCodes(["heart_rate"])
        let selectedTypes = controlProbeBacklog
            ? ["heart_rate", "sleep_analysis", "steps"] : ["heart_rate", "sleep_analysis"]
        if controlProbeBacklog { try fixture.background.markPendingObserverTypeCodes(["steps"]) }
        let transferReached = controlProbeBacklog
            ? expectation(description: "Collection releases its gate and reaches both probe transfers") : nil
        transferReached?.expectedFulfillmentCount = 2
        var retainedPayload: Data?
        if retainedBacklog {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let batch: HealthBridgeBatchV1
            if controlProbeBacklog {
                batch = ConnectionTestBatchFactory.make(now: now)
            } else {
                batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeQuantityBatch(
                    samples: [HealthKitQuantitySampleSummary(
                        uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000173")),
                        typeCode: "heart_rate", start: now, end: now.addingTimeInterval(60), value: 71
                    )],
                    selectedTypeCodes: ["heart_rate"], windowStart: now, windowEnd: now.addingTimeInterval(120),
                    generatedAt: now
                ))
            }
            let payload = try HealthBridgeBatchEncoder().encode(batch)
            retainedPayload = payload
            let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
            _ = try fixture.outbox.enqueueSequence(
                [payload], receiverIdentity: binding,
                cursorCheckpoint: controlProbeBacklog ? nil : FileOutboxCursorCheckpoint(
                    receiverIdentity: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                    cursorKind: GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "heart_rate"),
                    cursorValue: try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 173))
                ),
                pendingGenerationRetirements: controlProbeBacklog ? [:] : ["heart_rate": 1]
            )
            if !controlProbeBacklog {
                try fixture.background.markPendingObserverTypeCodes(["heart_rate"])
            }
        }
        let generations = try fixture.background.loadPendingObserverTypeCodeGenerations()
        var quantityReadCount = 0
        var stepReadCount = 0
        var stepDailyReadCount = 0
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { DirectSleepPreparationFixture.installationID }
            ),
            outbox: fixture.outbox, receiverClient: ReceiverClient(session: fixture.session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(
                fileURL: fixture.root.appendingPathComponent("diagnostics.json")
            ),
            sleepManifestStore: fixture.sleep,
            readAnchoredSleepChanges: { anchor, _, now in
                fixture.readAnchors.append(anchor)
                return HealthKitAnchoredSleepChanges(
                    addedSamples: [], deletedSamples: [],
                    anchorCursorValue: fixture.nextAnchor, receivedAt: now
                )
            },
            readAnchoredStepChanges: { anchor, _, now in
                stepReadCount += 1
                XCTAssertNil(anchor, "A connection probe cannot select a HealthKit anchor.")
                return HealthKitAnchoredStepChanges(
                    stepSamples: [HealthKitStepSampleSummary(
                        uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000175")),
                        start: now.addingTimeInterval(-60), end: now, count: 17
                    )],
                    deletedStepSamples: [],
                    anchorCursorValue: try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 175)),
                    windowStart: now.addingTimeInterval(-60), windowEnd: now
                )
            },
            automaticSyncEligibleTypeCodesForTesting: selectedTypes,
            readDailyActivityAggregates: { types, start, end, calendar in
                guard controlProbeBacklog else {
                    XCTFail("Daily Steps was not selected.")
                    return []
                }
                stepDailyReadCount += 1
                XCTAssertEqual(types, ["steps"])
                let today = calendar.startOfDay(for: end)
                let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
                XCTAssertLessThanOrEqual(start, yesterday)
                return [HealthKitDailyActivityAggregate(
                    typeCode: "steps", dayStart: yesterday, dayEnd: today, value: 123,
                    timeZoneIdentifier: calendar.timeZone.identifier
                )]
            },
            scheduleDirectBackgroundUploads: { 0 },
            terminalBackgroundPayloadDrain: { true },
            platformBackgroundPayloadDrain: { fixture.platformDrainReady },
            readAnchoredQuantityChanges: { type, _, start, now in
                quantityReadCount += 1
                return HealthKitAnchoredQuantityChanges(
                    typeCode: type,
                    samples: [HealthKitQuantitySampleSummary(
                        uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000171")),
                        typeCode: type, start: now, end: now, value: 70
                    )],
                    deletedSamples: [],
                    anchorCursorValue: try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 171)),
                    windowStart: start ?? now, windowEnd: now
                )
            }
        )
        await viewModel.bootstrap()
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("Only synthetic readers may run.") }, stopQuery: { _ in },
            enableDelivery: { _, completion in completion(false, nil) }, disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in },
            beginBackgroundOwner: { expire in
                if retainedBacklog {
                    fixture.recorder.setHeldResponseHandler { _ in
                        transferReached?.fulfill()
                        expire()
                        return true
                    }
                } else {
                    fixture.recorder.setBeforeResponse { _, _ in expire() }
                }
                return {}
            },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
        )
        let runtime = HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel, automaticSyncPlatform: platform
        )

        if initiallyBlockedDrain {
            XCTAssertTrue(viewModel.canSyncSleep, "Bootstrap must finish before testing an incomplete collection drain.")
            fixture.platformDrainReady = false
            await runtime.automaticSyncRuntime.runAutomaticSync(
                reason: .observerBatch(typeCodes: ["heart_rate", "sleep_analysis"])
            )
            XCTAssertTrue(fixture.readAnchors.isEmpty)
            XCTAssertNil(try fixture.sleep.loadPendingTransition())
            XCTAssertEqual(try fixture.outbox.pendingItems().count, 1)
            XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), generations)
            fixture.platformDrainReady = true
        }
        let runs = Task { @MainActor in
            for _ in 0..<(retainedBacklog ? 2 : 1) {
                guard !Task.isCancelled else { return }
                await runtime.automaticSyncRuntime.runAutomaticSync(
                    reason: .observerBatch(typeCodes: selectedTypes)
                )
            }
        }
        if let transferReached {
            // The timeout is only a deadlock circuit breaker; the transport event synchronizes.
            await fulfillment(of: [transferReached], timeout: 10)
            runs.cancel()
            await runtime.automaticSyncRuntime.cancelAndWait()
        }
        await runs.value
        await runtime.automaticSyncRuntime.cancelAndWait()
        await viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(fixture.readAnchors, [fixture.previousAnchor])
        if controlProbeBacklog {
            XCTAssertEqual(quantityReadCount, 1)
            XCTAssertEqual(stepReadCount, 1)
            XCTAssertEqual(stepDailyReadCount, 1)
        }
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
        let pending = try XCTUnwrap(fixture.sleep.loadPendingTransition())
        XCTAssertEqual(pending.manifest.anchorCursorValue, fixture.nextAnchor)
        XCTAssertEqual(pending.manifest.publishedSessions, fixture.initialManifest.publishedSessions)
        let items = try fixture.outbox.pendingItems()
        let healthItems = controlProbeBacklog ? Array(items.dropFirst()) : items
        let queuedBatches = try healthItems.map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: $0.fileURL))
        }
        let queuedTypes = queuedBatches.flatMap { $0.healthTypes.map(\.typeCode) }
        XCTAssertEqual(Set(queuedTypes), Set(selectedTypes))
        if controlProbeBacklog {
            let queuedStepSamples = queuedBatches.flatMap(\.samples).filter { $0.typeCode == "steps" }
            XCTAssertEqual(queuedStepSamples.map { $0.metadata["sample_kind"] ?? "" },
                ["raw_quantity", "daily_aggregate"], "The bounded projection must queue behind raw Steps.")
            XCTAssertEqual(queuedStepSamples.map(\.value), [17, 123])

            let cursors = try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json"))
            let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
            for kind in [
                GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "steps"),
                StepCountSyncBatchFactory.anchoredCursorKind,
                DailyActivityAggregateSyncPolicy.cursorKind,
            ] {
                XCTAssertNil(try cursors.cursorValue(
                    receiverBindingID: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                    cursorKind: kind
                ), "A held connection probe cannot commit \(kind).")
            }
        }
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), generations)
        if let retainedPayload {
            if !controlProbeBacklog {
                XCTAssertEqual(quantityReadCount, 0, "A retained cursor blocks its own lane, not unrelated Sleep.")
            }
            XCTAssertEqual(items.count, controlProbeBacklog ? 5 : 2,
                "Repeated failed delivery must not duplicate any payload.")
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(items.first).fileURL), retainedPayload)
            XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
            XCTAssertEqual(fixture.recorder.invocationCount, 2)
        }
    }

    func testReplayedSleepJournalDoesNotRetireAYoungerUnreadGeneration() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [],
                anchorCursorValue: fixture.nextAnchor, receivedAt: Date()
            ),
            receiverSettingsGeneration: fixture.settings.receiverSettingsGenerationToken,
            historyDepth: .allAvailable, historyStartDate: nil
        ))
        try fixture.sleep.savePendingTransition(SleepSyncPendingTransition(
            payload: try HealthBridgeBatchEncoder().encode(transition.batch),
            manifest: transition.manifest,
            receiverBindingID: try XCTUnwrap(fixture.settings.receiverBindingID),
            connectionGeneration: fixture.settings.receiverSettingsGenerationToken
        ))
        try fixture.background.markPendingObserverTypeCodes(["sleep_analysis"])
        let younger = try fixture.background.loadPendingObserverTypeCodeGenerations()
        let runtime = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep)

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observer(typeCode: "sleep_analysis"))

        XCTAssertTrue(fixture.readAnchors.isEmpty, "Replaying an old journal is not a fresh HealthKit query.")
        XCTAssertEqual(try fixture.sleep.loadManifest(), transition.manifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), younger)

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observer(typeCode: "sleep_analysis"))
        await runtime.automaticSyncRuntime.cancelAndWait()
        XCTAssertEqual(fixture.readAnchors, [fixture.nextAnchor])
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
    }

    func testForegroundSleepRestartResumesDurableCleanupWithoutEnqueue() async throws {
        try await runForegroundSleepRestart(.cleanupIntent)
    }

    func testForegroundSleepRestartHoldsUncheckedACKBeforeCleanupIntent() async throws {
        try await runForegroundSleepRestart(.uncheckedACK)
    }

    func testForegroundSleepRestartAttemptsEnqueueWhenTrackedItemHasNoACK() async throws {
        try await runForegroundSleepRestart(.noACK)
    }

    func testForegroundSleepWriterRestartAfterDurableACKRetiresObserverGeneration() async throws {
        try await runForegroundSleepRestart(.writerInterruption)
    }

    func testFailedReceiverSettingsSaveKeepsGenerationForPendingSleepCleanup() async throws {
        try await runReceiverSettingsSaveWithPendingSleepCleanup(payloadStillPresent: true)
    }

    func testReceiverSettingsSaveCannotAbandonSleepCleanupWithNoPayloadFile() async throws {
        try await runReceiverSettingsSaveWithPendingSleepCleanup(payloadStillPresent: false)
    }

    func testReceiverSettingsSaveKeepsGenerationForPayloadlessLegacySleepACK() async throws {
        try await runReceiverSettingsSaveWithPendingSleepCleanup(payloadStillPresent: false, legacyUnchecked: true)
    }

    func testColdLegacySleepACKWithoutJournalPausesSleepUntilConfirmedResetFinishes() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires the isolated app test host.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let (item, pending) = try Self.stageSleepForConnectionTransition(
            settings: fixture.settings, outbox: fixture.outbox, store: fixture.sleep,
            previous: fixture.initialManifest, generations: fixture.generations
        )
        XCTAssertNotNil(try fixture.outbox.recordDirectUploadAccepted(
            itemID: item.id, receiverIdentity: pending.receiverBindingID
        ))
        try fixture.sleep.saveManifest(pending.manifest)
        try fixture.sleep.clearPendingTransition(id: pending.id)
        let outbox = try FileOutbox(directory: fixture.outbox.directoryURL)
        let store = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        var drains = 0
        var enqueues = 0
        let runtime = try await makeIssue96CodecRuntime(
            fixture, store: store, outbox: outbox, terminalDrain: {
                drains += 1
                return false
            },
            requestProjectionReadAuthorization: { _ in XCTFail("Sleep authorization reached during hold") },
            beforeBootstrap: { $0.observeSleepEnqueueAttemptForTesting = { enqueues += 1 } }
        )
        let model = runtime.viewModel
        XCTAssertTrue(model.automaticSyncRuntimeIsReady)
        XCTAssertEqual(model.pendingOutboxCount, 0)
        XCTAssertFalse(model.hasPendingSleepTransition)
        XCTAssertFalse(model.hasPendingPrivateStorageRecovery)
        XCTAssertEqual(
            model.acceptedFinalizationRecoveryMessage,
            "The server accepted an earlier upload, but this iPhone no longer has enough evidence to finish its local processing safely. Sleep sync is paused to avoid accidentally sending Sleep twice."
        )
        let automatic = await model.processAutomaticSyncType("sleep_analysis", pendingGenerations: fixture.generations)
        XCTAssertEqual(automatic, .deferredCovering(fixture.generations))
        try fixture.background.markPendingObserverTypeCodes(["steps", "workouts"])
        var visitedTypes: [String] = []
        let engine = AutomaticSyncEngine(
            pendingStore: fixture.background,
            processType: { typeCode, generations in
                visitedTypes.append(typeCode)
                if typeCode == HealthBridgeHealthType.sleepAnalysis.typeCode {
                    return await model.processAutomaticSyncType(typeCode, pendingGenerations: generations)
                }
                return .noPayload
            }
        )
        try await engine.requestRun(reason: .manualSync)
        XCTAssertEqual(visitedTypes, ["sleep_analysis", "steps", "workouts"])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        let manual = await model.syncRecentSleepSessions()
        XCTAssertFalse(manual)
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(fixture.readAnchors.isEmpty)
        XCTAssertEqual(enqueues, 0)

        model.requestBackgroundSyncEnabled(false)
        await model.waitForAutomaticSyncDisableCleanup()
        let connection = try fixture.settings.currentConnectionRecordV2()
        model.receiverURLString = "http://127.0.0.1:8766/v1/batches"
        await model.saveReceiverSettings()
        XCTAssertTrue(model.statusMessage.contains("code=transition_requires_empty_outbox"))
        let disconnect = await model.disconnectReceiver()
        guard case .rejected(_, 0, true) = disconnect else {
            return XCTFail("Expected a preserved connection and zero payloads")
        }
        model.pairingImportText = String(decoding: try JSONEncoder().encode(syntheticInvitation()), as: UTF8.self)
        await model.importPairingText()
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.statusMessage.contains("code=pairing_commit_outbox_not_empty"))
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), connection)
        XCTAssertEqual(drains, 0)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertTrue(try outbox.hasUncheckedDirectAcknowledgment(itemID: item.id, receiverBindingID: pending.receiverBindingID))
        XCTAssertEqual(try store.loadManifest(), pending.manifest)
        XCTAssertNil(try store.loadPendingTransition())
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)

        await model.clearPendingOutbox()
        XCTAssertEqual(drains, 1)
        XCTAssertTrue(outbox.terminalResetRequestIsActive)
        XCTAssertFalse(outbox.clearIntentIsActive)
        XCTAssertEqual(try outbox.acceptedFinalizationHold()?.reason, .proofMissing)
        XCTAssertNotNil(model.acceptedFinalizationRecoveryMessage)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        let reopened = try FileOutbox(directory: outbox.directoryURL)
        let resumed = try await makeIssue96CodecRuntime(fixture, store: store, outbox: reopened)
        XCTAssertFalse(reopened.destructiveRecoveryIsRequested)
        XCTAssertNil(try reopened.acceptedFinalizationHold())
        XCTAssertNil(resumed.viewModel.acceptedFinalizationRecoveryMessage)
        XCTAssertNil(try store.loadManifest())
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        #endif
    }

    func testSaveRechecksPayloadlessSleepReceiptCreatedDuringDrain() async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        let before = try fixture.settings.currentConnectionRecordV2()
        let runtime = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep, terminalDrain: {
            do {
                let (item, pending) = try Self.stageSleepForConnectionTransition(
                    settings: fixture.settings, outbox: fixture.outbox, store: fixture.sleep,
                    previous: fixture.initialManifest, generations: fixture.generations
                )
                _ = try fixture.outbox.recordDirectUploadAccepted(itemID: item.id, receiverIdentity: pending.receiverBindingID)
                try fixture.sleep.clearPendingTransition(id: pending.id)
            } catch { XCTFail("Failed to stage the interrupted acceptance: \(error)") }
            return true
        })
        XCTAssertNil(runtime.viewModel.acceptedFinalizationRecoveryMessage)
        runtime.viewModel.receiverURLString = "http://127.0.0.1:8766/v1/batches"
        await runtime.viewModel.saveReceiverSettings()
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), before)
        XCTAssertTrue(runtime.viewModel.statusIsError)
        XCTAssertNotNil(runtime.viewModel.acceptedFinalizationRecoveryMessage)
        XCTAssertEqual(runtime.viewModel.pendingOutboxCount, 0)
    }

    func testSleepHoldCreatedDuringReadDefersOnlySleepLane() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires the isolated app test host.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        var readCount = 0
        let runtime = try await makeIssue96CodecRuntime(
            fixture,
            store: fixture.sleep,
            readAnchoredSleepChanges: { _, _, receivedAt in
                readCount += 1
                if readCount == 1 {
                    let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
                    let checkpoint = FileOutboxCursorCheckpoint(
                        receiverIdentity: binding,
                        sourceKey: DirectSleepPreparationFixture.installationID,
                        cursorKind: SleepSyncBatchFactory.anchoredCursorKind,
                        cursorValue: fixture.nextAnchor
                    )
                    let item = try XCTUnwrap(fixture.outbox.enqueueSequence(
                        [Data("{}".utf8)],
                        receiverIdentity: binding,
                        cursorCheckpoint: checkpoint,
                        pendingGenerationRetirements: fixture.generations
                    ).first)
                    XCTAssertNotNil(try fixture.outbox.recordDirectUploadAccepted(
                        itemID: item.id,
                        receiverIdentity: binding
                    ))
                    try FileManager.default.removeItem(at: item.fileURL)
                }
                return HealthKitAnchoredSleepChanges(
                    addedSamples: [],
                    deletedSamples: [],
                    anchorCursorValue: fixture.nextAnchor,
                    receivedAt: receivedAt
                )
            }
        )
        let model = runtime.viewModel
        XCTAssertNil(model.acceptedFinalizationRecoveryMessage)
        try fixture.background.markPendingObserverTypeCodes(["steps", "workouts"])
        var visitedTypes: [String] = []
        var sleepResult: AutomaticSyncTypeResult?
        let engine = AutomaticSyncEngine(
            pendingStore: fixture.background,
            processType: { typeCode, generations in
                visitedTypes.append(typeCode)
                if typeCode == HealthBridgeHealthType.sleepAnalysis.typeCode {
                    let result = await model.processAutomaticSyncType(typeCode, pendingGenerations: generations)
                    sleepResult = result
                    return result
                }
                return .noPayload
            }
        )

        try await engine.requestRun(reason: .manualSync)

        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(sleepResult, .deferredCovering(fixture.generations))
        XCTAssertEqual(visitedTypes, ["sleep_analysis", "steps", "workouts"])
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(try fixture.outbox.acceptedFinalizationHold()?.reason, .proofMissing)
        XCTAssertNotNil(model.acceptedFinalizationRecoveryMessage)
        XCTAssertEqual(model.pendingOutboxCount, 0)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        #endif
    }

    func testUnreadableFinalizationEvidenceClearsPublishedSleepRecoveryMessageDuringSave() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires the isolated app test host.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        let (item, pending) = try Self.stageSleepForConnectionTransition(
            settings: fixture.settings, outbox: fixture.outbox, store: fixture.sleep,
            previous: fixture.initialManifest, generations: fixture.generations
        )
        XCTAssertNotNil(try fixture.outbox.recordDirectUploadAccepted(
            itemID: item.id, receiverIdentity: pending.receiverBindingID
        ))
        try fixture.sleep.clearPendingTransition(id: pending.id)
        let runtime = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep)
        let model = runtime.viewModel
        XCTAssertNotNil(model.acceptedFinalizationRecoveryMessage)
        let connection = try fixture.settings.currentConnectionRecordV2()
        let journal = fixture.outbox.directoryURL.appendingPathComponent(".enqueue-transaction")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)

        model.receiverURLString = "http://127.0.0.1:8766/v1/batches"
        await model.saveReceiverSettings()

        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), connection)
        XCTAssertTrue(model.statusIsError)
        XCTAssertNil(model.acceptedFinalizationRecoveryMessage)
        #endif
    }

    func testRejectedSettingsSaveReservationDoesNotInterruptAcceptedSleepWriter() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        let driver = Issue96CodecInvalidationDriver(target: .encodeManifest)
        defer { driver.releaseCodec() }
        let store = try FileSleepSyncManifestStore(
            fileURL: fixture.root.appendingPathComponent("sleep.json"),
            observeCodec: { driver.beforeCodec($0) }
        )
        let runtime = try await makeIssue96CodecRuntime(
            fixture, store: store, terminalDrain: { false }
        )
        let viewModel = runtime.viewModel
        let savedURL = fixture.settings.receiverURLString
        let (item, pending) = try Self.stageSleepForConnectionTransition(
            settings: fixture.settings, outbox: fixture.outbox, store: store,
            previous: fixture.initialManifest, generations: fixture.generations
        )
        let codecEntered = expectation(description: "the accepted response is encoding its manifest")
        driver.start(waitForAdmissionClose: true) {
            codecEntered.fulfill()
        }
        let gate = viewModel.terminalTransitionRequestGateForTesting
        try await gate.acquire()
        let writing = Task { @MainActor in
            await viewModel.syncRecentSleepSessions(executionMode: .foreground)
        }
        await fulfillment(of: [codecEntered], timeout: 5)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [pending.payload])
        XCTAssertEqual(try store.loadPendingTransition(), pending)
        XCTAssertEqual(try store.loadManifest(), fixture.initialManifest)
        XCTAssertNil(try fixture.outbox.directSleepCleanupRecord(receiverBindingID: pending.receiverBindingID))

        let reserved = expectation(description: "Save reserves the request before awaiting the held gate")
        let subscription = viewModel.$terminalTransitionRequestIsActive.filter { $0 }.prefix(1).sink { _ in
            reserved.fulfill()
        }
        viewModel.receiverURLString = "http://127.0.0.1:8766/v1/batches"
        let saving = Task { @MainActor in await viewModel.saveReceiverSettings() }
        await fulfillment(of: [reserved], timeout: 5)
        XCTAssertTrue(viewModel.terminalTransitionRequestIsActive)
        XCTAssertEqual(fixture.settings.receiverURLString, savedURL)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, pending.connectionGeneration)
        XCTAssertEqual(fixture.settings.receiverBindingID, pending.receiverBindingID)
        driver.invalidationApplied()
        _ = await writing.value

        XCTAssertTrue(viewModel.terminalTransitionRequestIsActive, "The writer must finish while Save is still awaiting the real gate.")
        XCTAssertTrue(driver.didInvalidateWhileHeld)
        XCTAssertEqual(try store.loadManifest(), pending.manifest)
        XCTAssertNil(try store.loadPendingTransition())
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
        XCTAssertNil(try fixture.outbox.directFinalizationRecordReady(receiverIdentity: pending.receiverBindingID))
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)

        await gate.release()
        await saving.value
        subscription.cancel()
        driver.releaseCodec()
        try await driver.join().get()
        XCTAssertTrue(viewModel.statusIsError, "The incomplete drain must refuse the changed settings.")
        XCTAssertEqual(fixture.settings.receiverURLString, savedURL)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, pending.connectionGeneration)
        XCTAssertEqual(fixture.settings.receiverBindingID, pending.receiverBindingID)
        XCTAssertEqual(fixture.recorder.payloads, [pending.payload], "The original writer must retire without a second POST.")
        XCTAssertTrue(fixture.readAnchors.isEmpty)
        #endif
    }

    func testPendingPairingCancellationDoesNotWriteMarkersOverPayloadlessSleepCleanup() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        let state = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { DirectSleepPreparationFixture.installationID }
        )
        let runtime = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep, pairingStateStore: state)
        let invitation = try state.stage(invitation: syntheticInvitation())
        let before = try fixture.settings.currentConnectionRecordV2()
        let (item, pending) = try Self.stageSleepForConnectionTransition(
            settings: fixture.settings, outbox: fixture.outbox, store: fixture.sleep,
            previous: fixture.initialManifest, generations: fixture.generations
        )
        let cleanup = try Self.recordPayloadlessSleepCleanup(item, pending: pending, outbox: fixture.outbox, store: fixture.sleep)

        await runtime.viewModel.cancelPendingPairing()

        XCTAssertTrue(runtime.viewModel.statusIsError)
        XCTAssertTrue(runtime.viewModel.statusMessage.contains("code=transition_requires_empty_outbox"))
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), before)
        XCTAssertEqual(try state.loadPending(), invitation)
        XCTAssertFalse(try state.hasPendingCancellation())
        XCTAssertNil(fixture.settings.terminalCancellationExpectedGeneration)
        XCTAssertEqual(try fixture.sleep.loadPendingTransition(), pending)
        XCTAssertEqual(try fixture.outbox.directSleepCleanupRecord(receiverBindingID: pending.receiverBindingID), cleanup)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)

        await runtime.viewModel.retryPrivateStorage()
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), before)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertEqual(try fixture.sleep.loadManifest(), pending.manifest)
        XCTAssertNil(try fixture.outbox.directFinalizationRecordReady(receiverIdentity: pending.receiverBindingID))
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertTrue(fixture.readAnchors.isEmpty)
        #endif
    }

    fileprivate static func stageSleepForConnectionTransition(
        settings: ReceiverSettingsStore, outbox: FileOutbox, store: FileSleepSyncManifestStore,
        previous: SleepSyncManifest, generations: [String: Int]
    ) throws -> (FileOutboxItem, SleepSyncPendingTransition) {
        let binding = try XCTUnwrap(settings.receiverBindingID)
        let generation = settings.receiverSettingsGenerationToken
        let date = Date(timeIntervalSince1970: 1_700_259_200)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: previous,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [], anchorCursorValue: "synthetic-transition-anchor", receivedAt: date
            ),
            receiverSettingsGeneration: generation,
            historyDepth: .allAvailable, historyStartDate: nil, generatedAt: date
        ))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let item = try XCTUnwrap(try outbox.enqueueSequence(
            [payload], receiverIdentity: binding, pendingGenerationRetirements: generations
        ).first)
        let pending = SleepSyncPendingTransition(
            payload: payload, manifest: transition.manifest, receiverBindingID: binding,
            connectionGeneration: generation, outboxItemID: item.id
        )
        try store.savePendingTransition(pending)
        return (item, pending)
    }

    fileprivate static func recordPayloadlessSleepCleanup(
        _ item: FileOutboxItem, pending: SleepSyncPendingTransition, outbox: FileOutbox,
        store: FileSleepSyncManifestStore
    ) throws -> FileOutboxFinalizationRecord {
        try store.saveManifest(pending.manifest)
        let record = try outbox.recordDirectSleepAcceptance(DirectSleepCleanupIntent(
            itemID: item.id, journalID: pending.id, receiverBindingID: pending.receiverBindingID,
            receiverGeneration: pending.connectionGeneration
        ), onNewAcceptance: {})
        try FileManager.default.removeItem(at: item.fileURL)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        return record
    }

    private func runReceiverSettingsSaveWithPendingSleepCleanup(
        payloadStillPresent: Bool, legacyUnchecked: Bool = false
    ) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        try fixture.background.setEnabledDurably(false)
        let runtime = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep)
        let viewModel = runtime.viewModel
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let savedURL = fixture.settings.receiverURLString
        let savedToken = try fixture.settings.loadBearerToken()
        let date = Date(timeIntervalSince1970: 1_700_259_200)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [], anchorCursorValue: fixture.nextAnchor, receivedAt: date
            ),
            receiverSettingsGeneration: generation,
            historyDepth: .allAvailable, historyStartDate: nil, generatedAt: date
        ))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let item = try XCTUnwrap(try fixture.outbox.enqueueSequence(
            [payload], receiverIdentity: binding, pendingGenerationRetirements: fixture.generations
        ).first)
        let pending = SleepSyncPendingTransition(
            payload: payload, manifest: transition.manifest, receiverBindingID: binding,
            connectionGeneration: generation, outboxItemID: item.id
        )
        try fixture.sleep.savePendingTransition(pending)
        try fixture.sleep.saveManifest(pending.manifest)
        let intent: DirectSleepCleanupIntent?
        let record: FileOutboxFinalizationRecord
        if legacyUnchecked {
            intent = nil
            record = try XCTUnwrap(try fixture.outbox.recordDirectUploadAccepted(
                itemID: item.id, receiverIdentity: binding
            ))
        } else {
            let scoped = DirectSleepCleanupIntent(
                itemID: item.id, journalID: pending.id, receiverBindingID: binding, receiverGeneration: generation
            )
            intent = scoped
            record = try fixture.outbox.recordDirectSleepAcceptance(scoped, onNewAcceptance: {})
            if !payloadStillPresent {
                try FileManager.default.removeItem(at: item.fileURL)
            }
        }
        let outbox = try FileOutbox(directory: fixture.outbox.directoryURL)
        let sleep = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        let finalizer = OutboxDeliveryCursorFinalizer(
            outbox: outbox,
            cursorStore: try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("cursors.json")),
            pendingGenerationStore: fixture.background
        )
        func assertRetained(_ phase: String) throws {
            XCTAssertEqual(try sleep.loadPendingTransition(), pending, phase)
            XCTAssertEqual(try sleep.loadManifest(), pending.manifest, phase)
            XCTAssertEqual(try outbox.directFinalizationRecordReady(receiverIdentity: binding), record, phase)
            XCTAssertEqual(try outbox.directSleepCleanupIntent(for: record), intent, phase)
            XCTAssertTrue(try outbox.hasUncheckedDirectAcknowledgment(
                itemID: item.id, receiverBindingID: binding
            ), phase)
            XCTAssertEqual(try outbox.pendingItems().map(\.id), payloadStillPresent ? [item.id] : [], phase)
            if payloadStillPresent {
                XCTAssertEqual(try Data(contentsOf: item.fileURL), payload, phase)
            }
            XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations, phase)
        }

        let wrongBinding = try await finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: "synthetic-wrong-binding", receiverGeneration: generation,
            sleepStore: sleep, validate: {}
        )
        XCTAssertFalse(wrongBinding)
        try assertRetained("Wrong binding with correct generation")
        let wrongGeneration = try await finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: binding, receiverGeneration: "g999999",
            sleepStore: sleep, validate: {}
        )
        XCTAssertFalse(wrongGeneration)
        try assertRetained("Wrong generation with correct binding")

        viewModel.receiverURLString = "http://127.0.0.1:8766/v1/batches"
        await viewModel.saveReceiverSettings()
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        await viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertTrue(viewModel.statusIsError, "A connection change cannot abandon accepted Sleep cleanup.")
        XCTAssertTrue(viewModel.statusMessage.contains("code=transition_requires_empty_outbox"))
        XCTAssertEqual(fixture.settings.receiverURLString, savedURL)
        XCTAssertEqual(try fixture.settings.loadBearerToken(), savedToken)
        XCTAssertEqual(fixture.settings.receiverBindingID, binding)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertNil(try sleep.loadPendingTransition())
        XCTAssertEqual(try sleep.loadManifest(), pending.manifest)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertNil(try outbox.directSleepCleanupIntent(for: record))
        XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: binding))
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertTrue(fixture.readAnchors.isEmpty)
        #endif
    }

    private enum ForegroundSleepRestartState {
        case cleanupIntent, uncheckedACK, noACK, writerInterruption
    }

    #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
    private func interruptForegroundSleepWriter(
        _ fixture: DirectSleepPreparationFixture,
        item: FileOutboxItem,
        pending: SleepSyncPendingTransition
    ) async throws {
        let fault = SleepPayloadUnlinkInterruption(payloadURL: item.fileURL)
        let directory = fixture.outbox.directoryURL
        let interruptedOutbox = try FileOutbox(directory: directory, fileManager: fault)
        var enqueueAttempts = 0
        let installObserver: @MainActor (HealthBridgeCompanionViewModel) -> Void = { model in
            model.observeSleepEnqueueAttemptForTesting = { enqueueAttempts += 1 }
        }
        let binding = pending.receiverBindingID
        var recordedAcceptance: LastAcceptedTransferObservation?
        do {
            let writer = try await makeIssue96CodecRuntime(
                fixture, store: fixture.sleep, outbox: interruptedOutbox, beforeBootstrap: installObserver
            )
            XCTAssertEqual(try interruptedOutbox.pendingItems().map(\.id), [item.id])
            XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
            XCTAssertEqual(try fixture.sleep.loadPendingTransition(), pending)
            XCTAssertEqual(fixture.recorder.invocationCount, 0)
            XCTAssertNil(writer.viewModel.lastAcceptedTransferObservation)

            _ = await writer.viewModel.syncRecentSleepSessions(executionMode: .foreground)
            writer.automaticSyncRuntime.stopAdmission()
            await writer.automaticSyncRuntime.cancelAndWait()
            await writer.viewModel.waitForBootstrapAndForegroundWork()
            recordedAcceptance = writer.viewModel.lastAcceptedTransferObservation
            XCTAssertEqual(recordedAcceptance?.bindingID, binding)
            XCTAssertEqual(recordedAcceptance?.evidenceKind, .directResponse)
        }

        XCTAssertEqual(fault.interruptions, 1, "Stop inside the ACK-driven payload unlink, after removal.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
        XCTAssertEqual(fixture.recorder.invocationCount, 1)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [pending.payload])
        XCTAssertEqual(enqueueAttempts, 0)
        let checked = try interruptedOutbox.hasDirectAcknowledgmentWithSleepChecked(
            itemID: item.id, receiverIdentity: binding
        )
        let unchecked = try interruptedOutbox.hasUncheckedDirectAcknowledgment(
            itemID: item.id, receiverBindingID: binding
        )
        XCTAssertTrue(checked || unchecked, "The real writer persisted the ACK before unlinking the payload.")
        XCTAssertTrue(checked, "The ACK must record that the accepted Sleep journal was checked.")
        XCTAssertEqual(try fixture.sleep.loadManifest(), pending.manifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)

        let recoveredOutbox = try FileOutbox(directory: directory)
        let recoveredStore = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        let restarted = try await makeIssue96CodecRuntime(
            fixture, store: recoveredStore, outbox: recoveredOutbox, beforeBootstrap: installObserver
        )
        restarted.automaticSyncRuntime.stopAdmission()
        await restarted.automaticSyncRuntime.cancelAndWait()
        await restarted.viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(restarted.viewModel.lastAcceptedTransferObservation, recordedAcceptance)
        XCTAssertEqual(try recoveredStore.loadManifest(), pending.manifest)
        XCTAssertNil(try recoveredStore.loadPendingTransition())
        XCTAssertTrue(try recoveredOutbox.pendingItems().isEmpty)
        XCTAssertNil(try recoveredOutbox.directFinalizationRecordReady(receiverIdentity: binding))
        XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertTrue(fixture.readAnchors.isEmpty)
        XCTAssertEqual(enqueueAttempts, 0)
        XCTAssertEqual(fixture.recorder.invocationCount, 1)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [pending.payload])
    }
    #endif

    private func runForegroundSleepRestart(_ state: ForegroundSleepRestartState) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let generation = fixture.settings.receiverSettingsGenerationToken
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let date = Date(timeIntervalSince1970: 1_700_259_200)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [], anchorCursorValue: fixture.nextAnchor, receivedAt: date
            ),
            receiverSettingsGeneration: generation,
            historyDepth: .allAvailable, historyStartDate: nil, generatedAt: date
        ))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        if state == .cleanupIntent {
            // Give bootstrap a ready non-Sleep record so the foreground owner has to resume Sleep.
            let earlier = try XCTUnwrap(try fixture.outbox.enqueueSequence(
                [Data("{}".utf8)], receiverIdentity: binding,
                cursorCheckpoint: FileOutboxCursorCheckpoint(
                    receiverIdentity: binding, sourceKey: "synthetic.issue194",
                    cursorKind: "synthetic_issue194", cursorValue: "synthetic-checkpoint"
                )
            ).first)
            XCTAssertNotNil(try fixture.outbox.recordDirectUploadAccepted(itemID: earlier.id, receiverIdentity: binding))
        }
        let item: FileOutboxItem
        if state == .noACK {
            item = try fixture.outbox.enqueue(payload, receiverIdentity: binding)
            // Model an absent tracked file with no durable acceptance to consult.
            try FileManager.default.removeItem(at: item.fileURL)
        } else {
            item = try XCTUnwrap(try fixture.outbox.enqueueSequence(
                [payload], receiverIdentity: binding, pendingGenerationRetirements: fixture.generations
            ).first)
        }
        let pending = SleepSyncPendingTransition(
            payload: payload, manifest: transition.manifest, receiverBindingID: binding,
            connectionGeneration: generation, outboxItemID: item.id
        )
        try fixture.sleep.savePendingTransition(pending)
        if state == .writerInterruption {
            try await interruptForegroundSleepWriter(fixture, item: item, pending: pending)
            return
        }
        let acceptedRecord: FileOutboxFinalizationRecord?
        if state == .noACK {
            acceptedRecord = nil
        } else {
            let record = try XCTUnwrap(try fixture.outbox.recordDirectUploadAccepted(
                itemID: item.id, receiverIdentity: binding
            ))
            acceptedRecord = record
            if state == .cleanupIntent {
                try fixture.sleep.saveManifest(pending.manifest)
                try fixture.outbox.beginDirectSleepCleanup(DirectSleepCleanupIntent(
                    itemID: item.id, journalID: pending.id,
                    receiverBindingID: binding, receiverGeneration: generation
                ), for: record)
            }
        }

        let outbox = try FileOutbox(directory: fixture.outbox.directoryURL)
        let store = try FileSleepSyncManifestStore(fileURL: fixture.root.appendingPathComponent("sleep.json"))
        var enqueueAttempts = 0
        fixture.recorder.setResponseStatusCode(500)
        let runtime = try await makeIssue96CodecRuntime(
            fixture, store: store, outbox: outbox,
            beforeBootstrap: { model in model.observeSleepEnqueueAttemptForTesting = { enqueueAttempts += 1 } }
        )
        XCTAssertEqual(enqueueAttempts, 0)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertEqual(try store.loadPendingTransition(), pending)
        XCTAssertEqual(try store.loadManifest(), state == .cleanupIntent ? pending.manifest : fixture.initialManifest)
        XCTAssertNotEqual(fixture.initialManifest, pending.manifest)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try outbox.directFinalizationRecordReady(receiverIdentity: binding), acceptedRecord)
        XCTAssertEqual(try outbox.hasUncheckedDirectAcknowledgment(itemID: item.id, receiverBindingID: binding), state != .noACK)
        XCTAssertEqual(try outbox.hasDirectSleepCleanupIntent(
            itemID: item.id, receiverBindingID: binding, receiverGeneration: generation
        ), state == .cleanupIntent)

        _ = await runtime.viewModel.syncRecentSleepSessions(executionMode: .foreground)
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertTrue(fixture.readAnchors.isEmpty)
        XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
        XCTAssertEqual(enqueueAttempts, state == .noACK ? 1 : 0)
        XCTAssertEqual(fixture.recorder.invocationCount, state == .noACK ? 1 : 0)
        switch state {
        case .cleanupIntent:
            XCTAssertFalse(runtime.viewModel.statusIsError)
            XCTAssertNil(try store.loadPendingTransition())
            XCTAssertEqual(try store.loadManifest(), pending.manifest)
            XCTAssertTrue(try outbox.pendingItems().isEmpty)
            XCTAssertNil(try outbox.directFinalizationRecordReady(receiverIdentity: binding))
            XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        case .uncheckedACK:
            XCTAssertTrue(runtime.viewModel.statusIsError)
            XCTAssertEqual(try store.loadPendingTransition(), pending)
            XCTAssertEqual(try store.loadManifest(), fixture.initialManifest)
            XCTAssertTrue(try outbox.pendingItems().isEmpty)
            XCTAssertEqual(try outbox.directFinalizationRecordReady(receiverIdentity: binding), acceptedRecord)
            XCTAssertFalse(try outbox.hasDirectSleepCleanupIntent(
                itemID: item.id, receiverBindingID: binding, receiverGeneration: generation
            ))
            XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        case .noACK:
            let replacement = try XCTUnwrap(try outbox.pendingItems().first)
            XCTAssertEqual(try outbox.pendingItems().map(\.id), [replacement.id])
            XCTAssertNotEqual(replacement.id, item.id)
            XCTAssertEqual(try store.loadPendingTransition(), pending.assigningOutboxItemID(replacement.id))
            XCTAssertEqual(try Data(contentsOf: replacement.fileURL), payload)
            XCTAssertEqual(fixture.recorder.payloads, [payload])
            XCTAssertEqual(try store.loadManifest(), fixture.initialManifest)
            XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        case .writerInterruption:
            XCTFail("The live writer case must run before seeding an ACK.")
        }
        #endif
    }

    func testPlainDirectItemKeepsScopedTransferWhenPayloadUnlinkThrows() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires isolated app host.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let bytes = try HealthBridgeBatchEncoder().encode(
            ConnectionTestBatchFactory.make(now: Date(timeIntervalSince1970: 1_700_000_000))
        )
        let item = try fixture.outbox.enqueue(bytes, receiverIdentity: binding)
        let fault = SleepPayloadUnlinkInterruption(payloadURL: item.fileURL)
        let directory = fixture.outbox.directoryURL
        var accepted: LastAcceptedTransferObservation?
        for first in [true, false] {
            let outbox = try FileOutbox(directory: directory, fileManager: first ? fault : .default)
            let runtime = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep, outbox: outbox)
            let model = runtime.viewModel
            if first { XCTAssertNil(model.lastAcceptedTransferObservation) }
            let retry = AutomaticSyncEngine(
                pendingStore: fixture.background, processType: { _, _ in .blocked },
                performOpportunity: { opportunity, processPendingTypes in
                    _ = await model.performAutomaticSyncOpportunity(
                        opportunity: opportunity, processPendingTypes: processPendingTypes
                    )
                }
            )
            try await retry.requestRun(reason: .manualSync)
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await model.waitForBootstrapAndForegroundWork()
            let reopened = try FileOutbox(directory: directory)
            let ready = try reopened.directFinalizationRecordReady(receiverIdentity: binding)
            if first {
                accepted = model.lastAcceptedTransferObservation
                XCTAssertEqual(ready?.itemIDs, [item.id])
            } else {
                XCTAssertNil(ready, "Retry must retire the accepted record, not just remove its payload.")
                XCTAssertEqual(model.lastAcceptedTransferObservation, accepted)
            }
            XCTAssertEqual(model.lastAcceptedTransferObservation?.bindingID, binding)
            XCTAssertEqual(model.lastAcceptedTransferObservation?.evidenceKind, .directResponse)
            XCTAssertEqual(fixture.recorder.acceptedPayloads, [bytes])
        }
        XCTAssertEqual(fault.interruptions, 1)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        #endif
    }

    func testForegroundSleepRetryRetiresAcceptanceAcrossJournalUnlinkFaultsWithoutReposting() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        for afterUnlink in [false, true] {
            for tracksGeneration in [false, true] {
                try await runForegroundSleepJournalUnlinkFault(
                    afterUnlink: afterUnlink, tracksGeneration: tracksGeneration
                )
            }
        }
        #endif
    }

    #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
    private func runForegroundSleepJournalUnlinkFault(
        afterUnlink: Bool, tracksGeneration: Bool
    ) async throws {
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let context = "afterUnlink=\(afterUnlink), tracksGeneration=\(tracksGeneration)"
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let date = Date(timeIntervalSince1970: 1_700_259_200)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [], anchorCursorValue: fixture.nextAnchor, receivedAt: date
            ),
            receiverSettingsGeneration: generation,
            historyDepth: .allAvailable, historyStartDate: nil, generatedAt: date
        ))
        let expectedManifest = transition.manifest
        XCTAssertNotEqual(expectedManifest, fixture.initialManifest, context)
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let item = try fixture.outbox.enqueueIfAbsent(
            payload, receiverIdentity: binding,
            pendingGenerationRetirements: tracksGeneration ? fixture.generations : [:]
        ).item
        let sentinelPayload = try HealthBridgeBatchEncoder().encode(ConnectionTestBatchFactory.make(now: date))
        let sentinel = try fixture.outbox.enqueue(sentinelPayload, receiverIdentity: binding)
        let pending = SleepSyncPendingTransition(
            payload: payload, manifest: expectedManifest, receiverBindingID: binding,
            connectionGeneration: generation, outboxItemID: item.id
        )
        try fixture.sleep.savePendingTransition(pending)

        let sleepURL = fixture.root.appendingPathComponent("sleep.json")
        let journalURL = sleepURL.appendingPathExtension("pending")
        let fault = SleepJournalUnlinkInterruption(journalURL: journalURL, afterUnlink: afterUnlink)
        var enqueueAttempts = 0
        let installObserver: @MainActor (HealthBridgeCompanionViewModel) -> Void = { model in
            model.observeSleepEnqueueAttemptForTesting = { enqueueAttempts += 1 }
        }
        do {
            let store = try FileSleepSyncManifestStore(fileURL: sleepURL, fileManager: fault)
            let writer = try await makeIssue96CodecRuntime(fixture, store: store, beforeBootstrap: installObserver)
            XCTAssertEqual(fixture.recorder.invocationCount, 0, context)
            XCTAssertEqual(try store.loadPendingTransition(), pending, context)
            _ = await writer.viewModel.syncRecentSleepSessions(executionMode: .foreground)
            writer.automaticSyncRuntime.stopAdmission()
            await writer.automaticSyncRuntime.cancelAndWait()
            await writer.viewModel.waitForBootstrapAndForegroundWork()
        }
        XCTAssertEqual(fault.interruptions, 1, context)
        XCTAssertEqual(FileManager.default.fileExists(atPath: journalURL.path), !afterUnlink, context)
        XCTAssertEqual(try fixture.sleep.loadPendingTransition(), afterUnlink ? nil : pending, context)
        XCTAssertEqual(try fixture.sleep.loadManifest(), expectedManifest, context)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations, context)
        XCTAssertTrue(try fixture.outbox.hasDirectSleepCleanupIntent(
            itemID: item.id, receiverBindingID: binding, receiverGeneration: generation
        ), context)
        XCTAssertEqual(fixture.recorder.invocationCount, 1, context)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [payload], context)
        XCTAssertEqual(enqueueAttempts, 0, context)

        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [item.id, sentinel.id], context)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload, context)
        XCTAssertEqual(try fixture.outbox.uploadablePendingItems(for: binding).map(\.id), [], context)

        let recoveredOutbox = try FileOutbox(directory: fixture.outbox.directoryURL)
        let recoveredStore = try FileSleepSyncManifestStore(fileURL: sleepURL)
        XCTAssertEqual(try recoveredOutbox.pendingItems().map(\.id), [item.id, sentinel.id], context)
        XCTAssertEqual(try recoveredOutbox.uploadablePendingItems(for: binding).map(\.id), [], context)
        try await recoveredOutbox.prepareNutritionCompatibility()
        XCTAssertEqual(try recoveredOutbox.nutritionCompatibleItems(for: binding, support: .supported).map(\.id), [], context)
        let restarted = try await makeIssue96CodecRuntime(
            fixture, store: recoveredStore, outbox: recoveredOutbox, beforeBootstrap: installObserver
        )
        XCTAssertNil(try recoveredStore.loadPendingTransition(), context)
        XCTAssertEqual(try recoveredOutbox.pendingItems().map(\.id), [sentinel.id], context)
        XCTAssertEqual(try recoveredOutbox.uploadablePendingItems(for: binding).map(\.id), [sentinel.id], context)
        XCTAssertEqual(fixture.recorder.invocationCount, 1, context)
        // Run the real Direct queue drain without letting a fresh HealthKit read
        // produce a new cursor-only transition after recovery.
        let viewModel = restarted.viewModel
        let retry = AutomaticSyncEngine(
            pendingStore: fixture.background,
            processType: { _, _ in .blocked },
            performOpportunity: { opportunity, processPendingTypes in
                _ = await viewModel.performAutomaticSyncOpportunity(
                    opportunity: opportunity, processPendingTypes: processPendingTypes
                )
            }
        )
        try await retry.requestRun(reason: .manualSync)
        restarted.automaticSyncRuntime.stopAdmission()
        await restarted.automaticSyncRuntime.cancelAndWait()
        await restarted.viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertFalse(restarted.viewModel.statusIsError, context)
        XCTAssertEqual(fixture.background.lastRun?.outcome, tracksGeneration ? .completed : .interrupted, context)
        XCTAssertEqual(try recoveredStore.loadManifest(), expectedManifest, context)
        XCTAssertNil(try recoveredStore.loadPendingTransition(), context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path), context)
        XCTAssertTrue(try recoveredOutbox.pendingItems().isEmpty, context)
        XCTAssertNil(try recoveredOutbox.directFinalizationRecordReady(receiverIdentity: binding), context)
        XCTAssertFalse(try recoveredOutbox.hasDirectSleepCleanupIntent(
            itemID: item.id, receiverBindingID: binding, receiverGeneration: generation
        ), context)
        XCTAssertEqual(
            try fixture.background.loadPendingObserverTypeCodeGenerations(),
            tracksGeneration ? [:] : fixture.generations,
            context
        )
        XCTAssertEqual(fixture.recorder.invocationCount, 2, context)
        XCTAssertEqual(fixture.recorder.payloads, [payload, sentinelPayload], context)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [payload, sentinelPayload], context)
        XCTAssertEqual(enqueueAttempts, 0, context)
        XCTAssertTrue(fixture.readAnchors.isEmpty, context)
    }
    #endif

    func testAutomaticSleepColdOwnerCompletesAcceptedJournalBeforeNextRead() async throws {
        let fixture = try SleepStoreFaultFixture(point: .pendingClear, withReadableBaseline: true)
        defer { fixture.cleanUp() }
        let pending = fixture.pending
        // A reset-only, empty baseline deliberately ignores its stored anchor on the next read.
        // This fixture represents an accepted populated baseline where that would be a regression.
        XCTAssertFalse(pending.manifest.baselineResetPending == true)
        let expectedAnchor = try XCTUnwrap(pending.manifest.anchorCursorValue)
        let itemID = try XCTUnwrap(pending.outboxItemID)
        let binding = pending.receiverBindingID
        let sleepURL = fixture.root.appendingPathComponent("sleep.json")
        let debt = BackgroundSyncSettingsStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName)))
        XCTAssertNotEqual(fixture.reservation, pending.manifest)
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.reservation)

        // Stop the real Direct writer after it commits the manifest and ACK, but before it clears the journal.
        do {
            let writer = try await makeSleepStoreFaultRuntime(fixture)
            fixture.store.faultEnabled = true
            await writer.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
            writer.automaticSyncRuntime.stopAdmission()
            await writer.automaticSyncRuntime.cancelAndWait()
            await writer.viewModel.waitForBootstrapAndForegroundWork()
        }
        XCTAssertGreaterThan(fixture.store.faultCount, 0)

        let reopenedOutbox = try FileOutbox(directory: fixture.outbox.directoryURL)
        let reopenedStore = try FileSleepSyncManifestStore(fileURL: sleepURL)
        let record = try XCTUnwrap(try reopenedOutbox.directSleepCleanupRecord(receiverBindingID: binding, itemID: itemID))
        XCTAssertEqual(try reopenedOutbox.directSleepCleanupIntent(for: record), DirectSleepCleanupIntent(
            itemID: itemID, journalID: pending.id, receiverBindingID: binding,
            receiverGeneration: pending.connectionGeneration
        ))
        XCTAssertTrue(try reopenedOutbox.hasUncheckedDirectAcknowledgment(itemID: itemID, receiverBindingID: binding))
        let item = try XCTUnwrap(try reopenedOutbox.pendingItem(id: itemID))
        XCTAssertEqual(try Data(contentsOf: item.fileURL), pending.payload)
        XCTAssertTrue(try reopenedOutbox.uploadablePendingItems(for: binding).isEmpty)
        XCTAssertNil(record.cursorCheckpoint)
        XCTAssertEqual(try reopenedStore.loadPendingTransition(), pending)
        XCTAssertEqual(try reopenedStore.loadManifest(), pending.manifest)
        XCTAssertEqual(try debt.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(fixture.recorder.invocationCount, 1)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [pending.payload])
        let cursorURL = fixture.root.appendingPathComponent("cursors.json")
        let priorCursors = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: cursorURL))

        #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        var enqueueAttempts = 0
        let installObserver: @MainActor (HealthBridgeCompanionViewModel) -> Void = { model in
            model.observeSleepEnqueueAttemptForTesting = { enqueueAttempts += 1 }
        }
        #else
        let installObserver: @MainActor (HealthBridgeCompanionViewModel) -> Void = { _ in }
        #endif
        let stores = (outbox: reopenedOutbox, sleep: reopenedStore)
        do {
            let recovering = try await makeSleepStoreFaultRuntime(
                fixture, reopened: stores, beforeBootstrap: installObserver
            )
            XCTAssertFalse(recovering.viewModel.statusIsError)
            XCTAssertNil(try reopenedStore.loadPendingTransition())
            XCTAssertEqual(try reopenedStore.loadManifest(), pending.manifest)
            XCTAssertTrue(try reopenedOutbox.pendingItems().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
            XCTAssertNil(try reopenedOutbox.directSleepCleanupRecord(receiverBindingID: binding, itemID: itemID))
            XCTAssertNil(try reopenedOutbox.directFinalizationRecordReady(receiverIdentity: binding))
            XCTAssertFalse(try reopenedOutbox.hasUncheckedDirectAcknowledgment(itemID: itemID, receiverBindingID: binding))
            XCTAssertEqual(
                try debt.loadPendingObserverTypeCodeGenerations(), fixture.generations,
                "Finishing an old accepted journal does not satisfy the next fresh-read obligation."
            )
            XCTAssertEqual(fixture.recorder.invocationCount, 1)
            #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
            XCTAssertEqual(enqueueAttempts, 0)
            #endif
            recovering.automaticSyncRuntime.stopAdmission()
            await recovering.automaticSyncRuntime.cancelAndWait()
            await recovering.viewModel.waitForBootstrapAndForegroundWork()
        }

        var nextReadAnchors: [String?] = []
        let next = try await makeSleepStoreFaultRuntime(
            fixture, reopened: stores, beforeBootstrap: installObserver, readAttempted: { anchor in
                nextReadAnchors.append(anchor)
            }
        )
        await next.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        next.automaticSyncRuntime.stopAdmission()
        await next.automaticSyncRuntime.cancelAndWait()
        await next.viewModel.waitForBootstrapAndForegroundWork()

        XCTAssertEqual(nextReadAnchors, [expectedAnchor], "The first new read must use the recovered Sleep anchor.")
        XCTAssertNil(try reopenedStore.loadPendingTransition())
        XCTAssertEqual(try reopenedStore.loadManifest(), pending.manifest)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: cursorURL)), priorCursors)
        XCTAssertEqual(try debt.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertEqual(fixture.recorder.invocationCount, 1)
        XCTAssertEqual(fixture.recorder.acceptedPayloads, [pending.payload])
        #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        XCTAssertEqual(enqueueAttempts, 0)
        #endif
    }

    func testRejectedSleepRecoveryJournalFailureKeepsErrorPrivate() async throws {
        try await exerciseRejectedSleepRecoveryFailure(.rejectionPendingSave)
    }

    func testRejectedSleepRecoveryResetFailureKeepsErrorPrivate() async throws {
        try await exerciseRejectedSleepRecoveryFailure(.rejectionReset)
    }

    private func exerciseRejectedSleepRecoveryFailure(_ point: SleepStoreFaultFixture.Point) async throws {
        let fixture = try SleepStoreFaultFixture(point: point)
        defer { fixture.cleanUp() }
        let runtime = try await makeSleepStoreFaultRuntime(fixture)
        let rejected = fixture.pending.markingRejected(minimumResetEpoch: 2)
        try fixture.store.base.savePendingTransition(rejected)
        fixture.store.faultEnabled = true

        await runtime.viewModel.retryPrivateStorage()

        XCTAssertGreaterThan(fixture.store.faultCount, 0)
        XCTAssertTrue(runtime.viewModel.statusIsError)
        XCTAssertFalse(runtime.viewModel.statusMessage.contains(SleepStoreFaultFixture.privateMarker))
        XCTAssertEqual(try fixture.store.base.loadPendingTransition(), rejected)
        XCTAssertEqual(try fixture.outbox.pendingItems().count, point == .rejectionPendingSave ? 1 : 0)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)

        fixture.store.faultEnabled = false
        await runtime.viewModel.retryPrivateStorage()
        XCTAssertTrue(runtime.viewModel.canSyncSleep)
        XCTAssertNil(try fixture.store.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(fixture.recorder.invocationCount, 0)
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        withExtendedLifetime(runtime) {}
    }

    private func exerciseSleepStoreFailure(_ point: SleepStoreFaultFixture.Point) async throws {
        let fixture = try SleepStoreFaultFixture(point: point)
        defer { fixture.cleanUp() }
        let runtime = try await makeSleepStoreFaultRuntime(fixture)
        let posts: (automaticFault: Int, foregroundFault: Int, recovery: Int)
        switch point {
        case .pendingSave: posts = (0, 0, 1)
        case .manifestSave: posts = (1, 2, 3) // HTTP 200 arrives before the app can persist its ACK.
        case .pendingClear: posts = (1, 1, 1) // The durable ACK and cleanup intent prevent another POST.
        case .rejectionPendingSave, .rejectionReset:
            XCTFail("Rejection faults are exercised separately.")
            return
        }
        let hasCleanupIntent = point == .pendingClear
        let faultedManifest = hasCleanupIntent ? fixture.pending.manifest : fixture.reservation
        let binding = fixture.pending.receiverBindingID

        func assertPosts(_ count: Int, phase: String) {
            XCTAssertEqual(fixture.recorder.invocationCount, count, phase)
            XCTAssertEqual(fixture.recorder.acceptedPayloads, Array(repeating: fixture.pending.payload, count: count), phase)
        }

        func assertFaultedStorage(_ itemID: String, phase: String) throws {
            XCTAssertEqual(try fixture.store.loadPendingTransition(), fixture.pending, phase)
            XCTAssertEqual(try fixture.store.loadManifest(), faultedManifest, phase)
            XCTAssertEqual(try fixture.outbox.hasUncheckedDirectAcknowledgment(
                itemID: itemID, receiverBindingID: binding
            ), hasCleanupIntent, phase)
            let record = try fixture.outbox.directFinalizationRecordReady(receiverIdentity: binding)
            let intent = try record.flatMap { try fixture.outbox.directSleepCleanupIntent(for: $0) }
            XCTAssertEqual(intent, hasCleanupIntent ? DirectSleepCleanupIntent(
                itemID: itemID, journalID: fixture.pending.id,
                receiverBindingID: binding, receiverGeneration: fixture.pending.connectionGeneration
            ) : nil, phase)
        }
        fixture.store.faultEnabled = true
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["sleep_analysis"]))
        XCTAssertEqual(recordedSleepFailure(runtime.viewModel), AutomaticSyncDiagnosticFailure(
            stage: .store, category: .operationFailed
        ))
        XCTAssertGreaterThan(fixture.store.faultCount, 0)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertTrue(runtime.viewModel.canSyncSleep)
        assertPosts(posts.automaticFault, phase: "automatic while faulted")
        XCTAssertFalse(runtime.viewModel.statusMessage.contains(SleepStoreFaultFixture.privateMarker))
        XCTAssertFalse(fixture.diagnostics.latestRecord?.latestLaneSummary.contains(SleepStoreFaultFixture.privateMarker) ?? true)
        let item = try XCTUnwrap(try fixture.outbox.pendingItems().first)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), fixture.pending.payload)
        try assertFaultedStorage(item.id, phase: "automatic while faulted")
        let automaticFaultCount = fixture.store.faultCount
        _ = await runtime.viewModel.syncRecentSleepSessions()
        assertPosts(posts.foregroundFault, phase: "foreground retry while faulted")
        try assertFaultedStorage(item.id, phase: "foreground retry while faulted")
        XCTAssertGreaterThan(fixture.store.faultCount, automaticFaultCount)
        XCTAssertFalse(runtime.viewModel.statusMessage.contains(SleepStoreFaultFixture.privateMarker))
        fixture.store.faultEnabled = false
        fixture.recorder.setBeforeResponse { payload, _ in
            XCTAssertEqual(payload, fixture.pending.payload)
            XCTAssertEqual(try fixture.store.base.loadManifest(), faultedManifest)
            XCTAssertNotNil(try fixture.store.base.loadPendingTransition())
        }
        _ = await runtime.viewModel.syncRecentSleepSessions()
        XCTAssertNil(try fixture.store.loadPendingTransition())
        XCTAssertEqual(try fixture.store.loadManifest(), fixture.pending.manifest)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertNil(try fixture.outbox.directFinalizationRecordReady(receiverIdentity: binding))
        assertPosts(posts.recovery, phase: "foreground recovery")
        XCTAssertEqual(fixture.recorder.responseInspectionCount, posts.recovery - posts.foregroundFault)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        if point == .pendingSave {
            await runtime.automaticSyncRuntime.cancelAndWait()
            var freshReadAttempted = false
            let next = try await makeSleepStoreFaultRuntime(fixture, readAttempted: { _ in freshReadAttempted = true })
            await next.automaticSyncRuntime.runAutomaticSync(reason: .observer(typeCode: "sleep_analysis"))
            await next.automaticSyncRuntime.cancelAndWait()
            XCTAssertTrue(freshReadAttempted, "Old-journal replay must retain the next fresh-read obligation.")
            XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
            assertPosts(posts.recovery, phase: "next fresh read")
        }
    }

    private func recordedSleepFailure(_ viewModel: HealthBridgeCompanionViewModel) -> AutomaticSyncDiagnosticFailure? {
        Mirror(reflecting: viewModel).children.first {
            $0.label == "backgroundAutomaticSyncFailure"
        }?.value as? AutomaticSyncDiagnosticFailure
    }

    private func makeSleepStoreFaultRuntime(
        _ fixture: SleepStoreFaultFixture,
        reopened: (outbox: FileOutbox, sleep: FileSleepSyncManifestStore)? = nil,
        beforeBootstrap: @MainActor (HealthBridgeCompanionViewModel) -> Void = { _ in },
        readAttempted: (@MainActor (String?) -> Void)? = nil
    ) async throws -> HealthBridgeCompanionApplicationRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        fixture.session = session
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { "synthetic-issue64-installation" }
            ),
            outbox: reopened?.outbox ?? fixture.outbox, receiverClient: ReceiverClient(session: session),
            automaticSyncDiagnosticStore: fixture.diagnostics,
            sleepManifestStore: reopened.map { $0.sleep as any SleepSyncManifestStoring } ?? fixture.store,
            readAnchoredSleepChanges: { anchor, _, receivedAt in
                if let readAttempted {
                    readAttempted(anchor)
                } else {
                    XCTFail("Pending delivery failure must not reach a HealthKit query.")
                }
                throw CancellationError()
            },
            automaticSyncEligibleTypeCodesForTesting: ["sleep_analysis"],
            scheduleDirectBackgroundUploads: { 0 }
        )
        beforeBootstrap(viewModel)
        await viewModel.bootstrap()
        XCTAssertTrue(viewModel.canSyncSleep)
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("Sleep store tests must use the injected reader.") },
            stopQuery: { _ in }, enableDelivery: { _, completion in completion(false, nil) },
            disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in {} },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
        )
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel, automaticSyncPlatform: platform)
    }

    private func runIssue96SuspensionFence(
        _ scenario: Issue96CodecCase,
        invalidation: Issue96CodecInvalidation,
        resumeAfterCancellation: Bool = false
    ) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture(
            nightCount: resumeAfterCancellation ? 3 : 3_650, childrenPerNight: 16,
            historyOrigin: Date(timeIntervalSince1970: 1_300_000_000),
            cursorless: scenario == .firstJournal || scenario == .trackedJournal
        )
        defer { fixture.cleanUp() }
        let driver = Issue96CodecInvalidationDriver(target: scenario.operation)
        defer { driver.releaseCodec() }
        let store = try FileSleepSyncManifestStore(
            fileURL: fixture.root.appendingPathComponent("sleep.json"),
            observeCodec: { driver.beforeCodec($0) }
        )
        var seeded: SleepSyncPendingTransition?
        if scenario == .pendingReplay || scenario == .completion {
            let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
                previousManifest: fixture.initialManifest,
                changes: HealthKitAnchoredSleepChanges(addedSamples: [], deletedSamples: [],
                    anchorCursorValue: fixture.nextAnchor, receivedAt: Date()),
                receiverSettingsGeneration: fixture.settings.receiverSettingsGenerationToken,
                historyDepth: .allAvailable, historyStartDate: nil
            ))
            let pending = SleepSyncPendingTransition(
                payload: try HealthBridgeBatchEncoder().encode(transition.batch), manifest: transition.manifest,
                receiverBindingID: try XCTUnwrap(fixture.settings.receiverBindingID),
                connectionGeneration: fixture.settings.receiverSettingsGenerationToken
            )
            try fixture.sleep.savePendingTransition(pending)
            seeded = pending
        }
        let state = Issue96SafetyState()
        let runtime = try await makeIssue96CodecRuntime(
            fixture, store: store,
            admissionClosed: { driver.invalidationApplied() },
            terminalDrain: {
                do {
                    let committed = try fixture.sleep.loadManifest()
                    let pending = try fixture.sleep.loadPendingTransition()
                    let items = try fixture.outbox.pendingItems()
                    if scenario == .firstJournal {
                        state.resetBoundaryValid = committed == fixture.initialManifest && pending == nil && items.isEmpty
                    } else {
                        state.resetBoundaryValid = committed == fixture.initialManifest
                            && pending != nil && pending?.outboxItemID == nil && items.count == 1
                        if let pending, let item = items.first {
                            let payload = try Data(contentsOf: item.fileURL)
                            state.resetBoundaryValid = state.resetBoundaryValid
                                && payload == pending.payload
                        }
                    }
                } catch { state.resetBoundaryValid = false }
                return true
            }
        )
        let operation = Task { @MainActor in
            await runtime.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        }
        driver.start(waitForAdmissionClose: invalidation == .reset) {
            switch invalidation {
            case .cancel: operation.cancel()
            case .replace:
                try fixture.settings.save(receiverURLString: "http://127.0.0.1:8766/v1/batches",
                    bearerToken: "synthetic-codec-replacement", rotateBindingID: true)
            case .reset:
                state.reset = Task { @MainActor in await runtime.viewModel.clearPendingOutbox() }
            }
        }
        await operation.value
        driver.releaseCodec()
        let actionResult = await driver.join()
        await state.reset?.value
        let foreground = runtime.automaticSyncRuntime.foregroundCatchUpCompletion()
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()
        await foreground?()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
        try actionResult.get()
        XCTAssertTrue(driver.didInvalidateWhileHeld, "Invalidation must precede codec release.")
        XCTAssertFalse(runtime.viewModel.automaticSyncOwnerIsActive)
        let committed = try fixture.sleep.loadManifest()
        let pending = try fixture.sleep.loadPendingTransition()
        let items = try fixture.outbox.pendingItems()
        if invalidation == .reset {
            XCTAssertTrue(state.resetBoundaryValid, "No stale journal may appear before the real reset commit.")
            XCTAssertNil(committed)
            XCTAssertNil(pending)
            XCTAssertTrue(items.isEmpty)
        } else {
            XCTAssertTrue(committed == fixture.initialManifest)
            switch scenario {
            case .firstJournal:
                XCTAssertNil(pending)
                XCTAssertTrue(items.isEmpty)
            case .trackedJournal:
                let retained = try XCTUnwrap(pending)
                XCTAssertNil(retained.outboxItemID)
                XCTAssertEqual(items.count, 1)
                XCTAssertTrue(try Data(contentsOf: XCTUnwrap(items.first).fileURL) == retained.payload)
            case .pendingReplay:
                XCTAssertTrue(pending == seeded)
                XCTAssertTrue(items.isEmpty)
            case .completion:
                let retained = try XCTUnwrap(pending)
                XCTAssertEqual(retained.id, seeded?.id)
                XCTAssertEqual(retained.payload, seeded?.payload)
                XCTAssertEqual(retained.manifest, seeded?.manifest)
                XCTAssertEqual(retained.connectionGeneration, seeded?.connectionGeneration)
                XCTAssertEqual(retained.receiverBindingID, seeded?.receiverBindingID)
                XCTAssertEqual(items.count, 1)
                let item = try XCTUnwrap(items.first)
                XCTAssertEqual(item.id, retained.outboxItemID)
                XCTAssertEqual(item.receiverIdentity, retained.receiverBindingID)
                XCTAssertEqual(try Data(contentsOf: item.fileURL), retained.payload)
            case .coldManifest: XCTFail("Cold construction is covered by the unchanged responsiveness regression.")
            }
        }
        if scenario == .completion {
            XCTAssertTrue(fixture.recorder.acceptedPayloads == seeded.map { [$0.payload] })
        } else {
            XCTAssertTrue(fixture.recorder.payloads.isEmpty)
        }
        if resumeAfterCancellation {
            let resumed = try await makeIssue96CodecRuntime(fixture, store: fixture.sleep)
            await resumed.automaticSyncRuntime.runAutomaticSync(reason: .observer(typeCode: "sleep_analysis"))
            await resumed.automaticSyncRuntime.cancelAndWait()
            await resumed.viewModel.waitForBootstrapAndForegroundWork()
            XCTAssertNil(try fixture.sleep.loadPendingTransition())
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
            XCTAssertEqual(try fixture.sleep.loadManifest()?.anchorCursorValue, fixture.nextAnchor)
            XCTAssertEqual(fixture.recorder.acceptedPayloads.count, 1)
            XCTAssertEqual(
                fixture.readAnchors.count, scenario == .firstJournal ? 2 : 1,
                "A retained journal replays; only a cancelled first write needs a fresh read."
            )
            XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        }
        #endif
    }

    private func runIssue96PendingPayloadRead(invalidateFIFO: Bool) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture()
        defer { fixture.cleanUp() }
        let barrier = DirectSleepPreparationBarrier()
        defer { barrier.releasePreparation() }
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: fixture.initialManifest,
            changes: HealthKitAnchoredSleepChanges(addedSamples: [], deletedSamples: [],
                anchorCursorValue: fixture.nextAnchor, receivedAt: Date()),
            receiverSettingsGeneration: fixture.settings.receiverSettingsGenerationToken,
            historyDepth: .allAvailable, historyStartDate: nil
        ))
        let pending = SleepSyncPendingTransition(
            payload: try HealthBridgeBatchEncoder().encode(transition.batch),
            manifest: transition.manifest,
            receiverBindingID: try XCTUnwrap(fixture.settings.receiverBindingID),
            connectionGeneration: fixture.settings.receiverSettingsGenerationToken
        )
        try fixture.sleep.savePendingTransition(pending)
        let item = try fixture.outbox.enqueue(
            pending.payload, receiverIdentity: pending.receiverBindingID
        )
        barrier.startDriver {
            if invalidateFIFO {
                _ = try fixture.outbox.enqueue(
                    Data("{\"schema_id\":\"synthetic.concurrent-upload\"}".utf8),
                    receiverIdentity: pending.receiverBindingID
                )
            }
        }

        let runtime = try await makeIssue96CodecRuntime(
            fixture, store: fixture.sleep,
            beforeBootstrap: { model in
                model.observeSleepOutboxPayloadReadForTesting = { barrier.blockPreparation() }
            }
        )
        try await barrier.joinDriver()
        runtime.automaticSyncRuntime.stopAdmission()
        await runtime.automaticSyncRuntime.cancelAndWait()

        XCTAssertTrue(barrier.observation().entered)
        XCTAssertTrue(barrier.observation().actionBeforeRelease)
        let retained = try XCTUnwrap(fixture.sleep.loadPendingTransition())
        XCTAssertEqual(retained.id, pending.id)
        XCTAssertEqual(retained.outboxItemID, invalidateFIFO ? nil : item.id)
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
        XCTAssertEqual(try fixture.outbox.pendingItems().count, invalidateFIFO ? 2 : 1)
        #endif
    }

    private func runIssue96CodecCase(
        _ scenario: Issue96CodecCase,
        blocking: Bool,
        receiverStatus: Int = 200
    ) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let fixture = try DirectSleepPreparationFixture(
            nightCount: 3_650, childrenPerNight: 16,
            historyOrigin: Date(timeIntervalSince1970: 1_300_000_000),
            cursorless: scenario == .firstJournal || scenario == .trackedJournal
        )
        defer { fixture.cleanUp() }
        let barrier = Issue96CodecBarrier(target: scenario.operation, blocking: blocking)
        defer { barrier.releaseCodec() }
        let audit = Issue96CodecAudit(
            root: fixture.root, committed: fixture.initialManifest, recorder: fixture.recorder)
        let store = try FileSleepSyncManifestStore(
            fileURL: fixture.root.appendingPathComponent("sleep.json"),
            observeCodec: { operation in
                audit.observe(operation)
                barrier.beforeCodec(operation)
            }
        )
        fixture.recorder.setResponseStatusCode(receiverStatus)
        fixture.recorder.setBeforeResponse { payload, _ in try audit.beforeACK(payload) }
        var seed: SleepSyncPendingTransition?
        if scenario == .pendingReplay || scenario == .completion {
            let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
                previousManifest: fixture.initialManifest,
                changes: HealthKitAnchoredSleepChanges(addedSamples: [], deletedSamples: [],
                    anchorCursorValue: fixture.nextAnchor, receivedAt: Date()),
                receiverSettingsGeneration: fixture.settings.receiverSettingsGenerationToken,
                historyDepth: .allAvailable, historyStartDate: nil
            ))
            let pending = SleepSyncPendingTransition(
                payload: try HealthBridgeBatchEncoder().encode(transition.batch),
                manifest: transition.manifest,
                receiverBindingID: try XCTUnwrap(fixture.settings.receiverBindingID),
                connectionGeneration: fixture.settings.receiverSettingsGenerationToken
            )
            try fixture.sleep.savePendingTransition(pending)
            seed = pending
        }
        var runtime: HealthBridgeCompanionApplicationRuntime?
        do {
            if scenario == .coldManifest { barrier.arm() }
            let created = try await makeIssue96CodecRuntime(fixture, store: store)
            runtime = created
            if scenario != .coldManifest { barrier.arm() }
            await created.automaticSyncRuntime.runAutomaticSync(reason: .launchCatchUp)
        } catch {
            await finishIssue96CodecCase(runtime, barrier: barrier)
            throw error
        }
        await finishIssue96CodecCase(runtime, barrier: barrier)
        let observation = barrier.observation()
        XCTAssertTrue(observation.entered, "The real requested Sleep JSON codec must be reached.")
        XCTAssertFalse(observation.watchdogExpired, "Codec watchdog must not be needed on the normal path.")
        if blocking {
            XCTAssertTrue(observation.driverObservedHeartbeatWhileHeld,
                "MainActor heartbeat must be observed by the independent driver BEFORE codec release.")
        }
        let active = try XCTUnwrap(runtime)
        XCTAssertFalse(active.viewModel.automaticSyncOwnerIsActive)
        XCTAssertNil(active.automaticSyncRuntime.foregroundCatchUpCompletion())
        let auditResult = audit.observation()
        let pending = try XCTUnwrap(
            receiverStatus == 200 ? auditResult.pendingBeforeACK : fixture.sleep.loadPendingTransition())
        if receiverStatus == 200 {
            XCTAssertEqual(try fixture.sleep.loadManifest(), pending.manifest)
            XCTAssertNil(try fixture.sleep.loadPendingTransition())
        } else {
            XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
            XCTAssertEqual(try fixture.sleep.loadPendingTransition(), pending)
        }
        XCTAssertTrue(pending.connectionGeneration == fixture.settings.receiverSettingsGenerationToken)
        XCTAssertTrue(pending.receiverBindingID == fixture.settings.receiverBindingID)
        XCTAssertNotNil(pending.outboxItemID)
        XCTAssertTrue(pending.manifest.anchorCursorValue == fixture.nextAnchor)
        XCTAssertTrue(pending.manifest.activeChildSamples == fixture.children)
        XCTAssertEqual(pending.manifest.activeChildSamples.count, 58_400)
        XCTAssertEqual(pending.manifest.publishedSessions.count, 3_650)
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: pending.payload)
        XCTAssertTrue(batch.deletedRecords.isEmpty)
        if scenario == .firstJournal || scenario == .trackedJournal {
            XCTAssertNil(fixture.initialManifest.anchorCursorValue)
            XCTAssertTrue(fixture.readAnchors == [nil])
            XCTAssertEqual(batch.sleepSessions.count, 3_650)
        } else {
            XCTAssertTrue(batch.sleepSessions.isEmpty)
            XCTAssertTrue(pending.manifest.publishedSessions == fixture.initialManifest.publishedSessions)
            XCTAssertTrue(pending.manifest.nextRevisionSequence == fixture.initialManifest.nextRevisionSequence)
            switch scenario {
            case .coldManifest: XCTAssertTrue(fixture.readAnchors == [fixture.previousAnchor])
            case .pendingReplay:
                XCTAssertTrue(fixture.readAnchors.isEmpty)
                XCTAssertTrue(pending.id == seed?.id)
            case .completion:
                XCTAssertTrue(fixture.readAnchors.isEmpty)
                XCTAssertEqual(pending.id, seed?.id)
            case .firstJournal, .trackedJournal: break
            }
        }
        XCTAssertEqual(auditResult.failures, 0, "Durable journal/FIFO/ACK ordering audit must hold.")
        XCTAssertGreaterThan(auditResult.trackedWrites, 0)
        if scenario == .firstJournal || scenario == .trackedJournal || scenario == .coldManifest {
            XCTAssertEqual(auditResult.untrackedWrites, 1)
            XCTAssertEqual(auditResult.trackedWrites, 1)
        }
        let items = try fixture.outbox.pendingItems()
        if receiverStatus == 200 {
            XCTAssertTrue(items.isEmpty)
            let expectedPayloads = [pending.payload]
            XCTAssertTrue(fixture.recorder.acceptedPayloads == expectedPayloads)
            XCTAssertEqual(auditResult.preACKChecks, expectedPayloads.count)
        } else {
            XCTAssertTrue(fixture.recorder.acceptedPayloads.isEmpty)
            XCTAssertEqual(items.count, 1)
            let item = try XCTUnwrap(items.first)
            XCTAssertTrue(item.id == pending.outboxItemID)
            XCTAssertTrue(item.receiverIdentity == pending.receiverBindingID)
            XCTAssertTrue(try Data(contentsOf: item.fileURL) == pending.payload)
            XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations() == fixture.generations)
        }
        #endif
    }

    private func finishIssue96CodecCase(
        _ runtime: HealthBridgeCompanionApplicationRuntime?,
        barrier: Issue96CodecBarrier
    ) async {
        barrier.releaseCodec()
        await barrier.join()
        if let runtime {
            let foreground = runtime.automaticSyncRuntime.foregroundCatchUpCompletion()
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await foreground?()
            await runtime.viewModel.waitForBootstrapAndForegroundWork()
        }
    }

    private func makeIssue96CodecRuntime(
        _ fixture: DirectSleepPreparationFixture,
        store: FileSleepSyncManifestStore,
        pairingStateStore: ReceiverPairingStateStore? = nil,
        outbox: FileOutbox? = nil,
        admissionClosed: @escaping @MainActor () -> Void = {},
        terminalDrain: @escaping @MainActor () async -> Bool = { true },
        readAnchoredSleepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredSleepChanges)? = nil,
        requestProjectionReadAuthorization: (@MainActor ([String]) async throws -> Void)? = nil,
        beforeBootstrap: @MainActor (HealthBridgeCompanionViewModel) -> Void = { _ in }
    ) async throws -> HealthBridgeCompanionApplicationRuntime {
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let sleepReader = readAnchoredSleepChanges ?? { anchor, start, receivedAt in
            fixture.readAnchors.append(anchor)
            XCTAssertNil(start)
            return HealthKitAnchoredSleepChanges(
                addedSamples: anchor == nil ? fixture.children : [], deletedSamples: [],
                anchorCursorValue: fixture.nextAnchor, receivedAt: receivedAt
            )
        }
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: pairingStateStore ?? ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { DirectSleepPreparationFixture.installationID }
            ),
            outbox: outbox ?? fixture.outbox, receiverClient: ReceiverClient(session: fixture.session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: fixture.root.appendingPathComponent("diagnostics.json")),
            sleepManifestStore: store,
            readAnchoredSleepChanges: sleepReader,
            automaticSyncEligibleTypeCodesForTesting: ["sleep_analysis"],
            scheduleDirectBackgroundUploads: {
                fixture.directScheduleCount += 1
                return 0
            },
            terminalBackgroundPayloadDrain: terminalDrain, platformBackgroundPayloadDrain: { true },
            requestProjectionReadAuthorization: requestProjectionReadAuthorization
        )
        beforeBootstrap(viewModel)
        await viewModel.bootstrap()
        await viewModel.waitForBootstrapAndForegroundWork()
        XCTAssertTrue(viewModel.canSyncSleep, "Synthetic Direct bootstrap must be ready.")
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("Unexpected real HealthKit query.") }, stopQuery: { _ in },
            enableDelivery: { _, completion in completion(false, nil) }, disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { open in if !open { admissionClosed() } }, beginBackgroundOwner: { _ in {} },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
        )
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel, automaticSyncPlatform: platform)
    }

    private func makeIssue96Runtime(
        _ fixture: DirectSleepPreparationFixture,
        barrier: DirectSleepPreparationBarrier
    ) async throws -> HealthBridgeCompanionApplicationRuntime {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        PayloadFenceURLProtocol.networkRecorder = fixture.recorder
        let viewModel = try makeViewModel(
            root: fixture.root, defaults: fixture.defaults, settingsStore: fixture.settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore(),
                installationIDGenerator: { DirectSleepPreparationFixture.installationID }
            ),
            outbox: fixture.outbox, receiverClient: ReceiverClient(session: fixture.session),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: fixture.root.appendingPathComponent("diagnostics.json")),
            sleepManifestStore: fixture.sleep,
            sleepSyncPreparer: AnchoredSleepSyncPreparer(beforePreparation: { barrier.blockPreparation() }),
            readAnchoredSleepChanges: { anchor, start, receivedAt in
                fixture.readAnchors.append(anchor)
                XCTAssertEqual(anchor, fixture.previousAnchor)
                XCTAssertNil(start)
                return HealthKitAnchoredSleepChanges(
                    addedSamples: [], deletedSamples: [],
                    anchorCursorValue: fixture.nextAnchor, receivedAt: receivedAt
                )
            },
            automaticSyncEligibleTypeCodesForTesting: ["sleep_analysis"],
            scheduleDirectBackgroundUploads: { 0 },
            terminalBackgroundPayloadDrain: { true },
            platformBackgroundPayloadDrain: { true }
        )
        await viewModel.bootstrap()
        XCTAssertTrue(viewModel.canSyncSleep, viewModel.statusMessage)
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("Issue96 tests must use only the injected synthetic sleep reader.") },
            stopQuery: { _ in }, enableDelivery: { _, completion in completion(false, nil) },
            disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in {} },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator
        )
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel, automaticSyncPlatform: platform)
        #endif
    }

    private func assertIssue96PreparationWasAbandoned(
        _ fixture: DirectSleepPreparationFixture,
        runtime: HealthBridgeCompanionApplicationRuntime
    ) throws {
        XCTAssertEqual(fixture.readAnchors, [fixture.previousAnchor])
        XCTAssertEqual(try fixture.sleep.loadManifest(), fixture.initialManifest)
        XCTAssertNil(try fixture.sleep.loadPendingTransition())
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.background.loadPendingObserverTypeCodeGenerations(), fixture.generations)
        XCTAssertTrue(fixture.recorder.payloads.isEmpty, "Abandoned preparation must not reach the transport.")
        XCTAssertFalse(runtime.viewModel.activityLogMessages.contains { $0.contains("Uploading ") },
            "Abandoned preparation must not publish an upload-start status.")
    }

    private func makeViewModel(
        root: URL,
        defaults: UserDefaults,
        settingsStore: ReceiverSettingsStore,
        pairingStateStore: ReceiverPairingStateStore,
        outbox: FileOutbox,
        receiverClient: ReceiverClient = ReceiverClient(),
        automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore = AutomaticSyncDiagnosticStore(),
        sleepManifestStore: (any SleepSyncManifestStoring)? = nil,
        sleepSyncPreparer: AnchoredSleepSyncPreparer = AnchoredSleepSyncPreparer(),
        readAnchoredSleepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredSleepChanges)? = nil,
        readAnchoredStepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredStepChanges)? = nil,
        automaticSyncEligibleTypeCodesForTesting: [String]? = nil,
        readDailyActivityAggregates: (@MainActor (
            [String], Date, Date, Calendar
        ) async throws -> [HealthKitDailyActivityAggregate])? = nil,
        scheduleDirectBackgroundUploads: (@MainActor () async throws -> Int)? = nil,
        cancelInheritedLegacyUploads: @escaping @MainActor () async -> BackgroundUploadCancellationResult = {
            BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
        },
        terminalBackgroundPayloadDrain: (@MainActor () async -> Bool)? = nil,
        terminalRecoveryDrainTimeoutNanoseconds: UInt64 = 5_000_000_000,
        platformBackgroundPayloadDrain: (@MainActor () async -> Bool)? = nil,
        readAnchoredQuantityChanges: (@MainActor (String, String?, Date?, Date) async throws -> HealthKitAnchoredQuantityChanges)? = nil,
        requestProjectionReadAuthorization: (@MainActor ([String]) async throws -> Void)? = nil
    ) throws -> HealthBridgeCompanionViewModel {
        HealthBridgeCompanionViewModel(
            receiverClient: receiverClient,
            settingsStore: settingsStore,
            pairingStateStore: pairingStateStore,
            backgroundSyncStore: BackgroundSyncSettingsStore(userDefaults: defaults),
            automaticSyncDiagnosticStore: automaticSyncDiagnosticStore,
            healthPermissionRequestStore: CompanionHealthPermissionRequestStore(
                userDefaults: defaults
            ),
            healthHistoryDepthStore: HealthHistoryDepthSelectionStore(userDefaults: defaults),
            historicalBackfillStateStore: HealthHistoricalBackfillStateStore(
                userDefaults: defaults
            ),
            quantityObservationStore: QuantityObservationStore(userDefaults: defaults),
            coreLaneUploadProofStore: CoreLaneUploadProofStore(userDefaults: defaults),
            acceptedTransferStore: makeResetTestTransferStore(root: root, defaults: defaults),
            outbox: outbox,
            outboxDirectoryURL: outbox.directoryURL,
            cursorStore: try FileSyncCursorStore(
                fileURL: root.appendingPathComponent("cursors.json")
            ),
            cursorStoreFileURL: root.appendingPathComponent("cursors.json"),
            sleepManifestStore: try sleepManifestStore ?? FileSleepSyncManifestStore(
                fileURL: root.appendingPathComponent("sleep.json")
            ),
            sleepManifestFileURL: root.appendingPathComponent("sleep.json"),
            sleepResetEpochStore: SleepResetEpochStore(
                tokenStore: MemoryReceiverTokenStore(),
                epochFloorProvider: { 1 }
            ),
            sleepSyncPreparer: sleepSyncPreparer,
            mailboxKeyStore: MailboxKeyStore(
                service: "synthetic.reset-regression",
                keychain: MemoryMailboxKeychain()
            ),
            readAnchoredSleepChanges: readAnchoredSleepChanges,
            readAnchoredStepChanges: readAnchoredStepChanges,
            automaticSyncEligibleTypeCodesForTesting: automaticSyncEligibleTypeCodesForTesting,
            readDailyActivityAggregates: readDailyActivityAggregates,
            scheduleDirectBackgroundUploads: scheduleDirectBackgroundUploads,
            cancelInheritedLegacyUploads: cancelInheritedLegacyUploads,
            terminalBackgroundPayloadDrain: terminalBackgroundPayloadDrain,
            terminalRecoveryDrainTimeoutNanoseconds: terminalRecoveryDrainTimeoutNanoseconds,
            platformBackgroundPayloadDrain: platformBackgroundPayloadDrain,
            readAnchoredQuantityChanges: readAnchoredQuantityChanges,
            requestProjectionReadAuthorization: requestProjectionReadAuthorization
        )
    }
}

// Historical settings-generation evidence. The current app is only the reader.
extension HealthBridgeCompanionResetAdmissionTests {
    func testReopenedHistoricalSleepMismatchWithPayloadDeniesWithoutMutation() async throws {
        try await assertHistoricalSleepMismatchDenial(payloadPresent: true)
    }

    func testReopenedHistoricalSleepMismatchWithoutPayloadDeniesWithoutMutation() async throws {
        try await assertHistoricalSleepMismatchDenial(payloadPresent: false)
    }

    private func assertHistoricalSleepMismatchDenial(payloadPresent: Bool) async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Requires HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST for synthetic app testing.")
        #else
        let seed = try DirectSleepPreparationFixture()
        defer { seed.cleanUp() }
        let seedSettingsSuite = "\(seed.suiteName).historicalSettings"
        let seedSettingsDefaults = try XCTUnwrap(UserDefaults(suiteName: seedSettingsSuite))
        defer { seedSettingsDefaults.removePersistentDomain(forName: seedSettingsSuite) }
        let tokens = MemoryReceiverTokenStore()
        let seedSettings = ReceiverSettingsStore(
            userDefaults: seedSettingsDefaults, tokenStore: tokens,
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true }
        )
        try seedSettings.save(
            receiverURLString: seed.settings.receiverURLString,
            bearerToken: try seed.settings.loadBearerToken()
        )
        let g1Token = try tokens.loadToken()
        let g1 = seedSettings.receiverSettingsGenerationToken
        let binding = try XCTUnwrap(seedSettings.receiverBindingID)
        XCTAssertEqual(g1, "g1")

        let date = Date(timeIntervalSince1970: 1_700_259_200)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: seed.initialManifest,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [], deletedSamples: [], anchorCursorValue: seed.nextAnchor, receivedAt: date
            ),
            receiverSettingsGeneration: g1, historyDepth: .allAvailable, historyStartDate: nil, generatedAt: date
        ))
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: DirectSleepPreparationFixture.installationID,
            cursorKind: SleepSyncBatchFactory.anchoredCursorKind, cursorValue: seed.nextAnchor
        )
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let item = try XCTUnwrap(try seed.outbox.enqueueSequence(
            [payload], receiverIdentity: binding, cursorCheckpoint: checkpoint,
            pendingGenerationRetirements: seed.generations
        ).first)
        let journal = SleepSyncPendingTransition(
            payload: payload, manifest: transition.manifest, receiverBindingID: binding,
            connectionGeneration: g1, outboxItemID: item.id
        )
        let intent = DirectSleepCleanupIntent(
            itemID: item.id, journalID: journal.id, receiverBindingID: binding, receiverGeneration: g1
        )
        try seed.sleep.savePendingTransition(journal)
        try seed.sleep.saveManifest(journal.manifest)
        let record = try seed.outbox.recordDirectSleepAcceptance(intent, onNewAcceptance: {})
        try FileSyncCursorStore(fileURL: seed.root.appendingPathComponent("cursors.json")).saveCursorValue(
            seed.previousAnchor, receiverBindingID: binding,
            sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
        )

        var failedSaveProjection: HistoricalSleepProjection?
        for history in HistoricalSleepHistory.allCases {
            let label = "\(history), payloadPresent=\(payloadPresent)"
            let root = seed.root.appendingPathComponent(history.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["outbox", "sleep.json", "sleep.json.pending", "cursors.json"] {
                try FileManager.default.copyItem(
                    at: seed.root.appendingPathComponent(name), to: root.appendingPathComponent(name)
                )
            }
            let suite = "\(seed.suiteName).\(history.rawValue)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let background = BackgroundSyncSettingsStore(userDefaults: defaults)
            try background.setEnabledDurably(false)
            try background.markPendingObserverTypeCodes(["sleep_analysis"])
            let primary = MemoryReceiverTokenStore()
            try primary.saveToken(g1Token)
            let backup = MemoryReceiverTokenStore()
            let writer = ReceiverSettingsStore(
                userDefaults: defaults, tokenStore: primary, preCutoverBackupStore: backup, synchronize: { true }
            )
            let outboxURL = root.appendingPathComponent("outbox")
            let writerOutbox = try FileOutbox(directory: outboxURL)
            switch history {
            case .parentShapedFailedSave:
                // Model the parent's invalidate-before-empty-check ordering using the real barrier.
                // Do not call the current app's Save and attribute the old fault to it.
                do {
                    try await ReceiverConnectionTerminalBarrier().perform(
                        closeAdmission: {},
                        invalidateGeneration: { try writer.invalidateReceiverSettingsGeneration() },
                        cancelAndAwaitPairing: {}, cancelAndAwaitForegroundPayloads: {},
                        drainBackgroundPayloads: { true },
                        commit: { generation in
                            guard ReceiverConnectionTransitionPolicy.canBegin(
                                outboxIdentityAdmissionReady: true,
                                pendingItemCount: try writerOutbox.pendingItems().count,
                                clearIntentIsActive: writerOutbox.destructiveRecoveryIsRequested
                            ) else {
                                throw ReceiverOutboxIdentityError.receiverTransitionRequiresEmptyOutbox
                            }
                            try writer.save(
                                receiverURLString: "http://127.0.0.1:8766/v1/batches",
                                bearerToken: try seed.settings.loadBearerToken(),
                                expectedGeneration: generation
                            )
                        }
                    )
                    XCTFail("The parent-shaped Save must encounter a nonempty FIFO.")
                } catch ReceiverOutboxIdentityError.receiverTransitionRequiresEmptyOutbox {}
            case .deliberateInvalidation:
                XCTAssertEqual(try writer.invalidateReceiverSettingsGeneration(), "g2")
            }

            let payloadURL = outboxURL.appendingPathComponent(item.fileURL.lastPathComponent)
            // Model loss of the payload *after* the fence, not a failed empty-FIFO Save.
            if !payloadPresent { try FileManager.default.removeItem(at: payloadURL) }
            let settings = ReceiverSettingsStore(
                userDefaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                tokenStore: primary, preCutoverBackupStore: backup, synchronize: { true }
            )
            let outbox = try FileOutbox(directory: outboxURL)
            let sleep = try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json"))
            XCTAssertEqual(settings.receiverSettingsGenerationToken, "g2", label)
            XCTAssertEqual(settings.receiverBindingID, binding, label)
            XCTAssertEqual(settings.receiverURLString, seed.settings.receiverURLString, label)
            XCTAssertEqual(try settings.loadBearerToken(), try seed.settings.loadBearerToken(), label)
            XCTAssertEqual(try sleep.loadPendingTransition(), journal, label)
            XCTAssertEqual(try sleep.loadManifest(), journal.manifest, label)
            XCTAssertEqual(try outbox.pendingItems().map(\.id), payloadPresent ? [item.id] : [], label)
            XCTAssertEqual(try outbox.directSleepCleanupRecord(receiverBindingID: binding), record, label)
            XCTAssertEqual(try outbox.directSleepCleanupIntent(for: record), intent, label)
            XCTAssertTrue(try outbox.hasUncheckedDirectAcknowledgment(itemID: item.id, receiverBindingID: binding), label)
            XCTAssertEqual(try background.loadPendingObserverTypeCodeGenerations(), seed.generations, label)

            func projection() throws -> HistoricalSleepProjection {
                let paths = ["sleep.json", "sleep.json.pending", "cursors.json",
                             "outbox/.enqueue-transaction", "outbox/.fifo-sequence", "outbox/\(payloadURL.lastPathComponent)"]
                var files: [String: Data] = [:]
                for path in paths {
                    let url = root.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: url.path) { files[path] = try Data(contentsOf: url) }
                }
                return try HistoricalSleepProjection(
                    settings: settings.currentConnectionRecordV2(), primary: primary.loadToken(),
                    backup: backup.loadToken(), observers: background.loadPendingObserverTypeCodeGenerations(),
                    files: files
                )
            }
            let before = try projection()
            switch history {
            case .parentShapedFailedSave:
                failedSaveProjection = before
            case .deliberateInvalidation:
                XCTAssertEqual(before, try XCTUnwrap(failedSaveProjection), "Reopened projections must be identical.")
            }

            let recorder = PayloadFenceNetworkRecorder()
            PayloadFenceURLProtocol.networkRecorder = recorder
            var authorizationRequests: [[String]] = []
            var healthReads = 0
            let viewModel = try makeViewModel(
                root: root, defaults: defaults, settingsStore: settings,
                pairingStateStore: ReceiverPairingStateStore(
                    pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                    cancellationStore: MemoryReceiverTokenStore(),
                    installationIDGenerator: { DirectSleepPreparationFixture.installationID }
                ),
                outbox: outbox, receiverClient: ReceiverClient(session: seed.session),
                automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json")),
                sleepManifestStore: sleep,
                readAnchoredSleepChanges: { _, _, _ in
                    healthReads += 1
                    throw HistoricalSleepProbeStop.unexpectedHealthWork
                },
                terminalBackgroundPayloadDrain: { true }, platformBackgroundPayloadDrain: { true },
                requestProjectionReadAuthorization: { types in
                    authorizationRequests.append(types)
                    // Stop after the stale-journal decision, before a new baseline can hide it.
                    throw HistoricalSleepProbeStop.unexpectedHealthWork
                }
            )
            await viewModel.bootstrap()
            await viewModel.waitForBootstrapAndForegroundWork()
            XCTAssertEqual(try projection(), before, "Bootstrap admission changed evidence: \(label)")
            let delivered = await viewModel.syncRecentSleepSessions()
            await viewModel.waitForBootstrapAndForegroundWork()
            XCTAssertFalse(delivered, label)
            XCTAssertEqual(try projection(), before, "Sleep opportunity changed evidence: \(label)")
            XCTAssertEqual(authorizationRequests, [], label)
            XCTAssertEqual(healthReads, 0, label)
            XCTAssertEqual(recorder.invocationCount, 0, label)
        }
        #endif
    }

    #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
    private enum HistoricalSleepHistory: String, CaseIterable {
        case parentShapedFailedSave
        case deliberateInvalidation
    }

    private enum HistoricalSleepProbeStop: Error {
        case unexpectedHealthWork
    }

    private struct HistoricalSleepProjection: Equatable {
        let settings: ReceiverConnectionRecordV2?
        let primary: String
        let backup: String
        let observers: [String: Int]
        let files: [String: Data]
    }
    #endif
}

private func makeResetTestTransferStore(root: URL, defaults: UserDefaults) -> LastAcceptedTransferObservationStore {
    LastAcceptedTransferObservationStore(
        userDefaults: defaults, resetEpochURL: root.appendingPathComponent("accepted-transfer-reset-epoch")
    )
}

private final class OfflinePreflightTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.withLock { recorded } }
    func record(_ event: String) { lock.withLock { recorded.append(event) } }
    func reset() { lock.withLock { recorded.removeAll() } }
}

private final class OfflinePreflightURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var trace: OfflinePreflightTrace?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.trace?.record("http.\(request.httpMethod ?? "UNKNOWN").\(request.url?.path ?? "UNKNOWN").failed")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private enum Issue96CodecInvalidation { case cancel, replace, reset }

@MainActor
private final class Issue96SafetyState {
    var reset: Task<Void, Never>?
    var resetBoundaryValid = false
}

private final class Issue96CodecInvalidationDriver: @unchecked Sendable {
    private let target: FileSleepSyncManifestStore.CodecOperation
    private let lock = NSLock()
    private let entry = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let applied = DispatchSemaphore(value: 0)
    private let driver = DispatchGroup()
    private var armed = false
    private var entered = false
    private var released = false
    private var invalidated = false
    private var action: Task<Void, Error>?

    init(target: FileSleepSyncManifestStore.CodecOperation) { self.target = target }

    func start(waitForAdmissionClose: Bool, action: @escaping @MainActor @Sendable () throws -> Void) {
        lock.withLock { armed = true }
        driver.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { releaseCodec(); driver.leave() }
            guard entry.wait(timeout: .now() + 90) == .success else { return }
            let task = Task { @MainActor [self] in
                do {
                    try action()
                    if !waitForAdmissionClose { invalidationApplied() }
                } catch {
                    releaseCodec()
                    throw error
                }
            }
            lock.withLock { self.action = task }
            _ = applied.wait(timeout: .now() + 10)
        }
    }

    func beforeCodec(_ operation: FileSleepSyncManifestStore.CodecOperation) {
        let selected = lock.withLock {
            guard armed, !entered, !released, operation == target else { return false }
            entered = true
            return true
        }
        guard selected else { return }
        entry.signal()
        if release.wait(timeout: .now() + 20) != .success { releaseCodec() }
    }

    func invalidationApplied() {
        lock.withLock { if entered && !released { invalidated = true } }
        applied.signal()
    }

    func releaseCodec() {
        let signal = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if signal { release.signal(); entry.signal() }
    }

    var didInvalidateWhileHeld: Bool { lock.withLock { invalidated } }

    func join() async -> Result<Void, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            driver.notify(queue: .global()) { continuation.resume() }
        }
        let task = lock.withLock { action }
        return await task?.result ?? .success(())
    }
}

private enum Issue96CodecCase: Equatable {
    case firstJournal, trackedJournal, coldManifest, pendingReplay, completion

    var operation: FileSleepSyncManifestStore.CodecOperation {
        switch self {
        case .firstJournal: .encodePending(tracked: false)
        case .trackedJournal: .encodePending(tracked: true)
        case .coldManifest: .decodeManifest
        case .pendingReplay: .decodePending
        case .completion: .encodeManifest
        }
    }
}

private final class Issue96CodecBarrier: @unchecked Sendable {
    private let target: FileSleepSyncManifestStore.CodecOperation
    private let blocking: Bool
    private let lock = NSLock()
    private let codecEntered = DispatchSemaphore(value: 0)
    private let codecRelease = DispatchSemaphore(value: 0)
    private let heartbeatDone = DispatchSemaphore(value: 0)
    private let driver = DispatchGroup()
    private var armed = false
    private var entered = false
    private var held = false
    private var released = false
    private var heartbeatWhileHeld = false
    private var driverObserved = false
    private var watchdogExpired = false
    private var heartbeat: Task<Void, Never>?

    init(target: FileSleepSyncManifestStore.CodecOperation, blocking: Bool) {
        self.target = target
        self.blocking = blocking
    }

    func arm() {
        lock.withLock { armed = true }
        guard blocking else { return }
        driver.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { driver.leave() }
            let signaled = codecEntered.wait(timeout: .now() + 90) == .success
            let canProbe = lock.withLock { entered && held && !released }
            guard signaled, canProbe else {
                releaseCodec()
                if !signaled { lock.withLock { watchdogExpired = true } }
                return
            }
            let task = Task { @MainActor [self] in
                lock.withLock { heartbeatWhileHeld = held && !released }
                heartbeatDone.signal()
            }
            lock.withLock { heartbeat = task }
            let completed = heartbeatDone.wait(timeout: .now() + 2) == .success
            lock.withLock { driverObserved = completed && heartbeatWhileHeld && held && !released }
            releaseCodec()
        }
    }

    func beforeCodec(_ operation: FileSleepSyncManifestStore.CodecOperation) {
        let selected = lock.withLock {
            guard armed, !entered, !released, operation == target else { return false }
            entered = true
            held = blocking
            return true
        }
        guard selected, blocking else { return }
        codecEntered.signal()
        if codecRelease.wait(timeout: .now() + 15) != .success {
            releaseCodec()
            lock.withLock { watchdogExpired = true }
        }
        lock.withLock { held = false }
    }

    func releaseCodec() {
        let shouldSignal = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldSignal {
            codecRelease.signal()
            codecEntered.signal()
        }
    }

    func join() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            driver.notify(queue: .global()) { continuation.resume() }
        }
        let task = lock.withLock { heartbeat }
        await task?.value
    }

    func observation() -> (entered: Bool, driverObservedHeartbeatWhileHeld: Bool, watchdogExpired: Bool) {
        lock.withLock { (entered, driverObserved, watchdogExpired) }
    }
}

private final class Issue96CodecAudit: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private let expectedCommitted: SleepSyncManifest
    private let recorder: PayloadFenceNetworkRecorder
    private var failures = 0
    private var untrackedWrites = 0
    private var trackedWrites = 0
    private var preACKChecks = 0
    private var pendingBeforeACK: SleepSyncPendingTransition?

    init(root: URL, committed: SleepSyncManifest, recorder: PayloadFenceNetworkRecorder) {
        self.root = root
        self.expectedCommitted = committed
        self.recorder = recorder
    }

    private var manifestURL: URL { root.appendingPathComponent("sleep.json") }
    private var pendingURL: URL { manifestURL.appendingPathExtension("pending") }

    private func payloadFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("outbox"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    func observe(_ operation: FileSleepSyncManifestStore.CodecOperation) {
        do {
            switch operation {
            case .encodePending(tracked: false):
                let files = try payloadFiles()
                let valid = !FileManager.default.fileExists(atPath: pendingURL.path)
                    && files.isEmpty
                lock.withLock { untrackedWrites += 1; if !valid { failures += 1 } }
            case .encodePending(tracked: true):
                let previous = try JSONDecoder().decode(SleepSyncPendingTransition.self, from: Data(contentsOf: pendingURL))
                let files = try payloadFiles()
                let payloadMatches = try files.first.map { try Data(contentsOf: $0) == previous.payload } ?? false
                let valid = previous.outboxItemID == nil && files.count == 1
                    && payloadMatches
                lock.withLock { trackedWrites += 1; if !valid { failures += 1 } }
            case .encodeManifest:
                let previous = try JSONDecoder().decode(SleepSyncPendingTransition.self, from: Data(contentsOf: pendingURL))
                let files = try payloadFiles()
                let payloadMatches = try files.first.map { try Data(contentsOf: $0) == previous.payload } ?? false
                let valid = files.count == 1
                    && files.first?.deletingPathExtension().lastPathComponent == previous.outboxItemID
                    && payloadMatches && recorder.acceptedPayloads == [previous.payload]
                lock.withLock { if !valid || preACKChecks == 0 { failures += 1 } }
            case .decodeManifest, .decodePending: break
            }
        } catch {
            lock.withLock { failures += 1 }
        }
    }

    func beforeACK(_ payload: Data) throws {
        let committed = try JSONDecoder().decode(SleepSyncManifest.self, from: Data(contentsOf: manifestURL))
        let pending = try JSONDecoder().decode(SleepSyncPendingTransition.self, from: Data(contentsOf: pendingURL))
        let files = try payloadFiles()
        let itemIsFIFOHead = files.count == 1 && files.first?.deletingPathExtension().lastPathComponent == pending.outboxItemID
        let matches = pending.payload == payload && itemIsFIFOHead
        lock.withLock {
            preACKChecks += 1
            pendingBeforeACK = pending
            if !matches || committed != expectedCommitted { failures += 1 }
        }
    }

    func observation() -> (
        failures: Int, untrackedWrites: Int, trackedWrites: Int,
        preACKChecks: Int, pendingBeforeACK: SleepSyncPendingTransition?
    ) {
        lock.withLock { (failures, untrackedWrites, trackedWrites, preACKChecks, pendingBeforeACK) }
    }
}

#if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
private final class SleepPayloadUnlinkInterruption: FileManager, @unchecked Sendable {
    enum Fault: Error { case afterUnlink }
    private let payloadURL: URL
    private let lock = NSLock()
    private var faultCount = 0

    init(payloadURL: URL) {
        self.payloadURL = payloadURL
        super.init()
    }

    var interruptions: Int { lock.withLock { faultCount } }

    override func removeItem(at url: URL) throws {
        try super.removeItem(at: url)
        guard url == payloadURL else { return }
        lock.withLock { faultCount += 1 }
        throw Fault.afterUnlink
    }
}
#endif

#if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
private final class SleepJournalUnlinkInterruption: FileManager, @unchecked Sendable {
    private enum Fault: Error { case interrupted }
    private let journalURL: URL
    private let afterUnlink: Bool
    private let lock = NSLock()
    private var faultCount = 0
    private var faultEnabled = true

    init(journalURL: URL, afterUnlink: Bool) {
        self.journalURL = journalURL
        self.afterUnlink = afterUnlink
        super.init()
    }

    var interruptions: Int { lock.withLock { faultCount } }

    func stopInterrupting() {
        lock.withLock { faultEnabled = false }
    }

    override func removeItem(at url: URL) throws {
        guard url == journalURL else { return try super.removeItem(at: url) }
        let shouldInterrupt = lock.withLock {
            guard faultEnabled else { return false }
            faultCount += 1
            return true
        }
        guard shouldInterrupt else { return try super.removeItem(at: url) }
        if afterUnlink { try super.removeItem(at: url) }
        throw Fault.interrupted
    }
}
#endif

@MainActor
private final class DirectSleepPreparationFixture {
    static let installationID = "synthetic-issue96-installation"
    let root: URL
    let suiteName = "Synthetic.Issue96.SleepPreparation.\(UUID())"
    let defaults: UserDefaults
    let settings: ReceiverSettingsStore
    let background: BackgroundSyncSettingsStore
    let generations: [String: Int]
    let sleep: FileSleepSyncManifestStore
    let outbox: FileOutbox
    let initialManifest: SleepSyncManifest
    let children: [HealthKitSleepChildSample]
    let previousAnchor = "synthetic-issue96-previous-anchor"
    let nextAnchor = "synthetic-issue96-next-anchor"
    var platformDrainReady = true
    var directScheduleCount = 0
    var cancelledSchedulingCount = 0
    let recorder = PayloadFenceNetworkRecorder()
    let session: URLSession
    var readAnchors: [String?] = []

    init(
        nightCount: Int = 3,
        childrenPerNight: Int = 8,
        historyOrigin: Date = Date(timeIntervalSince1970: 1_700_000_000),
        cursorless: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Synthetic-Issue96-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true }
        )
        try settings.save(receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-issue96-credential", rotateBindingID: true)
        background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        try background.markPendingObserverTypeCodes(["sleep_analysis"])
        generations = try background.loadPendingObserverTypeCodeGenerations()
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        sleep = try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json"))
        let reservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: settings.receiverSettingsGenerationToken,
            historyDepth: .allAvailable, historyStartDate: nil,
            sourceKey: "apple_health.phone.\(Self.installationID)", baselineResetEpoch: 1,
            identityNamespace: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000096"))
        )
        let date = historyOrigin
        let samples = try (0 ..< nightCount * childrenPerNight).map { index in
            let start = date.addingTimeInterval(Double(index / childrenPerNight) * 86_400 + Double(index % childrenPerNight) * 1_800)
            return HealthKitSleepChildSample(
                uuid: try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))),
                stage: index.isMultiple(of: 2) ? "core" : "deep", start: start,
                end: start.addingTimeInterval(1_800)
            )
        }
        children = samples
        if cursorless {
            initialManifest = reservation
        } else {
            initialManifest = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
                previousManifest: reservation,
                changes: HealthKitAnchoredSleepChanges(addedSamples: samples, deletedSamples: [],
                    anchorCursorValue: previousAnchor, receivedAt: date.addingTimeInterval(Double(nightCount) * 86_400)),
                receiverSettingsGeneration: settings.receiverSettingsGenerationToken,
                historyDepth: .allAvailable, historyStartDate: nil, generatedAt: date
            )).manifest
        }
        try sleep.saveManifest(initialManifest)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        PayloadFenceURLProtocol.networkRecorder = nil
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: root))
    }
}

// The independent driver can release preparation even if a regression blocks MainActor.
// Every mutable field is protected by the lock; the optional action is joined on MainActor.
private final class DirectSleepPreparationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let actionDone = DispatchSemaphore(value: 0)
    private let driver = DispatchGroup()
    private var didEnter = false
    private var observedEntry = false
    private var released = false
    private var actionBeforeRelease = false
    private var actionTask: Task<Void, any Error>?

    func blockPreparation() {
        let isFirst = lock.withLock {
            guard !didEnter else { return false }
            didEnter = true
            return true
        }
        guard isFirst else { return }

        entered.signal()
        if release.wait(timeout: .now() + 15) != .success {
            releasePreparation()
        }
    }

    func startDriver(action: @escaping @MainActor @Sendable () throws -> Void = {}) {
        driver.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { driver.leave() }
            let observed = entered.wait(timeout: .now() + 5) == .success
            lock.withLock { observedEntry = observed }
            if observed {
                let task = Task { @MainActor [self] in
                    defer { actionDone.signal() }
                    try action()
                    lock.withLock { actionBeforeRelease = !released }
                }
                lock.withLock { actionTask = task }
                _ = actionDone.wait(timeout: .now() + 5)
            }
            releasePreparation()
        }
    }

    func releasePreparation() {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { release.signal() }
    }

    func joinDriver() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            driver.notify(queue: .global()) { continuation.resume() }
        }
        let task = lock.withLock { actionTask }
        try await task?.value
    }

    func observation() -> (entered: Bool, actionBeforeRelease: Bool) {
        lock.withLock { (observedEntry, actionBeforeRelease) }
    }
}

private final class FaultingSleepManifestStore: SleepSyncManifestStoring, @unchecked Sendable {
    let base: FileSleepSyncManifestStore
    let point: SleepStoreFaultFixture.Point
    var faultEnabled = false
    var faultCount = 0
    var failure: Error = CocoaError(.fileWriteUnknown, userInfo: [
        NSLocalizedDescriptionKey: SleepStoreFaultFixture.privateMarker,
        NSFilePathErrorKey: "/synthetic/" + SleepStoreFaultFixture.privateMarker,
        NSUnderlyingErrorKey: NSError(domain: "synthetic.private", code: 1, userInfo: [
            NSLocalizedDescriptionKey: SleepStoreFaultFixture.privateMarker
        ]),
    ])

    init(base: FileSleepSyncManifestStore, point: SleepStoreFaultFixture.Point) {
        self.base = base
        self.point = point
    }

    private func fail(_ point: SleepStoreFaultFixture.Point) throws {
        if faultEnabled && self.point == point {
            faultCount += 1
            throw failure
        }
    }

    func loadManifest() throws -> SleepSyncManifest? { try base.loadManifest() }
    func loadPendingTransition() throws -> SleepSyncPendingTransition? { try base.loadPendingTransition() }
    var recoveryMayBeNeeded: Bool { base.recoveryMayBeNeeded }
    func revisionForSync() throws -> SleepSyncStorageRevision { try base.revisionForSync() }

    @MainActor
    func loadManifestForSync(validate: @MainActor () throws -> Void) async throws -> SleepSyncManifest? {
        try await base.loadManifestForSync(validate: validate)
    }

    @MainActor
    func loadPendingForSync(validate: @MainActor () throws -> Void) async throws -> SleepSyncPendingTransition? {
        try await base.loadPendingForSync(validate: validate)
    }

    @MainActor
    func saveManifestForSync(_ manifest: SleepSyncManifest, validate: @MainActor () throws -> Void) async throws -> SleepSyncStorageRevision {
        try fail(.manifestSave)
        return try await base.saveManifestForSync(manifest, validate: validate)
    }

    @MainActor
    func savePendingForSync(_ transition: SleepSyncPendingTransition, validate: @MainActor () throws -> Void) async throws -> SleepSyncStorageRevision {
        try fail(.pendingSave)
        if transition.rejectedMinimumResetEpoch != nil { try fail(.rejectionPendingSave) }
        return try await base.savePendingForSync(transition, validate: validate)
    }

    @MainActor
    func clearPendingForSync(id: String, validate: @MainActor () throws -> Void) async throws -> SleepSyncStorageRevision {
        try fail(.pendingClear)
        return try await base.clearPendingForSync(id: id, validate: validate)
    }
    func saveManifest(_ manifest: SleepSyncManifest) throws {
        try fail(.manifestSave)
        try base.saveManifest(manifest)
    }
    func savePendingTransition(_ transition: SleepSyncPendingTransition) throws {
        try fail(.pendingSave)
        if transition.rejectedMinimumResetEpoch != nil {
            try fail(.rejectionPendingSave)
        }
        try base.savePendingTransition(transition)
    }
    func clearPendingTransition(id: String) throws {
        try fail(.pendingClear)
        try base.clearPendingTransition(id: id)
    }
    func resetSynchronizationState() throws {
        try fail(.rejectionReset)
        try base.resetSynchronizationState()
    }
}

private final class SleepStoreFaultFixture: @unchecked Sendable {
    enum Point { case pendingSave, manifestSave, pendingClear, rejectionPendingSave, rejectionReset }
    static let privateMarker = "synthetic-private-error-marker"
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let settings: ReceiverSettingsStore
    let background: BackgroundSyncSettingsStore
    let generations: [String: Int]
    let diagnostics: AutomaticSyncDiagnosticStore
    let outbox: FileOutbox
    let store: FaultingSleepManifestStore
    let reservation: SleepSyncManifest
    let pending: SleepSyncPendingTransition
    let recorder = PayloadFenceNetworkRecorder()
    var session: URLSession?

    init(point: Point, withReadableBaseline: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Synthetic-Issue64-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "Synthetic.Issue64.SleepStore.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = ReceiverSettingsStore(userDefaults: defaults, tokenStore: MemoryReceiverTokenStore(),
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true })
        try settings.save(receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-issue64-credential", rotateBindingID: true)
        background = BackgroundSyncSettingsStore(userDefaults: defaults)
        try background.setEnabledDurably(true)
        try background.markPendingObserverTypeCodes(["sleep_analysis"])
        generations = try background.loadPendingObserverTypeCodeGenerations()
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        diagnostics = AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json"))
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        outbox.automaticSyncDiagnosticStore = diagnostics
        let base = try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json"))
        store = FaultingSleepManifestStore(base: base, point: point)
        reservation = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: settings.receiverSettingsGenerationToken,
            historyDepth: HealthHistoryDepthSelectionStore(userDefaults: defaults).historyDepth, historyStartDate: nil,
            sourceKey: "apple_health.phone.synthetic-issue64-installation", baselineResetEpoch: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let addedSamples = withReadableBaseline ? [HealthKitSleepChildSample(
            uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000064")),
            stage: "core", start: date.addingTimeInterval(-3600), end: date
        )] : []
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: reservation,
            changes: HealthKitAnchoredSleepChanges(addedSamples: addedSamples, deletedSamples: [],
                anchorCursorValue: "synthetic-issue64-anchor", receivedAt: date),
            receiverSettingsGeneration: settings.receiverSettingsGenerationToken,
            historyDepth: reservation.historyDepth, historyStartDate: nil, generatedAt: date))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let binding = try XCTUnwrap(settings.receiverBindingID)
        var itemID: String?
        if point != .pendingSave {
            let item = try outbox.enqueue(payload, receiverIdentity: binding)
            itemID = item.id
        }
        pending = SleepSyncPendingTransition(payload: payload, manifest: transition.manifest,
            receiverBindingID: binding, connectionGeneration: settings.receiverSettingsGenerationToken,
            outboxItemID: itemID)
        try base.saveManifest(reservation)
        try base.savePendingTransition(pending)
    }

    func cleanUp() {
        session?.invalidateAndCancel()
        PayloadFenceURLProtocol.networkRecorder = nil
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: root))
    }
}

@MainActor
private final class AutomaticStepsFaultFixture {
    enum ReadFailure: Error { case injected }

    let root: URL
    let suiteName = "AutomaticStepsFaultTests.\(UUID().uuidString)"
    let tokenStore = MemoryReceiverTokenStore()
    let backupStore = MemoryReceiverTokenStore()
    let pairingPendingStore = MemoryReceiverTokenStore()
    let installationStore = MemoryReceiverTokenStore()
    let pairingCancellationStore = MemoryReceiverTokenStore()
    let recorder = PayloadFenceNetworkRecorder()
    let previousAnchor: String
    let currentAnchor: String
    private(set) var receiverBindingID = ""
    var sessions: [URLSession] = []
    var failRawRead = false
    var failStepsDailyRead = false
    var emptyStepsDailyRead = false
    var captureObservationOrder = false
    var completedStepsValue: Double = 4_321
    var completedBasalEnergyValue: Double = 345
    private(set) var declinedBackgroundSchedules = 0
    var beforeBackgroundSchedule: (@MainActor () async -> Void)?
    private(set) var rawAnchors: [String] = []
    private(set) var rawReadStarts: [Date?] = []
    var quantityReadAnchors: [String?] = []
    private(set) var dailyRequests: [[String]] = []
    private(set) var readEvents: [String] = []
    private(set) var completedStepsDay: HealthKitDailyActivityAggregate?
    private(set) var dailyWindowStarts: [Date] = []
    private(set) var ordersBeforeRead: [Issue63OutboxOrderSnapshot?] = []
    var ownersStarted = 0
    var ownersFinished = 0
    var platformDrains = 0
    var sampleStart: Date
    var projectRawSampleDay = false

    init(sampleStart: Date = Date().addingTimeInterval(-120), hasInitialAnchor: Bool = true) throws {
        self.sampleStart = sampleStart
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticStepsFaultTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        previousAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 41))
        currentAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 42))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = makeSettingsStore(defaults: defaults)
        try settings.save(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-steps-fault-credential",
            rotateBindingID: true
        )
        receiverBindingID = try XCTUnwrap(settings.receiverBindingID)
        try BackgroundSyncSettingsStore(userDefaults: defaults).setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
        if hasInitialAnchor {
            try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).saveCursorValue(
                previousAnchor,
                receiverBindingID: receiverBindingID,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
            )
            CoreLaneUploadProofStore(userDefaults: defaults).markUploadedRecords(
                lane: .steps, receiverBindingID: receiverBindingID
            )
        }
    }

    func makeSettingsStore(defaults: UserDefaults) -> ReceiverSettingsStore {
        ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: tokenStore,
            preCutoverBackupStore: backupStore, synchronize: { true }
        )
    }

    func pending() throws -> [String: Int] {
        try BackgroundSyncSettingsStore(userDefaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
            .loadPendingObserverTypeCodeGenerations()
    }

    func admit(_ types: [String]) throws -> [String: Int] {
        let store = BackgroundSyncSettingsStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        try store.markPendingObserverTypeCodes(types)
        let admitted = try store.loadPendingObserverTypeCodeGenerations()
        XCTAssertEqual(admitted.keys.sorted(), types.sorted())
        return admitted
    }

    func stepCursor(kind: String = StepCountSyncBatchFactory.anchoredCursorKind) throws -> String? {
        try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).cursorValue(
            receiverBindingID: receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: kind
        )
    }

    func acceptedSamples(kind: String) throws -> [HealthBridgeSample] {
        try recorder.acceptedPayloads.flatMap {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0).samples
        }.filter { $0.metadata["sample_kind"] == kind }
    }

    func inspectBeforeACK(eligible: [String], admitted: [String: Int], acceptedBefore: Int, opportunity: Int) {
        let root = root
        let suiteName = suiteName
        let binding = receiverBindingID
        let rawCursor = opportunity == 1 ? previousAnchor : currentAnchor
        let dailyCursor = currentAnchor
        recorder.setBeforeResponse { payload, acceptedCount in
            let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: payload)
            let pending = try BackgroundSyncSettingsStore(
                userDefaults: XCTUnwrap(UserDefaults(suiteName: suiteName))
            ).loadPendingObserverTypeCodeGenerations()
            if acceptedCount == acceptedBefore {
                XCTAssertEqual(pending.keys.sorted(), eligible.sorted())
            }
            let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
            XCTAssertTrue(try outbox.pendingItems().contains { try Data(contentsOf: $0.fileURL) == payload })
            for sample in batch.samples {
                let generation = try XCTUnwrap(pending[sample.typeCode], "Generation must remain pending before ACK.")
                if let original = admitted[sample.typeCode] { XCTAssertEqual(generation, original) }
                let isDaily = sample.metadata["sample_kind"] == "daily_aggregate"
                XCTAssertEqual(try outbox.hasPendingGenerationRetirement(
                    typeCode: sample.typeCode, generation: generation
                ), isDaily, "Only daily coverage can carry the retirement marker.")
                if sample.typeCode == "steps" {
                    let cursor = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")).cursorValue(
                        receiverBindingID: binding,
                        sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                        cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
                    )
                    XCTAssertEqual(cursor, isDaily ? dailyCursor : rawCursor,
                        "Raw cursor advances only after its ACK; daily delivery preserves it.")
                }
            }
        }
    }

    func readRaw(anchor: String?, start: Date?, receivedAt: Date) throws -> HealthKitAnchoredStepChanges {
        try captureOrderBeforeRead()
        readEvents.append("steps.raw")
        if projectRawSampleDay, rawReadStarts.isEmpty {
            // Use the raw query's clock once, near the end of the last completed local day.
            sampleStart = Calendar.current.startOfDay(for: receivedAt).addingTimeInterval(-120)
            XCTAssertLessThanOrEqual(try XCTUnwrap(start), sampleStart)
        }
        rawReadStarts.append(start)
        if let anchor {
            rawAnchors.append(anchor)
            XCTAssertTrue([previousAnchor, currentAnchor].contains(anchor))
            XCTAssertNil(start)
        } else {
            XCTAssertNotNil(start)
        }
        if failRawRead {
            readEvents.append("steps.raw.failed")
            throw ReadFailure.injected
        }
        readEvents.append("steps.raw.succeeded")
        return HealthKitAnchoredStepChanges(
            stepSamples: anchor == currentAnchor ? [] : [HealthKitStepSampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000058")),
                start: sampleStart, end: sampleStart.addingTimeInterval(60), count: 17
            )],
            deletedStepSamples: [], anchorCursorValue: currentAnchor,
            windowStart: sampleStart, windowEnd: receivedAt
        )
    }

    func readDaily(types: [String], start: Date, end: Date, calendar: Calendar) throws -> [HealthKitDailyActivityAggregate] {
        try captureOrderBeforeRead()
        readEvents.append("\(types.joined(separator: ",")).daily")
        dailyRequests.append(types)
        dailyWindowStarts.append(start)
        XCTAssertFalse(types.isEmpty)
        XCTAssertTrue(Set(types).isSubset(of: ["steps", "basal_energy"]))
        XCTAssertEqual(calendar.timeZone, Calendar.current.timeZone)
        if failStepsDailyRead, types.contains("steps") { throw ReadFailure.injected }
        if emptyStepsDailyRead, types.contains("steps") { return [] }
        readEvents.append("\(types.joined(separator: ",")).daily.succeeded")
        let today = calendar.startOfDay(for: end)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let completedDay = projectRawSampleDay
            ? try XCTUnwrap(calendar.dateInterval(of: .day, for: sampleStart))
            : DateInterval(start: yesterday, end: today)
        XCTAssertLessThanOrEqual(start, completedDay.start)
        XCTAssertLessThanOrEqual(completedDay.end, today)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return types.flatMap { type in
            let completed = HealthKitDailyActivityAggregate(
                typeCode: type, dayStart: completedDay.start, dayEnd: completedDay.end,
                value: type == "steps" ? completedStepsValue : completedBasalEnergyValue,
                calendarDay: formatter.string(from: completedDay.start),
                timeZoneIdentifier: calendar.timeZone.identifier
            )
            if type == "steps" { completedStepsDay = completed }
            return [completed, HealthKitDailyActivityAggregate(
                typeCode: type, dayStart: today, dayEnd: tomorrow, value: 99,
                isComplete: false, calendarDay: formatter.string(from: today),
                timeZoneIdentifier: calendar.timeZone.identifier
            )]
        }
    }

    func declineBackgroundScheduling() -> Int {
        declinedBackgroundSchedules += 1
        return 0
    }

    private func captureOrderBeforeRead() throws {
        guard captureObservationOrder else { return }
        let manifest = root.appendingPathComponent("outbox/.fifo-sequence")
        let snapshot: Issue63OutboxOrderSnapshot?
        if FileManager.default.fileExists(atPath: manifest.path) {
            snapshot = try JSONDecoder().decode(Issue63OutboxOrderSnapshot.self, from: Data(contentsOf: manifest))
        } else {
            snapshot = nil
        }
        ordersBeforeRead.append(snapshot)
    }

    func cleanUp() {
        sessions.forEach { $0.invalidateAndCancel() }
        PayloadFenceURLProtocol.networkRecorder = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct Issue63OutboxOrderSnapshot: Decodable {
    let nextSequence: UInt64
    let observationNamespace: String?
}

private enum Issue63FixtureError: Error { case isolatedHostRequired }

private struct Issue63ObservationWire: Decodable {
    let namespace: String
    let sequence: UInt64
    let typeCode: String
    let rawIntervals: [Issue63RawIntervalWire]
    let statisticsWindow: HealthBridgeTimeWindow?

    enum CodingKeys: String, CodingKey {
        case namespace, sequence
        case typeCode = "type_code"
        case rawIntervals = "raw_intervals"
        case statisticsWindow = "statistics_window"
    }
}

private struct Issue63RawIntervalWire: Decodable {
    let clientRecordID: String
    let startTime: String
    let endTime: String

    enum CodingKeys: String, CodingKey {
        case clientRecordID = "client_record_id"
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

private struct ResetObservation {
    let queuedItemCount: Int
    let clearIntentIsActive: Bool
}

private final class HeldFirstProtocolResponse: @unchecked Sendable {
    let held = XCTestExpectation(description: "First real HTTP response is held")
    private let lock = NSLock()
    private var used = false
    private var resume: (@Sendable () -> Void)?

    func holdFirst(_ resume: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !used else {
            lock.unlock()
            return false
        }
        used = true
        self.resume = resume
        lock.unlock()
        held.fulfill()
        return true
    }

    @discardableResult
    func release() -> Bool {
        lock.lock()
        used = true
        let resume = self.resume
        self.resume = nil
        lock.unlock()
        resume?()
        return resume != nil
    }
}

private final class PayloadFenceNetworkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var recordedPayloads: [Data] = []
    private var successfulPayloads: [Data] = []
    private var failedStepsSampleKinds: Set<String> = []
    private var failedCursorKinds: Set<String> = []
    private var beforeResponse: (@Sendable (Data, Int) throws -> Void)?
    private var inspectionCount = 0
    private var forcedResponseStatusCode: Int?
    private var capabilitySupport: Bool?
    private var capabilityRequests = 0
    private var heldCapabilityHandler: (@Sendable () -> Void)?
    private var heldResponseHandler: (@Sendable (Data?, @escaping @Sendable () -> Void) -> Bool)?

    func setHeldResponseHandler(
        forPayload expectedPayload: Data? = nil,
        _ handler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Bool
    ) {
        lock.lock()
        heldResponseHandler = { payload, resume in
            (expectedPayload == nil || payload == expectedPayload) && handler(resume)
        }
        lock.unlock()
    }

    func holdResponseIfRequested(payload: Data?, resume: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        let handler = heldResponseHandler
        lock.unlock()
        return handler?(payload, resume) ?? false
    }

    func setFailedCursorKinds(_ kinds: Set<String>) {
        lock.lock()
        failedCursorKinds = kinds
        lock.unlock()
    }

    func setResponseStatusCode(_ statusCode: Int) {
        lock.lock()
        forcedResponseStatusCode = statusCode
        lock.unlock()
    }

    func setCapabilitySupport(_ supported: Bool) {
        lock.lock()
        capabilitySupport = supported
        lock.unlock()
    }

    func setHeldCapabilityHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        heldCapabilityHandler = handler
        lock.unlock()
    }

    var capabilityRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capabilityRequests
    }

    func holdCapabilityResponseIfRequested() -> Bool {
        lock.lock()
        capabilityRequests += 1
        let handler = heldCapabilityHandler
        lock.unlock()
        guard let handler else { return false }
        handler()
        return true
    }

    var capabilityResponseBody: Data? {
        lock.lock()
        let supported = capabilitySupport
        lock.unlock()
        guard let supported else { return nil }
        return Data("""
        {"schema_id":"health_bridge.receiver_capabilities.v1","batch_schema_id":"health_bridge.batch.v1","nutrition_supported":\(supported)}
        """.utf8)
    }

    func setBeforeResponse(_ inspect: @escaping @Sendable (Data, Int) throws -> Void) {
        lock.lock()
        beforeResponse = inspect
        lock.unlock()
    }

    var responseInspectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inspectionCount
    }

    func inspectBeforeResponse(_ payload: Data) throws {
        lock.lock()
        let inspect = beforeResponse
        let acceptedCount = successfulPayloads.count
        if inspect != nil { inspectionCount += 1 }
        lock.unlock()
        try inspect?(payload, acceptedCount)
    }

    func setFailedStepsSampleKinds(_ kinds: Set<String>) {
        lock.lock()
        failedStepsSampleKinds = kinds
        lock.unlock()
    }

    func responseStatusCode(for payload: Data?) -> Int {
        lock.lock()
        let failedKinds = failedStepsSampleKinds
        let failedCursors = failedCursorKinds
        let forcedStatus = forcedResponseStatusCode
        lock.unlock()
        if let forcedStatus { return forcedStatus }
        guard !failedKinds.isEmpty || !failedCursors.isEmpty else { return 200 }
        guard let payload,
              let batch = try? JSONDecoder().decode(HealthBridgeBatchV1.self, from: payload) else {
            return 500
        }
        if batch.sync.cursors.contains(where: { failedCursors.contains($0.cursorKind) }) { return 500 }
        return batch.samples.contains {
            $0.typeCode == "steps" && failedKinds.contains($0.metadata["sample_kind"] ?? "")
        } ? 500 : 200
    }

    var acceptedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return successfulPayloads
    }

    func recordAcceptedPayload(_ payload: Data) {
        lock.lock()
        successfulPayloads.append(payload)
        lock.unlock()
    }

    var payloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPayloads
    }

    func recordPayload(_ payload: Data) {
        lock.lock()
        recordedPayloads.append(payload)
        lock.unlock()
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class BootstrapInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class PayloadFenceURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var networkRecorder: PayloadFenceNetworkRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.networkRecorder?.recordInvocation()
        var payload: Data?
        if let body = request.httpBody {
            payload = body
            Self.networkRecorder?.recordPayload(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else {
                    client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeContentData))
                    return
                }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            payload = body
            Self.networkRecorder?.recordPayload(body)
        }
        let responsePayload = payload
        if request.url?.path == "/v1/capabilities",
           Self.networkRecorder?.holdCapabilityResponseIfRequested() == true { return }
        if Self.networkRecorder?.holdResponseIfRequested(
            payload: responsePayload,
            resume: { self.completeLoading(with: responsePayload) }
        ) == true { return }
        completeLoading(with: payload)
    }

    private func completeLoading(with payload: Data?) {
        let statusCode = Self.networkRecorder?.responseStatusCode(for: payload) ?? 200
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: nil,
                  headerFields: url.path == "/v1/capabilities"
                    ? ["Content-Type": "application/json", "Cache-Control": "no-store"]
                    : ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if statusCode == 200, let payload {
            do {
                try Self.networkRecorder?.inspectBeforeResponse(payload)
            } catch {
                XCTFail("Pre-ACK inspection failed.")
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = statusCode == 200 ? #"{"status":"ok"}"# : #"{"status":"synthetic_failure"}"#
        let capabilityBody = statusCode == 200 && url.path == "/v1/capabilities"
            ? Self.networkRecorder?.capabilityResponseBody : nil
        client?.urlProtocol(self, didLoad: capabilityBody ?? Data(body.utf8))
        if statusCode == 200, let payload { Self.networkRecorder?.recordAcceptedPayload(payload) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BlockingBootstrapCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: () -> Void
    private let onCancel: () -> Void
    private let releaseOnCancellation: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(
        releaseOnCancellation: Bool = true,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.releaseOnCancellation = releaseOnCancellation
        self.onStart = onStart
        self.onCancel = onCancel
    }

    func wait() async -> BackgroundUploadCancellationResult {
        onStart()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                let shouldResume = released
                if !shouldResume {
                    self.continuation = continuation
                }
                lock.unlock()
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.onCancel()
            if self.releaseOnCancellation {
                self.release()
            }
        }
        return BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

@MainActor
final class MailboxForegroundLaunchCatchUpTests: XCTestCase {
    #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
    func testFreshURLFreeNativePairingEnablesAutomaticSyncAndPublishesFirstPayloadWithAuthenticatedACK() async throws {
        let fixture = try MailboxLaunchFixture(representation: .raw, enabled: false, unpaired: true)
        let pending = MemoryReceiverTokenStore()
        let state = ReceiverPairingStateStore(
            pendingStore: pending, installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "00000000-0000-4000-8000-000000000077" },
            deviceCredentialGenerator: { "hb_" + String(repeating: "a", count: 64) }
        )
        let peer = try ExchangePeer()
        let privateRoot = fixture.root.appendingPathComponent("first-native-exchange")
        var requests: [Data] = []
        var completionReads = 0
        func requirePrivateURL(_ url: URL) throws {
            guard url.isFileURL,
                  url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/") else {
                XCTFail("Native exchange escaped the private fixture root")
                throw ExchangeFailure.invalidPeer
            }
        }
        let io = NativeMailboxPairingIO(resolve: { descriptor in
            XCTAssertEqual(descriptor, try peer.invitation().mailboxBootstrap)
            let directory = privateRoot.appendingPathComponent("pairing/\(descriptor.invitationID)")
            try requirePrivateURL(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return directory
        }, publish: { url, bytes in
            try requirePrivateURL(url)
            guard url.lastPathComponent == "request.hbp" else { throw ExchangeFailure.invalidPeer }
            let staged = try XCTUnwrap(state.loadPending())
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(try pending.loadToken().utf8)) as? [String: Any])
            let sealed = try XCTUnwrap(object["sealedRequest"] as? String)
            XCTAssertEqual(Data(base64Encoded: sealed), bytes, "Persist the exact request before publication")
            requests.append(bytes)
            try ExchangePeer.write(bytes, to: url)
            try ExchangePeer.write(peer.completion(request: bytes, pending: staged),
                to: url.deletingLastPathComponent().appendingPathComponent("completion.hbp"))
        }, read: { url in
            try requirePrivateURL(url)
            if url.lastPathComponent == "completion.hbp" { completionReads += 1 }
            return FileManager.default.fileExists(atPath: url.path) ? .available(try Data(contentsOf: url)) : .missing
        }, hydrate: { url in
            try requirePrivateURL(url)
        }, wait: { throw ExchangeFailure.responseUnavailable })
        let keysBefore = try fixture.keys.loadOrCreate()
        let freshAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 43))
        let freshSampleID = UUID()
        var rawBindings: [String] = []
        var rawAnchors: [String?] = []
        let runtime = try fixture.makeRuntime(
            cleanup: nil, nativeMailboxIO: io, pairingStateStore: state,
            firstReaderOverride: { anchor, _, now in
                let record = try XCTUnwrap(fixture.settings.currentConnectionRecordV2())
                guard case .available(let identity) = record.mailboxIdentity else {
                    throw ExchangeFailure.invalidPeer
                }
                XCTAssertEqual(identity.opaqueBinding, peer.expectedBinding)
                XCTAssertEqual(record.localScope.bindingID, identity.opaqueBinding)
                XCTAssertNil(try fixture.cursors.cursorValue(
                    receiverBindingID: identity.opaqueBinding,
                    sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                    cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
                ))
                rawBindings.append(identity.opaqueBinding)
                rawAnchors.append(anchor)
                fixture.reads.append("raw")
                if anchor == fixture.nextAnchor {
                    // New data is ready before the second opportunity, even though its
                    // first turn belongs to the previously acknowledged raw checkpoint.
                    let start = Calendar.current.startOfDay(for: now)
                    return HealthKitAnchoredStepChanges(
                        stepSamples: [HealthKitStepSampleSummary(
                            uuid: freshSampleID, start: start, end: now, count: 29
                        )],
                        deletedStepSamples: [], anchorCursorValue: freshAnchor,
                        windowStart: start, windowEnd: now
                    )
                }
                XCTAssertNil(anchor, "The initial raw payload must not be replayed from a different anchor.")
                return fixture.rawChanges(now: now, hasRecords: true)
            },
            deliveryOverride: { try fixture.nativeFlowDelivery(peer: peer) },
            authorizationOverride: { _ in
                XCTFail("Automatic work must not request HealthKit authorization")
                throw ExchangeFailure.invalidPeer
            }
        )
        addTeardownBlock { @MainActor in
            fixture.readSuspension?.release()
            await runtime.viewModel.waitForAutomaticSyncPreferenceWorkForTesting()
            runtime.viewModel.requestBackgroundSyncEnabled(false)
            await runtime.viewModel.waitForAutomaticSyncDisableCleanup()
            await fixture.join(runtime)
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        await runtime.bootstrap()
        await fixture.join(runtime)
        XCTAssertNil(try fixture.settings.currentConnectionRecordV2())
        XCTAssertNil(fixture.settings.receiverBindingID)
        XCTAssertTrue(try fixture.settings.receiverSettingsAreCleared(),
            "An unpaired URL display default is not a committed HTTP connection")
        XCTAssertTrue(try fixture.settings.loadBearerToken().isEmpty)
        XCTAssertEqual(try fixture.keys.publicSummary().state, .active)
        XCTAssertTrue(runtime.viewModel.healthPermissionsRequested)
        XCTAssertFalse(runtime.viewModel.hasPendingPrivateStorageRecovery)
        XCTAssertFalse(runtime.viewModel.hasTransientPrivateStorageFailure)
        XCTAssertFalse(fixture.outbox.destructiveRecoveryIsRequested)
        XCTAssertFalse(runtime.viewModel.backgroundSyncRequestedEnabled)
        XCTAssertFalse(runtime.viewModel.backgroundSyncEnabled)
        XCTAssertFalse(runtime.viewModel.automaticSyncToggleIsOn)
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        let generationBeforeImport = fixture.settings.receiverSettingsGenerationToken
        let invitation = try JSONEncoder().encode(peer.invitation())
        let link = try XCTUnwrap(URL(string: "healthbridge://pair?payload=\(ExchangePeer.b64(invitation))"))

        await runtime.viewModel.importPairingURL(link)

        XCTAssertEqual(requests.count, 1)
        XCTAssertGreaterThan(completionReads, 0)
        XCTAssertNil(try state.loadPending())
        let committed = try XCTUnwrap(fixture.settings.currentConnectionRecordV2())
        guard case .available(let identity) = committed.mailboxIdentity else {
            XCTFail("Fresh native enrollment must commit its authenticated identity")
            throw ExchangeFailure.invalidPeer
        }
        let generation = fixture.settings.receiverSettingsGenerationToken
        XCTAssertNotEqual(generation, generationBeforeImport)
        XCTAssertEqual(committed.activation, .paired(activeTransport: .mailbox))
        XCTAssertEqual(committed.localScope.bindingID, identity.opaqueBinding)
        XCTAssertEqual(fixture.settings.receiverBindingID, identity.opaqueBinding)
        XCTAssertEqual(identity.opaqueBinding, peer.expectedBinding)
        XCTAssertEqual(identity.deviceSigningKeyID, keysBefore.signingKeyID)
        XCTAssertEqual(identity.deviceAgreementKeyID, keysBefore.agreementKeyID)
        XCTAssertEqual(identity.receiverSigningPublicKey, ExchangePeer.b64(peer.signing.publicKey.rawRepresentation))
        XCTAssertEqual(identity.receiverAgreementPublicKey, ExchangePeer.b64(peer.agreement.publicKey.rawRepresentation))
        XCTAssertEqual(runtime.viewModel.setupState, .ready)
        XCTAssertTrue(runtime.viewModel.receiverSettingsSaved)
        XCTAssertFalse(runtime.viewModel.statusIsError)
        XCTAssertFalse(runtime.viewModel.canSaveReceiverSettings)
        XCTAssertTrue(runtime.viewModel.canSendConnectionTest)
        XCTAssertTrue(runtime.viewModel.canChangeAutomaticSyncSetting)
        XCTAssertTrue(runtime.viewModel.healthPermissionsRequested)
        XCTAssertFalse(runtime.viewModel.hasPendingPrivateStorageRecovery)
        XCTAssertFalse(runtime.viewModel.hasTransientPrivateStorageFailure)
        XCTAssertTrue(runtime.viewModel.receiverURLString.isEmpty)
        XCTAssertTrue(runtime.viewModel.bearerToken.isEmpty)
        XCTAssertTrue(fixture.settings.receiverURLString.isEmpty)
        XCTAssertTrue(try fixture.settings.loadBearerToken().isEmpty)
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertFalse(runtime.viewModel.backgroundSyncRequestedEnabled)
        XCTAssertFalse(runtime.viewModel.backgroundSyncEnabled)
        XCTAssertFalse(runtime.viewModel.automaticSyncToggleIsOn)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.keys.loadOrCreate(), keysBefore)
        XCTAssertEqual(runtime.viewModel.automaticSyncSelectedEligibleTypeCodes(), ["steps"])
        XCTAssertNil(try fixture.cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ))

        runtime.viewModel.requestBackgroundSyncEnabled(true)
        await runtime.viewModel.waitForAutomaticSyncPreferenceWorkForTesting()
        await fixture.join(runtime)

        XCTAssertTrue(runtime.viewModel.backgroundSyncRequestedEnabled,
            "The committed native connection must permit automatic enable without HTTP settings")
        XCTAssertTrue(runtime.viewModel.backgroundSyncEnabled)
        XCTAssertTrue(runtime.viewModel.automaticSyncToggleIsOn)
        XCTAssertTrue(fixture.background.isEnabled)
        XCTAssertFalse(runtime.viewModel.statusIsError, runtime.viewModel.statusMessage)
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), committed)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertEqual(try fixture.keys.loadOrCreate(), keysBefore)
        XCTAssertTrue(runtime.viewModel.receiverURLString.isEmpty)
        XCTAssertTrue(runtime.viewModel.bearerToken.isEmpty)
        XCTAssertTrue(fixture.settings.receiverURLString.isEmpty)
        XCTAssertTrue(try fixture.settings.loadBearerToken().isEmpty)
        // Fail boundedly at the completed enable decision; never wait for a success signal.
        _ = try XCTUnwrap(fixture.background.isEnabled ? true : nil,
            "NOT_REACHED: encrypted first payload and ACK until enable succeeds")
        XCTAssertEqual(rawBindings, [identity.opaqueBinding], "One first read on the authenticated new binding")
        XCTAssertEqual(rawAnchors, [nil], "The first raw read starts without a shared or automatic anchor")
        XCTAssertGreaterThan(fixture.deliveryConstructions, 0)
        let beforeACK = try fixture.outbox.pendingItems()
        let item = try XCTUnwrap(beforeACK.first, "The real automatic owner must enqueue its first payload")
        XCTAssertEqual(item.receiverIdentity, identity.opaqueBinding)
        XCTAssertEqual(item.deliveryState?.phase, .providerObserved)
        let components = try fixture.nativeFlowComponents(peer: peer)
        let locator = try components.locate()
        let envelopeID = try components.transport.finalizedEnvelopeID(itemID: item.id)
        let envelopeName = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .delivery)
        let envelopeURL = try XCTUnwrap(locator.lanes[.deliveries]).appendingPathComponent(envelopeName)
        let envelope = try Data(contentsOf: envelopeURL)
        let opened = try DeliveryProtocolV1.openDelivery(envelope, context: DeliveryEnvelopeOpenContext(
            receiverID: components.ackContext.receiverID, deviceID: components.ackContext.deviceID,
            connectionGeneration: Int64(identity.connectionGeneration),
            receiverAgreementPrivateKey: peer.agreement,
            senderSigningPublicKey: components.deviceSigningPublicKey
        ))
        let payload = try Data(contentsOf: item.fileURL)
        XCTAssertEqual(opened.plaintext, payload)
        XCTAssertEqual(opened.payloadSHA256, ExchangePeer.hex(ExchangePeer.hash(payload)))
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: opened.plaintext)
        XCTAssertEqual(batch.samples.map(\.typeCode), ["steps"])
        XCTAssertEqual(batch.samples.first?.metadata["sample_kind"], "raw_quantity")
        XCTAssertEqual(batch.samples.first?.value, 17)
        XCTAssertEqual(batch.sync.cursors.first {
            $0.cursorKind == StepCountSyncBatchFactory.anchoredCursorKind
        }?.cursorValue, fixture.nextAnchor)
        XCTAssertNil(try fixture.cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), "Publication alone must not advance the raw cursor")
        let noACK = try await fixture.nativeFlowDelivery(peer: peer)
            .reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(noACK.finalizedCount, 0)
        XCTAssertEqual(try fixture.outbox.pendingItems(), beforeACK)
        XCTAssertNil(try fixture.cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ))
        let pendingSteps = try fixture.pending()
        XCTAssertNotNil(pendingSteps["steps"])
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        await fixture.join(runtime)
        XCTAssertEqual(fixture.reads, ["raw"], "An unacknowledged raw head must block further collection")
        XCTAssertEqual(try fixture.outbox.pendingItems(), beforeACK)
        XCTAssertEqual(try fixture.pending(), pendingSteps)

        let unrelatedBytes = try beforeACK.dropFirst().map { try Data(contentsOf: $0.fileURL) }
        func sealACK(envelopeID: Data, payloadSHA256: String, receiptID: Int64) throws -> Data {
            try DeliveryProtocolV1.sealAck(
                DeliveryReceiptV1(
                    result: .committed, payloadSHA256: payloadSHA256,
                    receiptID: receiptID, datasetGeneration: 1,
                    committedAtMS: Int64(Date().timeIntervalSince1970 * 1_000), errorCode: nil
                ),
                context: DeliveryAckSealContext(
                    envelopeID: envelopeID, receiverID: components.ackContext.receiverID,
                    deviceID: components.ackContext.deviceID,
                    connectionGeneration: Int64(identity.connectionGeneration),
                    deviceAgreementPublicKey: try fixture.keys.agreementPrivateKey().publicKey,
                    receiverSigningPrivateKey: peer.signing, receiverAgreementPrivateKey: peer.agreement
                )
            )
        }
        let ack = try sealACK(envelopeID: envelopeID, payloadSHA256: opened.payloadSHA256, receiptID: 1)
        let ackName = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .acknowledgment)
        let ackURL = try XCTUnwrap(locator.lanes[.acks]).appendingPathComponent(ackName)
        try ack.write(to: ackURL, options: [.withoutOverwriting])
        let accepted = try await fixture.nativeFlowDelivery(peer: peer)
            .reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(accepted.finalizedCount, 1)
        XCTAssertEqual(accepted.hydration.requestedDownloadCount, 0)
        XCTAssertNil(try fixture.outbox.pendingItem(id: item.id))
        XCTAssertEqual(try fixture.outbox.pendingItems(), Array(beforeACK.dropFirst()),
            "An authenticated ACK retires only its FIFO item, not unrelated daily/cursor work")
        XCTAssertEqual(try beforeACK.dropFirst().map { try Data(contentsOf: $0.fileURL) }, unrelatedBytes)
        XCTAssertNil(try fixture.cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), "Cursorless automatic fallback must not initialize shared progress, even after committed ACK")
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), committed)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertEqual(try fixture.keys.loadOrCreate(), keysBefore)
        XCTAssertFalse(runtime.viewModel.canSaveReceiverSettings)
        XCTAssertTrue(runtime.viewModel.receiverURLString.isEmpty)
        XCTAssertTrue(runtime.viewModel.bearerToken.isEmpty)
        XCTAssertTrue(fixture.background.isEnabled)
        XCTAssertEqual(try fixture.pending(), pendingSteps, "Raw ACK must leave daily Steps work pending")
        let automaticAnchorKind = GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "steps")
        func automaticAnchor() throws -> String? {
            try fixture.cursors.cursorValue(
                receiverBindingID: identity.opaqueBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: automaticAnchorKind
            )
        }
        XCTAssertEqual(try automaticAnchor(), fixture.nextAnchor)

        fixture.offerData = true
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        await fixture.join(runtime)
        XCTAssertEqual(fixture.reads, ["raw", "daily"],
            "Acknowledged raw coverage must get a daily turn even when fresh raw is available")
        let nextItems = try fixture.outbox.pendingItems()
        XCTAssertEqual(nextItems.count, 1)
        let nextItem = try XCTUnwrap(nextItems.first)
        XCTAssertEqual(nextItem.deliveryState?.phase, .providerObserved)
        let nextPayload = try Data(contentsOf: nextItem.fileURL)
        let nextBatch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: nextPayload)
        XCTAssertFalse(nextBatch.samples.isEmpty)
        XCTAssertTrue(nextBatch.samples.allSatisfy {
            $0.metadata["sample_kind"] == "daily_aggregate" && $0.metadata["aggregation_completeness"] == "complete"
        })
        XCTAssertEqual(try fixture.pending(), pendingSteps, "Publication must not retire the pending Steps generation")

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        await fixture.join(runtime)
        XCTAssertEqual(fixture.reads, ["raw", "daily"], "A held daily head must also block fresh raw collection")
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [nextItem.id])
        XCTAssertEqual(try Data(contentsOf: nextItem.fileURL), nextPayload)
        XCTAssertEqual(try automaticAnchor(), fixture.nextAnchor)

        let dailyEnvelopeID = try components.transport.finalizedEnvelopeID(itemID: nextItem.id)
        let dailyACK = try sealACK(
            envelopeID: dailyEnvelopeID, payloadSHA256: ExchangePeer.hex(ExchangePeer.hash(nextPayload)), receiptID: 2
        )
        let dailyACKName = try MailboxLayoutV1.finalFileName(identifier: dailyEnvelopeID.hexV1, kind: .acknowledgment)
        try dailyACK.write(to: ackURL.deletingLastPathComponent().appendingPathComponent(dailyACKName),
            options: [.withoutOverwriting])
        let dailyAccepted = try await fixture.nativeFlowDelivery(peer: peer)
            .reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(dailyAccepted.finalizedCount, 1)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.pending(), pendingSteps, "This daily turn cannot retire unread raw work")

        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .scheduledRefresh)
        await fixture.join(runtime)
        XCTAssertEqual(fixture.reads, ["raw", "daily", "raw"])
        XCTAssertEqual(rawAnchors, [nil, fixture.nextAnchor], "Fresh raw resumes from the exact ACK's checkpoint")
        let freshItems = try fixture.outbox.pendingItems()
        XCTAssertEqual(freshItems.count, 1)
        let freshItem = try XCTUnwrap(freshItems.first)
        XCTAssertEqual(freshItem.deliveryState?.phase, .providerObserved)
        let freshBatch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: freshItem.fileURL))
        XCTAssertEqual(freshBatch.samples.map(\.value), [29])
        XCTAssertEqual(freshBatch.samples.map { $0.metadata["sample_kind"] }, ["raw_quantity"])
        XCTAssertEqual(try automaticAnchor(), fixture.nextAnchor, "Publishing new raw cannot advance its checkpoint")
        XCTAssertNil(try fixture.cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ))
        XCTAssertFalse(fixture.proofs.hasUploadedRecords(lane: .steps, receiverBindingID: identity.opaqueBinding))

        #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        // Only this isolated synthetic fixture's already-observed wire and keys.
        let witness: [String: Any] = [
            "schema_version": 1,
            "envelope_b64": envelope.base64EncodedString(),
            "ack_b64": ack.base64EncodedString(),
            "plaintext_b64": opened.plaintext.base64EncodedString(),
            "receiver_id_hex": identity.receiverID,
            "device_id_hex": identity.deviceID,
            "connection_generation": identity.connectionGeneration,
            "receiver_agreement_private_key_b64": peer.agreement.rawRepresentation.base64EncodedString(),
            "receiver_signing_private_key_b64": peer.signing.rawRepresentation.base64EncodedString(),
            "device_signing_public_key_b64": components.deviceSigningPublicKey.rawRepresentation.base64EncodedString(),
            "device_agreement_private_key_b64": try fixture.keys.agreementPrivateKey().rawRepresentation.base64EncodedString(),
            "payload_sha256": opened.payloadSHA256,
        ]
        let witnessData = try JSONSerialization.data(withJSONObject: witness, options: [.sortedKeys])
        print("HERMES_SYNTHETIC_NATIVE_INTEROP_V1 " + String(decoding: witnessData, as: UTF8.self))
        #endif
    }
    #endif

    func testFreshNativePairingUsesComposedOwnerWithoutHTTPOrAutomaticSync() async throws {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Build the App host and test target with HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST.")
        #else
        let fixture = try MailboxLaunchFixture(representation: .raw, enabled: false, unpaired: true)
        XCTAssertNil(try fixture.settings.currentConnectionRecordV2())
        let pending = MemoryReceiverTokenStore()
        let state = ReceiverPairingStateStore(
            pendingStore: pending, installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { "00000000-0000-4000-8000-000000000077" },
            deviceCredentialGenerator: { "hb_" + String(repeating: "a", count: 64) }
        )
        let peer = try ExchangePeer()
        let privateRoot = fixture.root.appendingPathComponent("native-exchange")
        var publishedRequests: [Data] = []
        var responseReads = 0
        let io = NativeMailboxPairingIO(resolve: { descriptor in
            XCTAssertEqual(descriptor, try peer.invitation().mailboxBootstrap)
            let directory = privateRoot.appendingPathComponent("pairing/\(descriptor.invitationID)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return directory
        }, publish: { url, bytes in
            guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/") else {
                XCTFail("Operation escaped private fixture root")
                throw ExchangeFailure.invalidPeer
            }
            guard url.lastPathComponent == "request.hbp" else { throw ExchangeFailure.invalidPeer }
            let staged = try XCTUnwrap(state.loadPending())
            let encoded = try pending.loadToken()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
            let sealed = try XCTUnwrap(object["sealedRequest"] as? String)
            XCTAssertEqual(Data(base64Encoded: sealed), bytes, "Persist request before publishing")
            publishedRequests.append(bytes)
            try ExchangePeer.write(bytes, to: url)
            try ExchangePeer.write(peer.completion(request: bytes, pending: staged),
                to: url.deletingLastPathComponent().appendingPathComponent("completion.hbp"))
        }, read: { url in
            guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/") else {
                XCTFail("Operation escaped private fixture root")
                throw ExchangeFailure.invalidPeer
            }
            if url.lastPathComponent == "completion.hbp" { responseReads += 1 }
            return FileManager.default.fileExists(atPath: url.path) ? .available(try Data(contentsOf: url)) : .missing
        }, hydrate: { url in
            guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/") else {
                XCTFail("Operation escaped private fixture root")
                throw ExchangeFailure.invalidPeer
            }
        }, wait: { throw ExchangeFailure.responseUnavailable })
        let runtime = try fixture.makeRuntime(cleanup: nil, nativeMailboxIO: io, pairingStateStore: state)
        addTeardownBlock { @MainActor in
            fixture.readSuspension?.release()
            await runtime.viewModel.waitForAutomaticSyncDisableCleanup()
            await fixture.join(runtime)
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        let keysBefore = try fixture.keys.loadOrCreate()
        await runtime.bootstrap()
        let generationBeforeImport = fixture.settings.receiverSettingsGenerationToken
        XCTAssertNil(fixture.settings.receiverBindingID)
        XCTAssertEqual(try fixture.cursors.cursorValue(
            receiverBindingID: fixture.identity.opaqueBinding,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), fixture.previousAnchor)
        XCTAssertEqual(try fixture.cursors.cursorValue(
            receiverBindingID: fixture.identity.opaqueBinding,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
        ), fixture.previousDailyCursor)
        let invitation = try JSONEncoder().encode(peer.invitation())
        let link = try XCTUnwrap(URL(string: "healthbridge://pair?payload=\(ExchangePeer.b64(invitation))"))
        await runtime.viewModel.importPairingURL(link)
        XCTAssertEqual(runtime.viewModel.setupState, .ready, "Fresh native pairing must publish ready immediately without reload or relaunch")
        XCTAssertFalse(runtime.viewModel.statusIsError, "Successful native pairing must not leave an error presentation")
        XCTAssertEqual(publishedRequests.count, 1, "NOT_REACHED: native request publication")
        XCTAssertGreaterThan(responseReads, 0, "NOT_REACHED: authenticated response")
        let record = try XCTUnwrap(fixture.settings.currentConnectionRecordV2())
        XCTAssertEqual(record.activation, .paired(activeTransport: .mailbox))
        guard case .available(let identity) = record.mailboxIdentity else { return XCTFail("No native commit") }
        XCTAssertEqual(identity.opaqueBinding, peer.expectedBinding)
        XCTAssertTrue(fixture.settings.receiverURLString.isEmpty)
        XCTAssertTrue(try fixture.settings.loadBearerToken().isEmpty)
        XCTAssertNil(try state.loadPending())
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(record.localScope.bindingID, identity.opaqueBinding)
        XCTAssertNotEqual(fixture.settings.receiverSettingsGenerationToken, generationBeforeImport)
        for binding in [fixture.identity.opaqueBinding, identity.opaqueBinding] {
            let rawCursor = try fixture.cursors.cursorValue(
                receiverBindingID: binding,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
            )
            let dailyCursor = try fixture.cursors.cursorValue(
                receiverBindingID: binding,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
            )
            XCTAssertNil(rawCursor)
            XCTAssertNil(dailyCursor)
        }
        XCTAssertEqual(try fixture.keys.loadOrCreate(), keysBefore)
        #endif
    }

    func testInterruptedNativePairingRetryReusesPublishedRequest() async throws {
        try await assertInterruptedNativePairingRecovery(coldBootstrap: false, superseded: false)
    }

    func testNativePairingRetryWaitsForPayloadlessDirectSleepCleanup() async throws {
        try await assertInterruptedNativePairingRecovery(
            coldBootstrap: false, superseded: false, protectDirectSleep: true
        )
    }

    func testInterruptedNativePairingColdBootstrapReusesPublishedRequest() async throws {
        try await assertInterruptedNativePairingRecovery(coldBootstrap: true, superseded: false)
    }

    func testInterruptedNativePairingRejectsSupersededGeneration() async throws {
        try await assertInterruptedNativePairingRecovery(coldBootstrap: false, superseded: true)
    }

    func testInterruptedNativePairingMatchingReimportCompletesPublishedRequest() async throws {
        try await assertInterruptedNativePairingRecovery(coldBootstrap: false, superseded: false, reimport: true)
    }

    func testInterruptedNativePairingConflictingReimportDoesNotPoisonPublishedRequest() async throws {
        try await assertInterruptedNativePairingRecovery(
            coldBootstrap: false, superseded: false, reimport: true, conflictingReimports: true
        )
    }

    func testInterruptedNativePairingReimportRejectsSupersededGeneration() async throws {
        try await assertInterruptedNativePairingRecovery(coldBootstrap: false, superseded: true, reimport: true)
    }

    func testInterruptedNativePairingMatchingTextReimportCompletesPublishedRequest() async throws {
        try await assertInterruptedNativePairingRecovery(
            coldBootstrap: false, superseded: false, textReimport: true
        )
    }

    func testInterruptedNativePairingConflictingTextReimportDoesNotPoisonPublishedRequest() async throws {
        try await assertInterruptedNativePairingRecovery(
            coldBootstrap: false, superseded: false, conflictingReimports: true, textReimport: true
        )
    }

    func testInterruptedNativePairingTextReimportRejectsSupersededGeneration() async throws {
        try await assertInterruptedNativePairingRecovery(
            coldBootstrap: false, superseded: true, textReimport: true
        )
    }

    func testConfirmedPrivateResetClearsPublishedNativePairingWithoutReceipt() async throws {
        let fixture = try MailboxLaunchFixture(representation: .raw, enabled: false, unpaired: true)
        let state = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore()
        )
        let peer = try ExchangePeer()
        let directory = fixture.root.appendingPathComponent("native-private-reset")
        var publications = 0
        let io = NativeMailboxPairingIO(resolve: { _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return directory
        }, publish: { url, bytes in
            guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
                  url.lastPathComponent == "request.hbp"
                else { throw ExchangeFailure.invalidPeer }
            XCTAssertTrue(try XCTUnwrap(state.loadPending()).publicationMayHaveOccurred)
            publications += 1
            try ExchangePeer.write(bytes, to: url)
        }, read: { _ in .missing }, hydrate: { _ in }, wait: { throw ExchangeFailure.responseUnavailable })
        let runtime = try fixture.makeRuntime(cleanup: nil, nativeMailboxIO: io, pairingStateStore: state)
        addTeardownBlock { @MainActor in
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        let keys = try fixture.keys.loadOrCreate()
        await runtime.bootstrap()
        let invitation = try JSONEncoder().encode(peer.invitation())
        let link = try XCTUnwrap(URL(string: "healthbridge://pair?payload=\(ExchangePeer.b64(invitation))"))
        await runtime.viewModel.importPairingURL(link)
        await fixture.join(runtime)
        let pending = try XCTUnwrap(state.loadPending())
        XCTAssertTrue(pending.publicationMayHaveOccurred)
        XCTAssertFalse(pending.nativeCancellationConfirmed)
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(runtime.viewModel.hasPendingPairing)

        await runtime.viewModel.clearPendingOutbox()
        await fixture.join(runtime)

        XCTAssertNil(try state.loadPending())
        XCTAssertFalse(try state.hasPendingCancellation())
        XCTAssertFalse(runtime.viewModel.hasPendingPairing)
        XCTAssertFalse(runtime.viewModel.hasPendingOutboxDeletion)
        XCTAssertFalse(runtime.viewModel.statusIsError, runtime.viewModel.statusMessage)
        XCTAssertTrue(try fixture.settings.receiverSettingsAreCleared())
        XCTAssertEqual(try fixture.keys.loadOrCreate(), keys)
        XCTAssertEqual(publications, 1, "Explicit local reset must not invent remote confirmation")
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertTrue(fixture.reads.isEmpty)
    }

    func testUnavailableNativeContainerCanBeCancelledLocally() async throws {
        let fixture = try MailboxLaunchFixture(representation: .raw, enabled: false, unpaired: true)
        let state = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore()
        )
        let peer = try ExchangePeer()
        var resolutions = 0
        var publications = 0
        let io = NativeMailboxPairingIO(resolve: { _ in
            resolutions += 1
            throw ExchangeFailure.responseUnavailable
        }, publish: { _, _ in publications += 1 }, read: { _ in .missing },
            hydrate: { _ in }, wait: { throw ExchangeFailure.responseUnavailable })
        let runtime = try fixture.makeRuntime(cleanup: nil, nativeMailboxIO: io, pairingStateStore: state)
        addTeardownBlock { @MainActor in
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        await runtime.bootstrap()
        let invitation = try JSONEncoder().encode(peer.invitation())
        let link = try XCTUnwrap(URL(string: "healthbridge://pair?payload=\(ExchangePeer.b64(invitation))"))
        await runtime.viewModel.importPairingURL(link)
        await fixture.join(runtime)
        XCTAssertTrue(runtime.viewModel.hasPendingPairing)
        XCTAssertFalse(try XCTUnwrap(state.loadPending()).publicationMayHaveOccurred)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(publications, 0)

        await runtime.viewModel.cancelPendingPairing()
        await fixture.join(runtime)

        XCTAssertNil(try state.loadPending())
        XCTAssertFalse(try state.hasPendingCancellation())
        XCTAssertNil(fixture.settings.terminalCancellationExpectedGeneration)
        XCTAssertFalse(runtime.viewModel.hasPendingPairing)
        XCTAssertFalse(runtime.viewModel.statusIsError, runtime.viewModel.statusMessage)
        XCTAssertEqual(resolutions, 1, "A never-published cancellation must not require the unavailable provider")
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(try fixture.settings.receiverSettingsAreCleared())
    }

    func testPublishedNativePairingCancellationReachesAuthenticatedReceipt() async throws {
        try await assertPublishedNativeCancellation(coldBootstrap: false, immediateReceipt: true)
    }

    func testPublishedNativePairingCancellationRetriesMissingAndInvalidReceipt() async throws {
        try await assertPublishedNativeCancellation(coldBootstrap: false, immediateReceipt: false)
    }

    func testPublishedNativePairingCancellationResumesAfterColdBootstrap() async throws {
        try await assertPublishedNativeCancellation(coldBootstrap: true, immediateReceipt: false)
    }

    func testPublishedNativePairingCancellationPreservesExistingDirectConnection() async throws {
        try await assertPublishedNativeCancellation(coldBootstrap: false, immediateReceipt: true, preserveDirect: true)
    }

    func testLocallyCommittedNativePairingCancellationRetriesPendingCleanup() async throws {
        try await assertPublishedNativeCancellation(coldBootstrap: false, immediateReceipt: false, locallyCommitted: true)
    }

    func testLocallyCommittedNativePairingCancellationRecoversAfterColdBootstrap() async throws {
        try await assertPublishedNativeCancellation(coldBootstrap: true, immediateReceipt: false, locallyCommitted: true)
    }

    private func assertPublishedNativeCancellation(
        coldBootstrap: Bool, immediateReceipt: Bool, preserveDirect: Bool = false,
        locallyCommitted: Bool = false
    ) async throws {
        let fixture = try MailboxLaunchFixture(representation: .raw, enabled: false, unpaired: true)
        if preserveDirect {
            try fixture.settings.save(
                receiverURLString: "https://receiver.invalid/v1/batches",
                bearerToken: "synthetic-existing-direct"
            )
        }
        let pendingStore = MemoryReceiverTokenStore()
        let state = ReceiverPairingStateStore(
            pendingStore: pendingStore, installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore()
        )
        let peer = try ExchangePeer()
        let privateRoot = fixture.root.appendingPathComponent("native-cancel")
        var requests: [Data] = []
        var cancellations: [Data] = []
        var receiptAvailable = immediateReceipt
        let io = NativeMailboxPairingIO(resolve: { descriptor in
            XCTAssertEqual(descriptor, try peer.invitation().mailboxBootstrap)
            let directory = privateRoot.appendingPathComponent(descriptor.invitationID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return directory
        }, publish: { url, bytes in
            guard url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/")
                else { throw ExchangeFailure.invalidPeer }
            if FileManager.default.fileExists(atPath: url.path),
               try MailboxRegularFileReader.read(url, maximumBytes: 65_536) != bytes {
                throw MailboxPublicationError.conflict
            }
            let pending = try XCTUnwrap(state.loadPending())
            let request = try XCTUnwrap(pending.sealedRequest)
            XCTAssertTrue(pending.publicationMayHaveOccurred)
            switch url.lastPathComponent {
            case "request.hbp":
                XCTAssertEqual(bytes, request)
                requests.append(bytes)
                if locallyCommitted {
                    try ExchangePeer.write(peer.completion(request: request, pending: pending),
                        to: url.deletingLastPathComponent().appendingPathComponent("completion.hbp"))
                }
            case "cancel.hbp":
                cancellations.append(bytes)
                try ExchangePeer.write(peer.cancelled(cancel: bytes, request: request),
                    to: url.deletingLastPathComponent().appendingPathComponent("cancelled.hbp"))
            default:
                throw ExchangeFailure.invalidPeer
            }
            try ExchangePeer.write(bytes, to: url)
        }, read: { url in
            guard url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/")
                else { throw ExchangeFailure.invalidPeer }
            if locallyCommitted, url.lastPathComponent == "completion.hbp" {
                pendingStore.rejectNextEmptySave = true
                return .available(try Data(contentsOf: url))
            }
            if url.lastPathComponent == "cancel.hbp" {
                return FileManager.default.fileExists(atPath: url.path) ? .available(try Data(contentsOf: url)) : .missing
            }
            guard url.lastPathComponent == "cancelled.hbp", receiptAvailable else { return .missing }
            return .available(try Data(contentsOf: url))
        }, hydrate: { url in
            guard url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/")
                else { throw ExchangeFailure.invalidPeer }
        }, wait: { throw ExchangeFailure.responseUnavailable })
        let initial = try fixture.makeRuntime(cleanup: nil, nativeMailboxIO: io, pairingStateStore: state)
        addTeardownBlock { @MainActor in
            initial.automaticSyncRuntime.stopAdmission()
            await initial.automaticSyncRuntime.cancelAndWait()
            await fixture.join(initial)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        let originalKeys = try fixture.keys.loadOrCreate()
        await initial.bootstrap()
        let invitation = try JSONEncoder().encode(peer.invitation())
        let link = try XCTUnwrap(URL(string: "healthbridge://pair?payload=\(ExchangePeer.b64(invitation))"))
        await initial.viewModel.importPairingURL(link)
        await fixture.join(initial)
        let pending = try XCTUnwrap(state.loadPending())
        let request = try XCTUnwrap(pending.sealedRequest)
        let generation = try XCTUnwrap(pending.nativeExpectedGeneration)
        XCTAssertEqual(requests, [request])
        XCTAssertTrue(pending.publicationMayHaveOccurred)
        let cursorBytes = try Data(contentsOf: fixture.cursors.fileURL)
        let connectionBeforeCancellation = try fixture.settings.currentConnectionRecordV2()
        let cancellationGeneration = fixture.settings.receiverSettingsGenerationToken
        if locallyCommitted {
            XCTAssertFalse(pendingStore.rejectNextEmptySave, "The real pending erase must have been attempted")
            let committed = try XCTUnwrap(connectionBeforeCancellation)
            XCTAssertEqual(committed.activation, .paired(activeTransport: .mailbox))
            XCTAssertEqual(committed.localScope.bindingID, peer.expectedBinding)
            XCTAssertEqual(committed.localScope.generation, try XCTUnwrap(UInt64(generation.dropFirst())) + 1)
        } else {
            XCTAssertEqual(cancellationGeneration, generation)
        }

        await initial.viewModel.cancelPendingPairing()
        await fixture.join(initial)
        XCTAssertEqual(cancellations.count, 1, "App cancellation must publish request-bound native intent")
        var resumed = initial
        if !immediateReceipt {
            XCTAssertEqual(try state.loadPending(), pending)
            XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, cancellationGeneration)
            XCTAssertTrue(initial.viewModel.hasPendingPairing)
            XCTAssertTrue(initial.viewModel.statusIsError)
            XCTAssertTrue(try state.hasPendingCancellation())

            receiptAvailable = true
            peer.receiptTamper = "requestDigest"
            await initial.viewModel.retryPendingPairing()
            await fixture.join(initial)
            XCTAssertEqual(cancellations.count, 2, "Retry must reach the native exchange despite pending cleanup")
            XCTAssertEqual(try state.loadPending(), pending, "An unrelated receipt cannot erase pending authority")
            XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, cancellationGeneration)
            XCTAssertTrue(initial.viewModel.hasPendingPairing)
            XCTAssertTrue(initial.viewModel.statusIsError)

            peer.receiptTamper = nil
            if coldBootstrap {
                initial.automaticSyncRuntime.stopAdmission()
                await initial.automaticSyncRuntime.cancelAndWait()
                await fixture.join(initial)
                resumed = try fixture.makeRuntime(cleanup: nil, nativeMailboxIO: io, pairingStateStore: state)
                let restored = resumed
                addTeardownBlock { @MainActor in
                    restored.automaticSyncRuntime.stopAdmission()
                    await restored.automaticSyncRuntime.cancelAndWait()
                    await fixture.join(restored)
                }
                await resumed.bootstrap()
            } else {
                await resumed.viewModel.retryPendingPairing()
            }
            await fixture.join(resumed)
            XCTAssertEqual(cancellations.count, 3)
        }
        XCTAssertNil(try state.loadPending())
        XCTAssertFalse(try state.hasPendingCancellation())
        XCTAssertNil(fixture.settings.terminalCancellationExpectedGeneration)
        XCTAssertFalse(resumed.viewModel.hasPendingPairing)
        XCTAssertFalse(resumed.viewModel.statusIsError, resumed.viewModel.statusMessage)
        XCTAssertEqual(resumed.viewModel.receiverSettingsSaved, preserveDirect)
        XCTAssertEqual(try fixture.settings.receiverSettingsAreCleared(), !preserveDirect)
        if locallyCommitted {
            XCTAssertEqual(try fixture.settings.currentConnectionRecordV2()?.activation, .unpaired)
        } else {
            XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), connectionBeforeCancellation)
        }
        XCTAssertEqual(resumed.viewModel.receiverURLString, fixture.settings.receiverURLString)
        XCTAssertEqual(resumed.viewModel.bearerToken, try fixture.settings.loadBearerToken())
        XCTAssertEqual(requests.count, cancellations.count + 1)
        XCTAssertTrue(requests.allSatisfy { $0 == request })
        XCTAssertEqual(try fixture.keys.loadOrCreate(), originalKeys)
        if locallyCommitted {
            XCTAssertNil(try fixture.cursors.cursorValue(
                receiverBindingID: fixture.identity.opaqueBinding,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
            ))
        } else {
            XCTAssertEqual(try Data(contentsOf: fixture.cursors.fileURL), cursorBytes)
        }
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
    }

    private func assertInterruptedNativePairingRecovery(
        coldBootstrap: Bool, superseded: Bool, reimport: Bool = false, conflictingReimports: Bool = false,
        textReimport: Bool = false, protectDirectSleep: Bool = false
    ) async throws {
        let fixture = try MailboxLaunchFixture(representation: .raw, enabled: false, unpaired: true)
        let state = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore()
        )
        if protectDirectSleep {
            try fixture.settings.save(
                receiverURLString: "http://127.0.0.1:8765/v1/batches",
                bearerToken: "synthetic-pairing-retry-direct-token", rotateBindingID: true
            )
        }
        let peer = try ExchangePeer()
        let privateRoot = fixture.root.appendingPathComponent("native-resume")
        var requests: [Data] = []
        var completionAvailable = false
        var responseReads = 0
        let io = NativeMailboxPairingIO(resolve: { descriptor in
            XCTAssertEqual(descriptor, try peer.invitation().mailboxBootstrap)
            let directory = privateRoot.appendingPathComponent(descriptor.invitationID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return directory
        }, publish: { url, bytes in
            guard url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/"),
                  url.lastPathComponent == "request.hbp" else { throw ExchangeFailure.invalidPeer }
            let pending = try XCTUnwrap(state.loadPending())
            XCTAssertEqual(pending.sealedRequest, bytes)
            XCTAssertTrue(pending.publicationMayHaveOccurred)
            requests.append(bytes)
            try ExchangePeer.write(bytes, to: url)
            try ExchangePeer.write(peer.completion(request: bytes, pending: pending),
                to: url.deletingLastPathComponent().appendingPathComponent("completion.hbp"))
        }, read: { url in
            guard url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/")
                else { throw ExchangeFailure.invalidPeer }
            guard completionAvailable else { return .missing }
            responseReads += 1
            return .available(try Data(contentsOf: url))
        }, hydrate: { url in
            guard url.standardizedFileURL.path.hasPrefix(privateRoot.standardizedFileURL.path + "/")
                else { throw ExchangeFailure.invalidPeer }
        }, wait: { throw ExchangeFailure.responseUnavailable })
        let initial = try fixture.makeRuntime(cleanup: nil, nativeMailboxIO: io, pairingStateStore: state)
        addTeardownBlock { @MainActor in
            initial.automaticSyncRuntime.stopAdmission()
            await initial.automaticSyncRuntime.cancelAndWait()
            await fixture.join(initial)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        let originalKeys = try fixture.keys.loadOrCreate()
        await initial.bootstrap()
        let invitation = try JSONEncoder().encode(peer.invitation())
        let link = try XCTUnwrap(URL(string: "healthbridge://pair?payload=\(ExchangePeer.b64(invitation))"))
        await initial.viewModel.importPairingURL(link)
        await fixture.join(initial)
        XCTAssertEqual(requests.count, 1, "Initial request must reach native publication")
        XCTAssertEqual(responseReads, 0)
        let publishedRequest = try XCTUnwrap(requests.first)
        let pending = try XCTUnwrap(state.loadPending())
        XCTAssertTrue(initial.viewModel.hasPendingPairing)
        XCTAssertTrue(initial.viewModel.statusIsError)
        XCTAssertEqual(initial.viewModel.receiverSettingsSaved, protectDirectSleep)
        let requestGeneration = try XCTUnwrap(pending.nativeExpectedGeneration)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, requestGeneration)

        if conflictingReimports {
            let originalRecord = try fixture.settings.currentConnectionRecordV2()
            let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: invitation) as? [String: Any])
            var conflicts: [[String: Any]] = []
            for (key, value) in [
                ("invitation_secret", "hbi_different_synthetic_invitation"),
                ("expires_at", "2098-01-01T00:00:00Z"),
            ] {
                var changed = originalObject
                changed[key] = value
                conflicts.append(changed)
            }
            let otherPeer = try ExchangePeer(signingByte: 0x41)
            conflicts.append(try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(otherPeer.invitation())) as? [String: Any]))
            var direct = originalObject
            direct.removeValue(forKey: "mailbox_bootstrap")
            direct.removeValue(forKey: "mailbox_protocol_version")
            direct["transport"] = "direct"
            direct["receiver_url"] = "https://synthetic.invalid"
            direct["redeem_url"] = "https://synthetic.invalid/pair/redeem"
            conflicts.append(direct)
            for conflict in conflicts {
                initial.viewModel.pairingImportText = String(
                    decoding: try JSONSerialization.data(withJSONObject: conflict), as: UTF8.self
                )
                await initial.viewModel.importPairingText()
                await fixture.join(initial)
                XCTAssertTrue(initial.viewModel.statusIsError)
                XCTAssertEqual(try state.loadPending(), pending, "Conflicting import must retain the original request")
                XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, requestGeneration,
                    "Rejected invitation must not invalidate the original native authority")
                XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), originalRecord)
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(responseReads, 0)
            }
        }

        if superseded {
            _ = try fixture.settings.invalidateReceiverSettingsGeneration()
        }
        let beforeRetry = try fixture.settings.currentConnectionRecordV2()
        completionAvailable = true
        if protectDirectSleep {
            let installationID = try state.loadOrCreateInstallationID()
            let previous = SleepSyncBatchFactory.makeManifestReservation(
                receiverSettingsGeneration: requestGeneration, historyDepth: .allAvailable, historyStartDate: nil,
                sourceKey: "apple_health.phone.\(installationID.lowercased())", baselineResetEpoch: 1
            )
            try fixture.background.markPendingObserverTypeCodes(["sleep_analysis"])
            let generations = try fixture.background.loadPendingObserverTypeCodeGenerations()
            let (item, sleepPending) = try HealthBridgeCompanionResetAdmissionTests.stageSleepForConnectionTransition(
                settings: fixture.settings, outbox: fixture.outbox, store: fixture.sleep,
                previous: previous, generations: generations
            )
            let cleanup = try HealthBridgeCompanionResetAdmissionTests.recordPayloadlessSleepCleanup(
                item, pending: sleepPending, outbox: fixture.outbox, store: fixture.sleep
            )

            await initial.viewModel.retryPendingPairing()
            await fixture.join(initial)

            XCTAssertTrue(initial.viewModel.statusIsError)
            XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), beforeRetry)
            XCTAssertEqual(try state.loadPending(), pending, "The published native request keeps its original authority.")
            XCTAssertEqual(requests, [publishedRequest])
            XCTAssertEqual(responseReads, 0)
            XCTAssertNil(try fixture.sleep.loadPendingTransition())
            XCTAssertEqual(try fixture.sleep.loadManifest(), sleepPending.manifest)
            XCTAssertNil(try fixture.outbox.directSleepCleanupIntent(for: cleanup))
            XCTAssertNil(try fixture.outbox.directFinalizationRecordReady(receiverIdentity: sleepPending.receiverBindingID))
            XCTAssertTrue(try fixture.background.loadPendingObserverTypeCodeGenerations().isEmpty)
        }
        let resumed: HealthBridgeCompanionApplicationRuntime
        if coldBootstrap {
            initial.automaticSyncRuntime.stopAdmission()
            await initial.automaticSyncRuntime.cancelAndWait()
            await fixture.join(initial)
            resumed = try fixture.makeRuntime(cleanup: nil, nativeMailboxIO: io, pairingStateStore: state)
            addTeardownBlock { @MainActor in
                resumed.automaticSyncRuntime.stopAdmission()
                await resumed.automaticSyncRuntime.cancelAndWait()
                await fixture.join(resumed)
            }
            await resumed.bootstrap()
        } else {
            resumed = initial
            if textReimport {
                resumed.viewModel.pairingImportText = String(decoding: invitation, as: UTF8.self)
                await resumed.viewModel.importPairingText()
            } else if reimport {
                await resumed.viewModel.importPairingURL(link)
            } else {
                await resumed.viewModel.retryPendingPairing()
            }
        }
        await fixture.join(resumed)
        if superseded {
            XCTAssertTrue(resumed.viewModel.statusIsError)
            XCTAssertFalse(resumed.viewModel.receiverSettingsSaved)
            XCTAssertEqual(try state.loadPending(), pending)
            XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), beforeRetry)
            XCTAssertEqual(requests.count, 1, "Stale authority must not republish")
            XCTAssertEqual(responseReads, 0, "Stale authority must not read a completion")
        } else {
            XCTAssertEqual(resumed.viewModel.setupState, .ready, resumed.viewModel.statusMessage)
            XCTAssertFalse(resumed.viewModel.statusIsError)
            XCTAssertTrue(resumed.viewModel.receiverSettingsSaved)
            XCTAssertNil(try state.loadPending())
            XCTAssertEqual(requests.count, 2)
            XCTAssertGreaterThan(responseReads, 0)
            let record = try XCTUnwrap(fixture.settings.currentConnectionRecordV2())
            XCTAssertEqual(record.activation, .paired(activeTransport: .mailbox))
            XCTAssertEqual(record.localScope.bindingID, peer.expectedBinding)
            let requestGenerationNumber = try XCTUnwrap(UInt64(requestGeneration.dropFirst()))
            XCTAssertEqual(record.localScope.generation, requestGenerationNumber + 1)
            if protectDirectSleep {
                let direct = DirectHTTPConnectionConfigurationV1(
                    receiverURLString: "http://127.0.0.1:8765/v1/batches",
                    bearerToken: "synthetic-pairing-retry-direct-token"
                )
                XCTAssertEqual(record.transportConfigurations, [
                    .directHTTP(activation: .inactive, configuration: direct),
                    .mailbox(activation: .active, configuration: MailboxConnectionConfigurationV1()),
                ])
                XCTAssertEqual(fixture.settings.receiverURLString, direct.receiverURLString)
            } else {
                XCTAssertTrue(fixture.settings.receiverURLString.isEmpty)
            }
        }
        XCTAssertTrue(requests.allSatisfy { $0 == publishedRequest })
        XCTAssertEqual(try fixture.keys.loadOrCreate(), originalKeys)
        if !protectDirectSleep {
            XCTAssertTrue(try fixture.settings.loadBearerToken().isEmpty)
        }
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
    }

    func testURLFreeMailboxConnectionCheckUsesCommittedIdentityWithoutHTTPOrSync() async throws {
        let (fixture, runtime) = try makeFixture(representation: .raw, enabled: false, mailboxOnly: true)
        await runtime.bootstrap()
        await fixture.join(runtime)

        let record = try XCTUnwrap(fixture.settings.currentConnectionRecordV2())
        let generation = fixture.settings.receiverSettingsGenerationToken
        let keys = try fixture.keys.loadOrCreate()
        let cursorBytes = try Data(contentsOf: fixture.cursors.fileURL)
        let deliveryConstructions = fixture.deliveryConstructions
        XCTAssertEqual(record.activation, .paired(activeTransport: .mailbox))
        XCTAssertEqual(record.mailboxIdentity, .available(fixture.identity))
        XCTAssertEqual(record.localScope.bindingID, fixture.identity.opaqueBinding)
        XCTAssertEqual(fixture.settings.receiverBindingID, record.localScope.bindingID)
        XCTAssertEqual(try fixture.keys.publicSummary().state, .active)
        XCTAssertEqual(keys.signingKeyID, fixture.identity.deviceSigningKeyID)
        XCTAssertEqual(keys.agreementKeyID, fixture.identity.deviceAgreementKeyID)
        XCTAssertTrue(runtime.viewModel.receiverSettingsSaved)
        XCTAssertEqual(runtime.viewModel.setupState, .ready)
        XCTAssertFalse(runtime.viewModel.canSaveReceiverSettings)
        XCTAssertTrue(runtime.viewModel.receiverURLString.isEmpty)
        XCTAssertTrue(runtime.viewModel.bearerToken.isEmpty)
        XCTAssertTrue(fixture.settings.receiverURLString.isEmpty)
        XCTAssertTrue(try fixture.settings.loadBearerToken().isEmpty)
        XCTAssertFalse(runtime.viewModel.backgroundSyncRequestedEnabled)
        XCTAssertFalse(runtime.viewModel.backgroundSyncEnabled)
        XCTAssertFalse(runtime.viewModel.automaticSyncToggleIsOn)
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertTrue(runtime.viewModel.canSendConnectionTest,
            "A ready URL-free Mailbox connection must admit its connection check without HTTP editor credentials")

        await runtime.viewModel.checkConnection()

        XCTAssertEqual(fixture.deliveryConstructions, deliveryConstructions + 1,
            "Connection check must construct the real fixture-local Mailbox delivery exactly once")
        XCTAssertFalse(runtime.viewModel.statusIsError)
        XCTAssertEqual(runtime.viewModel.statusMessage,
            "Mailbox folder is ready on this iPhone. Receiver delivery has not been verified.")
        XCTAssertTrue(runtime.viewModel.receiverSettingsSaved)
        XCTAssertEqual(runtime.viewModel.setupState, .ready)
        XCTAssertFalse(runtime.viewModel.canSaveReceiverSettings)
        XCTAssertTrue(runtime.viewModel.receiverURLString.isEmpty)
        XCTAssertTrue(runtime.viewModel.bearerToken.isEmpty)
        XCTAssertTrue(fixture.settings.receiverURLString.isEmpty)
        XCTAssertTrue(try fixture.settings.loadBearerToken().isEmpty)
        XCTAssertFalse(runtime.viewModel.backgroundSyncRequestedEnabled)
        XCTAssertFalse(runtime.viewModel.backgroundSyncEnabled)
        XCTAssertFalse(runtime.viewModel.automaticSyncToggleIsOn)
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), record)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertEqual(try fixture.keys.loadOrCreate(), keys)
        XCTAssertEqual(try Data(contentsOf: fixture.cursors.fileURL), cursorBytes)
    }

    func testURLFreeMailboxColdRestoreIsReadyWithAutomaticSyncExplicitlyOff() async throws {
        try await assertMailboxColdRestoreIsReady(mailboxOnly: true)
    }

    func testURLBearingMailboxColdRestoreIsReadyWithAutomaticSyncExplicitlyOff() async throws {
        try await assertMailboxColdRestoreIsReady(mailboxOnly: false)
    }

    func testConfirmedPrivateResetUnpairsLostKeyMailboxWithoutRegeneratingKeys() async throws {
        // Given: Keychain material survives but the local trust files are lost.
        let fixture = try MailboxLaunchFixture(
            representation: .raw, enabled: false, mailboxOnly: true
        )
        try fixture.keychain.removeTrust(service: fixture.keyService, record: .expectedIdentity)
        try fixture.keychain.removeTrust(service: fixture.keyService, record: .monotonicGeneration)
        let runtime = try fixture.makeRuntime(cleanup: nil)
        addTeardownBlock { @MainActor in
            await runtime.viewModel.waitForAutomaticSyncDisableCleanup()
            await fixture.join(runtime)
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        await runtime.bootstrap()
        await fixture.join(runtime)
        XCTAssertEqual(runtime.viewModel.mailboxKeyDiagnosticState, .lost)
        XCTAssertFalse(runtime.viewModel.canSendConnectionTest)
        XCTAssertFalse(runtime.viewModel.canResetLostMailboxConnectionKey)

        // When: the user explicitly confirms private sync-state reset.
        await runtime.viewModel.clearPendingOutbox()
        await fixture.join(runtime)

        // Then: key replacement remains explicit, but its recovery is reachable.
        XCTAssertTrue(try fixture.settings.receiverSettingsAreCleared())
        XCTAssertEqual(fixture.keys.diagnosticState(), .lost)
        XCTAssertTrue(runtime.viewModel.canResetLostMailboxConnectionKey)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertTrue(fixture.reads.isEmpty)
    }

    func testConfirmedPrivateResetKeepsHealthyMailboxConnection() async throws {
        // Given: a healthy committed Mailbox connection with automatic sync off.
        let (fixture, runtime) = try makeFixture(
            representation: .raw, enabled: false, mailboxOnly: true
        )
        await runtime.bootstrap()
        await fixture.join(runtime)
        let record = try fixture.settings.currentConnectionRecordV2()
        let keys = try fixture.keys.loadOrCreate()
        XCTAssertTrue(runtime.viewModel.canSendConnectionTest)
        let transferStore = makeResetTestTransferStore(root: fixture.root, defaults: fixture.defaults)
        let transfer = LastAcceptedTransferObservation(
            bindingID: try XCTUnwrap(fixture.settings.receiverBindingID),
            generation: fixture.settings.receiverSettingsGenerationToken,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000), evidenceKind: .mailboxCommit
        )
        transferStore.record(transfer)
        XCTAssertEqual(transferStore.load(bindingID: transfer.bindingID, generation: transfer.generation), transfer)

        // When: the user explicitly resets local sync progress.
        await runtime.viewModel.clearPendingOutbox()
        await fixture.join(runtime)

        // Then: healthy connection authority and keys are not discarded.
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), record)
        XCTAssertEqual(try fixture.keys.loadOrCreate(), keys)
        XCTAssertNil(transferStore.load(bindingID: transfer.bindingID, generation: transfer.generation))
        XCTAssertTrue(runtime.viewModel.canSendConnectionTest)
        XCTAssertTrue(fixture.reads.isEmpty)
    }

    func testConfirmedPrivateResetKeepsDirectConnectionWithLostMailboxKeys() async throws {
        // Given: Direct is paired while the unused Mailbox trust files are lost.
        let fixture = try MailboxLaunchFixture(
            representation: .raw, enabled: false, unpaired: true
        )
        try fixture.settings.save(
            receiverURLString: "https://receiver.example/v1/batches",
            bearerToken: "synthetic-direct-credential"
        )
        try fixture.keychain.removeTrust(service: fixture.keyService, record: .expectedIdentity)
        try fixture.keychain.removeTrust(service: fixture.keyService, record: .monotonicGeneration)
        let runtime = try fixture.makeRuntime(cleanup: nil)
        addTeardownBlock { @MainActor in
            await runtime.viewModel.waitForAutomaticSyncDisableCleanup()
            await fixture.join(runtime)
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        await runtime.bootstrap()
        await fixture.join(runtime)
        let record = try fixture.settings.currentConnectionRecordV2()
        XCTAssertEqual(fixture.settings.activeTransport, .directHTTP)
        XCTAssertEqual(fixture.keys.diagnosticState(), .lost)

        // When: the user explicitly resets local sync progress.
        await runtime.viewModel.clearPendingOutbox()
        await fixture.join(runtime)

        // Then: unused Mailbox key loss must not remove Direct authority.
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), record)
        XCTAssertEqual(try fixture.settings.loadBearerToken(), "synthetic-direct-credential")
        XCTAssertEqual(fixture.keys.diagnosticState(), .lost)
        XCTAssertTrue(runtime.viewModel.canSendConnectionTest)
        XCTAssertTrue(fixture.reads.isEmpty)
    }

    private func assertMailboxColdRestoreIsReady(mailboxOnly: Bool) async throws {
        let (fixture, runtime) = try makeFixture(representation: .raw, enabled: false, mailboxOnly: mailboxOnly)
        let record = try XCTUnwrap(fixture.settings.currentConnectionRecordV2())
        let keys = try fixture.keys.loadOrCreate()
        let generation = fixture.settings.receiverSettingsGenerationToken

        await runtime.bootstrap()
        await fixture.join(runtime)

        XCTAssertTrue(runtime.viewModel.receiverSettingsSaved)
        XCTAssertEqual(runtime.viewModel.setupState, .ready)
        XCTAssertFalse(runtime.viewModel.automaticSyncToggleIsOn)
        XCTAssertFalse(fixture.background.isEnabled)
        XCTAssertFalse(runtime.viewModel.automaticSyncRuntimeIsReady)
        XCTAssertEqual(try fixture.settings.currentConnectionRecordV2(), record)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertEqual(try fixture.keys.loadOrCreate(), keys)
        XCTAssertEqual(try Data(contentsOf: fixture.cursors.fileURL), fixture.initialCursorBytes)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertTrue(fixture.reads.isEmpty)
    }

    func testReadyMailboxForegroundLaunchResumesDurablePendingWithEmptyOutbox() async throws {
        for representation in MailboxLaunchFixture.Representation.allCases {
            let (fixture, runtime) = try makeFixture(representation: representation)
            await runtime.bootstrap()
            await fixture.join(runtime)
            XCTAssertTrue(runtime.viewModel.automaticSyncRuntimeIsReady)
            try await fixture.arm(runtime)
            let deliveryCalls = fixture.deliveryConstructions

            runtime.runForegroundCatchUpIfNeeded()
            await fixture.join(runtime)

            XCTAssertGreaterThan(fixture.deliveryConstructions, deliveryCalls,
                "The real foreground mailbox path must enter and naturally return.")
            try await fixture.assertCollectedAndAcknowledge()
        }
    }

    func testMailboxBootstrapResumesPreReadyDurableObserverWithoutSecondTrigger() async throws {
        for representation in MailboxLaunchFixture.Representation.allCases {
            let entered = expectation(description: "actual bootstrap cleanup entered")
            let barrier = BlockingBootstrapCleanup(onStart: { entered.fulfill() }, onCancel: {})
            let (fixture, runtime) = try makeFixture(representation: representation, cleanup: barrier)
            fixture.offerData = true
            runtime.prepareForBackgroundLaunch()
            let bootstrap = Task { @MainActor in await runtime.bootstrap() }
            addTeardownBlock { @MainActor in
                barrier.release()
                await bootstrap.value
            }
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertFalse(runtime.viewModel.automaticSyncRuntimeIsReady)
            XCTAssertTrue(fixture.reads.isEmpty)
            try fixture.admitObserver(runtime)
            let admitted = try fixture.pending()
            XCTAssertEqual(admitted.keys.sorted(), ["steps"])

            barrier.release()
            await bootstrap.value
            await fixture.join(runtime)

            XCTAssertTrue(runtime.viewModel.automaticSyncRuntimeIsReady)
            XCTAssertGreaterThan(fixture.deliveryConstructions, 0,
                "Bootstrap activation must reach actual mailbox reconciliation.")
            XCTAssertEqual(try fixture.pending(), admitted)
            try await fixture.assertCollectedAndAcknowledge()
        }
    }

    func testScheduledRefreshProcessesSameMailboxDurablePending() async throws {
        for representation in MailboxLaunchFixture.Representation.allCases {
            let (fixture, runtime) = try makeFixture(representation: representation)
            await runtime.bootstrap()
            await fixture.join(runtime)
            try await fixture.arm(runtime)

            await runtime.handleBackgroundRefresh()
            await fixture.join(runtime)

            XCTAssertEqual(fixture.refreshesConsumed, 1)
            XCTAssertGreaterThan(fixture.ownersStarted, 0)
            XCTAssertEqual(fixture.ownersFinished, fixture.ownersStarted)
            XCTAssertEqual(fixture.diagnostics.latestRecord?.triggerReason, .scheduledRefresh)
            XCTAssertNotNil(fixture.background.lastRun?.finishedAt)
            try await fixture.assertCollectedAndAcknowledge()
        }
    }

    func testMailboxFirstRawStepsACKWithNoPriorAnchorOpensDailyCollection() async throws {
        let (fixture, runtime) = try makeFixture(representation: .raw, hasPriorRawAnchor: false)
        let binding = fixture.identity.opaqueBinding
        let source = HealthBridgeAppleHealthSource.phone.sourceKey
        let rawKind = StepCountSyncBatchFactory.anchoredCursorKind
        let fallbackKind = GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "steps")
        func cursor(_ kind: String) throws -> String? {
            try fixture.cursors.cursorValue(receiverBindingID: binding, sourceKey: source, cursorKind: kind)
        }

        await runtime.bootstrap()
        await fixture.join(runtime)
        try await fixture.arm(runtime)
        let pending = try fixture.pending()
        let generation = try XCTUnwrap(pending["steps"])
        XCTAssertNil(try cursor(rawKind))
        XCTAssertNil(try cursor(fallbackKind))

        await runtime.handleBackgroundRefresh()
        await fixture.join(runtime)
        XCTAssertEqual(fixture.reads, ["raw"])
        let raw = try XCTUnwrap(fixture.outbox.pendingItems().first)
        XCTAssertEqual(raw.deliveryState?.phase, .providerObserved)
        XCTAssertNil(try cursor(fallbackKind), "Publishing raw bytes is not an ACK.")

        await runtime.handleBackgroundRefresh()
        await fixture.join(runtime)
        XCTAssertEqual(fixture.reads, ["raw"], "A published but unacknowledged item must still block collection.")
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [raw.id])
        XCTAssertEqual(try fixture.pending(), pending)

        try await fixture.acknowledge(raw)
        XCTAssertEqual(try cursor(fallbackKind), fixture.nextAnchor)
        XCTAssertNil(try cursor(rawKind), "An automatic bounded read must not establish the shared anchor.")
        XCTAssertEqual(try fixture.pending(), pending, "A raw ACK does not satisfy the observer's daily coverage.")

        await runtime.handleBackgroundRefresh()
        await fixture.join(runtime)
        XCTAssertEqual(fixture.reads, ["raw", "daily"], "The first post-ACK read must be daily even with raw data still available.")
        let daily = try XCTUnwrap(fixture.outbox.pendingItems().first)
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: daily.fileURL))
        XCTAssertFalse(batch.samples.isEmpty)
        XCTAssertTrue(batch.samples.allSatisfy { $0.metadata["sample_kind"] == "daily_aggregate" })
        XCTAssertFalse(try fixture.outbox.hasPendingGenerationRetirement(typeCode: "steps", generation: generation))
        try await fixture.acknowledge(daily)
        XCTAssertEqual(try fixture.pending(), pending, "The priority turn may not retire later unread raw work.")
    }

    func testMailboxAcknowledgedStepsProjectionRetriesAfterDailyReadFailure() async throws {
        for rawReadFails in [true, false] {
            let (fixture, runtime) = try makeFixture(representation: .raw)
            await runtime.bootstrap()
            await fixture.join(runtime)
            try await fixture.arm(runtime)

            await runtime.handleBackgroundRefresh()
            await fixture.join(runtime)
            try await fixture.assertCollectedAndAcknowledge()
            let admitted = try fixture.pending()
            let generation = try XCTUnwrap(admitted["steps"])
            let freshAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 43))
            fixture.followUpRawAnchor = freshAnchor
            fixture.failDailyStepsRead = true

            await runtime.handleBackgroundRefresh()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.reads, ["raw", "daily"], "The raw ACK must open one actual daily query.")
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty, "The daily query threw before enqueue.")
            XCTAssertEqual(try fixture.pending(), admitted)

            fixture.failRawStepsRead = rawReadFails
            // Keep statistics unavailable until raw has had its opportunity.
            await runtime.handleBackgroundRefresh()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.reads, ["raw", "daily", "raw"])
            if rawReadFails {
                XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
            } else {
                let freshRaw = try XCTUnwrap(fixture.outbox.pendingItems().first)
                let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: freshRaw.fileURL))
                XCTAssertEqual(batch.samples.map { $0.metadata["sample_kind"] }, ["raw_quantity"])
                XCTAssertEqual(batch.sync.cursors.first {
                    $0.cursorKind == StepCountSyncBatchFactory.anchoredCursorKind
                }?.cursorValue, freshAnchor)
                await runtime.handleBackgroundRefresh()
                await fixture.join(runtime)
                XCTAssertEqual(fixture.reads, ["raw", "daily", "raw"], "Daily must wait for the fresh raw FIFO head.")
                XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [freshRaw.id])
                try await fixture.acknowledge(freshRaw)
            }
            XCTAssertEqual(try fixture.pending(), admitted)

            fixture.failDailyStepsRead = false
            await runtime.handleBackgroundRefresh()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.reads, ["raw", "daily", "raw", "daily"],
                "Recovered daily statistics must be queried even when the intervening raw read still fails.")
            let items = try fixture.outbox.pendingItems()
            XCTAssertEqual(items.count, 1)
            let daily = try XCTUnwrap(items.first)
            let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: daily.fileURL))
            XCTAssertFalse(batch.samples.isEmpty)
            XCTAssertTrue(batch.samples.allSatisfy { $0.metadata["sample_kind"] == "daily_aggregate" })
            XCTAssertFalse(try fixture.outbox.hasPendingGenerationRetirement(typeCode: "steps", generation: generation))
            try await fixture.acknowledge(daily)
            XCTAssertEqual(try fixture.pending(), admitted, "A projection turn cannot retire unread raw work.")
        }
    }

    func testMailboxPreACKCursorComparisonRejectsOtherReceiverProjectionTurnMutation() throws {
        let (fixture, _) = try makeFixture(representation: .raw)
        let kind = "mailbox_steps_projection_turn"
        let source = HealthBridgeAppleHealthSource.phone.sourceKey
        let unrelatedBinding = Data(repeating: 0x55, count: 32).base64URLEncodedString()
        try fixture.cursors.saveCursorValue("old", receiverBindingID: unrelatedBinding, sourceKey: source, cursorKind: kind)
        let decoder = JSONDecoder()
        let before = try decoder.decode([String: String].self, from: Data(contentsOf: fixture.cursors.fileURL))
        try fixture.cursors.saveCursorValue("turn", receiverBindingID: fixture.identity.opaqueBinding, sourceKey: source, cursorKind: kind)
        let scopedTurnOnly = try decoder.decode([String: String].self, from: Data(contentsOf: fixture.cursors.fileURL))
        XCTAssertEqual(fixture.preACKCursorMap(before, allowRawProjectionTurn: true),
                       fixture.preACKCursorMap(scopedTurnOnly, allowRawProjectionTurn: true))
        XCTAssertNotEqual(fixture.preACKCursorMap(before, allowRawProjectionTurn: false),
                          fixture.preACKCursorMap(scopedTurnOnly, allowRawProjectionTurn: false))

        try fixture.cursors.saveCursorValue("changed", receiverBindingID: unrelatedBinding, sourceKey: source, cursorKind: kind)
        let unrelatedTurnChanged = try decoder.decode([String: String].self, from: Data(contentsOf: fixture.cursors.fileURL))
        for allowRawProjectionTurn in [true, false] {
            XCTAssertNotEqual(fixture.preACKCursorMap(scopedTurnOnly, allowRawProjectionTurn: allowRawProjectionTurn),
                              fixture.preACKCursorMap(unrelatedTurnChanged, allowRawProjectionTurn: allowRawProjectionTurn))
        }
    }

    func testForegroundMailboxWaitingHeadDoesNotCollectNewData() async throws {
        let (fixture, runtime) = try makeFixture(representation: .raw)
        await runtime.bootstrap()
        await fixture.join(runtime)
        try await fixture.arm(runtime)
        let head = try fixture.enqueueWaitingSteps()
        _ = try await fixture.delivery().publishPendingFIFOHead()
        let before = try fixture.outbox.pendingItems()
        XCTAssertEqual(before.map(\.id), [head.id])
        XCTAssertEqual(before.first?.deliveryState?.phase, .providerObserved)
        let payload = try Data(contentsOf: head.fileURL)
        let pending = try fixture.pending()
        let deliveryCalls = fixture.deliveryConstructions

        runtime.runForegroundCatchUpIfNeeded()
        await fixture.join(runtime)

        XCTAssertGreaterThan(fixture.deliveryConstructions, deliveryCalls)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [head.id])
        XCTAssertEqual(try Data(contentsOf: head.fileURL), payload)
        XCTAssertEqual(try fixture.pending(), pending)
        try fixture.assertOldProgress()
    }

    func testAutomaticSyncOFFBlocksForegroundCatchUp() async throws {
        let (fixture, runtime) = try makeFixture(representation: .raw, enabled: false)
        fixture.offerData = true
        try fixture.background.markPendingObserverTypeCodes(["steps"])
        let pending = try fixture.pending()
        await runtime.bootstrap()
        await fixture.join(runtime)
        XCTAssertTrue(runtime.viewModel.canSendConnectionTest)
        XCTAssertFalse(runtime.viewModel.automaticSyncRuntimeIsReady)
        XCTAssertGreaterThanOrEqual(fixture.platformDrains, 2,
            "OFF bootstrap must complete both ordinary and exclusive-transfer drains.")

        runtime.runForegroundCatchUpIfNeeded()
        await fixture.join(runtime)

        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertEqual(fixture.ownersStarted, 0)
        XCTAssertEqual(fixture.deliveryConstructions, 0)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try fixture.pending(), pending)
        try fixture.assertOldProgress()
    }

    func testForegroundEntryBeforeReadinessResumesAfterBootstrap() async throws {
        for representation in MailboxLaunchFixture.Representation.allCases {
            let entered = expectation(description: "bootstrap cleanup suspended before foreground entry")
            let barrier = BlockingBootstrapCleanup(onStart: { entered.fulfill() }, onCancel: {})
            let (fixture, runtime) = try makeFixture(representation: representation, cleanup: barrier)
            fixture.offerData = true
            try fixture.admitObserver(runtime)
            let bootstrap = Task { @MainActor in await runtime.bootstrap() }
            addTeardownBlock { @MainActor in
                barrier.release()
                await bootstrap.value
            }
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertFalse(runtime.viewModel.automaticSyncRuntimeIsReady)

            runtime.runForegroundCatchUpIfNeeded()
            XCTAssertTrue(fixture.reads.isEmpty)
            XCTAssertEqual(fixture.ownersStarted, 0)
            barrier.release()
            await bootstrap.value
            await fixture.join(runtime)

            XCTAssertTrue(runtime.viewModel.automaticSyncRuntimeIsReady)
            XCTAssertEqual(fixture.ownersStarted, 1)
            XCTAssertEqual(fixture.ownersFinished, 1)
            try await fixture.assertCollectedAndAcknowledge()
        }
    }

    func testRepeatedForegroundEntryDuringReadHasOneCollectionOwner() async throws {
        for representation in MailboxLaunchFixture.Representation.allCases {
            let (fixture, runtime) = try makeFixture(representation: representation)
            await runtime.bootstrap()
            await fixture.join(runtime)
            try await fixture.arm(runtime)
            let startedBefore = fixture.ownersStarted
            let finishedBefore = fixture.ownersFinished
            let (suspension, completion) = try await suspendForegroundRead(fixture, runtime)

            runtime.runForegroundCatchUpIfNeeded()
            runtime.runForegroundCatchUpIfNeeded()
            runtime.runForegroundCatchUpIfNeeded()
            XCTAssertEqual(fixture.ownersStarted - startedBefore, 1)
            XCTAssertEqual(fixture.ownersFinished, finishedBefore)
            XCTAssertEqual(suspension.enteredCount, 1)
            XCTAssertEqual(suspension.returnedCount, 0)
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
            try fixture.assertOldProgress()
            suspension.release()
            await completion()
            await fixture.join(runtime)

            XCTAssertEqual(fixture.ownersStarted - startedBefore, 1)
            XCTAssertEqual(fixture.ownersFinished - finishedBefore, 1)
            XCTAssertEqual(suspension.returnedCount, 1)
            try await fixture.assertCollectedAndAcknowledge()
        }
    }

    func testDisablingAutomaticSyncDuringReadRejectsReleasedResult() async throws {
        for representation in MailboxLaunchFixture.Representation.allCases {
            let (fixture, runtime) = try makeFixture(representation: representation)
            await runtime.bootstrap()
            await fixture.join(runtime)
            try await fixture.arm(runtime)
            let admitted = try fixture.pending()
            let (suspension, completion) = try await suspendForegroundRead(fixture, runtime)
            let deliveryCalls = fixture.deliveryConstructions

            runtime.viewModel.requestBackgroundSyncEnabled(false)
            XCTAssertFalse(runtime.viewModel.automaticSyncToggleIsOn)
            XCTAssertFalse(fixture.background.isEnabled)
            XCTAssertEqual(suspension.returnedCount, 0)
            suspension.release()
            await completion()
            await runtime.viewModel.waitForAutomaticSyncDisableCleanup()
            await fixture.join(runtime)

            XCTAssertEqual(suspension.returnedCount, 1)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            XCTAssertFalse(runtime.viewModel.automaticSyncRuntimeIsReady)
            XCTAssertEqual(fixture.deliveryConstructions, deliveryCalls)
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
            XCTAssertEqual(try fixture.pending(), admitted)
            try fixture.assertOldProgress()
            XCTAssertFalse(runtime.viewModel.statusIsError)
        }
    }

    func testConnectionReplacementDuringReadRejectsOldBindingResult() async throws {
        for representation in MailboxLaunchFixture.Representation.allCases {
            let (fixture, runtime) = try makeFixture(representation: representation)
            await runtime.bootstrap()
            await fixture.join(runtime)
            try await fixture.arm(runtime)
            let admitted = try fixture.pending()
            let oldGeneration = fixture.settings.receiverSettingsGenerationToken
            let (suspension, completion) = try await suspendForegroundRead(fixture, runtime)
            let deliveryCalls = fixture.deliveryConstructions

            let replacementBinding = try fixture.replaceMailboxConnectionWhileOutboxIsEmpty()
            XCTAssertNotEqual(fixture.settings.receiverSettingsGenerationToken, oldGeneration)
            XCTAssertNotEqual(replacementBinding, fixture.identity.opaqueBinding)
            XCTAssertEqual(fixture.settings.receiverBindingID, replacementBinding)
            XCTAssertEqual(suspension.returnedCount, 0)
            suspension.release()
            await completion()
            await fixture.join(runtime)

            XCTAssertEqual(suspension.returnedCount, 1)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            XCTAssertEqual(fixture.deliveryConstructions, deliveryCalls)
            XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
            XCTAssertEqual(try fixture.pending(), admitted)
            try fixture.assertOldProgress()
            for kind in [StepCountSyncBatchFactory.anchoredCursorKind, DailyActivityAggregateSyncPolicy.cursorKind] {
                XCTAssertNil(try fixture.cursors.cursorValue(
                    receiverBindingID: replacementBinding,
                    sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, cursorKind: kind
                ))
            }
            XCTAssertFalse(fixture.proofs.hasUploadedRecords(lane: .steps, receiverBindingID: replacementBinding))
        }
    }

    private func suspendForegroundRead(
        _ fixture: MailboxLaunchFixture,
        _ runtime: HealthBridgeCompanionApplicationRuntime
    ) async throws -> (MailboxLaunchReadSuspension, @MainActor () async -> Void) {
        let entered = expectation(description: "selected synthetic reader suspended")
        let suspension = MailboxLaunchReadSuspension(onEntry: { entered.fulfill() })
        fixture.readSuspension = suspension
        runtime.runForegroundCatchUpIfNeeded()
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(suspension.enteredCount, 1)
        XCTAssertEqual(suspension.returnedCount, 0)
        XCTAssertTrue(runtime.viewModel.automaticSyncOwnerIsActive)
        let completion = try XCTUnwrap(runtime.automaticSyncRuntime.foregroundCatchUpCompletion())
        addTeardownBlock { @MainActor in
            suspension.release()
            await completion()
        }
        return (suspension, completion)
    }

    private func makeFixture(
        representation: MailboxLaunchFixture.Representation,
        enabled: Bool = true,
        mailboxOnly: Bool = false,
        hasPriorRawAnchor: Bool = true,
        cleanup: BlockingBootstrapCleanup? = nil
    ) throws -> (MailboxLaunchFixture, HealthBridgeCompanionApplicationRuntime) {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw XCTSkip("Build the App host and test target with HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST.")
        #else
        let fixture = try MailboxLaunchFixture(
            representation: representation, enabled: enabled, mailboxOnly: mailboxOnly,
            hasPriorRawAnchor: hasPriorRawAnchor
        )
        let runtime = try fixture.makeRuntime(cleanup: cleanup)
        addTeardownBlock { @MainActor in
            cleanup?.release()
            fixture.readSuspension?.release()
            await runtime.viewModel.waitForAutomaticSyncDisableCleanup()
            await fixture.join(runtime)
            runtime.automaticSyncRuntime.stopAdmission()
            await runtime.automaticSyncRuntime.cancelAndWait()
            await fixture.join(runtime)
            XCTAssertEqual(fixture.ownersStarted, fixture.ownersFinished)
            fixture.removeOwnedStores()
        }
        return (fixture, runtime)
        #endif
    }
}

@MainActor
private final class MailboxLaunchFixture {
    enum Representation: CaseIterable { case raw, daily }
    private enum StepsReadFailure: Error { case raw, daily }

    let root: URL
    let suiteName = "MailboxForegroundLaunchCatchUpTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: ReceiverSettingsStore
    let background: BackgroundSyncSettingsStore
    let proofs: CoreLaneUploadProofStore
    let cursors: FileSyncCursorStore
    let sleep: FileSleepSyncManifestStore
    let outbox: FileOutbox
    let diagnostics: AutomaticSyncDiagnosticStore
    let keychain = MemoryMailboxKeychain()
    let keyService = "synthetic.launch.\(UUID().uuidString)"
    let keys: MailboxKeyStore
    let identity: MailboxConnectionIdentityV1
    let ackContext: MailboxAckContext
    let locator: MailboxResolvedLocatorV1
    let receiverSigning = Curve25519.Signing.PrivateKey()
    let receiverAgreement = Curve25519.KeyAgreement.PrivateKey()
    let previousAnchor: String
    let nextAnchor: String
    let previousDailyCursor: String
    let initialCursorBytes: Data
    let session: URLSession
    let representation: Representation
    let hasPriorRawAnchor: Bool
    var offerData = false
    var failRawStepsRead = false
    var failDailyStepsRead = false
    var followUpRawAnchor: String?
    var offeredDailyAggregates: [HealthKitDailyActivityAggregate] = []
    var readSuspension: MailboxLaunchReadSuspension?
    var reads: [String] = []
    var deliveryConstructions = 0
    var platformDrains = 0
    var refreshesConsumed = 0
    var ownersStarted = 0
    var ownersFinished = 0
    private var admittedGenerations: [String: Int] = [:]
    private var envelopeNumber: UInt8 = 0
    private var registeredQueries: [HKQuery] = []

    init(
        representation: Representation, enabled: Bool, mailboxOnly: Bool = false, unpaired: Bool = false,
        hasPriorRawAnchor: Bool = true
    ) throws {
        self.representation = representation
        self.hasPriorRawAnchor = hasPriorRawAnchor
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MailboxLaunchNoNetworkURLProtocol.self]
        session = URLSession(configuration: configuration)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailboxForegroundLaunchCatchUpTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let connectionTokens = MemoryReceiverTokenStore()
        settings = ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: connectionTokens,
            preCutoverBackupStore: MemoryReceiverTokenStore(), synchronize: { true }
        )
        background = BackgroundSyncSettingsStore(userDefaults: defaults)
        proofs = CoreLaneUploadProofStore(userDefaults: defaults)
        cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        sleep = try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json"))
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        diagnostics = AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json"))
        keys = MailboxKeyStore(service: keyService, keychain: keychain)
        let device = try keys.loadOrCreate()
        let receiverID = Data(repeating: 0x51, count: 16)
        let deviceID = Data(repeating: 0x52, count: 16)
        identity = MailboxConnectionIdentityV1(
            receiverID: receiverID.hexV1, deviceID: deviceID.hexV1,
            devicePrincipal: "synthetic-launch-device",
            deviceSigningKeyID: device.signingKeyID, deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "ed25519", publicKey: receiverSigning.publicKey.rawRepresentation
            ),
            receiverAgreementKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "x25519", publicKey: receiverAgreement.publicKey.rawRepresentation
            ),
            receiverSigningPublicKey: receiverSigning.publicKey.rawRepresentation.base64URLEncodedString(),
            receiverAgreementPublicKey: receiverAgreement.publicKey.rawRepresentation.base64URLEncodedString(),
            opaqueBinding: Data(repeating: 0x53, count: 32).base64URLEncodedString(),
            connectionGeneration: 1
        )
        if unpaired {
            // Fresh-pairing tests deliberately leave the real connection store empty.
        } else if mailboxOnly {
            // Seed the existing validated V2 representation of a committed
            // Mailbox connection. This tests cold restore, not enrollment.
            let record = ReceiverConnectionRecordV2(
                localScope: ReceiverLocalConnectionScopeV1(generation: 1, bindingID: identity.opaqueBinding),
                mailboxIdentity: .available(identity),
                activation: .paired(activeTransport: .mailbox),
                transportConfigurations: [
                    .mailbox(activation: .active, configuration: MailboxConnectionConfigurationV1()),
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try connectionTokens.saveToken(
                "health-bridge-connection-v2:" + encoder.encode(record).base64EncodedString()
            )
        } else {
            try settings.saveMailboxPairing(
                receiverURLString: "http://127.0.0.1:8765/v1/batches",
                bearerToken: "synthetic-unused-launch-credential",
                mailboxIdentity: identity, expectedGeneration: settings.receiverSettingsGenerationToken
            )
        }
        ackContext = MailboxAckContext(
            receiverID: receiverID, deviceID: deviceID, receiverBindingID: identity.opaqueBinding,
            connectionGeneration: 1, deviceAgreementPrivateKey: try keys.agreementPrivateKey(),
            deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningPublicKey: receiverSigning.publicKey, receiverSigningKeyID: identity.receiverSigningKeyID,
            receiverAgreementPublicKey: receiverAgreement.publicKey, receiverAgreementKeyID: identity.receiverAgreementKeyID,
            deviceSigningPublicKey: try Curve25519.Signing.PublicKey(rawRepresentation: device.signingPublicKey),
            deviceSigningKeyID: device.signingKeyID
        )
        let provider = root.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        locator = try MailboxLocatorV1.resolveIsolated(
            providerRoot: provider, containerIdentifier: "synthetic.launch",
            receiverComponent: identity.receiverID, deviceComponent: identity.deviceID,
            localRecordURL: root.appendingPathComponent("local/locator.json")
        )
        previousAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 41))
        nextAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 42))
        previousDailyCursor = HealthBridgeUTCFormatter.string(from: Date().addingTimeInterval(-172_800))
        // This models an existing installation with previously acknowledged raw Steps.
        // New reads must not replace this cursor or retire pending work without an ACK.
        if hasPriorRawAnchor {
            try cursors.saveCursorValue(
                previousAnchor, receiverBindingID: identity.opaqueBinding,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
            )
            proofs.markUploadedRecords(lane: .steps, receiverBindingID: identity.opaqueBinding)
        }
        try cursors.saveCursorValue(
            previousDailyCursor, receiverBindingID: identity.opaqueBinding,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
        )
        initialCursorBytes = try Data(contentsOf: cursors.fileURL)
        try background.setEnabledDurably(enabled)
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
            )
        )
    }

    func makeRuntime(
        cleanup: BlockingBootstrapCleanup?,
        nativeMailboxIO: NativeMailboxPairingIO? = nil,
        pairingStateStore: ReceiverPairingStateStore? = nil,
        firstReaderOverride: (@MainActor (String?, Date?, Date) async throws -> HealthKitAnchoredStepChanges)? = nil,
        deliveryOverride: (@MainActor () throws -> ProductionMailboxDelivery)? = nil,
        authorizationOverride: (@MainActor ([String]) async throws -> Void)? = nil
    ) throws -> HealthBridgeCompanionApplicationRuntime {
        let viewModel = HealthBridgeCompanionViewModel(
            receiverClient: ReceiverClient(session: session),
            settingsStore: settings,
            pairingStateStore: pairingStateStore ?? ReceiverPairingStateStore(
                pendingStore: MemoryReceiverTokenStore(), installationIDStore: MemoryReceiverTokenStore(),
                cancellationStore: MemoryReceiverTokenStore()
            ),
            backgroundSyncStore: background, automaticSyncDiagnosticStore: diagnostics,
            healthPermissionRequestStore: CompanionHealthPermissionRequestStore(userDefaults: defaults),
            healthHistoryDepthStore: HealthHistoryDepthSelectionStore(userDefaults: defaults),
            historicalBackfillStateStore: HealthHistoricalBackfillStateStore(userDefaults: defaults),
            quantityObservationStore: QuantityObservationStore(userDefaults: defaults),
            coreLaneUploadProofStore: proofs,
            acceptedTransferStore: makeResetTestTransferStore(root: root, defaults: defaults),
            outbox: outbox, outboxDirectoryURL: outbox.directoryURL,
            cursorStore: cursors, cursorStoreFileURL: cursors.fileURL,
            sleepManifestStore: sleep, sleepManifestFileURL: root.appendingPathComponent("sleep.json"),
            sleepResetEpochStore: SleepResetEpochStore(tokenStore: MemoryReceiverTokenStore(), epochFloorProvider: { 1 }),
            mailboxKeyStore: keys, nativeMailboxIO: nativeMailboxIO,
            readAnchoredStepChanges: firstReaderOverride ?? { [self] anchor, start, now in
                reads.append("raw")
                if hasPriorRawAnchor {
                    XCTAssertEqual(anchor, followUpRawAnchor == nil ? previousAnchor : nextAnchor)
                    XCTAssertNil(start)
                } else if reads == ["raw"] {
                    XCTAssertNil(anchor)
                    XCTAssertNotNil(start, "A cursorless automatic read must be bounded.")
                }
                if failRawStepsRead { throw StepsReadFailure.raw }
                let changes = rawChanges(
                    now: now, hasRecords: offerData && representation == .raw, resultAnchor: followUpRawAnchor
                )
                if representation == .raw, let readSuspension {
                    await readSuspension.wait()
                }
                return changes
            },
            automaticSyncEligibleTypeCodesForTesting: ["steps"],
            readDailyActivityAggregates: { [self] types, start, end, calendar in
                reads.append("daily")
                XCTAssertEqual(types, ["steps"])
                if failDailyStepsRead { throw StepsReadFailure.daily }
                guard offerData else { return [] }
                let today = calendar.startOfDay(for: end)
                let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
                XCTAssertLessThanOrEqual(start, yesterday)
                var aggregates: [HealthKitDailyActivityAggregate] = []
                var day = calendar.startOfDay(for: start)
                while day < today {
                    let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
                    aggregates.append(HealthKitDailyActivityAggregate(
                        typeCode: "steps", dayStart: day, dayEnd: nextDay, value: 123,
                        timeZoneIdentifier: calendar.timeZone.identifier
                    ))
                    day = nextDay
                }
                offeredDailyAggregates = aggregates
                if representation == .daily, let readSuspension {
                    await readSuspension.wait()
                }
                return aggregates
            },
            scheduleDirectBackgroundUploads: {
                XCTFail("Mailbox fixtures must not schedule direct uploads")
                return 0
            },
            cancelInheritedLegacyUploads: {
                if let cleanup { return await cleanup.wait() }
                return BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
            },
            platformBackgroundPayloadDrain: { [self] in platformDrains += 1; return true },
            productionMailboxDelivery: deliveryOverride ?? { [self] in try delivery() },
            requestProjectionReadAuthorization: authorizationOverride
        )
        let coordinator = HealthKitBackgroundDeliveryCoordinator(
            healthDataAvailable: { true },
            executeQuery: { [self] in registeredQueries.append($0) },
            stopQuery: { [self] query in registeredQueries.removeAll { $0 === query } },
            enableDelivery: { _, _ in },
            disableDelivery: { _ in }
        )
        let platform = AutomaticSyncRuntime.Platform(
            scheduleRefresh: { _ in }, cancelRefresh: {},
            consumeRefresh: { [self] in refreshesConsumed += 1 },
            setUploadAdmission: { _ in },
            beginBackgroundOwner: { [self] _ in
                ownersStarted += 1
                return { [self] in ownersFinished += 1 }
            },
            healthDataAvailable: { true }, backgroundDeliveryCoordinator: coordinator
        )
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel, automaticSyncPlatform: platform)
    }

    func join(_ runtime: HealthBridgeCompanionApplicationRuntime) async {
        await runtime.automaticSyncRuntime.waitForForegroundCatchUp()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
        XCTAssertFalse(runtime.viewModel.automaticSyncOwnerIsActive)
    }

    func arm(_ runtime: HealthBridgeCompanionApplicationRuntime) async throws {
        XCTAssertTrue(runtime.viewModel.automaticSyncRuntimeIsReady)
        XCTAssertEqual(runtime.viewModel.automaticSyncSelectedEligibleTypeCodes(), ["steps"])
        // Bootstrap sends an empty statistics observation even without readable values.
        // Establish an empty queue through its authenticated ACK, never by deleting it.
        let bootstrapItems = try outbox.pendingItems()
        XCTAssertEqual(bootstrapItems.count, 1)
        let bootstrapItem = try XCTUnwrap(bootstrapItems.first)
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: bootstrapItem.fileURL))
        XCTAssertTrue(batch.samples.isEmpty)
        XCTAssertEqual(batch.sync.cursors.map(\.cursorKind), ["daily_projection_observation:steps"])
        XCTAssertEqual(bootstrapItem.deliveryState?.phase, .providerObserved)
        let pendingBeforeACK = try pending()
        let noACK = try await delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(noACK.finalizedCount, 0)
        XCTAssertEqual(try outbox.pendingItems(), bootstrapItems)
        try await acknowledge(bootstrapItem)
        XCTAssertEqual(try pending(), pendingBeforeACK)
        try assertOldProgress()
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        offerData = true
        reads.removeAll()
        try admitObserver(runtime)
        XCTAssertEqual(try pending().keys.sorted(), ["steps"])
        runtime.noteSceneLeftActive()
    }

    func admitObserver(_ runtime: HealthBridgeCompanionApplicationRuntime) throws {
        guard case .continueProcessing = runtime.viewModel.admitAutomaticSyncObserver(
            typeCode: "steps", diagnosticRunID: UUID()
        ) else {
            XCTFail("Existing durable observer admission must succeed")
            return
        }
        admittedGenerations = try pending()
    }

    func rawChanges(now: Date, hasRecords: Bool, resultAnchor: String? = nil) -> HealthKitAnchoredStepChanges {
        let start = now.addingTimeInterval(-120)
        return HealthKitAnchoredStepChanges(
            stepSamples: hasRecords ? [HealthKitStepSampleSummary(
                uuid: UUID(), start: start, end: start.addingTimeInterval(60), count: 17
            )] : [],
            deletedStepSamples: [], anchorCursorValue: hasRecords ? (resultAnchor ?? nextAnchor) : previousAnchor,
            windowStart: start, windowEnd: now
        )
    }

    func pending() throws -> [String: Int] { try background.loadPendingObserverTypeCodeGenerations() }

    func replaceMailboxConnectionWhileOutboxIsEmpty() throws -> String {
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        let replacement = MailboxConnectionIdentityV1(
            receiverID: identity.receiverID, deviceID: identity.deviceID,
            devicePrincipal: identity.devicePrincipal,
            deviceSigningKeyID: identity.deviceSigningKeyID,
            deviceAgreementKeyID: identity.deviceAgreementKeyID,
            receiverSigningKeyID: identity.receiverSigningKeyID,
            receiverAgreementKeyID: identity.receiverAgreementKeyID,
            receiverSigningPublicKey: identity.receiverSigningPublicKey,
            receiverAgreementPublicKey: identity.receiverAgreementPublicKey,
            opaqueBinding: Data(repeating: 0x54, count: 32).base64URLEncodedString(),
            connectionGeneration: identity.connectionGeneration + 1
        )
        try settings.beginTerminalCancellationIntent(expectedGeneration: settings.receiverSettingsGenerationToken)
        try settings.resolveTerminalCancellationForPrivateReset()
        XCTAssertTrue(try settings.receiverSettingsAreCleared())
        try settings.saveMailboxPairing(
            receiverURLString: "http://127.0.0.1:8765/v1/batches",
            bearerToken: "synthetic-unused-launch-credential",
            mailboxIdentity: replacement, expectedGeneration: settings.receiverSettingsGenerationToken
        )
        return replacement.opaqueBinding
    }

    func preACKCursorMap(_ entries: [String: String], allowRawProjectionTurn: Bool) -> [String: String] {
        guard allowRawProjectionTurn else { return entries }
        let source = HealthBridgeAppleHealthSource.phone.sourceKey
        let turnKey = "receiver_binding_v1#\(identity.opaqueBinding)#\(source)#mailbox_steps_projection_turn"
        return entries.filter { $0.key != turnKey }
    }

    func assertOldProgress(allowRawProjectionTurn: Bool = false) throws {
        let decoder = JSONDecoder()
        let initial = try decoder.decode([String: String].self, from: initialCursorBytes)
        let current = try decoder.decode([String: String].self, from: Data(contentsOf: cursors.fileURL))
        XCTAssertEqual(preACKCursorMap(current, allowRawProjectionTurn: allowRawProjectionTurn),
                       preACKCursorMap(initial, allowRawProjectionTurn: allowRawProjectionTurn))
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), hasPriorRawAnchor ? previousAnchor : nil)
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
        ), previousDailyCursor)
        XCTAssertNil(try cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: "steps")
        ))
        XCTAssertEqual(proofs.hasUploadedRecords(lane: .steps, receiverBindingID: identity.opaqueBinding), hasPriorRawAnchor)
        XCTAssertFalse(proofs.hasUploadedRecords(lane: .workouts, receiverBindingID: identity.opaqueBinding))
    }

    func enqueueWaitingSteps() throws -> FileOutboxItem {
        let now = Date()
        let payload = try JSONEncoder().encode(StepCountSyncBatchFactory.makeAnchoredStepBatch(
            changes: rawChanges(now: now, hasRecords: true), generatedAt: now
        ))
        return try XCTUnwrap(outbox.enqueueSequence(
            [payload], receiverIdentity: identity.opaqueBinding,
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: identity.opaqueBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: StepCountSyncBatchFactory.anchoredCursorKind, cursorValue: nextAnchor,
                coreLaneUploadProof: .steps
            )
        ).first)
    }

    func components() -> ProductionMailboxComponents {
        let locator = locator
        let lookup = FileOutboxMailboxAckLookup(outbox: outbox, deviceSigningPublicKey: ackContext.deviceSigningPublicKey)
        let transport = MailboxTransport(
            outbox: outbox,
            context: MailboxTransportContext(
                receiverID: ackContext.receiverID, deviceID: ackContext.deviceID,
                receiverBindingID: identity.opaqueBinding, connectionGeneration: 1,
                receiverAgreementPublicKey: receiverAgreement.publicKey, receiverAgreementKeyID: identity.receiverAgreementKeyID,
                deviceSigningPublicKey: ackContext.deviceSigningPublicKey, deviceSigningKeyID: identity.deviceSigningKeyID
            ),
            sealer: DeliveryProtocolMailboxEnvelopeSealer(keyStore: keys), locate: { locator },
            publisher: POSIXMailboxEnvelopePublisher(),
            envelopeID: { [self] in
                envelopeNumber += 1
                return Data(repeating: envelopeNumber, count: 16)
            },
            nowMilliseconds: { Int64(Date().timeIntervalSince1970 * 1_000) },
            isCancelled: { withUnsafeCurrentTask { $0?.isCancelled ?? false } },
            observe: { url, digest in
                SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() == digest
            }
        )
        return ProductionMailboxComponents(
            identity: identity, deviceSigningPublicKey: ackContext.deviceSigningPublicKey,
            ackContext: ackContext, transport: transport, ackLookup: lookup,
            scanner: MailboxAckScanner(context: ackContext, lookup: lookup, locate: { locator }), locate: { locator }
        )
    }

    func delivery() throws -> ProductionMailboxDelivery {
        deliveryConstructions += 1
        let components = components()
        return ProductionMailboxDelivery(
            settingsStore: settings, outbox: outbox, cursorStore: cursors, proofStore: proofs,
            pendingGenerationStore: background, sleepStore: sleep, keyStore: keys,
            componentsFactory: { components }
        )
    }

    #if HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
    func nativeFlowComponents(peer: ExchangePeer) throws -> ProductionMailboxComponents {
        let record = try XCTUnwrap(settings.currentConnectionRecordV2())
        guard record.activation == .paired(activeTransport: .mailbox),
              case .available(let committedIdentity) = record.mailboxIdentity else {
            throw ExchangeFailure.invalidPeer
        }
        XCTAssertEqual(record.localScope.bindingID, committedIdentity.opaqueBinding)
        XCTAssertEqual(settings.receiverBindingID, committedIdentity.opaqueBinding)
        XCTAssertEqual(committedIdentity.opaqueBinding, peer.expectedBinding)
        let device = try keys.loadOrCreate()
        XCTAssertEqual(device.signingKeyID, committedIdentity.deviceSigningKeyID)
        XCTAssertEqual(device.agreementKeyID, committedIdentity.deviceAgreementKeyID)
        XCTAssertEqual(committedIdentity.receiverSigningPublicKey, ExchangePeer.b64(peer.signing.publicKey.rawRepresentation))
        XCTAssertEqual(committedIdentity.receiverAgreementPublicKey, ExchangePeer.b64(peer.agreement.publicKey.rawRepresentation))
        XCTAssertEqual(committedIdentity.receiverSigningKeyID, try DeliveryProtocolV1.keyID(
            algorithm: "ed25519", publicKey: peer.signing.publicKey.rawRepresentation))
        XCTAssertEqual(committedIdentity.receiverAgreementKeyID, try DeliveryProtocolV1.keyID(
            algorithm: "x25519", publicKey: peer.agreement.publicKey.rawRepresentation))
        let receiverID = try XCTUnwrap(Data(hexV1: committedIdentity.receiverID))
        let deviceID = try XCTUnwrap(Data(hexV1: committedIdentity.deviceID))
        let protocolGeneration = try XCTUnwrap(Int64(exactly: committedIdentity.connectionGeneration))
        let signing = try Curve25519.Signing.PublicKey(rawRepresentation: device.signingPublicKey)
        let context = MailboxAckContext(
            receiverID: receiverID, deviceID: deviceID,
            receiverBindingID: committedIdentity.opaqueBinding, connectionGeneration: protocolGeneration,
            deviceAgreementPrivateKey: try keys.agreementPrivateKey(), deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningPublicKey: peer.signing.publicKey, receiverSigningKeyID: committedIdentity.receiverSigningKeyID,
            receiverAgreementPublicKey: peer.agreement.publicKey, receiverAgreementKeyID: committedIdentity.receiverAgreementKeyID,
            deviceSigningPublicKey: signing, deviceSigningKeyID: device.signingKeyID
        )
        let provider = root.appendingPathComponent("native-flow-local-provider")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let isolated = try MailboxLocatorV1.resolveIsolated(
            providerRoot: provider, containerIdentifier: "synthetic.native.first.flow",
            receiverComponent: committedIdentity.receiverID, deviceComponent: committedIdentity.deviceID,
            localRecordURL: root.appendingPathComponent("native-flow-local/locator.json")
        )
        for lane in isolated.lanes.values {
            XCTAssertTrue(lane.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        }
        let lookup = FileOutboxMailboxAckLookup(outbox: outbox, deviceSigningPublicKey: signing)
        let transport = MailboxTransport(
            outbox: outbox,
            context: MailboxTransportContext(
                receiverID: receiverID, deviceID: deviceID,
                receiverBindingID: committedIdentity.opaqueBinding, connectionGeneration: protocolGeneration,
                receiverAgreementPublicKey: peer.agreement.publicKey,
                receiverAgreementKeyID: committedIdentity.receiverAgreementKeyID,
                deviceSigningPublicKey: signing, deviceSigningKeyID: device.signingKeyID
            ),
            sealer: DeliveryProtocolMailboxEnvelopeSealer(keyStore: keys), locate: { isolated },
            publisher: POSIXMailboxEnvelopePublisher(),
            envelopeID: { [self] in
                envelopeNumber += 1
                return Data(repeating: envelopeNumber, count: 16)
            },
            nowMilliseconds: { Int64(Date().timeIntervalSince1970 * 1_000) },
            isCancelled: { withUnsafeCurrentTask { $0?.isCancelled ?? false } },
            observe: { url, digest in
                guard url.standardizedFileURL.path.hasPrefix(provider.standardizedFileURL.path + "/") else {
                    throw ExchangeFailure.invalidPeer
                }
                return ExchangePeer.hex(ExchangePeer.hash(try Data(contentsOf: url))) == digest
            }
        )
        return ProductionMailboxComponents(
            identity: committedIdentity, deviceSigningPublicKey: signing,
            ackContext: context, transport: transport, ackLookup: lookup,
            scanner: MailboxAckScanner(context: context, lookup: lookup, locate: { isolated }),
            locate: { isolated }
        )
    }

    func nativeFlowDelivery(peer: ExchangePeer) throws -> ProductionMailboxDelivery {
        deliveryConstructions += 1
        let components = try nativeFlowComponents(peer: peer)
        return ProductionMailboxDelivery(
            settingsStore: settings, outbox: outbox, cursorStore: cursors, proofStore: proofs,
            pendingGenerationStore: background, sleepStore: sleep, keyStore: keys,
            componentsFactory: { components }
        )
    }
    #endif

    func assertCollectedAndAcknowledge() async throws {
        XCTAssertEqual(reads, representation == .raw ? ["raw"] : ["raw", "daily"],
            "After natural foreground completion, the selected HealthKit input must have been read.")
        let items = try outbox.pendingItems()
        XCTAssertEqual(items.count, 1, "The new representation must be durably queued before ACK.")
        let item = try XCTUnwrap(items.first)
        let payload = try Data(contentsOf: item.fileURL)
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: payload)
        let expectedCount = representation == .raw ? 1 : offeredDailyAggregates.count
        XCTAssertGreaterThan(expectedCount, 0)
        XCTAssertEqual(batch.samples.map(\.typeCode), Array(repeating: "steps", count: expectedCount))
        XCTAssertEqual(batch.samples.map { $0.metadata["sample_kind"] },
            Array(repeating: representation == .raw ? "raw_quantity" : "daily_aggregate", count: expectedCount))
        XCTAssertEqual(batch.samples.map(\.value), Array(repeating: representation == .raw ? 17 : 123, count: expectedCount))
        let admitted = try pending()
        XCTAssertEqual(admitted, admittedGenerations)
        let generation = try XCTUnwrap(admitted["steps"])
        XCTAssertEqual(try outbox.hasPendingGenerationRetirement(typeCode: "steps", generation: generation), representation == .daily)
        try assertOldProgress(allowRawProjectionTurn: representation == .raw)
        XCTAssertEqual(item.deliveryState?.phase, .providerObserved)
        let summaryWithoutACK = try await delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(summaryWithoutACK.finalizedCount, 0)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [item.id])
        XCTAssertEqual(try pending(), admitted)
        try assertOldProgress(allowRawProjectionTurn: representation == .raw)

        try await acknowledge(item)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
        XCTAssertEqual(try pending(), representation == .raw ? admitted : [:])
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
        ), representation == .raw ? nextAnchor : previousAnchor)
        let dailyCursor = try cursors.cursorValue(
            receiverBindingID: identity.opaqueBinding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
        )
        if representation == .daily {
            let expected = try XCTUnwrap(batch.sync.cursors.first {
                $0.cursorKind == DailyActivityAggregateSyncPolicy.cursorKind
            })
            XCTAssertEqual(dailyCursor, expected.cursorValue)
            XCTAssertNotEqual(dailyCursor, previousDailyCursor)
        } else {
            XCTAssertEqual(dailyCursor, previousDailyCursor)
        }
    }

    func acknowledge(_ item: FileOutboxItem) async throws {
        let payload = try Data(contentsOf: item.fileURL)
        let envelopeID = try components().transport.finalizedEnvelopeID(itemID: item.id)
        let ack = try DeliveryProtocolV1.sealAck(
            DeliveryReceiptV1(
                result: .committed,
                payloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                receiptID: 1, datasetGeneration: 1,
                committedAtMS: Int64(Date().timeIntervalSince1970 * 1_000), errorCode: nil
            ),
            context: DeliveryAckSealContext(
                envelopeID: envelopeID, receiverID: ackContext.receiverID, deviceID: ackContext.deviceID,
                connectionGeneration: 1, deviceAgreementPublicKey: ackContext.deviceAgreementPrivateKey.publicKey,
                receiverSigningPrivateKey: receiverSigning, receiverAgreementPrivateKey: receiverAgreement
            )
        )
        let name = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .acknowledgment)
        let lane = try XCTUnwrap(locator.lanes[.acks])
        try ack.write(to: lane.appendingPathComponent(name), options: [.withoutOverwriting])
        let summary = try await delivery().reconcilePendingFIFOHeadAcknowledgment(afterAcknowledgmentCheckpoint: nil)
        XCTAssertEqual(summary.finalizedCount, 1)
        XCTAssertEqual(summary.hydration.requestedDownloadCount, 0)
    }

    func removeOwnedStores() {
        XCTAssertTrue(registeredQueries.isEmpty)
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class MailboxLaunchReadSuspension {
    private let onEntry: () -> Void
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var enteredCount = 0
    private(set) var returnedCount = 0

    init(onEntry: @escaping () -> Void) { self.onEntry = onEntry }

    func wait() async {
        enteredCount += 1
        if enteredCount == 1 { onEntry() }
        if !released {
            await withCheckedContinuation { continuations.append($0) }
        }
        returnedCount += 1
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class MailboxLaunchNoNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Mailbox launch fixtures must not issue network requests")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}

private final class MemoryReceiverTokenStore: ReceiverTokenStoring {
    private var token = ""
    var rejectNextEmptySave = false

    func loadToken() throws -> String { token }

    func saveToken(_ token: String) throws {
        if token.isEmpty, rejectNextEmptySave {
            rejectNextEmptySave = false
            throw ExchangeFailure.pendingCleanupUnavailable
        }
        self.token = token
    }
}

private final class MemoryMailboxKeychain: MailboxKeychainClient {
    private var items: [String: Data] = [:]
    private var trustItems: [String: Data] = [:]

    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T {
        try body()
    }

    func data(service: String, account: String) throws -> Data? {
        items["\(service)\u{0}\(account)"]
    }

    func store(_ data: Data, service: String, account: String) throws {
        items["\(service)\u{0}\(account)"] = data
    }

    func remove(service: String, account: String) throws {
        items.removeValue(forKey: "\(service)\u{0}\(account)")
    }

    func trustData(service: String, record: MailboxTrustRecord) throws -> Data? {
        trustItems["\(service)\u{0}\(record.rawValue)"]
    }

    func storeTrust(_ data: Data, service: String, record: MailboxTrustRecord) throws {
        trustItems["\(service)\u{0}\(record.rawValue)"] = data
    }

    func removeTrust(service: String, record: MailboxTrustRecord) throws {
        trustItems.removeValue(forKey: "\(service)\u{0}\(record.rawValue)")
    }
}

private struct Issue63ProducerStream: Codable {
    let version: Int
    let payloads: [String]
    let stageEnds: [Int]
    let replayedPayloadIndex: Int
}

@MainActor
private final class Issue63StreamFixture {
    let base: AutomaticStepsFaultFixture
    var deleted = false
    var quantityReads = 0

    init() throws {
        base = try AutomaticStepsFaultFixture()
        let today = Calendar.current.startOfDay(for: Date())
        base.sampleStart = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today)).addingTimeInterval(3_600)
        base.completedStepsValue = 6
    }

    func raw(anchor: String?, start: Date?, now: Date) throws -> HealthKitAnchoredStepChanges {
        if !deleted { return try base.readRaw(anchor: anchor, start: start, receivedAt: now) }
        let next = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 43))
        return HealthKitAnchoredStepChanges(
            stepSamples: [],
            deletedStepSamples: anchor == next ? [] : [HealthKitDeletedStepSample(
                uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000058")), deletedAt: now
            )],
            anchorCursorValue: next, windowStart: base.sampleStart, windowEnd: now
        )
    }

    func quantity(type: String, anchor: String?, start: Date?, now: Date) throws -> HealthKitAnchoredQuantityChanges {
        quantityReads += 1
        let next = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 99))
        return HealthKitAnchoredQuantityChanges(
            typeCode: type,
            samples: anchor == next ? [] : [HealthKitQuantitySampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000063")),
                typeCode: type, start: base.sampleStart, end: base.sampleStart, value: 70
            )], deletedSamples: [], anchorCursorValue: next,
            windowStart: start ?? base.sampleStart, windowEnd: now
        )
    }
}

extension HealthBridgeCompanionResetAdmissionTests {
    func testIssue63ExportProducerCorrectionStream() async throws {
        let fixture = try Issue63StreamFixture()
        defer { fixture.base.cleanUp() }
        var runtime: HealthBridgeCompanionApplicationRuntime? = try await makeIssue63StreamRuntime(fixture)
        _ = try fixture.base.admit(["steps"])
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        XCTAssertEqual(try fixture.base.acceptedSamples(kind: "daily_aggregate").map(\.value), [6])
        let firstEnd = fixture.base.recorder.acceptedPayloads.count
        let originalDailyIndex = try XCTUnwrap(fixture.base.recorder.acceptedPayloads.firstIndex { data in
            (try? JSONDecoder().decode(HealthBridgeBatchV1.self, from: data))?.samples.contains {
                $0.metadata["sample_kind"] == "daily_aggregate"
            } == true
        })

        fixture.deleted = true
        fixture.base.emptyStepsDailyRead = true
        let pending = try fixture.base.admit(["steps"])
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        XCTAssertEqual(try fixture.base.pending(), pending)
        let deletedEnd = fixture.base.recorder.acceptedPayloads.count
        XCTAssertGreaterThan(deletedEnd, firstEnd)
        await runtime?.automaticSyncRuntime.cancelAndWait()
        runtime = nil

        fixture.base.emptyStepsDailyRead = false
        fixture.base.completedStepsValue = 0
        runtime = try await makeIssue63StreamRuntime(fixture)
        await runtime?.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps"]))
        XCTAssertEqual(try fixture.base.acceptedSamples(kind: "daily_aggregate").map(\.value), [6, 0])
        XCTAssertTrue(try fixture.base.pending().isEmpty)
        await runtime?.automaticSyncRuntime.cancelAndWait()

        var payloads = fixture.base.recorder.acceptedPayloads.map { String(decoding: $0, as: UTF8.self) }
        let recollectedEnd = payloads.count
        payloads.append(payloads[originalDailyIndex])
        let export = Issue63ProducerStream(version: 1, payloads: payloads,
            stageEnds: [firstEnd, deletedEnd, recollectedEnd, payloads.count], replayedPayloadIndex: originalDailyIndex)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(export), uniformTypeIdentifier: "public.json")
        attachment.name = "issue63-producer-stream-v1.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testIssue63UnknownStatisticsDoesNotStarveAnotherSelectedType() async throws {
        let fixture = try Issue63StreamFixture()
        defer { fixture.base.cleanUp() }
        fixture.base.emptyStepsDailyRead = true
        let runtime = try await makeIssue63StreamRuntime(fixture, eligible: ["steps", "weight"])
        let pending = try fixture.base.admit(["steps", "weight"])
        await runtime.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: ["steps", "weight"]))
        XCTAssertEqual(fixture.base.dailyRequests, [["steps"]])
        XCTAssertEqual(fixture.quantityReads, 1)
        XCTAssertEqual(try fixture.base.acceptedSamples(kind: "raw_quantity").filter { $0.typeCode == "weight" }.map(\.value), [70])
        XCTAssertEqual(try fixture.base.pending(), pending.filter { $0.key == "steps" })
        await runtime.automaticSyncRuntime.cancelAndWait()
    }

    func testIssue63RawChunksKeepEvidenceAndACKProgressAcrossReopen() throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        let anchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 63))
        let start = Date().addingTimeInterval(-30 * 86_400)
        let count = GenericQuantitySyncBatchFactory.defaultMaxSamplesPerBatch + 1
        let samples = try (1...count).map { index in
            HealthKitQuantitySampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index))),
                typeCode: "basal_energy", start: start, end: start.addingTimeInterval(60), value: 1
            )
        }
        let changes = HealthKitAnchoredQuantityChanges(typeCode: "basal_energy", samples: samples,
            deletedSamples: [], anchorCursorValue: anchor, windowStart: start, windowEnd: Date())
        let directory = fixture.root.appendingPathComponent("chunks")
        var outbox = try FileOutbox(directory: directory)
        let order = try outbox.reserveDailyProjectionObservation()
        let batches = try outbox.prepareProjectionRawBatches(
            GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(changes: changes),
            order: order, receiverBindingID: fixture.receiverBindingID, typeCode: "basal_energy",
            fallbackStart: start, end: Date(), calendar: .current
        )
        XCTAssertGreaterThan(batches.count, 1)
        for (index, batch) in batches.enumerated() {
            let evidence = try XCTUnwrap(batch.sync.cursors.first { $0.cursorKind == "daily_projection_observation:basal_energy" })
            let observation = try JSONDecoder().decode(Issue63ObservationWire.self, from: Data(evidence.cursorValue.utf8))
            XCTAssertEqual(observation.sequence, order.sequence)
            XCTAssertEqual(Set(observation.rawIntervals.map(\.clientRecordID)), Set(batch.samples.map(\.clientRecordID)))
            XCTAssertEqual(batch.sync.cursors.filter { !$0.cursorKind.hasPrefix("daily_projection_observation:") }.count, index == batches.count - 1 ? 1 : 0)
        }
        let cursorKind = GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "basal_energy")
        let cursorStore = try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("chunk-cursors.json"))
        let payloads = try batches.map { try HealthBridgeBatchEncoder().encode($0) }
        let items = try outbox.enqueueSequence(payloads, receiverIdentity: fixture.receiverBindingID,
            cursorCheckpoint: FileOutboxCursorCheckpoint(receiverIdentity: fixture.receiverBindingID,
                sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, cursorKind: cursorKind, cursorValue: anchor))
        let first = try XCTUnwrap(items.first)
        let finalizer = OutboxDeliveryCursorFinalizer(outbox: outbox, cursorStore: cursorStore)
        XCTAssertFalse(try finalizer.recordDirectReceiverAcceptance(itemID: first.id, receiverBindingID: fixture.receiverBindingID))
        XCTAssertNil(try cursorStore.cursorValue(receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, cursorKind: cursorKind))
        outbox = try FileOutbox(directory: directory)
        let remaining = try outbox.pendingItems()
        XCTAssertEqual(remaining.count, items.count - 1)
        let reopenedFinalizer = OutboxDeliveryCursorFinalizer(outbox: outbox, cursorStore: cursorStore)
        for item in remaining {
            XCTAssertTrue(payloads.contains(try Data(contentsOf: item.fileURL)))
            _ = try reopenedFinalizer.recordDirectReceiverAcceptance(itemID: item.id, receiverBindingID: fixture.receiverBindingID)
        }
        XCTAssertEqual(try cursorStore.cursorValue(receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, cursorKind: cursorKind), anchor)
        let next = try outbox.reserveDailyProjectionObservation()
        XCTAssertEqual(next.namespace, order.namespace)
        XCTAssertGreaterThan(next.sequence, order.sequence)
        XCTAssertNotNil(try outbox.projectionRepairStart(receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, typeCodes: ["basal_energy"]))
    }

    func testIssue63PartialStatisticsACKKeepsRemainingHistoricalRepair() throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date())
        let first = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: end))
        let second = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: first))
        let third = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: second))
        let directory = fixture.root.appendingPathComponent("partial-repair")
        var outbox = try FileOutbox(directory: directory)
        let rawOrder = try outbox.reserveDailyProjectionObservation()
        let changes = HealthKitAnchoredQuantityChanges(typeCode: "basal_energy", samples: [
            HealthKitQuantitySampleSummary(uuid: UUID(), typeCode: "basal_energy", start: first,
                end: second, value: 1),
            HealthKitQuantitySampleSummary(uuid: UUID(), typeCode: "basal_energy", start: second,
                end: third, value: 2)
        ], deletedSamples: [], anchorCursorValue: "synthetic-partial-anchor", windowStart: first, windowEnd: end)
        _ = try outbox.prepareProjectionRawBatches(
            GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(changes: changes),
            order: rawOrder, receiverBindingID: fixture.receiverBindingID, typeCode: "basal_energy",
            fallbackStart: first, end: end, calendar: calendar)
        let statisticsOrder = try outbox.reserveDailyProjectionObservation()
        let firstDay = try XCTUnwrap(DailyActivityAggregateSyncBatchFactory.makeDailyActivityAggregateBatch(
            aggregates: [HealthKitDailyActivityAggregate(typeCode: "basal_energy", dayStart: first,
                dayEnd: second, value: 6)], typeCodes: ["basal_energy"], windowStart: first, windowEnd: third))
        let batch = try DailyProjectionObservation(order: statisticsOrder, typeCode: "basal_energy",
            statisticsWindow: HealthBridgeTimeWindow(startTime: HealthBridgeUTCFormatter.string(from: first),
                endTime: HealthBridgeUTCFormatter.string(from: third))).appending(to: firstDay)
        let bytes = try HealthBridgeBatchEncoder().encode(batch)
        let item = try outbox.enqueue(bytes, receiverIdentity: fixture.receiverBindingID)
        XCTAssertEqual(try outbox.projectionRepairStart(receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, typeCodes: ["basal_energy"]), first)
        outbox = try FileOutbox(directory: directory)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), bytes)
        try outbox.markUploaded(item)
        outbox = try FileOutbox(directory: directory)
        XCTAssertEqual(try outbox.projectionRepairStart(receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, typeCodes: ["basal_energy"]), second)
        let newer = try outbox.reserveDailyProjectionObservation()
        XCTAssertEqual(newer.namespace, statisticsOrder.namespace)
        XCTAssertGreaterThan(newer.sequence, statisticsOrder.sequence)
        let secondDay = try XCTUnwrap(DailyActivityAggregateSyncBatchFactory.makeDailyActivityAggregateBatch(
            aggregates: [HealthKitDailyActivityAggregate(typeCode: "basal_energy", dayStart: second,
                dayEnd: third, value: 0)], typeCodes: ["basal_energy"], windowStart: second, windowEnd: third))
        let recollection = try DailyProjectionObservation(order: newer, typeCode: "basal_energy",
            statisticsWindow: HealthBridgeTimeWindow(startTime: HealthBridgeUTCFormatter.string(from: second),
                endTime: HealthBridgeUTCFormatter.string(from: third))).appending(to: secondDay)
        try outbox.markUploaded(outbox.enqueue(HealthBridgeBatchEncoder().encode(recollection),
            receiverIdentity: fixture.receiverBindingID))
        XCTAssertNil(try outbox.projectionRepairStart(receiverBindingID: fixture.receiverBindingID,
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, typeCodes: ["basal_energy"]))
    }

    func testIssue63ObservationCounterExhaustionNeverWrapsOrResets() throws {
        let fixture = try AutomaticStepsFaultFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.root.appendingPathComponent("exhausted-order")
        _ = try FileOutbox(directory: directory)
        let manifest = directory.appendingPathComponent(".fifo-sequence")
        let bytes = Data(#"{"version":3,"nextSequence":18446744073709551615,"entries":[]}"#.utf8)
        try bytes.write(to: manifest, options: [.atomic])
        let outbox = try FileOutbox(directory: directory)
        XCTAssertThrowsError(try outbox.reserveDailyProjectionObservation())
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }

    private func makeIssue63StreamRuntime(_ fixture: Issue63StreamFixture,
        eligible: [String] = ["steps"]) async throws -> HealthBridgeCompanionApplicationRuntime {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw Issue63FixtureError.isolatedHostRequired
        #else
        let base = fixture.base
        let defaults = try XCTUnwrap(UserDefaults(suiteName: base.suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        base.sessions.append(session)
        PayloadFenceURLProtocol.networkRecorder = base.recorder
        let viewModel = HealthBridgeCompanionViewModel(
            receiverClient: ReceiverClient(session: session), settingsStore: base.makeSettingsStore(defaults: defaults),
            pairingStateStore: ReceiverPairingStateStore(pendingStore: base.pairingPendingStore,
                installationIDStore: base.installationStore, cancellationStore: base.pairingCancellationStore,
                installationIDGenerator: { "synthetic-issue63-stream" }),
            backgroundSyncStore: BackgroundSyncSettingsStore(userDefaults: defaults),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: base.root.appendingPathComponent("diagnostics.json")),
            healthPermissionRequestStore: CompanionHealthPermissionRequestStore(userDefaults: defaults),
            healthHistoryDepthStore: HealthHistoryDepthSelectionStore(userDefaults: defaults),
            historicalBackfillStateStore: HealthHistoricalBackfillStateStore(userDefaults: defaults),
            quantityObservationStore: QuantityObservationStore(userDefaults: defaults),
            coreLaneUploadProofStore: CoreLaneUploadProofStore(userDefaults: defaults),
            outbox: try FileOutbox(directory: base.root.appendingPathComponent("outbox")),
            outboxDirectoryURL: base.root.appendingPathComponent("outbox"),
            cursorStore: try FileSyncCursorStore(fileURL: base.root.appendingPathComponent("cursors.json")),
            cursorStoreFileURL: base.root.appendingPathComponent("cursors.json"),
            sleepManifestStore: try FileSleepSyncManifestStore(fileURL: base.root.appendingPathComponent("sleep.json")),
            sleepManifestFileURL: base.root.appendingPathComponent("sleep.json"),
            sleepResetEpochStore: SleepResetEpochStore(tokenStore: MemoryReceiverTokenStore(), epochFloorProvider: { 1 }),
            mailboxKeyStore: MailboxKeyStore(service: "synthetic.issue63-stream", keychain: MemoryMailboxKeychain()),
            readAnchoredStepChanges: { try fixture.raw(anchor: $0, start: $1, now: $2) },
            automaticSyncEligibleTypeCodesForTesting: eligible,
            readDailyActivityAggregates: { try base.readDaily(types: $0, start: $1, end: $2, calendar: $3) },
            scheduleDirectBackgroundUploads: { base.declineBackgroundScheduling() },
            cancelInheritedLegacyUploads: { BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true) },
            terminalBackgroundPayloadDrain: { true }, platformBackgroundPayloadDrain: { true },
            readAnchoredQuantityChanges: { try fixture.quantity(type: $0, anchor: $1, start: $2, now: $3) }
        )
        await viewModel.bootstrap()
        XCTAssertFalse(viewModel.statusIsError, viewModel.statusMessage)
        let coordinator = HealthKitBackgroundDeliveryCoordinator(healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("Unexpected native HealthKit query") }, stopQuery: { _ in },
            enableDelivery: { _, completion in completion(false, nil) }, disableDelivery: { _ in })
        let platform = AutomaticSyncRuntime.Platform(scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in {} },
            healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator)
        return HealthBridgeCompanionApplicationRuntime(viewModel: viewModel, automaticSyncPlatform: platform)
        #endif
    }
}

private enum Issue63KnownWindowMode: Equatable, Sendable {
    case missingKnownDay, fullObservedWindow, neverObservedBlank
}

private enum Issue63KnownWindowPhase: String, Sendable {
    case seed, foreground, partial, restore
}

private func issue63KnownWindowRequire(
    _ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
) throws {
    _ = try XCTUnwrap(condition ? true : nil, message, file: file, line: line)
}

private struct Issue63KnownWindowManifest: Decodable {
    struct Repair: Decodable {
        let start: Date
        let end: Date
        let sequence: UInt64
    }
    let nextSequence: UInt64
    let projectionRepairs: [String: [Repair]]?
}

private final class Issue63KnownWindowTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@MainActor
private final class Issue63KnownWindowFixture {
    static let typeCode = "basal_energy"
    let root: URL
    let suiteName = "Issue63KnownWindow.\(UUID().uuidString)"
    let token = MemoryReceiverTokenStore()
    let backup = MemoryReceiverTokenStore()
    let pendingPairing = MemoryReceiverTokenStore()
    let installation = MemoryReceiverTokenStore()
    let cancellation = MemoryReceiverTokenStore()
    let recorder = PayloadFenceNetworkRecorder()
    let trace = Issue63KnownWindowTrace()
    let mode: Issue63KnownWindowMode
    let a: Date
    let b: Date
    let today: Date
    let seedAnchor: String
    let partialAnchor: String
    private(set) var binding = ""
    var phase = Issue63KnownWindowPhase.seed
    var sessions: [URLSession] = []
    var runtimes: [HealthBridgeCompanionApplicationRuntime] = []
    var authorizationRequests: [[String]] = []
    var ownersStarted = 0
    var ownersFinished = 0

    var rawKind: String {
        GenericQuantitySyncBatchFactory.automaticAnchoredCursorKind(for: Self.typeCode)
    }

    init(mode: Issue63KnownWindowMode) throws {
        self.mode = mode
        let calendar = Calendar.current
        today = calendar.startOfDay(for: Date())
        a = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: today))
        b = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: today))
        seedAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 101))
        partialAnchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 102))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Issue63KnownWindow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let savedSettings = settings(defaults)
        try savedSettings.save(receiverURLString: "https://synthetic.example.test/v1/batches",
            bearerToken: "synthetic-known-window-credential", rotateBindingID: true)
        binding = try XCTUnwrap(savedSettings.receiverBindingID)
        try BackgroundSyncSettingsStore(userDefaults: defaults).setEnabledDurably(true)
        CompanionHealthPermissionRequestStore(userDefaults: defaults).recordCompletedRequest(
            runtimeTypeCodes: HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes))
        let entry = try XCTUnwrap(HealthKitTypeCatalog.entry(for: Self.typeCode))
        try issue63KnownWindowRequire(entry.aggregation == .sum
            && HealthKitTypeCatalog.healthType(from: entry).category == .activity
            && HealthBridgeBackgroundSync.dailyActivityTypeCodes.contains(Self.typeCode),
            "SETUP: supported generic cumulative activity dispatch is required.")
    }

    func settings(_ defaults: UserDefaults) -> ReceiverSettingsStore {
        ReceiverSettingsStore(userDefaults: defaults, tokenStore: token,
            preCutoverBackupStore: backup, synchronize: { true })
    }

    func pending() throws -> [String: Int] {
        try BackgroundSyncSettingsStore(userDefaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
            .loadPendingObserverTypeCodeGenerations()
    }

    func cursor(_ kind: String) throws -> String? {
        try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
            .cursorValue(receiverBindingID: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey, cursorKind: kind)
    }

    func repairs() throws -> [Issue63KnownWindowManifest.Repair] {
        let path = root.appendingPathComponent("outbox/.fifo-sequence")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let state = try JSONDecoder().decode(Issue63KnownWindowManifest.self, from: Data(contentsOf: path))
        return state.projectionRepairs?[binding + "\n" + HealthBridgeAppleHealthSource.phone.sourceKey + "\n" + Self.typeCode] ?? []
    }

    func reservedSequence() throws -> UInt64 {
        let state = try JSONDecoder().decode(Issue63KnownWindowManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("outbox/.fifo-sequence")))
        try issue63KnownWindowRequire(state.nextSequence > 1, "SETUP: observation must be durably reserved before reading.")
        return state.nextSequence - 1
    }

    func dailySamples(since index: Int = 0) throws -> [HealthBridgeSample] {
        try recorder.acceptedPayloads.dropFirst(index).flatMap {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: $0).samples
        }.filter { $0.typeCode == Self.typeCode && $0.metadata["sample_kind"] == "daily_aggregate" }
    }

    func recordState(_ label: String) throws {
        let intervals = try repairs().map {
            "(\($0.start.timeIntervalSince(a)),\($0.end.timeIntervalSince(a)),\($0.sequence))"
        }.joined(separator: ",")
        trace.record("\(label): repairs=[\(intervals)] pending=\(try pending().values.sorted()) accepted=\(recorder.acceptedPayloads.count)")
    }

    func assertFresh() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        try issue63KnownWindowRequire(try cursor(rawKind) == nil
            && cursor(GenericQuantitySyncBatchFactory.anchoredCursorKind(for: Self.typeCode)) == nil
            && cursor(DailyActivityAggregateSyncPolicy.cursorKind) == nil
            && repairs().isEmpty && pending().isEmpty
            && QuantityObservationStore(userDefaults: defaults).observedTypeCodes.isEmpty
            && !CoreLaneUploadProofStore(userDefaults: defaults).hasUploadedRecords(lane: .steps, receiverBindingID: binding)
            && !CoreLaneUploadProofStore(userDefaults: defaults).hasUploadedRecords(lane: .workouts, receiverBindingID: binding),
            "SETUP: fresh stores must contain no manufactured progress, proof, history or repair.")
        trace.record("fresh.no-progress.ok")
    }

    func readRaw(type: String, anchor: String?, start: Date?, now: Date) throws -> HealthKitAnchoredQuantityChanges {
        try issue63KnownWindowRequire(type == Self.typeCode, "SETUP: unexpected selected raw type.")
        try issue63KnownWindowRequire(try cursor(rawKind) == anchor, "SETUP: reader must use the actual ACK-owned automatic cursor.")
        let days: [Date]
        let next: String
        switch phase {
        case .seed, .foreground:
            if anchor == nil {
                try issue63KnownWindowRequire(phase == .seed, "SETUP: foreground entry cannot manufacture a raw baseline.")
                days = mode == .neverObservedBlank ? [a] : [a, b]
                next = seedAnchor
                if let start {
                    try issue63KnownWindowRequire(start <= a.addingTimeInterval(3_600), "SETUP: raw seed must lie within the requested history.")
                }
            } else {
                try issue63KnownWindowRequire(anchor == seedAnchor, "SETUP: seed re-entry must use its earned anchor.")
                days = []
                next = seedAnchor
            }
        case .partial:
            try issue63KnownWindowRequire(anchor == seedAnchor || anchor == partialAnchor,
                "SETUP: partial collection requires previously ACKed generic raw progress.")
            days = anchor == seedAnchor ? [a] : []
            next = partialAnchor
        case .restore:
            try issue63KnownWindowRequire(anchor == partialAnchor, "SETUP: cold launch must retain the earned partial raw anchor.")
            days = []
            next = partialAnchor
        }
        let order = try reservedSequence()
        trace.record("\(phase.rawValue).raw.read: records=\(days.count) order=\(order) anchorKnown=\(anchor != nil)")
        if !days.isEmpty {
            try armACK(daily: false, order: order)
        }
        let samples = try days.map { day in
            HealthKitQuantitySampleSummary(
                uuid: try XCTUnwrap(UUID(uuidString: day == a
                    ? "00000000-0000-0000-0000-000000006301" : "00000000-0000-0000-0000-000000006302")),
                typeCode: type, start: day.addingTimeInterval(3_600), end: day.addingTimeInterval(3_660),
                value: phase == .partial ? 7 : 6)
        }
        return HealthKitAnchoredQuantityChanges(typeCode: type, samples: samples, deletedSamples: [],
            anchorCursorValue: next, windowStart: start ?? a, windowEnd: now)
    }

    func readDaily(types: [String], start: Date, end: Date, calendar: Calendar) throws -> [HealthKitDailyActivityAggregate] {
        try issue63KnownWindowRequire(types == [Self.typeCode], "SETUP: unexpected merged statistics type.")
        let before = try repairs()
        if phase == .partial {
            let old = try dailySamples().filter { $0.startTime == HealthBridgeUTCFormatter.string(from: b) }
            try issue63KnownWindowRequire(before.count == 1 && before[0].start == a
                && before[0].end == calendar.date(byAdding: .day, value: 1, to: a),
                "SETUP: only A has a pending raw repair; B must not be pre-seeded.")
            try issue63KnownWindowRequire(mode == .neverObservedBlank ? old.isEmpty : old.last?.value == 6,
                "SETUP: B must have the intended genuinely observed or never-observed history.")
            try issue63KnownWindowRequire(start <= a
                && calendar.date(byAdding: .day, value: 1, to: b).map { $0 <= end } == true,
                "SETUP: the actual partial statistics interval must contain complete A and B.")
            trace.record("partial.A-only.no-B-repair.window-AB.ok")
        }
        if phase == .restore {
            try issue63KnownWindowRequire(before.count == 1 && before[0].start == b && start <= b,
                "F3: recent cursor advancement must not strand the omitted known day.")
            trace.record("restore.query-reaches-B.ok")
        }
        var days: [Date]
        if mode == .fullObservedWindow {
            days = []
            var day = calendar.startOfDay(for: start)
            while day < calendar.startOfDay(for: end) {
                days.append(day)
                day = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            }
        } else if mode == .neverObservedBlank {
            days = [a]
        } else {
            switch phase {
            case .seed, .foreground: days = [a, b]
            case .partial: days = [a]
            case .restore: days = [b]
            }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let values = try days.map { day in
            let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            try issue63KnownWindowRequire(day >= start && next <= end, "SETUP: completed values must lie within the real requested window.")
            return HealthKitDailyActivityAggregate(typeCode: Self.typeCode, dayStart: day, dayEnd: next,
                value: phase == .partial ? 7 : (phase == .restore ? 9 : 6), isComplete: true,
                calendarDay: formatter.string(from: day), timeZoneIdentifier: calendar.timeZone.identifier)
        }
        trace.record("\(phase.rawValue).daily.read: startFromA=\(start.timeIntervalSince(a)) endFromA=\(end.timeIntervalSince(a)) records=\(values.count)")
        try armACK(daily: true, order: reservedSequence())
        return values
    }

    func armACK(daily: Bool, order: UInt64) throws {
        let root = self.root, binding = self.binding, suiteName = self.suiteName
        let type = Self.typeCode, phase = self.phase, mode = self.mode
        let a = self.a, b = self.b, trace = self.trace, rawKind = self.rawKind
        let oldRaw = try cursor(rawKind), oldDaily = try cursor(DailyActivityAggregateSyncPolicy.cursorKind)
        let admitted = try pending()
        let source = HealthBridgeAppleHealthSource.phone.sourceKey
        recorder.setBeforeResponse { bytes, _ in
            do {
                let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: bytes)
                let slot = try XCTUnwrap(batch.sync.cursors.first { $0.cursorKind == DailyProjectionObservation.cursorPrefix + type })
                let observation = try JSONDecoder().decode(Issue63ObservationWire.self, from: Data(slot.cursorValue.utf8))
                try issue63KnownWindowRequire(observation.sequence == order
                    && (observation.statisticsWindow != nil) == daily
                    && batch.deletedRecords.isEmpty
                    && batch.samples.allSatisfy {
                        $0.typeCode == type && $0.metadata["sample_kind"] == (daily ? "daily_aggregate" : "raw_quantity")
                    },
                    "SETUP: real encoded generic payload must match its reserved read, without Steps cleanup tombstones.")
                let head = try XCTUnwrap(FileOutbox(directory: root.appendingPathComponent("outbox")).pendingItems().first)
                try issue63KnownWindowRequire(try Data(contentsOf: head.fileURL) == bytes,
                    "SETUP: inspected bytes must be the actual durable FIFO head.")
                let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
                try issue63KnownWindowRequire(try cursors.cursorValue(receiverBindingID: binding, sourceKey: source, cursorKind: rawKind) == oldRaw
                    && cursors.cursorValue(receiverBindingID: binding, sourceKey: source, cursorKind: DailyActivityAggregateSyncPolicy.cursorKind) == oldDaily,
                    "SETUP: a payload cannot advance its checkpoint before actual ACK.")
                let pending = try BackgroundSyncSettingsStore(userDefaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
                    .loadPendingObserverTypeCodeGenerations()
                try issue63KnownWindowRequire(pending == admitted && (phase == .foreground || pending[type] != nil),
                    "SETUP: matching observer generation must remain pending before actual ACK.")
                let state = try JSONDecoder().decode(Issue63KnownWindowManifest.self,
                    from: Data(contentsOf: root.appendingPathComponent("outbox/.fifo-sequence")))
                let repairs = state.projectionRepairs?[binding + "\n" + source + "\n" + type] ?? []
                if phase == .partial {
                    try issue63KnownWindowRequire(repairs.contains { $0.start == a }
                        && repairs.allSatisfy { $0.start == a || (daily && mode == .missingKnownDay && $0.start == b) },
                        "SETUP: A stays pending before ACK; a new B obligation may only follow the partial result.")
                }
                if phase == .restore {
                    try issue63KnownWindowRequire(repairs.count == 1 && repairs[0].start == b,
                        "F3: B must remain pending before the real recollection ACK.")
                }
                if daily {
                    try issue63KnownWindowRequire(batch.samples.allSatisfy {
                        $0.metadata["aggregation_completeness"] == "complete" && $0.value.isFinite
                    }, "SETUP: only actual finite completed merged values may cover repair work.")
                }
                trace.record("\(phase.rawValue).\(daily ? "daily" : "raw").before-ACK.ok: order=\(order) repairs=\(repairs.count) pending=\(pending.values.sorted())")
            } catch {
                trace.record("SETUP.transport-inspection.failed")
                throw error
            }
        }
    }

    func makeRuntime() throws -> HealthBridgeCompanionApplicationRuntime {
        #if !HEALTH_BRIDGE_ISOLATED_APP_TEST_HOST
        throw Issue63FixtureError.isolatedHostRequired
        #else
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadFenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        PayloadFenceURLProtocol.networkRecorder = recorder
        let viewModel = HealthBridgeCompanionViewModel(
            receiverClient: ReceiverClient(session: session), settingsStore: settings(defaults),
            pairingStateStore: ReceiverPairingStateStore(pendingStore: pendingPairing,
                installationIDStore: installation, cancellationStore: cancellation,
                installationIDGenerator: { "synthetic-known-window-installation" }),
            backgroundSyncStore: BackgroundSyncSettingsStore(userDefaults: defaults),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json")),
            healthPermissionRequestStore: CompanionHealthPermissionRequestStore(userDefaults: defaults),
            healthHistoryDepthStore: HealthHistoryDepthSelectionStore(userDefaults: defaults),
            historicalBackfillStateStore: HealthHistoricalBackfillStateStore(userDefaults: defaults),
            quantityObservationStore: QuantityObservationStore(userDefaults: defaults),
            coreLaneUploadProofStore: CoreLaneUploadProofStore(userDefaults: defaults),
            outbox: try FileOutbox(directory: root.appendingPathComponent("outbox")),
            outboxDirectoryURL: root.appendingPathComponent("outbox"),
            cursorStore: try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            cursorStoreFileURL: root.appendingPathComponent("cursors.json"),
            sleepManifestStore: try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json")),
            sleepManifestFileURL: root.appendingPathComponent("sleep.json"),
            sleepResetEpochStore: SleepResetEpochStore(tokenStore: MemoryReceiverTokenStore(), epochFloorProvider: { 1 }),
            mailboxKeyStore: MailboxKeyStore(service: "synthetic.known-window", keychain: MemoryMailboxKeychain()),
            readAnchoredStepChanges: { _, _, _ in
                XCTFail("SETUP: unexpected Steps reader.")
                throw Issue63FixtureError.isolatedHostRequired
            },
            automaticSyncEligibleTypeCodesForTesting: [Self.typeCode],
            readDailyActivityAggregates: { try self.readDaily(types: $0, start: $1, end: $2, calendar: $3) },
            scheduleDirectBackgroundUploads: { 0 },
            cancelInheritedLegacyUploads: { BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true) },
            terminalBackgroundPayloadDrain: { true }, platformBackgroundPayloadDrain: { true },
            readAnchoredQuantityChanges: { try self.readRaw(type: $0, anchor: $1, start: $2, now: $3) },
            requestProjectionReadAuthorization: { types in
                try issue63KnownWindowRequire(self.phase == .foreground && types == [Self.typeCode],
                    "SETUP: only the explicit foreground daily seed requests authorization.")
                self.authorizationRequests.append(types)
                self.trace.record("foreground.authorization-request.injected")
            })
        let coordinator = HealthKitBackgroundDeliveryCoordinator(healthDataAvailable: { false },
            executeQuery: { _ in XCTFail("SETUP: unexpected real HealthKit query.") }, stopQuery: { _ in },
            enableDelivery: { _, completion in completion(false, nil) }, disableDelivery: { _ in })
        let platform = AutomaticSyncRuntime.Platform(scheduleRefresh: { _ in }, cancelRefresh: {}, consumeRefresh: {},
            setUploadAdmission: { _ in }, beginBackgroundOwner: { _ in
                self.ownersStarted += 1
                let label = self.phase.rawValue
                self.trace.record("\(label).owner.started")
                return {
                    self.ownersFinished += 1
                    self.trace.record("\(label).owner.finished")
                }
            }, healthDataAvailable: { false }, backgroundDeliveryCoordinator: coordinator)
        let runtime = HealthBridgeCompanionApplicationRuntime(viewModel: viewModel, automaticSyncPlatform: platform)
        runtimes.append(runtime)
        return runtime
        #endif
    }

    func join(_ runtime: HealthBridgeCompanionApplicationRuntime) async throws {
        await runtime.automaticSyncRuntime.waitForForegroundCatchUp()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
        try issue63KnownWindowRequire(!runtime.viewModel.automaticSyncOwnerIsActive
            && ownersStarted == ownersFinished, "SETUP: every started owner must be joined before changing phase.")
        try issue63KnownWindowRequire(!trace.snapshot.contains("SETUP.transport-inspection.failed"),
            "SETUP: transport preconditions failed; later product markers are not qualified.")
    }

    func stopAndJoin(_ runtime: HealthBridgeCompanionApplicationRuntime) async {
        let completion = runtime.automaticSyncRuntime.foregroundCatchUpCompletion()
        runtime.automaticSyncRuntime.stopAdmission()
        await completion?()
        await runtime.automaticSyncRuntime.cancelAndWait()
        await runtime.viewModel.waitForAutomaticSyncDisableCleanup()
        await runtime.viewModel.waitForBootstrapAndForegroundWork()
    }

    func tearDown() async {
        for runtime in runtimes { await stopAndJoin(runtime) }
        runtimes.removeAll()
        XCTAssertEqual(ownersStarted, ownersFinished)
        XCTContext.runActivity(named: "Issue63 synthetic causal state transitions") { activity in
            let attachment = XCTAttachment(string: trace.snapshot.joined(separator: "\n"))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        sessions.forEach { $0.invalidateAndCancel() }
        sessions.removeAll()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

extension HealthBridgeCompanionResetAdmissionTests {
    func testIssue63FollowupPartialWindowRetainsMissingKnownDayAcrossACKAndRestart() async throws {
        try await exerciseIssue63KnownWindow(.missingKnownDay)
    }

    func testIssue63FollowupFullyObservedWindowRetiresOnlyAfterACK() async throws {
        try await exerciseIssue63KnownWindow(.fullObservedWindow)
    }

    func testIssue63FollowupNeverObservedBlankDayDoesNotCreateRepair() async throws {
        try await exerciseIssue63KnownWindow(.neverObservedBlank)
    }

    private func exerciseIssue63KnownWindow(_ mode: Issue63KnownWindowMode) async throws {
        let fixture = try Issue63KnownWindowFixture(mode: mode)
        let previousRecorder = PayloadFenceURLProtocol.networkRecorder
        addTeardownBlock { @MainActor in
            await fixture.tearDown()
            PayloadFenceURLProtocol.networkRecorder = previousRecorder
        }
        var runtime: HealthBridgeCompanionApplicationRuntime? = try fixture.makeRuntime()
        try fixture.assertFresh()
        await runtime?.bootstrap()
        try await fixture.join(XCTUnwrap(runtime))
        try fixture.recordState("seed.accepted-and-owner-joined")
        try issue63KnownWindowRequire(try fixture.cursor(fixture.rawKind) == fixture.seedAnchor
            && fixture.repairs().isEmpty && fixture.pending().isEmpty
            && fixture.trace.snapshot.contains(where: { $0.hasPrefix("seed.daily.before-ACK.ok") }),
            "SETUP: natural launch must earn actual raw progress and retire all seeded repairs through ACK.")
        let initialB = try fixture.dailySamples().filter { $0.startTime == HealthBridgeUTCFormatter.string(from: fixture.b) }
        try issue63KnownWindowRequire(mode == .neverObservedBlank ? initialB.isEmpty : initialB.last?.value == 6,
            "SETUP: accepted seed must establish the intended known-B or never-observed-B control.")

        fixture.phase = .foreground
        let seededDaily = await runtime?.viewModel.syncDailyActivityAggregates(typeCodes: [Issue63KnownWindowFixture.typeCode])
        try await fixture.join(XCTUnwrap(runtime))
        try issue63KnownWindowRequire(seededDaily == true && fixture.authorizationRequests == [[Issue63KnownWindowFixture.typeCode]]
            && (try fixture.repairs()).isEmpty && (try fixture.pending()).isEmpty,
            "SETUP: explicit foreground daily ACK must finish the real seed without injected progress.")
        let seedDailyCursor = try XCTUnwrap(fixture.cursor(DailyActivityAggregateSyncPolicy.cursorKind))
        let seedDate = try XCTUnwrap(HealthBridgeUTCFormatter.date(from: seedDailyCursor))
        try issue63KnownWindowRequire(seedDate >= fixture.today, "SETUP: daily progress must already be recent while B is outside the rolling overlap.")
        try fixture.recordState("foreground.seed-checkpoint.accepted")
        try await Task.sleep(nanoseconds: 1_100_000_000)

        fixture.phase = .partial
        let active = try XCTUnwrap(runtime)
        let partialAcceptedStart = fixture.recorder.acceptedPayloads.count
        guard case .continueProcessing = active.viewModel.admitAutomaticSyncObserver(
            typeCode: Issue63KnownWindowFixture.typeCode, diagnosticRunID: UUID()) else {
            XCTFail("SETUP: supported durable observer admission failed.")
            return
        }
        let admitted = try fixture.pending()
        try issue63KnownWindowRequire(admitted.keys.sorted() == [Issue63KnownWindowFixture.typeCode],
            "SETUP: exactly the selected generic observer generation must be admitted.")
        await active.automaticSyncRuntime.runAutomaticSync(reason: .observerBatch(typeCodes: [Issue63KnownWindowFixture.typeCode]))
        try await fixture.join(active)
        try fixture.recordState("partial.accepted-and-owner-joined")
        try issue63KnownWindowRequire(fixture.trace.snapshot.contains("partial.A-only.no-B-repair.window-AB.ok")
            && fixture.trace.snapshot.contains(where: { $0.hasPrefix("partial.daily.before-ACK.ok") }),
            "SETUP: partial read and actual ACK prerequisites were not reached; no F3 product RED is qualified.")
        let partialValues = try fixture.dailySamples(since: partialAcceptedStart)
        try issue63KnownWindowRequire(partialValues.contains {
            $0.startTime == HealthBridgeUTCFormatter.string(from: fixture.a) && $0.value == 7
        } && (mode == .fullObservedWindow || !partialValues.contains {
            $0.startTime == HealthBridgeUTCFormatter.string(from: fixture.b)
        }), "SETUP: actual accepted partial statistics must contain A=7 and the intended B omission.")
        let recent = try XCTUnwrap(HealthBridgeUTCFormatter.date(from: XCTUnwrap(fixture.cursor(DailyActivityAggregateSyncPolicy.cursorKind))))
        try issue63KnownWindowRequire(try fixture.cursor(fixture.rawKind) == fixture.partialAnchor
            && recent > seedDate
            && FileOutbox(directory: fixture.root.appendingPathComponent("outbox")).pendingItems().isEmpty,
            "SETUP: observer ACK must earn partial raw progress and advance normal recent daily progress.")
        let expected = mode == .missingKnownDay ? [fixture.b] : []
        try issue63KnownWindowRequire(try fixture.repairs().map(\.start) == expected,
            "F3: A was ACKed; omitted known B needs a NEW obligation, but never-observed blank days do not.")
        try issue63KnownWindowRequire(try fixture.pending() == (mode == .missingKnownDay ? admitted : [:]),
            "F3: matching pending generation must survive exactly the missing-known-B obligation.")
        if mode == .missingKnownDay {
            await fixture.stopAndJoin(active)
            runtime = nil
            fixture.phase = .restore
            runtime = try fixture.makeRuntime()
            try fixture.recordState("cold.owner-created-before-bootstrap")
            try issue63KnownWindowRequire(try fixture.repairs().map(\.start) == expected
                && fixture.pending() == admitted,
                "F3: actual cold owner recreation must preserve known missing B and its pending generation.")
            let beforeRestore = fixture.recorder.acceptedPayloads.count
            await runtime?.bootstrap()
            try await fixture.join(XCTUnwrap(runtime))
            try fixture.recordState("restore.accepted-and-owner-joined")
            let restoredB = try fixture.dailySamples(since: beforeRestore).filter {
                $0.startTime == HealthBridgeUTCFormatter.string(from: fixture.b)
            }
            try issue63KnownWindowRequire(fixture.trace.snapshot.contains("restore.query-reaches-B.ok")
                && fixture.trace.snapshot.contains(where: { $0.hasPrefix("restore.daily.before-ACK.ok") })
                && restoredB.map(\.value) == [9],
                "F3: only actual newer completed B=9 may discharge B, never nil-to-zero.")
        }
        try issue63KnownWindowRequire(try fixture.pending().isEmpty && fixture.repairs().isEmpty,
            "F3: every legitimate obligation must retire after actual completed ACK.")
        if mode == .neverObservedBlank {
            try issue63KnownWindowRequire(try !fixture.dailySamples().contains {
                $0.startTime == HealthBridgeUTCFormatter.string(from: fixture.b)
            }, "F3: never-observed B must remain blank, not an invented total or repair.")
        }
        try issue63KnownWindowRequire(fixture.authorizationRequests == [[Issue63KnownWindowFixture.typeCode]],
            "SETUP: automatic observer/launch opportunities must not request authorization.")
    }
}

private enum ExchangeFailure: Error { case responseUnavailable, invalidPeer, pendingCleanupUnavailable }

// Independent synthetic receiver: current Python wire, CryptoKit and HBJCS1 only.
// Deliberately does not use any future native request/completion codec.
private final class ExchangePeer {
    static let invitationID = "00112233445566778899aabbccddeeff"
    static let invitationBytes = Data((0..<16).map { UInt8($0 * 17) })
    static let domain = "health-bridge/mailbox-pairing/v1/"
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey
    var tamper: String?
    var receiptTamper: String?
    var expectedBinding = ""

    init(signingByte: UInt8 = 0x31) throws {
        signing = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: signingByte, count: 32))
        agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x32, count: 32))
    }

    func invitation() throws -> ReceiverPairingInvitation {
        let object: [String: Any] = [
            "schema_id": "health_bridge.receiver_pairing_invitation.v2", "schema_version": "2.0.0",
            "label": "synthetic-native-iphone", "expires_at": "2099-01-01T00:00:00Z",
            "invitation_secret": "hbi_synthetic_native_invitation", "transport": "mailbox",
            "mailbox_protocol_version": 1,
            "mailbox_bootstrap": ["version": 1, "invitation_id": Self.invitationID,
                "receiver_signing_public_key": Self.b64(signing.publicKey.rawRepresentation),
                "receiver_agreement_public_key": Self.b64(agreement.publicKey.rawRepresentation)],
        ]
        return try ReceiverPairingInvitation(jsonData: JSONSerialization.data(withJSONObject: object))
    }

    static func installationHash(_ value: String) -> Data {
        hash(Data("health-bridge-pairing:installation:\(value)".utf8))
    }
    static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func b64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decoded(_ text: String) throws -> Data {
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        let bytes = try XCTUnwrap(Data(base64Encoded: padded))
        XCTAssertEqual(b64(bytes), text)
        return bytes
    }
    static func text(_ object: [String: Any], _ field: String) throws -> String {
        try XCTUnwrap(object[field] as? String, field)
    }
    static func canonical(_ object: [String: Any]) throws -> Data {
        var fields: [String: HBJCS1Value] = [:]
        for (key, value) in object {
            if let string = value as? String { fields[key] = .string(string) }
            else if let number = value as? Int { fields[key] = .integer(Int64(number)) }
            else if value is NSNull { fields[key] = .null }
            else { throw ExchangeFailure.invalidPeer }
        }
        return try DeliveryProtocolV1.encodeMetadata(.object(fields))
    }
    static func object(_ bytes: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(try canonical(object), bytes, "Wire must be canonical HBJCS1")
        return object
    }
    static func domainBytes(_ suffix: String) -> Data { Data((domain + suffix).utf8) }
    static func key(_ shared: SharedSecret, salt: Data, purpose: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: domainBytes(purpose), outputByteCount: 32)
    }
    static func keyID(_ algorithm: String, _ bytes: Data) -> String {
        hex(Data(hash(Data((algorithm + "\0").utf8) + bytes).prefix(16)))
    }
    static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func completion(request bytes: Data, pending: ReceiverPendingPairing) throws -> Data {
        XCTAssertLessThanOrEqual(bytes.count, 65_536)
        var envelope = try Self.object(bytes)
        guard Set(envelope.keys) == Set([
            "v", "kind", "invitation_id", "sender_signing_public_key",
            "ephemeral_public_key", "nonce", "ciphertext", "signature",
        ]) else { throw ExchangeFailure.invalidPeer }
        XCTAssertEqual(envelope["v"] as? Int, 1)
        XCTAssertEqual(try Self.text(envelope, "kind"), "request")
        XCTAssertEqual(try Self.text(envelope, "invitation_id"), Self.invitationID)
        let deviceSigning = try Self.decoded(Self.text(envelope, "sender_signing_public_key"))
        let signature = try Self.decoded(Self.text(envelope, "signature"))
        envelope.removeValue(forKey: "signature")
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: deviceSigning)
        guard try signingKey.isValidSignature(signature,
            for: Self.domainBytes("request/signature\0") + Self.canonical(envelope)) else {
            throw ExchangeFailure.invalidPeer
        }
        let ciphertext = try Self.decoded(Self.text(envelope, "ciphertext"))
        envelope.removeValue(forKey: "ciphertext")
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Self.decoded(Self.text(envelope, "ephemeral_public_key")))
        let requestShared = try agreement.sharedSecretFromKeyAgreement(with: ephemeral)
        let nonce = try AES.GCM.Nonce(data: Self.decoded(Self.text(envelope, "nonce")))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        let plaintext = try AES.GCM.open(box,
            using: Self.key(requestShared, salt: Self.invitationBytes, purpose: "request/key"),
            authenticating: Self.domainBytes("request/aad\0") + Self.canonical(envelope))
        let request = try Self.object(plaintext)
        guard Set(request.keys) == Set([
            "invitation_secret", "installation_id", "device_credential", "platform",
            "device_signing_public_key", "device_agreement_public_key",
        ]) else { throw ExchangeFailure.invalidPeer }
        XCTAssertEqual(try Self.text(request, "invitation_secret"), "hbi_synthetic_native_invitation")
        XCTAssertEqual(try Self.text(request, "installation_id"), pending.installationID)
        XCTAssertEqual(try Self.text(request, "device_credential"), pending.deviceCredential)
        XCTAssertEqual(try Self.text(request, "platform"), "ios")
        XCTAssertEqual(try Self.decoded(Self.text(request, "device_signing_public_key")), deviceSigning)
        let deviceAgreement = try Self.decoded(Self.text(request, "device_agreement_public_key"))
        let receiverSigning = signing.publicKey.rawRepresentation
        let receiverAgreement = agreement.publicKey.rawRepresentation
        let receiverID = Data(Self.hash(Data("health-bridge/mailbox/v1/receiver-id\0".utf8) + receiverSigning).prefix(16))
        let deviceID = Data(Self.hash(Data("health-bridge/mailbox/v1/device-id\0".utf8)
            + Self.installationHash(pending.installationID)).prefix(16))
        expectedBinding = Self.b64(Self.hash(Data("health-bridge/mailbox/v1/connection-binding\0".utf8)
            + receiverID + deviceID + deviceSigning + deviceAgreement + receiverSigning + receiverAgreement))
        var payload: [String: Any] = [
            "schema_id": "health_bridge.receiver_pairing_completion.v1", "schema_version": "1.0.0",
            "label": "synthetic-native-iphone", "receiver_url": NSNull(), "mailbox_protocol_version": 1,
            "mailbox_receiver_id": Self.hex(receiverID), "mailbox_device_id": Self.hex(deviceID),
            "mailbox_receiver_binding_id": expectedBinding, "mailbox_connection_generation": 1,
            "mailbox_receiver_signing_public_key": Self.b64(receiverSigning),
            "mailbox_receiver_agreement_public_key": Self.b64(receiverAgreement),
            "mailbox_receiver_signing_key_id": Self.keyID("ed25519", receiverSigning),
            "mailbox_receiver_agreement_key_id": Self.keyID("x25519", receiverAgreement),
        ]
        if tamper == "installation" { payload["mailbox_device_id"] = String(repeating: "9", count: 32) }
        if tamper == "binding" { payload["mailbox_receiver_binding_id"] = Self.b64(Data(repeating: 0x99, count: 32)) }
        let digest = Self.hash(bytes)
        let salt = Self.invitationBytes + digest
        let shared = try agreement.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: deviceAgreement))
        let nonceKey = Self.key(shared, salt: salt, purpose: "completion/nonce")
        let responseNonce = nonceKey.withUnsafeBytes { Data($0.prefix(12)) }
        let signer = tamper == "receiverTrust"
            ? try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x45, count: 32)) : signing
        var response: [String: Any] = ["v": 1, "kind": "completion",
            "invitation_id": tamper == "invitation" ? String(repeating: "9", count: 32) : Self.invitationID,
            "sender_signing_public_key": Self.b64(signer.publicKey.rawRepresentation),
            "request_sha256": tamper == "requestDigest" ? String(repeating: "9", count: 64) : Self.hex(digest),
            "nonce": Self.b64(responseNonce)]
        let sealed = try AES.GCM.seal(Self.canonical(payload),
            using: Self.key(shared, salt: salt, purpose: "completion/key"), nonce: AES.GCM.Nonce(data: responseNonce),
            authenticating: Self.domainBytes("completion/aad\0") + Self.canonical(response))
        response["ciphertext"] = Self.b64(sealed.ciphertext + sealed.tag)
        response["signature"] = try Self.b64(signer.signature(for:
            Self.domainBytes("completion/signature\0") + Self.canonical(response)))
        return try Self.canonical(response)
    }

    func cancelled(cancel: Data, request: Data) throws -> Data {
        var intent = try Self.object(cancel)
        guard Set(intent.keys) == Set([
            "v", "kind", "invitation_id", "request_sha256", "sender_signing_public_key", "signature",
        ]) else { throw ExchangeFailure.invalidPeer }
        let original = try Self.object(request)
        XCTAssertEqual(intent["v"] as? Int, 1)
        XCTAssertEqual(try Self.text(intent, "kind"), "cancel")
        XCTAssertEqual(try Self.text(intent, "invitation_id"), Self.invitationID)
        XCTAssertEqual(try Self.text(intent, "request_sha256"), Self.hex(Self.hash(request)))
        XCTAssertEqual(try Self.text(intent, "sender_signing_public_key"), try Self.text(original, "sender_signing_public_key"))
        let signature = try Self.decoded(Self.text(intent, "signature"))
        intent.removeValue(forKey: "signature")
        let device = try Curve25519.Signing.PublicKey(rawRepresentation:
            Self.decoded(Self.text(original, "sender_signing_public_key")))
        guard try device.isValidSignature(signature,
            for: Self.domainBytes("cancel/signature\0") + Self.canonical(intent)) else {
            throw ExchangeFailure.invalidPeer
        }
        var receipt: [String: Any] = ["v": 1, "kind": "cancelled", "invitation_id": Self.invitationID,
            "request_sha256": Self.hex(Self.hash(request)), "sender_signing_public_key": Self.b64(signing.publicKey.rawRepresentation)]
        if receiptTamper == "requestDigest" { receipt["request_sha256"] = String(repeating: "9", count: 64) }
        receipt["signature"] = try Self.b64(signing.signature(for:
            Self.domainBytes("cancelled/signature\0") + Self.canonical(receipt)))
        if receiptTamper == "signature" { receipt["signature"] = Self.b64(Data(repeating: 0, count: 64)) }
        return try Self.canonical(receipt)
    }
}

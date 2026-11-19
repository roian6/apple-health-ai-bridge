import Darwin
import Foundation
import Network
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class BackgroundAcceptedTransferObservationAppTests: XCTestCase {
    func testBootstrapFinishesInterruptedResetAndClearsTransferConfirmation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let accepted = LastAcceptedTransferObservation(
            bindingID: binding, generation: generation,
            observedAt: Date(timeIntervalSince1970: 1_790_000_000), evidenceKind: .directResponse
        )
        fixture.acceptedTransferStore.record(accepted)
        let ordinaryLaunch = try await fixture.makeViewModel()
        XCTAssertEqual(ordinaryLaunch.lastAcceptedTransferObservation, accepted)

        let item = try enqueueSteps(fixture)
        try FileOutbox.beginDestructiveRecovery(directory: fixture.outbox.directoryURL)
        XCTAssertTrue(fixture.outbox.destructiveRecoveryIsRequested)
        let resumed = try await fixture.makeViewModel()

        let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
        XCTAssertNil(try reopened.pendingItem(id: item.id))
        XCTAssertFalse(reopened.destructiveRecoveryIsRequested)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertEqual(fixture.settings.receiverBindingID, binding)
        XCTAssertNil(resumed.lastAcceptedTransferObservation)
        XCTAssertNil(fixture.acceptedTransferStore.load(
            bindingID: binding, generation: generation
        ))
    }

    func testUnrelatedBackgroundSuccessRetiresWithMalformedSleepJournal() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let item = try enqueueSteps(fixture)
        let journal = fixture.root.appendingPathComponent("sleep-sync-manifest-v1.json.pending")
        let damaged = Data("{".utf8)
        try damaged.write(to: journal)

        _ = try await receiveBackgroundCallback(item, fixture: fixture)

        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [],
                       "A real 202 for Steps must retire despite a damaged Sleep journal")
        XCTAssertEqual(try Data(contentsOf: journal), damaged)
    }

    func testSleepBackgroundSuccessWithMalformedJournalRetainsPayloadAndManifest() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let vm = try await fixture.makeViewModel()
        let generation = fixture.settings.receiverSettingsGenerationToken
        let manifestURL = fixture.root.appendingPathComponent("sleep-sync-manifest-v1.json")
        let sleepStore = try FileSleepSyncManifestStore(fileURL: manifestURL)
        let initial = SleepSyncBatchFactory.makeManifestReservation(
            receiverSettingsGeneration: generation, historyDepth: .allAvailable,
            historyStartDate: nil, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey
        )
        try sleepStore.saveManifest(initial)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let transition = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: initial,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: [HealthKitSleepChildSample(
                    uuid: UUID(), stage: "core", start: start, end: start.addingTimeInterval(3600)
                )], deletedSamples: [], anchorCursorValue: fixture.anchor,
                receivedAt: start.addingTimeInterval(7200)
            ),
            receiverSettingsGeneration: generation, historyDepth: .allAvailable, historyStartDate: nil
        ))
        let payload = try HealthBridgeBatchEncoder().encode(transition.batch)
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let item = try fixture.outbox.enqueue(payload, receiverIdentity: binding)
        let journal = manifestURL.appendingPathExtension("pending")
        let damaged = Data("{".utf8)
        try damaged.write(to: journal)

        let completion = try await receiveBackgroundCallback(item, fixture: fixture, expectRetainedOwnership: true)

        XCTAssertEqual(completion?.statusCode, 202)
        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(try sleepStore.loadManifest(), initial)
        XCTAssertEqual(try Data(contentsOf: journal), damaged)
        XCTAssertNil(vm.lastAcceptedTransferObservation)
    }

    func testBackgroundSuccessProjectsConfirmationAfterPlainItemRetires() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let vm = try await fixture.makeViewModel()
        let item = try enqueueSteps(fixture)
        XCTAssertNil(vm.lastAcceptedTransferObservation)

        _ = try await receiveBackgroundCallback(item, fixture: fixture)

        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(vm.lastAcceptedTransferObservation?.evidenceKind, .directResponse,
                       "The confirmation row must appear after a plain item is durably retired")
    }

    func testBackgroundSuccessProjectsConfirmationBeforeCollectionFinalization() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let vm = try await fixture.makeViewModel()
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: "synthetic_collection", cursorValue: fixture.anchor
        )
        let items = try fixture.outbox.enqueueSequence(
            [try stepsPayload(), try stepsPayload()], receiverIdentity: binding, cursorCheckpoint: checkpoint
        )
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        fixture.acceptedTransferStore.record(LastAcceptedTransferObservation(
            bindingID: binding, generation: generation, observedAt: oldDate, evidenceKind: .directResponse
        ))
        XCTAssertEqual(vm.lastAcceptedTransferObservation?.observedAt, oldDate)

        _ = try await receiveBackgroundCallback(items[0], fixture: fixture)

        let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
        XCTAssertEqual(try reopened.pendingItems().map(\.id), [items[1].id])
        XCTAssertNil(try reopened.directFinalizationRecordReady(receiverIdentity: binding))
        let cursors = try FileSyncCursorStore(fileURL: fixture.root.appendingPathComponent("sync-cursors.json"))
        XCTAssertNil(try cursors.cursorValue(
            receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
        ))
        XCTAssertNotEqual(vm.lastAcceptedTransferObservation?.observedAt, oldDate,
                          "The visible confirmation must advance even while the collection awaits its next item")
        XCTAssertEqual(vm.lastAcceptedTransferObservation?.evidenceKind, .directResponse)
    }

    func testRejectedBackgroundResponseDoesNotProjectConfirmation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let vm = try await fixture.makeViewModel()
        let item = try enqueueSteps(fixture)

        _ = try await receiveBackgroundCallback(item, fixture: fixture, status: 503)

        XCTAssertEqual(try fixture.outbox.pendingItems().map(\.id), [item.id])
        XCTAssertNil(vm.lastAcceptedTransferObservation)
    }

    func testBackgroundSuccessWithFailedOutboxDurabilityDoesNotProjectConfirmation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let vm = try await fixture.makeViewModel()
        let item = try enqueueSteps(fixture)
        let payload = try Data(contentsOf: item.fileURL)
        let journal = fixture.outbox.directoryURL.appendingPathComponent(".enqueue-transaction")
        let damaged = Data("{".utf8)

        let completion = try await receiveBackgroundCallback(item, fixture: fixture, expectRetainedOwnership: true) {
            try damaged.write(to: journal)
        }

        XCTAssertEqual(completion?.statusCode, 202)
        XCTAssertThrowsError(try fixture.outbox.pendingItems())
        XCTAssertEqual(try Data(contentsOf: journal), damaged)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertNil(vm.lastAcceptedTransferObservation)
    }

    func testDurableBackgroundAcceptanceConfirmsEvenWhenCursorWriteFails() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let vm = try await fixture.makeViewModel()
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: "synthetic_collection", cursorValue: fixture.anchor
        )
        let item = try XCTUnwrap(fixture.outbox.enqueueSequence(
            [try stepsPayload()], receiverIdentity: binding, cursorCheckpoint: checkpoint
        ).first)
        let cursorURL = fixture.root.appendingPathComponent("sync-cursors.json")
        _ = try FileSyncCursorStore(fileURL: cursorURL)
        // The existing cursor remains readable and accepts metadata changes.
        // An append-only flag on that file alone rejects atomic replacement.
        defer { _ = chflags(cursorURL.path, 0) }
        XCTAssertNil(vm.lastAcceptedTransferObservation)
        let acknowledged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: item.fileURL.path)
        }, object: nil)
        let completion = try await receiveBackgroundCallback(
            item, fixture: fixture, expectRetainedOwnership: true, reconcileRetainedCompletion: false
        ) {
            guard chflags(cursorURL.path, UInt32(UF_APPEND)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let readableCursor = try FileSyncCursorStore(fileURL: cursorURL)
            XCTAssertThrowsError(try readableCursor.saveCursorValue(
                checkpoint.cursorValue, receiverBindingID: binding,
                sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
            ))
        }
        await fulfillment(of: [acknowledged], timeout: 8)

        let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
        let ready = try XCTUnwrap(reopened.directFinalizationRecordReady(receiverIdentity: binding))
        XCTAssertEqual(ready.cursorCheckpoint, checkpoint)
        let ownership = try FileBackgroundUploadTaskOwnershipStore(
            fileURL: fixture.root.appendingPathComponent("background-tasks.json")
        )
        let retained = try XCTUnwrap(ownership.records().first)
        XCTAssertEqual(retained.itemID, item.id)
        XCTAssertEqual(retained.completion, completion)
        XCTAssertEqual(completion?.statusCode, 202)
        XCTAssertEqual(completion?.hadTransportError, false)
        let cursors = try FileSyncCursorStore(fileURL: cursorURL)
        XCTAssertNil(try cursors.cursorValue(
            receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
        ))
        let observed = vm.lastAcceptedTransferObservation
        XCTAssertEqual(observed?.evidenceKind, .directResponse,
                       "The first durable ACK must confirm while cursor finalization is still failing")

        guard chflags(cursorURL.path, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let restarted = BackgroundURLSessionOutboxUploader(
            receiverSettingsStore: fixture.settings, acceptedTransferStore: fixture.acceptedTransferStore,
            taskOwnershipStore: ownership
        )
        await recoverWithoutScheduling(restarted, fixture: fixture)

        XCTAssertTrue(try ownership.records().isEmpty)
        XCTAssertNil(try reopened.directFinalizationRecordReady(receiverIdentity: binding))
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: binding, sourceKey: checkpoint.sourceKey, cursorKind: checkpoint.cursorKind
        ), checkpoint.cursorValue)
        XCTAssertEqual(vm.lastAcceptedTransferObservation, observed,
                       "Replaying the durable ACK must not record it a second time")
        XCTAssertEqual(vm.lastAcceptedTransferObservation?.evidenceKind, .directResponse,
                       "Successful cursor replay must leave the original confirmation visible")
    }

    func testPersistedCompletionReplayPreservesAcceptedObservation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let item = try fixture.enqueueMixed()
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let ownership = try FileBackgroundUploadTaskOwnershipStore(
            fileURL: fixture.root.appendingPathComponent("background-tasks.json")
        )
        let completed = BackgroundUploadTaskOwnership(
            taskID: 42, itemID: item.id, receiverGeneration: generation,
            receiverBindingID: binding,
            completion: BackgroundUploadTaskCompletion(
                statusCode: 202, hadTransportError: false, sleepMinimumResetEpoch: nil
            )
        )
        let uploader = BackgroundURLSessionOutboxUploader(
            receiverSettingsStore: fixture.settings,
            acceptedTransferStore: fixture.acceptedTransferStore,
            taskOwnershipStore: ownership
        )
        try ownership.begin(completed)
        await recoverWithoutScheduling(uploader, fixture: fixture)
        let accepted = try XCTUnwrap(fixture.acceptedTransferStore.load(
            bindingID: binding, generation: generation
        ))
        XCTAssertEqual(accepted.evidenceKind, .directResponse)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        let cursors = try FileSyncCursorStore(
            fileURL: fixture.root.appendingPathComponent("sync-cursors.json")
        )
        let cursor = try cursors.cursorValue(
            receiverBindingID: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "dietary_protein")
        )
        XCTAssertEqual(cursor, fixture.anchor)
        let retained = LastAcceptedTransferObservation(
            bindingID: binding, generation: generation,
            observedAt: Date(timeIntervalSinceReferenceDate: 456_789), evidenceKind: .directResponse
        )
        fixture.acceptedTransferStore.record(retained)
        try ownership.begin(completed)

        await recoverWithoutScheduling(uploader, fixture: fixture)

        XCTAssertEqual(fixture.acceptedTransferStore.load(
            bindingID: binding, generation: generation
        ), retained)
        XCTAssertTrue(try ownership.records().isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "dietary_protein")
        ), cursor)
        XCTAssertTrue(fixture.receiver.batches.isEmpty)
    }

    private func recoverWithoutScheduling(
        _ uploader: BackgroundURLSessionOutboxUploader, fixture: NutritionFixture
    ) async {
        do {
            _ = try await uploader.schedulePendingUploads(
                outbox: fixture.outbox,
                receiverURL: XCTUnwrap(URL(string: fixture.settings.receiverURLString)),
                bearerToken: fixture.settings.loadBearerToken(),
                receiverGeneration: fixture.settings.receiverSettingsGenerationToken,
                receiverBindingID: XCTUnwrap(fixture.settings.receiverBindingID),
                isUploadAllowed: { false }
            )
            XCTFail("Closed admission must prevent a new background task")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func stepsPayload() throws -> Data {
        let fixtureDate = Date(timeIntervalSince1970: 1_790_000_000)
        let batch = try XCTUnwrap(GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(
            changes: HealthKitAnchoredQuantityChanges(
                typeCode: "steps",
                samples: [HealthKitQuantitySampleSummary(
                    uuid: UUID(), typeCode: "steps", start: fixtureDate,
                    end: fixtureDate.addingTimeInterval(60), value: 17
                )], deletedSamples: [], anchorCursorValue: "synthetic-steps",
                windowStart: fixtureDate, windowEnd: fixtureDate.addingTimeInterval(60)
            ), generatedAt: fixtureDate
        ).first)
        return try HealthBridgeBatchEncoder().encode(batch)
    }

    private func enqueueSteps(_ fixture: NutritionFixture) throws -> FileOutboxItem {
        try fixture.outbox.enqueue(stepsPayload(), receiverIdentity: XCTUnwrap(fixture.settings.receiverBindingID))
    }

    private func receiveBackgroundCallback(
        _ item: FileOutboxItem,
        fixture: NutritionFixture,
        status: Int = 202,
        expectRetainedOwnership: Bool = false,
        reconcileRetainedCompletion: Bool = true,
        beforeResume: () throws -> Void = {}
    ) async throws -> BackgroundUploadTaskCompletion? {
        let payload = try Data(contentsOf: item.fileURL)
        let ready = expectation(description: "Loopback receiver is listening")
        let received = expectation(description: "Loopback receiver got the exact upload and sent HTTP \(status)")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "background-callback-loopback")
        defer { listener.cancel() }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.reply(to: connection, payload: payload, status: status, received: received)
        }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/v1/batches"))
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let ownership = try FileBackgroundUploadTaskOwnershipStore(
            fileURL: fixture.root.appendingPathComponent("background-tasks.json")
        )
        let uploader = BackgroundURLSessionOutboxUploader(
            receiverSettingsStore: fixture.settings,
            acceptedTransferStore: fixture.acceptedTransferStore,
            taskOwnershipStore: ownership
        )
        // Point the real delegate at the fixture without starting its shared scheduling session.
        await recoverWithoutScheduling(uploader, fixture: fixture)
        let plan = try XCTUnwrap(BackgroundOutboxUploadPlanner.plan(
            pendingItems: [item], receiverURL: origin, bearerToken: fixture.settings.loadBearerToken(),
            receiverGeneration: generation, receiverBindingID: binding, alreadyScheduledItemIDs: []
        ).first)
        let configuration = URLSessionConfiguration.background(withIdentifier: "callback-test-\(UUID())")
        let session = URLSession(configuration: configuration, delegate: uploader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.uploadTask(with: plan.request, fromFile: plan.fileURL)
        task.taskDescription = plan.taskDescription
        let taskID = task.taskIdentifier
        try ownership.begin(BackgroundUploadTaskOwnership(
            taskID: taskID, itemID: item.id, receiverGeneration: generation, receiverBindingID: binding
        ))
        try beforeResume()
        let callback = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            do {
                let record = try ownership.record(forTaskID: taskID)
                return expectRetainedOwnership ? record?.completion != nil : record == nil
            } catch {
                return false
            }
        }, object: nil)
        task.resume()
        await fulfillment(of: [received], timeout: 15)
        let waited = await XCTWaiter.fulfillment(of: [callback], timeout: 8)
        XCTAssertEqual(waited, .completed, "HTTP \(status) callback did not reach expected durable ownership state")
        if expectRetainedOwnership && reconcileRetainedCompletion {
            // Join the production reconciler before reading negative postconditions.
            await recoverWithoutScheduling(uploader, fixture: fixture)
        }
        return try ownership.record(forTaskID: taskID)?.completion
    }

    private nonisolated static func reply(
        to connection: NWConnection, payload: Data, status: Int, received: XCTestExpectation,
        partial: Data = Data()
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, end, error in
            let bytes = partial + (data ?? Data())
            if let separator = bytes.range(of: Data("\r\n\r\n".utf8)),
               bytes.endIndex - separator.upperBound >= payload.count {
                XCTAssertTrue(bytes.starts(with: Data("POST /v1/batches HTTP/1.1\r\n".utf8)))
                XCTAssertEqual(Data(bytes[separator.upperBound...]), payload)
                let reason = status == 202 ? "Accepted" : "Service Unavailable"
                let response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { error in
                    XCTAssertNil(error)
                    received.fulfill()
                    connection.cancel()
                })
            } else if end || error != nil {
                XCTFail("Loopback request ended before receiving the complete upload: \(String(describing: error))")
                received.fulfill()
                connection.cancel()
            } else {
                reply(to: connection, payload: payload, status: status, received: received, partial: bytes)
            }
        }
    }
}

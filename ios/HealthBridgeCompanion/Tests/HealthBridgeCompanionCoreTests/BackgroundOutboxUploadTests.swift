import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class BackgroundOutboxUploadTests: XCTestCase {
    func testReceiverUploadRequestFactoryBuildsTokenBackedJSONPostWithoutBody() throws {
        let url = try XCTUnwrap(URL(string: "https://receiver.example.test/v1/batches"))

        let request = try ReceiverUploadRequestFactory.makeJSONPostRequest(
            url: url,
            bearerToken: "  token-value  "
        )

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.httpBody)
    }

    func testReceiverUploadRequestFactoryRejectsEmptyBearerToken() throws {
        let url = try XCTUnwrap(URL(string: "https://receiver.example.test/v1/batches"))

        XCTAssertThrowsError(
            try ReceiverUploadRequestFactory.makeJSONPostRequest(url: url, bearerToken: " \n ")
        ) { error in
            XCTAssertEqual(error as? ReceiverUploadRequestFactoryError, .emptyBearerToken)
        }
    }

    func testBackgroundOutboxTaskDescriptorRoundTripsSafeItemIDGenerationAndBindingWithoutSecrets() throws {
        let itemID = "00000000000000000001-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let receiverGeneration = "g123"
        let receiverBindingID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

        let description = try BackgroundOutboxTaskDescriptor.taskDescription(
            forItemID: itemID,
            receiverGeneration: receiverGeneration,
            receiverBindingID: receiverBindingID
        )

        XCTAssertEqual(BackgroundOutboxTaskDescriptor.itemID(fromTaskDescription: description), itemID)
        XCTAssertEqual(
            BackgroundOutboxTaskDescriptor.receiverGeneration(fromTaskDescription: description),
            receiverGeneration
        )
        XCTAssertEqual(
            BackgroundOutboxTaskDescriptor.receiverBindingID(fromTaskDescription: description),
            receiverBindingID
        )
        XCTAssertFalse(description.contains("Bearer"))
        XCTAssertFalse(description.contains("https://"))
        XCTAssertFalse(description.contains("/"))
    }

    func testBackgroundOutboxTaskDescriptorRejectsUnsafeItemIDsAndGenerations() {
        for unsafeID in ["", "../payload", "payload:token", "payload token", "payload/token", "payload\\token"] {
            XCTAssertThrowsError(
                try BackgroundOutboxTaskDescriptor.taskDescription(
                    forItemID: unsafeID,
                    receiverGeneration: "g1",
                    receiverBindingID: "binding-a"
                )
            )
        }
        for unsafeGeneration in ["", "g/1", "g:1", "g 1", "g.1"] {
            XCTAssertThrowsError(
                try BackgroundOutboxTaskDescriptor.taskDescription(
                    forItemID: "00000000000000000001-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    receiverGeneration: unsafeGeneration,
                    receiverBindingID: "binding-a"
                )
            )
        }
        for unsafeBindingID in ["", "binding/a", "binding:a", "binding a", "binding.a"] {
            XCTAssertThrowsError(
                try BackgroundOutboxTaskDescriptor.taskDescription(
                    forItemID: "00000000000000000001-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    receiverGeneration: "g1",
                    receiverBindingID: unsafeBindingID
                )
            )
        }
    }

    func testPlannerSchedulesOnlyOldestPendingItemToPreserveCursorOrder() throws {
        let directory = try temporaryDirectory()
        let outbox = try FileOutbox(directory: directory)
        let first = try outbox.enqueueForTesting(Data("one".utf8))
        _ = try outbox.enqueueForTesting(Data("two".utf8))
        _ = try outbox.enqueueForTesting(Data("three".utf8))
        let pending = try outbox.pendingItems()
        let receiverURL = try XCTUnwrap(URL(string: "https://receiver.example.test/v1/batches"))

        let plans = try BackgroundOutboxUploadPlanner.plan(
            pendingItems: pending,
            receiverURL: receiverURL,
            bearerToken: "token",
            receiverGeneration: "g1",
            receiverBindingID: "binding-a",
            alreadyScheduledItemIDs: [],
            maxTaskCount: 1
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].itemID, first.id)
        XCTAssertEqual(plans[0].receiverGeneration, "g1")
        XCTAssertEqual(plans[0].receiverBindingID, "binding-a")
        XCTAssertEqual(plans[0].fileURL.lastPathComponent, first.fileURL.lastPathComponent)
        XCTAssertEqual(plans[0].request.httpMethod, "POST")
        XCTAssertEqual(
            BackgroundOutboxTaskDescriptor.itemID(fromTaskDescription: plans[0].taskDescription),
            first.id
        )
        XCTAssertEqual(
            BackgroundOutboxTaskDescriptor.receiverBindingID(
                fromTaskDescription: plans[0].taskDescription
            ),
            "binding-a"
        )
    }

    func testPlannerDoesNotScheduleMoreWhenAnyBackgroundOutboxTaskIsAlreadyScheduled() throws {
        let directory = try temporaryDirectory()
        let outbox = try FileOutbox(directory: directory)
        let first = try outbox.enqueueForTesting(Data("one".utf8))
        _ = try outbox.enqueueForTesting(Data("two".utf8))
        let pending = try outbox.pendingItems()
        let receiverURL = try XCTUnwrap(URL(string: "https://receiver.example.test/v1/batches"))

        let plans = try BackgroundOutboxUploadPlanner.plan(
            pendingItems: pending,
            receiverURL: receiverURL,
            bearerToken: "token",
            receiverGeneration: "g1",
            receiverBindingID: "binding-a",
            alreadyScheduledItemIDs: [first.id],
            maxTaskCount: 1
        )

        XCTAssertTrue(plans.isEmpty)
    }

    func testPlannerRejectsEmptyTokenBeforeScheduling() throws {
        let receiverURL = try XCTUnwrap(URL(string: "https://receiver.example.test/v1/batches"))

        XCTAssertThrowsError(
            try BackgroundOutboxUploadPlanner.plan(
                pendingItems: [],
                receiverURL: receiverURL,
                bearerToken: "",
                receiverGeneration: "g1",
                receiverBindingID: "binding-a",
                alreadyScheduledItemIDs: [],
                maxTaskCount: 10
            )
        ) { error in
            XCTAssertEqual(error as? ReceiverUploadRequestFactoryError, .emptyBearerToken)
        }
    }

    func testCompletionPolicyMarksUploadedOnlyForTransportSuccess2xxAndCurrentReceiverGeneration() {
        XCTAssertTrue(BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(error: nil, httpStatusCode: 200))
        XCTAssertTrue(BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(error: nil, httpStatusCode: 204))
        XCTAssertFalse(BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(error: nil, httpStatusCode: 199))
        XCTAssertFalse(BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(error: nil, httpStatusCode: 300))
        XCTAssertFalse(BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), httpStatusCode: 200))
        XCTAssertFalse(BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(error: nil, httpStatusCode: nil))
        XCTAssertTrue(
            BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(
                error: nil,
                httpStatusCode: 200,
                taskReceiverGeneration: "g1",
                currentReceiverGeneration: "g1",
                taskReceiverBindingID: "binding-a",
                currentReceiverBindingID: "binding-a"
            )
        )
        XCTAssertFalse(
            BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(
                error: nil,
                httpStatusCode: 200,
                taskReceiverGeneration: "g1",
                currentReceiverGeneration: "g2",
                taskReceiverBindingID: "binding-a",
                currentReceiverBindingID: "binding-a"
            )
        )
        XCTAssertFalse(
            BackgroundOutboxUploadCompletionPolicy.shouldMarkUploaded(
                error: nil,
                httpStatusCode: 200,
                taskReceiverGeneration: "g1",
                currentReceiverGeneration: "g1",
                taskReceiverBindingID: "binding-a",
                currentReceiverBindingID: "binding-b"
            )
        )
    }

    func testCompletionPolicyParsesOnlyTypedSleepEpochConflictBodies() {
        let body = Data(
            #"{"error":"sleep_baseline_reset_epoch_conflict","minimum_reset_epoch":200}"#.utf8
        )

        XCTAssertEqual(
            BackgroundOutboxUploadCompletionPolicy.sleepBaselineConflictMinimumResetEpoch(
                error: nil,
                httpStatusCode: 409,
                responseBody: body
            ),
            200
        )
        XCTAssertNil(
            BackgroundOutboxUploadCompletionPolicy.sleepBaselineConflictMinimumResetEpoch(
                error: nil,
                httpStatusCode: 500,
                responseBody: body
            )
        )
        XCTAssertNil(
            BackgroundOutboxUploadCompletionPolicy.sleepBaselineConflictMinimumResetEpoch(
                error: nil,
                httpStatusCode: 409,
                responseBody: Data(#"{"error":"other","minimum_reset_epoch":200}"#.utf8)
            )
        )
    }

    func testBackgroundEventCompletionWaitsForUploadFinalization() throws {
        let coordinator = BackgroundEventFinalizationCoordinator<Int>()
        var completionCount = 0

        XCTAssertNil(coordinator.setCompletionHandler { completionCount += 1 })
        coordinator.begin(41)
        XCTAssertEqual(coordinator.pendingIDsSnapshot(), Set([41]))
        XCTAssertNil(coordinator.markEventsFinished())
        XCTAssertEqual(completionCount, 0)

        let completion = try XCTUnwrap(coordinator.complete(41))
        completion()

        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(coordinator.pendingIDsSnapshot().isEmpty)
        XCTAssertNil(coordinator.complete(41))
    }

    func testBackgroundEventCompletionDoesNotCarryAcrossUIKitWakeCycles() throws {
        let coordinator = BackgroundEventFinalizationCoordinator<Int>()
        var completionCount = 0

        XCTAssertNil(coordinator.markEventsFinished())
        XCTAssertNil(coordinator.setCompletionHandler { completionCount += 1 })
        XCTAssertEqual(completionCount, 0)

        let completion = try XCTUnwrap(coordinator.markEventsFinished())
        completion()

        XCTAssertEqual(completionCount, 1)
    }

    func testDuplicateBackgroundEventHandlersJoinSameUnfinishedCycle() throws {
        let coordinator = BackgroundEventFinalizationCoordinator<Int>()
        var completionOrder: [Int] = []

        XCTAssertNil(coordinator.setCompletionHandler { completionOrder.append(1) })
        coordinator.begin(51)
        XCTAssertNil(coordinator.markEventsFinished())
        XCTAssertNil(coordinator.setCompletionHandler { completionOrder.append(2) })
        let joinedState = coordinator.stateSnapshot()
        XCTAssertTrue(joinedState.hasUnfinishedEventCycle)
        XCTAssertEqual(joinedState.pendingIDs, [51])

        let completion = try XCTUnwrap(coordinator.complete(51))
        completion()

        XCTAssertEqual(completionOrder, [1, 2])
        XCTAssertTrue(coordinator.stateSnapshot().isIdle)
    }

    func testBackgroundTaskOwnershipLedgerSurvivesProcessRecreationUntilRemoval() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("background-task-ownership.json")
        let record = BackgroundUploadTaskOwnership(
            taskID: 73,
            itemID: "00000000000000000001-payload.json",
            receiverGeneration: "g1",
            receiverBindingID: "binding-a"
        )
        try FileBackgroundUploadTaskOwnershipStore(fileURL: fileURL).begin(record)

        let reopened = try FileBackgroundUploadTaskOwnershipStore(fileURL: fileURL)
        XCTAssertEqual(try reopened.records(), [record])
        let completion = BackgroundUploadTaskCompletion(
            statusCode: 409,
            hadTransportError: false,
            sleepMinimumResetEpoch: 200
        )
        try reopened.recordCompletion(completion, forTaskID: record.taskID)

        let completed = try XCTUnwrap(
            FileBackgroundUploadTaskOwnershipStore(fileURL: fileURL)
                .record(forTaskID: record.taskID)
        )
        XCTAssertEqual(completed.completion, completion)
        try reopened.remove(taskID: record.taskID)
        XCTAssertTrue(
            try FileBackgroundUploadTaskOwnershipStore(fileURL: fileURL).records().isEmpty
        )
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HealthBridgeBackgroundOutboxUploadTests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

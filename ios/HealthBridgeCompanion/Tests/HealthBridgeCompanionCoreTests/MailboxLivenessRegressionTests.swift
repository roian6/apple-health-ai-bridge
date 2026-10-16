import Darwin
import Dispatch
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxLivenessRegressionTests: XCTestCase {
    @MainActor
    func testPublicationExecutorAllowsMainActorHeartbeatBeforeOperationRelease() async {
        let barrier = MailboxPublicationHeartbeatBarrier()
        defer { barrier.releaseForCleanup() }
        let releaserFinished = XCTestExpectation(description: "independent releaser finished")
        DispatchQueue(label: "mailbox-liveness-test.releaser").async {
            barrier.releaseAfterHeartbeatOrTimeout()
            releaserFinished.fulfill()
        }

        let executor = MailboxFileProviderPublicationExecutor()
        // Await intentionally also compiles against the synchronous executor.
        let heartbeat = await executor.run {
            barrier.recordOperationEntered()
            let heartbeat = Task { @MainActor in
                barrier.recordHeartbeat()
            }
            barrier.waitForRelease()
            return heartbeat
        }
        await heartbeat.value
        let releaserResult = await XCTWaiter.fulfillment(of: [releaserFinished], timeout: 2)
        XCTAssertEqual(releaserResult, .completed)

        let snapshot = barrier.snapshot()
        XCTAssertEqual(
            snapshot.events,
            [.operationEntered, .heartbeat, .released, .operationReturned],
            "MainActor must run the heartbeat while the real executor operation is held"
        )
        XCTAssertFalse(snapshot.watchdogReleased, "Watchdog release is a failure, not responsiveness")
    }

    func testAckEnumerationRejectsRawEntryBudgetExhaustionIncludingIgnoredNames() throws {
        let lane = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailbox-liveness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: false)
        defer {
            do {
                try FileManager.default.removeItem(at: lane)
            } catch {
                XCTFail("Could not remove synthetic ACK lane: \(error)")
            }
        }

        func enumerateLane() throws -> MailboxAckLaneEnumeration {
            let directory = try MailboxAckFileReader.openDirectory(lane)
            defer { _ = close(directory) }
            return try MailboxAckFileReader.enumerate(directory: directory, maximumNames: 2)
        }

        let finalNames = (1 ... 3).map { String(format: "%032x.hba", $0) }
        for name in finalNames {
            try Data().write(to: lane.appendingPathComponent(name), options: [.withoutOverwriting])
        }
        let temporaryName = String(format: "%032x.hba.%032x.tmp", 1, 1)
        for name in [temporaryName, "invalid-synthetic-name"] {
            try Data().write(to: lane.appendingPathComponent(name), options: [.withoutOverwriting])
        }

        let small = try enumerateLane()
        XCTAssertEqual(small.finalNames, Array(finalNames.prefix(2)))
        XCTAssertEqual(small.ignoredTemporaryCount, 1)
        XCTAssertEqual(small.invalidNameCount, 1)

        for index in 1 ... (MailboxAckScanner.maximumScanFiles + 1) {
            let name = index.isMultiple(of: 2)
                ? String(format: "%032x.hba.%032x.tmp", index + 3, index + 3)
                : "invalid-synthetic-\(index)"
            try Data().write(to: lane.appendingPathComponent(name), options: [.withoutOverwriting])
        }

        XCTAssertThrowsError(
            try enumerateLane(),
            "Raw entries, including temporary and invalid names, must exhaust the scan budget"
        )
    }
}

// Every mutable field is protected by condition, justifying unchecked Sendable.
private final class MailboxPublicationHeartbeatBarrier: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case operationEntered
        case heartbeat
        case released
        case operationReturned
    }

    private let condition = NSCondition()
    private var events: [Event] = []
    private var heartbeatObserved = false
    private var released = false
    private var watchdogReleased = false

    func recordOperationEntered() {
        condition.lock()
        defer { condition.unlock() }
        events.append(.operationEntered)
    }

    func recordHeartbeat() {
        condition.lock()
        defer { condition.unlock() }
        events.append(.heartbeat)
        heartbeatObserved = true
        condition.broadcast()
    }

    func waitForRelease() {
        condition.lock()
        defer { condition.unlock() }
        while !released {
            condition.wait()
        }
        events.append(.operationReturned)
    }

    func releaseAfterHeartbeatOrTimeout() {
        let deadline = Date().addingTimeInterval(5)
        condition.lock()
        defer { condition.unlock() }
        while !heartbeatObserved && !released {
            if !condition.wait(until: deadline) { break }
        }
        guard !released else { return }
        watchdogReleased = !heartbeatObserved
        events.append(.released)
        released = true
        condition.broadcast()
    }

    func releaseForCleanup() {
        condition.lock()
        defer { condition.unlock() }
        released = true
        condition.broadcast()
    }

    func snapshot() -> (events: [Event], watchdogReleased: Bool) {
        condition.lock()
        defer { condition.unlock() }
        return (events, watchdogReleased)
    }
}

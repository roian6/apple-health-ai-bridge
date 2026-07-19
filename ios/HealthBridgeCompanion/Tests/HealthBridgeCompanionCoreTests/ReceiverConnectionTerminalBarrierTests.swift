import XCTest
@testable import HealthBridgeCompanionCore

final class ReceiverConnectionTerminalBarrierTests: XCTestCase {
    func testTerminalRequestLifecycleRejectsStaleActionsAfterFinalDrainUntilRelease() {
        let afterFinalDrain = TerminalRequestLifecycleSnapshot(
            requestIsActive: true,
            publicationIsSuppressed: false,
            payloadAdmissionIsOpen: true
        )
        XCTAssertFalse(afterFinalDrain.admitsUserAction)
        XCTAssertFalse(afterFinalDrain.admitsPayloadAction)

        let afterRequestRelease = TerminalRequestLifecycleSnapshot(
            requestIsActive: false,
            publicationIsSuppressed: false,
            payloadAdmissionIsOpen: true
        )
        XCTAssertTrue(afterRequestRelease.admitsUserAction)
        XCTAssertTrue(afterRequestRelease.admitsPayloadAction)
    }

    @MainActor
    func testTerminalRequestCoordinatorRejectsActionAfterFinalDrainUntilOutcomeRelease() async throws {
        let coordinator = TerminalRequestCoordinator()
        let finalDrainReached = expectation(description: "final drain reached")
        let outcomeGate = AsyncTestGate()
        var durableMutationCount = 0
        var publishedOutcomeCount = 0

        let terminalRequest = Task { @MainActor in
            try await coordinator.perform {
                finalDrainReached.fulfill()
                await outcomeGate.wait()
                publishedOutcomeCount += 1
                return "committed"
            }
        }

        await fulfillment(of: [finalDrainReached], timeout: 1)
        XCTAssertTrue(coordinator.isActive)
        do {
            _ = try await coordinator.perform {
                durableMutationCount += 1
            }
            XCTFail("Expected an action arriving after final drain to be rejected")
        } catch is CancellationError {
        }
        XCTAssertEqual(durableMutationCount, 0)
        XCTAssertEqual(publishedOutcomeCount, 0)

        await outcomeGate.open()
        let terminalResult = try await terminalRequest.value
        XCTAssertEqual(terminalResult, "committed")
        XCTAssertEqual(publishedOutcomeCount, 1)
        XCTAssertFalse(coordinator.isActive)

        try await coordinator.perform {
            durableMutationCount += 1
        }
        XCTAssertEqual(durableMutationCount, 1)
    }

    @MainActor
    func testPairingRequestEpochRejectsWaiterResumingAfterInvalidation() async {
        let epoch = PairingRequestEpoch()
        let waiterCapturedEpoch = expectation(description: "waiter captured epoch")
        let waiterGate = AsyncTestGate()
        var durableMutationCount = 0

        let waiter = Task { @MainActor in
            let capturedEpoch = epoch.capture()
            waiterCapturedEpoch.fulfill()
            await waiterGate.wait()
            guard epoch.isCurrent(capturedEpoch) else { return }
            durableMutationCount += 1
        }

        await fulfillment(of: [waiterCapturedEpoch], timeout: 1)
        epoch.invalidate()
        await waiterGate.open()
        await waiter.value

        XCTAssertEqual(durableMutationCount, 0)
    }

    @MainActor
    func testConcurrentTransitionWaitsForFirstTransitionThenCommits() async throws {
        let barrier = ReceiverConnectionTerminalBarrier()
        let drainStarted = expectation(description: "first drain started")
        let drainGate = AsyncTestGate()
        var events: [String] = []
        let first = Task { @MainActor in
            try await barrier.perform(
                closeAdmission: { events.append("first:close") },
                invalidateGeneration: { "g2" },
                cancelAndAwaitPairing: {},
                cancelAndAwaitForegroundPayloads: {
                    drainStarted.fulfill()
                    await drainGate.wait()
                },
                drainBackgroundPayloads: { true },
                commit: { _ in
                    events.append("first:commit")
                    return "first"
                }
            )
        }

        await fulfillment(of: [drainStarted], timeout: 1)
        let second = Task { @MainActor in
            try await barrier.perform(
                closeAdmission: { events.append("second:close") },
                invalidateGeneration: { "g3" },
                cancelAndAwaitPairing: {},
                cancelAndAwaitForegroundPayloads: {},
                drainBackgroundPayloads: { true },
                commit: { _ in
                    events.append("second:commit")
                    return "second"
                }
            )
        }
        await Task.yield()
        XCTAssertEqual(events, ["first:close"])
        await drainGate.open()

        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, "first")
        XCTAssertEqual(secondValue, "second")
        XCTAssertEqual(
            events,
            ["first:close", "first:commit", "second:close", "second:commit"]
        )
        XCTAssertTrue(barrier.admissionIsOpen)
    }

    @MainActor
    func testRecoveryTransitionSerializesAgainstConnectionReplacement() async throws {
        let barrier = ReceiverConnectionTerminalBarrier()
        let recoveryStarted = expectation(description: "recovery started")
        let recoveryGate = AsyncTestGate()
        var events: [String] = []
        let recovery = Task { @MainActor in
            try await barrier.performRecovery(
                closeAdmission: { events.append("recovery:close") },
                cancelAndAwaitPairing: { events.append("recovery:pairing") },
                cancelAndAwaitForegroundPayloads: {
                    events.append("recovery:foreground")
                    recoveryStarted.fulfill()
                    await recoveryGate.wait()
                },
                drainBackgroundPayloads: {
                    events.append("recovery:background")
                    return true
                },
                commit: {
                    events.append("recovery:commit")
                    return true
                }
            )
        }

        await fulfillment(of: [recoveryStarted], timeout: 1)
        let replacement = Task { @MainActor in
            try await barrier.perform(
                closeAdmission: { events.append("replacement:close") },
                invalidateGeneration: { "g2" },
                cancelAndAwaitPairing: {},
                cancelAndAwaitForegroundPayloads: {},
                drainBackgroundPayloads: { true },
                commit: { _ in events.append("replacement:commit") }
            )
        }
        await Task.yield()
        XCTAssertEqual(
            events,
            ["recovery:close", "recovery:pairing", "recovery:foreground"]
        )
        await recoveryGate.open()

        let recoveryValue = try await recovery.value
        XCTAssertTrue(recoveryValue)
        try await replacement.value
        XCTAssertEqual(
            events,
            [
                "recovery:close", "recovery:pairing", "recovery:foreground",
                "recovery:background", "recovery:commit", "replacement:close",
                "replacement:commit",
            ]
        )
        XCTAssertTrue(barrier.admissionIsOpen)
    }

    @MainActor
    func testTerminalTransitionClosesAdmissionAndDrainsInOrderBeforeCommit() async throws {
        let barrier = ReceiverConnectionTerminalBarrier()
        var events: [String] = []
        var generation = 1

        let committedGeneration = try await barrier.perform(
            closeAdmission: {
                XCTAssertFalse(barrier.admissionIsOpen)
                events.append("close")
            },
            invalidateGeneration: {
                XCTAssertFalse(barrier.admissionIsOpen)
                generation += 1
                events.append("invalidate")
                return "g\(generation)"
            },
            cancelAndAwaitPairing: {
                XCTAssertFalse(barrier.admissionIsOpen)
                events.append("pairing")
            },
            cancelAndAwaitForegroundPayloads: {
                XCTAssertFalse(barrier.admissionIsOpen)
                events.append("foreground")
            },
            drainBackgroundPayloads: {
                XCTAssertFalse(barrier.admissionIsOpen)
                events.append("background")
                return true
            },
            commit: { expectedGeneration in
                XCTAssertFalse(barrier.admissionIsOpen)
                events.append("commit")
                return expectedGeneration
            }
        )

        XCTAssertEqual(committedGeneration, "g2")
        XCTAssertEqual(
            events,
            ["close", "invalidate", "pairing", "foreground", "background", "commit"]
        )
        XCTAssertTrue(barrier.admissionIsOpen)
    }

    @MainActor
    func testStaleForegroundUploadCannotMutateDuringOrAfterTransition() async throws {
        let barrier = ReceiverConnectionTerminalBarrier()
        let uploadGeneration = "g7"
        var currentGeneration = uploadGeneration
        var mutationCount = 0

        _ = try await barrier.perform(
            closeAdmission: {},
            invalidateGeneration: {
                currentGeneration = "g8"
                return currentGeneration
            },
            cancelAndAwaitPairing: {},
            cancelAndAwaitForegroundPayloads: {
                if barrier.allowsPostResponseMutation(
                    capturedGeneration: uploadGeneration,
                    currentGeneration: currentGeneration
                ) {
                    mutationCount += 1
                }
            },
            drainBackgroundPayloads: { true },
            commit: { expectedGeneration in expectedGeneration }
        )

        if barrier.allowsPostResponseMutation(
            capturedGeneration: uploadGeneration,
            currentGeneration: currentGeneration
        ) {
            mutationCount += 1
        }

        XCTAssertEqual(mutationCount, 0)
        XCTAssertTrue(
            barrier.allowsPostResponseMutation(
                capturedGeneration: currentGeneration,
                currentGeneration: currentGeneration
            )
        )
    }

    @MainActor
    func testLegacyAndV2ReplacementShareTheSameTerminalBarrierSequence() async throws {
        let barrier = ReceiverConnectionTerminalBarrier()

        func runReplacement(_ label: String) async throws -> [String] {
            var events: [String] = []
            _ = try await barrier.perform(
                closeAdmission: { events.append("\(label):close") },
                invalidateGeneration: {
                    events.append("\(label):invalidate")
                    return "g-next"
                },
                cancelAndAwaitPairing: { events.append("\(label):pairing") },
                cancelAndAwaitForegroundPayloads: { events.append("\(label):foreground") },
                drainBackgroundPayloads: {
                    events.append("\(label):background")
                    return true
                },
                commit: { generation in
                    events.append("\(label):promote:\(generation)")
                }
            )
            return events.map { $0.replacingOccurrences(of: "\(label):", with: "") }
        }

        let legacyEvents = try await runReplacement("legacy-v1")
        let invitationEvents = try await runReplacement("invitation-v2")

        XCTAssertEqual(legacyEvents, invitationEvents)
        XCTAssertEqual(
            legacyEvents,
            ["close", "invalidate", "pairing", "foreground", "background", "promote:g-next"]
        )
    }

    @MainActor
    func testCancelledTransitionCannotCommitAfterCancellationDrain() async {
        let barrier = ReceiverConnectionTerminalBarrier()
        let drainStarted = expectation(description: "background drain started")
        let drainGate = AsyncTestGate()
        var didCommit = false
        let transition = Task { @MainActor in
            try await barrier.perform(
                closeAdmission: {},
                invalidateGeneration: { "g-next" },
                cancelAndAwaitPairing: {},
                cancelAndAwaitForegroundPayloads: {},
                drainBackgroundPayloads: {
                    drainStarted.fulfill()
                    await drainGate.wait()
                    return true
                },
                commit: { _ in didCommit = true }
            )
        }

        await fulfillment(of: [drainStarted], timeout: 1)
        transition.cancel()
        await drainGate.open()

        do {
            _ = try await transition.value
            XCTFail("Expected cancellation before commit")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertFalse(didCommit)
        XCTAssertTrue(barrier.admissionIsOpen)
    }

    @MainActor
    func testUnfinalizedBackgroundCancellationBlocksCommit() async {
        let barrier = ReceiverConnectionTerminalBarrier()
        var didCommit = false

        do {
            _ = try await barrier.perform(
                closeAdmission: {},
                invalidateGeneration: { "g-next" },
                cancelAndAwaitPairing: {},
                cancelAndAwaitForegroundPayloads: {},
                drainBackgroundPayloads: { false },
                commit: { _ in didCommit = true }
            )
            XCTFail("Expected unresolved cancellation to block commit")
        } catch let error as ReceiverConnectionTerminalBarrierError {
            XCTAssertEqual(error, .backgroundPayloadCancellationNotFinalized)
        } catch {
            XCTFail("Expected terminal barrier error, got \(error)")
        }

        XCTAssertFalse(didCommit)
        XCTAssertTrue(barrier.admissionIsOpen)
    }

    func testGenerationInvalidationDoesNotExposeOrChangeReceiverCredentials() throws {
        let suiteName = "ReceiverConnectionGenerationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = MemoryConnectionTokenStore()
        let settingsStore = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        try settingsStore.save(
            receiverURLString: "https://receiver.example.test/v1/batches",
            bearerToken: "synthetic-token"
        )

        let invalidatedGeneration = try settingsStore.invalidateReceiverSettingsGeneration()

        XCTAssertEqual(invalidatedGeneration, "g2")
        XCTAssertEqual(settingsStore.receiverURLString, "https://receiver.example.test/v1/batches")
        XCTAssertEqual(try settingsStore.loadBearerToken(), "synthetic-token")
        XCTAssertFalse(invalidatedGeneration.contains("synthetic-token"))
        XCTAssertFalse(invalidatedGeneration.contains("receiver.example.test"))
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class MemoryConnectionTokenStore: ReceiverTokenStoring {
    private var token = ""

    func loadToken() throws -> String { token }
    func saveToken(_ token: String) throws { self.token = token }
}

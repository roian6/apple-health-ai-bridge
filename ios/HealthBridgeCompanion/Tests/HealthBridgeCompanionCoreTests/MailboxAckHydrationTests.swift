import Foundation
import XCTest

#if canImport(HealthBridgeCompanionCore)
@testable import HealthBridgeCompanionCore
#endif

final class MailboxAckHydrationTests: XCTestCase {
    func testExplicitMissingCandidateIsSkippedWithoutWeakeningReplacementSafety() {
        XCTAssertEqual(
            ProductionMailboxAckHydration.identityFailureDisposition(
                .unavailable,
                explicitCandidate: true
            ),
            .skipCandidate
        )
        XCTAssertEqual(
            ProductionMailboxAckHydration.identityFailureDisposition(
                .unavailable,
                explicitCandidate: false
            ),
            .unsafeMailbox
        )
        XCTAssertEqual(
            ProductionMailboxAckHydration.identityFailureDisposition(
                .replaced,
                explicitCandidate: true
            ),
            .unsafeMailbox
        )
    }

    @MainActor
    func testDirectAcknowledgmentHitDoesNotInvokeBoundedFallback() async throws {
        var fallbackCalls = 0

        let selected = try await ProductionMailboxDelivery.preferDirectAcknowledgment(
            direct: { "direct" },
            boundedFallback: {
                fallbackCalls += 1
                return "fallback"
            }
        )

        XCTAssertEqual(selected, "direct")
        XCTAssertEqual(fallbackCalls, 0)
    }

    @MainActor
    func testAbsentOrUnusableDirectAcknowledgmentFallsBackInSameOpportunity() async throws {
        var fallbackCalls = 0

        let selected = try await ProductionMailboxDelivery.preferDirectAcknowledgment(
            direct: { nil as String? },
            boundedFallback: {
                fallbackCalls += 1
                return "checkpoint-window"
            }
        )

        XCTAssertEqual(selected, "checkpoint-window")
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testBackgroundPassRequestsOnlyItsBoundedPlaceholderWindow() async throws {
        let result = try await runThirtySevenPlaceholderScenario(maximumCandidates: 8)

        XCTAssertEqual(result.requestedCountBeforeFirstWait, 8)
        XCTAssertEqual(result.requestedURLs.count, 8)
        XCTAssertEqual(Set(result.requestedURLs).count, 8)
        XCTAssertEqual(result.waitCount, 1)
        XCTAssertEqual(
            result.report,
            MailboxAckHydrationReport(
                eligibleCandidateCount: 8,
                requestedDownloadCount: 8,
                remainingUnavailableCount: 0,
                skippedUnverifiableIdentityCount: 0
            )
        )
    }

    func testReportCountsRemainingUnavailableAndSkippedUnverifiableIdentities() async throws {
        let available = URL(fileURLWithPath: "/synthetic/acks/available.hba")
        let hydrated = URL(fileURLWithPath: "/synthetic/acks/hydrated.hba")
        let unavailable = URL(fileURLWithPath: "/synthetic/acks/unavailable.hba")
        var downloaded: Set<URL> = []
        let hydrator = MailboxAckHydrator(
            candidates: {
                MailboxAckHydrationCandidates(
                    eligible: [available, hydrated, unavailable],
                    skippedUnverifiableIdentityCount: 2
                )
            },
            availability: {
                $0 == available || downloaded.contains($0) ? .available : .remote
            },
            requestDownload: { candidate in
                if candidate == hydrated {
                    downloaded.insert(candidate)
                }
            },
            wait: {},
            maximumWaits: 1
        )

        let report = try await hydrator.hydrate()

        XCTAssertEqual(
            report,
            MailboxAckHydrationReport(
                eligibleCandidateCount: 3,
                requestedDownloadCount: 2,
                remainingUnavailableCount: 1,
                skippedUnverifiableIdentityCount: 2
            )
        )
    }

    func testProductionSummaryFormatsSecretFreeAckDiagnosticCounts() {
        var quarantine = MailboxAckQuarantineSummary()
        quarantine.append(.invalidName)
        quarantine.append(.authenticationFailed)
        quarantine.append(.authenticationFailed)
        quarantine.append(.stale)
        let summary = ProductionMailboxDeliverySummary(
            attemptedCount: 5,
            finalizedCount: 3,
            waitingCount: 2,
            terminalCount: 0,
            ackCleanupFailureCount: 1,
            hydration: MailboxAckHydrationReport(
                eligibleCandidateCount: 7,
                requestedDownloadCount: 6,
                remainingUnavailableCount: 2,
                skippedUnverifiableIdentityCount: 1
            ),
            scannedFinalCount: 4,
            scannedByteCount: 2_048,
            ignoredTemporaryCount: 3,
            quarantine: quarantine
        )

        XCTAssertEqual(
            summary.ackDiagnosticLine,
            "Mailbox ACK diagnostics: hydration eligible=7, downloadRequests=6, "
                + "remainingUnavailable=2, skippedUnverifiableIdentity=1; scan finalCount=4, "
                + "byteCount=2048, ignoredTemporaryCount=3; cleanupFailures=1; quarantine invalidName=1, "
                + "unsafeEntry=0, oversize=0, authenticationFailed=2, unknownEnvelope=0, "
                + "stale=1, bindingConflict=0, suppressed=0."
        )
    }

    func testDurablyCommittedAckCleanupFailureIsBestEffort() {
        var cleanupCalls = 0

        let deleted = ProductionMailboxDelivery.deleteAcknowledgmentAfterDurableCommit {
            cleanupCalls += 1
            throw SyntheticAckCleanupError.providerRejectedDeletion
        }

        XCTAssertFalse(deleted)
        XCTAssertEqual(cleanupCalls, 1)
    }

    func testDurablyCommittedAckCleanupSuccessIsReported() {
        var cleanupCalls = 0

        let deleted = ProductionMailboxDelivery.deleteAcknowledgmentAfterDurableCommit {
            cleanupCalls += 1
        }

        XCTAssertTrue(deleted)
        XCTAssertEqual(cleanupCalls, 1)
    }

    func testAcknowledgmentsAreOrderedByPendingFIFOThenStaleCleanup() {
        let order = ProductionMailboxDelivery.orderedAcknowledgmentIndices(
            itemIDs: ["later", "stale-a", "first", "middle", "stale-b"],
            pendingItemIDs: ["first", "middle", "later"]
        )

        XCTAssertEqual(order, [2, 3, 0, 1, 4])
    }

    func testBackgroundAcknowledgmentSelectionReturnsOnlyTheFIFOHead() {
        let head = Data(repeating: 1, count: 16)
        let later = Data(repeating: 2, count: 16)
        XCTAssertEqual(
            ProductionMailboxDelivery.acknowledgmentIndexForPendingFIFOHead(
                eventEnvelopeIDs: [later, head, head],
                pendingFIFOHeadEnvelopeID: head
            ),
            1
        )
        XCTAssertNil(
            ProductionMailboxDelivery.acknowledgmentIndexForPendingFIFOHead(
                eventEnvelopeIDs: [later],
                pendingFIFOHeadEnvelopeID: head
            )
        )
    }

    func testBackgroundPhaseNeverCombinesPublishAndAcknowledgmentWork() {
        XCTAssertEqual(
            ProductionMailboxDelivery.backgroundPhase(for: .collected),
            .publishFIFOHead
        )
        XCTAssertEqual(
            ProductionMailboxDelivery.backgroundPhase(for: .published),
            .reconcileFIFOHeadAcknowledgment
        )
        XCTAssertEqual(
            ProductionMailboxDelivery.backgroundPhase(for: .providerObserved),
            .reconcileFIFOHeadAcknowledgment
        )
        XCTAssertEqual(
            ProductionMailboxDelivery.backgroundPhase(for: .ackVerified),
            .reconcileFIFOHeadAcknowledgment
        )
        XCTAssertEqual(
            ProductionMailboxDelivery.backgroundPhase(for: .terminalFailure),
            .none
        )
    }

    func testPreCancelledTaskDoesNotInspectOrRequestCandidates() async {
        let result = await runPreCancelledScenario()

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.candidateCalls, 0)
        XCTAssertEqual(result.requestedCount, 0)
    }

    func testMidSweepCancellationStopsFurtherDownloadRequests() async {
        let result = await runMidSweepCancellationScenario()

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.requestedCount, 5)
    }
}

private enum SyntheticAckCleanupError: Error {
    case providerRejectedDeletion
}

private struct MailboxAckHydrationScenarioResult {
    let requestedCountBeforeFirstWait: Int
    let requestedURLs: [URL]
    let waitCount: Int
    let report: MailboxAckHydrationReport
}

private struct MailboxAckCancellationScenarioResult: Sendable {
    let cancelled: Bool
    let candidateCalls: Int
    let requestedCount: Int
}

private func runPreCancelledScenario() async -> MailboxAckCancellationScenarioResult {
    await Task {
        var candidateCalls = 0
        var requestedCount = 0
        let hydrator = MailboxAckHydrator(
            candidates: {
                candidateCalls += 1
                return MailboxAckHydrationCandidates(
                    eligible: [URL(fileURLWithPath: "/synthetic/acks/00000000000000000000000000000000.hba")],
                    skippedUnverifiableIdentityCount: 0
                )
            },
            availability: { _ in .remote },
            requestDownload: { _ in requestedCount += 1 },
            wait: {},
            maximumWaits: 1
        )
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try await hydrator.hydrate()
            return MailboxAckCancellationScenarioResult(
                cancelled: false,
                candidateCalls: candidateCalls,
                requestedCount: requestedCount
            )
        } catch is CancellationError {
            return MailboxAckCancellationScenarioResult(
                cancelled: true,
                candidateCalls: candidateCalls,
                requestedCount: requestedCount
            )
        } catch {
            return MailboxAckCancellationScenarioResult(
                cancelled: false,
                candidateCalls: candidateCalls,
                requestedCount: requestedCount
            )
        }
    }.value
}

private func runMidSweepCancellationScenario() async -> MailboxAckCancellationScenarioResult {
    await Task {
        let candidates = (0 ..< 37).map {
            URL(fileURLWithPath: "/synthetic/acks/\(String(format: "%032x", $0)).hba")
        }
        var candidateCalls = 0
        var requestedCount = 0
        let hydrator = MailboxAckHydrator(
            candidates: {
                candidateCalls += 1
                return MailboxAckHydrationCandidates(
                    eligible: candidates,
                    skippedUnverifiableIdentityCount: 0
                )
            },
            availability: { _ in .remote },
            requestDownload: { _ in
                requestedCount += 1
                if requestedCount == 5 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            wait: {},
            maximumWaits: 1
        )
        do {
            _ = try await hydrator.hydrate()
            return MailboxAckCancellationScenarioResult(
                cancelled: false,
                candidateCalls: candidateCalls,
                requestedCount: requestedCount
            )
        } catch is CancellationError {
            return MailboxAckCancellationScenarioResult(
                cancelled: true,
                candidateCalls: candidateCalls,
                requestedCount: requestedCount
            )
        } catch {
            return MailboxAckCancellationScenarioResult(
                cancelled: false,
                candidateCalls: candidateCalls,
                requestedCount: requestedCount
            )
        }
    }.value
}

private func runThirtySevenPlaceholderScenario(maximumCandidates: Int) async throws
    -> MailboxAckHydrationScenarioResult
{
    let candidates = (0 ..< 37).map {
        URL(fileURLWithPath: "/synthetic/acks/\(String(format: "%032x", $0)).hba")
    }
    var downloaded: Set<URL> = []
    var requested: [URL] = []
    var requestedCountBeforeFirstWait = -1
    var waitCount = 0
    let hydrator = MailboxAckHydrator(
        candidates: {
            MailboxAckHydrationCandidates(
                eligible: candidates,
                skippedUnverifiableIdentityCount: 0
            )
        },
        availability: { downloaded.contains($0) ? .available : .remote },
        requestDownload: { requested.append($0) },
        wait: {
            waitCount += 1
            if requestedCountBeforeFirstWait == -1 {
                requestedCountBeforeFirstWait = requested.count
            }
            downloaded.formUnion(requested)
        },
        maximumWaits: 2,
        maximumCandidates: maximumCandidates
    )

    let report = try await hydrator.hydrate()
    return MailboxAckHydrationScenarioResult(
        requestedCountBeforeFirstWait: requestedCountBeforeFirstWait,
        requestedURLs: requested,
        waitCount: waitCount,
        report: report
    )
}

#if ACK_HYDRATION_STANDALONE
private enum MailboxAckHydrationRegressionFailure: Error {
    case unexpectedResult
}

@main
private enum MailboxAckHydrationRegressionRunner {
    static func main() async throws {
        let result = try await runThirtySevenPlaceholderScenario(maximumCandidates: 8)
        guard result.requestedCountBeforeFirstWait == 8,
              result.requestedURLs.count == 8,
              Set(result.requestedURLs).count == 8,
              result.waitCount == 1 else {
            throw MailboxAckHydrationRegressionFailure.unexpectedResult
        }
        let preCancelled = await runPreCancelledScenario()
        guard preCancelled.cancelled,
              preCancelled.candidateCalls == 0,
              preCancelled.requestedCount == 0 else {
            throw MailboxAckHydrationRegressionFailure.unexpectedResult
        }
        let midSweep = await runMidSweepCancellationScenario()
        guard midSweep.cancelled,
              midSweep.requestedCount == 5 else {
            throw MailboxAckHydrationRegressionFailure.unexpectedResult
        }
        print("ACK hydration regression passed: requested=8 waits=1 cancellation=pre+mid")
    }
}
#endif

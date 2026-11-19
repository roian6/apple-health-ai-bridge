import XCTest
@testable import HealthBridgeCompanionCore

final class CompanionSyncPresentationTests: XCTestCase {
    func testFreshUnpairedStateIsNeutral() {
        let presentation = makePresentation(connected: false)

        XCTAssertEqual(presentation.phase, .unpaired)
        XCTAssertEqual(presentation.tone, .neutral)
    }

    func testRecoveryOutranksPairingActivityErrorsAndQueuedWork() {
        let presentation = makePresentation(
            syncing: true, error: true, pending: 2,
            pairing: true, pendingPairing: true, recovery: true
        )

        XCTAssertEqual(presentation.phase, .recoveryRequired)
        XCTAssertEqual(presentation.tone, .error)
    }

    func testPairingActivityOutranksPendingPairingAndStaleError() {
        let presentation = makePresentation(
            connected: false, error: true, pending: 2,
            pairing: true, pendingPairing: true
        )

        XCTAssertEqual(presentation.phase, .pairing)
        XCTAssertEqual(presentation.tone, .active)
    }

    func testPendingPairingOutranksDisconnectedQueueAndError() {
        let presentation = makePresentation(
            connected: false, error: true, pending: 2, pendingPairing: true
        )

        XCTAssertEqual(presentation.phase, .pendingPairing)
        XCTAssertEqual(presentation.tone, .attention)
    }

    func testDisconnectedQueuedWorkIsActionableRatherThanUnpairedOrActive() {
        for mailbox in [false, true] {
            let presentation = makePresentation(
                connected: false, syncing: true, error: true, pending: 2,
                mailbox: mailbox
            )

            XCTAssertEqual(presentation.phase, .connectionRequired)
            XCTAssertEqual(presentation.tone, .attention)
        }
    }

    func testBlockedSavedConnectionDoesNotAppearReadyOrActive() {
        let presentation = makePresentation(syncing: true, canSend: false)

        XCTAssertEqual(presentation.phase, .connectionRequired)
        XCTAssertEqual(presentation.tone, .attention)
    }

    func testActiveSyncOutranksErrorQueueAndPermissionRequest() {
        let presentation = makePresentation(
            permissionsRequested: false, syncing: true, error: true, pending: 2
        )

        XCTAssertEqual(presentation.phase, .syncing)
        XCTAssertEqual(presentation.tone, .active)
    }

    func testErrorOutranksQueuePermissionRequestAndNeutralSetup() {
        for connected in [false, true] {
            let presentation = makePresentation(
                connected: connected, permissionsRequested: false, error: true,
                pending: connected ? 2 : 0
            )

            XCTAssertEqual(presentation.phase, .needsAttention)
            XCTAssertEqual(presentation.tone, .error)
        }
    }

    func testQueuedRouteOutranksPermissionRequestAndNeverReportsReady() {
        let cases: [(Bool, CompanionSyncPresentation.Phase)] = [
            (false, .directQueued),
            (true, .mailboxConfirmationWaiting),
        ]
        for (mailbox, expected) in cases {
            let presentation = makePresentation(
                permissionsRequested: false, pending: 2, mailbox: mailbox
            )

            XCTAssertEqual(presentation.phase, expected)
            XCTAssertEqual(presentation.tone, .attention)
        }
    }

    func testPermissionRequestNeededForBothSavedRoutes() {
        for mailbox in [false, true] {
            let presentation = makePresentation(permissionsRequested: false, mailbox: mailbox)

            XCTAssertEqual(presentation.phase, .permissionRequestNeeded)
            XCTAssertEqual(presentation.tone, .attention)
        }
    }

    func testRequestedPermissionsAndEmptyQueueMeanOnlyNeutralReadiness() {
        for mailbox in [false, true] {
            let presentation = makePresentation(mailbox: mailbox)

            XCTAssertEqual(presentation.phase, .ready)
            XCTAssertEqual(presentation.tone, .neutral)
        }
    }

    private func makePresentation(
        connected: Bool = true,
        permissionsRequested: Bool = true,
        syncing: Bool = false,
        error: Bool = false,
        pending: Int = 0,
        pairing: Bool = false,
        pendingPairing: Bool = false,
        recovery: Bool = false,
        mailbox: Bool = false,
        canSend: Bool? = nil
    ) -> CompanionSyncPresentation {
        CompanionSyncPresentation(
            snapshot: CompanionSetupSnapshot(
                receiverURLString: connected && !mailbox ? "https://receiver.example/v1/batches" : "",
                hasBearerToken: connected && !mailbox,
                healthPermissionsRequested: permissionsRequested,
                isSyncing: syncing,
                statusIsError: error,
                pendingOutboxCount: pending,
                hasCommittedMailboxConnection: connected && mailbox
            ),
            canSendConnectionTest: canSend ?? connected,
            isPairing: pairing,
            hasPendingPairing: pendingPairing,
            hasPendingPrivateStorageRecovery: recovery,
            usesMailboxTransport: mailbox
        )
    }
}

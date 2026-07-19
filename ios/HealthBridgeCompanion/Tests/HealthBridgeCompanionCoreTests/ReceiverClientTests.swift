import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HealthBridgeCompanionCore

final class ReceiverClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testForegroundSessionSeparatesShortProbesFromLongTransfers() {
        let configuration = ReceiverClient.foregroundSessionConfiguration()

        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 3_600)
    }

    func testRedirectPolicyAllowsOnlyTheConfiguredOrigin() throws {
        let original = try XCTUnwrap(
            URL(string: "https://health.tailnet.example:8766/v1/batches")
        )

        XCTAssertTrue(
            ReceiverRedirectPolicy.allowsRedirect(
                from: original,
                to: try XCTUnwrap(
                    URL(string: "https://health.tailnet.example:8766/v1/batches/")
                )
            )
        )
        XCTAssertFalse(
            ReceiverRedirectPolicy.allowsRedirect(
                from: original,
                to: try XCTUnwrap(
                    URL(string: "http://health.tailnet.example:8766/v1/batches")
                )
            )
        )
        XCTAssertFalse(
            ReceiverRedirectPolicy.allowsRedirect(
                from: original,
                to: try XCTUnwrap(
                    URL(string: "https://other.tailnet.example:8766/v1/batches")
                )
            )
        )
        XCTAssertFalse(
            ReceiverRedirectPolicy.allowsRedirect(
                from: original,
                to: try XCTUnwrap(
                    URL(string: "https://health.tailnet.example:9443/v1/batches")
                )
            )
        )
    }

    func testUploadPostsBatchWithBearerTokenAndJSONContentType() async throws {
        let expectedBody = Data(#"{"schema_id":"health_bridge.batch.v1"}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ReceiverClient(session: session)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.httpBodyStream?.readAllData(), expectedBody)
            XCTAssertEqual(request.timeoutInterval, 120)
            return MockURLProtocolResponse(
                response: HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body: Data("{}".utf8)
            )
        }

        let result = try await client.upload(
            expectedBody,
            to: try XCTUnwrap(URL(string: "http://127.0.0.1:8765/v1/batches")),
            bearerToken: "test-token"
        )

        XCTAssertEqual(result.statusCode, 202)
    }

    func testHealthURLUsesReceiverOriginAndDropsBatchPathQueryAndFragment() throws {
        let batchURL = try XCTUnwrap(URL(string: "https://health.tailnet.example:8766/v1/batches?debug=true#section"))

        let healthURL = ReceiverClient.healthURL(forBatchURL: batchURL)

        XCTAssertEqual(healthURL.absoluteString, "https://health.tailnet.example:8766/health")
    }

    func testHealthCheckUsesGetWithoutBearerToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = ReceiverClient(session: URLSession(configuration: configuration))

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://health.tailnet.example:8766/health")
            XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody)
            return MockURLProtocolResponse(
                response: HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body: Data(#"{"status":"ok"}"#.utf8)
            )
        }

        let result = try await client.healthCheck(
            forBatchURL: try XCTUnwrap(URL(string: "https://health.tailnet.example:8766/v1/batches"))
        )

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(String(data: result.responseBody, encoding: .utf8), #"{"status":"ok"}"#)
    }

    func testUploadRejectsUnauthorizedResponsesWithStatusAndBodyDetails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = ReceiverClient(session: URLSession(configuration: configuration))

        MockURLProtocol.requestHandler = { request in
            MockURLProtocolResponse(
                response: HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body: Data(#"{"detail":"bad receiver token"}"#.utf8)
            )
        }

        do {
            _ = try await client.upload(
                Data("{}".utf8),
                to: try XCTUnwrap(URL(string: "http://127.0.0.1:8765/v1/batches")),
                bearerToken: "bad-token"
            )
            XCTFail("Expected unauthorized response to throw")
        } catch ReceiverClientError.unsuccessfulStatusCode(let statusCode, let responseBody) {
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(String(data: responseBody, encoding: .utf8), #"{"detail":"bad receiver token"}"#)
            XCTAssertEqual(
                ReceiverClientError.unsuccessfulStatusCode(statusCode: statusCode, responseBody: responseBody).localizedDescription,
                "Receiver returned HTTP 401."
            )
        }
    }

    func testUploadDecodesSleepBaselineEpochConflictFloor() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = ReceiverClient(session: URLSession(configuration: configuration))

        MockURLProtocol.requestHandler = { request in
            MockURLProtocolResponse(
                response: HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body: Data(
                    #"{"error":"sleep_baseline_reset_epoch_conflict","minimum_reset_epoch":200}"#.utf8
                )
            )
        }

        do {
            _ = try await client.upload(
                Data("{}".utf8),
                to: try XCTUnwrap(URL(string: "http://127.0.0.1:8765/v1/batches")),
                bearerToken: "test-token"
            )
            XCTFail("Expected sleep epoch conflict to throw")
        } catch ReceiverClientError.sleepBaselineResetEpochConflict(let minimumResetEpoch) {
            XCTAssertEqual(minimumResetEpoch, 200)
        }
    }

    func testReceiverClientErrorsHaveUserReadableDescriptions() {
        XCTAssertEqual(ReceiverClientError.emptyBearerToken.localizedDescription, "Bearer token is empty.")
        XCTAssertEqual(ReceiverClientError.nonHTTPResponse.localizedDescription, "Receiver returned a non-HTTP response.")
        XCTAssertEqual(
            ReceiverClientError.unsuccessfulStatusCode(
                statusCode: 422,
                responseBody: Data(#"{"detail":"Bearer synthetic-secret-value"}"#.utf8)
            ).localizedDescription,
            "Receiver returned HTTP 422."
        )
    }

    func testRedeemInvitationPostsStagedCredentialAndInstallationWithoutAuthorization() async throws {
        let client = makeClient()
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        let pending = syntheticPendingPairing(invitation: invitation)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, invitation.redeemURLString)
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(request.httpBodyStream?.readAllData())
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload, [
                "invitation_secret": "hbi_synthetic_secret",
                "installation_id": syntheticInstallationID,
                "device_credential": syntheticDeviceCredential,
                "platform": "ios",
            ])
            return pairingCompletionResponse(for: request)
        }

        let credential = try await client.redeem(pendingPairing: pending)

        XCTAssertEqual(credential.receiverURLString, invitation.receiverURLString)
        XCTAssertEqual(credential.bearerToken, syntheticDeviceCredential)
        XCTAssertEqual(credential.label, "maintainer-iphone")
    }

    func testRedeemManualPairingPostsNormalizedCode() async throws {
        let client = makeClient()
        let manual = try ReceiverManualPairing(
            serverURLString: "https://health-bridge.example.test",
            invitationCode: "abcde fghjk mnpqr"
        )

        let pending = syntheticPendingPairing(manualPairing: manual)
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(request.httpBodyStream?.readAllData())
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload, [
                "invitation_code": "ABCDE-FGHJK-MNPQR",
                "installation_id": syntheticInstallationID,
                "device_credential": syntheticDeviceCredential,
                "platform": "ios",
            ])
            return pairingCompletionResponse(for: request)
        }

        let credential = try await client.redeem(pendingPairing: pending)

        XCTAssertEqual(credential.bearerToken, syntheticDeviceCredential)
    }

    func testRedeemErrorDoesNotExposeResponseBody() async throws {
        let client = makeClient()
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        let pending = syntheticPendingPairing(invitation: invitation)
        MockURLProtocol.requestHandler = { request in
            MockURLProtocolResponse(
                response: HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body: Data(#"{"error":"hbi_must_not_leak"}"#.utf8)
            )
        }

        do {
            _ = try await client.redeem(pendingPairing: pending)
            XCTFail("Expected pairing redeem failure")
        } catch let error as ReceiverPairingRedeemError {
            XCTAssertEqual(error, .unsuccessfulStatusCode(400))
            XCTAssertFalse(error.localizedDescription.contains("hbi_must_not_leak"))
        }
    }

    func testRedeemClassifiesOnlyExactServerInvalidInvitationAsDefinitive() async throws {
        let client = makeClient()
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        let pending = syntheticPendingPairing(invitation: invitation)
        MockURLProtocol.requestHandler = { request in
            MockURLProtocolResponse(
                response: HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body: Data(#"{"error":"pairing_invitation_invalid"}"#.utf8)
            )
        }

        do {
            _ = try await client.redeem(pendingPairing: pending)
            XCTFail("Expected definitive invalid invitation")
        } catch let error as ReceiverPairingRedeemError {
            XCTAssertEqual(error, .invitationInvalid)
        }
    }

    func testRedeemRejectsMismatchedReceiverURL() async throws {
        let client = makeClient()
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        let pending = syntheticPendingPairing(invitation: invitation)
        MockURLProtocol.requestHandler = { request in
            pairingCompletionResponse(
                for: request,
                receiverURL: "https://attacker.example/v1/batches"
            )
        }

        do {
            _ = try await client.redeem(pendingPairing: pending)
            XCTFail("Expected mismatched receiver URL")
        } catch let error as ReceiverPairingRedeemError {
            XCTAssertEqual(error, .mismatchedReceiverURL)
        }
    }

    func testPairingStateStoreStagesCredentialOnceAndReusesPendingTupleForSameInvitation() throws {
        let pendingStore = MemoryReceiverTokenStore()
        let installationStore = MemoryReceiverTokenStore()
        var generatedCredentials = [syntheticDeviceCredential, secondSyntheticDeviceCredential]
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationStore,
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { generatedCredentials.removeFirst() }
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))

        let first = try stateStore.stage(invitation: invitation)
        let second = try stateStore.stage(invitation: invitation)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.installationID, syntheticInstallationID)
        XCTAssertEqual(first.deviceCredential, syntheticDeviceCredential)
        XCTAssertEqual(generatedCredentials, [secondSyntheticDeviceCredential])
        XCTAssertEqual(try stateStore.loadPending(), first)
        XCTAssertFalse(pendingStore.token.isEmpty)
        XCTAssertEqual(installationStore.token, syntheticInstallationID)
    }

    func testPairingStateStorePrivateResetClearsPendingAndCancellation() throws {
        let pendingStore = MemoryReceiverTokenStore()
        let installationStore = MemoryReceiverTokenStore()
        let cancellationStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: installationStore,
            cancellationStore: cancellationStore,
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        _ = try stateStore.stage(invitation: invitation)
        try stateStore.beginPendingCancellation(expectedGeneration: "g1")

        try stateStore.resetPrivatePairingState()

        XCTAssertNil(try stateStore.loadPending())
        XCTAssertFalse(try stateStore.hasPendingCancellation())
        XCTAssertEqual(try stateStore.loadOrCreateInstallationID(), syntheticInstallationID)
    }

    func testPairingStateStoreRejectsImplicitReplacementByDifferentInvitation() throws {
        let pendingStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let firstInvitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        let secondInvitation = try ReceiverPairingInvitation(
            jsonData: Data(
                validInvitationJSON.replacingOccurrences(
                    of: "hbi_synthetic_secret",
                    with: "hbi_different_synthetic_secret"
                ).utf8
            )
        )
        let firstPending = try stateStore.stage(invitation: firstInvitation)

        XCTAssertThrowsError(try stateStore.stage(invitation: secondInvitation)) { error in
            XCTAssertEqual(error as? ReceiverPairingStateError, .pendingPairingConflict)
        }
        XCTAssertEqual(try stateStore.loadPending(), firstPending)
    }

    @MainActor
    func testPairingCoordinatorMatchesOnlyExactPendingInvitation() throws {
        let stateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingCoordinatorPendingMatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: ReceiverSettingsStore(
                userDefaults: defaults,
                tokenStore: MemoryReceiverTokenStore()
            )
        )
        let firstInvitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        let secondInvitation = try ReceiverPairingInvitation(
            jsonData: Data(
                validInvitationJSON.replacingOccurrences(
                    of: "hbi_synthetic_secret",
                    with: "hbi_different_synthetic_secret"
                ).utf8
            )
        )

        XCTAssertFalse(try coordinator.pendingPairingMatches(firstInvitation))
        _ = try stateStore.stage(invitation: firstInvitation)
        XCTAssertTrue(try coordinator.pendingPairingMatches(firstInvitation))
        XCTAssertFalse(try coordinator.pendingPairingMatches(secondInvitation))
    }

    @MainActor
    func testPairingCoordinatorRecoversSamePendingCredentialAfterResponseLoss() async throws {
        let pendingStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeStore = MemoryReceiverTokenStore()
        let settingsStore = ReceiverSettingsStore(userDefaults: defaults, tokenStore: activeStore)
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        MockURLProtocol.requestHandler = { _ in throw URLError(.networkConnectionLost) }

        do {
            _ = try await coordinator.pair(invitation: invitation)
            XCTFail("Expected response loss")
        } catch {}

        let pendingAfterLoss = try XCTUnwrap(stateStore.loadPending())
        XCTAssertEqual(pendingAfterLoss.deviceCredential, syntheticDeviceCredential)
        XCTAssertEqual(try settingsStore.loadBearerToken(), "old-synthetic-token")
        XCTAssertEqual(settingsStore.receiverURLString, "https://old.example/v1/batches")
        XCTAssertEqual(settingsStore.receiverSettingsGeneration, 1)

        MockURLProtocol.requestHandler = { request in pairingCompletionResponse(for: request) }
        let recovered = try await coordinator.resumePendingPairing()

        XCTAssertEqual(recovered?.bearerToken, syntheticDeviceCredential)
        XCTAssertNil(try stateStore.loadPending())
        XCTAssertEqual(try settingsStore.loadBearerToken(), syntheticDeviceCredential)
        XCTAssertEqual(settingsStore.receiverURLString, invitation.receiverURLString)
        XCTAssertEqual(settingsStore.receiverSettingsGeneration, 2)
    }

    @MainActor
    func testPairingCoordinatorReusesPendingTupleWhenSameInvitationIsTappedAfterResponseLoss() async throws {
        let pendingStore = MemoryReceiverTokenStore()
        var generatedCredentials = [syntheticDeviceCredential, secondSyntheticDeviceCredential]
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { generatedCredentials.removeFirst() }
        )
        let suiteName = "PairingRetapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore()
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        var submittedCredentials: [String] = []
        var shouldLoseResponse = true
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(request.httpBodyStream?.readAllData())
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            submittedCredentials.append(try XCTUnwrap(payload["device_credential"]))
            if shouldLoseResponse {
                shouldLoseResponse = false
                throw URLError(.networkConnectionLost)
            }
            return pairingCompletionResponse(for: request)
        }

        do {
            _ = try await coordinator.pair(invitation: invitation)
            XCTFail("Expected response loss")
        } catch {}
        let recovered = try await coordinator.pair(invitation: invitation)

        XCTAssertEqual(
            submittedCredentials,
            [syntheticDeviceCredential, syntheticDeviceCredential]
        )
        XCTAssertEqual(generatedCredentials, [secondSyntheticDeviceCredential])
        XCTAssertEqual(recovered.bearerToken, syntheticDeviceCredential)
        XCTAssertNil(try stateStore.loadPending())
    }

    @MainActor
    func testPairingCoordinatorPreservesPendingAfterAmbiguousClientError() async throws {
        let pendingStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingAmbiguousErrorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeStore = MemoryReceiverTokenStore()
        let settingsStore = ReceiverSettingsStore(userDefaults: defaults, tokenStore: activeStore)
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocolResponse(
                response: HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 408,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body: Data(#"{"error":"proxy_timeout"}"#.utf8)
            )
        }

        do {
            _ = try await coordinator.pair(invitation: invitation)
            XCTFail("Expected ambiguous pairing failure")
        } catch let error as ReceiverPairingRedeemError {
            XCTAssertEqual(error, .unsuccessfulStatusCode(408))
        }

        XCTAssertNotNil(try stateStore.loadPending())
        XCTAssertEqual(settingsStore.receiverURLString, "https://old.example/v1/batches")
        XCTAssertEqual(try settingsStore.loadBearerToken(), "old-synthetic-token")
    }

    @MainActor
    func testDelayedPairingCompletionCannotRestoreSettingsAfterDisconnect() async throws {
        let stateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingDisconnectBarrierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore()
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        let requestStarted = expectation(description: "pairing request started")
        let responseGate = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            requestStarted.fulfill()
            _ = responseGate.wait(timeout: .now() + 2)
            return pairingCompletionResponse(for: request)
        }

        let pairingTask = Task {
            try await coordinator.pair(invitation: invitation)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        try coordinator.cancelPendingPairing()
        responseGate.signal()
        _ = try? await pairingTask.value

        XCTAssertEqual(
            settingsStore.receiverURLString,
            ReceiverSettingsStore.defaultReceiverURLString
        )
        XCTAssertEqual(try settingsStore.loadBearerToken(), "")
        XCTAssertNil(try stateStore.loadPending())
    }

    @MainActor
    func testPairingCoordinatorCancellationPreventsLatePromotion() async throws {
        let pendingStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingCancellationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeStore = MemoryReceiverTokenStore()
        let settingsStore = ReceiverSettingsStore(userDefaults: defaults, tokenStore: activeStore)
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        let requestStarted = expectation(description: "pairing request started")
        MockURLProtocol.requestHandler = { request in
            requestStarted.fulfill()
            Thread.sleep(forTimeInterval: 0.15)
            return pairingCompletionResponse(for: request)
        }

        let task = Task {
            try await coordinator.pair(invitation: invitation)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected pairing cancellation")
        } catch is CancellationError {
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }

        XCTAssertNotNil(try stateStore.loadPending())
        XCTAssertEqual(settingsStore.receiverURLString, "https://old.example/v1/batches")
        XCTAssertEqual(try settingsStore.loadBearerToken(), "old-synthetic-token")
    }

    @MainActor
    func testPairingCoordinatorCompletesCancellationWhenKeychainMarkerWriteFails() throws {
        let cancellationStore = ToggleFailingReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: cancellationStore,
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingMarkerFallbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore()
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        _ = try stateStore.stage(invitation: invitation)
        cancellationStore.shouldFail = true

        try coordinator.cancelPendingPairing()

        XCTAssertNil(try stateStore.loadPending())
        XCTAssertEqual(
            settingsStore.receiverURLString,
            ReceiverSettingsStore.defaultReceiverURLString
        )
        XCTAssertEqual(try settingsStore.loadBearerToken(), "")
        XCTAssertNil(settingsStore.terminalCancellationExpectedGeneration)
    }

    @MainActor
    func testPairingCoordinatorReportsCommittedCancellationWhenPendingCleanupFails() throws {
        let pendingStore = ToggleFailingReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingCommittedCleanupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore()
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(
            jsonData: Data(validInvitationJSON.utf8)
        )
        _ = try stateStore.stage(invitation: invitation)
        pendingStore.shouldFail = true

        let outcome = try coordinator.cancelPendingPairing()

        XCTAssertEqual(outcome, .committedCleanupPending)
        XCTAssertTrue(try stateStore.hasPendingCancellation())
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertEqual(try settingsStore.loadBearerToken(), "")
    }

    @MainActor
    func testPairingCoordinatorReportsCommittedCancellationWhenFinalIntentCleanupIsNotDurable() throws {
        let stateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingFinalIntentCleanupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var synchronizationCount = 0
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore(),
            synchronize: {
                synchronizationCount += 1
                return synchronizationCount < 2
            }
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )

        let outcome = try coordinator.cancelPendingPairing()

        XCTAssertEqual(outcome, .committedCleanupPending)
        XCTAssertTrue(try settingsStore.receiverSettingsAreCleared())
        XCTAssertTrue(try coordinator.hasPendingCancellationRecovery())
    }

    @MainActor
    func testPairingCoordinatorCompletesDurableCancellationAfterClearFailure() async throws {
        let pendingStore = MemoryReceiverTokenStore()
        let cancellationStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: cancellationStore,
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingDurableCancelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeStore = ToggleFailingReceiverTokenStore()
        let settingsStore = ReceiverSettingsStore(userDefaults: defaults, tokenStore: activeStore)
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        _ = try stateStore.stage(invitation: invitation)
        activeStore.shouldFail = true

        XCTAssertThrowsError(try coordinator.cancelPendingPairing())
        XCTAssertTrue(try stateStore.hasPendingCancellation())
        XCTAssertNotNil(try stateStore.loadPending())
        XCTAssertEqual(settingsStore.receiverURLString, "https://old.example/v1/batches")
        activeStore.shouldFail = false
        XCTAssertEqual(try settingsStore.loadBearerToken(), "old-synthetic-token")

        let recoveryBarrier = ReceiverConnectionTerminalBarrier()
        var recoveryEvents: [String] = []
        let recovered = try await recoveryBarrier.perform(
            closeAdmission: { recoveryEvents.append("close") },
            invalidateGeneration: {
                recoveryEvents.append("preserve-generation")
                return settingsStore.receiverSettingsGenerationToken
            },
            cancelAndAwaitPairing: { recoveryEvents.append("pairing") },
            cancelAndAwaitForegroundPayloads: { recoveryEvents.append("foreground") },
            drainBackgroundPayloads: {
                recoveryEvents.append("background")
                return true
            },
            commit: { expectedGeneration in
                recoveryEvents.append("recover")
                return try await coordinator.resumePendingPairing(
                    expectedGeneration: expectedGeneration
                )
            }
        )

        XCTAssertNil(recovered)
        XCTAssertEqual(
            recoveryEvents,
            [
                "close",
                "preserve-generation",
                "pairing",
                "foreground",
                "background",
                "recover",
            ]
        )
        XCTAssertFalse(try stateStore.hasPendingCancellation())
        XCTAssertNil(try stateStore.loadPending())
        XCTAssertEqual(
            settingsStore.receiverURLString,
            ReceiverSettingsStore.defaultReceiverURLString
        )
        XCTAssertEqual(try settingsStore.loadBearerToken(), "")
    }

    @MainActor
    func testDurableCancellationMarkerCannotClearLaterConnection() async throws {
        let stateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingBoundCancelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeStore = ToggleFailingReceiverTokenStore()
        let settingsStore = ReceiverSettingsStore(userDefaults: defaults, tokenStore: activeStore)
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        activeStore.shouldFail = true
        XCTAssertThrowsError(try coordinator.cancelPendingPairing())
        XCTAssertTrue(try stateStore.hasPendingCancellation())

        activeStore.shouldFail = false
        try settingsStore.save(
            receiverURLString: "https://new.example/v1/batches",
            bearerToken: "new-synthetic-token"
        )
        let recovered = try await coordinator.resumePendingPairing()

        XCTAssertNil(recovered)
        XCTAssertFalse(try stateStore.hasPendingCancellation())
        XCTAssertEqual(settingsStore.receiverURLString, "https://new.example/v1/batches")
        XCTAssertEqual(try settingsStore.loadBearerToken(), "new-synthetic-token")
    }

    @MainActor
    func testLegacyCancellationMarkerRequiresExplicitRetryWithoutClearingCurrentConnection() async throws {
        let cancellationStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: cancellationStore
        )
        let suiteName = "PairingLegacyCancelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore()
        )
        try settingsStore.save(
            receiverURLString: "https://current.example/v1/batches",
            bearerToken: "current-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        try cancellationStore.saveToken("cancel-requested")

        do {
            _ = try await coordinator.resumePendingPairing()
            XCTFail("Expected an unbound legacy cancellation marker to remain fail-closed")
        } catch let error as ReceiverPairingStateError {
            XCTAssertEqual(error, .legacyCancellationRequiresRetry)
        }

        XCTAssertTrue(try stateStore.hasPendingCancellation())
        XCTAssertEqual(settingsStore.receiverURLString, "https://current.example/v1/batches")
        XCTAssertEqual(try settingsStore.loadBearerToken(), "current-synthetic-token")

        try coordinator.cancelPendingPairing(
            expectedGeneration: settingsStore.receiverSettingsGenerationToken
        )
        XCTAssertFalse(try stateStore.hasPendingCancellation())
        XCTAssertEqual(try settingsStore.loadBearerToken(), "")
    }

    @MainActor
    func testStaleCancellationDoesNotPoisonNewerConnection() async throws {
        let cancellationStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: MemoryReceiverTokenStore(),
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: cancellationStore,
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingStaleCancelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: MemoryReceiverTokenStore()
        )
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        let staleGeneration = settingsStore.receiverSettingsGenerationToken
        try settingsStore.save(
            receiverURLString: "https://new.example/v1/batches",
            bearerToken: "new-synthetic-token"
        )
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )

        XCTAssertThrowsError(
            try coordinator.cancelPendingPairing(expectedGeneration: staleGeneration)
        ) { error in
            XCTAssertEqual(error as? ReceiverSettingsGenerationError, .staleGeneration)
        }
        XCTAssertFalse(try stateStore.hasPendingCancellation())

        let recovered = try await coordinator.resumePendingPairing()
        XCTAssertNil(recovered)
        XCTAssertEqual(settingsStore.receiverURLString, "https://new.example/v1/batches")
        XCTAssertEqual(try settingsStore.loadBearerToken(), "new-synthetic-token")
    }

    @MainActor
    func testPairingCoordinatorPreservesPendingAndActiveConnectionWhenPromotionFails() async throws {
        let pendingStore = MemoryReceiverTokenStore()
        let stateStore = ReceiverPairingStateStore(
            pendingStore: pendingStore,
            installationIDStore: MemoryReceiverTokenStore(),
            cancellationStore: MemoryReceiverTokenStore(),
            installationIDGenerator: { syntheticInstallationID },
            deviceCredentialGenerator: { syntheticDeviceCredential }
        )
        let suiteName = "PairingPromotionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeStore = ToggleFailingReceiverTokenStore()
        let settingsStore = ReceiverSettingsStore(userDefaults: defaults, tokenStore: activeStore)
        try settingsStore.save(
            receiverURLString: "https://old.example/v1/batches",
            bearerToken: "old-synthetic-token"
        )
        activeStore.shouldFail = true
        let coordinator = ReceiverPairingCoordinator(
            client: makeClient(),
            stateStore: stateStore,
            settingsStore: settingsStore
        )
        let invitation = try ReceiverPairingInvitation(jsonData: Data(validInvitationJSON.utf8))
        MockURLProtocol.requestHandler = { request in pairingCompletionResponse(for: request) }

        do {
            _ = try await coordinator.pair(invitation: invitation)
            XCTFail("Expected active Keychain promotion failure")
        } catch {}

        XCTAssertNotNil(try stateStore.loadPending())
        XCTAssertEqual(settingsStore.receiverURLString, "https://old.example/v1/batches")
        activeStore.shouldFail = false
        XCTAssertEqual(try settingsStore.loadBearerToken(), "old-synthetic-token")
        XCTAssertEqual(settingsStore.receiverSettingsGeneration, 1)

        _ = try await coordinator.resumePendingPairing()
        XCTAssertNil(try stateStore.loadPending())
        XCTAssertEqual(try settingsStore.loadBearerToken(), syntheticDeviceCredential)
        XCTAssertEqual(settingsStore.receiverSettingsGeneration, 2)
    }

    private func makeClient() -> ReceiverClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return ReceiverClient(session: URLSession(configuration: configuration))
    }
}

private let validInvitationJSON = """
{
  "schema_id": "health_bridge.receiver_pairing_invitation.v2",
  "schema_version": "2.0.0",
  "label": "maintainer-iphone",
  "receiver_url": "https://health-bridge.example.test/v1/batches",
  "redeem_url": "https://health-bridge.example.test/v1/pairing/redeem",
  "invitation_secret": "hbi_synthetic_secret",
  "expires_at": "2026-07-12T09:00:00Z"
}
"""

private let syntheticInstallationID = "00000000-0000-4000-8000-000000000001"
private let syntheticDeviceCredential = "hb_" + String(repeating: "a", count: 64)
private let secondSyntheticDeviceCredential = "hb_" + String(repeating: "b", count: 64)

private func syntheticPendingPairing(invitation: ReceiverPairingInvitation) -> ReceiverPendingPairing {
    ReceiverPendingPairing(
        label: invitation.label,
        receiverURLString: invitation.receiverURLString,
        redeemURLString: invitation.redeemURLString,
        invitationSecret: invitation.invitationSecret,
        invitationCode: nil,
        installationID: syntheticInstallationID,
        deviceCredential: syntheticDeviceCredential,
        platform: "ios"
    )
}

private func syntheticPendingPairing(manualPairing: ReceiverManualPairing) -> ReceiverPendingPairing {
    ReceiverPendingPairing(
        label: "iOS companion",
        receiverURLString: manualPairing.receiverURL.absoluteString,
        redeemURLString: manualPairing.redeemURL.absoluteString,
        invitationSecret: nil,
        invitationCode: manualPairing.invitationCode,
        installationID: syntheticInstallationID,
        deviceCredential: syntheticDeviceCredential,
        platform: "ios"
    )
}

private func pairingCompletionResponse(
    for request: URLRequest,
    receiverURL: String = "https://health-bridge.example.test/v1/batches"
) -> MockURLProtocolResponse {
    let body = """
    {
      "schema_id": "health_bridge.receiver_pairing_completion.v1",
      "schema_version": "1.0.0",
      "label": "maintainer-iphone",
      "receiver_url": "\(receiverURL)"
    }
    """
    return MockURLProtocolResponse(
        response: HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!,
        body: Data(body.utf8)
    )
}

private struct MockURLProtocolResponse {
    let response: HTTPURLResponse
    let body: Data
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> MockURLProtocolResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handled = try XCTUnwrap(Self.requestHandler)(request)
            client?.urlProtocol(self, didReceive: handled.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: handled.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum SyntheticPairingStoreError: Error {
    case saveFailed
}

private final class MemoryReceiverTokenStore: ReceiverTokenStoring {
    var token = ""

    func loadToken() throws -> String { token }
    func saveToken(_ token: String) throws { self.token = token }
}

private final class ToggleFailingReceiverTokenStore: ReceiverTokenStoring {
    var shouldFail = false
    private var token = ""

    func loadToken() throws -> String { token }

    func saveToken(_ token: String) throws {
        if shouldFail { throw SyntheticPairingStoreError.saveFailed }
        self.token = token
    }
}

private extension InputStream {
    func readAllData() -> Data {
        open()
        defer { close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

import XCTest
@testable import HealthBridgeCompanionCore

final class ReceiverPairingTests: XCTestCase {
    func testDecodesReceiverPairingBundleJSON() throws {
        let bundle = try ReceiverPairingBundle(jsonData: Data(validPairingJSON.utf8))

        XCTAssertEqual(bundle.schemaID, "health_bridge.receiver_pairing.v1")
        XCTAssertEqual(bundle.schemaVersion, "1.0.0")
        XCTAssertEqual(bundle.label, "maintainer-iphone")
        XCTAssertEqual(bundle.receiverURLString, "https://health-bridge.example.test/v1/batches")
        XCTAssertEqual(bundle.bearerToken, "hb_pairing_secret")
        XCTAssertEqual(bundle.tokenPrefix, "hb_pairing_")
        XCTAssertEqual(bundle.createdAt, "2026-06-10T09:00:00Z")
        XCTAssertEqual(bundle.receiverURL?.scheme, "https")
    }

    func testDecodesHealthBridgeDeepLinkPayload() throws {
        let deepLink = makeDeepLink(for: validPairingJSON)

        let bundle = try ReceiverPairingBundle(deepLink: deepLink)

        XCTAssertEqual(bundle.receiverURLString, "https://health-bridge.example.test/v1/batches")
        XCTAssertEqual(bundle.bearerToken, "hb_pairing_secret")
    }

    func testRejectsUnsupportedPairingSchema() throws {
        let invalidJSON = validPairingJSON.replacingOccurrences(
            of: "health_bridge.receiver_pairing.v1",
            with: "health_bridge.batch.v1"
        )

        XCTAssertThrowsError(try ReceiverPairingBundle(jsonData: Data(invalidJSON.utf8))) { error in
            XCTAssertEqual(error as? ReceiverPairingBundleError, .unsupportedSchema)
        }
    }

    func testRejectsNonHTTPReceiverURL() throws {
        let invalidJSON = validPairingJSON.replacingOccurrences(
            of: "https://health-bridge.example.test/v1/batches",
            with: "file:///tmp/receiver"
        )

        XCTAssertThrowsError(try ReceiverPairingBundle(jsonData: Data(invalidJSON.utf8))) { error in
            XCTAssertEqual(error as? ReceiverPairingBundleError, .invalidReceiverURL)
        }
    }

    func testDecodesV2InvitationFromCustomDeepLink() throws {
        let deepLink = makeDeepLink(for: validInvitationJSON)

        let material = try ReceiverPairingMaterial(deepLink: deepLink)

        guard case .invitation(let invitation) = material else {
            return XCTFail("Expected invitation material")
        }
        XCTAssertEqual(invitation.schemaID, "health_bridge.receiver_pairing_invitation.v2")
        XCTAssertEqual(invitation.receiverURLString, "https://health-bridge.example.test/v1/batches")
        XCTAssertEqual(invitation.redeemURLString, "https://health-bridge.example.test/v1/pairing/redeem")
        XCTAssertEqual(invitation.invitationSecret, "hbi_synthetic_secret")
        XCTAssertEqual(invitation.expiresAt, "2026-07-12T09:00:00Z")
    }

    func testDecodesV2InvitationFromFutureHTTPSPairLink() throws {
        let deepLink = makeDeepLink(
            for: validInvitationJSON,
            baseURL: "https://pair.example.test/pair"
        )

        let material = try ReceiverPairingMaterial(deepLink: deepLink)

        guard case .invitation(let invitation) = material else {
            return XCTFail("Expected invitation material")
        }
        XCTAssertEqual(invitation.invitationSecret, "hbi_synthetic_secret")
    }

    func testMaterialDecoderKeepsLegacyV1Compatibility() throws {
        let material = try ReceiverPairingMaterial.decode(validPairingJSON)

        guard case .legacy(let bundle) = material else {
            return XCTFail("Expected legacy material")
        }
        XCTAssertEqual(bundle.bearerToken, "hb_pairing_secret")
    }

    func testV2InvitationRejectsCrossOriginRedeemURL() throws {
        let invalidJSON = validInvitationJSON.replacingOccurrences(
            of: "https://health-bridge.example.test/v1/pairing/redeem",
            with: "https://attacker.example/v1/pairing/redeem"
        )

        XCTAssertThrowsError(try ReceiverPairingMaterial.decode(invalidJSON)) { error in
            XCTAssertEqual(error as? ReceiverPairingBundleError, .crossOriginRedeemURL)
        }
    }

    func testManualPairingNormalizesCodeAndDerivesReceiverEndpoints() throws {
        let manual = try ReceiverManualPairing(
            serverURLString: "https://health-bridge.example.test",
            invitationCode: " abcde fghjk mnpqr "
        )

        XCTAssertEqual(manual.invitationCode, "ABCDE-FGHJK-MNPQR")
        XCTAssertEqual(manual.receiverURL.absoluteString, "https://health-bridge.example.test/v1/batches")
        XCTAssertEqual(manual.redeemURL.absoluteString, "https://health-bridge.example.test/v1/pairing/redeem")
    }

    func testIncomingPairingPolicyImportsWhenNothingIsPending() {
        XCTAssertEqual(
            ReceiverIncomingPairingPolicy.decision(
                hasPendingPairing: false,
                matchesPendingInvitation: false
            ),
            .importIncoming
        )
    }

    func testIncomingPairingPolicyResumesOnlyTheMatchingPendingInvitation() {
        XCTAssertEqual(
            ReceiverIncomingPairingPolicy.decision(
                hasPendingPairing: true,
                matchesPendingInvitation: true
            ),
            .resumeMatchingPending
        )
    }

    func testIncomingPairingPolicyRejectsDifferentInvitationWithoutRetryingPending() {
        XCTAssertEqual(
            ReceiverIncomingPairingPolicy.decision(
                hasPendingPairing: true,
                matchesPendingInvitation: false
            ),
            .rejectDifferentPending
        )
    }
}

private let validPairingJSON = """
{
  "schema_id": "health_bridge.receiver_pairing.v1",
  "schema_version": "1.0.0",
  "label": "maintainer-iphone",
  "receiver_url": "https://health-bridge.example.test/v1/batches",
  "bearer_token": "hb_pairing_secret",
  "token_prefix": "hb_pairing_",
  "created_at": "2026-06-10T09:00:00Z",
  "warning": "This pairing bundle contains a receiver bearer-token secret."
}
"""

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

private func makeDeepLink(
    for json: String,
    baseURL: String = "healthbridge://pair"
) -> URL {
    let base64 = Data(json.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return URL(string: "\(baseURL)?payload=\(base64)")!
}

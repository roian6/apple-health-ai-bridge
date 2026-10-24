import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class NativeMailboxInvitationTests: XCTestCase {
    func testURLFreeNativeInvitationDecodesJSONAndCustomDeepLink() throws {
        let material = try ReceiverPairingMaterial.decode(nativeInvitationJSON)
        guard case .invitation(let invitation) = material else {
            return XCTFail("Expected native invitation material")
        }
        XCTAssertEqual(invitation.schemaID, "health_bridge.receiver_pairing_invitation.v2")
        XCTAssertEqual(invitation.schemaVersion, "2.0.0")
        XCTAssertEqual(invitation.label, "synthetic-native-iphone")
        XCTAssertEqual(invitation.transport, .mailbox)
        XCTAssertEqual(invitation.mailboxProtocolVersion, 1)
        XCTAssertEqual(invitation.invitationSecret, "hbi_synthetic_native_invitation")
        XCTAssertEqual(invitation.expiresAt, "2030-01-01T00:00:00Z")

        let payload = Data(nativeInvitationJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let link = try XCTUnwrap(URL(string: "healthbridge://pair?payload=\(payload)"))
        XCTAssertEqual(try ReceiverPairingMaterial(deepLink: link), material)
    }

    func testExistingDirectAndURLBearingMailboxInvitationsStillDecode() throws {
        for transport in ["direct", "mailbox"] {
            var object = try nativeInvitationObject()
            object.removeValue(forKey: "mailbox_bootstrap")
            object["receiver_url"] = "https://synthetic.example/v1/batches"
            object["redeem_url"] = "https://synthetic.example/v1/pairing/redeem"
            object["transport"] = transport
            if transport == "direct" {
                object.removeValue(forKey: "mailbox_protocol_version")
            }
            let invitation = try ReceiverPairingInvitation(
                jsonData: JSONSerialization.data(withJSONObject: object)
            )
            XCTAssertEqual(invitation.receiverURLString, "https://synthetic.example/v1/batches")
            XCTAssertEqual(invitation.redeemURLString, "https://synthetic.example/v1/pairing/redeem")
            XCTAssertEqual(invitation.transport, transport == "direct" ? .direct : .mailbox)
            XCTAssertEqual(invitation.mailboxProtocolVersion, transport == "direct" ? nil : 1)
        }
    }

    func testNativeInvitationRejectsAmbiguousHTTPRedemption() throws {
        var object = try nativeInvitationObject()
        object["receiver_url"] = "https://synthetic.example/v1/batches"
        object["redeem_url"] = "https://synthetic.example/v1/pairing/redeem"
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try ReceiverPairingMaterial(jsonData: data),
            "A native descriptor must not silently fall back to HTTP redemption.")
    }

    func testNativeInvitationRejectsMalformedBootstrapTrust() throws {
        let original = try nativeInvitationObject()
        let descriptor = try XCTUnwrap(original["mailbox_bootstrap"] as? [String: Any])
        for field in ["invitation_id", "receiver_signing_public_key", "receiver_agreement_public_key"] {
            var invalid = descriptor
            invalid[field] = "invalid"
            var object = original
            object["mailbox_bootstrap"] = invalid
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try ReceiverPairingMaterial(jsonData: data), field)
        }
    }

    func testURLFreeInvitationRequiresBootstrapAndExplicitMailboxV1() throws {
        for field in ["mailbox_bootstrap", "transport", "mailbox_protocol_version"] {
            var object = try nativeInvitationObject()
            object.removeValue(forKey: field)
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try ReceiverPairingMaterial(jsonData: data), field)
        }
    }
}

private func nativeInvitationObject() throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(nativeInvitationJSON.utf8)) as? [String: Any])
}

// ReceiverPairingInvitationPayload + BootstrapDescriptor wire shape. These are
// synthetic public bytes, not a captured invitation or an authenticated exchange.
private let nativeInvitationJSON = """
{
  "schema_id": "health_bridge.receiver_pairing_invitation.v2",
  "schema_version": "2.0.0",
  "label": "synthetic-native-iphone",
  "receiver_url": null,
  "redeem_url": null,
  "mailbox_bootstrap": {
    "version": 1,
    "invitation_id": "00112233445566778899aabbccddeeff",
    "receiver_signing_public_key": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
    "receiver_agreement_public_key": "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
  },
  "invitation_secret": "hbi_synthetic_native_invitation",
  "expires_at": "2030-01-01T00:00:00Z",
  "transport": "mailbox",
  "mailbox_protocol_version": 1
}
"""

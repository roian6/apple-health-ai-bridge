from pathlib import Path

PAIRING_SOURCE = Path(
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ReceiverPairing.swift"
)
CLIENT_SOURCE = Path(
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ReceiverClient.swift"
)
SETTINGS_SOURCE = Path(
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/FileOutbox.swift"
)
CONTENT_VIEW = Path("ios/HealthBridgeCompanion/App/ContentView.swift")


def test_ios_invitation_requires_explicit_mailbox_transport_intent() -> None:
    pairing = PAIRING_SOURCE.read_text(encoding="utf-8")

    assert "public enum ReceiverPairingTransport: String, Codable" in pairing
    assert "public let transport: ReceiverPairingTransport" in pairing
    assert "case direct" in pairing
    assert "case mailbox" in pairing
    assert "case (.some(.direct), nil), (nil, nil):" in pairing
    assert "case (.some(.mailbox), 1):" in pairing
    assert "throw ReceiverPairingBundleError.unsupportedTransport" in pairing


def test_ios_pairing_stages_validated_transport_intent_before_capability_use() -> None:
    client = CLIENT_SOURCE.read_text(encoding="utf-8")
    settings = SETTINGS_SOURCE.read_text(encoding="utf-8")

    assert "transport: invitation.transport" in settings
    assert "public let transport: ReceiverPairingTransport" in settings
    assert "case (.some(.direct), nil), (nil, nil):" in settings
    assert "case (.some(.mailbox), nil), (.some(.mailbox), 1):" in settings
    assert "(nil, 1)" not in settings
    assert "try container.encode(transport, forKey: .transport)" in settings
    assert "try container.encode(1, forKey: .mailboxProtocolVersion)" in settings
    assert "if pending.transport == .mailbox" in client
    assert "switch (pendingPairing.transport, mailboxPublicIdentity)" in client
    assert "pendingPairing.mailboxProtocolVersion" not in client
    assert "invitation.mailboxProtocolVersion" not in client


def test_ios_setup_explains_transport_choices_without_instant_sync_claims() -> None:
    content = CONTENT_VIEW.read_text(encoding="utf-8")

    for required in (
        "Direct / Tailscale-compatible",
        "Encrypted iCloud Mailbox (Beta)",
        "No VPN required",
        "Mac only",
        "Best-effort, eventual delivery",
        "Custom HTTPS",
        "Advanced / Limited",
    ):
        assert required in content
    assert "instant sync" not in content.lower()


def test_existing_ios_connection_records_keep_explicit_transport_activation() -> None:
    settings = SETTINGS_SOURCE.read_text(encoding="utf-8")

    assert "case directHTTP" in settings
    assert "case mailbox" in settings
    assert "activation: .paired(activeTransport: .directHTTP)" in settings
    assert "activation: .paired(activeTransport: .mailbox)" in settings

from pathlib import Path

QA_ROOT = Path("ios/HealthBridgeCompanion/MailboxQA")
RUNTIME = Path("src/health_bridge/mailbox_qa/qa_runtime.py")
CONTRACT = Path("src/health_bridge/mailbox_qa/qa_pairing_contract.py")


def test_qa_pairing_provisions_both_key_families_without_production_store() -> None:
    # Given: the QA-only app pairing client and ephemeral receiver endpoint.
    client = (QA_ROOT / "MailboxQAInvocation.swift").read_text(encoding="utf-8")
    receiver = RUNTIME.read_text(encoding="utf-8") + CONTRACT.read_text(
        encoding="utf-8"
    )

    # When: pairing request, completion, and persistence fields are inspected.
    # Then: both sides bind signing/agreement keys and only QA namespaces.
    for required in (
        "deviceSigningPublicKey",
        "deviceAgreementPublicKey",
        "receiverSigningPublicKey",
        "receiverAgreementPublicKey",
        "receiverBindingID",
        "connectionGeneration",
        "configuration.keychainService",
    ):
        assert required in client
    for required in (
        "MailboxKeyStore.for_testing",
        "MailboxConnectionStore.for_testing",
        "device_signing_public_key",
        "device_agreement_public_key",
        "receiver_signing_public_key",
        "receiver_agreement_public_key",
        "receiver_binding_id",
        "connection_generation",
    ):
        assert required in receiver
    assert "ReceiverSettingsStore" not in client
    assert "MailboxConnectionStore.production" not in receiver
    assert "server.mailbox_root / receiver_id.hex()" not in receiver
    assert "(mailbox_path / lane).mkdir" not in receiver
    assert '"hb_" + base64URL' in client
    assert "isPrivateReceiverHost" in client
    assert "invitationCode" not in client


def test_qa_pairing_is_immutable_and_harness_actions_are_ordered() -> None:
    # Given: the private QA invocation and harness sources.
    invocation = (QA_ROOT / "MailboxQAInvocation.swift").read_text(encoding="utf-8")
    core = Path("ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore")
    harness = (core / "MailboxQAHarness.swift").read_text(encoding="utf-8")
    models = (core / "MailboxQAModels.swift").read_text(encoding="utf-8")

    # When / Then: only explicit cleanup deletes state and actions are machine-owned.
    assert invocation.count("SecItemDelete") == 1
    assert "case .cleanup" in invocation
    assert "errSecDuplicateItem" in invocation
    assert "existingPairingMismatch" in invocation
    for action in ("pair", "advance", "scan_finalize", "signed_report", "cleanup"):
        assert action in models
    assert "generic_pass" not in (invocation + harness).lower()
    assert "checks" not in invocation
    assert "MailboxQASyntheticPayload.exactBytes" in harness

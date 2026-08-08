from __future__ import annotations

import sys
from pathlib import Path

import pytest
from pydantic import ValidationError

from health_bridge.mailbox_qa.production_seal import (
    load_production_identity_seal,
    production_seal_fingerprint,
)
from health_bridge.mailbox_qa.qa_pairing_contract import (
    QAPairingRedeemRequest,
    base64url,
)
from health_bridge.mailbox_qa.qa_runtime import (
    QAReceiverHTTPServer,
    QAReceiverRuntime,
    provision_qa_mailbox,
)
from health_bridge.mailbox_qa.receiver import QAReceiverConfig
from tests.scripts.production_seal_support import (
    synthetic_qa_request,
    write_synthetic_production_seal,
)

PUBLIC_QA_PROJECT_BUNDLE = "com.example.HealthBridgeCompanion.publicdocuments.mailboxqa"
PUBLIC_QA_BUNDLE_SUFFIX = ".publicdocuments.mailboxqa"


def _base_config(runtime: Path) -> QAReceiverConfig:
    seal_path = runtime.parent / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(seal_path)
    seal = load_production_identity_seal(seal_path, anchor)
    qa = synthetic_qa_request(runtime)
    return QAReceiverConfig(
        runtime_root=runtime,
        host="127.0.0.1",
        port=qa.receiver_port,
        namespace="qa-run-001",
        bundle_identifier=qa.bundle_identifier,
        container_identifier=qa.container_identifier,
        url_scheme=qa.url_scheme,
        keychain_service=qa.keychain_service,
        keychain_access_groups=qa.keychain_access_groups,
        outbox_root=qa.outbox_root,
        display_identity=qa.display_identity,
        database_namespace=qa.database_namespace,
        app_path=qa.app_path,
        production_seal=seal,
        production_seal_fingerprint=production_seal_fingerprint(seal),
    )


def test_public_documents_receiver_root_is_exact_confined_and_app_owned(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given: the exact public-documents target identity and Darwin provider root.
    host_platform = sys.platform
    project = Path(
        "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
    ).read_text(encoding="utf-8")
    assert f"PRODUCT_BUNDLE_IDENTIFIER = {PUBLIC_QA_PROJECT_BUNDLE};" in project
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    base_config = _base_config(runtime)
    bundle = f"{base_config.production_seal.bundle_identifier}{PUBLIC_QA_BUNDLE_SUFFIX}"
    container = f"iCloud.{bundle}"
    expected = (
        tmp_path
        / "Library/Mobile Documents"
        / container.replace(".", "~")
        / "Documents/HealthBridgeMailbox/v1"
    )
    values = base_config.model_dump()
    values.update(
        {
            "bundle_identifier": bundle,
            "container_identifier": container,
            "url_scheme": "healthbridgeqa-public-documents",
            "keychain_service": f"{bundle}.mailboxqa",
            "keychain_access_groups": (f"TEAM.{bundle}",),
            "outbox_root": "HealthBridgeMailboxPublicDocumentsQA",
            "display_identity": "Synthetic Health Bridge Mailbox Public Documents QA",
            "database_namespace": "qa-public-documents",
            "app_path": runtime / "HealthBridgeCompanionPublicDocumentsQA.app",
            "mailbox_root_override": expected,
        }
    )
    monkeypatch.setattr(
        "health_bridge.mailbox_qa.receiver.sys.platform",
        "darwin",
    )
    monkeypatch.setattr(
        "health_bridge.mailbox_qa.receiver.pathlib.Path.home",
        lambda: tmp_path,
    )

    # When: the existing receiver configuration parses the explicit public root.
    config = QAReceiverConfig.model_validate(values)
    monkeypatch.setattr(
        "health_bridge.mailbox_qa.receiver.sys.platform",
        host_platform,
    )

    # Then: the configured root is exact and pairing provisions only private state.
    assert config.mailbox_root == expected
    assert not expected.exists()
    server = QAReceiverHTTPServer(
        "127.0.0.1",
        0,
        QAReceiverRuntime(
            db_path=config.database_path,
            runtime_root=config.runtime_root,
            mailbox_root=config.mailbox_root,
            namespace=config.namespace,
        ),
    )
    request = QAPairingRedeemRequest(
        invitation_secret="private-test-invitation",
        device_credential=f"hb_{base64url(b'c' * 32)}",
        installation_id="public-documents-test-installation",
        device_signing_public_key=base64url(b"s" * 32),
        device_agreement_public_key=base64url(b"a" * 32),
        namespace=config.namespace,
        run_id="10" * 16,
        challenge=base64url(b"h" * 32),
    )
    try:
        completion = provision_qa_mailbox(server, request)
    finally:
        server.server_close()
    assert completion["kind"] == "health_bridge.mailbox_qa_pairing_completion.v1"
    assert not expected.exists()
    assert len(list((runtime / "private/connections").glob("*.hbjcs1"))) == 1


def test_public_documents_receiver_rejects_alternate_root(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given: an otherwise exact public-documents configuration.
    project = Path(
        "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
    ).read_text(encoding="utf-8")
    assert f"PRODUCT_BUNDLE_IDENTIFIER = {PUBLIC_QA_PROJECT_BUNDLE};" in project
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    base_config = _base_config(runtime)
    bundle = f"{base_config.production_seal.bundle_identifier}{PUBLIC_QA_BUNDLE_SUFFIX}"
    container = f"iCloud.{bundle}"
    values = base_config.model_dump()
    values.update(
        {
            "bundle_identifier": bundle,
            "container_identifier": container,
            "url_scheme": "healthbridgeqa-public-documents",
            "keychain_service": f"{bundle}.mailboxqa",
            "keychain_access_groups": (f"TEAM.{bundle}",),
            "outbox_root": "HealthBridgeMailboxPublicDocumentsQA",
            "display_identity": "Synthetic Health Bridge Mailbox Public Documents QA",
            "database_namespace": "qa-public-documents",
            "app_path": runtime / "HealthBridgeCompanionPublicDocumentsQA.app",
            "mailbox_root_override": tmp_path / "alternate-public-root",
        }
    )
    monkeypatch.setattr(
        "health_bridge.mailbox_qa.receiver.sys.platform",
        "darwin",
    )
    monkeypatch.setattr(
        "health_bridge.mailbox_qa.receiver.pathlib.Path.home",
        lambda: tmp_path,
    )

    # When / Then: configuration rejects path escape before lifecycle mutation.
    with pytest.raises(ValidationError):
        _ = QAReceiverConfig.model_validate(values)


def test_public_documents_receiver_reuses_existing_importer() -> None:
    # Given: the QA lifecycle and generic importer implementation.
    lifecycle = Path("src/health_bridge/mailbox_qa/lifecycle.py").read_text(
        encoding="utf-8"
    )
    importer = Path("src/health_bridge/mailbox/importer.py").read_text(encoding="utf-8")
    project = Path(
        "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
    ).read_text(encoding="utf-8")

    # When / Then: the public target reaches the one existing acceptance path.
    assert f"PRODUCT_BUNDLE_IDENTIFIER = {PUBLIC_QA_PROJECT_BUNDLE};" in project
    assert lifecycle.count("MailboxImporter(") == 1
    assert "1 if config.mailbox_root_override is not None else 0" in lifecycle
    assert '"outbox_root": config.outbox_root' in lifecycle
    assert '"outbox_root": "HealthBridgeMailboxQA"' not in lifecycle
    assert "config.mailbox_root.mkdir" not in lifecycle
    assert importer.count("DeliveryAcceptanceService(") == 1
    assert list(Path("src/health_bridge/mailbox_qa").glob("*importer*.py")) == []

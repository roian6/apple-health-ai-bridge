from __future__ import annotations

import base64
import hashlib
from typing import TYPE_CHECKING, cast

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_encode
from health_bridge.mailbox_qa.production_seal import QAIsolationRequest

if TYPE_CHECKING:
    from pathlib import Path

DOMAIN = b"health-bridge/mailbox/qa/production-identity-seal/v1"


def _text(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def write_synthetic_production_seal(
    path: Path,
    *,
    icloud_containers: list[str] | None = None,
    keychain_services: list[str] | None = None,
) -> tuple[str, dict[str, JsonValue]]:
    key = Ed25519PrivateKey.from_private_bytes(hashlib.sha256(b"seal-test").digest())
    public_key = key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    document: dict[str, JsonValue] = {
        "v": 1,
        "kind": "health_bridge.production_identity_seal.v1",
        "created_at_ms": 1_753_334_400_000,
        "provenance": "synthetic-fixture",
        "bundle_identifier": "dev.example.healthbridge",
        "icloud_containers": cast(
            "list[JsonValue]",
            ["iCloud.dev.example.healthbridge"]
            if icloud_containers is None
            else icloud_containers,
        ),
        "url_schemes": ["healthbridge"],
        "keychain_services": (
            ["dev.example.healthbridge"]
            if keychain_services is None
            else cast("list[JsonValue]", keychain_services)
        ),
        "keychain_access_groups": ["TEAM.dev.example.healthbridge"],
        "display_identity": "Synthetic Health Bridge",
        "outbox_roots": ["HealthBridgeMailbox"],
        "receiver_ports": [28765],
        "runtime_roots": ["/private/synthetic/health-bridge"],
        "database_namespaces": ["health-bridge-production"],
        "installed_app_path": "/Applications/SyntheticHealthBridge.app",
        "installed_app_observation_sha256": "11" * 32,
        "codesign_team_identifier_sha256": "22" * 32,
        "signing_public_key": _text(public_key),
    }
    document["signature"] = _text(key.sign(DOMAIN + b"\0" + hbjcs1_encode(document)))
    _ = path.write_bytes(hbjcs1_encode(document))
    path.chmod(0o600)
    return hashlib.sha256(public_key).hexdigest(), document


def synthetic_qa_request(runtime_root: Path) -> QAIsolationRequest:
    return QAIsolationRequest(
        bundle_identifier="dev.example.healthbridge.mailboxqa",
        container_identifier="iCloud.dev.example.healthbridge.mailboxqa",
        url_scheme="healthbridgeqa",
        keychain_service="dev.example.healthbridge.mailboxqa.mailboxqa",
        keychain_access_groups=("TEAM.dev.example.healthbridge.mailboxqa",),
        outbox_root="HealthBridgeMailboxQA",
        display_identity="Synthetic Health Bridge Mailbox QA",
        receiver_port=38765,
        runtime_root=runtime_root,
        database_namespace="qa-synthetic-run",
        app_path=runtime_root / "SyntheticMailboxQA.app",
    )


__all__ = ["synthetic_qa_request", "write_synthetic_production_seal"]

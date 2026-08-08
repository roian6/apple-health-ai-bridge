from __future__ import annotations

import base64
import hashlib
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_decode, hbjcs1_encode

COMMIT = "6eb12a4fb29543e691c7e930f385dc4f9964598f"
RUN_ID = "10101010101010101010101010101010"
RECEIVER_ID = "01010101010101010101010101010101"
DEVICE_ID = "02020202020202020202020202020202"
DEVICE_SIGNING_KEY_ID = "03030303030303030303030303030303"
DEVICE_AGREEMENT_KEY_ID = "04040404040404040404040404040404"
RECEIVER_SIGNING_KEY_ID = "05050505050505050505050505050505"
RECEIVER_AGREEMENT_KEY_ID = "06060606060606060606060606060606"
CHALLENGE_BYTES = bytes.fromhex("11" * 32)
CHALLENGE = base64.urlsafe_b64encode(CHALLENGE_BYTES).rstrip(b"=").decode("ascii")
ARCHIVE_SHA = "a" * 64
CODE_DIRECTORY_HASH = "b" * 40
SIGNING_IDENTITY_SHA = "c" * 64
CONTAINER_IDENTIFIER_SHA = "d" * 64
DEVICE_IDENTIFIER_SHA = "e" * 64
BUNDLE_IDENTIFIER_SHA = "f" * 64
INSTALL_RECEIPT_SHA = "1" * 64
CONNECTION_HANDLE = "synthetic-anchored-connection"
REPORT_SIGNATURE_DOMAIN = b"health-bridge/mailbox/v1/evidence/report/signature"


@dataclass(frozen=True, slots=True)
class SyntheticEvidence:
    directory: Path
    state_path: Path
    report_path: Path
    codesign_path: Path
    install_path: Path


def _private_key() -> Ed25519PrivateKey:
    seed = hashlib.sha256(b"health-bridge/todo12/synthetic-ed25519").digest()
    return Ed25519PrivateKey.from_private_bytes(seed)


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _write(path: Path, document: dict[str, JsonValue]) -> None:
    _ = path.write_bytes(hbjcs1_encode(document))


def read_document(path: Path) -> dict[str, JsonValue]:
    match hbjcs1_decode(path.read_bytes()):
        case dict() as document:
            return document
        case unexpected:
            msg = f"expected object, got {type(unexpected).__name__}"
            raise AssertionError(msg)


def write_document(path: Path, document: dict[str, JsonValue]) -> None:
    _write(path, document)


def build_synthetic_evidence(root: Path) -> SyntheticEvidence:
    root.mkdir(mode=0o700)
    now_ms = time.time_ns() // 1_000_000
    started_at_ms = now_ms - 1_000
    expires_at_ms = started_at_ms + 600_000
    installed_at_ms = started_at_ms + 100
    report_started_at_ms = started_at_ms + 200
    report_finished_at_ms = started_at_ms + 500
    public_key = (
        _private_key()
        .public_key()
        .public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
    )

    prerequisites: dict[str, JsonValue] = {
        "v": 1,
        "kind": "mailbox_physical_prerequisites",
        "signing": "available",
        "container": "available",
        "device": "available",
        "account": "available",
        "authorization": "available",
    }
    harness: dict[str, JsonValue] = {
        "v": 1,
        "kind": "mailbox_physical_harness",
        "run_id": RUN_ID,
        "challenge": CHALLENGE,
        "source_commit_sha": COMMIT,
        "archive_sha256": ARCHIVE_SHA,
        "code_directory_hash": CODE_DIRECTORY_HASH,
        "signing_identity_sha256": SIGNING_IDENTITY_SHA,
        "container_identifier_sha256": CONTAINER_IDENTIFIER_SHA,
        "device_identifier_sha256": DEVICE_IDENTIFIER_SHA,
        "device_model": "SyntheticPhone1,1",
        "os_version": "18.0-synthetic",
        "bundle_identifier_sha256": BUNDLE_IDENTIFIER_SHA,
        "app_version": "1.0.0",
        "build_number": "15",
        "install_receipt_sha256": INSTALL_RECEIPT_SHA,
        "started_at_ms": started_at_ms,
        "expires_at_ms": expires_at_ms,
    }
    codesign: dict[str, JsonValue] = {
        "v": 1,
        "kind": "mailbox_codesign_evidence",
        "verified": True,
        "archive_sha256": ARCHIVE_SHA,
        "code_directory_hash": CODE_DIRECTORY_HASH,
        "signing_identity_sha256": SIGNING_IDENTITY_SHA,
        "container_identifier_sha256": CONTAINER_IDENTIFIER_SHA,
        "bundle_identifier_sha256": BUNDLE_IDENTIFIER_SHA,
        "app_version": "1.0.0",
        "build_number": "15",
    }
    install: dict[str, JsonValue] = {
        "v": 1,
        "kind": "mailbox_install_receipt",
        "install_receipt_sha256": INSTALL_RECEIPT_SHA,
        "archive_sha256": ARCHIVE_SHA,
        "device_identifier_sha256": DEVICE_IDENTIFIER_SHA,
        "device_model": "SyntheticPhone1,1",
        "os_version": "18.0-synthetic",
        "bundle_identifier_sha256": BUNDLE_IDENTIFIER_SHA,
        "app_version": "1.0.0",
        "build_number": "15",
        "installed_at_ms": installed_at_ms,
    }
    receiver_fingerprint = _fingerprint(
        b"health-bridge/mailbox/v1/evidence/receiver-fingerprint",
        bytes.fromhex(RECEIVER_ID),
    )
    key_fingerprint = _fingerprint(
        b"health-bridge/mailbox/v1/evidence/device-signing-key-fingerprint",
        bytes.fromhex(DEVICE_SIGNING_KEY_ID),
    )
    report: dict[str, JsonValue] = {
        "v": 1,
        "kind": "mailbox_physical_report",
        "run_id": RUN_ID,
        "challenge": CHALLENGE,
        "embedded_commit_sha": COMMIT,
        "bundle_identifier_sha256": BUNDLE_IDENTIFIER_SHA,
        "app_version": "1.0.0",
        "build_number": "15",
        "device_identifier_sha256": DEVICE_IDENTIFIER_SHA,
        "device_model": "SyntheticPhone1,1",
        "os_version": "18.0-synthetic",
        "receiver_fingerprint": receiver_fingerprint,
        "device_signing_key_fingerprint": key_fingerprint,
        "connection_generation": 7,
        "started_at_ms": report_started_at_ms,
        "finished_at_ms": report_finished_at_ms,
        "scenario_results": [
            {
                "name": "persisted_encoder_bytes_encrypted_unchanged",
                "result": "pass",
                "started_at_ms": report_started_at_ms,
                "finished_at_ms": report_started_at_ms + 100,
                "assertion_count": 3,
            },
            {
                "name": "strict_receiver_parse_without_reserialization",
                "result": "pass",
                "started_at_ms": report_started_at_ms + 101,
                "finished_at_ms": report_finished_at_ms,
                "assertion_count": 2,
            },
        ],
        "transition_counts": {
            "collected": 1,
            "encrypted": 1,
            "published": 1,
            "provider_observed": 1,
            "ack_verified": 1,
            "committed_finalized": 1,
            "retryable_failure": 0,
            "terminal_failure": 0,
        },
        "receipt_id": 1,
        "dataset_generation": 1,
    }
    signature = _private_key().sign(
        REPORT_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(report)
    )
    report["signature"] = _base64url(signature)
    state: dict[str, JsonValue] = {
        "v": 1,
        "kind": "mailbox_evidence_anchor_state",
        "bindings": [
            {
                "run_id": RUN_ID,
                "challenge": CHALLENGE,
                "connection_handle": CONNECTION_HANDLE,
                "created_at_ms": started_at_ms,
                "expires_at_ms": expires_at_ms,
                "consumed": False,
            }
        ],
        "connections": [
            {
                "connection_handle": CONNECTION_HANDLE,
                "receiver_id": RECEIVER_ID,
                "device_id": DEVICE_ID,
                "device_signing_key_id": DEVICE_SIGNING_KEY_ID,
                "device_agreement_key_id": DEVICE_AGREEMENT_KEY_ID,
                "receiver_signing_key_id": RECEIVER_SIGNING_KEY_ID,
                "receiver_agreement_key_id": RECEIVER_AGREEMENT_KEY_ID,
                "device_signing_public_key": _base64url(public_key),
                "connection_generation": 7,
            }
        ],
    }

    _write(root / "prerequisites.hbjcs1", prerequisites)
    _write(root / "harness.hbjcs1", harness)
    _write(root / "codesign.hbjcs1", codesign)
    _write(root / "install-receipt.hbjcs1", install)
    _write(root / "report.hbjcs1", report)
    state_path = root / "validator-local-state.hbjcs1"
    _write(state_path, state)
    state_path.chmod(0o600)
    return SyntheticEvidence(
        directory=root,
        state_path=state_path,
        report_path=root / "report.hbjcs1",
        codesign_path=root / "codesign.hbjcs1",
        install_path=root / "install-receipt.hbjcs1",
    )


def run_validator(fixture: SyntheticEvidence) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            "scripts/validate-mailbox-device-evidence.py",
            "--phase",
            "delivery",
            "--strict",
            "--commit",
            COMMIT,
            str(fixture.directory),
        ],
        cwd=Path(__file__).resolve().parents[2],
        check=False,
        capture_output=True,
        text=True,
    )


def _fingerprint(domain: bytes, identifier: bytes) -> str:
    digest = hashlib.sha256(
        domain
        + b"\0"
        + bytes.fromhex(RUN_ID)
        + b"\0"
        + CHALLENGE_BYTES
        + b"\0"
        + identifier
    ).digest()
    return digest[:8].hex()

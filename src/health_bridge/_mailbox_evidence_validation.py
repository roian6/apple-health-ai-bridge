from __future__ import annotations

import base64
import binascii
import hashlib
from dataclasses import dataclass
from typing import TYPE_CHECKING, Final

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from health_bridge._mailbox_evidence_types import (
    EvidenceFailureCode,
    MailboxEvidenceError,
)
from health_bridge.contract._hbjcs1 import HBJCS1Error, hbjcs1_encode

if TYPE_CHECKING:
    from health_bridge._mailbox_evidence_models import (
        AnchoredConnection,
        AnchorState,
        CodeSignEvidence,
        InstallReceipt,
        PhysicalHarness,
        PhysicalReport,
    )
    from health_bridge.contract._hbjcs1 import JsonValue

REPORT_SIGNATURE_DOMAIN: Final = b"health-bridge/mailbox/v1/evidence/report/signature"
RECEIVER_FINGERPRINT_DOMAIN: Final = (
    b"health-bridge/mailbox/v1/evidence/receiver-fingerprint"
)
DEVICE_KEY_FINGERPRINT_DOMAIN: Final = (
    b"health-bridge/mailbox/v1/evidence/device-signing-key-fingerprint"
)
REQUIRED_SCENARIOS: Final = frozenset(
    {
        "persisted_encoder_bytes_encrypted_unchanged",
        "strict_receiver_parse_without_reserialization",
    }
)
HARNESS_LIFETIME_MS: Final = 600_000


@dataclass(frozen=True, slots=True)
class MailboxArtifactSet:
    harness: PhysicalHarness
    codesign: CodeSignEvidence
    install: InstallReceipt
    report: PhysicalReport


def validate_artifacts(
    artifacts: MailboxArtifactSet,
    expected_commit: str,
    now_ms: int,
) -> None:
    harness = artifacts.harness
    codesign = artifacts.codesign
    install = artifacts.install
    report = artifacts.report
    bindings_hold = (
        codesign.verified
        and harness.expires_at_ms == harness.started_at_ms + HARNESS_LIFETIME_MS
        and harness.started_at_ms <= install.installed_at_ms <= report.started_at_ms
        and report.started_at_ms <= report.finished_at_ms <= harness.expires_at_ms
        and report.finished_at_ms <= now_ms <= harness.expires_at_ms
        and harness.source_commit_sha == expected_commit
        and report.embedded_commit_sha == harness.source_commit_sha
        and codesign.archive_sha256 == harness.archive_sha256 == install.archive_sha256
        and codesign.code_directory_hash == harness.code_directory_hash
        and codesign.signing_identity_sha256 == harness.signing_identity_sha256
        and codesign.container_identifier_sha256 == harness.container_identifier_sha256
        and codesign.bundle_identifier_sha256
        == harness.bundle_identifier_sha256
        == install.bundle_identifier_sha256
        == report.bundle_identifier_sha256
        and codesign.app_version
        == harness.app_version
        == install.app_version
        == report.app_version
        and codesign.build_number
        == harness.build_number
        == install.build_number
        == report.build_number
        and install.install_receipt_sha256 == harness.install_receipt_sha256
        and install.device_identifier_sha256
        == harness.device_identifier_sha256
        == report.device_identifier_sha256
        and install.device_model == harness.device_model == report.device_model
        and install.os_version == harness.os_version == report.os_version
        and report.run_id == harness.run_id
        and report.challenge == harness.challenge
    )
    if not bindings_hold:
        raise MailboxEvidenceError(EvidenceFailureCode.ARTIFACT_BINDING_MISMATCH)


def _fingerprint(domain: bytes, run_id: str, challenge: str, identifier: str) -> str:
    try:
        challenge_bytes = base64.urlsafe_b64decode(challenge + "=")
        digest = hashlib.sha256(
            domain
            + b"\0"
            + bytes.fromhex(run_id)
            + b"\0"
            + challenge_bytes
            + b"\0"
            + bytes.fromhex(identifier)
        ).digest()
    except (ValueError, binascii.Error) as exc:
        raise MailboxEvidenceError(EvidenceFailureCode.SCHEMA_INVALID) from exc
    return digest[:8].hex()


def validate_fingerprints(
    state: AnchorState,
    connection: AnchoredConnection,
    report: PhysicalReport,
) -> None:
    expected_receiver = _fingerprint(
        RECEIVER_FINGERPRINT_DOMAIN,
        report.run_id,
        report.challenge,
        connection.receiver_id,
    )
    expected_key = _fingerprint(
        DEVICE_KEY_FINGERPRINT_DOMAIN,
        report.run_id,
        report.challenge,
        connection.device_signing_key_id,
    )
    if (
        report.receiver_fingerprint != expected_receiver
        or report.device_signing_key_fingerprint != expected_key
        or report.connection_generation != connection.connection_generation
    ):
        raise MailboxEvidenceError(EvidenceFailureCode.FINGERPRINT_MISMATCH)
    receiver_matches = sum(
        _fingerprint(
            RECEIVER_FINGERPRINT_DOMAIN,
            report.run_id,
            report.challenge,
            item.receiver_id,
        )
        == report.receiver_fingerprint
        for item in state.connections
    )
    key_matches = sum(
        _fingerprint(
            DEVICE_KEY_FINGERPRINT_DOMAIN,
            report.run_id,
            report.challenge,
            item.device_signing_key_id,
        )
        == report.device_signing_key_fingerprint
        for item in state.connections
    )
    if receiver_matches != 1 or key_matches != 1:
        raise MailboxEvidenceError(EvidenceFailureCode.FINGERPRINT_COLLISION)


def validate_scenarios(report: PhysicalReport) -> None:
    names = [result.name for result in report.scenario_results]
    if len(names) != len(set(names)) or not REQUIRED_SCENARIOS.issubset(names):
        raise MailboxEvidenceError(EvidenceFailureCode.SCENARIO_MISSING)
    if any(
        result.result != "pass"
        or not report.started_at_ms
        <= result.started_at_ms
        <= result.finished_at_ms
        <= report.finished_at_ms
        for result in report.scenario_results
    ):
        raise MailboxEvidenceError(EvidenceFailureCode.SCENARIO_FAILED)


def verify_signature(
    report_document: dict[str, JsonValue],
    report: PhysicalReport,
    connection: AnchoredConnection,
) -> None:
    unsigned = dict(report_document)
    del unsigned["signature"]
    try:
        signature = base64.urlsafe_b64decode(report.signature + "==")
        public_key = base64.urlsafe_b64decode(
            connection.device_signing_public_key + "="
        )
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            signature,
            REPORT_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned),
        )
    except (ValueError, binascii.Error, InvalidSignature, HBJCS1Error) as exc:
        raise MailboxEvidenceError(EvidenceFailureCode.SIGNATURE_INVALID) from exc

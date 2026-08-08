from __future__ import annotations

import base64
import hashlib
import os
import stat
from typing import TYPE_CHECKING

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    JsonValue,
    hbjcs1_decode,
    hbjcs1_encode,
)
from health_bridge.mailbox_qa.m3_errors import M3ValidationError
from health_bridge.mailbox_qa.m3_models import DeviceReportV1, M3AnchorV1
from health_bridge.mailbox_qa.m3_signatures import verify_signature
from health_bridge.mailbox_qa.scenario_contract import (
    DEVICE_SIGNATURE_DOMAIN,
    SYNTHETIC_PAYLOAD_SHA256,
)
from health_bridge.mailbox_qa.scenario_issuance import (
    OperationObservation,
    ScenarioReceiptContextV1,
    issue_scenario_receipt,
)

if TYPE_CHECKING:
    from collections.abc import Mapping
    from pathlib import Path

ED25519_PRIVATE_KEY_BYTES = 32


class DeviceOperationError(Exception):
    pass


def issue_device_observed_receipts(
    report_path: Path,
    anchor_path: Path,
    context: ScenarioReceiptContextV1,
    owner_key: Ed25519PrivateKey,
    *,
    provider_envelope: Path | None,
) -> tuple[dict[str, JsonValue], ...]:
    report_document = _private_canonical_document(report_path)
    anchor_document = _private_canonical_document(anchor_path)
    try:
        report = DeviceReportV1.model_validate(report_document)
        anchor = M3AnchorV1.model_validate(anchor_document)
        verify_signature(
            report_document,
            report.signature,
            anchor.device_report_public_key,
            DEVICE_SIGNATURE_DOMAIN,
        )
    except (ValueError, HBJCS1Error, M3ValidationError) as exc:
        raise DeviceOperationError from exc
    _validate_bindings(report, anchor, context)
    material = hbjcs1_encode(report_document)
    facts: dict[str, Mapping[str, bool]] = {
        "authenticated_committed_ack": {
            "ack_signature_verified": report.transition_counts.ack_verified == 1,
            "committed_status_bound": report.finalization_count == 1,
            "durable_before_ack": report.transition_counts.provider_observed >= 1,
        },
        "restart_retry": {
            "retry_survived_restart": (
                report.restart_epoch >= 1 and report.envelope_reuse_count >= 1
            ),
            "single_final_commit": report.finalization_count == 1,
        },
        "persisted_encoder_bytes_encrypted_unchanged": {
            "payload_bytes_unchanged": (
                report.synthetic_payload_sha256 == SYNTHETIC_PAYLOAD_SHA256
            ),
            "envelope_bytes_unchanged": report.envelope_reuse_count >= 1,
        },
        "lock_unlock": {
            "locked_attempt_bounded": (report.protected_data_unavailable_count >= 1),
            "unlock_retry_succeeded": report.protected_data_available_count >= 1,
        },
        "foreground_background_termination": {
            "foreground_published": (
                report.foreground_observation_count >= 1
                and report.transition_counts.published >= 1
            ),
            "background_retry_observed": (
                report.background_observation_count >= 1
                and report.transition_counts.retryable_failure >= 1
            ),
            "termination_recovery_succeeded": report.restart_epoch >= 1,
        },
        "quota_disk_fault": {
            "local_publisher_enospc_injected": report.fault_injection_count >= 1,
            "real_icloud_quota_not_claimed": True,
            "recovery_succeeded": report.transition_counts.published >= 1,
        },
    }
    if provider_envelope is not None:
        provider_bytes = _private_regular_bytes(provider_envelope)
        provider_hash = hashlib.sha256(provider_bytes).hexdigest()
        material += b"\0" + provider_hash.encode("ascii")
        facts["actual_icloud_publication"] = {
            "qa_container_observed": (report.transition_counts.provider_observed >= 1),
            "provider_visible_regular_file": (provider_hash == report.envelope_sha256),
        }
    return tuple(
        _issue(context, report, scenario, checks, material, owner_key)
        for scenario, checks in facts.items()
        if all(checks.values())
    )


def load_private_owner_key(path: Path) -> Ed25519PrivateKey:
    try:
        encoded = _private_regular_bytes(path).decode("ascii")
        raw = base64.urlsafe_b64decode(encoded + "=")
        canonical = base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")
        if len(raw) != ED25519_PRIVATE_KEY_BYTES or encoded != canonical:
            raise DeviceOperationError
        return Ed25519PrivateKey.from_private_bytes(raw)
    except (OSError, UnicodeError, ValueError) as exc:
        raise DeviceOperationError from exc


def _issue(  # noqa: PLR0913
    context: ScenarioReceiptContextV1,
    report: DeviceReportV1,
    scenario: str,
    facts: Mapping[str, bool],
    material: bytes,
    owner_key: Ed25519PrivateKey,
) -> dict[str, JsonValue]:
    return issue_scenario_receipt(
        OperationObservation(
            scenario=scenario,
            producer="parent_orchestrator",
            run_id=context.run_id,
            challenge=context.challenge,
            head=context.head,
            qa_bundle_fingerprint=context.qa_bundle_fingerprint,
            qa_container_fingerprint=context.qa_container_fingerprint,
            operation_id=hashlib.sha256(
                material + b"\0" + scenario.encode("ascii")
            ).hexdigest()[:32],
            started_at_ms=report.started_at_ms,
            finished_at_ms=report.finished_at_ms,
            facts=facts,
            observed_material=material,
        ),
        owner_key,
    )


def _validate_bindings(
    report: DeviceReportV1,
    anchor: M3AnchorV1,
    context: ScenarioReceiptContextV1,
) -> None:
    if (
        report.run_id != context.run_id
        or report.challenge != context.challenge
        or report.head != context.head
        or report.qa_bundle_fingerprint != context.qa_bundle_fingerprint
        or report.qa_container_fingerprint != context.qa_container_fingerprint
        or anchor.run_id != context.run_id
        or anchor.challenge != context.challenge
        or anchor.head != context.head
        or anchor.qa_bundle_fingerprint != context.qa_bundle_fingerprint
        or anchor.qa_container_fingerprint != context.qa_container_fingerprint
        or report.started_at_ms < anchor.created_at_ms
        or report.finished_at_ms > anchor.expires_at_ms
    ):
        raise DeviceOperationError


def _private_canonical_document(path: Path) -> dict[str, JsonValue]:
    encoded = _private_regular_bytes(path)
    try:
        document = hbjcs1_decode(encoded)
    except HBJCS1Error as exc:
        raise DeviceOperationError from exc
    if not isinstance(document, dict) or hbjcs1_encode(document) != encoded:
        raise DeviceOperationError
    return document


def _private_regular_bytes(path: Path) -> bytes:
    entry = path.lstat()
    if (
        not stat.S_ISREG(entry.st_mode)
        or entry.st_nlink != 1
        or (os.name == "posix" and entry.st_mode & 0o077)
    ):
        raise DeviceOperationError
    return path.read_bytes()


__all__ = [
    "DeviceOperationError",
    "issue_device_observed_receipts",
    "load_private_owner_key",
]

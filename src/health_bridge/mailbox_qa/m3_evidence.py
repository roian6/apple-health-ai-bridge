from __future__ import annotations

import hashlib
from typing import TYPE_CHECKING, Final

from health_bridge._milestone_files import read_scoped_regular_file
from health_bridge.mailbox_qa.m3_contract import (
    DEVICE_SIGNATURE_DOMAIN,
    EVIDENCE_CLASSES,
    PARENT_RECEIPTS,
    RECEIPT_SIGNATURE_DOMAIN,
    SCENARIO_CHECKS,
    SCENARIO_PRODUCERS,
    SYNTHETIC_PAYLOAD_SHA256,
)
from health_bridge.mailbox_qa.m3_errors import M3FailureCode, M3ValidationError
from health_bridge.mailbox_qa.m3_files import (
    bound_document,
    parse_document,
)
from health_bridge.mailbox_qa.m3_models import DeviceReportV1, ScenarioReceiptV1
from health_bridge.mailbox_qa.m3_privacy import (
    scan_evidence_privacy,
    scan_parent_receipt_privacy,
)
from health_bridge.mailbox_qa.m3_signatures import verify_signature

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.mailbox_qa.m3_models import M3AnchorV1, M3ManifestV1

REQUIRED_TRANSITIONS: Final = (
    "collected",
    "encrypted",
    "published",
    "provider_observed",
    "ack_verified",
    "committed_finalized",
    "retryable_failure",
)
REQUIRED_LIFECYCLE_EPOCH: Final = 2


def validate_parent_receipts(
    root: Path,
    manifest: M3ManifestV1,
    anchor: M3AnchorV1,
) -> None:
    by_kind = {binding.receipt_kind: binding for binding in manifest.parent_receipts}
    if set(by_kind) != set(PARENT_RECEIPTS):
        raise M3ValidationError(M3FailureCode.STALE_PARENT_RECEIPT)
    for receipt_kind, contract in PARENT_RECEIPTS.items():
        binding = by_kind[receipt_kind]
        content = read_scoped_regular_file(root, binding.path)
        if content is not None:
            scan_parent_receipt_privacy(
                content,
                full_identifiers=frozenset(anchor.full_identifiers),
            )
        binding_matches = (
            binding.kind == "parent_receipt"
            and binding.path == contract.path
            and content is not None
            and binding.sha256 == contract.sha256
            and hashlib.sha256(content).hexdigest() == contract.sha256
            and all(marker in content for marker in contract.required_markers)
        )
        if not binding_matches:
            raise M3ValidationError(M3FailureCode.STALE_PARENT_RECEIPT)


def validate_device_report(
    root: Path,
    manifest: M3ManifestV1,
    anchor: M3AnchorV1,
) -> None:
    binding = manifest.device_report
    if binding.kind != "device_report":
        raise M3ValidationError(M3FailureCode.ARTIFACT_BINDING)
    document = bound_document(root, binding)
    scan_evidence_privacy(document, full_identifiers=frozenset(anchor.full_identifiers))
    report = parse_document(document, DeviceReportV1)
    transitions = report.transition_counts.model_dump()
    common = (
        report.run_id == anchor.run_id
        and report.challenge == anchor.challenge
        and report.head == manifest.head
        and report.qa_bundle_fingerprint == manifest.qa_bundle_fingerprint
        and report.qa_container_fingerprint == manifest.qa_container_fingerprint
        and report.synthetic_payload_sha256 == SYNTHETIC_PAYLOAD_SHA256
        and report.envelope_reuse_count >= 1
        and report.lifecycle_epoch >= REQUIRED_LIFECYCLE_EPOCH
        and report.restart_epoch >= 1
        and report.finalization_count == 1
        and report.fault_injection_count >= 1
        and report.foreground_observation_count >= 1
        and report.background_observation_count >= 1
        and report.protected_data_available_count >= 1
        and report.protected_data_unavailable_count >= 1
        and _inside_anchor_window(report.started_at_ms, report.finished_at_ms, anchor)
        and all(transitions[name] >= 1 for name in REQUIRED_TRANSITIONS)
        and report.transition_counts.terminal_failure == 0
    )
    if not common:
        raise M3ValidationError(M3FailureCode.ARTIFACT_BINDING)
    verify_signature(
        document,
        report.signature,
        anchor.device_report_public_key,
        DEVICE_SIGNATURE_DOMAIN,
    )


def validate_scenario_receipts(
    root: Path,
    manifest: M3ManifestV1,
    anchor: M3AnchorV1,
) -> None:
    bindings = {binding.scenario: binding for binding in manifest.scenario_receipts}
    if set(bindings) != set(SCENARIO_PRODUCERS):
        raise M3ValidationError(M3FailureCode.SCENARIO_MISSING)
    for scenario, producer in SCENARIO_PRODUCERS.items():
        binding = bindings[scenario]
        if binding.kind != "scenario_receipt":
            raise M3ValidationError(M3FailureCode.ARTIFACT_BINDING)
        document = bound_document(root, binding)
        scan_evidence_privacy(
            document,
            full_identifiers=frozenset(anchor.full_identifiers),
        )
        receipt = parse_document(document, ScenarioReceiptV1)
        expected_checks = SCENARIO_CHECKS[scenario]
        common = (
            receipt.scenario == scenario
            and receipt.producer == producer
            and receipt.evidence_class
            == EVIDENCE_CLASSES.get(scenario, "receiver_commit")
            and receipt.issuance == "operation_v1"
            and tuple(receipt.checks) == expected_checks
            and receipt.assertion_count == len(expected_checks)
            and receipt.run_id == anchor.run_id
            and receipt.challenge == anchor.challenge
            and receipt.head == manifest.head
            and receipt.qa_bundle_fingerprint == manifest.qa_bundle_fingerprint
            and receipt.qa_container_fingerprint == manifest.qa_container_fingerprint
            and _inside_anchor_window(
                receipt.started_at_ms, receipt.finished_at_ms, anchor
            )
        )
        if not common:
            raise M3ValidationError(M3FailureCode.ARTIFACT_BINDING)
        public_key = (
            anchor.receiver_receipt_public_key
            if producer == "qa_receiver"
            else anchor.parent_receipt_public_key
        )
        verify_signature(
            document,
            receipt.signature,
            public_key,
            RECEIPT_SIGNATURE_DOMAIN,
        )


def _inside_anchor_window(
    started_at_ms: int,
    finished_at_ms: int,
    anchor: M3AnchorV1,
) -> bool:
    return (
        anchor.created_at_ms <= started_at_ms <= finished_at_ms <= anchor.expires_at_ms
    )


__all__ = [
    "validate_device_report",
    "validate_parent_receipts",
    "validate_scenario_receipts",
]

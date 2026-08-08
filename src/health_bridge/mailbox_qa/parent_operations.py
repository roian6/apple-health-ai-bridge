from __future__ import annotations

import hashlib
import time
from typing import TYPE_CHECKING, Final

from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_encode
from health_bridge.mailbox_qa.archive_provenance import load_archive_provenance
from health_bridge.mailbox_qa.m3_signatures import short_fingerprint
from health_bridge.mailbox_qa.parent_operation_files import (
    ParentOperationFileError,
    is_sha256,
    private_json,
    production_snapshot,
    regular_bytes,
    sha256,
    strings,
)
from health_bridge.mailbox_qa.production_seal import (
    ProductionIdentitySealV1,
    production_seal_fingerprint,
)
from health_bridge.mailbox_qa.scenario_issuance import (
    OperationObservation,
    ScenarioReceiptContextV1,
    issue_scenario_receipt,
)

if TYPE_CHECKING:
    from collections.abc import Mapping
    from pathlib import Path

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

MAXIMUM_DELAY_SECONDS = 60
QA_ARCHIVE_PROFILES: Final = (
    (".mailboxqa", "HealthBridgeCompanionMailboxQA"),
    (
        ".publicdocuments.mailboxqa",
        "HealthBridgeCompanionPublicDocumentsQA",
    ),
)


ParentOperationError = ParentOperationFileError


def observe_delayed_ack(
    ack_path: Path,
    context: ScenarioReceiptContextV1,
    owner_key: Ed25519PrivateKey,
    *,
    maximum_wait_seconds: int,
) -> dict[str, JsonValue]:
    if not 1 <= maximum_wait_seconds <= MAXIMUM_DELAY_SECONDS or ack_path.exists():
        raise ParentOperationError
    started_at_ms = time.time_ns() // 1_000_000
    deadline = time.monotonic() + maximum_wait_seconds
    while not ack_path.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    content = regular_bytes(ack_path, private=False)
    finished_at_ms = time.time_ns() // 1_000_000
    material = hashlib.sha256(content).hexdigest().encode("ascii")
    return _issue(
        context,
        owner_key,
        scenario="provider_delay",
        started_at_ms=started_at_ms,
        finished_at_ms=finished_at_ms,
        facts={
            "delay_observed": finished_at_ms > started_at_ms,
            "bounded_retry_succeeded": finished_at_ms
            <= (started_at_ms + maximum_wait_seconds * 1_000),
        },
        material=material,
    )


def issue_parent_artifact_receipts(  # noqa: PLR0913
    provenance_path: Path,
    install_inspection_path: Path,
    cleanup_output_path: Path,
    receiver_cleanup_path: Path,
    inventory_before_path: Path,
    inventory_after_path: Path,
    seal: ProductionIdentitySealV1,
    context: ScenarioReceiptContextV1,
    owner_key: Ed25519PrivateKey,
) -> tuple[dict[str, JsonValue], ...]:
    provenance = load_archive_provenance(provenance_path)
    install_inspection = private_json(install_inspection_path)
    cleanup = private_json(cleanup_output_path)
    receiver_cleanup = private_json(receiver_cleanup_path)
    before = tuple(strings(private_json(inventory_before_path)))
    after = tuple(strings(private_json(inventory_after_path)))
    seal_fingerprint = production_seal_fingerprint(seal)
    started_at_ms = context.created_at_ms
    finished_at_ms = time.time_ns() // 1_000_000
    material = hbjcs1_encode(
        {
            "provenance_sha256": sha256(provenance_path),
            "install_inspection_sha256": sha256(install_inspection_path),
            "cleanup_sha256": sha256(cleanup_output_path),
            "receiver_cleanup_sha256": sha256(receiver_cleanup_path),
            "inventory_before_sha256": sha256(inventory_before_path),
            "inventory_after_sha256": sha256(inventory_after_path),
        }
    )
    qa_removed = cleanup == {
        "action": "cleanup",
        "kind": "health_bridge.mailbox_qa_invocation_output.v1",
        "status": "qa_artifacts_removed",
        "v": 1,
    }
    receiver_removed = (
        receiver_cleanup.get("kind") == "health_bridge.mailbox_qa_cleanup_receipt.v1"
        and receiver_cleanup.get("status") == "complete"
    )
    production_before = (
        seal.bundle_identifier in before and seal.installed_app_path in before
    )
    production_after = (
        seal.bundle_identifier in after and seal.installed_app_path in after
    )
    production_snapshot_before = production_snapshot(before, seal)
    production_snapshot_after = production_snapshot(after, seal)
    qa_bundles_before = tuple(
        value
        for value in before
        if value.startswith(f"{seal.bundle_identifier}.")
        and value.endswith(".mailboxqa")
        and not value.startswith("iCloud.")
    )
    qa_bundles_after = tuple(
        value
        for value in after
        if value.startswith(f"{seal.bundle_identifier}.")
        and value.endswith(".mailboxqa")
        and not value.startswith("iCloud.")
    )
    install_valid = (
        install_inspection.get("kind")
        == "health_bridge.mailbox_qa_install_inspection.v1"
        and install_inspection.get("result") == "validated"
        and install_inspection.get("source_commit") == context.head
        and install_inspection.get("production_seal_fingerprint") == seal_fingerprint
        and install_inspection.get("executable_sha256") == provenance.executable_sha256
        and install_inspection.get("codesign_identity_sha256")
        == provenance.codesign_identity_sha256
        and is_sha256(install_inspection.get("entitlements_sha256"))
    )
    expected_qa_profile = _expected_qa_profile(seal, context)
    observations: tuple[tuple[str, Mapping[str, bool]], ...] = (
        (
            "signed_qa_app_provenance",
            {
                "executable_hash_bound": provenance.source_commit == context.head,
                "codesign_identity_bound": (
                    provenance.production_seal_fingerprint == seal_fingerprint
                ),
                "qa_entitlements_bound": (
                    install_valid
                    and expected_qa_profile is not None
                    and provenance.scheme == expected_qa_profile[1]
                    and provenance.target == expected_qa_profile[1]
                ),
            },
        ),
        (
            "cleanup",
            {
                "qa_process_stopped": receiver_removed,
                "qa_runtime_removed": receiver_removed,
            },
        ),
        (
            "rollback",
            {
                "qa_app_removed": (
                    qa_removed
                    and expected_qa_profile is not None
                    and qa_bundles_before == (expected_qa_profile[0],)
                    and not qa_bundles_after
                ),
                "qa_container_artifacts_removed": qa_removed,
            },
        ),
        (
            "production_preservation",
            {
                "production_identity_unchanged": (
                    production_before and production_after
                ),
                "production_state_unchanged": (
                    len(production_snapshot_before) > 0
                    and production_snapshot_before == production_snapshot_after
                ),
            },
        ),
    )
    receipts = tuple(
        _issue(
            context,
            owner_key,
            scenario=scenario,
            started_at_ms=started_at_ms,
            finished_at_ms=finished_at_ms,
            facts=facts,
            material=material,
        )
        for scenario, facts in observations
        if all(facts.values())
    )
    if len(receipts) != len(observations):
        raise ParentOperationError
    return receipts


def _expected_qa_profile(
    seal: ProductionIdentitySealV1,
    context: ScenarioReceiptContextV1,
) -> tuple[str, str] | None:
    for bundle_suffix, archive_target in QA_ARCHIVE_PROFILES:
        bundle = f"{seal.bundle_identifier}{bundle_suffix}"
        container = f"iCloud.{bundle}"
        if context.qa_bundle_fingerprint == short_fingerprint(
            b"health-bridge/mailbox/m3/v1/qa-bundle",
            bundle,
        ) and context.qa_container_fingerprint == short_fingerprint(
            b"health-bridge/mailbox/m3/v1/qa-container",
            container,
        ):
            return bundle, archive_target
    return None


def _issue(  # noqa: PLR0913
    context: ScenarioReceiptContextV1,
    owner_key: Ed25519PrivateKey,
    *,
    scenario: str,
    started_at_ms: int,
    finished_at_ms: int,
    facts: Mapping[str, bool],
    material: bytes,
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
            started_at_ms=started_at_ms,
            finished_at_ms=finished_at_ms,
            facts=facts,
            observed_material=material,
        ),
        owner_key,
    )


__all__ = [
    "ParentOperationError",
    "issue_parent_artifact_receipts",
    "observe_delayed_ack",
]

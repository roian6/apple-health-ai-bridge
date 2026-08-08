from __future__ import annotations

import base64
import hashlib
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_decode, hbjcs1_encode
from health_bridge.mailbox_m2_validator import (
    RECEIPT_POLICIES,
    REQUIRED_BOUNDARIES,
    REQUIRED_SCOPE_PATHS,
    STARTING_PLAN_SHA256,
)
from health_bridge.mailbox_qa.archive_provenance import (
    QAArchiveProvenanceV1,
    QALaneName,
    write_archive_provenance,
)
from health_bridge.mailbox_qa.device_operations import issue_device_observed_receipts
from health_bridge.mailbox_qa.m3_contract import (
    DEVICE_SIGNATURE_DOMAIN,
    PARENT_RECEIPTS,
    SCENARIO_PRODUCERS,
    SYNTHETIC_PAYLOAD_SHA256,
)
from health_bridge.mailbox_qa.parent_operations import (
    issue_parent_artifact_receipts,
    observe_delayed_ack,
)
from health_bridge.mailbox_qa.production_seal import (
    ProductionIdentitySealV1,
    load_production_identity_seal,
    production_seal_fingerprint,
)
from health_bridge.mailbox_qa.receiver_operations import (
    ReceiverOperationObservationV1,
    issue_receiver_receipts,
)
from health_bridge.mailbox_qa.scenario_issuance import ScenarioReceiptContextV1
from tests.scripts.production_seal_support import write_synthetic_production_seal

HEAD = "6eb12a4fb29543e691c7e930f385dc4f9964598f"
RUN_ID = "10" * 16
CHALLENGE = base64.urlsafe_b64encode(bytes.fromhex("11" * 32)).rstrip(b"=").decode()
QA_BUNDLE = "dev.example.healthbridge.mailboxqa"
QA_CONTAINER = "iCloud.dev.example.healthbridge.mailboxqa"
FULL_IDENTIFIER = "22" * 16
FULL_IDENTIFIERS = tuple(f"{value:02x}" * 16 for value in range(0x22, 0x2A))


@dataclass(frozen=True, slots=True)
class M3Fixture:
    root: Path
    m2_manifest: Path
    manifest: Path
    anchor: Path
    report: Path
    parent_receipts: tuple[Path, ...]
    receipts: tuple[Path, ...]
    production_seal: Path
    production_seal_anchor_sha256: str


def _private_key(label: bytes) -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(hashlib.sha256(label).digest())


def _text(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _public(key: Ed25519PrivateKey) -> str:
    return _text(
        key.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
    )


def _fingerprint(domain: bytes, value: str) -> str:
    return hashlib.sha256(domain + b"\0" + value.encode()).digest()[:8].hex()


def _write(path: Path, document: dict[str, JsonValue]) -> None:
    _ = path.write_bytes(hbjcs1_encode(document))


def read(path: Path) -> dict[str, JsonValue]:
    value = hbjcs1_decode(path.read_bytes())
    assert isinstance(value, dict)
    return value


def write(path: Path, document: dict[str, JsonValue]) -> None:
    _write(path, document)


def _signed(
    document: dict[str, JsonValue],
    key: Ed25519PrivateKey,
    domain: bytes,
) -> dict[str, JsonValue]:
    signed = dict(document)
    signed["signature"] = _text(key.sign(domain + b"\0" + hbjcs1_encode(document)))
    return signed


def _owner_issued_receipts(  # noqa: PLR0913
    root: Path,
    report_path: Path,
    anchor_path: Path,
    seal: ProductionIdentitySealV1,
    seal_fingerprint: str,
    receiver_key: Ed25519PrivateKey,
    parent_key: Ed25519PrivateKey,
    now_ms: int,
    archive_target: QALaneName | None,
    inventory_before_qa_bundles: tuple[str, ...] | None,
    inventory_after_qa_bundle: str | None,
) -> tuple[dict[str, JsonValue], ...]:
    context = ScenarioReceiptContextV1(
        v=1,
        kind="health_bridge.mailbox_qa_receipt_context.v1",
        run_id=RUN_ID,
        challenge=CHALLENGE,
        head=HEAD,
        qa_bundle_fingerprint=_fingerprint(
            b"health-bridge/mailbox/m3/v1/qa-bundle",
            QA_BUNDLE,
        ),
        qa_container_fingerprint=_fingerprint(
            b"health-bridge/mailbox/m3/v1/qa-container",
            QA_CONTAINER,
        ),
        created_at_ms=now_ms - 1_000,
        expires_at_ms=now_ms - 1_000 + 3_600_000,
    )
    receiver_observations = (
        ReceiverOperationObservationV1(
            v=1,
            kind="health_bridge.mailbox_qa_receiver_operation.v1",
            operation="one_shot_importer",
            imported=1,
            idempotent=0,
            quarantined=0,
            retryable=0,
            conflict=0,
            skipped=0,
            delivery_sha256_before="77" * 32,
            delivery_sha256_after="77" * 32,
            ack_count_before=0,
            ack_count_after=1,
            injected_local_conflict=False,
            started_at_ms=now_ms - 500,
            finished_at_ms=now_ms - 100,
        ),
        ReceiverOperationObservationV1(
            v=1,
            kind="health_bridge.mailbox_qa_receiver_operation.v1",
            operation="duplicate_identical",
            imported=0,
            idempotent=1,
            quarantined=0,
            retryable=0,
            conflict=0,
            skipped=0,
            delivery_sha256_before="77" * 32,
            delivery_sha256_after="77" * 32,
            ack_count_before=1,
            ack_count_after=1,
            injected_local_conflict=False,
            started_at_ms=now_ms - 500,
            finished_at_ms=now_ms - 100,
        ),
        ReceiverOperationObservationV1(
            v=1,
            kind="health_bridge.mailbox_qa_receiver_operation.v1",
            operation="conflict_rejected",
            imported=0,
            idempotent=0,
            quarantined=1,
            retryable=0,
            conflict=0,
            skipped=0,
            delivery_sha256_before="77" * 32,
            delivery_sha256_after="77" * 32,
            ack_count_before=1,
            ack_count_after=1,
            injected_local_conflict=True,
            started_at_ms=now_ms - 500,
            finished_at_ms=now_ms - 100,
        ),
    )
    receipts = [
        receipt
        for observation in receiver_observations
        for receipt in issue_receiver_receipts(observation, context, receiver_key)
    ]
    report_path.chmod(0o600)
    provider = root / "provider-envelope.hbd"
    _ = provider.write_bytes(b"synthetic finalized encrypted envelope")
    provider.chmod(0o600)
    receipts.extend(
        issue_device_observed_receipts(
            report_path,
            anchor_path,
            context,
            parent_key,
            provider_envelope=provider,
        )
    )
    delayed_ack = root / "delayed-ack.hba"

    def publish_delayed_ack() -> None:
        time.sleep(0.1)
        _ = delayed_ack.write_bytes(b"synthetic authenticated ack")
        delayed_ack.chmod(0o600)

    worker = threading.Thread(target=publish_delayed_ack)
    worker.start()
    receipts.append(
        observe_delayed_ack(
            delayed_ack,
            context,
            parent_key,
            maximum_wait_seconds=1,
        )
    )
    worker.join(timeout=2)
    provenance_path = root / "qa-provenance.hbjcs1"
    write_archive_provenance(
        provenance_path,
        QAArchiveProvenanceV1(
            v=1,
            kind="health_bridge.mailbox_qa_archive_provenance.v1",
            source_commit=HEAD,
            production_seal_fingerprint=seal_fingerprint,
            executable_sha256="33" * 32,
            codesign_identity_sha256="44" * 32,
            scheme=(
                archive_target
                if archive_target is not None
                else (
                    "HealthBridgeCompanionPublicDocumentsQA"
                    if f"{seal.bundle_identifier}.publicdocuments.mailboxqa"
                    == QA_BUNDLE
                    else "HealthBridgeCompanionMailboxQA"
                )
            ),
            target=(
                archive_target
                if archive_target is not None
                else (
                    "HealthBridgeCompanionPublicDocumentsQA"
                    if f"{seal.bundle_identifier}.publicdocuments.mailboxqa"
                    == QA_BUNDLE
                    else "HealthBridgeCompanionMailboxQA"
                )
            ),
        ),
    )
    artifact_documents: dict[str, dict[str, JsonValue]] = {
        "install-inspection.hbjcs1": {
            "v": 1,
            "kind": "health_bridge.mailbox_qa_install_inspection.v1",
            "result": "validated",
            "source_commit": HEAD,
            "production_seal_fingerprint": seal_fingerprint,
            "executable_sha256": "33" * 32,
            "codesign_identity_sha256": "44" * 32,
            "entitlements_sha256": "55" * 32,
        },
        "cleanup-output.hbjcs1": {
            "v": 1,
            "kind": "health_bridge.mailbox_qa_invocation_output.v1",
            "action": "cleanup",
            "status": "qa_artifacts_removed",
        },
        "receiver-cleanup.hbjcs1": {
            "v": 1,
            "kind": "health_bridge.mailbox_qa_cleanup_receipt.v1",
            "status": "complete",
            "run_reference": "synthetic-run",
        },
        "inventory-before.hbjcs1": {
            "apps": [
                seal.bundle_identifier,
                seal.installed_app_path,
                *(
                    inventory_before_qa_bundles
                    if inventory_before_qa_bundles is not None
                    else (QA_BUNDLE,)
                ),
            ]
        },
        "inventory-after.hbjcs1": {
            "apps": [
                seal.bundle_identifier,
                seal.installed_app_path,
                *(
                    [inventory_after_qa_bundle]
                    if inventory_after_qa_bundle is not None
                    else []
                ),
            ]
        },
    }
    artifact_paths: dict[str, Path] = {}
    for name, document in artifact_documents.items():
        path = root / name
        _write(path, document)
        path.chmod(0o600)
        artifact_paths[name] = path
    receipts.extend(
        issue_parent_artifact_receipts(
            provenance_path,
            artifact_paths["install-inspection.hbjcs1"],
            artifact_paths["cleanup-output.hbjcs1"],
            artifact_paths["receiver-cleanup.hbjcs1"],
            artifact_paths["inventory-before.hbjcs1"],
            artifact_paths["inventory-after.hbjcs1"],
            seal,
            context,
            parent_key,
        )
    )
    if {str(receipt["scenario"]) for receipt in receipts} != set(SCENARIO_PRODUCERS):
        raise AssertionError
    return tuple(receipts)


def build_m3_fixture(
    root: Path,
    *,
    prerequisites_available: bool = True,
    archive_target: QALaneName | None = None,
    inventory_before_qa_bundles: tuple[str, ...] | None = None,
    inventory_after_qa_bundle: str | None = None,
) -> M3Fixture:
    root.mkdir(mode=0o700)
    receipts_dir = root / "receipts"
    receipts_dir.mkdir(mode=0o700)
    parent_receipts_dir = root / "parent_receipts"
    parent_receipts_dir.mkdir(mode=0o700)
    now_ms = time.time_ns() // 1_000_000
    device_key = _private_key(b"m3-device")
    receiver_key = _private_key(b"m3-receiver")
    parent_key = _private_key(b"m3-parent")
    seal_path = root / "production-seal.hbjcs1"
    seal_anchor, _ = write_synthetic_production_seal(seal_path)
    seal = load_production_identity_seal(seal_path, seal_anchor)
    seal_fingerprint = production_seal_fingerprint(seal)
    m2_manifest_path = root / "m2-manifest.synthetic.hbjcs1"
    m2_manifest_document: dict[str, JsonValue] = {
        "v": 1,
        "milestone": "M2",
        "verdict": "PASS",
        "head": HEAD,
        "starting_plan_sha256": STARTING_PLAN_SHA256,
        "scope": [
            {"path": path, "sha256": "01" * 32} for path in sorted(REQUIRED_SCOPE_PATHS)
        ],
        "receipts": [
            {
                "kind": policy.kind,
                "path": policy.path,
                "sha256": "02" * 32,
            }
            for policy in RECEIPT_POLICIES
        ],
        "boundaries": dict(REQUIRED_BOUNDARIES),
    }
    _write(m2_manifest_path, m2_manifest_document)
    m2_manifest_path.chmod(0o600)
    m2_manifest_sha256 = hashlib.sha256(m2_manifest_path.read_bytes()).hexdigest()
    bundle_fingerprint = _fingerprint(
        b"health-bridge/mailbox/m3/v1/qa-bundle",
        QA_BUNDLE,
    )
    container_fingerprint = _fingerprint(
        b"health-bridge/mailbox/m3/v1/qa-container",
        QA_CONTAINER,
    )
    anchor: dict[str, JsonValue] = {
        "v": 1,
        "kind": "health_bridge.mailbox_m3_anchor.v1",
        "run_id": RUN_ID,
        "challenge": CHALLENGE,
        "head": HEAD,
        "m2_manifest_sha256": m2_manifest_sha256,
        "qa_bundle_identifier": QA_BUNDLE,
        "qa_container_identifier": QA_CONTAINER,
        "qa_bundle_fingerprint": bundle_fingerprint,
        "qa_container_fingerprint": container_fingerprint,
        "production_seal_fingerprint": seal_fingerprint,
        "device_report_public_key": _public(device_key),
        "receiver_receipt_public_key": _public(receiver_key),
        "parent_receipt_public_key": _public(parent_key),
        "full_identifiers": list(FULL_IDENTIFIERS),
        "created_at_ms": now_ms - 1_000,
        "expires_at_ms": now_ms - 1_000 + 3_600_000,
        "consumed": False,
    }
    anchor_path = root / "validator-anchor.hbjcs1"
    _write(anchor_path, anchor)
    anchor_path.chmod(0o600)
    report = _signed(
        {
            "v": 1,
            "kind": "health_bridge.mailbox_m3_device_report.v1",
            "run_id": RUN_ID,
            "challenge": CHALLENGE,
            "head": HEAD,
            "qa_bundle_fingerprint": bundle_fingerprint,
            "qa_container_fingerprint": container_fingerprint,
            "executable_sha256": "33" * 32,
            "device_fingerprint": "55" * 8,
            "device_model": "SyntheticPhone1,1",
            "os_version": "18.0-synthetic",
            "started_at_ms": now_ms - 500,
            "finished_at_ms": now_ms - 100,
            "transition_counts": {
                "collected": 1,
                "encrypted": 1,
                "published": 1,
                "provider_observed": 1,
                "ack_verified": 1,
                "committed_finalized": 1,
                "retryable_failure": 1,
                "terminal_failure": 0,
            },
            "synthetic_payload_sha256": SYNTHETIC_PAYLOAD_SHA256,
            "envelope_sha256": hashlib.sha256(
                b"synthetic finalized encrypted envelope"
            ).hexdigest(),
            "envelope_reuse_count": 1,
            "lifecycle_epoch": 2,
            "restart_epoch": 1,
            "finalization_count": 1,
            "fault_injection_count": 1,
            "foreground_observation_count": 1,
            "background_observation_count": 1,
            "protected_data_available_count": 1,
            "protected_data_unavailable_count": 1,
            "protection_state": "available",
        },
        device_key,
        DEVICE_SIGNATURE_DOMAIN,
    )
    report_path = root / "device-report.hbjcs1"
    _write(report_path, report)
    receipt_paths: list[Path] = []
    receipt_bindings: list[JsonValue] = []
    issued_receipts = _owner_issued_receipts(
        root,
        report_path,
        anchor_path,
        seal,
        seal_fingerprint,
        receiver_key,
        parent_key,
        now_ms,
        archive_target,
        inventory_before_qa_bundles,
        inventory_after_qa_bundle,
    )
    for receipt in issued_receipts:
        scenario = receipt["scenario"]
        assert isinstance(scenario, str)
        path = receipts_dir / f"{scenario}.hbjcs1"
        _write(path, receipt)
        receipt_paths.append(path)
        receipt_bindings.append(
            {
                "kind": "scenario_receipt",
                "scenario": scenario,
                "path": f"receipts/{path.name}",
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )
    fixture_root = Path(__file__).resolve().parents[1] / "fixtures/mailbox_m3"
    parent_receipt_paths: list[Path] = []
    parent_receipt_bindings: list[JsonValue] = []
    for receipt_kind, contract in PARENT_RECEIPTS.items():
        relative_path = contract.path
        path = root / relative_path
        _ = path.write_bytes((fixture_root / relative_path).read_bytes())
        path.chmod(0o600)
        parent_receipt_paths.append(path)
        parent_receipt_bindings.append(
            {
                "kind": "parent_receipt",
                "receipt_kind": receipt_kind,
                "path": relative_path,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )
    manifest: dict[str, JsonValue] = {
        "v": 1,
        "kind": "health_bridge.mailbox_m3_manifest.v1",
        "verdict": "PASS" if prerequisites_available else "HOLD",
        "head": HEAD,
        "m2_manifest_sha256": m2_manifest_sha256,
        "qa_bundle_fingerprint": bundle_fingerprint,
        "qa_container_fingerprint": container_fingerprint,
        "production_seal_fingerprint": seal_fingerprint,
        "prerequisites": {
            "signing": "available" if prerequisites_available else "unavailable",
            "container": "available",
            "device": "available",
            "account": "available",
            "qa_authorization": "available",
        },
        "parent_receipts": parent_receipt_bindings,
        "device_report": {
            "kind": "device_report",
            "path": report_path.name,
            "sha256": hashlib.sha256(report_path.read_bytes()).hexdigest(),
        },
        "scenario_receipts": receipt_bindings,
    }
    manifest_path = root / "m3-manifest.hbjcs1"
    _write(manifest_path, manifest)
    return M3Fixture(
        root=root,
        m2_manifest=m2_manifest_path,
        manifest=manifest_path,
        anchor=anchor_path,
        report=report_path,
        parent_receipts=tuple(parent_receipt_paths),
        receipts=tuple(receipt_paths),
        production_seal=seal_path,
        production_seal_anchor_sha256=seal_anchor,
    )


def refresh_binding(fixture: M3Fixture, path: Path) -> None:
    manifest = read(fixture.manifest)
    if path == fixture.report:
        binding = manifest["device_report"]
        assert isinstance(binding, dict)
        binding["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    else:
        bindings = manifest["scenario_receipts"]
        assert isinstance(bindings, list)
        for binding in bindings:
            assert isinstance(binding, dict)
            if binding["path"] == f"receipts/{path.name}":
                binding["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    write(fixture.manifest, manifest)


def run(fixture: M3Fixture) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            "scripts/validate-mailbox-m3-v1.py",
            "--strict",
            "--commit",
            HEAD,
            "--manifest",
            str(fixture.manifest),
            "--m2-manifest",
            str(fixture.m2_manifest),
            "--anchor",
            str(fixture.anchor),
            "--production-seal",
            str(fixture.production_seal),
            "--production-seal-anchor-sha256",
            fixture.production_seal_anchor_sha256,
        ],
        cwd=Path(__file__).resolve().parents[2],
        check=False,
        capture_output=True,
        text=True,
    )

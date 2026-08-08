from __future__ import annotations

import hashlib
from typing import TYPE_CHECKING

import pytest

from health_bridge.contract._hbjcs1 import hbjcs1_encode
from health_bridge.mailbox_qa.archive_provenance import (
    ArchiveProvenanceError,
    QAArchiveProvenanceV1,
    load_archive_provenance,
    write_archive_provenance,
)
from health_bridge.mailbox_qa.production_seal import (
    ProductionSealError,
    QAIsolationRequest,
    inventory_observes_app_path,
    load_production_identity_seal,
    validate_qa_isolation,
)
from tests.scripts.production_seal_support import (
    synthetic_qa_request,
    write_synthetic_production_seal,
)

if TYPE_CHECKING:
    from pathlib import Path


def test_signed_private_seal_allows_only_exact_derived_qa_identity(
    tmp_path: Path,
) -> None:
    # Given: a canonical signed synthetic seal and a disjoint QA runtime.
    seal_path = tmp_path / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(seal_path)
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)

    # When: the caller-private seal is loaded and the derived QA identity checked.
    seal = load_production_identity_seal(seal_path, anchor)
    fingerprint = validate_qa_isolation(seal, synthetic_qa_request(runtime))

    # Then: only a short run-scoped seal fingerprint leaves the boundary.
    assert len(fingerprint) == 16
    assert fingerprint == hashlib.sha256(seal_path.read_bytes()).hexdigest()[:16]


def test_inventory_app_path_accepts_only_exact_local_file_url() -> None:
    expected = "/private/var/containers/Bundle/Application/opaque/App.app"

    assert inventory_observes_app_path((f"file://{expected}",), expected)
    assert inventory_observes_app_path((expected,), expected)
    assert not inventory_observes_app_path((f"file://remote{expected}",), expected)
    assert not inventory_observes_app_path((f"file://{expected}.other",), expected)


def test_signed_seal_accepts_observed_production_app_without_icloud_capability(
    tmp_path: Path,
) -> None:
    # Given: the daily-use production app predates iCloud mailbox capability.
    seal_path = tmp_path / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(
        seal_path,
        icloud_containers=[],
    )
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)

    # When: the dedicated QA identity is derived from the sealed bundle identity.
    seal = load_production_identity_seal(seal_path, anchor)

    # Then: the absence of a production iCloud entitlement does not weaken any
    # other exact QA derivation or collision check.
    assert validate_qa_isolation(seal, synthetic_qa_request(runtime))


def test_exact_qa_keychain_service_is_safe_when_production_uses_receiver_suffix(
    tmp_path: Path,
) -> None:
    # Given: production stores its direct-HTTP token under <bundle>.receiver.
    seal_path = tmp_path / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(
        seal_path,
        keychain_services=["dev.example.healthbridge.receiver"],
    )
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)

    # When / Then: the exact derived QA service remains disjoint while direct
    # reuse of the sealed receiver service is still covered by collision tests.
    seal = load_production_identity_seal(seal_path, anchor)
    assert validate_qa_isolation(seal, synthetic_qa_request(runtime))


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("bundle_identifier", "dev.example.healthbridge"),
        ("container_identifier", "iCloud.dev.example.healthbridge"),
        ("url_scheme", "healthbridge"),
        ("keychain_service", "dev.example.healthbridge"),
        ("outbox_root", "HealthBridgeMailbox"),
        ("display_identity", "Synthetic Health Bridge"),
        ("receiver_port", 28765),
        ("database_namespace", "health-bridge-production"),
    ],
)
def test_seal_rejects_every_production_collision(
    tmp_path: Path,
    field: str,
    value: str | int,
) -> None:
    # Given: a valid seal and one QA value replaced with sealed production state.
    seal_path = tmp_path / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(seal_path)
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    values = synthetic_qa_request(runtime).model_dump()
    values[field] = value

    # When / Then: validation fails closed without exposing the colliding value.
    seal = load_production_identity_seal(seal_path, anchor)
    with pytest.raises(ProductionSealError, match="production identity seal rejected"):
        _ = validate_qa_isolation(seal, QAIsolationRequest.model_validate(values))


def test_seal_rejects_missing_anchor_bad_signature_and_symlink(
    tmp_path: Path,
) -> None:
    # Given: separate invalid trust-boundary attempts.
    seal_path = tmp_path / "production-seal.hbjcs1"
    anchor, document = write_synthetic_production_seal(seal_path)
    linked = tmp_path / "linked.hbjcs1"
    linked.symlink_to(seal_path)
    document["signature"] = "A" * 86
    bad = tmp_path / "bad.hbjcs1"
    _ = bad.write_bytes(hbjcs1_encode(document))
    bad.chmod(0o600)

    # When / Then: absent trust, invalid signatures, and links all fail closed.
    with pytest.raises(ProductionSealError):
        _ = load_production_identity_seal(seal_path, "")
    with pytest.raises(ProductionSealError):
        _ = load_production_identity_seal(bad, anchor)
    with pytest.raises(ProductionSealError):
        _ = load_production_identity_seal(linked, anchor)


def test_archive_provenance_is_private_canonical_and_seal_bound(
    tmp_path: Path,
) -> None:
    # Given: build-observed hashes and a short synthetic production seal binding.
    path = tmp_path / "qa-archive-provenance.hbjcs1"
    provenance = QAArchiveProvenanceV1(
        v=1,
        kind="health_bridge.mailbox_qa_archive_provenance.v1",
        source_commit="6eb12a4fb29543e691c7e930f385dc4f9964598f",
        production_seal_fingerprint="12" * 8,
        executable_sha256="34" * 32,
        codesign_identity_sha256="56" * 32,
        scheme="HealthBridgeCompanionMailboxQA",
        target="HealthBridgeCompanionMailboxQA",
    )

    # When: the build provenance is written and reloaded.
    write_archive_provenance(path, provenance)

    # Then: canonical private bytes round-trip and links are rejected.
    assert load_archive_provenance(path) == provenance
    assert path.stat().st_mode & 0o777 == 0o600
    linked = tmp_path / "linked-provenance.hbjcs1"
    linked.symlink_to(path)
    with pytest.raises(ArchiveProvenanceError):
        _ = load_archive_provenance(linked)

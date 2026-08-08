from __future__ import annotations

import hashlib
import time
from typing import TYPE_CHECKING, Final

from pydantic import ValidationError

from health_bridge._milestone_files import read_scoped_regular_file
from health_bridge.contract._hbjcs1 import HBJCS1Error, hbjcs1_decode, hbjcs1_encode
from health_bridge.mailbox_m2_validator import M2Manifest
from health_bridge.mailbox_qa.m3_errors import M3FailureCode, M3ValidationError
from health_bridge.mailbox_qa.m3_evidence import (
    validate_device_report,
    validate_parent_receipts,
    validate_scenario_receipts,
)
from health_bridge.mailbox_qa.m3_files import (
    external_file,
    parse_document,
    read_document,
    validate_anchor_file,
)
from health_bridge.mailbox_qa.m3_models import M3AnchorV1, M3ManifestV1
from health_bridge.mailbox_qa.m3_privacy import (
    M3ForbiddenDataError,
    M3ForbiddenIdentifierError,
    scan_evidence_privacy,
)
from health_bridge.mailbox_qa.m3_signatures import short_fingerprint
from health_bridge.mailbox_qa.production_seal import (
    ProductionIdentitySealV1,
    ProductionSealError,
    load_production_identity_seal,
    production_seal_fingerprint,
)
from health_bridge.private_files import write_private_text_file

if TYPE_CHECKING:
    from pathlib import Path

ANCHOR_LIFETIME_MS: Final = 3_600_000


def validate_m3_v1(  # noqa: PLR0911, PLR0913
    manifest_path: Path,
    m2_manifest_path: Path,
    anchor_path: Path,
    production_seal_path: Path,
    *,
    production_seal_anchor_sha256: str,
    expected_commit: str,
    now_ms: int | None = None,
) -> tuple[int, str]:
    try:
        manifest_root, manifest = _load_manifest(manifest_path)
    except (
        M3ValidationError,
        M3ForbiddenDataError,
        M3ForbiddenIdentifierError,
        OSError,
        ProductionSealError,
    ):
        return 1, "FAIL schema_invalid\n"
    try:
        seal = load_production_identity_seal(
            production_seal_path,
            production_seal_anchor_sha256,
        )
        return _validate_m3(
            manifest_root,
            m2_manifest_path,
            anchor_path,
            manifest,
            seal,
            expected_commit=expected_commit,
            now_ms=now_ms,
        )
    except M3ForbiddenIdentifierError:
        return 1, "FAIL M3 forbidden_identifier\n"
    except M3ForbiddenDataError:
        return 1, "FAIL M3 forbidden_data\n"
    except M3ValidationError as exc:
        return 1, f"FAIL M3 {exc.code.value}\n"
    except OSError:
        return 1, "FAIL M3 schema_invalid\n"
    except ProductionSealError:
        return 1, "FAIL M3 production_seal_invalid\n"


def _load_manifest(manifest_path: Path) -> tuple[Path, M3ManifestV1]:
    manifest_root, manifest_name = external_file(manifest_path)
    document = read_document(manifest_root, manifest_name)
    scan_evidence_privacy(document, full_identifiers=frozenset())
    return manifest_root, parse_document(document, M3ManifestV1)


def _validate_m3(  # noqa: PLR0913
    manifest_root: Path,
    m2_manifest_path: Path,
    anchor_path: Path,
    manifest: M3ManifestV1,
    production_seal: ProductionIdentitySealV1,
    *,
    expected_commit: str,
    now_ms: int | None,
) -> tuple[int, str]:
    if manifest.head != expected_commit:
        raise M3ValidationError(M3FailureCode.STALE_COMMIT)
    if not manifest.prerequisites.available:
        if manifest.verdict == "HOLD":
            return 3, "HOLD M3 external_prerequisite\n"
        raise M3ValidationError(M3FailureCode.PREREQUISITE_VERDICT)
    if manifest.verdict != "PASS":
        raise M3ValidationError(M3FailureCode.MANIFEST_VERDICT)
    anchor_root, anchor_name = external_file(anchor_path)
    anchor = parse_document(read_document(anchor_root, anchor_name), M3AnchorV1)
    validate_anchor_file(anchor_path)
    if not _m2_preserved(m2_manifest_path, manifest, anchor):
        raise M3ValidationError(M3FailureCode.STALE_M2)
    current_ms = time.time_ns() // 1_000_000 if now_ms is None else now_ms
    _validate_anchor(
        anchor,
        manifest,
        production_seal,
        expected_commit,
        current_ms,
    )
    validate_parent_receipts(manifest_root, manifest, anchor)
    validate_device_report(manifest_root, manifest, anchor)
    validate_scenario_receipts(manifest_root, manifest, anchor)
    consumed = anchor.model_copy(update={"consumed": True})
    write_private_text_file(
        anchor_path,
        hbjcs1_encode(consumed.model_dump(mode="json")).decode("utf-8"),
    )
    return 0, "PASS M3\n"


def _m2_preserved(
    m2_manifest_path: Path,
    manifest: M3ManifestV1,
    anchor: M3AnchorV1,
) -> bool:
    try:
        m2_root, m2_name = external_file(m2_manifest_path)
        content = read_scoped_regular_file(m2_root, m2_name)
        if content is None:
            return False
        document = hbjcs1_decode(content)
        if not isinstance(document, dict) or hbjcs1_encode(document) != content:
            return False
        m2_manifest = M2Manifest.model_validate_json(content)
    except (HBJCS1Error, M3ValidationError, OSError, ValidationError):
        return False
    digest = hashlib.sha256(content).hexdigest()
    return (
        digest == manifest.m2_manifest_sha256 == anchor.m2_manifest_sha256
        and m2_manifest.verdict == "PASS"
        and m2_manifest.head == manifest.head
    )


def _validate_anchor(
    anchor: M3AnchorV1,
    manifest: M3ManifestV1,
    production_seal: ProductionIdentitySealV1,
    expected_commit: str,
    current_ms: int,
) -> None:
    approved_qa_bundles = {
        f"{production_seal.bundle_identifier}.mailboxqa",
        f"{production_seal.bundle_identifier}.publicdocuments.mailboxqa",
    }
    identifiers_are_qa = (
        anchor.qa_bundle_identifier in approved_qa_bundles
        and anchor.qa_container_identifier == f"iCloud.{anchor.qa_bundle_identifier}"
        and anchor.qa_bundle_identifier != production_seal.bundle_identifier
        and anchor.qa_container_identifier not in production_seal.icloud_containers
    )
    binding_matches = (
        anchor.head == expected_commit
        and anchor.qa_bundle_fingerprint == manifest.qa_bundle_fingerprint
        and anchor.qa_container_fingerprint == manifest.qa_container_fingerprint
        and anchor.production_seal_fingerprint
        == manifest.production_seal_fingerprint
        == production_seal_fingerprint(production_seal)
        and short_fingerprint(
            b"health-bridge/mailbox/m3/v1/qa-bundle",
            anchor.qa_bundle_identifier,
        )
        == anchor.qa_bundle_fingerprint
        and short_fingerprint(
            b"health-bridge/mailbox/m3/v1/qa-container",
            anchor.qa_container_identifier,
        )
        == anchor.qa_container_fingerprint
        and anchor.expires_at_ms == anchor.created_at_ms + ANCHOR_LIFETIME_MS
        and anchor.created_at_ms <= current_ms <= anchor.expires_at_ms
        and not anchor.consumed
    )
    if not identifiers_are_qa or not binding_matches:
        raise M3ValidationError(M3FailureCode.ANCHOR_MISMATCH)


__all__ = ["validate_m3_v1"]

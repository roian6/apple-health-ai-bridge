from __future__ import annotations

import time
from typing import TYPE_CHECKING, Final, TypeVar

from pydantic import BaseModel, ValidationError

from health_bridge._mailbox_evidence_models import (
    AnchorState,
    CodeSignEvidence,
    InstallReceipt,
    PhysicalHarness,
    PhysicalPrerequisites,
    PhysicalReport,
)
from health_bridge._mailbox_evidence_privacy import (
    ForbiddenDataError,
    ForbiddenIdentifierError,
    scan_report_privacy,
)
from health_bridge._mailbox_evidence_state import (
    anchor_lock,
    consume_binding,
    full_identifiers,
    resolve_anchor,
)
from health_bridge._mailbox_evidence_types import (
    EvidenceFailureCode,
    EvidenceHold,
    EvidencePass,
    MailboxEvidenceError,
)
from health_bridge._mailbox_evidence_validation import (
    MailboxArtifactSet,
    validate_artifacts,
    validate_fingerprints,
    validate_scenarios,
    verify_signature,
)
from health_bridge.contract._hbjcs1 import HBJCS1Error, JsonValue, hbjcs1_decode

if TYPE_CHECKING:
    from pathlib import Path

MAX_DOCUMENT_BYTES: Final = 1_048_576
_ModelT = TypeVar("_ModelT", bound=BaseModel)


def validate_evidence_directory(
    evidence_directory: Path,
    *,
    expected_commit: str,
    now_ms: int | None = None,
) -> EvidencePass | EvidenceHold:
    current_ms = time.time_ns() // 1_000_000 if now_ms is None else now_ms
    prerequisites = _parse_model(
        evidence_directory / "prerequisites.hbjcs1",
        PhysicalPrerequisites,
    )
    if not prerequisites.available:
        return EvidenceHold()
    state_path = evidence_directory / "validator-local-state.hbjcs1"
    with anchor_lock(state_path):
        state_document = _read_object(state_path)
        state = _validate_model(state_document, AnchorState)
        harness = _parse_model(evidence_directory / "harness.hbjcs1", PhysicalHarness)
        codesign = _parse_model(
            evidence_directory / "codesign.hbjcs1",
            CodeSignEvidence,
        )
        install = _parse_model(
            evidence_directory / "install-receipt.hbjcs1",
            InstallReceipt,
        )
        report_document = _read_object(evidence_directory / "report.hbjcs1")
        try:
            scan_report_privacy(
                report_document,
                full_identifiers=full_identifiers(state),
            )
        except ForbiddenIdentifierError as exc:
            raise MailboxEvidenceError(
                EvidenceFailureCode.FORBIDDEN_IDENTIFIER
            ) from exc
        except ForbiddenDataError as exc:
            raise MailboxEvidenceError(EvidenceFailureCode.FORBIDDEN_DATA) from exc
        report = _validate_model(report_document, PhysicalReport)
        binding, connection = resolve_anchor(state, harness, report, current_ms)
        validate_artifacts(
            MailboxArtifactSet(
                harness=harness,
                codesign=codesign,
                install=install,
                report=report,
            ),
            expected_commit,
            current_ms,
        )
        validate_fingerprints(state, connection, report)
        validate_scenarios(report)
        verify_signature(report_document, report, connection)
        consume_binding(state, binding, state_path)
    return EvidencePass()


def _read_object(path: Path) -> dict[str, JsonValue]:
    try:
        encoded = path.read_bytes()
        if len(encoded) > MAX_DOCUMENT_BYTES:
            raise MailboxEvidenceError(EvidenceFailureCode.SCHEMA_INVALID)
        match hbjcs1_decode(encoded):
            case dict() as document:
                return document
            case _:
                raise MailboxEvidenceError(EvidenceFailureCode.SCHEMA_INVALID)
    except (OSError, HBJCS1Error) as exc:
        raise MailboxEvidenceError(EvidenceFailureCode.SCHEMA_INVALID) from exc


def _parse_model(path: Path, model: type[_ModelT]) -> _ModelT:
    return _validate_model(_read_object(path), model)


def _validate_model(document: dict[str, JsonValue], model: type[_ModelT]) -> _ModelT:
    try:
        return model.model_validate(document)
    except ValidationError as exc:
        raise MailboxEvidenceError(EvidenceFailureCode.SCHEMA_INVALID) from exc


__all__ = [
    "EvidenceHold",
    "EvidencePass",
    "MailboxEvidenceError",
    "validate_evidence_directory",
]

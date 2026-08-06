from __future__ import annotations

from enum import StrEnum


class M3FailureCode(StrEnum):
    ANCHOR_MISMATCH = "anchor_mismatch"
    ANCHOR_UNSAFE = "anchor_unsafe"
    ARTIFACT_BINDING = "artifact_binding"
    MANIFEST_VERDICT = "manifest_verdict"
    PREREQUISITE_VERDICT = "prerequisite_verdict"
    SCENARIO_MISSING = "scenario_missing"
    SCHEMA_INVALID = "schema_invalid"
    SIGNATURE_INVALID = "signature_invalid"
    STALE_COMMIT = "stale_commit"
    STALE_M2 = "stale_m2"
    STALE_PARENT_RECEIPT = "stale_parent_receipt"


class M3ValidationError(Exception):
    code: M3FailureCode

    def __init__(self, code: M3FailureCode) -> None:
        self.code = code
        super().__init__(code.value)


__all__ = ["M3FailureCode", "M3ValidationError"]

from __future__ import annotations

from enum import StrEnum
from typing import ClassVar, final

from typing_extensions import override


class EvidenceFailureCode(StrEnum):
    SCHEMA_INVALID = "schema_invalid"
    FORBIDDEN_DATA = "forbidden_data"
    FORBIDDEN_IDENTIFIER = "forbidden_identifier"
    ANCHORED_LOOKUP_MISSING = "anchored_lookup_missing"
    ANCHORED_LOOKUP_AMBIGUOUS = "anchored_lookup_ambiguous"
    CHALLENGE_REUSED = "challenge_reused"
    CHALLENGE_STALE = "challenge_stale"
    FINGERPRINT_MISMATCH = "fingerprint_mismatch"
    FINGERPRINT_COLLISION = "fingerprint_collision"
    ARTIFACT_BINDING_MISMATCH = "artifact_binding_mismatch"
    SCENARIO_MISSING = "scenario_missing"
    SCENARIO_FAILED = "scenario_failed"
    SIGNATURE_INVALID = "signature_invalid"
    ANCHOR_STATE_UNSAFE = "anchor_state_unsafe"


@final
class MailboxEvidenceError(Exception):
    __slots__: ClassVar[tuple[str]] = ("code",)
    code: EvidenceFailureCode

    def __init__(self, code: EvidenceFailureCode) -> None:
        self.code = code
        super().__init__(code.value)

    @override
    def __str__(self) -> str:
        return self.code.value


@final
class EvidencePass:
    __slots__: ClassVar[tuple[()]] = ()


@final
class EvidenceHold:
    __slots__: ClassVar[tuple[()]] = ()

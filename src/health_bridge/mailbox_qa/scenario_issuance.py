from __future__ import annotations

import base64
import hashlib
import os
import stat
from dataclasses import dataclass
from typing import TYPE_CHECKING, Annotated, ClassVar, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    JsonValue,
    hbjcs1_decode,
    hbjcs1_encode,
)
from health_bridge.mailbox_qa.scenario_contract import (
    EVIDENCE_CLASSES,
    RECEIPT_SIGNATURE_DOMAIN,
    SCENARIO_CHECKS,
    SCENARIO_PRODUCERS,
)

if TYPE_CHECKING:
    from collections.abc import Mapping
    from pathlib import Path

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


class ScenarioIssuanceError(Exception):
    pass


Hex16 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{16}$")]
Hex32 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
Hex40 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40}$")]
Base64URL32 = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{43}$")]


class ScenarioReceiptContextV1(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    v: Literal[1]
    kind: Literal["health_bridge.mailbox_qa_receipt_context.v1"]
    run_id: Hex32
    challenge: Base64URL32
    head: Hex40
    qa_bundle_fingerprint: Hex16
    qa_container_fingerprint: Hex16
    created_at_ms: Annotated[int, Field(ge=0)]
    expires_at_ms: Annotated[int, Field(ge=0)]


@dataclass(frozen=True, slots=True)
class OperationObservation:
    scenario: str
    producer: str
    run_id: str
    challenge: str
    head: str
    qa_bundle_fingerprint: str
    qa_container_fingerprint: str
    operation_id: str
    started_at_ms: int
    finished_at_ms: int
    facts: Mapping[str, bool]
    observed_material: bytes


def issue_scenario_receipt(
    observation: OperationObservation,
    owner_key: Ed25519PrivateKey,
) -> dict[str, JsonValue]:
    expected_checks = SCENARIO_CHECKS.get(observation.scenario)
    expected_producer = SCENARIO_PRODUCERS.get(observation.scenario)
    facts = tuple(name for name, observed in observation.facts.items() if observed)
    if (
        expected_checks is None
        or observation.producer != expected_producer
        or facts != expected_checks
        or set(observation.facts) != set(expected_checks)
        or observation.started_at_ms > observation.finished_at_ms
        or len(observation.observed_material) == 0
    ):
        raise ScenarioIssuanceError
    checks: list[JsonValue] = list(expected_checks)
    unsigned: dict[str, JsonValue] = {
        "v": 1,
        "kind": "health_bridge.mailbox_m3_scenario_receipt.v1",
        "scenario": observation.scenario,
        "producer": observation.producer,
        "evidence_class": EVIDENCE_CLASSES.get(
            observation.scenario,
            "receiver_commit",
        ),
        "issuance": "operation_v1",
        "operation_id": observation.operation_id,
        "observation_sha256": hashlib.sha256(observation.observed_material).hexdigest(),
        "verdict": "PASS",
        "run_id": observation.run_id,
        "challenge": observation.challenge,
        "head": observation.head,
        "qa_bundle_fingerprint": observation.qa_bundle_fingerprint,
        "qa_container_fingerprint": observation.qa_container_fingerprint,
        "started_at_ms": observation.started_at_ms,
        "finished_at_ms": observation.finished_at_ms,
        "assertion_count": len(expected_checks),
        "checks": checks,
    }
    signature = owner_key.sign(
        RECEIPT_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned)
    )
    return {
        **unsigned,
        "signature": base64.urlsafe_b64encode(signature).rstrip(b"=").decode("ascii"),
    }


def load_receipt_context(path: Path) -> ScenarioReceiptContextV1:
    try:
        entry = path.lstat()
        encoded = path.read_bytes()
    except OSError as exc:
        raise ScenarioIssuanceError from exc
    if (
        not stat.S_ISREG(entry.st_mode)
        or entry.st_nlink != 1
        or (os.name == "posix" and entry.st_mode & 0o077)
    ):
        raise ScenarioIssuanceError
    try:
        document = hbjcs1_decode(encoded)
        context = ScenarioReceiptContextV1.model_validate(document)
    except (ValueError, TypeError, HBJCS1Error) as exc:
        raise ScenarioIssuanceError from exc
    if not isinstance(document, dict) or context.created_at_ms >= context.expires_at_ms:
        raise ScenarioIssuanceError
    return context


__all__ = [
    "OperationObservation",
    "ScenarioIssuanceError",
    "ScenarioReceiptContextV1",
    "issue_scenario_receipt",
    "load_receipt_context",
]

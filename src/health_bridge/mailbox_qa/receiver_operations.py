from __future__ import annotations

import hashlib
import os
import stat
import time
import uuid
from typing import TYPE_CHECKING, Annotated, ClassVar, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_encode
from health_bridge.mailbox_qa.lifecycle import import_once
from health_bridge.mailbox_qa.scenario_issuance import (
    OperationObservation,
    ScenarioReceiptContextV1,
    issue_scenario_receipt,
)
from health_bridge.private_files import write_private_text_file

if TYPE_CHECKING:
    from pathlib import Path

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    from health_bridge.mailbox_qa.receiver import QAReceiverConfig

Hex64 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]


class ReceiverOperationObservationV1(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    v: Literal[1]
    kind: Literal["health_bridge.mailbox_qa_receiver_operation.v1"]
    operation: Literal[
        "one_shot_importer",
        "duplicate_identical",
        "conflict_rejected",
    ]
    imported: Annotated[int, Field(ge=0)]
    idempotent: Annotated[int, Field(ge=0)]
    quarantined: Annotated[int, Field(ge=0)]
    retryable: Annotated[int, Field(ge=0)]
    conflict: Annotated[int, Field(ge=0)]
    skipped: Annotated[int, Field(ge=0)]
    delivery_sha256_before: Hex64
    delivery_sha256_after: Hex64
    ack_count_before: Annotated[int, Field(ge=0)]
    ack_count_after: Annotated[int, Field(ge=0)]
    injected_local_conflict: bool
    started_at_ms: Annotated[int, Field(ge=0)]
    finished_at_ms: Annotated[int, Field(ge=0)]


def run_receiver_operation(
    config: QAReceiverConfig,
    operation: Literal[
        "one_shot_importer",
        "duplicate_identical",
        "conflict_rejected",
    ],
) -> ReceiverOperationObservationV1:
    delivery = _single_delivery(config)
    before = _read_regular(delivery)
    ack_before = _ack_count(config)
    started_at_ms = time.time_ns() // 1_000_000
    injected = operation == "conflict_rejected"
    if injected:
        conflicting = bytearray(before)
        conflicting[-1] ^= 1
        _replace_private(delivery, bytes(conflicting))
    try:
        counts = import_once(config)
    finally:
        if injected:
            _replace_private(delivery, before)
    after = _read_regular(delivery)
    return ReceiverOperationObservationV1(
        v=1,
        kind="health_bridge.mailbox_qa_receiver_operation.v1",
        operation=operation,
        imported=counts[0],
        idempotent=counts[1],
        quarantined=counts[2],
        retryable=counts[3],
        conflict=counts[4],
        skipped=counts[5],
        delivery_sha256_before=hashlib.sha256(before).hexdigest(),
        delivery_sha256_after=hashlib.sha256(after).hexdigest(),
        ack_count_before=ack_before,
        ack_count_after=_ack_count(config),
        injected_local_conflict=injected,
        started_at_ms=started_at_ms,
        finished_at_ms=time.time_ns() // 1_000_000,
    )


def write_receiver_operation(
    path: Path,
    observation: ReceiverOperationObservationV1,
) -> None:
    write_private_text_file(
        path,
        hbjcs1_encode(observation.model_dump(mode="json")).decode("utf-8"),
    )


def issue_receiver_receipts(
    observation: ReceiverOperationObservationV1,
    context: ScenarioReceiptContextV1,
    owner_key: Ed25519PrivateKey,
) -> tuple[dict[str, JsonValue], ...]:
    scenarios = {
        "one_shot_importer": (
            "one_shot_importer",
            "strict_receiver_parse_without_reserialization",
        ),
        "duplicate_identical": ("duplicate_identical",),
        "conflict_rejected": ("conflict_rejected",),
    }[observation.operation]
    material = hbjcs1_encode(observation.model_dump(mode="json"))
    receipts: list[dict[str, JsonValue]] = []
    for scenario in scenarios:
        facts = _receiver_facts(observation, scenario)
        receipts.append(
            issue_scenario_receipt(
                OperationObservation(
                    scenario=scenario,
                    producer="qa_receiver",
                    run_id=context.run_id,
                    challenge=context.challenge,
                    head=context.head,
                    qa_bundle_fingerprint=context.qa_bundle_fingerprint,
                    qa_container_fingerprint=context.qa_container_fingerprint,
                    operation_id=hashlib.sha256(
                        material + b"\0" + scenario.encode()
                    ).hexdigest()[:32],
                    started_at_ms=observation.started_at_ms,
                    finished_at_ms=observation.finished_at_ms,
                    facts=facts,
                    observed_material=material,
                ),
                owner_key,
            )
        )
    return tuple(receipts)


def _receiver_facts(
    value: ReceiverOperationObservationV1,
    scenario: str,
) -> dict[str, bool]:
    unchanged = value.delivery_sha256_before == value.delivery_sha256_after
    if scenario == "one_shot_importer":
        return {
            "single_import_run": value.imported == 1,
            "delivery_committed_once": (
                value.idempotent == 0
                and value.quarantined == 0
                and value.ack_count_after == 1
            ),
        }
    if scenario == "strict_receiver_parse_without_reserialization":
        return {
            "strict_parse_succeeded": value.imported == 1,
            "no_reserialization": unchanged,
        }
    if scenario == "duplicate_identical":
        return {
            "duplicate_classified": value.idempotent == 1,
            "no_second_commit": value.imported == 0 and value.ack_count_after == 1,
        }
    if scenario == "conflict_rejected":
        return {
            "conflicting_same_name_rejected": value.injected_local_conflict,
            "quarantine_observed": value.quarantined == 1,
            "no_conflicting_commit": (
                value.imported == 0 and value.ack_count_after == value.ack_count_before
            ),
        }
    raise ValueError


def _single_delivery(config: QAReceiverConfig) -> Path:
    deliveries = [
        path
        for path in _single_mailbox(config).joinpath("deliveries").iterdir()
        if path.suffix == ".hbd"
    ]
    if len(deliveries) != 1:
        raise RuntimeError
    _ = _read_regular(deliveries[0])
    return deliveries[0]


def _single_mailbox(config: QAReceiverConfig) -> Path:
    candidates = [
        device
        for receiver in config.mailbox_root.iterdir()
        if receiver.is_dir() and not receiver.is_symlink()
        for device in receiver.iterdir()
        if device.is_dir() and not device.is_symlink()
    ]
    if len(candidates) != 1:
        raise RuntimeError
    return candidates[0]


def _ack_count(config: QAReceiverConfig) -> int:
    return sum(
        1
        for path in _single_mailbox(config).joinpath("acks").iterdir()
        if path.suffix == ".hba" and path.is_file() and not path.is_symlink()
    )


def _read_regular(path: Path) -> bytes:
    entry = path.lstat()
    if not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1:
        raise RuntimeError
    return path.read_bytes()


def _replace_private(path: Path, content: bytes) -> None:
    temporary = path.with_name(f"{path.name}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
            _ = stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        _ = temporary.replace(path)
    except OSError:
        temporary.unlink(missing_ok=True)
        raise


__all__ = [
    "ReceiverOperationObservationV1",
    "issue_receiver_receipts",
    "run_receiver_operation",
    "write_receiver_operation",
]

from __future__ import annotations

import fcntl
import os
import stat
from contextlib import contextmanager
from typing import TYPE_CHECKING

from health_bridge._mailbox_evidence_types import (
    EvidenceFailureCode,
    MailboxEvidenceError,
)
from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_encode
from health_bridge.private_files import ensure_private_file, write_private_text_file

if TYPE_CHECKING:
    from collections.abc import Generator
    from pathlib import Path

    from health_bridge._mailbox_evidence_models import (
        AnchorBinding,
        AnchoredConnection,
        AnchorState,
        PhysicalHarness,
        PhysicalReport,
    )


@contextmanager
def anchor_lock(state_path: Path) -> Generator[None, None, None]:
    try:
        metadata = state_path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
        ):
            raise MailboxEvidenceError(EvidenceFailureCode.ANCHOR_STATE_UNSAFE)
        lock_path = state_path.with_suffix(f"{state_path.suffix}.lock")
        _ = ensure_private_file(lock_path)
        descriptor = os.open(
            lock_path,
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as exc:
        raise MailboxEvidenceError(EvidenceFailureCode.ANCHOR_STATE_UNSAFE) from exc
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def resolve_anchor(
    state: AnchorState,
    harness: PhysicalHarness,
    report: PhysicalReport,
    now_ms: int,
) -> tuple[AnchorBinding, AnchoredConnection]:
    bindings = [
        item
        for item in state.bindings
        if item.run_id == report.run_id and item.challenge == report.challenge
    ]
    if not bindings:
        raise MailboxEvidenceError(EvidenceFailureCode.ANCHORED_LOOKUP_MISSING)
    if len(bindings) != 1:
        raise MailboxEvidenceError(EvidenceFailureCode.ANCHORED_LOOKUP_AMBIGUOUS)
    binding = bindings[0]
    if binding.consumed:
        raise MailboxEvidenceError(EvidenceFailureCode.CHALLENGE_REUSED)
    if (
        binding.created_at_ms != harness.started_at_ms
        or binding.expires_at_ms != harness.expires_at_ms
        or not binding.created_at_ms <= now_ms <= binding.expires_at_ms
    ):
        raise MailboxEvidenceError(EvidenceFailureCode.CHALLENGE_STALE)
    connections = [
        item
        for item in state.connections
        if item.connection_handle == binding.connection_handle
    ]
    if not connections:
        raise MailboxEvidenceError(EvidenceFailureCode.ANCHORED_LOOKUP_MISSING)
    if len(connections) != 1:
        raise MailboxEvidenceError(EvidenceFailureCode.ANCHORED_LOOKUP_AMBIGUOUS)
    return binding, connections[0]


def full_identifiers(state: AnchorState) -> frozenset[str]:
    identifiers: set[str] = set()
    for connection in state.connections:
        identifiers.update(connection.full_identifiers)
    return frozenset(identifiers)


def consume_binding(
    state: AnchorState,
    consumed: AnchorBinding,
    state_path: Path,
) -> None:
    bindings: list[JsonValue] = [
        {
            "run_id": binding.run_id,
            "challenge": binding.challenge,
            "connection_handle": binding.connection_handle,
            "created_at_ms": binding.created_at_ms,
            "expires_at_ms": binding.expires_at_ms,
            "consumed": binding == consumed or binding.consumed,
        }
        for binding in state.bindings
    ]
    connections: list[JsonValue] = [
        {
            "connection_handle": item.connection_handle,
            "receiver_id": item.receiver_id,
            "device_id": item.device_id,
            "device_signing_key_id": item.device_signing_key_id,
            "device_agreement_key_id": item.device_agreement_key_id,
            "receiver_signing_key_id": item.receiver_signing_key_id,
            "receiver_agreement_key_id": item.receiver_agreement_key_id,
            "device_signing_public_key": item.device_signing_public_key,
            "connection_generation": item.connection_generation,
        }
        for item in state.connections
    ]
    document: dict[str, JsonValue] = {
        "v": 1,
        "kind": "mailbox_evidence_anchor_state",
        "bindings": bindings,
        "connections": connections,
    }
    write_private_text_file(state_path, hbjcs1_encode(document).decode("utf-8"))

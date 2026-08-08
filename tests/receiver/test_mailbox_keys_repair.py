import multiprocessing
import shutil
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from pydantic import JsonValue, TypeAdapter

from health_bridge.receiver.mailbox_keys import (
    MailboxKeyStore,
    MailboxKeyStoreError,
    MailboxKeyStoreErrorCode,
    verify_mailbox_key_continuity,
)

_JSON_OBJECT = TypeAdapter(dict[str, JsonValue])


class _Barrier(Protocol):
    def wait(self, timeout: float | None = None) -> int: ...


class _Process(Protocol):
    @property
    def exitcode(self) -> int | None: ...

    def start(self) -> None: ...

    def join(self, timeout: float | None = None) -> None: ...


def _store(
    state_dir: Path,
    anchor_dir: Path,
    *,
    transaction_barrier: Callable[[], int] | None = None,
    filesystem_kind: str = "local",
) -> MailboxKeyStore:
    return MailboxKeyStore.for_testing(
        state_dir=state_dir,
        anchor_dir=anchor_dir,
        transaction_barrier=transaction_barrier,
        filesystem_kind=filesystem_kind,
    )


def _initialize_worker(
    state_dir: Path,
    anchor_dir: Path,
    barrier: _Barrier,
    result_path: Path,
) -> None:
    identity = _store(
        state_dir,
        anchor_dir,
        transaction_barrier=barrier.wait,
    ).load_or_create()
    _ = result_path.write_text(identity.signing_key_id, encoding="ascii")


def _rotate_worker(
    state_dir: Path,
    anchor_dir: Path,
    expected_id: str,
    barrier: _Barrier,
    result_path: Path,
) -> None:
    try:
        rotation = _store(
            state_dir,
            anchor_dir,
            transaction_barrier=barrier.wait,
        ).rotate(expected_signing_key_id=expected_id)
        _ = result_path.write_text(
            f"ok:{rotation.identity.signing_key_id}", encoding="ascii"
        )
    except MailboxKeyStoreError as exc:
        _ = result_path.write_text(f"error:{exc.code.value}", encoding="ascii")


def _run_processes(processes: tuple[_Process, ...]) -> None:
    for process in processes:
        process.start()
    for process in processes:
        process.join(timeout=10)
        assert process.exitcode == 0


def test_complete_private_store_loss_is_detected_from_external_anchor(
    tmp_path: Path,
) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    first = _store(state_dir, anchor_dir).load_or_create()
    shutil.rmtree(state_dir)

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST
    assert (
        first.signing_key_id
        in (anchor_dir / "mailbox-expected-identity.json").read_text()
    )


def test_concurrent_process_initialization_returns_one_persisted_identity(
    tmp_path: Path,
) -> None:
    # Given
    context = multiprocessing.get_context("fork")
    barrier = context.Barrier(2)
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    results = (tmp_path / "first", tmp_path / "second")
    processes = tuple(
        context.Process(
            target=_initialize_worker,
            args=(state_dir, anchor_dir, barrier, result),
        )
        for result in results
    )

    # When
    _run_processes(processes)

    # Then
    returned = tuple(result.read_text(encoding="ascii") for result in results)
    persisted = _store(state_dir, anchor_dir).load_or_create()
    assert returned == (persisted.signing_key_id, persisted.signing_key_id)


def test_concurrent_process_rotation_allows_one_expected_identity_writer(
    tmp_path: Path,
) -> None:
    # Given
    context = multiprocessing.get_context("fork")
    barrier = context.Barrier(2)
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    first = _store(state_dir, anchor_dir).load_or_create()
    results = (tmp_path / "first", tmp_path / "second")
    processes = tuple(
        context.Process(
            target=_rotate_worker,
            args=(state_dir, anchor_dir, first.signing_key_id, barrier, result),
        )
        for result in results
    )

    # When
    _run_processes(processes)

    # Then
    outcomes = sorted(result.read_text(encoding="ascii") for result in results)
    persisted = _store(state_dir, anchor_dir).load_or_create()
    assert outcomes == [
        "error:stale_identity",
        f"ok:{persisted.signing_key_id}",
    ]


def test_rotation_persists_verified_old_key_signed_canonical_continuity(
    tmp_path: Path,
) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    store = _store(state_dir, anchor_dir)
    old = store.load_or_create()

    # When
    rotation = store.rotate(expected_signing_key_id=old.signing_key_id)

    # Then
    record = rotation.continuity
    assert record.old_signing_key_id == old.signing_key_id
    assert record.old_agreement_key_id == old.agreement_key_id
    assert record.new_signing_key_id == rotation.identity.signing_key_id
    assert record.new_agreement_key_id == rotation.identity.agreement_key_id
    verify_mailbox_key_continuity(record)
    Ed25519PublicKey.from_public_bytes(old.signing_public_key).verify(
        record.signature_bytes(), record.signature_preimage()
    )
    persisted = _JSON_OBJECT.validate_json(
        (anchor_dir / "mailbox-expected-identity.json").read_bytes()
    )
    assert persisted["continuity"] == _JSON_OBJECT.validate_json(
        record.canonical_bytes()
    )


def test_rotation_continuity_tamper_is_rejected(tmp_path: Path) -> None:
    # Given
    store = _store(tmp_path / "private-store", tmp_path / "external-anchor")
    old = store.load_or_create()
    rotation = store.rotate(expected_signing_key_id=old.signing_key_id)
    tampered = rotation.continuity.model_copy(update={"new_agreement_key_id": "0" * 32})

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        verify_mailbox_key_continuity(tampered)

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.MALFORMED_STATE


def test_rotation_interruption_reconciles_a_stale_external_anchor(
    tmp_path: Path,
) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    store = _store(state_dir, anchor_dir)
    old = store.load_or_create()
    anchor_path = anchor_dir / "mailbox-expected-identity.json"
    stale_anchor = anchor_path.read_bytes()
    rotation = store.rotate(expected_signing_key_id=old.signing_key_id)
    _ = anchor_path.write_bytes(stale_anchor)
    anchor_path.chmod(0o600)

    # When
    recovered = _store(state_dir, anchor_dir).load_or_create()

    # Then
    assert recovered == rotation.identity
    persisted = _JSON_OBJECT.validate_json(anchor_path.read_bytes())
    assert persisted["signing_key_id"] == rotation.identity.signing_key_id
    assert persisted["continuity"] == _JSON_OBJECT.validate_json(
        rotation.continuity.canonical_bytes()
    )

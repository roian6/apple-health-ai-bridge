import errno
import os
from pathlib import Path
from threading import Event
from typing import TYPE_CHECKING

import pytest

from health_bridge.contract._delivery_common import b64encode
from health_bridge.mailbox.filesystem import MailboxDirectoryHandle
from health_bridge.mailbox.importer import MailboxImportConfig, MailboxImporter
from health_bridge.mailbox.publication import publish_final
from health_bridge.receiver.mailbox_bootstrap import (
    PAIRING_DOMAIN,
    BootstrapDescriptor,
    PairingRequestEnvelope,
    canonical_model,
    open_pairing_request,
    seal_pairing_request,
)
from health_bridge.receiver.mailbox_keys import MailboxIdentity, MailboxKeyStore
from health_bridge.receiver.mailbox_runtime import MailboxRuntimeWorker
from health_bridge.storage.database import connect_database
from tests.receiver.delivery_acceptance_support import NOW_MS, counts
from tests.receiver.native_pairing_support import LegacyPeer, stage_native
from tests.receiver.test_mailbox_bootstrap import open_completion, publish_completion

if TYPE_CHECKING:
    from collections.abc import Callable


def assert_worker_recovers(
    peer: LegacyPeer,
    descriptor: BootstrapDescriptor,
    hostile: bytes,
    valid: bytes,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trusted = peer.trusted()
    root = peer.root / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", hostile)
    mailbox = root / trusted.receiver_id.hex() / trusted.device_id.hex()
    for lane in ("deliveries", "acks", "quarantine"):
        (mailbox / lane).mkdir(parents=True)
    _ = publish_final(
        mailbox / "deliveries", "01" * 16 + ".hbd", peer.upload(trusted).envelope_bytes
    )

    def importer(
        db: Path, path: Path, handle: MailboxDirectoryHandle
    ) -> MailboxImporter:
        return MailboxImporter(
            MailboxImportConfig(
                db_path=db,
                mailbox_path=path,
                lock_path=peer.connections.lock_path(path),
                connection=peer.connections.load(path),
                clock_ms=lambda: NOW_MS,
                directory=handle,
            )
        )

    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish_completion,
        importer_factory=importer,
        poll_interval_seconds=0.01,
    )
    first_ack, paired, second_ack, resume_pairing, resume_delivery, finish = (
        Event() for _ in range(6)
    )
    checkpoints: tuple[tuple[Callable[[], bool], Event, Event], ...] = (
        (
            lambda: len(list((mailbox / "acks").glob("*.hba"))) == 1,
            first_ack,
            resume_pairing,
        ),
        ((directory / "completion.hbp").exists, paired, resume_delivery),
        (
            lambda: len(list((mailbox / "acks").glob("*.hba"))) == 2,
            second_ack,
            finish,
        ),
    )
    checkpoint = 0
    run_once = worker.run_once

    def observe_cycle() -> None:
        nonlocal checkpoint
        run_once()
        if checkpoint < len(checkpoints):
            predicate, completed, resume = checkpoints[checkpoint]
            if predicate():
                checkpoint += 1
                # Observe only after the real cycle releases its database and
                # directory handles. Hold the next cycle until assertions and
                # request replacement finish, not for an assumed time interval.
                completed.set()
                assert resume.wait(5), "test did not release the worker checkpoint"

    monkeypatch.setattr(worker, "run_once", observe_cycle)
    worker.start()
    try:
        assert first_ack.wait(5), "worker did not finish the first ACK cycle"
        assert not worker.terminal_error(), (
            "malformed peer crypto terminated shared worker"
        )
        assert worker.is_alive()
        assert counts(peer.db) == (1, 1, 1)
        assert not (directory / "completion.hbp").exists()
        with connect_database(peer.db) as db:
            assert db.execute(
                "select count(*) from pairing_invitation_redemptions"
            ).fetchone() == (1,)
        (directory / "request.hbp").unlink()
        _ = publish_final(directory, "request.hbp", valid)
        resume_pairing.set()
        assert paired.wait(5), "worker did not finish the valid pairing cycle"
        assert not worker.terminal_error()
        assert open_completion(
            (directory / "completion.hbp").read_bytes(), valid, descriptor, peer.device
        )
        _ = publish_final(
            mailbox / "deliveries",
            "02" * 16 + ".hbd",
            peer.upload(trusted, 2).envelope_bytes,
        )
        resume_delivery.set()
        assert second_ack.wait(5), "worker did not finish the second ACK cycle"
        assert not worker.terminal_error()
        assert worker.is_alive()
        assert counts(peer.db) == (1, 2, 2)
    finally:
        for _, _, resume in checkpoints:
            resume.set()
        assert worker.stop()


@pytest.mark.parametrize(
    "low_order", [bytes(32), b"\x01" + bytes(31)], ids=["zero", "one"]
)
def test_unknown_secret_signed_low_order_ephemeral_keeps_worker_alive(
    tmp_path: Path, low_order: bytes, monkeypatch: pytest.MonkeyPatch
) -> None:
    peer = LegacyPeer(tmp_path)
    _ = peer.register()
    descriptor, valid = stage_native(peer)
    opened = open_pairing_request(valid, descriptor, peer.receiver).model_copy(
        update={"installation_id": "00000000-0000-4000-8000-000000000002"}
    )
    valid = seal_pairing_request(opened, descriptor, peer.device)
    # Attacker knows only the public descriptor, not an invitation secret or ciphertext.
    envelope = PairingRequestEnvelope(
        invitation_id=descriptor.invitation_id,
        sender_signing_public_key=b64encode(
            peer.device.load_or_create().signing_public_key
        ),
        ephemeral_public_key=b64encode(low_order),
        nonce=b64encode(bytes(12)),
        ciphertext=b64encode(bytes(16)),
        signature="",
    )
    hostile = canonical_model(
        envelope.model_copy(
            update={
                "signature": b64encode(
                    peer.device.sign(
                        PAIRING_DOMAIN
                        + b"request/signature\0"
                        + canonical_model(envelope, exclude={"signature"})
                    )
                )
            }
        )
    )
    assert_worker_recovers(peer, descriptor, hostile, valid, monkeypatch)


@pytest.mark.parametrize(
    "low_order", [bytes(32), b"\x01" + bytes(31)], ids=["zero", "one"]
)
def test_decrypted_low_order_device_key_keeps_worker_alive_without_enrollment(
    tmp_path: Path, low_order: bytes, monkeypatch: pytest.MonkeyPatch
) -> None:
    peer = LegacyPeer(tmp_path)
    _ = peer.register()
    descriptor, valid = stage_native(peer)
    opened = open_pairing_request(valid, descriptor, peer.receiver).model_copy(
        update={"installation_id": "00000000-0000-4000-8000-000000000002"}
    )
    valid = seal_pairing_request(opened, descriptor, peer.device)
    hostile = seal_pairing_request(
        opened.model_copy(update={"device_agreement_public_key": b64encode(low_order)}),
        descriptor,
        peer.device,
    )
    assert_worker_recovers(peer, descriptor, hostile, valid, monkeypatch)


@pytest.mark.parametrize("damage", ["lost", "corrupt", "revoked"])
def test_local_key_failure_remains_terminal(
    tmp_path: Path, damage: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    directory = tmp_path / "provider" / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    identity = tmp_path / "receiver" / "mailbox-identity.json"
    receiver = peer.receiver
    original_load = MailboxKeyStore.load_or_create
    loads = 0

    def load_then_damage(store: MailboxKeyStore) -> MailboxIdentity:
        nonlocal loads
        identity_value = original_load(store)
        if store is receiver:
            loads += 1
            # Worker descriptor and protocol identity checks succeed, then the local
            # store fails at private-key acquisition. Peer errors must not hide this.
            if loads == 2:
                if damage == "lost":
                    identity.unlink()
                elif damage == "corrupt":
                    _ = identity.write_bytes(b"{}")
                else:
                    _ = receiver.revoke()
        return identity_value

    monkeypatch.setattr(MailboxKeyStore, "load_or_create", load_then_damage)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=tmp_path / "provider",
        pairing_keys=receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish_completion,
        poll_interval_seconds=0.01,
    )
    attempted = Event()
    run_once = worker.run_once

    def observe_attempt() -> None:
        try:
            run_once()
        finally:
            attempted.set()

    monkeypatch.setattr(worker, "run_once", observe_attempt)
    worker.start()
    try:
        assert attempted.wait(5), "worker did not attempt local-key acquisition"
        # stop joins the actual worker: its exception handler must finish before
        # terminal state and thread termination are inspected.
        assert not worker.stop()
        assert worker.terminal_error()
        assert loads == 2
        assert worker.health_error() == "mailbox_worker_terminal_error"
        assert not worker.is_alive()
        assert not (directory / "completion.hbp").exists()
        with connect_database(peer.db) as db:
            assert db.execute("select count(*) from receiver_tokens").fetchone() == (0,)
    finally:
        _ = worker.stop()


def test_transient_local_key_io_failure_keeps_worker_alive(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    directory = tmp_path / "provider" / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    lock = (tmp_path / "receiver-anchor" / "mailbox-identity.lock").stat()
    original_fchmod = os.fchmod
    failures = 0

    def unavailable_once(fd: int, mode: int) -> None:
        nonlocal failures
        opened = os.fstat(fd)
        if not failures and (opened.st_dev, opened.st_ino) == (
            lock.st_dev,
            lock.st_ino,
        ):
            failures += 1
            raise OSError(errno.EIO, "synthetic transient key-store I/O failure")
        original_fchmod(fd, mode)

    monkeypatch.setattr(os, "fchmod", unavailable_once)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=tmp_path / "provider",
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish_completion,
        poll_interval_seconds=0.01,
    )
    attempted, resume, recovered, finish = (Event() for _ in range(4))
    run_once = worker.run_once

    def observe_cycle() -> None:
        first = not attempted.is_set()
        try:
            run_once()
        finally:
            if first:
                attempted.set()
                assert resume.wait(5), "test did not release the failed I/O cycle"
        if (directory / "completion.hbp").exists():
            recovered.set()
            assert finish.wait(5), "test did not release the recovered worker"

    monkeypatch.setattr(worker, "run_once", observe_cycle)
    worker.start()
    try:
        assert attempted.wait(5), "worker did not attempt local-key acquisition"
        assert failures == 1
        assert not (directory / "completion.hbp").exists()
        resume.set()
        assert recovered.wait(5), worker.health_error()
        assert worker.is_alive()
        assert not worker.terminal_error()
        assert open_completion(
            (directory / "completion.hbp").read_bytes(),
            request,
            descriptor,
            peer.device,
        )
        with connect_database(peer.db) as db:
            assert db.execute("select count(*) from receiver_tokens").fetchone() == (1,)
    finally:
        resume.set()
        finish.set()
        _ = worker.stop()

import hashlib
import os
import sqlite3
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from threading import Event

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from typer.testing import CliRunner
from typing_extensions import override

import health_bridge.receiver.mailbox_runtime as runtime_module
from health_bridge.cli import app
from health_bridge.contract._delivery_common import b64decode, derive_key
from health_bridge.contract._hbjcs1 import hbjcs1_decode
from health_bridge.mailbox.publication import publish_final
from health_bridge.queries.models import SyncedMetricsResult
from health_bridge.receiver.delivery_acceptance import DeliveryAcceptanceService
from health_bridge.receiver.mailbox_bootstrap import (
    PAIRING_DOMAIN,
    BootstrapDescriptor,
    PairingCompletionEnvelope,
    canonical_model,
)
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.mailbox_runtime import MailboxRuntimeWorker
from health_bridge.storage.database import (
    connect_live_readonly_database,
    initialize_database,
)
from tests.receiver.delivery_acceptance_support import NOW_MS, counts
from tests.receiver.native_pairing_support import LegacyPeer, stage_native


def publish_completion(directory: Path, content: bytes) -> None:
    _ = publish_final(directory, "completion.hbp", content)


def open_completion(
    encoded: bytes,
    request: bytes,
    descriptor: BootstrapDescriptor,
    device: MailboxKeyStore,
) -> bytes:
    envelope = PairingCompletionEnvelope.model_validate(hbjcs1_decode(encoded))
    assert envelope.request_sha256 == hashlib.sha256(request).hexdigest()
    assert envelope.invitation_id == descriptor.invitation_id
    assert envelope.sender_signing_public_key == descriptor.receiver_signing_public_key
    Ed25519PublicKey.from_public_bytes(
        b64decode(descriptor.receiver_signing_public_key, length=32)
    ).verify(
        b64decode(envelope.signature, length=64),
        PAIRING_DOMAIN
        + b"completion/signature\0"
        + canonical_model(envelope, exclude={"signature"}),
    )
    salt = bytes.fromhex(descriptor.invitation_id) + hashlib.sha256(request).digest()
    shared = device.exchange(
        b64decode(descriptor.receiver_agreement_public_key, length=32)
    )
    return AESGCM(derive_key(shared, salt, PAIRING_DOMAIN + b"completion/key")).decrypt(
        b64decode(envelope.nonce, length=12),
        b64decode(envelope.ciphertext),
        PAIRING_DOMAIN
        + b"completion/aad\0"
        + canonical_model(envelope, exclude={"ciphertext", "signature"}),
    )


@pytest.mark.parametrize("response_loss", [False, True])
def test_native_worker_pairs_then_authenticates_nonempty_health_and_normal_query(
    tmp_path: Path,
    response_loss: bool,
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    publications: list[bytes] = []

    def publish(directory: Path, content: bytes) -> None:
        publish_completion(directory, content)
        publications.append(content)
        if response_loss and len(publications) == 1:
            message = "synthetic lost publication confirmation"
            raise OSError(message)

    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish,
    )
    worker.run_once()
    assert not root.exists()
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    worker.run_once()
    assert (directory / "completion.hbp").exists(), "native request was not completed"
    response = (directory / "completion.hbp").read_bytes()
    assert b'"receiver_url":null' in open_completion(
        response, request, descriptor, peer.device
    )
    if response_loss:
        (directory / "completion.hbp").unlink()
        worker = MailboxRuntimeWorker(
            capability_publisher=lambda _directory: None,
            db_path=peer.db,
            mailbox_root=root,
            pairing_keys=peer.receiver,
            pairing_connections=peer.connections,
            pairing_publisher=publish,
        )
    worker.run_once()
    assert (directory / "completion.hbp").read_bytes() == response
    assert all(value == response for value in publications)
    trusted = peer.trusted()
    assert (
        DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
        .accept(peer.upload(trusted))
        .receipt.result
        == "committed"
    )
    assert counts(peer.db) == (1, 1, 1)
    queried = CliRunner().invoke(app, ["query", "synced-metrics", "--db", str(peer.db)])
    assert queried.exit_code == 0, queried.output
    assert (
        SyncedMetricsResult.model_validate_json(queried.output).metrics[0].record_count
        == 1
    )


@pytest.mark.parametrize("boundary", ["root", "database"])
@pytest.mark.parametrize("error_type", [PermissionError, OSError])
def test_bootstrap_storage_failure_keeps_worker_available_and_recovers(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    boundary: str,
    error_type: type[OSError],
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    unavailable = True
    original_lstat = Path.lstat

    def lstat(path: Path) -> os.stat_result:
        if unavailable and boundary == "root" and path == root:
            raise error_type
        return original_lstat(path)

    @contextmanager
    def reader(path: Path) -> Generator[sqlite3.Connection, None, None]:
        if unavailable and boundary == "database":
            raise error_type
        with connect_live_readonly_database(path) as database:
            yield database

    monkeypatch.setattr(Path, "lstat", lstat)
    monkeypatch.setattr(runtime_module, "connect_live_readonly_database", reader)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish_completion,
        capability_publisher=lambda _directory: None,
    )

    # The synchronous boundary first proves the precise retry classification.
    with pytest.raises(runtime_module.MailboxDiscoveryError) as raised:
        worker.run_once()
    assert (
        raised.value.code
        is runtime_module.MailboxDiscoveryErrorCode.STORAGE_UNAVAILABLE
    )
    assert isinstance(raised.value.__cause__, error_type)

    failed, resume, recovered = Event(), Event(), Event()

    class CycleGate(Event):
        @override
        def wait(self, timeout: float | None = None) -> bool:
            if not failed.is_set():
                failed.set()
                assert resume.wait(5), "test did not release retryable cycle"
                return self.is_set()
            recovered.set()
            return super().wait(timeout)

    monkeypatch.setattr(worker, "_stop", CycleGate())
    try:
        worker.start()
        assert failed.wait(5), "worker did not complete the failing cycle"
        assert worker.is_alive()
        assert not worker.terminal_error()
        assert worker.health_error() == "mailbox_discovery_storage_unavailable"
        unavailable = False
        resume.set()
        assert recovered.wait(5), "worker did not complete the recovery cycle"
        assert worker.is_alive()
        assert worker.health_error() is None
        assert open_completion(
            (directory / "completion.hbp").read_bytes(),
            request,
            descriptor,
            peer.device,
        )
        assert not peer.trusted().sender_key_revoked
    finally:
        resume.set()
        stopped = worker.stop()
    assert stopped


@pytest.mark.parametrize("awaiting", [False, True])
def test_bootstrap_missing_root_preserves_awaiting_policy(
    tmp_path: Path, awaiting: bool
) -> None:
    peer = LegacyPeer(tmp_path)
    if awaiting:
        _ = stage_native(peer)
    else:
        initialize_database(peer.db)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=tmp_path / "absent",
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        capability_publisher=lambda _directory: None,
    )
    if awaiting:
        worker.run_once()
    else:
        with pytest.raises(runtime_module.MailboxDiscoveryError) as raised:
            worker.run_once()
        assert (
            raised.value.code
            is runtime_module.MailboxDiscoveryErrorCode.ROOT_UNAVAILABLE
        )


@pytest.mark.parametrize("boundary", ["root", "database"])
def test_bootstrap_blocking_io_defers_without_discovery(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, boundary: str
) -> None:
    peer = LegacyPeer(tmp_path)
    _ = stage_native(peer)
    root = tmp_path / "provider"
    original_lstat = Path.lstat

    def lstat(path: Path) -> os.stat_result:
        if boundary == "root" and path == root:
            raise BlockingIOError
        return original_lstat(path)

    @contextmanager
    def reader(path: Path) -> Generator[sqlite3.Connection, None, None]:
        if boundary == "database":
            raise BlockingIOError
        with connect_live_readonly_database(path) as database:
            yield database

    monkeypatch.setattr(Path, "lstat", lstat)
    monkeypatch.setattr(runtime_module, "connect_live_readonly_database", reader)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        capability_publisher=lambda _directory: None,
    )

    worker.run_once()

    assert worker.health_error() is None

import hashlib
import sqlite3
from pathlib import Path
from threading import Event

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import TypeAdapter
from typer.testing import CliRunner

import health_bridge.receiver.mailbox_runtime as runtime_module
from health_bridge.cli import app
from health_bridge.cli_config import save_database
from health_bridge.contract._delivery_common import b64decode, b64encode, derive_key
from health_bridge.contract._hbjcs1 import hbjcs1_decode
from health_bridge.mailbox.filesystem import open_directory
from health_bridge.mailbox.publication import PublicationState, publish_final
from health_bridge.queries.models import SyncedMetricsResult
from health_bridge.receiver.delivery_acceptance import (
    DeliveryAcceptanceService,
)
from health_bridge.receiver.invitations import local_setup_pairing
from health_bridge.receiver.mailbox_bootstrap import (
    PAIRING_DOMAIN,
    BootstrapDescriptor,
    PairingCompletionEnvelope,
    PairingRequestEnvelope,
    canonical_model,
)
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.mailbox_pairing import redeem_native_pairing
from health_bridge.receiver.mailbox_runtime import MailboxRuntimeWorker
from health_bridge.storage.database import connect_database, connect_readonly_database
from tests.receiver.delivery_acceptance_support import NOW_MS
from tests.receiver.test_mailbox_enrollment import NativePeer, peer

__all__ = ["peer"]


def publish_completion(directory: Path, content: bytes) -> None:
    assert publish_final(directory, "completion.hbp", content) in {
        PublicationState.CREATED,
        PublicationState.IDENTICAL,
    }


def open_completion(
    encoded: bytes,
    request: bytes,
    descriptor: BootstrapDescriptor,
    device: MailboxKeyStore,
) -> bytes:
    envelope = PairingCompletionEnvelope.model_validate(hbjcs1_decode(encoded))
    assert envelope.request_sha256 == hashlib.sha256(request).hexdigest()
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
    key = derive_key(shared, salt, PAIRING_DOMAIN + b"completion/key")
    return AESGCM(key).decrypt(
        b64decode(envelope.nonce, length=12),
        b64decode(envelope.ciphertext),
        PAIRING_DOMAIN
        + b"completion/aad\0"
        + canonical_model(envelope, exclude={"ciphertext", "signature"}),
    )


@pytest.mark.parametrize(
    "interruption", ["none", "writer", "reader", "sqlite", "publication", "root_open"]
)
def test_native_worker_pairs_then_authenticates_nonempty_health_and_normal_query(
    peer: NativePeer,
    monkeypatch: pytest.MonkeyPatch,
    interruption: str,
) -> None:
    monkeypatch.setenv("HOME", str(peer.root))
    descriptor, request = peer.stage()
    receiver, device, connections, db = (
        peer.receiver,
        peer.device,
        peer.connections,
        peer.db,
    )
    root = peer.root / "provider/Documents/HealthBridgeMailbox/v1"
    publications: list[bytes] = []
    completed = Event()

    def publish(directory: Path, content: bytes) -> None:
        publications.append(content)
        publish_completion(directory, content)
        if interruption == "publication" and len(publications) == 1:
            message = "synthetic provider confirmation failure after file creation"
            raise OSError(message)
        completed.set()

    worker = MailboxRuntimeWorker(
        db_path=db,
        mailbox_root=root,
        pairing_keys=receiver,
        pairing_connections=connections,
        pairing_publisher=publish,
        poll_interval_seconds=0.01,
    )

    worker.run_once()
    assert not root.exists()
    assert local_setup_pairing(db) is None
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    if interruption in {"writer", "reader", "sqlite"}:
        run_through_contention(worker, db, completed, interruption, monkeypatch)
    elif interruption == "root_open":
        run_through_root_open(worker, db, root, completed, monkeypatch)
    else:
        worker.run_once()
    response = (directory / "completion.hbp").read_bytes()
    worker.run_once()
    assert (directory / "completion.hbp").read_bytes() == response
    assert completed.is_set()
    assert all(value == response for value in publications)
    assert len(publications) == (2 if interruption == "publication" else 1)
    completion = TypeAdapter(dict[str, str | int | None]).validate_json(
        open_completion(response, request, descriptor, device)
    )
    assert completion["receiver_url"] is None
    paired = local_setup_pairing(db)
    assert paired is not None
    assert paired.progress.data_receipt_status == "not_received"

    trusted = connections.load(
        root
        / TypeAdapter(str).validate_python(completion["mailbox_receiver_id"])
        / TypeAdapter(str).validate_python(completion["mailbox_device_id"])
    )
    accepted = DeliveryAcceptanceService(db, trusted, lambda: NOW_MS).accept(
        peer.upload(trusted)
    )
    assert accepted.receipt.result == "committed"
    paired = local_setup_pairing(db)
    assert paired is not None
    assert paired.progress.data_receipt_status == "received"
    save_database(db)
    queried = CliRunner().invoke(app, ["query", "synced-metrics"])
    assert queried.exit_code == 0, queried.output
    assert (
        SyncedMetricsResult.model_validate_json(queried.output).metrics[0].record_count
        > 0
    )


def test_native_rejects_tampered_signature_before_enrollment(peer: NativePeer) -> None:
    descriptor, request = peer.stage()
    tampered = PairingRequestEnvelope.model_validate(hbjcs1_decode(request)).model_copy(
        update={"signature": b64encode(bytes(64))}
    )
    with pytest.raises(InvalidSignature):
        _ = redeem_native_pairing(
            peer.db,
            canonical_model(tampered),
            descriptor,
            (peer.receiver, peer.connections),
        )
    assert local_setup_pairing(peer.db) is None


def run_through_contention(
    worker: MailboxRuntimeWorker,
    db: Path,
    completed: Event,
    interruption: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    held = connect_database if interruption == "writer" else connect_readonly_database
    attempted = Event()
    run_once = worker.run_once

    def observed_poll() -> None:
        try:
            run_once()
        finally:
            attempted.set()

    monkeypatch.setattr(worker, "run_once", observed_poll)
    try:
        with sqlite3.connect(db) if interruption == "sqlite" else held(db) as database:
            if interruption in {"writer", "sqlite"}:
                assert isinstance(database, sqlite3.Connection)
                _ = database.execute("begin immediate")
            worker.start()
            assert attempted.wait(10)
            assert not completed.is_set()
        assert completed.wait(5)
        assert worker.is_alive()
        assert not worker.terminal_error()
    finally:
        assert worker.stop()


def run_through_root_open(
    worker: MailboxRuntimeWorker,
    db: Path,
    root: Path,
    completed: Event,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    interrupted = False

    def transient_root_open(path: Path) -> int:
        nonlocal interrupted
        if path == root and not interrupted:
            interrupted = True
            message = "synthetic transient native root failure"
            raise FileNotFoundError(message)
        return open_directory(path)

    monkeypatch.setattr(runtime_module, "open_directory", transient_root_open)
    worker.run_once()
    assert interrupted
    assert not completed.is_set()
    assert local_setup_pairing(db) is None
    worker.run_once()

import hashlib
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from health_bridge.contract._delivery_common import b64decode, b64encode
from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_decode, hbjcs1_encode
from health_bridge.mailbox.connections import (
    MailboxConnectionStore,
    MailboxTrustedConnectionRecord,
)
from health_bridge.mailbox.publication import publish_final
from health_bridge.receiver import invitations
from health_bridge.receiver.delivery_acceptance import DeliveryAcceptanceService
from health_bridge.receiver.mailbox_bootstrap import PAIRING_DOMAIN
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.mailbox_runtime import MailboxRuntimeWorker
from health_bridge.storage.database import connect_database
from tests.receiver.delivery_acceptance_support import NOW_MS, counts
from tests.receiver.native_pairing_support import LegacyPeer, stage_native
from tests.receiver.test_mailbox_bootstrap import open_completion


def cancellation(request: bytes, invitation: str, device: MailboxKeyStore) -> bytes:
    unsigned: dict[str, JsonValue] = {
        "v": 1,
        "kind": "cancel",
        "invitation_id": invitation,
        "request_sha256": hashlib.sha256(request).hexdigest(),
        "sender_signing_public_key": b64encode(
            device.load_or_create().signing_public_key
        ),
    }
    signature = device.sign(
        PAIRING_DOMAIN + b"cancel/signature\0" + hbjcs1_encode(unsigned)
    )
    return hbjcs1_encode({**unsigned, "signature": b64encode(signature)})


def publish_response(directory: Path, content: bytes) -> None:
    name = "cancelled.hbp" if b'"kind":"cancelled"' in content else "completion.hbp"
    _ = publish_final(directory, name, content)


@pytest.mark.parametrize("restarted", [False, True])
def test_native_bootstrap_bounds_helper_work_across_restart(
    tmp_path: Path, restarted: bool
) -> None:
    # Given two authenticated cancellations, including a superseded invitation.
    peer = LegacyPeer(tmp_path)
    root = tmp_path / "provider"
    for _ in range(2):
        descriptor, request = stage_native(peer)
        directory = root / "pairing" / descriptor.invitation_id
        directory.mkdir(parents=True)
        _ = publish_final(directory, "request.hbp", request)
        _ = publish_final(
            directory,
            "cancel.hbp",
            cancellation(request, descriptor.invitation_id, peer.device),
        )
    publications: list[bytes] = []

    def publish(path: Path, content: bytes) -> None:
        publications.append(content)
        publish_response(path, content)

    if restarted:
        previous = MailboxRuntimeWorker(
            capability_publisher=lambda _directory: None,
            db_path=peer.db,
            mailbox_root=root,
            pairing_keys=peer.receiver,
            pairing_connections=peer.connections,
            pairing_publisher=publish,
        )
        previous.run_once()
        previous.run_once()
        assert len(publications) == 2
        publications.clear()
    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish,
    )
    # When one real bootstrap cycle runs, even after losing in-memory receipts.
    worker.run_once()
    # Then at most one slow native publication is attempted in that cycle.
    assert len(publications) == 1
    worker.run_once()
    assert len(publications) == 2
    worker.run_once()
    assert len(publications) == 2


@pytest.mark.parametrize("committed", [False, True])
def test_cancellation_revokes_exact_request_across_restart(
    tmp_path: Path, committed: bool
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    publications: list[bytes] = []

    def publish(directory: Path, content: bytes) -> None:
        publications.append(content)
        publish_response(directory, content)

    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish,
    )
    if committed:
        worker.run_once()
        assert (directory / "completion.hbp").exists()
        # Completion is lost before the synthetic peer activates anything.
        (directory / "completion.hbp").unlink()
    _ = publish_final(
        directory,
        "cancel.hbp",
        cancellation(request, descriptor.invitation_id, peer.device),
    )
    worker.run_once()
    assert (directory / "cancelled.hbp").exists(), (
        "receiver did not acknowledge cancellation"
    )
    receipt = (directory / "cancelled.hbp").read_bytes()
    worker.run_once()
    assert publications.count(receipt) == 1
    decoded = hbjcs1_decode(receipt)
    assert isinstance(decoded, dict)
    signature = decoded.pop("signature")
    assert isinstance(signature, str)
    assert decoded["request_sha256"] == hashlib.sha256(request).hexdigest()
    assert decoded["invitation_id"] == descriptor.invitation_id
    assert decoded["kind"] == "cancelled"
    Ed25519PublicKey.from_public_bytes(
        b64decode(descriptor.receiver_signing_public_key, length=32)
    ).verify(
        b64decode(signature, length=64),
        PAIRING_DOMAIN + b"cancelled/signature\0" + hbjcs1_encode(decoded),
    )
    restarted = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish,
    )
    restarted.run_once()
    assert (directory / "cancelled.hbp").read_bytes() == receipt
    assert not (directory / "completion.hbp").exists()
    if committed:
        trusted = peer.trusted()
        result = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS).accept(
            peer.upload(trusted)
        )
        assert result.receipt.error_code == "key_revoked"
    else:
        with connect_database(peer.db) as db:
            assert db.execute("select count(*) from receiver_tokens").fetchone() == (0,)
    assert counts(peer.db) == (0, 0, 0)


@pytest.mark.parametrize("cancelled", [False, True])
@pytest.mark.parametrize("restarted", [False, True])
def test_older_native_request_recovers_beyond_first_invitation_page(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    cancelled: bool,
    restarted: bool,
) -> None:
    invitation_ids = iter(
        [
            UUID("ffffffff-ffff-4fff-8fff-ffffffffffff"),
            *(UUID(int=number, version=4) for number in range(1, 129)),
        ]
    )
    monkeypatch.setattr(invitations, "uuid4", lambda: next(invitation_ids))
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    publications: list[bytes] = []

    def publish(path: Path, content: bytes) -> None:
        publications.append(content)
        publish_response(path, content)

    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish,
    )
    worker.run_once()
    assert open_completion(
        (directory / "completion.hbp").read_bytes(), request, descriptor, peer.device
    )
    (directory / "completion.hbp").unlink()
    for _ in range(128):
        _ = invitations.create_pairing_invitation(
            peer.db,
            label="newer-synthetic",
            receiver_url=None,
            transport="mailbox",
            now=datetime(2099, 1, 1, tzinfo=UTC),
        )
    with connect_database(peer.db) as db:
        assert db.execute(
            "select count(*) from pairing_invitations where pairing_invitation_id < ?",
            (str(UUID(descriptor.invitation_id)),),
        ).fetchone() == (128,)
    if cancelled:
        _ = publish_final(
            directory,
            "cancel.hbp",
            cancellation(request, descriptor.invitation_id, peer.device),
        )
    if restarted:
        worker = MailboxRuntimeWorker(
            capability_publisher=lambda _directory: None,
            db_path=peer.db,
            mailbox_root=root,
            pairing_keys=peer.receiver,
            pairing_connections=peer.connections,
            pairing_publisher=publish,
        )
    publications.clear()
    response_name = "cancelled.hbp" if cancelled else "completion.hbp"
    # Drive a finite number of real cycles, not a timing-dependent wait.
    for cycle in range(3):
        before = len(publications)
        worker.run_once()
        assert len(publications) - before <= 1
        if cycle == 0:
            assert not (directory / response_name).exists()
    assert (directory / response_name).exists()
    response = (directory / response_name).read_bytes()
    assert publications == [response]
    if cancelled:
        decoded = hbjcs1_decode(response)
        assert isinstance(decoded, dict)
        signature = decoded.pop("signature")
        assert isinstance(signature, str)
        assert decoded["request_sha256"] == hashlib.sha256(request).hexdigest()
        assert decoded["invitation_id"] == descriptor.invitation_id
        Ed25519PublicKey.from_public_bytes(
            b64decode(descriptor.receiver_signing_public_key, length=32)
        ).verify(
            b64decode(signature, length=64),
            PAIRING_DOMAIN + b"cancelled/signature\0" + hbjcs1_encode(decoded),
        )
        with connect_database(peer.db) as db:
            assert db.execute(
                "select count(*) from receiver_tokens where revoked_at is null"
            ).fetchone() == (0,)
    else:
        assert open_completion(response, request, descriptor, peer.device)
    for _ in range(3):
        worker.run_once()
    assert publications == [response]


def test_wrong_peer_cannot_cancel_committed_request(tmp_path: Path) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish_response,
    )
    worker.run_once()
    other = LegacyPeer(tmp_path / "other")
    _ = publish_final(
        directory,
        "cancel.hbp",
        cancellation(request, descriptor.invitation_id, other.device),
    )
    worker.run_once()
    assert not (directory / "cancelled.hbp").exists()
    trusted = peer.trusted()
    assert (
        DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
        .accept(peer.upload(trusted))
        .receipt.result
        == "committed"
    )


def test_cancel_arriving_after_trust_save_prevents_registration_commit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:

    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    directory = tmp_path / "provider/pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    original = MailboxConnectionStore.save

    def intercept(
        store: MailboxConnectionStore, record: MailboxTrustedConnectionRecord
    ) -> None:
        original(store, record)
        _ = publish_final(
            directory,
            "cancel.hbp",
            cancellation(request, descriptor.invitation_id, peer.device),
        )

    monkeypatch.setattr(MailboxConnectionStore, "save", intercept)
    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=tmp_path / "provider",
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish_response,
    )
    worker.run_once()
    with connect_database(peer.db) as db:
        assert db.execute("select count(*) from receiver_tokens").fetchone() == (0,)
    worker.run_once()
    assert (directory / "cancelled.hbp").exists()

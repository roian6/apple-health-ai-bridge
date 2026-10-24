import hashlib
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from health_bridge.contract._delivery_common import b64decode, b64encode
from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_decode, hbjcs1_encode
from health_bridge.mailbox.connections import (
    MailboxConnectionStore,
    MailboxTrustedConnectionRecord,
)
from health_bridge.mailbox.publication import publish_final
from health_bridge.receiver.delivery_acceptance import DeliveryAcceptanceService
from health_bridge.receiver.mailbox_bootstrap import PAIRING_DOMAIN
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.mailbox_runtime import MailboxRuntimeWorker
from health_bridge.storage.database import connect_database
from tests.receiver.delivery_acceptance_support import NOW_MS, counts
from tests.receiver.native_pairing_support import LegacyPeer, stage_native


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


def test_wrong_peer_cannot_cancel_committed_request(tmp_path: Path) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    worker = MailboxRuntimeWorker(
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

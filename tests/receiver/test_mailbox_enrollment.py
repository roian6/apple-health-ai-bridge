from dataclasses import replace
from pathlib import Path

import pytest

from health_bridge.contract.delivery_v1 import DevicePrincipal
from health_bridge.receiver.delivery_acceptance import DeliveryAcceptanceService
from health_bridge.receiver.invitations import (
    create_pairing_invitation,
    revoke_receiver_device,
)
from health_bridge.storage.database import connect_database
from tests.receiver.delivery_acceptance_support import NOW_MS, counts
from tests.receiver.native_pairing_support import LegacyPeer


def test_revoke_blocks_new_delivery_but_replays_committed_receipt(
    tmp_path: Path,
) -> None:
    peer = LegacyPeer(tmp_path)
    trusted = peer.register()
    service = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
    upload = peer.upload(trusted)
    first = service.accept(upload)
    assert first.receipt.result == "committed"
    installation = trusted.source_principal.installation_id_hash
    assert installation is not None
    assert revoke_receiver_device(peer.db, installation[:12]) == 1
    denied = service.accept(peer.upload(trusted, 2))
    assert denied.receipt.result == "terminal"
    assert denied.receipt.error_code == "key_revoked"
    replay = service.accept(upload)
    assert replay.replayed
    assert replay.ack_bytes == first.ack_bytes
    assert counts(peer.db) == (1, 1, 1)


@pytest.mark.parametrize(
    "state",
    [
        "preserve",
        "absent_redemption",
        "revoked",
        "revoked_device",
        "wrong_key",
        "wrong_principal",
        "torn",
        "ambiguous",
        "native_null",
    ],
)
def test_legacy_digest_transition_requires_proven_active_peer(
    tmp_path: Path, state: str
) -> None:
    peer = LegacyPeer(tmp_path)
    trusted = peer.register()
    service = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
    if state == "preserve":
        assert service.accept(peer.upload(trusted)).receipt.result == "committed"
    with connect_database(peer.db) as database:
        _ = database.execute(
            "update pairing_invitation_redemptions set mailbox_enrollment_sha256 = null"
        )
        mutation = {
            "absent_redemption": "delete from pairing_invitation_redemptions",
            "native_null": "update pairing_invitations set receiver_url = ''",
            "revoked_device": (
                "update receiver_devices set revoked_at = '2026-01-01T00:00:00Z'"
            ),
            "revoked": "update receiver_tokens set revoked_at = '2026-01-01T00:00:00Z'",
            "torn": "delete from receiver_token_devices",
        }.get(state)
        if mutation is not None:
            _ = database.execute(mutation)
    if state == "wrong_key":
        trusted = replace(
            trusted,
            device_agreement_public_key=peer.receiver.private_identity().agreement_private_key.public_key(),
        )
    if state == "wrong_principal":
        trusted = replace(trusted, device_principal=DevicePrincipal("wrong"))
    if state == "ambiguous":
        invitation = create_pairing_invitation(
            peer.db,
            label="ambiguous",
            receiver_url="https://receiver.example.test/v1/batches",
            transport="mailbox",
        )
        with connect_database(peer.db) as database:
            _ = database.execute(
                """insert into receiver_tokens (token_label, token_prefix,
                token_hash) select token_label, token_prefix, token_hash || 'x'
                from receiver_tokens limit 1"""
            )
            _ = database.execute(
                """insert into receiver_token_devices select last_insert_rowid(),
                receiver_device_id, paired_at from receiver_token_devices limit 1"""
            )
            _ = database.execute(
                """update pairing_invitations set redeemed_at = created_at
                where pairing_invitation_id = ?""",
                (invitation.invitation_id,),
            )
            _ = database.execute(
                """insert into pairing_invitation_redemptions
                (pairing_invitation_id, receiver_device_id, receiver_token_id,
                redeemed_at) select ?, receiver_device_id, (select
                max(receiver_token_id) from receiver_tokens), redeemed_at from
                pairing_invitation_redemptions limit 1""",
                (invitation.invitation_id,),
            )
    before = counts(peer.db)
    result = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS).accept(
        peer.upload(trusted, 2)
    )
    assert result.receipt.result == ("committed" if state == "preserve" else "terminal")
    if state != "preserve":
        assert counts(peer.db) == before


def test_completed_url_mailbox_without_delivery_preserves_first_ingest(
    tmp_path: Path,
) -> None:
    peer = LegacyPeer(tmp_path)
    original = peer.register()
    persisted = {
        path: path.read_bytes() for path in (tmp_path / "connections").glob("*.hbjcs1")
    }
    identity = peer.receiver.load_or_create()
    assert len(persisted) == 1
    assert counts(peer.db) == (0, 0, 0)
    # BASE HTTP pairing commits no enrollment digest. No original request is replayed.
    with connect_database(peer.db) as database:
        _ = database.execute(
            "update pairing_invitation_redemptions set mailbox_enrollment_sha256 = null"
        )
    restarted = LegacyPeer(tmp_path)
    trusted = restarted.trusted()
    assert trusted.enrollment_digest() == original.enrollment_digest()
    service = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
    upload = restarted.upload(trusted)
    first = service.accept(upload)
    assert first.receipt.result == "committed", (
        "completed URL enrollment must not require prior delivery"
    )
    assert counts(peer.db) == (1, 1, 1)
    assert service.accept(upload).ack_bytes == first.ack_bytes
    assert restarted.receiver.load_or_create() == identity
    assert {path: path.read_bytes() for path in persisted} == persisted
    with connect_database(peer.db) as database:
        assert database.execute(
            "select mailbox_enrollment_sha256 from pairing_invitation_redemptions"
        ).fetchone() == (trusted.enrollment_digest(),)

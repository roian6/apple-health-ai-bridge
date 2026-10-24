import sqlite3
from dataclasses import replace
from pathlib import Path

import pytest
from cryptography.exceptions import InvalidSignature, InvalidTag

from health_bridge.contract._delivery_common import b64encode
from health_bridge.contract._hbjcs1 import hbjcs1_decode
from health_bridge.contract.delivery_v1 import DevicePrincipal, OpaqueBinding
from health_bridge.mailbox.connections import MailboxConnectionError
from health_bridge.receiver.delivery_acceptance import DeliveryAcceptanceService
from health_bridge.receiver.invitations import PairingInvitationError
from health_bridge.receiver.mailbox_bootstrap import (
    NativePairingError,
    PairingRequestEnvelope,
    canonical_model,
    open_pairing_request,
    seal_pairing_request,
)
from health_bridge.receiver.mailbox_pairing import redeem_native_pairing
from health_bridge.storage.database import connect_database
from tests.receiver.delivery_acceptance_support import NOW_MS, counts
from tests.receiver.native_pairing_support import LegacyPeer, stage_native
from tests.receiver.test_mailbox_bootstrap import open_completion


@pytest.mark.parametrize(
    "mutation",
    ["signature", "receiver", "invitation", "installation", "key", "resealed"],
)
def test_native_recovery_requires_exact_authenticated_request(
    tmp_path: Path, mutation: str
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    first = redeem_native_pairing(
        peer.db, request, descriptor, (peer.receiver, peer.connections)
    )
    envelope = PairingRequestEnvelope.model_validate(hbjcs1_decode(request))
    if mutation == "signature":
        request = canonical_model(
            envelope.model_copy(update={"signature": b64encode(bytes(64))})
        )
    elif mutation == "receiver":
        descriptor = descriptor.model_copy(
            update={"receiver_signing_public_key": b64encode(bytes(32))}
        )
    elif mutation == "invitation":
        descriptor = descriptor.model_copy(update={"invitation_id": "f" * 32})
    else:
        opened = open_pairing_request(request, descriptor, peer.receiver)
        if mutation == "installation":
            opened = opened.model_copy(
                update={"installation_id": "00000000-0000-4000-8000-000000000002"}
            )
        elif mutation == "key":
            opened = opened.model_copy(
                update={
                    "device_agreement_public_key": b64encode(
                        peer.receiver.load_or_create().agreement_public_key
                    )
                }
            )
        request = seal_pairing_request(opened, descriptor, peer.device)
    with pytest.raises(
        (
            PairingInvitationError,
            NativePairingError,
            InvalidSignature,
            InvalidTag,
            MailboxConnectionError,
        )
    ):
        _ = redeem_native_pairing(
            peer.db, request, descriptor, (peer.receiver, peer.connections)
        )
    assert first
    assert counts(peer.db) == (0, 0, 0)


@pytest.mark.parametrize("committed", [False, True])
def test_expiry_blocks_new_registration_but_not_exact_committed_recovery(
    tmp_path: Path, committed: bool
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    original = (
        redeem_native_pairing(
            peer.db, request, descriptor, (peer.receiver, peer.connections)
        )
        if committed
        else None
    )
    with connect_database(peer.db) as db:
        _ = db.execute(
            "update pairing_invitations set expires_at='2020-01-01T00:00:00Z'"
        )
    if committed:
        response = redeem_native_pairing(
            peer.db, request, descriptor, (peer.receiver, peer.connections)
        )
        assert response == original
        assert open_completion(response, request, descriptor, peer.device)
    else:
        with pytest.raises(PairingInvitationError):
            _ = redeem_native_pairing(
                peer.db, request, descriptor, (peer.receiver, peer.connections)
            )


@pytest.mark.parametrize("failure", ["filesystem", "sqlite"])
def test_partial_commit_orphan_is_inert_and_exact_request_recovers(
    tmp_path: Path, failure: str
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    if failure == "sqlite":
        with connect_database(peer.db) as db:
            _ = db.executescript("""
                create table synthetic_failure (device integer
                    references receiver_devices(receiver_device_id)
                    deferrable initially deferred);
                create trigger synthetic_fail
                after insert on pairing_invitation_redemptions
                begin insert into synthetic_failure values (-1); end;
            """)

    def fail() -> None:
        if failure == "filesystem":
            message = "synthetic detached request"
            raise OSError(message)

    with pytest.raises((OSError, sqlite3.IntegrityError)):
        _ = redeem_native_pairing(
            peer.db,
            request,
            descriptor,
            (peer.receiver, peer.connections),
            validate_request=fail,
        )
    trusted = peer.trusted()
    service = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
    assert service.accept(peer.upload(trusted)).receipt.error_code == "key_revoked"
    with connect_database(peer.db) as db:
        assert db.execute("select count(*) from receiver_tokens").fetchone() == (0,)
        if failure == "sqlite":
            _ = db.execute("drop trigger synthetic_fail")
    restarted = LegacyPeer(tmp_path)
    _ = redeem_native_pairing(
        peer.db, request, descriptor, (restarted.receiver, restarted.connections)
    )
    assert service.accept(peer.upload(trusted)).receipt.result == "committed"


@pytest.mark.parametrize("mutation", ["binding", "principal", "mapping"])
def test_installed_enrollment_rejects_mismatched_trust(
    tmp_path: Path, mutation: str
) -> None:

    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    _ = redeem_native_pairing(
        peer.db, request, descriptor, (peer.receiver, peer.connections)
    )
    trusted = peer.trusted()
    if mutation == "binding":
        trusted = replace(trusted, opaque_binding=OpaqueBinding(bytes(32)))
    elif mutation == "principal":
        trusted = replace(trusted, device_principal=DevicePrincipal("wrong"))
    else:
        with connect_database(peer.db) as db:
            _ = db.execute("delete from receiver_token_devices")
    assert (
        DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
        .accept(peer.upload(trusted))
        .receipt.error_code
        == "key_revoked"
    )
    assert counts(peer.db) == (0, 0, 0)


def test_completion_cannot_be_verified_for_different_request(tmp_path: Path) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    response = redeem_native_pairing(
        peer.db, request, descriptor, (peer.receiver, peer.connections)
    )
    with pytest.raises(AssertionError):
        _ = open_completion(response, request + b" ", descriptor, peer.device)

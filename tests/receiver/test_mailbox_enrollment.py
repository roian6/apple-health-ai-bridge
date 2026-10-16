import hashlib
import sqlite3
from dataclasses import dataclass, replace
from pathlib import Path
from threading import Event, Thread

import pytest

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.contract._delivery_common import b64encode
from health_bridge.ingest import ingest_fixture
from health_bridge.mailbox.connections import MailboxConnectionStore
from health_bridge.receiver.delivery_acceptance import (
    DeliveryAcceptanceFaultPoint,
    DeliveryAcceptanceRequest,
    DeliveryAcceptanceService,
    DeliveryTrustedConnection,
)
from health_bridge.receiver.invitations import (
    PairingRedemptionCompletion,
    local_setup_pairing,
    redeem_pairing_invitation,
    revoke_receiver_device,
)
from health_bridge.receiver.mailbox_bootstrap import (
    BootstrapDescriptor,
    NativePairingRequest,
    seal_pairing_request,
)
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.mailbox_pairing import (
    MailboxProvisioningTransaction,
    redeem_native_pairing,
)
from health_bridge.receiver.pairing import create_receiver_pairing_invitation_bundle
from health_bridge.receiver.tokens import ReceiverTokenPrincipal
from health_bridge.storage import database as database_module
from health_bridge.storage.database import connect_database, initialize_database
from tests.contract.delivery_v1_support import BATCH
from tests.receiver.delivery_acceptance_support import NOW_MS, counts

INSTALLATION = "00000000-0000-4000-8000-000000000001"


@dataclass
class NativePeer:
    db: Path
    root: Path
    receiver: MailboxKeyStore
    device: MailboxKeyStore
    connections: MailboxConnectionStore
    last_request: tuple[bytes, BootstrapDescriptor] | None = None

    def stage(self) -> tuple[BootstrapDescriptor, bytes]:
        invitation = create_receiver_pairing_invitation_bundle(
            self.db,
            label="synthetic",
            receiver_url=None,
            transport="mailbox",
            mailbox_key_store=self.receiver,
        )
        descriptor = invitation.mailbox_bootstrap
        assert descriptor is not None
        identity = self.device.load_or_create()
        request = seal_pairing_request(
            NativePairingRequest(
                invitation_secret=invitation.invitation_secret,
                installation_id=INSTALLATION,
                device_credential="hb_" + descriptor.invitation_id * 2,
                platform="ios",
                device_signing_public_key=b64encode(identity.signing_public_key),
                device_agreement_public_key=b64encode(identity.agreement_public_key),
            ),
            descriptor,
            self.device,
        )

        self.last_request = (request, descriptor)
        return descriptor, request

    def enroll(self, *, fail: bool = False) -> DeliveryTrustedConnection:
        descriptor, request = self.stage()

        def validate() -> None:
            if fail:
                message = "synthetic detached request after trust save"
                raise OSError(message)

        if fail:
            with pytest.raises(OSError, match="detached request"):
                _ = redeem_native_pairing(
                    self.db,
                    request,
                    descriptor,
                    (self.receiver, self.connections),
                    validate_request=validate,
                )
        else:
            first = redeem_native_pairing(
                self.db, request, descriptor, (self.receiver, self.connections)
            )
            assert (
                redeem_native_pairing(
                    self.db, request, descriptor, (self.receiver, self.connections)
                )
                == first
            )
        return self.trusted()

    def trusted(self) -> DeliveryTrustedConnection:
        signing = self.receiver.private_identity().signing_private_key.public_key()
        receiver_id = hashlib.sha256(
            b"health-bridge/mailbox/v1/receiver-id\0" + signing.public_bytes_raw()
        ).digest()[:16]
        installation = hashlib.sha256(
            ("health-bridge-pairing:installation:" + INSTALLATION).encode()
        ).digest()
        device_id = hashlib.sha256(
            b"health-bridge/mailbox/v1/device-id\0" + installation
        ).digest()[:16]
        return self.connections.load(self.root / receiver_id.hex() / device_id.hex())

    def upload(
        self, trusted: DeliveryTrustedConnection, number: int = 1
    ) -> DeliveryAcceptanceRequest:
        envelope = delivery.create_delivery_envelope(
            BATCH.replace(b"synthetic.phone.alpha", b"apple_health.phone"),
            delivery.DeliveryCreateParams(
                envelope_id=bytes([number]) * 16,
                receiver_id=trusted.receiver_id,
                device_id=trusted.device_id,
                connection_generation=trusted.connection_generation,
                created_at_ms=NOW_MS,
                receiver_agreement_public_key=self.receiver.private_identity().agreement_private_key.public_key(),
                sender_signing_private_key=self.device.private_identity().signing_private_key,
            ),
        )
        return DeliveryAcceptanceRequest(
            envelope.to_bytes(), trusted.device_principal, trusted.opaque_binding
        )


@pytest.fixture
def peer(tmp_path: Path) -> NativePeer:
    receiver = MailboxKeyStore.for_testing(
        state_dir=tmp_path / "receiver", anchor_dir=tmp_path / "receiver-anchor"
    )
    return NativePeer(
        tmp_path / "health.sqlite",
        tmp_path,
        receiver,
        MailboxKeyStore.for_testing(
            state_dir=tmp_path / "device", anchor_dir=tmp_path / "device-anchor"
        ),
        MailboxConnectionStore.for_testing(tmp_path / "connections", receiver),
    )


def test_revoke_blocks_new_delivery_but_replays_committed_receipt(
    peer: NativePeer,
) -> None:
    trusted = peer.enroll()
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


@pytest.mark.parametrize("prior", ["none", "direct", "mailbox"])
def test_orphan_trust_cannot_borrow_prior_enrollment(
    peer: NativePeer, prior: str
) -> None:
    if prior == "direct":
        invitation = create_receiver_pairing_invitation_bundle(
            peer.db,
            label="prior",
            receiver_url="https://health.example.test/v1/batches",
        )
        _ = redeem_pairing_invitation(
            peer.db,
            invitation_secret=invitation.invitation_secret,
            installation_id=INSTALLATION,
            device_credential="hb_" + "b" * 43,
            platform="ios",
        )
    elif prior == "mailbox":
        receiver = MailboxKeyStore.for_testing(
            state_dir=peer.root / "prior", anchor_dir=peer.root / "prior-anchor"
        )
        previous = replace(
            peer,
            receiver=receiver,
            connections=MailboxConnectionStore.for_testing(
                peer.root / "prior-connections", receiver
            ),
        )
        _ = previous.enroll()
    trusted = peer.enroll(fail=True)
    assert (local_setup_pairing(peer.db) is not None) == (prior != "none")
    denied = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS).accept(
        peer.upload(trusted)
    )
    assert denied.receipt.result == "terminal"
    assert counts(peer.db) == (0, 0, 0)


@pytest.mark.parametrize(
    "mutation", ["principal", "installation", "binding", "agreement", "mapping"]
)
def test_enrollment_requires_exact_peer(peer: NativePeer, mutation: str) -> None:
    trusted = peer.enroll()
    if mutation == "principal":
        trusted = replace(
            trusted, device_principal=delivery.DevicePrincipal("unmapped")
        )
    elif mutation == "installation":
        trusted = replace(
            trusted,
            source_principal=ReceiverTokenPrincipal(installation_id_hash="f" * 64),
        )
    elif mutation == "binding":
        trusted = replace(trusted, opaque_binding=delivery.OpaqueBinding(b"x" * 32))
    elif mutation == "mapping":
        with connect_database(peer.db) as database:
            _ = database.execute("delete from receiver_token_devices")
    else:
        trusted = replace(
            trusted,
            device_agreement_public_key=peer.receiver.private_identity().agreement_private_key.public_key(),
        )
    result = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS).accept(
        peer.upload(trusted)
    )
    assert result.receipt.result == "terminal"
    assert counts(peer.db) == (0, 0, 0)


def test_revocation_waits_for_actual_acceptance_transaction(peer: NativePeer) -> None:
    trusted = peer.enroll()
    service = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
    entered, release, revoked = Event(), Event(), Event()
    results: list[str] = []

    def hold(point: DeliveryAcceptanceFaultPoint) -> None:
        if point == DeliveryAcceptanceFaultPoint.BEFORE_COMMIT:
            entered.set()
            assert release.wait(5)

    def accept() -> None:
        results.append(service.accept(peer.upload(trusted), hold).receipt.result)

    def revoke() -> None:
        installation = trusted.source_principal.installation_id_hash
        assert installation is not None
        _ = revoke_receiver_device(peer.db, installation[:12])
        revoked.set()

    worker = Thread(target=accept)
    worker.start()
    assert entered.wait(5)
    revoker = Thread(target=revoke)
    revoker.start()
    try:
        assert not revoked.is_set()
    finally:
        release.set()
        worker.join(5)
        revoker.join(5)
    assert results == ["committed"]
    assert revoked.is_set()
    assert service.accept(peer.upload(trusted, 2)).receipt.error_code == "key_revoked"


def test_commit_failure_keeps_orphan_inert_and_exact_replay_recovers(
    peer: NativePeer,
) -> None:
    initialize_database(peer.db)
    with connect_database(peer.db) as database:
        _ = database.executescript("""
            create table synthetic_commit_failure (
                device integer references receiver_devices(receiver_device_id)
                deferrable initially deferred);
            create trigger synthetic_fail after insert on pairing_invitation_redemptions
            begin insert into synthetic_commit_failure values (-1); end;
        """)
    with pytest.raises(sqlite3.IntegrityError, match="FOREIGN KEY"):
        _ = peer.enroll()
    trusted = peer.trusted()
    service = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
    assert service.accept(peer.upload(trusted)).receipt.result == "terminal"
    assert local_setup_pairing(peer.db) is None
    with connect_database(peer.db) as database:
        _ = database.execute("drop trigger synthetic_fail")
    assert peer.last_request is not None
    request, descriptor = peer.last_request
    response = redeem_native_pairing(
        peer.db, request, descriptor, (peer.receiver, peer.connections)
    )
    assert (
        redeem_native_pairing(
            peer.db, request, descriptor, (peer.receiver, peer.connections)
        )
        == response
    )
    assert service.accept(peer.upload(trusted)).receipt.result == "committed"


def test_populated_old_schema_preserves_enrollment_and_requires_same_peer_replay(
    peer: NativePeer, monkeypatch: pytest.MonkeyPatch
) -> None:
    original_provision = MailboxProvisioningTransaction.__call__

    def old_provision(
        transaction: MailboxProvisioningTransaction,
        completion: PairingRedemptionCompletion,
    ) -> None:
        _ = original_provision(transaction, completion)

    with monkeypatch.context() as old:
        old.setattr(
            database_module, "MIGRATION_IDS", database_module.MIGRATION_IDS[:-1]
        )
        old.setattr(MailboxProvisioningTransaction, "__call__", old_provision)
        trusted = peer.enroll()
        _ = ingest_fixture(
            peer.db,
            Path(__file__).parents[2]
            / "fixtures/health_bridge_batch_v1.synthetic.json",
        )
        with connect_database(peer.db) as database:
            assert (
                database.execute(
                    """select 1 from pragma_table_info('pairing_invitation_redemptions')
                    where name = 'mailbox_enrollment_sha256'"""
                ).fetchone()
                is None
            )
            original_samples = database.execute("select * from samples").fetchall()
            original_rows = database.execute(
                "select * from receiver_devices"
            ).fetchall()
            original_tokens = database.execute(
                "select * from receiver_tokens"
            ).fetchall()
    initialize_database(peer.db)
    initialize_database(peer.db)
    with connect_database(peer.db) as database:
        assert database.execute("select * from samples").fetchall() == original_samples
        assert (
            database.execute("select * from receiver_devices").fetchall()
            == original_rows
        )
        assert (
            database.execute("select * from receiver_tokens").fetchall()
            == original_tokens
        )
    assert peer.trusted().enrollment_digest() == trusted.enrollment_digest()
    service = DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
    before = counts(peer.db)
    unbound = service.accept(peer.upload(trusted))
    assert unbound.receipt.result == "retryable"
    assert unbound.receipt.error_code == "storage_unavailable"
    assert counts(peer.db) == before
    assert peer.last_request is not None
    request, descriptor = peer.last_request
    first = redeem_native_pairing(
        peer.db, request, descriptor, (peer.receiver, peer.connections)
    )
    assert (
        redeem_native_pairing(
            peer.db, request, descriptor, (peer.receiver, peer.connections)
        )
        == first
    )
    assert service.accept(peer.upload(trusted)).receipt.result == "committed"

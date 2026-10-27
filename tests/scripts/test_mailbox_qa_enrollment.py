from collections.abc import Generator
from dataclasses import dataclass, replace
from http.client import HTTPConnection
from pathlib import Path
from threading import Thread

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.mailbox.connections import (
    MailboxConnectionStore,
    MailboxTrustedConnectionRecord,
)
from health_bridge.mailbox_qa.qa_pairing_contract import (
    QAPairingRedeemRequest,
    base64url,
)
from health_bridge.mailbox_qa.qa_runtime import (
    QAReceiverHTTPServer,
    QAReceiverRuntime,
    provision_qa_mailbox,
)
from health_bridge.receiver.delivery_acceptance import (
    DeliveryAcceptanceRequest,
    DeliveryAcceptanceService,
    DeliveryTrustedConnection,
)
from health_bridge.receiver.invitations import create_pairing_invitation
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.storage.database import connect_database
from tests.contract.delivery_v1_support import BATCH
from tests.receiver.delivery_acceptance_support import NOW_MS, counts
from tests.scripts.test_mailbox_qa_pairing_runtime import CompletionDocument


@dataclass
class QAPeer:
    server: QAReceiverHTTPServer
    request: QAPairingRedeemRequest
    signing: Ed25519PrivateKey

    def post(self, request: QAPairingRedeemRequest | None = None) -> tuple[int, bytes]:
        connection = HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=5
        )
        try:
            connection.request(
                "POST",
                "/qa/v1/pairing/redeem",
                body=(request or self.request).model_dump_json().encode(),
                headers={"Content-Type": "application/json"},
            )
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def trusted(self) -> DeliveryTrustedConnection:
        root = self.server.runtime_root
        key_store = MailboxKeyStore.for_testing(
            state_dir=root / "private/receiver-keys",
            anchor_dir=root / "private/receiver-anchor",
        )
        store = MailboxConnectionStore.for_testing(
            root / "private/connections", key_store
        )
        path = next((root / "private/connections").glob("*.hbjcs1"))
        record = MailboxTrustedConnectionRecord.model_validate_json(path.read_bytes())
        return store.load(
            self.server.mailbox_root / record.receiver_id / record.device_id
        )

    def accept(self, trusted: DeliveryTrustedConnection) -> delivery.DeliveryReceiptV1:
        envelope = delivery.create_delivery_envelope(
            BATCH.replace(b"synthetic.phone.alpha", b"apple_health.phone"),
            delivery.DeliveryCreateParams(
                envelope_id=b"\x24" * 16,
                receiver_id=trusted.receiver_id,
                device_id=trusted.device_id,
                connection_generation=trusted.connection_generation,
                created_at_ms=NOW_MS,
                receiver_agreement_public_key=trusted.receiver_agreement_private_key.public_key(),
                sender_signing_private_key=self.signing,
            ),
        )
        return (
            DeliveryAcceptanceService(self.server.db_path, trusted, lambda: NOW_MS)
            .accept(
                DeliveryAcceptanceRequest(
                    envelope.to_bytes(),
                    trusted.device_principal,
                    trusted.opaque_binding,
                )
            )
            .receipt
        )


@pytest.fixture
def qa_peer(tmp_path: Path) -> Generator[QAPeer, None, None]:
    runtime = tmp_path / "runtime"
    runtime.mkdir(mode=0o700)
    server = QAReceiverHTTPServer(
        "127.0.0.1",
        0,
        QAReceiverRuntime(
            db_path=runtime / "receiver.sqlite",
            runtime_root=runtime,
            mailbox_root=runtime / "mailbox-qa",
            namespace="qa-grant",
        ),
    )
    # Explicit Mailbox isolates callback ownership from lifecycle's transport default.
    invitation = create_pairing_invitation(
        server.db_path,
        label="qa-grant",
        receiver_url="http://127.0.0.1:12345/v1/batches",
        transport="mailbox",
    )
    signing = Ed25519PrivateKey.generate()
    agreement = X25519PrivateKey.generate()
    request = QAPairingRedeemRequest(
        invitation_secret=invitation.invitation_secret,
        device_credential="hb_" + base64url(b"c" * 32),
        installation_id="00000000-0000-4000-8000-000000000001",
        device_signing_public_key=base64url(signing.public_key().public_bytes_raw()),
        device_agreement_public_key=base64url(
            agreement.public_key().public_bytes_raw()
        ),
        namespace=server.namespace,
        run_id="10" * 16,
        challenge=base64url(b"h" * 32),
    )
    worker = Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield QAPeer(server, request, signing)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


def test_qa_redemption_commits_exact_persisted_grant_and_replays(
    qa_peer: QAPeer,
) -> None:
    status, encoded = qa_peer.post()
    assert status == 200
    completion = CompletionDocument.model_validate_json(encoded)
    trusted = qa_peer.trusted()
    assert trusted.device_principal.value == f"qa:{trusted.device_id.hex()}"
    assert trusted.source_principal.installation_id_hash is not None
    assert not qa_peer.server.mailbox_root.exists()
    with connect_database(qa_peer.server.db_path) as db:
        assert db.execute(
            "select mailbox_enrollment_sha256 from pairing_invitation_redemptions"
        ).fetchone() == (trusted.enrollment_digest(),)
    assert qa_peer.accept(trusted).result == "committed"
    assert counts(qa_peer.server.db_path) == (1, 1, 1)
    status, repeated = qa_peer.post()
    assert status == 200
    assert CompletionDocument.model_validate_json(repeated) == completion
    assert (
        qa_peer.post(
            qa_peer.request.model_copy(
                update={"device_credential": "hb_" + base64url(b"d" * 32)}
            )
        )[0]
        == 400
    )
    assert (
        qa_peer.post(qa_peer.request.model_copy(update={"namespace": "qa-other"}))[0]
        == 400
    )
    with connect_database(qa_peer.server.db_path) as db:
        assert db.execute("select count(*) from receiver_tokens").fetchone() == (1,)
        assert db.execute(
            "select count(*) from pairing_invitation_redemptions"
        ).fetchone() == (1,)


@pytest.mark.parametrize("failure", ["file_only", "callback", "sqlite"])
def test_qa_orphan_has_no_grant_and_exact_request_recovers(
    qa_peer: QAPeer,
    failure: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    if failure == "file_only":
        completion = provision_qa_mailbox(qa_peer.server, qa_peer.request)
        assert completion["kind"] == "health_bridge.mailbox_qa_pairing_completion.v1"
    elif failure == "callback":

        def fail_anchor(_path: Path, _text: str) -> None:
            message = "synthetic anchor publication failure after trust save"
            raise OSError(message)

        with monkeypatch.context() as patch:
            patch.setattr(
                "health_bridge.mailbox_qa.qa_runtime.write_private_text_file",
                fail_anchor,
            )
            assert qa_peer.post()[0] == 400
    else:
        with connect_database(qa_peer.server.db_path) as db:
            _ = db.executescript("""
                create table synthetic_failure (device integer
                    references receiver_devices(receiver_device_id)
                    deferrable initially deferred);
                create trigger synthetic_fail
                after update of mailbox_enrollment_sha256
                on pairing_invitation_redemptions
                begin insert into synthetic_failure values (-1); end;
            """)
        assert qa_peer.post()[0] == 400
        with connect_database(qa_peer.server.db_path) as db:
            _ = db.execute("drop trigger synthetic_fail")
    trusted = qa_peer.trusted()
    assert not qa_peer.server.mailbox_root.exists()
    with connect_database(qa_peer.server.db_path) as db:
        assert db.execute(
            "select count(*) from pairing_invitation_redemptions"
        ).fetchone() == (0,)
        assert db.execute("select count(*) from receiver_tokens").fetchone() == (0,)
        assert db.execute("select redeemed_at from pairing_invitations").fetchone() == (
            None,
        )
    assert qa_peer.accept(trusted).error_code == "key_revoked"
    assert counts(qa_peer.server.db_path) == (0, 0, 0)
    assert qa_peer.post()[0] == 200
    assert qa_peer.accept(trusted).result == "committed"


@pytest.mark.parametrize(
    "mutation",
    ["null_digest", "principal", "binding", "key", "token", "device", "direct"],
)
def test_qa_grant_does_not_authorize_changed_or_revoked_trust(
    qa_peer: QAPeer,
    mutation: str,
) -> None:
    assert qa_peer.post()[0] == 200
    trusted = qa_peer.trusted()
    if mutation == "principal":
        trusted = replace(
            trusted, device_principal=delivery.DevicePrincipal("qa:other")
        )
    elif mutation == "binding":
        trusted = replace(trusted, opaque_binding=delivery.OpaqueBinding(bytes(32)))
    elif mutation == "key":
        trusted = replace(
            trusted,
            device_agreement_public_key=X25519PrivateKey.generate().public_key(),
        )
    else:
        sql = {
            "null_digest": """update pairing_invitation_redemptions
                set mailbox_enrollment_sha256 = null""",
            "token": "update receiver_tokens set revoked_at = '2026-01-01T00:00:00Z'",
            "device": "update receiver_devices set revoked_at = '2026-01-01T00:00:00Z'",
            "direct": "update pairing_invitations set transport = 'direct'",
        }[mutation]
        with connect_database(qa_peer.server.db_path) as db:
            _ = db.execute(sql)
    assert qa_peer.accept(trusted).error_code == "key_revoked"
    assert counts(qa_peer.server.db_path) == (0, 0, 0)

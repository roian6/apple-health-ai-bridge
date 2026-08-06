from __future__ import annotations

import base64
import json
import os
import threading
import uuid
from http.client import HTTPConnection
from typing import TYPE_CHECKING, ClassVar, Literal
from urllib.parse import parse_qs, urlparse

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from pydantic import BaseModel, ConfigDict

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.mailbox_qa.lifecycle import (
    acknowledgment_ready,
    create_pairing_material,
    prepare_receiver,
    receiver_receipt_private_key,
)
from health_bridge.mailbox_qa.m3_models import ScenarioReceiptV1
from health_bridge.mailbox_qa.production_seal import (
    load_production_identity_seal,
    production_seal_fingerprint,
)
from health_bridge.mailbox_qa.qa_runtime import QAReceiverHTTPServer, QAReceiverRuntime
from health_bridge.mailbox_qa.receiver import QAReceiverConfig
from health_bridge.mailbox_qa.receiver_operations import (
    issue_receiver_receipts,
    run_receiver_operation,
)
from health_bridge.mailbox_qa.scenario_issuance import ScenarioReceiptContextV1
from tests.contract.delivery_v1_support import BATCH
from tests.scripts.production_seal_support import (
    synthetic_qa_request,
    write_synthetic_production_seal,
)

if TYPE_CHECKING:
    from pathlib import Path


class InvocationDocument(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    v: Literal[1]
    kind: Literal["health_bridge.mailbox_qa_invocation.v1"]
    action: Literal["pair"]
    run_id: str
    challenge: str
    source_commit: str
    bundle_identifier: str
    container_identifier: str
    keychain_service: str
    outbox_root: str
    namespace: str
    redeem_url: str
    invitation_secret: str


class CompletionDocument(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    v: Literal[1]
    kind: Literal["health_bridge.mailbox_qa_pairing_completion.v1"]
    namespace: str
    receiver_id: str
    device_id: str
    receiver_binding_id: str
    connection_generation: int
    receiver_signing_public_key: str
    receiver_agreement_public_key: str
    receiver_signing_key_id: str
    receiver_agreement_key_id: str


def test_qa_http_pairing_redeems_one_secret_without_creating_mailbox(  # noqa: PLR0915
    tmp_path: Path,
) -> None:
    # Given: a fresh ephemeral QA receiver and one private invitation secret.
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    server = QAReceiverHTTPServer(
        "127.0.0.1",
        0,
        QAReceiverRuntime(
            db_path=runtime / "receiver.sqlite",
            runtime_root=runtime,
            mailbox_root=runtime / "mailbox-qa",
            namespace="qa-run-001",
        ),
    )
    port = server.server_address[1]
    seal_path = tmp_path / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(seal_path)
    seal = load_production_identity_seal(seal_path, anchor)
    qa = synthetic_qa_request(runtime)
    config = QAReceiverConfig(
        runtime_root=runtime,
        host="127.0.0.1",
        port=port,
        namespace="qa-run-001",
        bundle_identifier=qa.bundle_identifier,
        container_identifier=qa.container_identifier,
        url_scheme=qa.url_scheme,
        keychain_service=qa.keychain_service,
        keychain_access_groups=qa.keychain_access_groups,
        outbox_root=qa.outbox_root,
        display_identity=qa.display_identity,
        database_namespace=qa.database_namespace,
        app_path=qa.app_path,
        production_seal=seal,
        production_seal_fingerprint=production_seal_fingerprint(seal),
    )
    _ = prepare_receiver(config)
    invocation_path = create_pairing_material(
        config,
        run_id="10" * 16,
        challenge="ERERERERERERERERERERERERERERERERERERERERERE",
        source_commit="6eb12a4fb29543e691c7e930f385dc4f9964598f",
    )
    invocation = InvocationDocument.model_validate_json(invocation_path.read_bytes())
    invocation_url = urlparse(
        invocation_path.with_suffix(".url").read_text(encoding="ascii")
    )
    encoded_request = parse_qs(invocation_url.query)["request"]
    assert len(encoded_request) == 1
    assert base64.b64decode(encoded_request[0]) == invocation_path.read_bytes()
    assert (invocation_url.scheme, invocation_url.hostname) == (
        "healthbridgeqa",
        "invoke",
    )
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()

    # When: synthetic signing/agreement keys redeem only that secret.
    device_signing = Ed25519PrivateKey.generate()
    device_agreement = X25519PrivateKey.generate()
    body = json.dumps(
        {
            "invitation_secret": invocation.invitation_secret,
            "device_credential": f"hb_{_random_base64url()}",
            "installation_id": str(uuid.uuid4()),
            "device_signing_public_key": _public_text(
                device_signing.public_key().public_bytes_raw()
            ),
            "device_agreement_public_key": _public_text(
                device_agreement.public_key().public_bytes_raw()
            ),
            "namespace": invocation.namespace,
            "run_id": invocation.run_id,
            "challenge": invocation.challenge,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    redeem_url = urlparse(invocation.redeem_url)
    assert redeem_url.hostname is not None
    assert redeem_url.port is not None
    connection = HTTPConnection(redeem_url.hostname, redeem_url.port, timeout=5)
    try:
        connection.request(
            "POST",
            redeem_url.path,
            body=body,
            headers={"Content-Type": "application/json"},
        )
        response = connection.getresponse()
        status = response.status
        completion = CompletionDocument.model_validate_json(response.read())
    finally:
        connection.close()
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)

    # Then: the authenticated contract provisions only the QA connection state.
    assert status == 200
    assert completion.kind == "health_bridge.mailbox_qa_pairing_completion.v1"
    assert completion.namespace == config.namespace
    assert len(list((runtime / "private/connections").glob("*.hbjcs1"))) == 1
    mailbox_root = runtime / "mailbox-qa"
    assert list(mailbox_root.glob("*/*")) == []
    envelope_id = b"\x17" * 16
    paired_batch = BATCH.replace(b"synthetic.phone.alpha", b"apple_health.phone")
    envelope = delivery.create_delivery_envelope(
        paired_batch,
        delivery.DeliveryCreateParams(
            envelope_id=envelope_id,
            receiver_id=_decode(completion.receiver_id),
            device_id=_decode(completion.device_id),
            connection_generation=completion.connection_generation,
            created_at_ms=1_782_000_000_000,
            receiver_agreement_public_key=_agreement_public(
                completion.receiver_agreement_public_key
            ),
            sender_signing_private_key=device_signing,
        ),
    ).to_bytes()
    # The app owns first creation of the public mailbox tree. This test fixture
    # takes the app role only after pairing has proved it left the tree absent.
    mailbox = (
        mailbox_root
        / _decode(completion.receiver_id).hex()
        / _decode(completion.device_id).hex()
    )
    for lane in ("deliveries", "acks", "pairing", "quarantine"):
        (mailbox / lane).mkdir(mode=0o700, parents=True, exist_ok=True)
    delivery_path = mailbox / "deliveries" / f"{envelope_id.hex()}.hbd"
    _ = delivery_path.write_bytes(envelope)
    delivery_path.chmod(0o600)

    imported = run_receiver_operation(config, "one_shot_importer")
    assert (
        imported.imported,
        imported.idempotent,
        imported.quarantined,
        imported.retryable,
        imported.conflict,
        imported.skipped,
    ) == (1, 0, 0, 0, 0, 0)
    assert imported.delivery_sha256_before == imported.delivery_sha256_after
    ack_path = next((mailbox / "acks").glob("*.hba"))
    receipt = delivery.open_delivery_ack(
        ack_path.read_bytes(),
        delivery.AckOpenParams(
            envelope_id=envelope_id,
            receiver_id=_decode(completion.receiver_id),
            device_id=_decode(completion.device_id),
            connection_generation=completion.connection_generation,
            device_agreement_private_key=device_agreement,
            receiver_signing_public_key=_signing_public(
                completion.receiver_signing_public_key
            ),
            receiver_agreement_public_key=_agreement_public(
                completion.receiver_agreement_public_key
            ),
        ),
    )
    assert acknowledgment_ready(config)
    assert receipt.result == "committed"
    duplicate = run_receiver_operation(config, "duplicate_identical")
    assert duplicate.idempotent == 1
    assert duplicate.imported == 0
    assert duplicate.ack_count_after == 1
    conflict = run_receiver_operation(config, "conflict_rejected")
    assert conflict.injected_local_conflict
    assert conflict.quarantined == 1
    assert conflict.delivery_sha256_before == conflict.delivery_sha256_after
    assert conflict.ack_count_after == 1
    receipt_context = ScenarioReceiptContextV1(
        v=1,
        kind="health_bridge.mailbox_qa_receipt_context.v1",
        run_id=invocation.run_id,
        challenge=invocation.challenge,
        head=invocation.source_commit,
        qa_bundle_fingerprint="12" * 8,
        qa_container_fingerprint="34" * 8,
        created_at_ms=0,
        expires_at_ms=2**62,
    )
    owner_key = receiver_receipt_private_key(config)
    issued = (
        *issue_receiver_receipts(imported, receipt_context, owner_key),
        *issue_receiver_receipts(duplicate, receipt_context, owner_key),
        *issue_receiver_receipts(conflict, receipt_context, owner_key),
    )
    parsed = tuple(ScenarioReceiptV1.model_validate(receipt) for receipt in issued)
    assert {receipt.scenario for receipt in parsed} == {
        "one_shot_importer",
        "strict_receiver_parse_without_reserialization",
        "duplicate_identical",
        "conflict_rejected",
    }
    assert all(receipt.issuance == "operation_v1" for receipt in parsed)


def _random_base64url() -> str:
    return base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode("ascii")


def _public_text(encoded: bytes) -> str:
    return base64.urlsafe_b64encode(encoded).rstrip(b"=").decode("ascii")


def _decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _signing_public(value: str) -> Ed25519PublicKey:
    return Ed25519PublicKey.from_public_bytes(_decode(value))


def _agreement_public(value: str) -> X25519PublicKey:
    return X25519PublicKey.from_public_bytes(_decode(value))

from __future__ import annotations

import hashlib
import sqlite3
from dataclasses import dataclass
from http import HTTPStatus
from http.server import ThreadingHTTPServer
from typing import TYPE_CHECKING, cast
from urllib.parse import urlparse

from pydantic import ValidationError
from typing_extensions import override

from health_bridge.contract._delivery_common import key_id
from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_encode
from health_bridge.mailbox.connections import (
    MailboxConnectionStore,
    MailboxTrustedConnectionRecord,
)
from health_bridge.mailbox_qa.qa_pairing_contract import (
    QAPairingRedeemRequest,
    base64url,
    decode32,
)
from health_bridge.private_files import write_private_text_file
from health_bridge.receiver.invitations import (
    PairingInvitationError,
    PairingRedemptionCompletion,
    redeem_pairing_invitation,
)
from health_bridge.receiver.mailbox_keys import MailboxKeyStore, MailboxKeyStoreError
from health_bridge.receiver.server import (
    MAX_PAIRING_REDEEM_BYTES,
    PairingRedeemRateLimiter,
    ReceiverHTTPServer,
    ReceiverRequestHandler,
)
from health_bridge.storage.database import initialize_database

if TYPE_CHECKING:
    from pathlib import Path


@dataclass(frozen=True)
class QAReceiverRuntime:
    db_path: Path
    runtime_root: Path
    mailbox_root: Path
    namespace: str


class QAReceiverHTTPServer(ReceiverHTTPServer):
    db_path: Path
    runtime_root: Path
    mailbox_root: Path
    namespace: str
    pairing_redeem_limiter: PairingRedeemRateLimiter

    def __init__(
        self,
        host: str,
        port: int,
        runtime: QAReceiverRuntime,
    ) -> None:
        self.db_path = runtime.db_path
        self.runtime_root = runtime.runtime_root
        self.mailbox_root = runtime.mailbox_root
        self.namespace = runtime.namespace
        self.pairing_redeem_limiter = PairingRedeemRateLimiter()
        ThreadingHTTPServer.__init__(self, (host, port), QAReceiverRequestHandler)


class QAReceiverRequestHandler(ReceiverRequestHandler):
    @property
    def qa_server(self) -> QAReceiverHTTPServer:
        return cast("QAReceiverHTTPServer", self.server)

    @override
    def do_POST(self) -> None:
        if urlparse(self.path).path != "/qa/v1/pairing/redeem":
            super().do_POST()
            return
        client_key = self.client_address[0]
        if not self.qa_server.pairing_redeem_limiter.allow(client_key):
            self._send_json(
                HTTPStatus.TOO_MANY_REQUESTS,
                {"error": "pairing_rate_limited"},
            )
            return
        body = self._read_body(
            max_bytes=MAX_PAIRING_REDEEM_BYTES,
            too_large_error="pairing_request_too_large",
        )
        if body is None:
            return
        try:
            request = QAPairingRedeemRequest.model_validate_json(body)
            _require_namespace(request.namespace, self.qa_server.namespace)
            responses: list[dict[str, bool | int | str]] = []

            def provision(_completion: PairingRedemptionCompletion) -> None:
                responses.append(provision_qa_mailbox(self.qa_server, request))

            _ = redeem_pairing_invitation(
                self.qa_server.db_path,
                invitation_secret=request.invitation_secret,
                installation_id=request.installation_id,
                device_credential=request.device_credential,
                platform="ios",
                before_commit=provision,
            )
            response = responses[0]
        except (
            PairingInvitationError,
            MailboxKeyStoreError,
            OSError,
            ValueError,
            ValidationError,
            sqlite3.Error,
        ):
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "qa_pairing_rejected"},
            )
            return
        self._send_json(HTTPStatus.OK, response)


def provision_qa_mailbox(
    server: QAReceiverHTTPServer,
    request: QAPairingRedeemRequest,
) -> dict[str, bool | int | str]:
    key_store = MailboxKeyStore.for_testing(
        state_dir=server.runtime_root / "private/receiver-keys",
        anchor_dir=server.runtime_root / "private/receiver-anchor",
    )
    identity = key_store.load_or_create()
    receiver_id = hashlib.sha256(
        b"health-bridge/mailbox-qa/receiver\0" + server.namespace.encode()
    ).digest()[:16]
    device_id = hashlib.sha256(
        b"health-bridge/mailbox-qa/device\0" + request.installation_id.encode()
    ).digest()[:16]
    binding = hashlib.sha256(
        b"health-bridge/mailbox-qa/binding\0"
        + receiver_id
        + device_id
        + bytes.fromhex(request.run_id)
    ).digest()
    installation_id_hash = hashlib.sha256(
        f"health-bridge-pairing:installation:{request.installation_id}".encode()
    ).hexdigest()
    device_signing = decode32(request.device_signing_public_key)
    device_agreement = decode32(request.device_agreement_public_key)
    connection_root = server.runtime_root / "private/connections"
    connection_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    connection_store = MailboxConnectionStore.for_testing(
        connection_root,
        key_store,
    )
    connection_store.save(
        MailboxTrustedConnectionRecord(
            receiver_id=receiver_id.hex(),
            device_id=device_id.hex(),
            connection_generation=1,
            device_principal=f"qa:{device_id.hex()}",
            opaque_binding=base64url(binding),
            device_signing_key_id=key_id("ed25519", device_signing),
            device_agreement_key_id=key_id("x25519", device_agreement),
            receiver_signing_key_id=identity.signing_key_id,
            receiver_agreement_key_id=identity.agreement_key_id,
            sender_signing_public_key=request.device_signing_public_key,
            device_agreement_public_key=request.device_agreement_public_key,
            installation_id_hash=installation_id_hash,
        )
    )
    document: dict[str, JsonValue] = {
        "v": 1,
        "kind": "health_bridge.mailbox_qa_connection_anchor.v1",
        "namespace": server.namespace,
        "run_id": request.run_id,
        "challenge": request.challenge,
        "receiver_id": receiver_id.hex(),
        "device_id": device_id.hex(),
        "receiver_binding_id": binding.hex(),
        "connection_generation": 1,
        "device_signing_public_key": request.device_signing_public_key,
        "device_agreement_public_key": request.device_agreement_public_key,
        "receiver_signing_public_key": base64url(identity.signing_public_key),
        "receiver_agreement_public_key": base64url(identity.agreement_public_key),
    }
    anchor_name = hashlib.sha256(
        request.run_id.encode() + request.challenge.encode()
    ).hexdigest()[:32]
    write_private_text_file(
        server.runtime_root / "private/pairing" / f"{anchor_name}.hbjcs1",
        hbjcs1_encode(document).decode("utf-8"),
    )
    return {
        "v": 1,
        "kind": "health_bridge.mailbox_qa_pairing_completion.v1",
        "namespace": server.namespace,
        "receiver_id": base64url(receiver_id),
        "device_id": base64url(device_id),
        "receiver_binding_id": base64url(binding),
        "connection_generation": 1,
        "receiver_signing_public_key": base64url(identity.signing_public_key),
        "receiver_agreement_public_key": base64url(identity.agreement_public_key),
        "receiver_signing_key_id": key_id(
            "ed25519",
            identity.signing_public_key,
        ),
        "receiver_agreement_key_id": key_id(
            "x25519",
            identity.agreement_public_key,
        ),
    }


def _require_namespace(candidate: str, expected: str) -> None:
    if candidate != expected:
        raise ValueError


def serve_qa_receiver(
    host: str,
    port: int,
    runtime: QAReceiverRuntime,
) -> None:
    initialize_database(runtime.db_path)
    with QAReceiverHTTPServer(
        host,
        port,
        runtime,
    ) as server:
        server.serve_forever()


__all__ = ["QAReceiverRuntime", "provision_qa_mailbox", "serve_qa_receiver"]

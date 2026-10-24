from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pathlib import Path
from urllib.request import Request

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.contract._delivery_common import b64encode
from health_bridge.mailbox.connections import MailboxConnectionStore
from health_bridge.receiver.delivery_acceptance import (
    DeliveryAcceptanceRequest,
    DeliveryTrustedConnection,
)
from health_bridge.receiver.invitations import create_pairing_invitation
from health_bridge.receiver.mailbox_bootstrap import (
    BootstrapDescriptor,
    NativePairingRequest,
    seal_pairing_request,
)
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.pairing import create_receiver_pairing_invitation_bundle
from tests.contract.delivery_v1_support import BATCH
from tests.receiver.delivery_acceptance_support import NOW_MS
from tests.receiver.test_pairing_redeem_server import (
    open_http_response,
    redeem_body,
    running_receiver,
)

INSTALLATION = "00000000-0000-4000-8000-000000000001"
CREDENTIAL = "hb_" + "a" * 64


@dataclass
class LegacyPeer:
    root: Path

    @property
    def db(self) -> Path:
        return self.root / "health.sqlite"

    @property
    def receiver(self) -> MailboxKeyStore:
        return MailboxKeyStore.for_testing(
            state_dir=self.root / "receiver", anchor_dir=self.root / "receiver-anchor"
        )

    @property
    def device(self) -> MailboxKeyStore:
        return MailboxKeyStore.for_testing(
            state_dir=self.root / "device", anchor_dir=self.root / "device-anchor"
        )

    @property
    def connections(self) -> MailboxConnectionStore:
        return MailboxConnectionStore.for_testing(
            self.root / "connections", self.receiver
        )

    def register(self) -> DeliveryTrustedConnection:
        invitation = create_pairing_invitation(
            self.db,
            label="synthetic",
            receiver_url="https://receiver.example.test/v1/batches",
            transport="mailbox",
        )
        identity = self.device.load_or_create()
        with running_receiver(
            self.db,
            mailbox_key_store=self.receiver,
            mailbox_connection_store=self.connections,
        ) as origin:
            request = Request(
                f"{origin}/v1/pairing/redeem",
                data=redeem_body(
                    invitation_secret=invitation.invitation_secret,
                    device_signing_public_key=b64encode(identity.signing_public_key),
                    device_agreement_public_key=b64encode(
                        identity.agreement_public_key
                    ),
                ),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with open_http_response(request) as response:
                assert response.status == 200
                assert json.loads(response.read())["mailbox_protocol_version"] == 1
        return self.trusted()

    def trusted(self) -> DeliveryTrustedConnection:
        receiver_id = hashlib.sha256(
            b"health-bridge/mailbox/v1/receiver-id\0"
            + self.receiver.load_or_create().signing_public_key
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


def stage_native(peer: LegacyPeer) -> tuple[BootstrapDescriptor, bytes]:
    invitation = create_receiver_pairing_invitation_bundle(
        peer.db,
        label="native-synthetic",
        receiver_url=None,
        transport="mailbox",
        mailbox_key_store=peer.receiver,
    )
    descriptor = invitation.mailbox_bootstrap
    assert descriptor is not None
    identity = peer.device.load_or_create()
    return descriptor, seal_pairing_request(
        NativePairingRequest(
            invitation_secret=invitation.invitation_secret,
            installation_id=INSTALLATION,
            device_credential="hb_" + descriptor.invitation_id * 2,
            platform="ios",
            device_signing_public_key=b64encode(identity.signing_public_key),
            device_agreement_public_key=b64encode(identity.agreement_public_key),
        ),
        descriptor,
        peer.device,
    )

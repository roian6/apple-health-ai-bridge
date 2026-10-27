from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Final
from uuid import UUID

from health_bridge.contract._delivery_common import key_id
from health_bridge.contract._hbjcs1 import hbjcs1_encode
from health_bridge.mailbox.connections import (
    MailboxConnectionError,
    MailboxConnectionErrorCode,
    MailboxConnectionStore,
    MailboxTrustedConnectionRecord,
    strict_base64url_encode,
)
from health_bridge.receiver._mailbox_key_models import (
    MailboxKeyStoreError,
    strict_base64url_decode,
)
from health_bridge.receiver.invitations import (
    PairingRedemptionCompletion,
    cancel_native_invitation,
    redeem_pairing_invitation,
)
from health_bridge.receiver.mailbox_bootstrap import (
    BootstrapDescriptor,
    open_pairing_request,
    seal_cancellation_receipt,
    seal_pairing_completion,
    verify_pairing_cancellation,
)
from health_bridge.receiver.transports import ReceiverTransport

if TYPE_CHECKING:
    from collections.abc import Callable

    from health_bridge.receiver.mailbox_keys import MailboxKeyStore

_RECEIVER_ID_DOMAIN: Final = b"health-bridge/mailbox/v1/receiver-id\0"
_DEVICE_ID_DOMAIN: Final = b"health-bridge/mailbox/v1/device-id\0"
_BINDING_DOMAIN: Final = b"health-bridge/mailbox/v1/connection-binding\0"
_HASH_HEX_LENGTH: Final = 64


@dataclass(frozen=True, slots=True)
class MailboxPairingCompletion:
    receiver_id: str
    device_id: str
    receiver_binding_id: str
    connection_generation: int
    receiver_signing_public_key: str
    receiver_agreement_public_key: str
    receiver_signing_key_id: str
    receiver_agreement_key_id: str


def provision_mailbox_connection(
    *,
    connection_store: MailboxConnectionStore,
    key_store: MailboxKeyStore,
    installation_id_hash: str,
    device_signing_public_key: str,
    device_agreement_public_key: str,
) -> MailboxPairingCompletion:
    """Provision one immutable local trust record for a capable iPhone."""
    if (
        len(installation_id_hash) != _HASH_HEX_LENGTH
        or not installation_id_hash.isascii()
    ):
        raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED)
    try:
        installation_hash = bytes.fromhex(installation_id_hash)
        device_signing = strict_base64url_decode(device_signing_public_key, 32)
        device_agreement = strict_base64url_decode(device_agreement_public_key, 32)
    except (MailboxKeyStoreError, ValueError) as exc:
        raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED) from exc
    receiver = key_store.load_or_create()
    receiver_id = hashlib.sha256(
        _RECEIVER_ID_DOMAIN + receiver.signing_public_key
    ).digest()[:16]
    device_id = hashlib.sha256(_DEVICE_ID_DOMAIN + installation_hash).digest()[:16]
    binding = hashlib.sha256(
        _BINDING_DOMAIN
        + receiver_id
        + device_id
        + device_signing
        + device_agreement
        + receiver.signing_public_key
        + receiver.agreement_public_key
    ).digest()
    receiver_binding_id = strict_base64url_encode(binding)
    connection_store.save(
        MailboxTrustedConnectionRecord(
            receiver_id=receiver_id.hex(),
            device_id=device_id.hex(),
            connection_generation=1,
            device_principal=f"installation:{installation_id_hash}",
            opaque_binding=receiver_binding_id,
            device_signing_key_id=key_id("ed25519", device_signing),
            device_agreement_key_id=key_id("x25519", device_agreement),
            receiver_signing_key_id=receiver.signing_key_id,
            receiver_agreement_key_id=receiver.agreement_key_id,
            sender_signing_public_key=device_signing_public_key,
            device_agreement_public_key=device_agreement_public_key,
            installation_id_hash=installation_id_hash,
        )
    )
    return MailboxPairingCompletion(
        receiver_id=receiver_id.hex(),
        device_id=device_id.hex(),
        receiver_binding_id=receiver_binding_id,
        connection_generation=1,
        receiver_signing_public_key=strict_base64url_encode(
            receiver.signing_public_key
        ),
        receiver_agreement_public_key=strict_base64url_encode(
            receiver.agreement_public_key
        ),
        receiver_signing_key_id=receiver.signing_key_id,
        receiver_agreement_key_id=receiver.agreement_key_id,
    )


__all__ = ["MailboxPairingCompletion", "provision_mailbox_connection"]


@dataclass
class MailboxProvisioningTransaction:
    key_store: MailboxKeyStore | None
    connection_store: MailboxConnectionStore | None
    device_signing_public_key: str | None
    device_agreement_public_key: str | None
    completion: MailboxPairingCompletion | None = None
    validate_request: Callable[[], None] | None = None

    def __call__(self, redemption: PairingRedemptionCompletion) -> str | None:
        match redemption.transport:
            case ReceiverTransport.DIRECT:
                return None
            case ReceiverTransport.MAILBOX:
                pass
        if self.key_store is None or self.connection_store is None:
            raise MailboxTransportUnavailableError
        if (
            self.device_signing_public_key is None
            or self.device_agreement_public_key is None
        ):
            raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED)
        _validate_mailbox_public_keys(
            self.device_signing_public_key,
            self.device_agreement_public_key,
        )
        self.completion = provision_mailbox_connection(
            connection_store=self.connection_store,
            key_store=self.key_store,
            installation_id_hash=redemption.installation_id_hash,
            device_signing_public_key=self.device_signing_public_key,
            device_agreement_public_key=self.device_agreement_public_key,
        )
        if self.validate_request is not None:
            self.validate_request()
        trusted = self.connection_store.load(
            Path(self.completion.receiver_id) / self.completion.device_id
        )
        return trusted.enrollment_digest()


class MailboxTransportUnavailableError(Exception):
    pass


def _validate_mailbox_public_keys(
    device_signing_public_key: str,
    device_agreement_public_key: str,
) -> None:
    try:
        _ = strict_base64url_decode(device_signing_public_key, 32)
        _ = strict_base64url_decode(device_agreement_public_key, 32)
    except MailboxKeyStoreError as exc:
        raise MailboxConnectionError(MailboxConnectionErrorCode.MALFORMED) from exc


def pairing_completion_fields(
    completion: PairingRedemptionCompletion,
    mailbox: MailboxPairingCompletion | None,
) -> dict[str, str | int | bool | None]:
    fields: dict[str, str | int | bool | None] = {
        "schema_id": "health_bridge.receiver_pairing_completion.v1",
        "schema_version": "1.0.0",
        "label": completion.label,
        "receiver_url": completion.receiver_url,
    }
    if mailbox is not None:
        fields["mailbox_protocol_version"] = 1
        fields.update(
            {
                "mailbox_receiver_id": mailbox.receiver_id,
                "mailbox_device_id": mailbox.device_id,
                "mailbox_receiver_binding_id": mailbox.receiver_binding_id,
                "mailbox_connection_generation": mailbox.connection_generation,
                "mailbox_receiver_signing_public_key": (
                    mailbox.receiver_signing_public_key
                ),
                "mailbox_receiver_agreement_public_key": (
                    mailbox.receiver_agreement_public_key
                ),
                "mailbox_receiver_signing_key_id": mailbox.receiver_signing_key_id,
                "mailbox_receiver_agreement_key_id": mailbox.receiver_agreement_key_id,
            }
        )
    return fields


def redeem_native_pairing(
    db_path: Path,
    encoded_request: bytes,
    descriptor: BootstrapDescriptor,
    receiver: tuple[MailboxKeyStore, MailboxConnectionStore],
    *,
    validate_request: Callable[[], None] | None = None,
) -> bytes:
    keys, connections = receiver
    request = open_pairing_request(encoded_request, descriptor, keys)
    provisioning = MailboxProvisioningTransaction(
        key_store=keys,
        connection_store=connections,
        device_signing_public_key=request.device_signing_public_key,
        device_agreement_public_key=request.device_agreement_public_key,
        validate_request=validate_request,
    )
    completion = redeem_pairing_invitation(
        db_path,
        installation_id=request.installation_id,
        device_credential=request.device_credential,
        platform=request.platform,
        invitation_secret=request.invitation_secret,
        native_invitation_id=str(UUID(hex=descriptor.invitation_id)),
        native_request_sha256=hashlib.sha256(encoded_request).hexdigest(),
        before_commit=provisioning,
    )
    plaintext = hbjcs1_encode(
        dict(pairing_completion_fields(completion, provisioning.completion))
    )
    return seal_pairing_completion(plaintext, encoded_request, keys)


def cancel_native_pairing(  # noqa: PLR0913 - authenticated wire and commit boundary.
    db_path: Path,
    encoded_request: bytes,
    encoded_cancel: bytes,
    descriptor: BootstrapDescriptor,
    keys: MailboxKeyStore,
    *,
    validate_request: Callable[[], None] | None = None,
) -> bytes:
    request = verify_pairing_cancellation(
        encoded_cancel, encoded_request, descriptor, keys
    )
    cancel_native_invitation(
        db_path,
        invitation_id=str(UUID(hex=descriptor.invitation_id)),
        invitation_secret=request.invitation_secret,
        installation_id=request.installation_id,
        device_credential=request.device_credential,
        request_sha256=hashlib.sha256(encoded_request).hexdigest(),
        before_commit=validate_request,
    )
    return seal_cancellation_receipt(encoded_request, descriptor, keys)

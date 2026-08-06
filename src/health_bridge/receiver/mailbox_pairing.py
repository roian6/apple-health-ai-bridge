from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import TYPE_CHECKING, Final

from health_bridge.contract._delivery_common import key_id
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

if TYPE_CHECKING:
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

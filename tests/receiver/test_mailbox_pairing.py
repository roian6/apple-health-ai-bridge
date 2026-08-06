from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from health_bridge.mailbox.connections import (
    MailboxConnectionError,
    MailboxConnectionErrorCode,
    MailboxConnectionStore,
    strict_base64url_encode,
)
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.mailbox_pairing import provision_mailbox_connection


def test_production_pairing_is_idempotent_and_never_creates_public_mailbox(
    tmp_path: Path,
) -> None:
    key_store = MailboxKeyStore.for_testing(
        state_dir=tmp_path / "private/receiver-keys",
        anchor_dir=tmp_path / "private/receiver-anchor",
    )
    connections = MailboxConnectionStore.for_testing(
        tmp_path / "private/connections",
        key_store,
    )
    public_documents = tmp_path / "PublicDocuments"
    signing = Ed25519PrivateKey.generate().public_key().public_bytes_raw()
    agreement = X25519PrivateKey.generate().public_key().public_bytes_raw()

    first = provision_mailbox_connection(
        connection_store=connections,
        key_store=key_store,
        installation_id_hash="11" * 32,
        device_signing_public_key=strict_base64url_encode(signing),
        device_agreement_public_key=strict_base64url_encode(agreement),
    )
    retry = provision_mailbox_connection(
        connection_store=connections,
        key_store=key_store,
        installation_id_hash="11" * 32,
        device_signing_public_key=strict_base64url_encode(signing),
        device_agreement_public_key=strict_base64url_encode(agreement),
    )

    assert retry == first
    assert not public_documents.exists()
    trusted = connections.load(tmp_path / first.receiver_id / first.device_id)
    assert trusted.receiver_id.hex() == first.receiver_id
    assert trusted.device_id.hex() == first.device_id
    assert trusted.connection_generation == 1
    assert trusted.source_principal.installation_id_hash == "11" * 32


def test_production_pairing_rejects_conflicting_reprovisioning(tmp_path: Path) -> None:
    key_store = MailboxKeyStore.for_testing(
        state_dir=tmp_path / "private/receiver-keys",
        anchor_dir=tmp_path / "private/receiver-anchor",
    )
    connections = MailboxConnectionStore.for_testing(
        tmp_path / "private/connections",
        key_store,
    )
    signing = Ed25519PrivateKey.generate().public_key().public_bytes_raw()
    agreement = X25519PrivateKey.generate().public_key().public_bytes_raw()
    _ = provision_mailbox_connection(
        connection_store=connections,
        key_store=key_store,
        installation_id_hash="22" * 32,
        device_signing_public_key=strict_base64url_encode(signing),
        device_agreement_public_key=strict_base64url_encode(agreement),
    )

    with pytest.raises(MailboxConnectionError) as exc_info:
        _ = provision_mailbox_connection(
            connection_store=connections,
            key_store=key_store,
            installation_id_hash="22" * 32,
            device_signing_public_key=strict_base64url_encode(
                Ed25519PrivateKey.generate().public_key().public_bytes_raw()
            ),
            device_agreement_public_key=strict_base64url_encode(agreement),
        )

    assert exc_info.value.code is MailboxConnectionErrorCode.CONFLICT

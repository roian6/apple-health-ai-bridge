import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from health_bridge.contract._delivery_models import (
    AckOpenParams,
    AckSealParams,
    DeliveryCreateParams,
    DeliveryOpenParams,
    DeliverySealParams,
)
from tests.contract.delivery_v1_support import Contexts


@pytest.fixture
def contexts() -> Contexts:
    sender_signing = Ed25519PrivateKey.from_private_bytes(b"\x11" * 32)
    receiver_signing = Ed25519PrivateKey.from_private_bytes(b"\x22" * 32)
    receiver_agreement = X25519PrivateKey.from_private_bytes(b"\x33" * 32)
    device_agreement = X25519PrivateKey.from_private_bytes(b"\x44" * 32)
    seal = DeliveryCreateParams(
        envelope_id=b"\x01" * 16,
        receiver_id=b"\x02" * 16,
        device_id=b"\x03" * 16,
        connection_generation=7,
        created_at_ms=1_782_000_000_123,
        receiver_agreement_public_key=receiver_agreement.public_key(),
        sender_signing_private_key=sender_signing,
    )
    opening = DeliveryOpenParams(
        receiver_id=b"\x02" * 16,
        device_id=b"\x03" * 16,
        connection_generation=7,
        receiver_agreement_private_key=receiver_agreement,
        sender_signing_public_key=sender_signing.public_key(),
    )
    ack_seal = AckSealParams(
        envelope_id=b"\x01" * 16,
        receiver_id=b"\x02" * 16,
        device_id=b"\x03" * 16,
        connection_generation=7,
        device_agreement_public_key=device_agreement.public_key(),
        receiver_signing_private_key=receiver_signing,
        receiver_agreement_private_key=receiver_agreement,
    )
    ack_open = AckOpenParams(
        envelope_id=b"\x01" * 16,
        receiver_id=b"\x02" * 16,
        device_id=b"\x03" * 16,
        connection_generation=7,
        device_agreement_private_key=device_agreement,
        receiver_signing_public_key=receiver_signing.public_key(),
        receiver_agreement_public_key=receiver_agreement.public_key(),
    )
    return seal, opening, ack_seal, ack_open


@pytest.fixture
def vector_seal() -> DeliverySealParams:
    receiver_agreement = X25519PrivateKey.from_private_bytes(b"\x33" * 32)
    return DeliverySealParams(
        envelope_id=b"\x01" * 16,
        receiver_id=b"\x02" * 16,
        device_id=b"\x03" * 16,
        connection_generation=7,
        created_at_ms=1_782_000_000_123,
        receiver_agreement_public_key=receiver_agreement.public_key(),
        sender_signing_private_key=Ed25519PrivateKey.from_private_bytes(b"\x11" * 32),
        ephemeral_private_key=X25519PrivateKey.from_private_bytes(b"\x55" * 32),
        nonce=b"\x66" * 12,
    )

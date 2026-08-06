from __future__ import annotations

import base64
import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Final, Literal

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from pydantic import TypeAdapter
from typing_extensions import TypedDict

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.contract._delivery_envelope import seal_delivery_envelope_vector
from health_bridge.contract._delivery_models import DeliverySealParams
from tests.contract.delivery_v1_support import decode_object

if TYPE_CHECKING:
    from collections.abc import Callable

FIXTURES: Final = Path(__file__).parents[2] / "fixtures"


class NegativeVector(TypedDict):
    target: Literal["delivery", "ack"]
    field: str
    replacement: str


class VectorFixture(TypedDict):
    origin: str
    plaintext: str
    payload_sha256: str
    envelope: str
    ack: str
    receipt: str
    negative: list[NegativeVector]


VECTOR_ADAPTER: Final = TypeAdapter(VectorFixture)


@dataclass(frozen=True, slots=True)
class VectorContexts:
    seal: DeliverySealParams
    opening: delivery.DeliveryOpenParams
    ack_seal: delivery.AckSealParams
    ack_open: delivery.AckOpenParams


def _digest(label: str) -> bytes:
    return hashlib.sha256(label.encode()).digest()


def _signing(label: str) -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(_digest(label))


def _agreement(label: str) -> X25519PrivateKey:
    return X25519PrivateKey.from_private_bytes(_digest(label))


def _contexts(origin: str) -> VectorContexts:
    prefix = f"health-bridge/{origin}"
    envelope_id = _digest(f"{prefix}/envelope-id")[:16]
    receiver_id = _digest(f"{prefix}/receiver-id")[:16]
    device_id = _digest(f"{prefix}/device-id")[:16]
    generation = 7 if origin == "python" else 8
    created_at_ms = 1_782_000_000_123 if origin == "python" else -1
    receiver_agreement = _agreement(f"{prefix}/receiver-agreement")
    device_agreement = _agreement(f"{prefix}/device-agreement")
    sender_signing = _signing(f"{prefix}/sender-signing")
    receiver_signing = _signing(f"{prefix}/receiver-signing")
    seal = DeliverySealParams(
        envelope_id=envelope_id,
        receiver_id=receiver_id,
        device_id=device_id,
        connection_generation=generation,
        created_at_ms=created_at_ms,
        receiver_agreement_public_key=receiver_agreement.public_key(),
        sender_signing_private_key=sender_signing,
        ephemeral_private_key=_agreement(f"{prefix}/ephemeral-agreement"),
        nonce=_digest(f"{prefix}/delivery-nonce")[:12],
    )
    return VectorContexts(
        seal=seal,
        opening=delivery.DeliveryOpenParams(
            receiver_id=receiver_id,
            device_id=device_id,
            connection_generation=generation,
            receiver_agreement_private_key=receiver_agreement,
            sender_signing_public_key=sender_signing.public_key(),
        ),
        ack_seal=delivery.AckSealParams(
            envelope_id=envelope_id,
            receiver_id=receiver_id,
            device_id=device_id,
            connection_generation=generation,
            device_agreement_public_key=device_agreement.public_key(),
            receiver_signing_private_key=receiver_signing,
            receiver_agreement_private_key=receiver_agreement,
        ),
        ack_open=delivery.AckOpenParams(
            envelope_id=envelope_id,
            receiver_id=receiver_id,
            device_id=device_id,
            connection_generation=generation,
            device_agreement_private_key=device_agreement,
            receiver_signing_public_key=receiver_signing.public_key(),
            receiver_agreement_public_key=receiver_agreement.public_key(),
        ),
    )


def _decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _load(origin: str) -> VectorFixture:
    path = FIXTURES / f"delivery_v1_{origin}.synthetic.json"
    with path.open("rb") as stream:
        return VECTOR_ADAPTER.validate_json(stream.read())


def _open_delivery(encoded: bytes, contexts: VectorContexts) -> None:
    _ = delivery.open_delivery_envelope(encoded, contexts.opening)


def _open_ack(encoded: bytes, contexts: VectorContexts) -> None:
    _ = delivery.open_delivery_ack(encoded, contexts.ack_open)


@pytest.mark.parametrize("origin", ["python", "swift"])
def test_each_language_verifies_the_other_exact_envelope_and_ack_bytes(
    origin: str,
) -> None:
    fixture = _load(origin)
    contexts = _contexts(origin)
    plaintext = _decode(fixture["plaintext"])
    envelope = _decode(fixture["envelope"])
    ack = _decode(fixture["ack"])
    receipt = delivery.DeliveryReceiptV1(
        result="committed",
        payload_sha256=hashlib.sha256(plaintext).hexdigest(),
        receipt_id=9,
        dataset_generation=4,
        committed_at_ms=1_782_000_000_456,
        error_code=None,
    )

    generated_envelope = decode_object(
        seal_delivery_envelope_vector(plaintext, contexts.seal).to_bytes()
    )
    generated_ack = decode_object(
        delivery.create_delivery_ack(receipt, contexts.ack_seal).to_bytes()
    )
    fixture_envelope = decode_object(envelope)
    fixture_ack = decode_object(ack)
    assert (
        generated_envelope | {"signature": fixture_envelope["signature"]}
        == fixture_envelope
    )
    assert generated_ack | {"signature": fixture_ack["signature"]} == fixture_ack
    assert delivery.hbjcs1_encode(fixture_envelope) == envelope
    assert delivery.hbjcs1_encode(fixture_ack) == ack
    assert (
        delivery.open_delivery_envelope(envelope, contexts.opening).plaintext
        == plaintext
    )
    assert delivery.open_delivery_ack(ack, contexts.ack_open) == receipt
    assert receipt.to_bytes() == _decode(fixture["receipt"])
    assert hashlib.sha256(plaintext).hexdigest() == fixture["payload_sha256"]
    assert b'"value":1.25' in plaintext


@pytest.mark.parametrize("origin", ["python", "swift"])
def test_committed_negative_metadata_vectors_fail_closed(origin: str) -> None:
    fixture = _load(origin)
    contexts = _contexts(origin)
    sources = {
        "delivery": fixture["envelope"],
        "ack": fixture["ack"],
    }
    openers: dict[str, Callable[[bytes, VectorContexts], None]] = {
        "delivery": _open_delivery,
        "ack": _open_ack,
    }
    for mutation in fixture["negative"]:
        source = _decode(sources[mutation["target"]])
        raw = decode_object(source)
        raw[mutation["field"]] = mutation["replacement"]
        encoded = delivery.hbjcs1_encode(raw)
        with pytest.raises(delivery.DeliveryProtocolError):
            openers[mutation["target"]](encoded, contexts)


def test_hbjcs1_float_rejection_does_not_reject_fractional_delivery_plaintext() -> None:
    fixture = _load("swift")
    plaintext = _decode(fixture["plaintext"])

    with pytest.raises(delivery.HBJCS1Error):
        _ = delivery.hbjcs1_decode(b'{"value":1.25}')
    assert (
        delivery.open_delivery_envelope(
            _decode(fixture["envelope"]), _contexts("swift").opening
        ).plaintext
        == plaintext
    )

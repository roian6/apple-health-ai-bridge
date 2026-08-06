from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass
from typing import TYPE_CHECKING, ClassVar, Literal

if TYPE_CHECKING:
    from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from pydantic import BaseModel, ConfigDict, ValidationError

from health_bridge.contract._batch_json import BatchJsonError, validate_batch_json
from health_bridge.contract._delivery_ack import create_delivery_ack, open_delivery_ack
from health_bridge.contract._delivery_common import DeliveryProtocolError, fail
from health_bridge.contract._delivery_envelope import (
    create_delivery_envelope,
    open_delivery_envelope,
    seal_delivery_envelope_vector,
)
from health_bridge.contract._delivery_models import (
    AckOpenParams,
    AckSealParams,
    DeliveryCreateParams,
    DeliveryOpenParams,
    DeliveryReceiptV1,
    DeliverySealParams,
)
from health_bridge.contract._delivery_self_test_vectors import (
    FixtureMutation,
    inner_mutation,
    outer_mutation,
)
from health_bridge.contract._hbjcs1 import hbjcs1_encode


class DeliverySelfTestFixture(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid", frozen=True, strict=True
    )

    v: Literal[1]
    kind: Literal["delivery_v1_self_test"]
    batch_fixture: Literal["health_bridge_batch_v1.synthetic.json"]
    mutation: FixtureMutation
    field: str | None


@dataclass(frozen=True, slots=True)
class SelfTestCounts:
    delivery_cases: int
    ack_cases: int

    def to_bytes(self) -> bytes:
        return hbjcs1_encode(
            {"delivery_cases": self.delivery_cases, "ack_cases": self.ack_cases}
        )


@dataclass(frozen=True, slots=True)
class _Contexts:
    create: DeliveryCreateParams
    vector: DeliverySealParams
    opening: DeliveryOpenParams
    ack_seal: AckSealParams
    ack_open: AckOpenParams


def _contexts() -> _Contexts:
    sender_signing = Ed25519PrivateKey.generate()
    receiver_signing = Ed25519PrivateKey.generate()
    receiver_agreement = X25519PrivateKey.generate()
    device_agreement = X25519PrivateKey.generate()
    envelope_id = os.urandom(16)
    receiver_id = os.urandom(16)
    device_id = os.urandom(16)
    generation = 1
    return _Contexts(
        create=DeliveryCreateParams(
            envelope_id=envelope_id,
            receiver_id=receiver_id,
            device_id=device_id,
            connection_generation=generation,
            created_at_ms=1_782_000_000_123,
            receiver_agreement_public_key=receiver_agreement.public_key(),
            sender_signing_private_key=sender_signing,
        ),
        vector=DeliverySealParams(
            envelope_id=envelope_id,
            receiver_id=receiver_id,
            device_id=device_id,
            connection_generation=generation,
            created_at_ms=1_782_000_000_123,
            receiver_agreement_public_key=receiver_agreement.public_key(),
            sender_signing_private_key=sender_signing,
            ephemeral_private_key=X25519PrivateKey.generate(),
            nonce=os.urandom(12),
        ),
        opening=DeliveryOpenParams(
            receiver_id=receiver_id,
            device_id=device_id,
            connection_generation=generation,
            receiver_agreement_private_key=receiver_agreement,
            sender_signing_public_key=sender_signing.public_key(),
        ),
        ack_seal=AckSealParams(
            envelope_id=envelope_id,
            receiver_id=receiver_id,
            device_id=device_id,
            connection_generation=generation,
            device_agreement_public_key=device_agreement.public_key(),
            receiver_signing_private_key=receiver_signing,
            receiver_agreement_private_key=receiver_agreement,
        ),
        ack_open=AckOpenParams(
            envelope_id=envelope_id,
            receiver_id=receiver_id,
            device_id=device_id,
            connection_generation=generation,
            device_agreement_private_key=device_agreement,
            receiver_signing_public_key=receiver_signing.public_key(),
            receiver_agreement_public_key=receiver_agreement.public_key(),
        ),
    )


def run_self_test(path: Path) -> SelfTestCounts:
    try:
        fixture_bytes = path.read_bytes()
        validate_batch_json(fixture_bytes.decode("utf-8"))
        fixture = DeliverySelfTestFixture.model_validate_json(fixture_bytes)
        payload = (path.parent / fixture.batch_fixture).read_bytes()
    except (
        OSError,
        UnicodeDecodeError,
        BatchJsonError,
        RecursionError,
        ValidationError,
    ):
        fail("payload_invalid")
    contexts = _contexts()
    mutated_payload = inner_mutation(payload, fixture.mutation)
    if fixture.mutation == "none":
        envelope = create_delivery_envelope(mutated_payload, contexts.create)
    else:
        envelope = seal_delivery_envelope_vector(mutated_payload, contexts.vector)
    encoded = outer_mutation(envelope.to_bytes(), fixture.mutation, fixture.field)
    opened = open_delivery_envelope(encoded, contexts.opening)
    if fixture.mutation == "none":
        if opened.plaintext != payload:
            fail("authentication_failed")
    else:
        fail("authentication_failed")
    receipt = DeliveryReceiptV1(
        result="committed",
        payload_sha256=hashlib.sha256(opened.plaintext).hexdigest(),
        receipt_id=1,
        dataset_generation=1,
        committed_at_ms=1_782_000_000_456,
        error_code=None,
    )
    ack = create_delivery_ack(receipt, contexts.ack_seal)
    if open_delivery_ack(ack.to_bytes(), contexts.ack_open) != receipt:
        fail("authentication_failed")
    return SelfTestCounts(delivery_cases=1, ack_cases=1)


__all__ = ["DeliveryProtocolError", "SelfTestCounts", "run_self_test"]

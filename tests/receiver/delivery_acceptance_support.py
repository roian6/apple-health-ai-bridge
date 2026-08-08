from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from pathlib import Path
from threading import BrokenBarrierError
from typing import TYPE_CHECKING, Final, Protocol

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.receiver.delivery_acceptance import (
    DeliveryAcceptanceRequest,
    DeliveryAcceptanceService,
    DeliveryTrustedConnection,
)
from health_bridge.receiver.tokens import ReceiverTokenPrincipal
from health_bridge.storage.database import initialize_database
from health_bridge.storage.sqlite_rows import fetch_one_int
from tests.contract.delivery_v1_support import BATCH

if TYPE_CHECKING:
    from collections.abc import Callable

    from health_bridge.receiver._delivery_acceptance_models import (
        DeliveryAcceptanceFaultHook,
        DeliveryAcceptanceFaultPoint,
    )

NOW_MS: Final = 1_784_600_000_123
PRINCIPAL: Final = delivery.DevicePrincipal("synthetic.device")
BINDING: Final = delivery.OpaqueBinding(b"\x77" * 32)


class StringSink(Protocol):
    def put(self, value: str) -> None: ...


class ProcessBarrier(Protocol):
    def wait(self, timeout: float | None = None) -> int: ...


@dataclass(frozen=True, slots=True)
class RequestSpec:
    payload: bytes = BATCH
    envelope_byte: int = 1
    generation: int = 7
    principal: delivery.DevicePrincipal = PRINCIPAL
    binding: delivery.OpaqueBinding = BINDING
    sender: Ed25519PrivateKey | None = None


def signing_private() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(b"\x11" * 32)


def receiver_signing_private() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(b"\x22" * 32)


def receiver_agreement_private() -> X25519PrivateKey:
    return X25519PrivateKey.from_private_bytes(b"\x33" * 32)


def device_agreement_private() -> X25519PrivateKey:
    return X25519PrivateKey.from_private_bytes(b"\x44" * 32)


def connection(
    *, generation: int = 7, revoked: bool = False
) -> DeliveryTrustedConnection:
    return DeliveryTrustedConnection(
        receiver_id=b"\x02" * 16,
        device_id=b"\x03" * 16,
        connection_generation=generation,
        device_principal=PRINCIPAL,
        opaque_binding=BINDING,
        receiver_agreement_private_key=receiver_agreement_private(),
        sender_signing_public_key=signing_private().public_key(),
        device_agreement_public_key=device_agreement_private().public_key(),
        receiver_signing_private_key=receiver_signing_private(),
        source_principal=ReceiverTokenPrincipal(installation_id_hash=None),
        sender_key_revoked=revoked,
    )


def envelope(spec: RequestSpec) -> bytes:
    return delivery.create_delivery_envelope(
        spec.payload,
        delivery.DeliveryCreateParams(
            envelope_id=bytes([spec.envelope_byte]) * 16,
            receiver_id=b"\x02" * 16,
            device_id=b"\x03" * 16,
            connection_generation=spec.generation,
            created_at_ms=NOW_MS - 1,
            receiver_agreement_public_key=receiver_agreement_private().public_key(),
            sender_signing_private_key=(
                signing_private() if spec.sender is None else spec.sender
            ),
        ),
    ).to_bytes()


def request(spec: RequestSpec | None = None) -> DeliveryAcceptanceRequest:
    active = RequestSpec() if spec is None else spec
    return DeliveryAcceptanceRequest(
        envelope_bytes=envelope(active),
        device_principal=active.principal,
        opaque_binding=active.binding,
    )


def service(
    db_path: Path,
    *,
    revoked: bool = False,
    before_commit_validator: Callable[[], None] | None = None,
) -> DeliveryAcceptanceService:
    initialize_database(db_path)
    return DeliveryAcceptanceService(
        db_path,
        connection(revoked=revoked),
        lambda: NOW_MS,
        before_commit_validator=before_commit_validator,
    )


def opened_receipt(
    ack_bytes: bytes,
    *,
    envelope_byte: int = 1,
    generation: int = 7,
) -> delivery.DeliveryReceiptV1:
    return delivery.open_delivery_ack(
        ack_bytes,
        delivery.AckOpenParams(
            envelope_id=bytes([envelope_byte]) * 16,
            receiver_id=b"\x02" * 16,
            device_id=b"\x03" * 16,
            connection_generation=generation,
            device_agreement_private_key=device_agreement_private(),
            receiver_signing_public_key=receiver_signing_private().public_key(),
            receiver_agreement_public_key=receiver_agreement_private().public_key(),
        ),
    )


def counts(db_path: Path) -> tuple[int, int, int]:
    with sqlite3.connect(db_path) as database:
        return (
            fetch_one_int(database, "select count(*) from samples"),
            fetch_one_int(database, "select count(*) from sync_runs"),
            fetch_one_int(database, "select count(*) from delivery_receipts"),
        )


def alternate_batch() -> bytes:
    return BATCH.replace(b',"export_window"', b', "export_window"', 1).replace(
        b'"value":1.25', b'"value":125e-2'
    )


def with_phone_source(payload: bytes) -> bytes:
    return payload.replace(b"synthetic.phone.alpha", b"apple_health.phone")


def race_worker(
    db_path_text: str,
    payload: bytes,
    barrier: ProcessBarrier,
    sink: StringSink,
) -> None:
    try:
        _ = barrier.wait(timeout=15)
    except BrokenBarrierError:
        raise SystemExit(2) from None
    result = service(Path(db_path_text)).accept(request(RequestSpec(payload=payload)))
    receipt = opened_receipt(result.ack_bytes)
    sink.put(receipt.result if receipt.error_code is None else receipt.error_code)


def fault_at(target: DeliveryAcceptanceFaultPoint) -> DeliveryAcceptanceFaultHook:
    def inject(point: DeliveryAcceptanceFaultPoint) -> None:
        if point == target:
            raise RuntimeError(target.value)

    return inject

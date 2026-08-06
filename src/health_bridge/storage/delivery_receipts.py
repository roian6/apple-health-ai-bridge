import sqlite3
from dataclasses import dataclass
from typing import Final, Literal, TypeAlias

from pydantic import TypeAdapter
from typing_extensions import override

from health_bridge.contract.delivery_v1 import (
    DeliveryProtocolError,
    DeliveryReceiptV1,
)

DeliveryResult: TypeAlias = Literal["committed", "retryable", "terminal"]
DeliveryErrorCode: TypeAlias = Literal[
    "receiver_busy",
    "storage_unavailable",
    "quota_exceeded",
    "internal_retry",
    "payload_invalid",
    "payload_oversize",
    "duplicate_conflict",
    "principal_mismatch",
    "binding_mismatch",
    "generation_mismatch",
    "key_revoked",
]
DeliveryReceiptRow: TypeAlias = tuple[
    int | None,
    bytes,
    bytes,
    bytes,
    bytes,
    bytes,
    bytes,
    bytes,
    bytes,
    bytes,
    int,
    DeliveryResult,
    int | None,
    bytes,
    int | None,
    int | None,
    DeliveryErrorCode | None,
]
RECEIPT_ROW_ADAPTER: Final[TypeAdapter[DeliveryReceiptRow | None]] = TypeAdapter(
    DeliveryReceiptRow | None
)
INSERT_RECEIPT_SQL: Final = """
insert into delivery_receipts (
    receipt_id, envelope_id, payload_sha256, receiver_id, device_id,
    receiver_agreement_key_id, sender_signing_key_id,
    device_agreement_key_id, receiver_signing_key_id, opaque_binding,
    connection_generation, result, committed_sync_run_id, ack_id,
    dataset_generation, committed_at_ms, error_code
) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""
SELECT_RECEIPT_SQL: Final = """
select receipt_id, envelope_id, payload_sha256, receiver_id, device_id,
       receiver_agreement_key_id, sender_signing_key_id,
       device_agreement_key_id, receiver_signing_key_id, opaque_binding,
       connection_generation, result, committed_sync_run_id, ack_id,
       dataset_generation, committed_at_ms, error_code
from delivery_receipts
where delivery_receipt_row_id = ?
"""
SELECT_RECEIPT_BY_SCOPE_SQL: Final = """
select receipt_id, envelope_id, payload_sha256, receiver_id, device_id,
       receiver_agreement_key_id, sender_signing_key_id,
       device_agreement_key_id, receiver_signing_key_id, opaque_binding,
       connection_generation, result, committed_sync_run_id, ack_id,
       dataset_generation, committed_at_ms, error_code
from delivery_receipts
where receiver_id = ? and device_id = ? and envelope_id = ?
"""


@dataclass(frozen=True, slots=True)
class DeliveryReceiptValueError(Exception):
    field: str

    @override
    def __str__(self) -> str:
        return f"invalid delivery receipt metadata: {self.field}"


@dataclass(frozen=True, slots=True)
class DeliveryReceiptConflictError(Exception):
    @override
    def __str__(self) -> str:
        return "delivery receipt identity conflict"


@dataclass(frozen=True, slots=True)
class DeliveryReceiptRecord:
    receipt_id: int | None
    envelope_id: bytes
    payload_sha256: bytes
    receiver_id: bytes
    device_id: bytes
    receiver_agreement_key_id: bytes
    sender_signing_key_id: bytes
    device_agreement_key_id: bytes
    receiver_signing_key_id: bytes
    opaque_binding: bytes
    connection_generation: int
    result: DeliveryResult
    committed_sync_run_id: int | None
    ack_id: bytes
    dataset_generation: int | None
    committed_at_ms: int | None
    error_code: DeliveryErrorCode | None

    def __post_init__(self) -> None:
        _require_bytes("envelope_id", self.envelope_id, 16)
        _require_bytes("payload_sha256", self.payload_sha256, 32)
        _require_bytes("receiver_id", self.receiver_id, 16)
        _require_bytes("device_id", self.device_id, 16)
        _require_bytes("receiver_agreement_key_id", self.receiver_agreement_key_id, 16)
        _require_bytes("sender_signing_key_id", self.sender_signing_key_id, 16)
        _require_bytes("device_agreement_key_id", self.device_agreement_key_id, 16)
        _require_bytes("receiver_signing_key_id", self.receiver_signing_key_id, 16)
        _require_bytes("opaque_binding", self.opaque_binding, 32)
        _require_bytes("ack_id", self.ack_id, 16)
        _require_i64("receipt_id", self.receipt_id, minimum=0)
        _require_i64(
            "connection_generation",
            self.connection_generation,
            minimum=0,
        )
        _require_i64(
            "committed_sync_run_id",
            self.committed_sync_run_id,
            minimum=1,
        )
        _require_i64(
            "dataset_generation",
            self.dataset_generation,
            minimum=0,
        )
        _require_i64("committed_at_ms", self.committed_at_ms, minimum=0)
        try:
            _ = DeliveryReceiptV1(
                result=self.result,
                payload_sha256=self.payload_sha256.hex(),
                receipt_id=self.receipt_id,
                dataset_generation=self.dataset_generation,
                committed_at_ms=self.committed_at_ms,
                error_code=self.error_code,
            )
        except DeliveryProtocolError:
            raise DeliveryReceiptValueError(field="receipt") from None
        requires_sync_run = self.result == "committed"
        if requires_sync_run != (self.committed_sync_run_id is not None):
            raise DeliveryReceiptValueError(field="committed_sync_run_id")


def insert_delivery_receipt(
    connection: sqlite3.Connection,
    receipt: DeliveryReceiptRecord,
) -> int:
    try:
        cursor = connection.execute(
            INSERT_RECEIPT_SQL,
            (
                receipt.receipt_id,
                receipt.envelope_id,
                receipt.payload_sha256,
                receipt.receiver_id,
                receipt.device_id,
                receipt.receiver_agreement_key_id,
                receipt.sender_signing_key_id,
                receipt.device_agreement_key_id,
                receipt.receiver_signing_key_id,
                receipt.opaque_binding,
                receipt.connection_generation,
                receipt.result,
                receipt.committed_sync_run_id,
                receipt.ack_id,
                receipt.dataset_generation,
                receipt.committed_at_ms,
                receipt.error_code,
            ),
        )
    except sqlite3.IntegrityError as exc:
        if exc.sqlite_errorcode == sqlite3.SQLITE_CONSTRAINT_UNIQUE:
            raise DeliveryReceiptConflictError from None
        raise
    row_id = cursor.lastrowid
    if row_id is None:
        raise sqlite3.DatabaseError
    return row_id


def fetch_delivery_receipt(
    connection: sqlite3.Connection,
    row_id: int,
) -> DeliveryReceiptRecord | None:
    row = RECEIPT_ROW_ADAPTER.validate_python(
        connection.execute(SELECT_RECEIPT_SQL, (row_id,)).fetchone()
    )
    if row is None:
        return None
    return DeliveryReceiptRecord(*row)


def fetch_delivery_receipt_by_scope(
    connection: sqlite3.Connection,
    *,
    receiver_id: bytes,
    device_id: bytes,
    envelope_id: bytes,
) -> DeliveryReceiptRecord | None:
    _require_bytes("receiver_id", receiver_id, 16)
    _require_bytes("device_id", device_id, 16)
    _require_bytes("envelope_id", envelope_id, 16)
    row = RECEIPT_ROW_ADAPTER.validate_python(
        connection.execute(
            SELECT_RECEIPT_BY_SCOPE_SQL,
            (receiver_id, device_id, envelope_id),
        ).fetchone()
    )
    if row is None:
        return None
    return DeliveryReceiptRecord(*row)


def _require_bytes(field: str, value: bytes, length: int) -> None:
    if type(value) is not bytes or len(value) != length:
        raise DeliveryReceiptValueError(field=field)


def _require_i64(field: str, value: int | None, *, minimum: int) -> None:
    if value is None:
        return
    if type(value) is not int or not minimum <= value <= (2**63) - 1:
        raise DeliveryReceiptValueError(field=field)

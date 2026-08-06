from __future__ import annotations

import sqlite3
from collections.abc import Callable
from dataclasses import replace
from typing import TYPE_CHECKING, Final, cast

import pytest

from health_bridge.storage.database import initialize_database
from health_bridge.storage.delivery_receipts import (
    DeliveryReceiptRecord,
    DeliveryReceiptValueError,
)
from tests.storage.delivery_receipt_reopened_support import (
    RAW_RECEIPT_INSERT_SQL,
    SqliteValue,
    committed_receipt,
    raw_receipt_values,
)

if TYPE_CHECKING:
    from pathlib import Path

InvalidRuntimeValue = bool | bytearray | bytes | float | int | memoryview | str
ReceiptMutation = Callable[
    [DeliveryReceiptRecord, InvalidRuntimeValue],
    DeliveryReceiptRecord,
]
INTEGER_MUTATIONS: Final[tuple[tuple[str, ReceiptMutation], ...]] = (
    (
        "receipt_id",
        lambda receipt, value: replace(receipt, receipt_id=cast("int", value)),
    ),
    (
        "connection_generation",
        lambda receipt, value: replace(
            receipt, connection_generation=cast("int", value)
        ),
    ),
    (
        "committed_sync_run_id",
        lambda receipt, value: replace(
            receipt, committed_sync_run_id=cast("int", value)
        ),
    ),
    (
        "dataset_generation",
        lambda receipt, value: replace(receipt, dataset_generation=cast("int", value)),
    ),
    (
        "committed_at_ms",
        lambda receipt, value: replace(receipt, committed_at_ms=cast("int", value)),
    ),
)
BLOB_MUTATIONS: Final[tuple[tuple[str, int, ReceiptMutation], ...]] = (
    (
        "envelope_id",
        16,
        lambda receipt, value: replace(receipt, envelope_id=cast("bytes", value)),
    ),
    (
        "payload_sha256",
        32,
        lambda receipt, value: replace(receipt, payload_sha256=cast("bytes", value)),
    ),
    (
        "receiver_id",
        16,
        lambda receipt, value: replace(receipt, receiver_id=cast("bytes", value)),
    ),
    (
        "device_id",
        16,
        lambda receipt, value: replace(receipt, device_id=cast("bytes", value)),
    ),
    (
        "receiver_agreement_key_id",
        16,
        lambda receipt, value: replace(
            receipt, receiver_agreement_key_id=cast("bytes", value)
        ),
    ),
    (
        "sender_signing_key_id",
        16,
        lambda receipt, value: replace(
            receipt, sender_signing_key_id=cast("bytes", value)
        ),
    ),
    (
        "device_agreement_key_id",
        16,
        lambda receipt, value: replace(
            receipt, device_agreement_key_id=cast("bytes", value)
        ),
    ),
    (
        "receiver_signing_key_id",
        16,
        lambda receipt, value: replace(
            receipt, receiver_signing_key_id=cast("bytes", value)
        ),
    ),
    (
        "opaque_binding",
        32,
        lambda receipt, value: replace(receipt, opaque_binding=cast("bytes", value)),
    ),
    (
        "ack_id",
        16,
        lambda receipt, value: replace(receipt, ack_id=cast("bytes", value)),
    ),
)


@pytest.mark.parametrize(("field", "mutation"), INTEGER_MUTATIONS)
@pytest.mark.parametrize("invalid", [True, 1.5, "1", -1, 2**63])
def test_runtime_api_rejects_non_i64_integer_metadata(
    field: str,
    mutation: ReceiptMutation,
    invalid: InvalidRuntimeValue,
) -> None:
    del field
    with pytest.raises(DeliveryReceiptValueError):
        _ = mutation(committed_receipt(), invalid)


@pytest.mark.parametrize(("field", "length", "mutation"), BLOB_MUTATIONS)
@pytest.mark.parametrize("kind", ["str", "bytearray", "memoryview", "short"])
def test_runtime_api_rejects_non_bytes_and_wrong_blob_lengths(
    field: str,
    length: int,
    mutation: ReceiptMutation,
    kind: str,
) -> None:
    values: dict[str, InvalidRuntimeValue] = {
        "str": "x" * length,
        "bytearray": bytearray(length),
        "memoryview": memoryview(bytes(length)),
        "short": bytes(length - 1),
    }
    with pytest.raises(DeliveryReceiptValueError, match=field):
        _ = mutation(committed_receipt(), values[kind])


@pytest.mark.parametrize("field", [value[0] for value in INTEGER_MUTATIONS])
@pytest.mark.parametrize("invalid", [1.5, "1", "9223372036854775808", b"1"])
def test_sql_rejects_noninteger_storage_classes_and_coercible_text(
    tmp_path: Path,
    field: str,
    invalid: SqliteValue,
) -> None:
    db_path = tmp_path / "integer-domain.sqlite"
    initialize_database(db_path)
    values = raw_receipt_values()
    values[field] = invalid

    with (
        sqlite3.connect(db_path) as connection,
        pytest.raises(sqlite3.IntegrityError),
    ):
        _ = connection.execute(RAW_RECEIPT_INSERT_SQL, values)


@pytest.mark.parametrize(("field", "length", "mutation"), BLOB_MUTATIONS)
def test_sql_rejects_text_in_every_blob_metadata_column(
    tmp_path: Path,
    field: str,
    length: int,
    mutation: ReceiptMutation,
) -> None:
    del mutation
    db_path = tmp_path / "blob-domain.sqlite"
    initialize_database(db_path)
    values = raw_receipt_values()
    values[field] = "x" * length

    with (
        sqlite3.connect(db_path) as connection,
        pytest.raises(sqlite3.IntegrityError),
    ):
        _ = connection.execute(RAW_RECEIPT_INSERT_SQL, values)

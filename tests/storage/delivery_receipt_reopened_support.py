from __future__ import annotations

from typing import Final, TypeAlias

from health_bridge.storage.delivery_receipts import DeliveryReceiptRecord

SqliteValue: TypeAlias = bytes | float | int | str | None
RAW_RECEIPT_INSERT_SQL: Final = """
insert into delivery_receipts (
    receipt_id, envelope_id, payload_sha256, receiver_id, device_id,
    receiver_agreement_key_id, sender_signing_key_id,
    device_agreement_key_id, receiver_signing_key_id, opaque_binding,
    connection_generation, result, committed_sync_run_id, ack_id,
    dataset_generation, committed_at_ms, error_code
) values (
    :receipt_id, :envelope_id, :payload_sha256, :receiver_id, :device_id,
    :receiver_agreement_key_id, :sender_signing_key_id,
    :device_agreement_key_id, :receiver_signing_key_id, :opaque_binding,
    :connection_generation, :result, :committed_sync_run_id, :ack_id,
    :dataset_generation, :committed_at_ms, :error_code
)
"""


def committed_receipt() -> DeliveryReceiptRecord:
    return DeliveryReceiptRecord(
        receipt_id=11,
        envelope_id=bytes([1]) * 16,
        payload_sha256=bytes([2]) * 32,
        receiver_id=bytes([3]) * 16,
        device_id=bytes([4]) * 16,
        receiver_agreement_key_id=bytes([13]) * 16,
        sender_signing_key_id=bytes([14]) * 16,
        device_agreement_key_id=bytes([5]) * 16,
        receiver_signing_key_id=bytes([6]) * 16,
        opaque_binding=bytes([7]) * 32,
        connection_generation=8,
        result="committed",
        committed_sync_run_id=1,
        ack_id=bytes([9]) * 16,
        dataset_generation=10,
        committed_at_ms=1_782_000_000_000,
        error_code=None,
    )


def raw_receipt_values() -> dict[str, SqliteValue]:
    receipt = committed_receipt()
    return {
        "receipt_id": receipt.receipt_id,
        "envelope_id": receipt.envelope_id,
        "payload_sha256": receipt.payload_sha256,
        "receiver_id": receipt.receiver_id,
        "device_id": receipt.device_id,
        "receiver_agreement_key_id": receipt.receiver_agreement_key_id,
        "sender_signing_key_id": receipt.sender_signing_key_id,
        "device_agreement_key_id": receipt.device_agreement_key_id,
        "receiver_signing_key_id": receipt.receiver_signing_key_id,
        "opaque_binding": receipt.opaque_binding,
        "connection_generation": receipt.connection_generation,
        "result": receipt.result,
        "committed_sync_run_id": receipt.committed_sync_run_id,
        "ack_id": receipt.ack_id,
        "dataset_generation": receipt.dataset_generation,
        "committed_at_ms": receipt.committed_at_ms,
        "error_code": receipt.error_code,
    }

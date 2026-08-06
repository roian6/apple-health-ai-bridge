from pathlib import Path

from health_bridge.storage._migration_backup_files import (
    DeliveryReceiptRollbackDecision,
    atomic_copy_private,
    delivery_receipt_backup_path,
    delivery_receipt_rollback_guard_path,
    restore_delivery_receipt_backup_locked,
)
from health_bridge.storage._migration_recovery import (
    DeliveryReceiptRecoveryMismatchError,
    DeliveryReceiptRecoveryStateError,
    DeliveryReceiptRecoveryStatus,
    reconcile_delivery_receipt_recovery,
)
from health_bridge.storage.database import exclusive_database_maintenance

__all__ = [
    "DeliveryReceiptRollbackDecision",
    "delivery_receipt_backup_path",
    "delivery_receipt_rollback_guard_path",
    "restore_delivery_receipt_backup",
]


def restore_delivery_receipt_backup(
    db_path: Path,
) -> DeliveryReceiptRollbackDecision:
    with exclusive_database_maintenance(db_path):
        try:
            status = reconcile_delivery_receipt_recovery(
                db_path,
                migration_applied=False,
            )
        except DeliveryReceiptRecoveryMismatchError:
            return DeliveryReceiptRollbackDecision.HOLD_POST_MIGRATION_COMMIT
        except DeliveryReceiptRecoveryStateError:
            return DeliveryReceiptRollbackDecision.HOLD_INVALID_GUARD
        if status == DeliveryReceiptRecoveryStatus.PRECOMMIT:
            atomic_copy_private(delivery_receipt_backup_path(db_path), db_path)
            return DeliveryReceiptRollbackDecision.RESTORED
        return restore_delivery_receipt_backup_locked(db_path)

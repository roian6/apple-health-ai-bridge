import os
import sqlite3
import tempfile
from collections.abc import Callable
from enum import StrEnum
from pathlib import Path
from typing import NoReturn

from health_bridge.storage._migration_backup_files import (
    atomic_copy_private,
    delivery_receipt_backup_path,
    delivery_receipt_recovery_path,
    delivery_receipt_rollback_guard_path,
    file_sha256,
    read_hash_pair,
    remove_private_file,
    write_hash_pair,
)

StagedMigration = Callable[[sqlite3.Connection], None]


class DeliveryReceiptRecoveryStatus(StrEnum):
    NONE = "none"
    PRECOMMIT = "precommit"
    MIGRATED = "migrated"
    GUARDED = "guarded"


class DeliveryReceiptRecoveryStateError(OSError):
    pass


class DeliveryReceiptRecoveryMismatchError(OSError):
    pass


def prepare_delivery_receipt_recovery(
    db_path: Path,
    stage_migration: StagedMigration,
) -> None:
    backup_path = delivery_receipt_backup_path(db_path)
    recovery_path = delivery_receipt_recovery_path(db_path)
    fd, stage_name = tempfile.mkstemp(
        dir=db_path.parent,
        prefix=f".{db_path.name}.008-expected.",
        suffix=".sqlite",
    )
    os.close(fd)
    stage_path = Path(stage_name)
    try:
        atomic_copy_private(backup_path, stage_path)
        with sqlite3.connect(stage_path) as staged_connection:
            stage_migration(staged_connection)
        write_hash_pair(
            recovery_path,
            file_sha256(backup_path),
            file_sha256(stage_path),
        )
    finally:
        _remove_stage_files(stage_path)


def reconcile_delivery_receipt_recovery(
    db_path: Path,
    *,
    migration_applied: bool,
) -> DeliveryReceiptRecoveryStatus:
    backup_path = delivery_receipt_backup_path(db_path)
    recovery_path = delivery_receipt_recovery_path(db_path)
    guard_path = delivery_receipt_rollback_guard_path(db_path)
    recovery_exists = recovery_path.exists() or recovery_path.is_symlink()
    guard_hashes = read_hash_pair(guard_path)
    if not recovery_exists:
        return _status_without_recovery(
            backup_path,
            guard_hashes,
            migration_applied,
        )
    recovery_hashes = read_hash_pair(recovery_path)
    guard_is_valid = guard_hashes is not None and _backup_matches(
        backup_path,
        guard_hashes[0],
    )
    if recovery_hashes is None:
        if guard_is_valid:
            remove_private_file(recovery_path)
            return DeliveryReceiptRecoveryStatus.GUARDED
        _raise_invalid_state()
    if not _backup_matches(
        backup_path,
        recovery_hashes[0],
    ):
        _raise_invalid_state()
    if guard_hashes == recovery_hashes:
        remove_private_file(recovery_path)
        return DeliveryReceiptRecoveryStatus.GUARDED
    live_sha256 = file_sha256(db_path)
    if live_sha256 == recovery_hashes[1]:
        write_hash_pair(guard_path, *recovery_hashes)
        remove_private_file(recovery_path)
        return DeliveryReceiptRecoveryStatus.MIGRATED
    if live_sha256 == recovery_hashes[0]:
        remove_private_file(recovery_path)
        return DeliveryReceiptRecoveryStatus.PRECOMMIT
    return _raise_mismatch()


def complete_delivery_receipt_recovery(db_path: Path) -> None:
    recovery_path = delivery_receipt_recovery_path(db_path)
    guard_path = delivery_receipt_rollback_guard_path(db_path)
    recovery_hashes = read_hash_pair(recovery_path)
    guard_hashes = read_hash_pair(guard_path)
    if recovery_hashes is None or guard_hashes != recovery_hashes:
        _raise_invalid_state()
    remove_private_file(recovery_path)


def delivery_receipt_recovery_is_complete(db_path: Path) -> bool:
    recovery_path = delivery_receipt_recovery_path(db_path)
    if recovery_path.exists() or recovery_path.is_symlink():
        return False
    guard_hashes = read_hash_pair(delivery_receipt_rollback_guard_path(db_path))
    return guard_hashes is not None and _backup_matches(
        delivery_receipt_backup_path(db_path),
        guard_hashes[0],
    )


def _status_without_recovery(
    backup_path: Path,
    guard_hashes: tuple[str, str] | None,
    migration_applied: bool,
) -> DeliveryReceiptRecoveryStatus:
    if guard_hashes is not None and _backup_matches(backup_path, guard_hashes[0]):
        return DeliveryReceiptRecoveryStatus.GUARDED
    if migration_applied:
        _raise_invalid_state()
    return DeliveryReceiptRecoveryStatus.NONE


def _backup_matches(backup_path: Path, expected_sha256: str) -> bool:
    try:
        return file_sha256(backup_path) == expected_sha256
    except OSError:
        return False


def _remove_stage_files(stage_path: Path) -> None:
    remove_private_file(stage_path)
    for suffix in ("-journal", "-wal", "-shm"):
        sidecar = Path(f"{stage_path}{suffix}")
        if sidecar.exists() or sidecar.is_symlink():
            remove_private_file(sidecar)


def _raise_invalid_state() -> NoReturn:
    message = "invalid delivery receipt migration recovery state"
    raise DeliveryReceiptRecoveryStateError(message)


def _raise_mismatch() -> NoReturn:
    message = "delivery receipt migration recovery mismatch"
    raise DeliveryReceiptRecoveryMismatchError(message)

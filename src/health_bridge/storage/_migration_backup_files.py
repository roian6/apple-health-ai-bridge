import hashlib
import os
import re
import shutil
import stat
import tempfile
from enum import StrEnum
from pathlib import Path
from typing import Final

from health_bridge.private_files import (
    PRIVATE_FILE_MODE,
    apply_private_file_mode,
    ensure_private_directory,
    write_private_text_file,
)

DELIVERY_RECEIPT_MIGRATION_ID: Final = "008_delivery_receipts"
HASH_PAIR_PATTERN: Final = re.compile(
    r"pre_migration_sha256=([0-9a-f]{64})\n" + r"post_migration_sha256=([0-9a-f]{64})\n"
)
HASH_PAIR_TEMPLATE: Final = "pre_migration_sha256={}\npost_migration_sha256={}\n"


class DeliveryReceiptRollbackDecision(StrEnum):
    RESTORED = "restored"
    HOLD_MISSING_BACKUP = "hold_missing_backup"
    HOLD_INVALID_GUARD = "hold_invalid_guard"
    HOLD_BACKUP_MISMATCH = "hold_backup_mismatch"
    HOLD_POST_MIGRATION_COMMIT = "hold_post_migration_commit"


def delivery_receipt_backup_path(db_path: Path) -> Path:
    return Path(f"{db_path}.pre-{DELIVERY_RECEIPT_MIGRATION_ID}.sqlite")


def delivery_receipt_rollback_guard_path(db_path: Path) -> Path:
    return Path(f"{db_path}.pre-{DELIVERY_RECEIPT_MIGRATION_ID}.sha256")


def delivery_receipt_recovery_path(db_path: Path) -> Path:
    return Path(f"{db_path}.pre-{DELIVERY_RECEIPT_MIGRATION_ID}.pending")


def prepare_delivery_receipt_backup(db_path: Path) -> None:
    atomic_copy_private(db_path, delivery_receipt_backup_path(db_path))


def finalize_delivery_receipt_rollback_guard(db_path: Path) -> None:
    backup_sha256 = file_sha256(delivery_receipt_backup_path(db_path))
    migrated_sha256 = file_sha256(db_path)
    write_hash_pair(
        delivery_receipt_rollback_guard_path(db_path),
        backup_sha256,
        migrated_sha256,
    )


def restore_delivery_receipt_backup_locked(
    db_path: Path,
) -> DeliveryReceiptRollbackDecision:
    backup_path = delivery_receipt_backup_path(db_path)
    guard_path = delivery_receipt_rollback_guard_path(db_path)
    if not backup_path.is_file() or backup_path.is_symlink():
        return DeliveryReceiptRollbackDecision.HOLD_MISSING_BACKUP
    try:
        guard = read_regular_file(guard_path).decode("ascii")
    except (FileNotFoundError, UnicodeDecodeError, OSError):
        return DeliveryReceiptRollbackDecision.HOLD_INVALID_GUARD
    match = HASH_PAIR_PATTERN.fullmatch(guard)
    if match is None:
        return DeliveryReceiptRollbackDecision.HOLD_INVALID_GUARD
    backup_sha256, migrated_sha256 = match.groups()
    if file_sha256(backup_path) != backup_sha256:
        return DeliveryReceiptRollbackDecision.HOLD_BACKUP_MISMATCH
    if file_sha256(db_path) != migrated_sha256:
        return DeliveryReceiptRollbackDecision.HOLD_POST_MIGRATION_COMMIT
    atomic_copy_private(backup_path, db_path)
    return DeliveryReceiptRollbackDecision.RESTORED


def atomic_copy_private(source: Path, destination: Path) -> None:
    ensure_private_directory(destination.parent)
    source_fd = _open_regular_file(source)
    temp_fd = -1
    temp_path: Path | None = None
    try:
        temp_fd, temp_name = tempfile.mkstemp(
            dir=destination.parent,
            prefix=f".{destination.name}.",
            suffix=".tmp",
        )
        temp_path = Path(temp_name)
        apply_private_file_mode(temp_fd, temp_path)
        with (
            os.fdopen(source_fd, "rb") as source_file,
            os.fdopen(temp_fd, "wb") as destination_file,
        ):
            source_fd = -1
            temp_fd = -1
            _ = shutil.copyfileobj(source_file, destination_file)
            destination_file.flush()
            os.fsync(destination_file.fileno())
        _ = temp_path.replace(destination)
        temp_path = None
        directory_fd = os.open(
            destination.parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if source_fd >= 0:
            os.close(source_fd)
        if temp_fd >= 0:
            os.close(temp_fd)
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    fd = _open_regular_file(path)
    with os.fdopen(fd, "rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def read_regular_file(path: Path) -> bytes:
    fd = _open_regular_file(path)
    with os.fdopen(fd, "rb") as file:
        return file.read()


def _open_regular_file(path: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    opened = os.fstat(fd)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != PRIVATE_FILE_MODE
    ):
        os.close(fd)
        message = f"migration backup path is not a private regular file: {path}"
        raise OSError(message)
    return fd


def read_hash_pair(path: Path) -> tuple[str, str] | None:
    try:
        content = read_regular_file(path).decode("ascii")
    except (FileNotFoundError, UnicodeDecodeError, OSError):
        return None
    match = HASH_PAIR_PATTERN.fullmatch(content)
    if match is None:
        return None
    return match.group(1), match.group(2)


def write_hash_pair(path: Path, before: str, after: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{64}", before) or not re.fullmatch(
        r"[0-9a-f]{64}",
        after,
    ):
        message = "migration recovery hashes must be lowercase SHA-256"
        raise ValueError(message)
    write_private_text_file(path, HASH_PAIR_TEMPLATE.format(before, after))


def remove_private_file(path: Path) -> None:
    path.unlink(missing_ok=True)
    directory_fd = os.open(
        path.parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

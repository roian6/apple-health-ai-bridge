from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol


class MailboxImportFaultPoint(StrEnum):
    AFTER_DELIVERY_OPEN = "after_delivery_open"
    BEFORE_ACCEPT = "before_accept"
    AFTER_ACCEPT = "after_accept"
    BEFORE_ACK_RENAME = "before_ack_rename"
    AFTER_ACK_RENAME = "after_ack_rename"
    BEFORE_CLEANUP_UNLINK = "before_cleanup_unlink"


class MailboxImportFaultHook(Protocol):
    def __call__(self, point: MailboxImportFaultPoint) -> None: ...


@dataclass(frozen=True, slots=True)
class MailboxImportResult:
    imported: int = 0
    idempotent: int = 0
    quarantined: int = 0
    retryable: int = 0
    conflict: int = 0
    skipped: int = 0

    def counts(self) -> tuple[int, int, int, int, int, int]:
        return (
            self.imported,
            self.idempotent,
            self.quarantined,
            self.retryable,
            self.conflict,
            self.skipped,
        )

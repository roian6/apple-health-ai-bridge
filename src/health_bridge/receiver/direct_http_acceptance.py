from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from typing import TYPE_CHECKING, TypeAlias, assert_never, final

from health_bridge.receiver.batch_acceptance import (
    BatchAcceptanceCore,
    BatchAcceptanceInput,
    BatchPayloadInvalid,
    BatchPrincipalMismatch,
    PreparedBatch,
)
from health_bridge.storage.sleep import StaleOrderedSleepBaselineResetError

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.storage.models import IngestResult


@dataclass(frozen=True, slots=True)
class DirectBatchAccepted:
    ingest_result: IngestResult


@dataclass(frozen=True, slots=True)
class DirectBatchPayloadInvalid:
    pass


@dataclass(frozen=True, slots=True)
class DirectBatchPrincipalMismatch:
    pass


@dataclass(frozen=True, slots=True)
class DirectBatchSleepBaselineConflict:
    minimum_reset_epoch: int


@dataclass(frozen=True, slots=True)
class DirectBatchStorageUnavailable:
    pass


DirectHTTPAcceptanceResult: TypeAlias = (
    DirectBatchAccepted
    | DirectBatchPayloadInvalid
    | DirectBatchPrincipalMismatch
    | DirectBatchSleepBaselineConflict
    | DirectBatchStorageUnavailable
)


@final
class DirectHTTPAcceptance:
    def __init__(self, db_path: Path) -> None:
        self._db_path = db_path

    def accept(self, value: BatchAcceptanceInput) -> DirectHTTPAcceptanceResult:
        prepared = BatchAcceptanceCore.prepare(value)
        # BasedPyright rejects an unreachable default; terminal assert_never follows.
        match prepared:  # noqa: RUF100 -- no-excuse marker "# noqa: MATCH_OK"
            case PreparedBatch():
                return self._commit(prepared)
            case BatchPayloadInvalid():
                return DirectBatchPayloadInvalid()
            case BatchPrincipalMismatch():
                return DirectBatchPrincipalMismatch()
        assert_never(prepared)

    def _commit(self, prepared: PreparedBatch) -> DirectHTTPAcceptanceResult:
        try:
            result = BatchAcceptanceCore.commit(
                self._db_path,
                prepared,
                "receiver",
            )
        except StaleOrderedSleepBaselineResetError as exc:
            return DirectBatchSleepBaselineConflict(exc.current_epoch)
        except (sqlite3.Error, OSError):
            return DirectBatchStorageUnavailable()
        return DirectBatchAccepted(result)

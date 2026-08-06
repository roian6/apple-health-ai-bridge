from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, TypeAlias, final

from pydantic import ValidationError

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.ingest import (
    ingest_batch,
    ingest_batch_in_connection,
)
from health_bridge.receiver.source_binding import (
    SourcePrincipalMismatchError,
    bind_batch_to_principal,
)

if TYPE_CHECKING:
    import sqlite3
    from pathlib import Path

    from health_bridge.ingest import TransactionalIngestResult
    from health_bridge.receiver.tokens import ReceiverTokenPrincipal
    from health_bridge.storage.models import IngestResult


@dataclass(frozen=True, slots=True)
class BatchAcceptanceInput:
    exact_bytes: bytes
    principal: ReceiverTokenPrincipal


@dataclass(frozen=True, slots=True)
class PreparedBatch:
    exact_bytes: bytes
    batch: HealthBridgeBatchV1


@dataclass(frozen=True, slots=True)
class BatchPayloadInvalid:
    pass


@dataclass(frozen=True, slots=True)
class BatchPrincipalMismatch:
    pass


BatchPreparationResult: TypeAlias = (
    PreparedBatch | BatchPayloadInvalid | BatchPrincipalMismatch
)


@final
class BatchAcceptanceCore:
    @staticmethod
    def prepare(value: BatchAcceptanceInput) -> BatchPreparationResult:
        try:
            batch = HealthBridgeBatchV1.model_validate_json(value.exact_bytes)
        except ValidationError:
            return BatchPayloadInvalid()
        try:
            bound = bind_batch_to_principal(batch, value.principal)
        except SourcePrincipalMismatchError:
            return BatchPrincipalMismatch()
        return PreparedBatch(exact_bytes=value.exact_bytes, batch=bound)

    @staticmethod
    def commit(
        db_path: Path,
        prepared: PreparedBatch,
        source_name: str,
    ) -> IngestResult:
        return ingest_batch(db_path, prepared.batch, source_name)

    @staticmethod
    def commit_in_connection(
        connection: sqlite3.Connection,
        prepared: PreparedBatch,
        source_name: str,
    ) -> TransactionalIngestResult:
        return ingest_batch_in_connection(connection, prepared.batch, source_name)

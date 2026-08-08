from __future__ import annotations

import hashlib
import sqlite3
from typing import TYPE_CHECKING, assert_never, final

from health_bridge.contract.delivery_v1 import DeliveryProtocolError, DeliveryReceiptV1
from health_bridge.receiver._delivery_acceptance_crypto import (
    committed_receipt_record,
    envelope_claims,
    open_exact_plaintext,
    receipt_ack_id,
    same_receipt_context,
    seal_receipt,
    stored_receipt,
)
from health_bridge.receiver._delivery_acceptance_models import (
    DeliveryAcceptanceFaultHook,
    DeliveryAcceptanceFaultPoint,
    DeliveryAcceptanceRequest,
    DeliveryAcceptanceResult,
    DeliveryEnvelopeClaims,
    DeliveryTerminalError,
    DeliveryTrustedConnection,
)
from health_bridge.receiver.batch_acceptance import (
    BatchAcceptanceCore,
    BatchAcceptanceInput,
    BatchPayloadInvalid,
    BatchPrincipalMismatch,
    PreparedBatch,
)
from health_bridge.storage.database import connect_database
from health_bridge.storage.delivery_receipts import (
    DeliveryReceiptConflictError,
    DeliveryReceiptRecord,
    fetch_delivery_receipt_by_scope,
    insert_delivery_receipt,
)
from health_bridge.storage.sleep import StaleOrderedSleepBaselineResetError

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

    from health_bridge.contract._delivery_common import TerminalCode

__all__ = [
    "DeliveryAcceptanceFaultPoint",
    "DeliveryAcceptanceRequest",
    "DeliveryAcceptanceResult",
    "DeliveryAcceptanceService",
    "DeliveryTrustedConnection",
]


@final
class DeliveryAcceptanceService:
    def __init__(
        self,
        db_path: Path,
        connection: DeliveryTrustedConnection,
        clock_ms: Callable[[], int],
        before_commit_validator: Callable[[], None] | None = None,
    ) -> None:
        self._db_path = db_path
        self._connection = connection
        self._clock_ms = clock_ms
        self._before_commit_validator = before_commit_validator

    def accept(
        self,
        request: DeliveryAcceptanceRequest,
        fault_hook: DeliveryAcceptanceFaultHook | None = None,
    ) -> DeliveryAcceptanceResult:
        claims = envelope_claims(request.envelope_bytes, self._connection)
        try:
            plaintext = open_exact_plaintext(
                request.envelope_bytes,
                claims,
                self._connection,
            )
        except DeliveryProtocolError as exc:
            if exc.code == "authentication_failed":
                raise
            return self._terminal(claims, exc.code)
        try:
            prepared = self._prepared_batch(request, claims, plaintext)
        except DeliveryTerminalError as exc:
            return self._terminal(claims, exc.code)
        digest = hashlib.sha256(prepared.exact_bytes).digest()
        self._fault(fault_hook, DeliveryAcceptanceFaultPoint.BEFORE_CLAIM)
        try:
            with connect_database(self._db_path) as database:
                _ = database.execute("begin immediate")
                existing = fetch_delivery_receipt_by_scope(
                    database,
                    receiver_id=self._connection.receiver_id,
                    device_id=self._connection.device_id,
                    envelope_id=claims.envelope_id,
                )
                if existing is not None:
                    return self._existing(existing, claims, digest, fault_hook)
                self._fault(fault_hook, DeliveryAcceptanceFaultPoint.AFTER_CLAIM)
                ingested = BatchAcceptanceCore.commit_in_connection(
                    database,
                    prepared,
                    "delivery",
                )
                self._fault(fault_hook, DeliveryAcceptanceFaultPoint.DURING_INGEST)
                receipt = DeliveryReceiptV1(
                    result="committed",
                    payload_sha256=digest.hex(),
                    receipt_id=ingested.sync_run_id,
                    dataset_generation=ingested.sync_run_id,
                    committed_at_ms=self._clock_ms(),
                    error_code=None,
                )
                record = committed_receipt_record(receipt, claims, self._connection)
                _ = insert_delivery_receipt(database, record)
                self._fault(fault_hook, DeliveryAcceptanceFaultPoint.BEFORE_COMMIT)
                if self._before_commit_validator is not None:
                    self._before_commit_validator()
        except DeliveryReceiptConflictError:
            return self._terminal(claims, "duplicate_conflict")
        except (sqlite3.Error, OSError, StaleOrderedSleepBaselineResetError):
            return self._retryable(claims)
        self._fault(fault_hook, DeliveryAcceptanceFaultPoint.AFTER_COMMIT)
        return self._publish(receipt, claims, replayed=False, fault_hook=fault_hook)

    def _identity_error(
        self,
        request: DeliveryAcceptanceRequest,
        claims: DeliveryEnvelopeClaims,
    ) -> TerminalCode | None:
        if claims.connection_generation != self._connection.connection_generation:
            return "generation_mismatch"
        if self._connection.sender_key_revoked:
            return "key_revoked"
        if request.device_principal != self._connection.device_principal:
            return "principal_mismatch"
        if request.opaque_binding != self._connection.opaque_binding:
            return "binding_mismatch"
        return None

    def _prepared_batch(
        self,
        request: DeliveryAcceptanceRequest,
        claims: DeliveryEnvelopeClaims,
        plaintext: bytes,
    ) -> PreparedBatch:
        identity_error = self._identity_error(request, claims)
        if identity_error is not None:
            raise DeliveryTerminalError(identity_error)
        prepared = BatchAcceptanceCore.prepare(
            BatchAcceptanceInput(
                exact_bytes=plaintext,
                principal=self._connection.source_principal,
            )
        )
        # BasedPyright rejects an unreachable default; terminal assert_never follows.
        match prepared:  # noqa: RUF100 -- no-excuse marker "# noqa: MATCH_OK"
            case PreparedBatch():
                return prepared
            case BatchPayloadInvalid():
                code: TerminalCode = "payload_invalid"
                raise DeliveryTerminalError(code)
            case BatchPrincipalMismatch():
                code = "principal_mismatch"
                raise DeliveryTerminalError(code)
        assert_never(prepared)

    def _existing(
        self,
        existing: DeliveryReceiptRecord,
        claims: DeliveryEnvelopeClaims,
        digest: bytes,
        fault_hook: DeliveryAcceptanceFaultHook | None,
    ) -> DeliveryAcceptanceResult:
        if existing.payload_sha256 != digest or not same_receipt_context(
            existing,
            claims,
            self._connection,
        ):
            return self._terminal(claims, "duplicate_conflict")
        receipt = stored_receipt(existing)
        expected_ack_id = receipt_ack_id(receipt, claims.envelope_id)
        if expected_ack_id != existing.ack_id:
            return self._terminal(claims, "duplicate_conflict")
        return self._publish(receipt, claims, replayed=True, fault_hook=fault_hook)

    def _terminal(
        self,
        claims: DeliveryEnvelopeClaims,
        code: TerminalCode,
    ) -> DeliveryAcceptanceResult:
        receipt = DeliveryReceiptV1(
            result="terminal",
            payload_sha256=claims.payload_sha256.hex(),
            receipt_id=None,
            dataset_generation=None,
            committed_at_ms=None,
            error_code=code,
        )
        return DeliveryAcceptanceResult(
            ack_bytes=seal_receipt(receipt, claims, self._connection),
            receipt=receipt,
            replayed=False,
        )

    def _retryable(self, claims: DeliveryEnvelopeClaims) -> DeliveryAcceptanceResult:
        receipt = DeliveryReceiptV1(
            result="retryable",
            payload_sha256=claims.payload_sha256.hex(),
            receipt_id=None,
            dataset_generation=None,
            committed_at_ms=None,
            error_code="storage_unavailable",
        )
        return DeliveryAcceptanceResult(
            ack_bytes=seal_receipt(receipt, claims, self._connection),
            receipt=receipt,
            replayed=False,
        )

    def _publish(
        self,
        receipt: DeliveryReceiptV1,
        claims: DeliveryEnvelopeClaims,
        *,
        replayed: bool,
        fault_hook: DeliveryAcceptanceFaultHook | None,
    ) -> DeliveryAcceptanceResult:
        ack_bytes = seal_receipt(receipt, claims, self._connection)
        self._fault(fault_hook, DeliveryAcceptanceFaultPoint.BEFORE_ACK_PUBLICATION)
        return DeliveryAcceptanceResult(
            ack_bytes=ack_bytes,
            receipt=receipt,
            replayed=replayed,
        )

    @staticmethod
    def _fault(
        hook: DeliveryAcceptanceFaultHook | None,
        point: DeliveryAcceptanceFaultPoint,
    ) -> None:
        if hook is not None:
            hook(point)

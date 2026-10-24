from __future__ import annotations

import hashlib
import sqlite3
from typing import TYPE_CHECKING, assert_never, final

from pydantic import TypeAdapter

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
            prepared = self._prepared_batch(request, claims, plaintext)
        except (DeliveryProtocolError, DeliveryTerminalError) as exc:
            if exc.code == "authentication_failed":
                raise
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
                if not self._enrollment_valid(database):
                    return self._terminal(claims, "key_revoked")
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

    def _enrollment_valid(self, database: sqlite3.Connection) -> bool:
        trusted = self._connection
        installation = trusted.source_principal.installation_id_hash
        # Existing explicitly configured unbound delivery principals are unchanged.
        if installation is None:
            return not trusted.device_principal.value.startswith("installation:")
        rows = TypeAdapter(
            list[tuple[str, str | None, str, str | None]]
        ).validate_python(
            database.execute(
                """select redemption.pairing_invitation_id, mailbox_enrollment_sha256,
                invitation.receiver_url, native_request_sha256
                from pairing_invitation_redemptions redemption
                join pairing_invitations invitation using (pairing_invitation_id)
                join receiver_devices device using (receiver_device_id)
                join receiver_tokens token using (receiver_token_id)
                join receiver_token_devices mapping
                  on mapping.receiver_token_id = redemption.receiver_token_id
                 and mapping.receiver_device_id = redemption.receiver_device_id
                where invitation.transport = 'mailbox'
                  and invitation.redeemed_at is not null
                  and invitation.revoked_at is null and device.revoked_at is null
                  and token.revoked_at is null and device.installation_id_hash = ?""",
                (installation,),
            ).fetchall()
        )
        if len(rows) != 1:
            return False
        invitation_id, digest, url, native_request = rows[0]
        expected = trusted.enrollment_digest()
        if digest is not None:
            return digest == expected
        return (
            trusted.device_principal.value == f"installation:{installation}"
            and bool(url)
            and native_request is None
            and self._legacy_binding_valid()
            and self._preserve_legacy_enrollment(database, invitation_id, expected)
        )

    def _preserve_legacy_enrollment(
        self,
        database: sqlite3.Connection,
        invitation_id: str,
        expected: str,
    ) -> bool:
        # A completed URL redemption already authorizes its persisted canonical
        # trust, even before the first delivery. The caller verifies the unique
        # active principal/mapping and excludes URL-free native orphan state.
        _ = database.execute(
            """update pairing_invitation_redemptions set mailbox_enrollment_sha256 = ?
            where pairing_invitation_id = ? and mailbox_enrollment_sha256 is null""",
            (expected, invitation_id),
        )
        return True

    def _legacy_binding_valid(self) -> bool:
        trusted = self._connection
        installation = trusted.source_principal.installation_id_hash
        if installation is None or trusted.connection_generation != 1:
            return False
        signing = trusted.receiver_signing_private_key.public_key().public_bytes_raw()
        receiver = hashlib.sha256(
            b"health-bridge/mailbox/v1/receiver-id\0" + signing
        ).digest()[:16]
        device = hashlib.sha256(
            b"health-bridge/mailbox/v1/device-id\0" + bytes.fromhex(installation)
        ).digest()[:16]
        binding = hashlib.sha256(
            b"health-bridge/mailbox/v1/connection-binding\0"
            + receiver
            + device
            + trusted.sender_signing_public_key.public_bytes_raw()
            + trusted.device_agreement_public_key.public_bytes_raw()
            + signing
            + trusted.receiver_agreement_private_key.public_key().public_bytes_raw()
        ).digest()
        return (
            trusted.receiver_id == receiver
            and trusted.device_id == device
            and trusted.opaque_binding.value == binding
        )

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

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, assert_never, cast, final

from typing_extensions import override

from health_bridge.contract._delivery_common import MAX_ENVELOPE_BYTES
from health_bridge.contract.delivery_v1 import DeliveryProtocolError
from health_bridge.mailbox.filesystem import (
    FileSnapshot,
    MailboxFileError,
    MailboxFileErrorCode,
    mailbox_writer_lock,
    read_final,
    revalidate_final,
    scan_delivery_lane,
    unlink_same,
)
from health_bridge.mailbox.models import (
    MailboxImportFaultHook,
    MailboxImportFaultPoint,
    MailboxImportResult,
)
from health_bridge.mailbox.publication import (
    ACK_RETENTION_MS,
    DELIVERY_RETENTION_MS,
    PublicationState,
    cleanup_expired_finals,
    cleanup_quarantine,
    cleanup_stale_temps,
    publish_final,
    publish_quarantine,
)
from health_bridge.receiver._delivery_acceptance_crypto import (
    envelope_claims,
    receipt_ack_id,
)
from health_bridge.receiver.delivery_acceptance import (
    DeliveryAcceptanceRequest,
    DeliveryAcceptanceResult,
    DeliveryAcceptanceService,
)

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path
    from typing import Literal

    from health_bridge.receiver.delivery_acceptance import DeliveryTrustedConnection


@dataclass(frozen=True, slots=True)
class MailboxImportConfig:
    db_path: Path
    mailbox_path: Path
    lock_path: Path
    connection: DeliveryTrustedConnection
    clock_ms: Callable[[], int]
    path_replacement_retry_limit: int = 0


class MailboxBusyError(Exception):
    @override
    def __str__(self) -> str:
        return "mailbox importer is busy"


@dataclass(frozen=True, slots=True)
class _AcceptedDelivery:
    snapshot: FileSnapshot
    result: DeliveryAcceptanceResult
    ack_name: str


@final
class MailboxImporter:
    def __init__(self, config: MailboxImportConfig) -> None:
        if not 0 <= config.path_replacement_retry_limit <= 1:
            raise ValueError
        self._config = config

    def import_once(
        self,
        fault_hook: MailboxImportFaultHook | None = None,
    ) -> MailboxImportResult:
        try:
            with mailbox_writer_lock(self._config.lock_path):
                return self._import_locked(fault_hook)
        except BlockingIOError as exc:
            raise MailboxBusyError from exc

    def expected_ack_path(self, delivery_path: Path) -> Path:
        accepted = self._accept(delivery_path, None)
        return self._config.mailbox_path / "acks" / accepted.ack_name

    def _import_locked(
        self,
        fault_hook: MailboxImportFaultHook | None,
    ) -> MailboxImportResult:
        deliveries = self._config.mailbox_path / "deliveries"
        acks = self._config.mailbox_path / "acks"
        quarantine = self._config.mailbox_path / "quarantine"
        scan = scan_delivery_lane(deliveries)
        aggregate = MailboxImportResult(skipped=scan.skipped)
        for entry in scan.entries:
            delivery_path = deliveries / entry.name
            try:
                accepted = self._accept_with_path_replacement_retry(
                    delivery_path,
                    fault_hook,
                )
                publication = publish_final(
                    acks,
                    accepted.ack_name,
                    accepted.result.ack_bytes,
                    fault_hook,
                )
            except MailboxFileError as exc:
                aggregate = _combine(
                    aggregate,
                    self._quarantine(quarantine, entry.name, exc.code.value),
                )
                continue
            except DeliveryProtocolError:
                aggregate = _combine(
                    aggregate,
                    self._quarantine(quarantine, entry.name, "authentication_failed"),
                )
                continue
            except OSError:
                aggregate = _combine(
                    aggregate,
                    MailboxImportResult(retryable=1),
                )
                continue
            if publication is PublicationState.CONFLICT:
                aggregate = _combine(aggregate, MailboxImportResult(conflict=1))
                continue
            aggregate = _combine(aggregate, _accepted_result(accepted.result))
            self._expire_delivery(delivery_path, accepted, acks)
        for lane in (deliveries, acks, quarantine):
            cleanup_stale_temps(
                lane,
                now_ms=self._config.clock_ms(),
                fault_hook=fault_hook,
            )
        cleanup_expired_finals(
            acks,
            extension="hba",
            retention_ms=ACK_RETENTION_MS,
            now_ms=self._config.clock_ms(),
        )
        cleanup_quarantine(quarantine, now_ms=self._config.clock_ms())
        return aggregate

    def _accept_with_path_replacement_retry(
        self,
        delivery_path: Path,
        fault_hook: MailboxImportFaultHook | None,
    ) -> _AcceptedDelivery:
        remaining = self._config.path_replacement_retry_limit
        while True:
            try:
                return self._accept(delivery_path, fault_hook)
            except MailboxFileError as exc:
                if exc.code is not MailboxFileErrorCode.PATH_REPLACED or remaining == 0:
                    raise
                remaining -= 1

    def _accept(
        self,
        delivery_path: Path,
        fault_hook: MailboxImportFaultHook | None,
    ) -> _AcceptedDelivery:
        snapshot = read_final(delivery_path, maximum_bytes=MAX_ENVELOPE_BYTES)
        try:
            _fault(fault_hook, MailboxImportFaultPoint.AFTER_DELIVERY_OPEN)
        except RuntimeError:
            if not revalidate_final(delivery_path, snapshot.identity):
                raise MailboxFileError(
                    code=MailboxFileErrorCode.PATH_REPLACED
                ) from None
            raise
        if not revalidate_final(delivery_path, snapshot.identity):
            raise MailboxFileError(code=MailboxFileErrorCode.PATH_REPLACED)
        claims = envelope_claims(snapshot.content, self._config.connection)
        if delivery_path.stem != claims.envelope_id.hex():
            code = "authentication_failed"
            raise DeliveryProtocolError(code)
        _fault(fault_hook, MailboxImportFaultPoint.BEFORE_ACCEPT)
        result = DeliveryAcceptanceService(
            self._config.db_path,
            self._config.connection,
            self._config.clock_ms,
        ).accept(
            DeliveryAcceptanceRequest(
                envelope_bytes=snapshot.content,
                device_principal=self._config.connection.device_principal,
                opaque_binding=self._config.connection.opaque_binding,
            )
        )
        _fault(fault_hook, MailboxImportFaultPoint.AFTER_ACCEPT)
        return _AcceptedDelivery(
            snapshot=snapshot,
            result=result,
            ack_name=f"{receipt_ack_id(result.receipt, claims.envelope_id).hex()}.hba",
        )

    def _quarantine(
        self,
        directory: Path,
        source_name: str,
        reason: str,
    ) -> MailboxImportResult:
        try:
            publication = publish_quarantine(directory, source_name, reason)
        except OSError:
            return MailboxImportResult(retryable=1)
        if publication is PublicationState.CONFLICT:
            return MailboxImportResult(conflict=1)
        return MailboxImportResult(quarantined=1)

    def _expire_delivery(
        self,
        delivery_path: Path,
        accepted: _AcceptedDelivery,
        ack_directory: Path,
    ) -> None:
        try:
            ack_stat = (ack_directory / accepted.ack_name).lstat()
        except OSError:
            return
        age_ms = self._config.clock_ms() - ack_stat.st_mtime_ns // 1_000_000
        if age_ms >= DELIVERY_RETENTION_MS:
            _ = unlink_same(delivery_path, accepted.snapshot.identity)


def _accepted_result(value: DeliveryAcceptanceResult) -> MailboxImportResult:
    result = cast(
        "Literal['committed', 'retryable', 'terminal']",
        value.receipt.result,
    )
    match result:
        case "committed":
            return (
                MailboxImportResult(idempotent=1)
                if value.replayed
                else MailboxImportResult(imported=1)
            )
        case "retryable":
            return MailboxImportResult(retryable=1)
        case "terminal":
            return (
                MailboxImportResult(conflict=1)
                if value.receipt.error_code == "duplicate_conflict"
                else MailboxImportResult(quarantined=1)
            )
        case _:
            assert_never(result)


def _combine(
    left: MailboxImportResult,
    right: MailboxImportResult,
) -> MailboxImportResult:
    return MailboxImportResult(
        imported=left.imported + right.imported,
        idempotent=left.idempotent + right.idempotent,
        quarantined=left.quarantined + right.quarantined,
        retryable=left.retryable + right.retryable,
        conflict=left.conflict + right.conflict,
        skipped=left.skipped + right.skipped,
    )


def _fault(
    hook: MailboxImportFaultHook | None,
    point: MailboxImportFaultPoint,
) -> None:
    if hook is not None:
        hook(point)

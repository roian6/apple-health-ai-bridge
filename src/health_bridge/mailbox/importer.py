from __future__ import annotations

import os
from collections.abc import Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING, assert_never, cast, final

from typing_extensions import override

from health_bridge.contract._delivery_common import MAX_ACK_BYTES, MAX_ENVELOPE_BYTES
from health_bridge.contract.delivery_v1 import DeliveryProtocolError
from health_bridge.mailbox.filesystem import (
    FileSnapshot,
    MailboxDirectoryHandle,
    MailboxFileError,
    MailboxFileErrorCode,
    mailbox_writer_lock,
    open_mailbox_directory,
    read_final_at,
    revalidate_final_at,
    scan_delivery_lane,
    unlink_same_at,
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
    cleanup_expired_finals_at,
    cleanup_quarantine_at,
    cleanup_stale_temps_at,
    publish_final_at,
    publish_quarantine_at,
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
    from pathlib import Path
    from typing import Literal

    from health_bridge.receiver.delivery_acceptance import DeliveryTrustedConnection


AckPublisher = Callable[[MailboxDirectoryHandle, str, bytes], PublicationState]


@dataclass(frozen=True, slots=True)
class MailboxImportConfig:
    db_path: Path
    mailbox_path: Path
    lock_path: Path
    connection: DeliveryTrustedConnection
    clock_ms: Callable[[], int]
    path_replacement_retry_limit: int = 0
    directory: MailboxDirectoryHandle | None = None
    ack_publisher: AckPublisher | None = None


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
                if self._config.directory is not None:
                    self._config.directory.validate_attached()
                    return self._import_locked(self._config.directory, fault_hook)
                with open_mailbox_directory(self._config.mailbox_path) as directory:
                    directory.validate_attached()
                    return self._import_locked(directory, fault_hook)
        except BlockingIOError as exc:
            raise MailboxBusyError from exc

    def expected_ack_path(self, delivery_path: Path) -> Path:
        with open_mailbox_directory(self._config.mailbox_path) as directory:
            accepted = self._accept(directory, delivery_path.name, None)
        return self._config.mailbox_path / "acks" / accepted.ack_name

    def _import_locked(
        self,
        directory: MailboxDirectoryHandle,
        fault_hook: MailboxImportFaultHook | None,
    ) -> MailboxImportResult:
        directory.validate_attached()
        scan = scan_delivery_lane(directory.deliveries_fd)
        aggregate = MailboxImportResult(skipped=scan.skipped)
        for entry in scan.entries:
            try:
                accepted = self._accept_with_path_replacement_retry(
                    directory,
                    entry.name,
                    fault_hook,
                )
                directory.validate_attached()
                publication = self._publish_ack(
                    directory,
                    accepted,
                    fault_hook,
                )
            except MailboxFileError as exc:
                directory.validate_attached()
                aggregate = _combine(
                    aggregate,
                    self._quarantine(directory, entry.name, exc.code.value),
                )
                continue
            except DeliveryProtocolError:
                directory.validate_attached()
                aggregate = _combine(
                    aggregate,
                    self._quarantine(directory, entry.name, "authentication_failed"),
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
            self._expire_delivery(directory, entry.name, accepted)
        for lane_fd in (
            directory.deliveries_fd,
            directory.acks_fd,
            directory.quarantine_fd,
        ):
            directory.validate_attached()
            cleanup_stale_temps_at(
                lane_fd,
                now_ms=self._config.clock_ms(),
                fault_hook=fault_hook,
                before_mutation=directory.validate_attached,
            )
        directory.validate_attached()
        cleanup_expired_finals_at(
            directory.acks_fd,
            extension="hba",
            retention_ms=ACK_RETENTION_MS,
            now_ms=self._config.clock_ms(),
            before_mutation=directory.validate_attached,
        )
        directory.validate_attached()
        cleanup_quarantine_at(
            directory.quarantine_fd,
            now_ms=self._config.clock_ms(),
            before_mutation=directory.validate_attached,
        )
        directory.validate_attached()
        return aggregate

    def _publish_ack(
        self,
        directory: MailboxDirectoryHandle,
        accepted: _AcceptedDelivery,
        fault_hook: MailboxImportFaultHook | None,
    ) -> PublicationState:
        try:
            metadata = os.stat(
                accepted.ack_name,
                dir_fd=directory.acks_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            existing = None
        except OSError:
            raise
        else:
            if metadata.st_nlink != 1:
                existing = None
            else:
                try:
                    existing = read_final_at(
                        directory.acks_fd,
                        accepted.ack_name,
                        maximum_bytes=MAX_ACK_BYTES,
                    ).content
                except MailboxFileError as exc:
                    raise OSError from exc
        if existing is not None:
            return (
                PublicationState.IDENTICAL
                if existing == accepted.result.ack_bytes
                else PublicationState.CONFLICT
            )
        directory.validate_attached()
        return (
            self._config.ack_publisher(
                directory,
                accepted.ack_name,
                accepted.result.ack_bytes,
            )
            if self._config.ack_publisher is not None
            else publish_final_at(
                directory.acks_fd,
                accepted.ack_name,
                accepted.result.ack_bytes,
                fault_hook,
                before_mutation=directory.validate_attached,
            )
        )

    def _accept_with_path_replacement_retry(
        self,
        directory: MailboxDirectoryHandle,
        delivery_name: str,
        fault_hook: MailboxImportFaultHook | None,
    ) -> _AcceptedDelivery:
        remaining = self._config.path_replacement_retry_limit
        while True:
            try:
                return self._accept(directory, delivery_name, fault_hook)
            except MailboxFileError as exc:
                if exc.code is not MailboxFileErrorCode.PATH_REPLACED or remaining == 0:
                    raise
                remaining -= 1

    def _accept(
        self,
        directory: MailboxDirectoryHandle,
        delivery_name: str,
        fault_hook: MailboxImportFaultHook | None,
    ) -> _AcceptedDelivery:
        snapshot = read_final_at(
            directory.deliveries_fd,
            delivery_name,
            maximum_bytes=MAX_ENVELOPE_BYTES,
        )
        try:
            _fault(fault_hook, MailboxImportFaultPoint.AFTER_DELIVERY_OPEN)
        except RuntimeError:
            if not revalidate_final_at(
                directory.deliveries_fd, delivery_name, snapshot.identity
            ):
                raise MailboxFileError(
                    code=MailboxFileErrorCode.PATH_REPLACED
                ) from None
            raise
        if not revalidate_final_at(
            directory.deliveries_fd, delivery_name, snapshot.identity
        ):
            raise MailboxFileError(code=MailboxFileErrorCode.PATH_REPLACED)
        claims = envelope_claims(snapshot.content, self._config.connection)
        if delivery_name.removesuffix(".hbd") != claims.envelope_id.hex():
            code = "authentication_failed"
            raise DeliveryProtocolError(code)
        _fault(fault_hook, MailboxImportFaultPoint.BEFORE_ACCEPT)
        directory.validate_attached()
        result = DeliveryAcceptanceService(
            self._config.db_path,
            self._config.connection,
            self._config.clock_ms,
            before_commit_validator=directory.validate_attached,
        ).accept(
            DeliveryAcceptanceRequest(
                envelope_bytes=snapshot.content,
                device_principal=self._config.connection.device_principal,
                opaque_binding=self._config.connection.opaque_binding,
            )
        )
        _fault(fault_hook, MailboxImportFaultPoint.AFTER_ACCEPT)
        receipt_result = cast(
            "Literal['committed', 'retryable', 'terminal']",
            result.receipt.result,
        )
        match receipt_result:
            case "committed" | "terminal":
                ack_identifier = claims.envelope_id
            case "retryable":
                ack_identifier = receipt_ack_id(result.receipt, claims.envelope_id)
            case _:
                assert_never(receipt_result)
        return _AcceptedDelivery(
            snapshot=snapshot,
            result=result,
            ack_name=f"{ack_identifier.hex()}.hba",
        )

    def _quarantine(
        self,
        directory: MailboxDirectoryHandle,
        source_name: str,
        reason: str,
    ) -> MailboxImportResult:
        directory.validate_attached()
        try:
            publication = publish_quarantine_at(
                directory.quarantine_fd,
                source_name,
                reason,
                before_mutation=directory.validate_attached,
            )
        except OSError:
            return MailboxImportResult(retryable=1)
        if publication is PublicationState.CONFLICT:
            return MailboxImportResult(conflict=1)
        return MailboxImportResult(quarantined=1)

    def _expire_delivery(
        self,
        directory: MailboxDirectoryHandle,
        delivery_name: str,
        accepted: _AcceptedDelivery,
    ) -> None:
        directory.validate_attached()
        try:
            ack_stat = os.stat(
                accepted.ack_name,
                dir_fd=directory.acks_fd,
                follow_symlinks=False,
            )
        except OSError:
            return
        age_ms = self._config.clock_ms() - ack_stat.st_mtime_ns // 1_000_000
        if age_ms >= DELIVERY_RETENTION_MS:
            directory.validate_attached()
            _ = unlink_same_at(
                directory.deliveries_fd,
                delivery_name,
                accepted.snapshot.identity,
                before_unlink=directory.validate_attached,
            )


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

from __future__ import annotations

import os
import re
import sqlite3
import stat
import time
from collections.abc import Callable, Iterable
from enum import StrEnum
from pathlib import Path
from threading import Event, Lock, Thread
from typing import TYPE_CHECKING, Final, Protocol, final

from typing_extensions import override

from health_bridge.mailbox.filesystem import (
    MailboxDirectoryHandle,
    MailboxFileError,
    MailboxFileErrorCode,
    open_directory_at,
    open_directory_with_parent,
    open_mailbox_at,
)

if TYPE_CHECKING:
    from health_bridge.mailbox.models import MailboxImportResult

MAX_RECEIVER_ENTRIES: Final = 128
MAX_DEVICE_ENTRIES: Final = 1_024
MAX_RAW_RECEIVER_ENTRIES: Final = 4_096
MAX_RAW_DEVICE_ENTRIES: Final = 16_384
MAILBOX_POLL_INTERVAL_SECONDS: Final = 1.0
MAILBOX_SHUTDOWN_TIMEOUT_SECONDS: Final = 5.0
MAILBOX_MAINTENANCE_INTERVAL_SECONDS: Final = 300.0
MAILBOX_INCOMPLETE_RETRY_INTERVAL_SECONDS: Final = 30.0
MAX_LANE_SIGNATURE_ENTRIES: Final = 16_384
_OPAQUE_COMPONENT: Final = re.compile(r"^[0-9a-f]{32}$")


class MailboxImporterProtocol(Protocol):
    def import_once(self) -> MailboxImportResult: ...


MailboxImporterFactory = Callable[
    [Path, Path, MailboxDirectoryHandle], MailboxImporterProtocol
]
MailboxEntrySignature = tuple[str, int, int, int, int, int, int, int, int, int]
MailboxLaneSignature = tuple[tuple[MailboxEntrySignature, ...], ...]


class MailboxDiscoveryErrorCode(StrEnum):
    RAW_BUDGET_EXCEEDED = "mailbox_discovery_raw_budget_exceeded"
    ROOT_UNAVAILABLE = "mailbox_discovery_root_unavailable"
    UNSAFE_ROOT = "mailbox_discovery_unsafe_root"
    STORAGE_UNAVAILABLE = "mailbox_discovery_storage_unavailable"
    NAMESPACE_DETACHED = "mailbox_namespace_detached"


class MailboxDiscoveryError(Exception):
    def __init__(self, code: MailboxDiscoveryErrorCode) -> None:
        super().__init__(code.value)
        self.code: MailboxDiscoveryErrorCode = code

    @override
    def __str__(self) -> str:
        return self.code.value


def _close_handles(handles: Iterable[MailboxDirectoryHandle]) -> None:
    first_error: OSError | None = None
    for handle in handles:
        try:
            handle.close()
        except OSError as exc:
            if first_error is None:
                first_error = exc
    if first_error is not None:
        raise first_error


def discover_mailboxes(
    mailbox_root: Path,
    *,
    max_receiver_entries: int = MAX_RECEIVER_ENTRIES,
    max_device_entries: int = MAX_DEVICE_ENTRIES,
    max_raw_receiver_entries: int = MAX_RAW_RECEIVER_ENTRIES,
    max_raw_device_entries: int = MAX_RAW_DEVICE_ENTRIES,
) -> tuple[Path, ...]:
    if (
        min(
            max_receiver_entries,
            max_device_entries,
            max_raw_receiver_entries,
            max_raw_device_entries,
        )
        < 1
    ):
        raise ValueError
    handles = _discover_mailbox_handles(
        mailbox_root,
        max_receiver_entries=max_receiver_entries,
        max_device_entries=max_device_entries,
        max_raw_receiver_entries=max_raw_receiver_entries,
        max_raw_device_entries=max_raw_device_entries,
    )
    try:
        return tuple(sorted(handle.path for handle in handles))
    finally:
        _close_handles(handles)


def _bounded_safe_directory_names(
    parent_fd: int, *, valid_limit: int, raw_limit: int
) -> tuple[str, ...]:
    directories: list[str] = []
    with os.scandir(parent_fd) as entries:
        for raw_count, entry in enumerate(entries, start=1):
            if raw_count > raw_limit:
                raise MailboxDiscoveryError(
                    MailboxDiscoveryErrorCode.RAW_BUDGET_EXCEEDED
                )
            try:
                if (
                    len(directories) < valid_limit
                    and _OPAQUE_COMPONENT.fullmatch(entry.name) is not None
                    and entry.is_dir(follow_symlinks=False)
                    and not entry.is_symlink()
                ):
                    directories.append(entry.name)
            except OSError:
                continue
    return tuple(directories)


def _discover_mailbox_handles(  # noqa: C901 - bounded traversal policy.
    mailbox_root: Path,
    *,
    max_receiver_entries: int,
    max_device_entries: int,
    max_raw_receiver_entries: int,
    max_raw_device_entries: int,
) -> tuple[MailboxDirectoryHandle, ...]:
    handles: list[MailboxDirectoryHandle] = []
    try:
        root_stat = mailbox_root.lstat()
    except FileNotFoundError as exc:
        raise MailboxDiscoveryError(MailboxDiscoveryErrorCode.ROOT_UNAVAILABLE) from exc
    except OSError as exc:
        raise MailboxDiscoveryError(
            MailboxDiscoveryErrorCode.STORAGE_UNAVAILABLE
        ) from exc
    if not stat.S_ISDIR(root_stat.st_mode) or mailbox_root.is_symlink():
        raise MailboxDiscoveryError(MailboxDiscoveryErrorCode.UNSAFE_ROOT)
    try:
        root_parent_fd, root_fd, root_name = open_directory_with_parent(mailbox_root)
    except MailboxFileError as exc:
        code = (
            MailboxDiscoveryErrorCode.UNSAFE_ROOT
            if exc.code.value == "unsafe_entry"
            else MailboxDiscoveryErrorCode.STORAGE_UNAVAILABLE
        )
        raise MailboxDiscoveryError(code) from exc
    try:
        receiver_names = _bounded_safe_directory_names(
            root_fd,
            valid_limit=max_receiver_entries,
            raw_limit=max_raw_receiver_entries,
        )
        for receiver_name in receiver_names:
            try:
                receiver_fd = open_directory_at(root_fd, receiver_name)
            except MailboxFileError:
                continue
            try:
                device_names = _bounded_safe_directory_names(
                    receiver_fd,
                    valid_limit=max_device_entries,
                    raw_limit=max_raw_device_entries,
                )
            finally:
                os.close(receiver_fd)
            for device_name in device_names:
                try:
                    handles.append(
                        open_mailbox_at(
                            root_fd,
                            mailbox_root,
                            receiver_name,
                            device_name,
                            root_parent_fd=root_parent_fd,
                            root_name=root_name,
                        )
                    )
                except MailboxFileError:
                    continue
        return tuple(handles)
    except MailboxDiscoveryError:
        _close_handles(handles)
        raise
    except OSError as exc:
        _close_handles(handles)
        raise MailboxDiscoveryError(
            MailboxDiscoveryErrorCode.STORAGE_UNAVAILABLE
        ) from exc
    finally:
        os.close(root_fd)
        os.close(root_parent_fd)


def _production_importer(
    db_path: Path,
    mailbox_path: Path,
    directory: MailboxDirectoryHandle,
) -> MailboxImporterProtocol:
    # Lazy import avoids the receiver package/server/CLI initialization cycle.
    from health_bridge.cli_mailbox import production_importer  # noqa: PLC0415

    return production_importer(db_path, mailbox_path, directory=directory)


def _retryable_errors() -> tuple[type[Exception], ...]:
    # These modules eventually import receiver services. Keep them off the module import
    # path so mailbox QA can import the production importer without a receiver cycle.
    from health_bridge.mailbox.connections import (  # noqa: PLC0415
        MailboxConnectionError,
    )
    from health_bridge.mailbox.filesystem import MailboxFileError  # noqa: PLC0415
    from health_bridge.mailbox.importer import MailboxBusyError  # noqa: PLC0415
    from health_bridge.receiver._mailbox_key_models import (  # noqa: PLC0415
        MailboxKeyStoreError,
    )

    return (
        MailboxBusyError,
        MailboxConnectionError,
        MailboxFileError,
        MailboxKeyStoreError,
        OSError,
        sqlite3.Error,
    )


def _lane_entries_signature(
    directory_fd: int,
) -> tuple[MailboxEntrySignature, ...] | None:
    entries: list[MailboxEntrySignature] = []
    try:
        with os.scandir(directory_fd) as scanned:
            for count, entry in enumerate(scanned, start=1):
                if count > MAX_LANE_SIGNATURE_ENTRIES:
                    return None
                metadata = os.stat(
                    entry.name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                entries.append(
                    (
                        entry.name,
                        metadata.st_dev,
                        metadata.st_ino,
                        metadata.st_mode,
                        metadata.st_nlink,
                        metadata.st_size,
                        metadata.st_mtime_ns,
                        metadata.st_ctime_ns,
                        metadata.st_uid,
                        int(getattr(metadata, "st_flags", 0)),
                    )
                )
    except OSError:
        return None
    entries.sort()
    return tuple(entries)


def _lane_signature(directory: MailboxDirectoryHandle) -> MailboxLaneSignature | None:
    signatures = tuple(
        _lane_entries_signature(directory_fd)
        for directory_fd in (
            directory.deliveries_fd,
            directory.acks_fd,
            directory.quarantine_fd,
        )
    )
    if any(signature is None for signature in signatures):
        return None
    return tuple(signature for signature in signatures if signature is not None)


@final
class MailboxRuntimeWorker:
    def __init__(  # noqa: PLR0913 - explicit bounded worker policy inputs.
        self,
        *,
        db_path: Path,
        mailbox_root: Path,
        importer_factory: MailboxImporterFactory = _production_importer,
        poll_interval_seconds: float = MAILBOX_POLL_INTERVAL_SECONDS,
        max_receiver_entries: int = MAX_RECEIVER_ENTRIES,
        max_device_entries: int = MAX_DEVICE_ENTRIES,
        max_raw_receiver_entries: int = MAX_RAW_RECEIVER_ENTRIES,
        max_raw_device_entries: int = MAX_RAW_DEVICE_ENTRIES,
        shutdown_timeout_seconds: float = MAILBOX_SHUTDOWN_TIMEOUT_SECONDS,
        maintenance_interval_seconds: float = MAILBOX_MAINTENANCE_INTERVAL_SECONDS,
        incomplete_retry_interval_seconds: float = (
            MAILBOX_INCOMPLETE_RETRY_INTERVAL_SECONDS
        ),
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        if (
            poll_interval_seconds <= 0
            or shutdown_timeout_seconds <= 0
            or maintenance_interval_seconds <= 0
            or incomplete_retry_interval_seconds <= 0
        ):
            raise ValueError
        self._db_path = db_path
        self._mailbox_root = mailbox_root
        self._importer_factory = importer_factory
        self._poll_interval_seconds = poll_interval_seconds
        self._max_receiver_entries = max_receiver_entries
        self._max_device_entries = max_device_entries
        self._max_raw_receiver_entries = max_raw_receiver_entries
        self._max_raw_device_entries = max_raw_device_entries
        self._shutdown_timeout_seconds = shutdown_timeout_seconds
        self._maintenance_interval_seconds = maintenance_interval_seconds
        self._incomplete_retry_interval_seconds = incomplete_retry_interval_seconds
        self._monotonic = monotonic
        self._stop = Event()
        self._lifecycle_lock = Lock()
        self._thread: Thread | None = None
        self._last_discovery_error: str | None = None
        self._terminal_error: str | None = None
        self._idle_signatures: dict[Path, tuple[MailboxLaneSignature, float]] = {}

    def run_once(self) -> None:
        directories = _discover_mailbox_handles(
            self._mailbox_root,
            max_receiver_entries=self._max_receiver_entries,
            max_device_entries=self._max_device_entries,
            max_raw_receiver_entries=self._max_raw_receiver_entries,
            max_raw_device_entries=self._max_raw_device_entries,
        )
        seen: set[Path] = set()
        try:
            for directory in directories:
                seen.add(directory.path)
                try:
                    with directory:
                        directory.validate_attached()
                        before = _lane_signature(directory)
                        cached = self._idle_signatures.get(directory.path)
                        now = self._monotonic()
                        if (
                            before is not None
                            and cached is not None
                            and cached[0] == before
                            and now < cached[1]
                        ):
                            directory.validate_attached()
                            continue
                        importer = self._importer_factory(
                            self._db_path, directory.path, directory
                        )
                        directory.validate_attached()
                        result = importer.import_once()
                        directory.validate_attached()
                        after = _lane_signature(directory)
                        if before is not None and before == after:
                            complete = (
                                result.retryable == 0
                                and result.skipped == 0
                                and result.conflict == 0
                            )
                            retry_interval = (
                                self._maintenance_interval_seconds
                                if complete
                                else self._incomplete_retry_interval_seconds
                            )
                            self._idle_signatures[directory.path] = (
                                before,
                                self._monotonic() + retry_interval,
                            )
                        else:
                            _ = self._idle_signatures.pop(directory.path, None)
                except MailboxFileError as exc:
                    _ = self._idle_signatures.pop(directory.path, None)
                    if exc.code is MailboxFileErrorCode.PATH_REPLACED:
                        raise MailboxDiscoveryError(
                            MailboxDiscoveryErrorCode.NAMESPACE_DETACHED
                        ) from exc
                    continue
                except _retryable_errors():
                    _ = self._idle_signatures.pop(directory.path, None)
                    continue
        finally:
            self._idle_signatures = {
                path: value
                for path, value in self._idle_signatures.items()
                if path in seen
            }
            _close_handles(directories)

    def start(self) -> None:
        with self._lifecycle_lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
            self._thread = Thread(
                target=self._run,
                name="health-bridge-mailbox-importer",
                daemon=True,
            )
            self._thread.start()

    def stop(self) -> bool:
        with self._lifecycle_lock:
            thread = self._thread
            self._stop.set()
        if thread is not None:
            thread.join(timeout=self._shutdown_timeout_seconds)
            if thread.is_alive():
                return False
        with self._lifecycle_lock:
            if self._thread is thread:
                self._thread = None
        with self._lifecycle_lock:
            return self._terminal_error is None

    def is_alive(self) -> bool:
        with self._lifecycle_lock:
            return self._thread is not None and self._thread.is_alive()

    def discovery_error(self) -> str | None:
        with self._lifecycle_lock:
            return self._last_discovery_error

    def health_error(self) -> str | None:
        with self._lifecycle_lock:
            return self._terminal_error or self._last_discovery_error

    def terminal_error(self) -> bool:
        with self._lifecycle_lock:
            return self._terminal_error is not None

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.run_once()
            except MailboxDiscoveryError as exc:
                with self._lifecycle_lock:
                    self._last_discovery_error = str(exc)
            except Exception:  # noqa: BLE001 - fixed terminal state, no details escape.
                with self._lifecycle_lock:
                    self._terminal_error = "mailbox_worker_terminal_error"
                return
            else:
                with self._lifecycle_lock:
                    self._last_discovery_error = None
            if self._stop.wait(self._poll_interval_seconds):
                return

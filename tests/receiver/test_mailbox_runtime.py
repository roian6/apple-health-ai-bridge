from __future__ import annotations

import json
import os
import sqlite3
import time
from threading import Event, Thread
from typing import TYPE_CHECKING, Self, cast, final
from urllib.error import HTTPError
from urllib.request import urlopen

import pytest

import health_bridge.receiver.mailbox_runtime as runtime_module
import health_bridge.receiver.server as server_module
from health_bridge.mailbox.models import MailboxImportResult
from tests.mailbox.importer_support import (
    configured_importer,
    database_counts,
    environment,
    opened_receipt,
    write_delivery,
)

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

    from health_bridge.mailbox.filesystem import MailboxDirectoryHandle


RECEIVER_ID = "02" * 16
DEVICE_ID = "03" * 16
SECOND_DEVICE_ID = "04" * 16


@final
class _RecordingImporter:
    def __init__(
        self,
        mailbox: Path,
        calls: list[Path],
        *,
        error: OSError | None = None,
    ) -> None:
        self._mailbox = mailbox
        self._calls = calls
        self._error = error

    def import_once(self) -> MailboxImportResult:
        self._calls.append(self._mailbox)
        if self._error is not None:
            raise self._error
        return MailboxImportResult(imported=1)


def _mailbox(root: Path, device_id: str = DEVICE_ID) -> Path:
    mailbox = root / RECEIVER_ID / device_id
    for lane in ("deliveries", "acks", "quarantine"):
        (mailbox / lane).mkdir(parents=True, exist_ok=True)
    return mailbox


def test_mailbox_discovery_is_bounded_and_skips_unsafe_unknown_entries(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    first = _mailbox(root)
    second = _mailbox(root, SECOND_DEVICE_ID)
    _ = (root / "unknown-receiver").mkdir()
    _ = (root / RECEIVER_ID / "unknown-device").mkdir()
    _ = (root / RECEIVER_ID / ("05" * 16)).write_text("not-a-directory")
    (root / ("06" * 16)).symlink_to(root / RECEIVER_ID, target_is_directory=True)
    (root / RECEIVER_ID / ("07" * 16)).symlink_to(
        first,
        target_is_directory=True,
    )

    discovered = runtime_module.discover_mailboxes(
        root,
        max_receiver_entries=10,
        max_device_entries=10,
    )

    assert discovered == (first, second)
    assert (
        len(
            runtime_module.discover_mailboxes(
                root,
                max_receiver_entries=1,
                max_device_entries=1,
            )
        )
        <= 1
    )


def test_unknown_entries_do_not_starve_valid_mailbox_within_raw_budget(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    root.mkdir()
    for index in range(3):
        (root / f"unknown-{index}").mkdir()
    mailbox = _mailbox(root)

    assert runtime_module.discover_mailboxes(
        root,
        max_receiver_entries=1,
        max_device_entries=1,
        max_raw_receiver_entries=4,
        max_raw_device_entries=2,
    ) == (mailbox,)


def test_raw_discovery_budget_overflow_is_explicit_and_privacy_safe(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    root.mkdir()
    for index in range(3):
        (root / f"unknown-{index}").mkdir()

    with pytest.raises(runtime_module.MailboxDiscoveryError) as raised:
        _ = runtime_module.discover_mailboxes(
            root,
            max_receiver_entries=1,
            max_device_entries=1,
            max_raw_receiver_entries=2,
            max_raw_device_entries=2,
        )

    assert str(raised.value) == "mailbox_discovery_raw_budget_exceeded"


def test_runtime_retries_errors_and_discovers_newly_paired_devices(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    root.mkdir()
    calls: list[Path] = []
    failed: set[Path] = set()

    def importer_factory(
        _db: Path,
        mailbox: Path,
        _directory: MailboxDirectoryHandle,
    ) -> _RecordingImporter:
        error = None
        if mailbox not in failed:
            failed.add(mailbox)
            error = OSError("synthetic retryable failure")
        return _RecordingImporter(mailbox, calls, error=error)

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=importer_factory,
        poll_interval_seconds=0.01,
    )

    worker.run_once()
    first = _mailbox(root)
    worker.run_once()
    worker.run_once()
    second = _mailbox(root, SECOND_DEVICE_ID)
    worker.run_once()
    worker.run_once()

    assert calls.count(first) == 2
    assert calls.count(second) == 2


def test_runtime_skips_unchanged_mailbox_until_lane_changes(tmp_path: Path) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    calls: list[Path] = []

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, path, _directory: _RecordingImporter(path, calls),
    )

    worker.run_once()
    worker.run_once()
    _ = (mailbox / "deliveries" / ("01" * 16 + ".hbd")).write_bytes(b"new")
    worker.run_once()
    worker.run_once()

    assert calls == [mailbox, mailbox]


def test_runtime_ack_deletion_invalidates_idle_gate(tmp_path: Path) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    ack = mailbox / "acks" / ("01" * 16 + ".hba")
    _ = ack.write_bytes(b"ack")
    calls: list[Path] = []

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, path, _directory: _RecordingImporter(path, calls),
    )
    worker.run_once()
    worker.run_once()
    ack.unlink()
    worker.run_once()

    assert calls == [mailbox, mailbox]


def test_runtime_same_size_in_place_rewrite_invalidates_idle_gate(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    delivery = mailbox / "deliveries" / ("01" * 16 + ".hbd")
    _ = delivery.write_bytes(b"first")
    calls: list[Path] = []

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, path, _directory: _RecordingImporter(path, calls),
    )
    worker.run_once()
    worker.run_once()
    _ = delivery.write_bytes(b"other")
    worker.run_once()

    assert calls == [mailbox, mailbox]


def test_lane_signature_changes_when_dataless_flag_changes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    _ = (mailbox / "deliveries" / ("01" * 16 + ".hbd")).write_bytes(b"payload")
    calls: list[Path] = []
    original_stat = os.stat
    flags = 0x40000000

    @final
    class StatWithFlags:
        def __init__(self, metadata: object) -> None:
            self._metadata: object = metadata
            self.st_flags: int = flags

        def __getattr__(self, name: str) -> object:
            return cast("object", getattr(self._metadata, name))

    def stat_with_flags(*args: object, **kwargs: object) -> StatWithFlags:
        return StatWithFlags(
            original_stat(*args, **kwargs)  # pyright: ignore[reportArgumentType]
        )

    monkeypatch.setattr(os, "stat", stat_with_flags)

    class IncompleteImporter:
        def import_once(self) -> MailboxImportResult:
            calls.append(mailbox)
            return MailboxImportResult(retryable=1)

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, _path, _directory: IncompleteImporter(),
        incomplete_retry_interval_seconds=30,
    )
    worker.run_once()
    worker.run_once()
    flags = 0
    worker.run_once()

    assert calls == [mailbox, mailbox]


def test_runtime_backs_off_unchanged_incomplete_result(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    calls: list[Path] = []
    now = 10.0

    class IncompleteImporter:
        def import_once(self) -> MailboxImportResult:
            calls.append(mailbox)
            return MailboxImportResult(retryable=1, skipped=1, conflict=1)

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, _path, _directory: IncompleteImporter(),
        incomplete_retry_interval_seconds=30,
        monotonic=lambda: now,
    )
    worker.run_once()
    worker.run_once()
    now += 29
    worker.run_once()
    now += 1
    worker.run_once()

    assert calls == [mailbox, mailbox]


def test_runtime_incomplete_backoff_starts_after_import_finishes(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    calls: list[Path] = []
    now = 10.0

    class SlowIncompleteImporter:
        def import_once(self) -> MailboxImportResult:
            nonlocal now
            calls.append(mailbox)
            now += 40
            return MailboxImportResult(retryable=1)

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, _path, _directory: SlowIncompleteImporter(),
        incomplete_retry_interval_seconds=30,
        monotonic=lambda: now,
    )
    worker.run_once()
    worker.run_once()

    assert calls == [mailbox]


def test_runtime_lane_mutation_bypasses_incomplete_result_backoff(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    calls: list[Path] = []

    class IncompleteImporter:
        def import_once(self) -> MailboxImportResult:
            calls.append(mailbox)
            return MailboxImportResult(retryable=1)

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, _path, _directory: IncompleteImporter(),
        incomplete_retry_interval_seconds=30,
    )
    worker.run_once()
    worker.run_once()
    _ = (mailbox / "deliveries" / ("03" * 16 + ".hbd")).write_bytes(b"new")
    worker.run_once()

    assert calls == [mailbox, mailbox]


def test_runtime_retries_when_lane_changes_during_import(tmp_path: Path) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    calls: list[Path] = []
    mutated = False

    class MutatingImporter:
        def import_once(self) -> MailboxImportResult:
            nonlocal mutated
            calls.append(mailbox)
            if not mutated:
                mutated = True
                _ = (mailbox / "acks" / ("02" * 16 + ".hba")).write_bytes(b"ack")
            return MailboxImportResult(imported=1)

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, _path, _directory: MutatingImporter(),
    )
    worker.run_once()
    worker.run_once()
    worker.run_once()

    assert calls == [mailbox, mailbox]


def test_runtime_periodically_rechecks_unchanged_mailbox(tmp_path: Path) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    calls: list[Path] = []
    now = 10.0

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, path, _directory: _RecordingImporter(path, calls),
        maintenance_interval_seconds=300,
        monotonic=lambda: now,
    )
    worker.run_once()
    worker.run_once()
    now += 301
    worker.run_once()

    assert calls == [mailbox, mailbox]


def test_runtime_worker_stops_promptly_after_background_start(tmp_path: Path) -> None:
    root = tmp_path / "mailboxes"
    _ = _mailbox(root)
    called = Event()

    class SignallingImporter:
        def import_once(self) -> MailboxImportResult:
            called.set()
            return MailboxImportResult()

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, _mailbox_path, _directory: SignallingImporter(),
        poll_interval_seconds=30,
    )

    worker.start()
    assert called.wait(timeout=2)
    _ = worker.stop()

    assert not worker.is_alive()


def test_runtime_worker_shutdown_is_bounded_and_reports_blocked_importer(
    tmp_path: Path,
) -> None:
    root = tmp_path / "mailboxes"
    _ = _mailbox(root)
    entered = Event()
    release = Event()

    class BlockedImporter:
        def import_once(self) -> MailboxImportResult:
            entered.set()
            _ = release.wait()
            return MailboxImportResult()

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=lambda _db, _mailbox_path, _handle: BlockedImporter(),
        poll_interval_seconds=30,
        shutdown_timeout_seconds=0.05,
    )
    worker.start()
    assert entered.wait(timeout=2)

    started = time.monotonic()
    stopped = worker.stop()
    elapsed = time.monotonic() - started

    assert stopped is False
    assert elapsed < 0.5
    assert worker.is_alive()
    release.set()
    assert worker.stop() is True
    assert not worker.is_alive()


def test_runtime_delivery_commits_to_database_before_publishing_ack(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)
    expected_ack = configured_importer(value).expected_ack_path(delivery)

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=value.db_path,
        mailbox_root=tmp_path,
        importer_factory=lambda db, mailbox, _directory: _validated_fixture_importer(
            db,
            mailbox,
            value.db_path,
            value.mailbox_path,
            lambda: configured_importer(value),
        ),
    )
    worker.run_once()

    assert database_counts(value) == (1, 1, 1)
    assert expected_ack.is_file()
    assert opened_receipt(expected_ack).result == "committed"


@pytest.mark.parametrize(
    "replace_level",
    ["root", "receiver", "device", "deliveries", "acks", "quarantine"],
)
def test_runtime_rejects_mailbox_identity_replacement_without_external_write(
    tmp_path: Path,
    replace_level: str,
) -> None:
    root = tmp_path / "mailboxes"
    mailbox = _mailbox(root)
    external = tmp_path / "external"
    external_mailbox = _mailbox(external)
    factory_called = Event()

    class ForbiddenImporter:
        def import_once(self) -> MailboxImportResult:
            pytest.fail("replaced mailbox must not reach database acceptance")

    def replacing_factory(
        _db: Path,
        _mailbox_path: Path,
        _directory: MailboxDirectoryHandle,
    ) -> ForbiddenImporter:
        factory_called.set()
        if replace_level == "root":
            _ = root.rename(tmp_path / "detached-root")
            _ = root.symlink_to(external, target_is_directory=True)
        elif replace_level == "receiver":
            receiver = mailbox.parent
            _ = receiver.rename(root / "detached-receiver")
            _ = receiver.symlink_to(external_mailbox.parent, target_is_directory=True)
        elif replace_level == "device":
            _ = mailbox.rename(mailbox.parent / "detached-device")
            _ = mailbox.symlink_to(external_mailbox, target_is_directory=True)
        else:
            lane = mailbox / replace_level
            _ = lane.rename(mailbox / f"detached-{replace_level}")
            _ = lane.symlink_to(
                external_mailbox / replace_level,
                target_is_directory=True,
            )
        return ForbiddenImporter()

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=replacing_factory,
    )
    with pytest.raises(
        runtime_module.MailboxDiscoveryError,
        match=r"^mailbox_namespace_detached$",
    ):
        worker.run_once()

    assert factory_called.is_set()
    assert not (tmp_path / "receiver.sqlite").exists()
    assert list((external_mailbox / "acks").iterdir()) == []
    assert list((external_mailbox / "quarantine").iterdir()) == []


@pytest.mark.parametrize(
    ("failure", "expected_code", "expected_status"),
    [
        ("raw-budget", "mailbox_discovery_raw_budget_exceeded", 503),
        ("missing-root", "mailbox_discovery_root_unavailable", 503),
        ("terminal", "mailbox_worker_terminal_error", 500),
    ],
)
def test_mailbox_worker_failure_makes_server_health_non_ok(
    tmp_path: Path,
    failure: str,
    expected_code: str,
    expected_status: int,
) -> None:
    root = tmp_path / "mailboxes"
    calls: list[Path] = []

    def recording_factory(
        _db: Path,
        mailbox: Path,
        _directory: MailboxDirectoryHandle,
    ) -> _RecordingImporter:
        return _RecordingImporter(mailbox, calls)

    importer_factory: runtime_module.MailboxImporterFactory = recording_factory

    max_raw_receiver_entries = runtime_module.MAX_RAW_RECEIVER_ENTRIES
    if failure == "raw-budget":
        root.mkdir()
        for index in range(3):
            (root / f"unknown-{index}").mkdir()
        max_raw_receiver_entries = 2
    elif failure == "terminal":
        _ = _mailbox(root)

        def terminal_factory(
            _db: Path,
            _mailbox_path: Path,
            _directory: MailboxDirectoryHandle,
        ) -> _RecordingImporter:
            message = "synthetic programmer defect"
            raise ValueError(message)

        importer_factory = terminal_factory

    worker = runtime_module.MailboxRuntimeWorker(
        db_path=tmp_path / "receiver.sqlite",
        mailbox_root=root,
        importer_factory=importer_factory,
        poll_interval_seconds=0.01,
        max_raw_receiver_entries=max_raw_receiver_entries,
    )
    server = server_module.ReceiverHTTPServer(
        "127.0.0.1",
        0,
        tmp_path / "receiver.sqlite",
        mailbox_worker=worker,
    )
    server_thread = Thread(target=server.serve_forever, daemon=True)
    worker.start()
    server_thread.start()
    try:
        deadline = time.monotonic() + 2
        while worker.health_error() != expected_code and time.monotonic() < deadline:
            time.sleep(0.01)
        with pytest.raises(HTTPError) as raised:
            urlopen(
                f"http://127.0.0.1:{server_module.server_port(server)}/health",
                timeout=2,
            )
        body = cast("dict[str, str]", json.loads(raised.value.read()))
        raised.value.close()
        assert raised.value.code == expected_status
        assert body["status"] != "ok"
        assert body["error"] == expected_code
        assert worker.stop() is (failure != "terminal")
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)


def _validated_fixture_importer(
    db: Path,
    mailbox: Path,
    expected_db: Path,
    expected_mailbox: Path,
    factory: Callable[[], runtime_module.MailboxImporterProtocol],
) -> runtime_module.MailboxImporterProtocol:
    assert db == expected_db
    assert mailbox == expected_mailbox
    return factory()


def test_serve_receiver_owns_mailbox_worker_lifecycle(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[str] = []

    class FakeWorker:
        def __init__(self, *, db_path: Path, mailbox_root: Path) -> None:
            assert db_path == tmp_path / "receiver.sqlite"
            assert mailbox_root == tmp_path / "mailboxes"

        def start(self) -> None:
            events.append("worker-start")

        def stop(self) -> None:
            events.append("worker-stop")

    class FakeServer:
        def __init__(self, **_kwargs: object) -> None:
            pass

        def __enter__(self) -> Self:
            events.append("server-enter")
            return self

        def __exit__(self, *_args: object) -> None:
            events.append("server-exit")

        def serve_forever(self) -> None:
            events.append("serve")

    monkeypatch.setattr(server_module, "MailboxRuntimeWorker", FakeWorker)
    monkeypatch.setattr(server_module, "ReceiverHTTPServer", FakeServer)

    server_module.serve_receiver(
        tmp_path / "receiver.sqlite",
        "127.0.0.1",
        0,
        mailbox_root=tmp_path / "mailboxes",
    )

    assert events == [
        "server-enter",
        "worker-start",
        "serve",
        "worker-stop",
        "server-exit",
    ]


def test_direct_serve_receiver_never_starts_mailbox_worker(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class ForbiddenWorker:
        def __init__(self, **_kwargs: object) -> None:
            pytest.fail("direct receiver must not construct mailbox worker")

    class FakeServer:
        def __init__(self, **_kwargs: object) -> None:
            pass

        def __enter__(self) -> Self:
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def serve_forever(self) -> None:
            return None

    monkeypatch.setattr(server_module, "MailboxRuntimeWorker", ForbiddenWorker)
    monkeypatch.setattr(server_module, "ReceiverHTTPServer", FakeServer)

    server_module.serve_receiver(tmp_path / "receiver.sqlite", "127.0.0.1", 0)

    with sqlite3.connect(tmp_path / "receiver.sqlite") as connection:
        assert connection.execute("SELECT 1").fetchone() == (1,)

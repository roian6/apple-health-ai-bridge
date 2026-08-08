from __future__ import annotations

import os
import sqlite3
from dataclasses import dataclass
from typing import TYPE_CHECKING, Final

from typer.testing import CliRunner

from health_bridge.cli import app
from health_bridge.mailbox.filesystem import scan_delivery_lane
from health_bridge.mailbox.importer import MailboxImportConfig, MailboxImporter
from health_bridge.mailbox.publication import cleanup_quarantine
from health_bridge.storage.database import initialize_database
from health_bridge.storage.sqlite_rows import fetch_one_int
from tests.contract.delivery_v1_support import BATCH
from tests.receiver.delivery_acceptance_support import (
    NOW_MS,
    RequestSpec,
    alternate_batch,
    connection,
    envelope,
)
from tests.receiver.delivery_acceptance_support import (
    opened_receipt as open_ack,
)

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

    import pytest
    from typer.testing import Result

    from health_bridge.contract import delivery_v1 as delivery
    from health_bridge.mailbox.filesystem import DeliveryScan
    from health_bridge.mailbox.models import (
        MailboxImportFaultHook,
        MailboxImportFaultPoint,
        MailboxImportResult,
    )

DAY_MS: Final = 86_400_000
DELIVERY_ID: Final = "01" * 16
IMPORTED_COUNTS: Final = {
    "conflict": 0,
    "idempotent": 0,
    "imported": 1,
    "quarantined": 0,
    "retryable": 0,
    "skipped": 0,
}
INVALID_PAYLOADS: Final = (
    b"\xff",
    b'{"schema_id":',
    BATCH + b" trailing",
    BATCH.replace(
        b'{"deleted_records":[]',
        b'{"schema_id":"health_bridge.batch.v1","deleted_records":[]',
    ),
    BATCH.replace(
        b'{"end_time":"2026-06-09T00:00:00Z","start_time"',
        b"".join(
            (
                b'{"end_time":"2026-06-09T00:00:00Z",',
                b'"end_time":"2026-06-09T00:00:00Z","start_time"',
            )
        ),
        1,
    ),
    BATCH.replace(
        b'{"client_record_id":"synthetic-sample-1"',
        b'{"unit":"count","client_record_id":"synthetic-sample-1"',
        1,
    ),
    BATCH.replace(b'"value":1.25', b'"value":NaN'),
    BATCH.replace(b'"value":1.25', b'"value":Infinity'),
    BATCH.replace(b'"value":1.25', b'"value":-Infinity'),
)


@dataclass(frozen=True, slots=True)
class ImportEnvironment:
    db_path: Path
    mailbox_path: Path
    deliveries: Path
    acks: Path
    quarantine: Path
    lock_path: Path


def environment(tmp_path: Path) -> ImportEnvironment:
    mailbox = tmp_path / ("02" * 16) / ("03" * 16)
    deliveries = mailbox / "deliveries"
    acks = mailbox / "acks"
    quarantine = mailbox / "quarantine"
    for lane in (deliveries, acks, quarantine):
        lane.mkdir(parents=True, exist_ok=True)
    db_path = tmp_path / "health.sqlite"
    initialize_database(db_path)
    return ImportEnvironment(
        db_path=db_path,
        mailbox_path=mailbox,
        deliveries=deliveries,
        acks=acks,
        quarantine=quarantine,
        lock_path=tmp_path / "mailbox-import.lock",
    )


def write_delivery(
    value: ImportEnvironment,
    *,
    payload: bytes = BATCH,
    envelope_byte: int = 1,
) -> Path:
    path = value.deliveries / f"{f'{envelope_byte:02x}' * 16}.hbd"
    _ = path.write_bytes(
        envelope(RequestSpec(payload=payload, envelope_byte=envelope_byte))
    )
    return path


def configured_importer(
    value: ImportEnvironment,
    *,
    now_ms: int = NOW_MS,
    path_replacement_retry_limit: int = 0,
) -> MailboxImporter:
    return MailboxImporter(
        MailboxImportConfig(
            db_path=value.db_path,
            mailbox_path=value.mailbox_path,
            lock_path=value.lock_path,
            connection=connection(),
            clock_ms=lambda: now_ms,
            path_replacement_retry_limit=path_replacement_retry_limit,
        )
    )


def import_once(
    value: ImportEnvironment,
    *,
    now_ms: int = NOW_MS,
    fault_hook: MailboxImportFaultHook | None = None,
) -> MailboxImportResult:
    return configured_importer(value, now_ms=now_ms).import_once(fault_hook=fault_hook)


def database_counts(value: ImportEnvironment) -> tuple[int, int, int]:
    with sqlite3.connect(value.db_path) as database:
        return (
            fetch_one_int(database, "select count(*) from samples"),
            fetch_one_int(database, "select count(*) from sync_runs"),
            fetch_one_int(database, "select count(*) from delivery_receipts"),
        )


def ack_is_deterministic(value: ImportEnvironment, ack_path: Path) -> bool:
    before = ack_path.read_bytes()
    replay = import_once(value)
    return replay.idempotent == 1 and ack_path.read_bytes() == before


def opened_receipt(
    ack_path: Path,
    *,
    envelope_byte: int = 1,
) -> delivery.DeliveryReceiptV1:
    return open_ack(ack_path.read_bytes(), envelope_byte=envelope_byte)


def age(path: Path, *, now_ms: int, elapsed_ms: int) -> None:
    timestamp = (now_ms - elapsed_ms) / 1000
    os.utime(path, (timestamp, timestamp), follow_symlinks=False)


def fault_at(
    target: MailboxImportFaultPoint,
    action: Callable[[], None] | None = None,
) -> MailboxImportFaultHook:
    def inject(point: MailboxImportFaultPoint) -> None:
        if point == target:
            if action is not None:
                action()
            raise RuntimeError(point.value)

    return inject


def invoke_import_cli(
    value: ImportEnvironment,
    importer: MailboxImporter,
    monkeypatch: pytest.MonkeyPatch,
) -> Result:
    def use_importer(_db: Path, _mailbox: Path) -> MailboxImporter:
        return importer

    monkeypatch.setattr(
        "health_bridge.cli_mailbox.production_importer",
        use_importer,
    )
    return CliRunner().invoke(
        app,
        [
            "mailbox",
            "import",
            "--db",
            str(value.db_path),
            "--mailbox",
            str(value.mailbox_path),
            "--once",
            "--json",
        ],
    )


def populate_scan_and_quarantine_caps(value: ImportEnvironment) -> None:
    for index in range(10_001):
        _ = (value.deliveries / f"{index:032x}.hbd").touch()
    for index in range(1_001):
        marker = value.quarantine / f"{index:032x}.hbq"
        _ = marker.write_bytes(b"{}")
        os.utime(marker, (index + 1, index + 1))


def scan_size_cap(path: Path) -> DeliveryScan:
    path.mkdir()
    for index in range(1_025):
        entry = path / f"{index:032x}.hbd"
        _ = entry.touch()
        os.truncate(entry, 2 * 1024 * 1024)
    return scan_delivery_lane(path)


def quarantine_byte_and_age_caps(path: Path) -> bool:
    path.mkdir()
    now_ms = 4_000_000_000
    for index in range(2):
        marker = path / f"{index:032x}.hbq"
        _ = marker.touch()
        os.truncate(marker, 33 * 1024 * 1024)
        timestamp = now_ms / 1000 - (2 - index)
        os.utime(marker, (timestamp, timestamp))
    cleanup_quarantine(path, now_ms=now_ms)
    byte_cap_holds = len(list(path.glob("*.hbq"))) == 1
    old = path / f"{2:032x}.hbq"
    _ = old.touch()
    timestamp = (now_ms - 30 * DAY_MS) / 1000
    os.utime(old, (timestamp, timestamp))
    cleanup_quarantine(path, now_ms=now_ms)
    return byte_cap_holds and not old.exists()


__all__ = [
    "BATCH",
    "DAY_MS",
    "DELIVERY_ID",
    "IMPORTED_COUNTS",
    "INVALID_PAYLOADS",
    "ImportEnvironment",
    "ack_is_deterministic",
    "age",
    "alternate_batch",
    "configured_importer",
    "database_counts",
    "environment",
    "fault_at",
    "import_once",
    "invoke_import_cli",
    "opened_receipt",
    "populate_scan_and_quarantine_caps",
    "quarantine_byte_and_age_caps",
    "scan_size_cap",
    "write_delivery",
]

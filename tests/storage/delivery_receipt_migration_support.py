import multiprocessing
import sqlite3
from multiprocessing.synchronize import Barrier as ProcessBarrier
from pathlib import Path
from threading import BrokenBarrierError

from health_bridge.storage.database import initialize_database

LEGACY_MIGRATION_IDS = (
    "001_initial",
    "002_sync_window",
    "003_receiver_tokens",
    "004_pairing_invitations",
    "005_pairing_devices",
    "006_sleep_session_revisions",
    "007_sleep_baseline_namespaces",
)
EXPECTED_RECEIPT_COLUMNS = {
    "delivery_receipt_row_id",
    "receipt_id",
    "envelope_id",
    "payload_sha256",
    "receiver_id",
    "device_id",
    "receiver_agreement_key_id",
    "sender_signing_key_id",
    "device_agreement_key_id",
    "receiver_signing_key_id",
    "opaque_binding",
    "connection_generation",
    "result",
    "committed_sync_run_id",
    "ack_id",
    "dataset_generation",
    "committed_at_ms",
    "error_code",
}
PROHIBITED_RECEIPT_COLUMN_PARTS = {
    "ciphertext",
    "plaintext",
    "payload_json",
    "batch",
    "ack_body",
    "nonce",
    "signature",
    "bearer",
    "token",
    "private",
    "health_value",
    "cursor",
    "locator",
    "path",
}


def create_legacy_database(db_path: Path) -> None:
    migration_dir = Path("src/health_bridge/storage/migrations")
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute("pragma foreign_keys = on")
        for migration_id in LEGACY_MIGRATION_IDS:
            _ = connection.executescript(
                (migration_dir / f"{migration_id}.sql").read_text(encoding="utf-8")
            )
            _ = connection.execute(
                "insert into schema_migrations (migration_id) values (?)",
                (migration_id,),
            )
        _ = connection.execute(
            "insert into sources (source_key, name, kind) values (?, ?, ?)",
            ("synthetic.source", "Synthetic Source", "phone"),
        )
        insert_sync_run_sql = (
            "insert into sync_runs (started_at, finished_at, status, "
            "fixture_name, source_count) values (?, ?, ?, ?, ?)"
        )
        _ = connection.execute(
            insert_sync_run_sql,
            (
                "2026-07-21T00:00:00Z",
                "2026-07-21T00:00:00Z",
                "succeeded",
                "synthetic-v7.json",
                1,
            ),
        )


def process_upgrade_worker(
    db_path: Path,
    barrier: ProcessBarrier,
) -> None:
    try:
        _ = barrier.wait(timeout=15)
    except BrokenBarrierError:
        raise SystemExit(2) from None
    initialize_database(db_path)


def run_concurrent_process_upgrades(db_path: Path, worker_count: int = 4) -> None:
    context = multiprocessing.get_context("spawn")
    barrier = context.Barrier(worker_count)
    workers = [
        context.Process(target=process_upgrade_worker, args=(db_path, barrier))
        for _ in range(worker_count)
    ]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join(timeout=30)
        if worker.is_alive():
            worker.terminate()
            worker.join(timeout=5)
            message = "concurrent migration worker did not exit"
            raise RuntimeError(message)
        if worker.exitcode != 0:
            message = f"concurrent migration worker exited {worker.exitcode}"
            raise RuntimeError(message)

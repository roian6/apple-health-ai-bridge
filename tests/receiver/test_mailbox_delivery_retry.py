from __future__ import annotations

import os
import stat
from typing import TYPE_CHECKING

import pytest

import health_bridge.mailbox.importer as importer_module
from health_bridge.mailbox.filesystem import revalidate_final_at
from health_bridge.mailbox.importer import MailboxImportConfig, MailboxImporter
from health_bridge.mailbox.publication import PublicationState, publish_quarantine
from health_bridge.receiver.mailbox_runtime import MailboxRuntimeWorker
from tests.mailbox.importer_support import (
    database_counts,
    environment,
    opened_receipt,
    write_delivery,
)
from tests.receiver.delivery_acceptance_support import (
    NOW_MS,
    alternate_batch,
    connection,
)

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.mailbox.filesystem import FileIdentity, MailboxDirectoryHandle


def test_runtime_retries_unstable_delivery_with_unchanged_lane_after_thirty_seconds(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    value = environment(tmp_path)
    unstable_delivery = write_delivery(value)
    next_delivery = write_delivery(value, payload=alternate_batch(), envelope_byte=2)
    assert (
        publish_quarantine(value.quarantine, unstable_delivery.name, "path_replaced")
        is PublicationState.CREATED
    )
    marker = next(value.quarantine.iterdir())
    marker_before = marker.stat()
    unstable_ack = value.acks / unstable_delivery.with_suffix(".hba").name
    next_ack = value.acks / next_delivery.with_suffix(".hba").name
    denied = 0
    unstable = True
    now = 0.0

    def revalidate(directory_fd: int, name: str, identity: FileIdentity) -> bool:
        nonlocal denied
        if not unstable or name != unstable_delivery.name:
            return revalidate_final_at(directory_fd, name, identity)
        # Make the real relative stat fail without changing a delivery entry.
        mode = stat.S_IMODE(os.fstat(directory_fd).st_mode)
        os.fchmod(directory_fd, 0)
        try:
            with pytest.raises(PermissionError):
                _ = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            denied += 1
            return revalidate_final_at(directory_fd, name, identity)
        finally:
            os.fchmod(directory_fd, mode)

    def importer(
        db: Path, mailbox: Path, directory: MailboxDirectoryHandle
    ) -> MailboxImporter:
        return MailboxImporter(
            MailboxImportConfig(
                db_path=db,
                mailbox_path=mailbox,
                lock_path=value.lock_path,
                connection=connection(),
                clock_ms=lambda: NOW_MS,
                directory=directory,
            )
        )

    monkeypatch.setattr(importer_module, "revalidate_final_at", revalidate)
    worker = MailboxRuntimeWorker(
        db_path=value.db_path,
        mailbox_root=tmp_path,
        importer_factory=importer,
        capability_publisher=lambda _directory: None,
        monotonic=lambda: now,
    )

    worker.run_once()
    assert not unstable_ack.exists()
    assert opened_receipt(next_ack, envelope_byte=2).result == "committed"
    assert database_counts(value)[2] == 1
    worker.run_once()  # The first pass published the other delivery's ACK.
    assert denied == 2
    assert not unstable_ack.exists()
    assert database_counts(value)[2] == 1
    marker_after = marker.stat()
    assert (
        marker_after.st_ino,
        marker_after.st_mtime_ns,
        marker_after.st_ctime_ns,
    ) == (
        marker_before.st_ino,
        marker_before.st_mtime_ns,
        marker_before.st_ctime_ns,
    )

    unstable = False
    first_ack_at = None
    for now in (29.0, 30.0, 299.0, 300.0):
        worker.run_once()
        if unstable_ack.exists():
            first_ack_at = now
            break

    assert opened_receipt(unstable_ack).result == "committed"
    assert database_counts(value)[2] == 2
    assert first_ack_at == 30.0, (
        f"stable delivery first acknowledged at t={first_ack_at}s"
    )

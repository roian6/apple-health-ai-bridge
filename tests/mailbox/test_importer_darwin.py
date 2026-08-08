from __future__ import annotations

import errno
import os
import subprocess
import sys
from typing import TYPE_CHECKING, cast

import pytest

from health_bridge.mailbox import publication
from health_bridge.mailbox.filesystem import mailbox_writer_lock
from health_bridge.mailbox.models import MailboxImportFaultPoint
from health_bridge.mailbox.publication import PublicationState, publish_final
from tests.mailbox.importer_support import (
    DAY_MS,
    configured_importer,
    database_counts,
    environment,
    write_delivery,
)

if TYPE_CHECKING:
    from pathlib import Path
    from typing import TextIO

pytestmark = pytest.mark.skipif(
    sys.platform != "darwin", reason="Darwin filesystem gate"
)


def test_darwin_writer_lock_is_exclusive_across_processes(tmp_path: Path) -> None:
    lock_path = tmp_path / "mailbox-import.lock"
    script = (
        "from pathlib import Path\n"
        "import sys\n"
        "from health_bridge.mailbox.filesystem import mailbox_writer_lock\n"
        "with mailbox_writer_lock(Path(sys.argv[1])):\n"
        "    print('LOCKED', flush=True)\n"
        "    sys.stdin.readline()\n"
    )
    process = subprocess.Popen(
        [sys.executable, "-c", script, str(lock_path)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None
    process_stdin = cast("TextIO", process.stdin)
    process_stdout = cast("TextIO", process.stdout)
    process_stderr = cast("TextIO", process.stderr)
    try:
        assert process_stdout.readline().strip() == "LOCKED"
        with pytest.raises(BlockingIOError), mailbox_writer_lock(lock_path):
            pytest.fail("second process acquired the writer lock")
    finally:
        _ = process_stdin.write("release\n")
        process_stdin.flush()
        process_stdin.close()
        assert process.wait(timeout=10) == 0
        process_stdout.close()
        process_stderr.close()


def test_darwin_exclusive_rename_is_idempotent_and_never_clobbers(
    tmp_path: Path,
) -> None:
    assert (
        publish_final(tmp_path, "01" * 16 + ".hba", b"first")
        is PublicationState.CREATED
    )
    assert (
        publish_final(tmp_path, "01" * 16 + ".hba", b"first")
        is PublicationState.IDENTICAL
    )
    assert (
        publish_final(tmp_path, "01" * 16 + ".hba", b"second")
        is PublicationState.CONFLICT
    )
    assert (tmp_path / ("01" * 16 + ".hba")).read_bytes() == b"first"
    assert list(tmp_path.glob("*.tmp")) == []


@pytest.mark.parametrize("unsafe_kind", ["hardlink", "fifo"])
def test_darwin_importer_rejects_hardlink_and_fifo(
    tmp_path: Path,
    unsafe_kind: str,
) -> None:
    value = environment(tmp_path)
    final = value.deliveries / ("01" * 16 + ".hbd")
    if unsafe_kind == "hardlink":
        source = tmp_path / "hardlink-source"
        _ = source.write_bytes(b"synthetic")
        os.link(source, final)
    else:
        os.mkfifo(final)

    result = configured_importer(value).import_once()

    assert result.quarantined == 1
    assert database_counts(value) == (0, 0, 0)
    assert final.exists()


def test_darwin_rename_failure_restarts_after_commit_without_duplicate(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)

    def fail_finalize(*_args: object, **_kwargs: object) -> None:
        raise OSError(errno.ENOSPC, "synthetic final rename failure")

    with monkeypatch.context() as patcher:
        patcher.setattr(publication, "_exclusive_finalize", fail_finalize)
        failed = configured_importer(value).import_once()

    assert failed.retryable == 1
    assert database_counts(value) == (1, 1, 1)
    assert delivery.exists()
    assert list(value.acks.glob("*.hba")) == []
    assert list(value.acks.glob("*.tmp")) == []

    restarted = configured_importer(value).import_once()
    assert restarted.idempotent == 1
    assert database_counts(value) == (1, 1, 1)
    assert len(list(value.acks.glob("*.hba"))) == 1


def test_darwin_fsync_failure_is_best_effort_and_cleanup_race_is_safe(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value)

    def fail_fsync(_descriptor: int) -> None:
        raise OSError(errno.EIO, "synthetic provider fsync failure")

    monkeypatch.setattr(os, "fsync", fail_fsync)
    imported = configured_importer(value).import_once()
    assert imported.imported == 1
    assert len(list(value.acks.glob("*.hba"))) == 1

    stale = value.deliveries / ("02" * 16 + ".hbd." + "03" * 16 + ".tmp")
    _ = stale.write_bytes(b"partial")
    old_ns = (1_784_600_000_123 - DAY_MS) * 1_000_000
    os.utime(stale, ns=(old_ns, old_ns), follow_symlinks=False)
    replacement = tmp_path / "replacement"
    _ = replacement.write_bytes(b"keep")

    def replace_before_cleanup(point: MailboxImportFaultPoint) -> None:
        if point is MailboxImportFaultPoint.BEFORE_CLEANUP_UNLINK:
            stale.unlink()
            stale.symlink_to(replacement)

    _ = configured_importer(value).import_once(replace_before_cleanup)
    assert stale.is_symlink()
    assert replacement.read_bytes() == b"keep"

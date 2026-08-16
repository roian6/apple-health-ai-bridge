from __future__ import annotations

import errno
import hashlib
import os
import sys
from typing import TYPE_CHECKING, Never

import pytest

from health_bridge.mailbox import filesystem as mailbox_files
from health_bridge.mailbox.filesystem import (
    MailboxDirectoryHandle,
    MailboxFileError,
    file_identity,
    open_directory,
    unlink_same_at,
)
from health_bridge.mailbox.importer import (
    MailboxBusyError,
    MailboxImportConfig,
    MailboxImporter,
)
from health_bridge.mailbox.models import MailboxImportFaultPoint
from health_bridge.mailbox.publication import (
    PublicationState,
    cleanup_quarantine,
    publish_final_at,
)
from health_bridge.receiver._delivery_acceptance_crypto import receipt_ack_id
from health_bridge.storage.database import connect_database
from tests.contract.delivery_v1_support import authenticated_oversize_envelope
from tests.mailbox.importer_support import (
    DAY_MS,
    INVALID_PAYLOADS,
    ack_is_deterministic,
    age,
    alternate_batch,
    configured_importer,
    database_counts,
    environment,
    fault_at,
    import_once,
    opened_receipt,
    populate_scan_and_quarantine_caps,
    quarantine_byte_and_age_caps,
    scan_size_cap,
    write_delivery,
)
from tests.receiver.delivery_acceptance_support import NOW_MS, connection

if TYPE_CHECKING:
    from pathlib import Path


def test_imports_exact_plaintext_bytes_and_replays_idempotently(
    tmp_path: Path,
) -> None:
    # Given
    value = environment(tmp_path)
    delivery = write_delivery(value)

    # When
    first = import_once(value)
    second = import_once(value)

    # Then
    assert first.counts() == (1, 0, 0, 0, 0, 0)
    assert second.counts() == (0, 1, 0, 0, 0, 0)
    assert database_counts(value) == (1, 1, 1)
    ack = next(value.acks.glob("*.hba"))
    assert ack_is_deterministic(value, ack)
    assert delivery.exists()


def test_committed_ack_uses_envelope_id_as_final_basename(tmp_path: Path) -> None:
    # Given
    value = environment(tmp_path)
    _ = write_delivery(value, envelope_byte=4)

    # When
    result = import_once(value)

    # Then
    assert result.imported == 1
    assert {path.name for path in value.acks.glob("*.hba")} == {"04" * 16 + ".hba"}


def test_terminal_ack_uses_envelope_id_as_final_basename(tmp_path: Path) -> None:
    # Given
    value = environment(tmp_path)
    _ = write_delivery(value, payload=b"\xff", envelope_byte=5)

    # When
    result = import_once(value)

    # Then
    ack_path = value.acks / ("05" * 16 + ".hba")
    assert result.quarantined == 1
    assert ack_path.is_file()
    assert opened_receipt(ack_path, envelope_byte=5).result == "terminal"
    first_bytes = ack_path.read_bytes()

    replay = import_once(value)

    assert replay.quarantined == 1
    assert replay.conflict == 0
    assert ack_path.read_bytes() == first_bytes
    assert list(value.acks.glob("*.hba")) == [ack_path]


def test_retryable_ack_keeps_ack_id_as_final_basename(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    value = environment(tmp_path)
    _ = write_delivery(value, envelope_byte=6)

    def unavailable(_db_path: Path) -> Never:
        raise OSError

    monkeypatch.setattr(
        "health_bridge.receiver.delivery_acceptance.connect_database",
        unavailable,
    )

    # When
    result = import_once(value)

    # Then
    ack_path = next(value.acks.glob("*.hba"))
    receipt = opened_receipt(ack_path, envelope_byte=6)
    expected_name = receipt_ack_id(receipt, bytes([6]) * 16).hex() + ".hba"
    assert result.retryable == 1
    assert receipt.result == "retryable"
    assert ack_path.name == expected_name


def test_retryable_then_committed_publishes_distinct_envelope_final(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    value = environment(tmp_path)
    _ = write_delivery(value, envelope_byte=7)

    def unavailable(_db_path: Path) -> Never:
        raise OSError

    monkeypatch.setattr(
        "health_bridge.receiver.delivery_acceptance.connect_database",
        unavailable,
    )
    retryable = import_once(value)
    retryable_path = next(value.acks.glob("*.hba"))
    retryable_bytes = retryable_path.read_bytes()
    monkeypatch.setattr(
        "health_bridge.receiver.delivery_acceptance.connect_database",
        connect_database,
    )

    # When
    committed = import_once(value)

    # Then
    committed_path = value.acks / ("07" * 16 + ".hba")
    assert retryable.retryable == 1
    assert committed.imported == 1
    assert committed.conflict == 0
    assert retryable_path.read_bytes() == retryable_bytes
    assert committed_path.is_file()
    assert {path.name for path in value.acks.glob("*.hba")} == {
        retryable_path.name,
        committed_path.name,
    }


def test_duplicate_committed_replay_skips_external_publisher_for_identical_ack(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value, envelope_byte=8)
    calls = 0

    def counting_publisher(
        directory: MailboxDirectoryHandle,
        final_name: str,
        content: bytes,
    ) -> PublicationState:
        nonlocal calls
        calls += 1
        return publish_final_at(directory.acks_fd, final_name, content)

    importer = MailboxImporter(
        MailboxImportConfig(
            db_path=value.db_path,
            mailbox_path=value.mailbox_path,
            lock_path=value.lock_path,
            connection=connection(),
            clock_ms=lambda: NOW_MS,
            ack_publisher=counting_publisher,
        )
    )

    first = importer.import_once()
    replay = importer.import_once()

    assert first.imported == 1
    assert replay.idempotent == 1
    assert replay.conflict == 0
    assert calls == 1


def test_committed_replay_republishes_when_ack_is_missing(tmp_path: Path) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value, envelope_byte=9)
    calls = 0

    def counting_publisher(
        directory: MailboxDirectoryHandle,
        final_name: str,
        content: bytes,
    ) -> PublicationState:
        nonlocal calls
        calls += 1
        return publish_final_at(directory.acks_fd, final_name, content)

    importer = MailboxImporter(
        MailboxImportConfig(
            db_path=value.db_path,
            mailbox_path=value.mailbox_path,
            lock_path=value.lock_path,
            connection=connection(),
            clock_ms=lambda: NOW_MS,
            ack_publisher=counting_publisher,
        )
    )
    _ = importer.import_once()
    next(value.acks.glob("*.hba")).unlink()

    replay = importer.import_once()

    assert replay.idempotent == 1
    assert replay.conflict == 0
    assert calls == 2
    assert len(list(value.acks.glob("*.hba"))) == 1


def test_duplicate_committed_replay_keeps_one_envelope_named_final(
    tmp_path: Path,
) -> None:
    # Given
    value = environment(tmp_path)
    _ = write_delivery(value, envelope_byte=8)
    first = import_once(value)
    ack_path = value.acks / ("08" * 16 + ".hba")
    first_bytes = ack_path.read_bytes()

    # When
    replay = import_once(value)

    # Then
    assert first.imported == 1
    assert replay.idempotent == 1
    assert replay.conflict == 0
    assert ack_path.read_bytes() == first_bytes
    assert list(value.acks.glob("*.hba")) == [ack_path]


def test_one_shot_importer_rejects_replaced_device_without_external_write(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value)
    importer = configured_importer(value)
    external = tmp_path / "external-mailbox"
    for lane in ("deliveries", "acks", "quarantine"):
        (external / lane).mkdir(parents=True, exist_ok=True)
    detached = value.mailbox_path.parent / "detached-device"
    _ = value.mailbox_path.rename(detached)
    _ = value.mailbox_path.symlink_to(external, target_is_directory=True)

    with pytest.raises(MailboxFileError):
        _ = importer.import_once()

    assert database_counts(value) == (0, 0, 0)
    assert list((external / "acks").iterdir()) == []
    assert list((external / "quarantine").iterdir()) == []


def test_ack_finalize_revalidates_namespace_at_mutation_boundary(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value)
    detached_acks = tmp_path / "detached-acks"
    replaced = False

    def detach_before_finalize(point: MailboxImportFaultPoint) -> None:
        nonlocal replaced
        if point is MailboxImportFaultPoint.BEFORE_ACK_RENAME and not replaced:
            _ = value.acks.rename(detached_acks)
            value.acks.mkdir()
            replaced = True

    with pytest.raises(MailboxFileError):
        _ = import_once(value, fault_hook=detach_before_finalize)

    assert replaced
    assert database_counts(value) == (1, 1, 1)
    assert list(value.acks.iterdir()) == []
    assert list(detached_acks.glob("*.hba")) == []

    restarted = import_once(value)

    assert restarted.idempotent == 1
    assert len(list(value.acks.glob("*.hba"))) == 1


def test_cleanup_revalidates_namespace_at_each_unlink_boundary(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    stale = value.deliveries / ("11" * 16 + ".hbd." + "22" * 16 + ".tmp")
    _ = stale.write_bytes(b"stale")
    age(stale, now_ms=NOW_MS, elapsed_ms=2 * DAY_MS)
    detached_deliveries = tmp_path / "detached-deliveries"
    replaced = False

    def detach_before_unlink(point: MailboxImportFaultPoint) -> None:
        nonlocal replaced
        if point is MailboxImportFaultPoint.BEFORE_CLEANUP_UNLINK and not replaced:
            _ = value.deliveries.rename(detached_deliveries)
            value.deliveries.mkdir()
            replaced = True

    with pytest.raises(MailboxFileError):
        _ = import_once(value, fault_hook=detach_before_unlink)

    assert replaced
    assert list(value.deliveries.iterdir()) == []
    assert stale.name in {path.name for path in detached_deliveries.iterdir()}


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="exercises the Linux renameat2 partial-finalize path",
)
def test_linux_partial_finalize_recovers_idempotent_ack_after_restart(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value)
    real_unlink = os.unlink
    failed_unlinks = 0

    def fail_first_two_temp_unlinks(
        path: str | bytes | os.PathLike[str] | os.PathLike[bytes],
        *,
        dir_fd: int | None = None,
    ) -> None:
        nonlocal failed_unlinks
        if os.fsdecode(path).endswith(".tmp") and failed_unlinks < 2:
            failed_unlinks += 1
            raise OSError(errno.EIO, "synthetic unlink failure")
        real_unlink(path, dir_fd=dir_fd)

    monkeypatch.setattr(os, "unlink", fail_first_two_temp_unlinks)
    first = import_once(value)

    assert failed_unlinks == 2
    assert first.retryable == 1
    assert database_counts(value) == (1, 1, 1)
    assert len(list(value.acks.glob("*.hba"))) == 1
    assert len(list(value.acks.glob("*.tmp"))) == 1

    monkeypatch.setattr(os, "unlink", real_unlink)
    restarted = import_once(value)

    assert restarted.idempotent == 1
    assert restarted.conflict == 0
    assert len(list(value.acks.glob("*.hba"))) == 1
    assert list(value.acks.glob("*.tmp")) == []
    assert next(value.acks.glob("*.hba")).stat().st_nlink == 1


def test_unlink_rechecks_entry_identity_after_ancestry_validator(
    tmp_path: Path,
) -> None:
    lane = tmp_path / "lane"
    lane.mkdir()
    entry = lane / "entry.tmp"
    _ = entry.write_bytes(b"original")
    expected = file_identity(entry.stat(follow_symlinks=False))
    preserved = lane / "preserved.tmp"
    directory_fd = open_directory(lane)

    def replace_during_validator() -> None:
        _ = entry.rename(preserved)
        _ = entry.write_bytes(b"replacement")

    try:
        removed = unlink_same_at(
            directory_fd,
            entry.name,
            expected,
            before_unlink=replace_during_validator,
        )
    finally:
        os.close(directory_fd)

    assert not removed
    assert entry.read_bytes() == b"replacement"
    assert preserved.read_bytes() == b"original"


def test_partial_finalize_identity_race_stays_retryable_without_unlink(
    tmp_path: Path,
) -> None:
    lane = tmp_path / "acks"
    lane.mkdir()
    final_name = f"{'11' * 16}.hba"
    temp_name = f"{final_name}.{'22' * 16}.tmp"
    final = lane / final_name
    temp = lane / temp_name
    content = b"synthetic-ack"
    _ = final.write_bytes(content)
    os.link(final, temp)
    preserved = lane / "preserved.tmp"
    directory_fd = open_directory(lane)

    def replace_during_validator() -> None:
        _ = temp.rename(preserved)
        _ = temp.write_bytes(b"replacement")

    try:
        with pytest.raises(OSError, match="publication recovery pending") as raised:
            _ = publish_final_at(
                directory_fd,
                final_name,
                content,
                before_mutation=replace_during_validator,
            )
    finally:
        os.close(directory_fd)

    assert raised.value.errno == errno.EAGAIN
    assert final.read_bytes() == content
    assert final.stat().st_nlink == 2
    assert preserved.read_bytes() == content
    assert temp.read_bytes() == b"replacement"


def test_mailbox_directory_close_attempts_every_descriptor_and_is_idempotent(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    value = environment(tmp_path)
    handle = mailbox_files.open_mailbox_directory(value.mailbox_path)
    descriptors = (
        handle.quarantine_fd,
        handle.acks_fd,
        handle.deliveries_fd,
        handle.mailbox_fd,
        handle.receiver_fd,
        handle.root_fd,
        handle.root_parent_fd,
    )
    failed_descriptor = descriptors[0]
    real_close = os.close
    closed: list[int] = []

    failed_once = False

    def recording_close(descriptor: int) -> None:
        nonlocal failed_once
        closed.append(descriptor)
        if descriptor == failed_descriptor and not failed_once:
            failed_once = True
            raise OSError(errno.EIO, "synthetic close failure")
        real_close(descriptor)

    monkeypatch.setattr(os, "close", recording_close)
    with pytest.raises(OSError, match="synthetic close failure"):
        handle.close()
    assert closed == list(descriptors)

    handle.close()

    assert closed == [*descriptors, failed_descriptor]


def test_semantically_valid_alternate_json_keeps_original_digest(
    tmp_path: Path,
) -> None:
    # Given
    value = environment(tmp_path)
    payload = alternate_batch()
    _ = write_delivery(value, payload=payload, envelope_byte=2)

    # When
    result = import_once(value)

    # Then
    receipt = opened_receipt(next(value.acks.glob("*.hba")), envelope_byte=2)
    assert result.imported == 1
    assert receipt.payload_sha256 == hashlib.sha256(payload).hexdigest()


@pytest.mark.parametrize(
    "payload",
    INVALID_PAYLOADS,
)
def test_authenticated_invalid_plaintext_publishes_closed_nack(
    tmp_path: Path,
    payload: bytes,
) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value, payload=payload)

    result = import_once(value)

    receipt = opened_receipt(next(value.acks.glob("*.hba")))
    assert result.quarantined == 1
    assert (receipt.result, receipt.error_code) == ("terminal", "payload_invalid")
    assert database_counts(value) == (0, 0, 0)


@pytest.mark.parametrize("entry_kind", ["symlink", "hardlink", "directory"])
def test_unsafe_final_delivery_fails_closed(
    tmp_path: Path,
    entry_kind: str,
) -> None:
    value = environment(tmp_path)
    target = tmp_path / "synthetic-envelope"
    _ = target.write_bytes(b"synthetic")
    final = value.deliveries / f"{'01' * 16}.hbd"
    if entry_kind == "symlink":
        final.symlink_to(target)
    elif entry_kind == "hardlink":
        final.hardlink_to(target)
    else:
        final.mkdir()

    result = import_once(value)

    assert result.quarantined == 1
    assert database_counts(value) == (0, 0, 0)
    assert final.exists() or final.is_symlink()


@pytest.mark.parametrize(
    ("content", "ack_count"),
    [
        (b"x" * 2_097_153, 0),
        (authenticated_oversize_envelope(b" " * 1_048_577), 1),
    ],
)
def test_outer_and_authenticated_plaintext_oversize_fail_closed(
    tmp_path: Path,
    content: bytes,
    ack_count: int,
) -> None:
    value = environment(tmp_path)
    delivery = value.deliveries / f"{'01' * 16}.hbd"
    _ = delivery.write_bytes(content)

    result = import_once(value)

    assert result.quarantined == 1
    assert len(list(value.acks.glob("*.hba"))) == ack_count
    assert database_counts(value) == (0, 0, 0)


def test_path_replacement_after_open_is_detected_before_commit(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)
    replacement = tmp_path / "replacement"
    _ = replacement.write_bytes(b"replacement")

    def replace() -> None:
        delivery.unlink()
        delivery.symlink_to(replacement)

    result = import_once(
        value,
        fault_hook=fault_at(MailboxImportFaultPoint.AFTER_DELIVERY_OPEN, replace),
    )

    assert result.quarantined == 1
    assert database_counts(value) == (0, 0, 0)


def test_provider_path_replacement_is_retried_once_when_opted_in(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)
    original = delivery.read_bytes()
    replacement_count = 0

    def replace_once(point: MailboxImportFaultPoint) -> None:
        nonlocal replacement_count
        if (
            point == MailboxImportFaultPoint.AFTER_DELIVERY_OPEN
            and replacement_count == 0
        ):
            replacement = tmp_path / "provider-replacement"
            _ = replacement.write_bytes(original)
            _ = replacement.replace(delivery)
            replacement_count += 1

    result = configured_importer(
        value,
        path_replacement_retry_limit=1,
    ).import_once(fault_hook=replace_once)

    assert replacement_count == 1
    assert result.imported == 1
    assert result.quarantined == 0
    assert database_counts(value) == (1, 1, 1)
    assert len(list(value.acks.glob("*.hba"))) == 1


def test_restart_after_commit_before_ack_rename_regenerates_same_ack(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)
    with pytest.raises(RuntimeError, match="before_ack_rename"):
        _ = import_once(
            value,
            fault_hook=fault_at(MailboxImportFaultPoint.BEFORE_ACK_RENAME),
        )
    assert database_counts(value) == (1, 1, 1)
    assert delivery.exists()
    assert list(value.acks.glob("*.hba")) == []

    restarted = import_once(value)

    assert restarted.idempotent == 1
    assert database_counts(value) == (1, 1, 1)
    assert len(list(value.acks.glob("*.hba"))) == 1


@pytest.mark.parametrize(
    ("point", "committed", "ack_count"),
    [
        (MailboxImportFaultPoint.BEFORE_ACCEPT, False, 0),
        (MailboxImportFaultPoint.AFTER_ACCEPT, True, 0),
        (MailboxImportFaultPoint.AFTER_ACK_RENAME, True, 1),
    ],
)
def test_crash_boundaries_restart_without_duplicate_ingest(
    tmp_path: Path,
    point: MailboxImportFaultPoint,
    committed: bool,
    ack_count: int,
) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)
    with pytest.raises(RuntimeError, match=point.value):
        _ = import_once(value, fault_hook=fault_at(point))
    assert database_counts(value) == ((1, 1, 1) if committed else (0, 0, 0))
    assert len(list(value.acks.glob("*.hba"))) == ack_count
    assert delivery.exists()

    restarted = import_once(value)

    assert database_counts(value) == (1, 1, 1)
    assert restarted.imported + restarted.idempotent == 1


def test_conflicting_final_ack_retains_delivery(tmp_path: Path) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)
    with pytest.raises(RuntimeError):
        _ = import_once(
            value,
            fault_hook=fault_at(MailboxImportFaultPoint.BEFORE_ACK_RENAME),
        )
    expected = configured_importer(value).expected_ack_path(delivery)
    _ = expected.write_bytes(b"conflict")

    result = import_once(value)

    assert result.conflict == 1
    assert delivery.exists()
    assert expected.read_bytes() == b"conflict"
    assert database_counts(value) == (1, 1, 1)


def test_concurrent_writer_lock_is_retryable_and_redacted(tmp_path: Path) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value)
    with (
        mailbox_files.mailbox_writer_lock(value.lock_path),
        pytest.raises(MailboxBusyError) as exc,
    ):
        _ = import_once(value)
    assert str(exc.value) == "mailbox importer is busy"


def test_quota_failure_keeps_delivery_and_reports_retryable(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)

    def full_disk(_fd: int, _data: bytes) -> int:
        raise OSError(errno.ENOSPC, "synthetic")

    monkeypatch.setattr(os, "write", full_disk)
    result = import_once(value)

    assert result.retryable == 1
    assert delivery.exists()
    assert database_counts(value) == (1, 1, 1)


def test_exact_retention_and_stale_temp_boundaries(tmp_path: Path) -> None:
    value = environment(tmp_path)
    delivery = write_delivery(value)
    _ = import_once(value)
    ack = next(value.acks.glob("*.hba"))
    age(ack, now_ms=1_784_600_000_123, elapsed_ms=7 * DAY_MS)
    stale = value.deliveries / f"{'02' * 16}.hbd.{'03' * 16}.tmp"
    _ = stale.write_bytes(b"partial")
    age(stale, now_ms=1_784_600_000_123, elapsed_ms=DAY_MS)

    _ = import_once(value)

    assert not delivery.exists()
    assert not stale.exists()
    age(ack, now_ms=1_784_600_000_123, elapsed_ms=30 * DAY_MS)
    _ = import_once(value)
    assert not ack.exists()


def test_cleanup_restart_is_idempotent(tmp_path: Path) -> None:
    value = environment(tmp_path)
    stale = value.deliveries / f"{'02' * 16}.hbd.{'03' * 16}.tmp"
    _ = stale.write_bytes(b"partial")
    age(stale, now_ms=1_784_600_000_123, elapsed_ms=DAY_MS)
    with pytest.raises(RuntimeError, match="before_cleanup_unlink"):
        _ = import_once(
            value,
            fault_hook=fault_at(MailboxImportFaultPoint.BEFORE_CLEANUP_UNLINK),
        )
    assert stale.exists()

    _ = import_once(value)

    assert not stale.exists()


def test_scan_and_quarantine_caps_are_numeric_and_oldest_first(
    tmp_path: Path,
) -> None:
    value = environment(tmp_path)
    populate_scan_and_quarantine_caps(value)
    scan = mailbox_files.scan_delivery_lane(value.deliveries)
    assert len(scan.entries) == 10_000
    assert scan.skipped == 1
    assert scan.entries[0].name == f"{0:032x}.hbd"
    assert scan.entries[-1].name == f"{9_999:032x}.hbd"

    cleanup_quarantine(value.quarantine, now_ms=1_002_000)
    assert len(list(value.quarantine.glob("*.hbq"))) == 1_000
    assert not (value.quarantine / f"{0:032x}.hbq").exists()
    size_scan = scan_size_cap(tmp_path / "size-cap")
    assert (len(size_scan.entries), size_scan.skipped) == (1_024, 1)
    assert quarantine_byte_and_age_caps(tmp_path / "quarantine-caps")

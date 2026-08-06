from __future__ import annotations

import errno
import hashlib
import os
from typing import TYPE_CHECKING

import pytest

from health_bridge.mailbox import filesystem as mailbox_files
from health_bridge.mailbox.importer import MailboxBusyError
from health_bridge.mailbox.models import MailboxImportFaultPoint
from health_bridge.mailbox.publication import cleanup_quarantine
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

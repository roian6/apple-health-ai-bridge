# pyright: reportPrivateUsage=false

import os
import re
import sqlite3
import stat
from pathlib import Path
from subprocess import run
from typing import Final, TypeAlias

import pytest
import typer
from pydantic import BaseModel, TypeAdapter

import health_bridge.cli_receiver as receiver_cli_module
from health_bridge.receiver.invitations import (
    create_pairing_invitation,
    redeem_pairing_invitation,
)
from health_bridge.receiver.pairing import (
    pairing_bundle_from_deep_link,
    pairing_invitation_from_deep_link,
)
from health_bridge.receiver.tokens import authenticate_receiver_token
from health_bridge.storage.database import connect_database


class ReceiverTokenCliOutput(BaseModel):
    label: str
    token: str
    token_prefix: str
    warning: str


class ReceiverTokenFileCliOutput(BaseModel):
    label: str
    secret_file: str
    token_prefix: str
    warning: str


class ReceiverPairingCliOutput(BaseModel):
    schema_id: str
    schema_version: str
    label: str
    receiver_url: str
    bearer_token: str
    token_prefix: str
    created_at: str
    warning: str
    pairing_url: str


class ReceiverPairingInvitationCliOutput(BaseModel):
    schema_id: str
    schema_version: str
    invitation_id: str
    label: str
    receiver_url: str
    redeem_url: str
    invitation_secret: str
    invitation_code: str
    created_at: str
    expires_at: str
    warning: str
    pairing_url: str


class ReceiverPairingDeepLinkCliOutput(BaseModel):
    label: str
    pairing_url: str
    pairing_schema_id: str
    invitation_expires_at: str
    warning: str


class ReceiverPairingSetupPageCliOutput(BaseModel):
    label: str
    setup_page: str
    pairing_schema_id: str
    invitation_expires_at: str
    warning: str


class ReceiverDeviceCliOutput(BaseModel):
    device_ref: str
    label: str
    platform: str
    last_paired_at: str
    revoked_at: str | None


class ReceiverDeviceListCliOutput(BaseModel):
    devices: list[ReceiverDeviceCliOutput]


class ReceiverDeviceRevokeCliOutput(BaseModel):
    revoked_device_ref: str
    revoked_token_count: int


class ReceiverPurgeCliOutput(BaseModel):
    status: str
    database: str
    paths: list[str]
    confirm_required: bool
    warning: str
    quarantine_path: str | None = None
    quarantined_paths: list[str] | None = None
    truncated_paths: list[str] | None = None


ReceiverTokenRow: TypeAlias = tuple[str, str, str]
RECEIVER_TOKEN_ROW_ADAPTER: Final[TypeAdapter[ReceiverTokenRow | None]] = TypeAdapter(
    ReceiverTokenRow | None,
)


def test_receiver_purge_is_dry_run_by_default(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"
    with connect_database(db_path) as connection:
        _ = connection.execute("create table synthetic_private_data (value text)")
    journal_path = Path(f"{db_path}-journal")
    _ = journal_path.write_text("synthetic sidecar", encoding="utf-8")

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "purge",
            "--db",
            str(db_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverPurgeCliOutput.model_validate_json(result.stdout)

    assert result.returncode == 0, result.stderr
    assert output.status == "dry-run"
    assert output.database == str(db_path)
    assert output.paths == [str(db_path), str(journal_path)]
    assert output.confirm_required is True
    assert "Stop the receiver" in output.warning
    assert "Apple Health" in output.warning
    assert db_path.exists()
    assert journal_path.exists()


def test_receiver_purge_deletes_only_database_scope_with_confirmation(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    unrelated_path = tmp_path / "keep.txt"
    _ = unrelated_path.write_text("keep", encoding="utf-8")
    with connect_database(db_path) as connection:
        _ = connection.execute("create table synthetic_private_data (value text)")

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "purge",
            "--db",
            str(db_path),
            "--confirm",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverPurgeCliOutput.model_validate_json(result.stdout)

    assert result.returncode == 0, result.stderr
    assert output.status == "purged"
    assert output.paths == [str(db_path)]
    assert output.confirm_required is False
    assert not db_path.exists()
    assert unrelated_path.read_text(encoding="utf-8") == "keep"
    quarantine_paths = tuple(tmp_path.glob(".receiver.sqlite.purge-*"))
    assert len(quarantine_paths) == 1
    assert (quarantine_paths[0] / db_path.name).read_bytes() == b""


def test_receiver_purge_refuses_symlink_without_touching_target(tmp_path: Path) -> None:
    target = tmp_path / "target.sqlite"
    _ = target.write_text("not a database", encoding="utf-8")
    db_path = tmp_path / "receiver.sqlite"
    db_path.symlink_to(target)

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "purge",
            "--db",
            str(db_path),
            "--confirm",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert result.stdout == ""
    assert "symlink" in result.stderr.lower()
    assert db_path.is_symlink()
    assert target.read_text(encoding="utf-8") == "not a database"


def test_receiver_purge_refuses_symlinked_parent(tmp_path: Path) -> None:
    real_parent = tmp_path / "real"
    real_parent.mkdir(mode=0o700)
    linked_parent = tmp_path / "linked"
    linked_parent.symlink_to(real_parent, target_is_directory=True)
    real_db = real_parent / "receiver.sqlite"
    with connect_database(real_db):
        pass

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "purge",
            "--db",
            str(linked_parent / real_db.name),
            "--confirm",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "symlinked parent" in result.stderr
    assert real_db.exists()


def test_receiver_purge_already_absent_does_not_create_parent(tmp_path: Path) -> None:
    db_path = tmp_path / "missing" / "receiver.sqlite"

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "purge",
            "--db",
            str(db_path),
            "--confirm",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverPurgeCliOutput.model_validate_json(result.stdout)

    assert result.returncode == 0, result.stderr
    assert output.status == "already-absent"
    assert not db_path.parent.exists()


def test_receiver_purge_refuses_active_database_lock(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"
    with connect_database(db_path) as connection:
        _ = connection.execute("BEGIN EXCLUSIVE")

        result = run(
            [
                "uv",
                "run",
                "health-bridge",
                "receiver",
                "purge",
                "--db",
                str(db_path),
                "--confirm",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        connection.rollback()

    assert result.returncode == 1
    assert result.stdout == ""
    assert "unavailable or still in use" in result.stderr
    assert db_path.exists()
    with sqlite3.connect(db_path) as connection:
        assert connection.execute("pragma integrity_check").fetchone() == ("ok",)


@pytest.mark.skipif(os.name != "posix", reason="FIFO is a POSIX file type")
def test_receiver_purge_refuses_special_sidecar_before_deleting_database(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    with connect_database(db_path):
        pass
    fifo_path = Path(f"{db_path}-wal")
    os.mkfifo(fifo_path)

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "purge",
            "--db",
            str(db_path),
            "--confirm",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert result.stdout == ""
    assert db_path.exists()
    assert stat.S_ISFIFO(fifo_path.lstat().st_mode)


def test_purge_quarantine_replaced_inode_requires_recovery_without_deletion(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    _ = db_path.write_bytes(b"expected database bytes")
    backup_path = tmp_path / "expected-backup.sqlite"
    scope = (db_path,)
    parent_fd = os.open(tmp_path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    identities = receiver_cli_module._validated_purge_identities(  # noqa: SLF001
        parent_fd,
        scope,
    )
    real_rename = os.rename
    replaced = False

    def replace_before_first_quarantine(
        src: str,
        dst: str,
        *,
        src_dir_fd: int | None = None,
        dst_dir_fd: int | None = None,
    ) -> None:
        nonlocal replaced
        if not replaced and src_dir_fd == parent_fd:
            replaced = True
            real_rename(
                src, backup_path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd
            )
            _ = db_path.write_bytes(b"unrelated replacement bytes")
        real_rename(src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)

    monkeypatch.setattr(os, "rename", replace_before_first_quarantine)
    try:
        with pytest.raises(receiver_cli_module.PurgeRecoveryRequiredError) as caught:
            receiver_cli_module._quarantine_and_delete(  # noqa: SLF001
                parent_fd,
                db_path,
                identities,
            )
    finally:
        os.close(parent_fd)

    assert not db_path.exists()
    assert backup_path.read_bytes() == b"expected database bytes"
    quarantine_paths = tuple(tmp_path.glob(".receiver.sqlite.purge-*"))
    assert len(quarantine_paths) == 1
    assert (quarantine_paths[0] / db_path.name).read_bytes() == (
        b"unrelated replacement bytes"
    )
    assert caught.value.quarantine_path == quarantine_paths[0]
    assert caught.value.quarantined_paths == (quarantine_paths[0] / db_path.name,)
    assert caught.value.truncated_paths == ()
    assert caught.value.residual_paths == ()


def test_receiver_purge_cli_source_collision_reports_recovery_required(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    with connect_database(db_path) as connection:
        _ = connection.execute("create table synthetic_private_data (value text)")
    replacement = b"unrelated replacement bytes"
    real_move = receiver_cli_module._move_paths_to_quarantine  # noqa: SLF001

    def move_then_collide(
        parent_fd: int,
        quarantine_fd: int,
        identities: dict[str, tuple[int, int, int, int, int]],
        moved: list[str],
    ) -> None:
        real_move(parent_fd, quarantine_fd, identities, moved)
        _ = db_path.write_bytes(replacement)

    monkeypatch.setattr(
        receiver_cli_module,
        "_move_paths_to_quarantine",
        move_then_collide,
    )

    with pytest.raises(typer.Exit) as caught:
        receiver_cli_module.purge_receiver_store(db=db_path, confirm=True)

    captured = capsys.readouterr()
    output = ReceiverPurgeCliOutput.model_validate_json(captured.out)
    assert caught.value.exit_code == 1
    assert output.status == "recovery-required"
    assert output.paths == [str(db_path)]
    assert output.quarantine_path is not None
    quarantine = Path(output.quarantine_path)
    assert output.quarantined_paths == [str(quarantine / db_path.name)]
    assert output.truncated_paths == []
    assert db_path.read_bytes() == replacement
    assert (quarantine / db_path.name).read_bytes().startswith(b"SQLite format 3")
    assert "requires recovery" in captured.err
    assert "failed safely" not in captured.err


def test_purge_sidecar_truncate_failure_reports_recovery_required(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    journal_path = Path(f"{db_path}-journal")
    wal_path = Path(f"{db_path}-wal")
    _ = db_path.write_bytes(b"database")
    _ = journal_path.write_bytes(b"journal")
    _ = wal_path.write_bytes(b"wal")
    scope = (db_path, journal_path, wal_path)
    parent_fd = os.open(tmp_path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    identities = receiver_cli_module._validated_purge_identities(  # noqa: SLF001
        parent_fd,
        scope,
    )
    wal_identity = (wal_path.stat().st_dev, wal_path.stat().st_ino)
    real_ftruncate = os.ftruncate

    def fail_on_wal(fd: int, length: int) -> None:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) == wal_identity:
            message = "synthetic sidecar truncate failure"
            raise PermissionError(message)
        real_ftruncate(fd, length)

    monkeypatch.setattr(os, "ftruncate", fail_on_wal)
    try:
        with pytest.raises(receiver_cli_module.PurgeRecoveryRequiredError) as caught:
            receiver_cli_module._quarantine_and_delete(  # noqa: SLF001
                parent_fd,
                db_path,
                identities,
            )
    finally:
        os.close(parent_fd)

    assert not db_path.exists()
    assert not wal_path.exists()
    assert not journal_path.exists()
    quarantine = next(tmp_path.glob(".receiver.sqlite.purge-*"))
    assert (quarantine / db_path.name).read_bytes() == b"database"
    assert (quarantine / wal_path.name).read_bytes() == b"wal"
    assert (quarantine / journal_path.name).read_bytes() == b""
    assert caught.value.quarantine_path == quarantine
    assert caught.value.truncated_paths == (quarantine / journal_path.name,)
    assert caught.value.residual_paths == ()


def test_purge_refuses_late_sidecar_before_truncating_database(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    _ = db_path.write_bytes(b"database")
    parent_fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    identities = receiver_cli_module._validated_purge_identities(  # noqa: SLF001
        parent_fd,
        (db_path,),
    )
    real_require_absent = receiver_cli_module._require_absent_source_paths  # noqa: SLF001
    injected = False

    def inject_late_wal(checked_parent_fd: int, checked_db_path: Path) -> None:
        nonlocal injected
        if not injected:
            injected = True
            _ = Path(f"{checked_db_path}-wal").write_bytes(b"late wal")
        real_require_absent(checked_parent_fd, checked_db_path)

    monkeypatch.setattr(
        receiver_cli_module,
        "_require_absent_source_paths",
        inject_late_wal,
    )
    try:
        with pytest.raises(OSError, match="reappeared"):
            receiver_cli_module._quarantine_and_delete(  # noqa: SLF001
                parent_fd,
                db_path,
                identities,
            )
    finally:
        os.close(parent_fd)

    assert db_path.read_bytes() == b"database"
    assert Path(f"{db_path}-wal").read_bytes() == b"late wal"


def test_purge_reports_late_sidecar_after_truncate_as_recovery_required(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    wal_path = Path(f"{db_path}-wal")
    _ = db_path.write_bytes(b"database")
    parent_fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    identities = receiver_cli_module._validated_purge_identities(  # noqa: SLF001
        parent_fd,
        (db_path,),
    )
    real_ftruncate = os.ftruncate
    injected = False

    def inject_after_last_absence_check(fd: int, length: int) -> None:
        nonlocal injected
        if not injected:
            injected = True
            _ = wal_path.write_bytes(b"LATE_PRIVATE_WAL")
        real_ftruncate(fd, length)

    monkeypatch.setattr(os, "ftruncate", inject_after_last_absence_check)
    try:
        with pytest.raises(receiver_cli_module.PurgeRecoveryRequiredError) as caught:
            receiver_cli_module._quarantine_and_delete(  # noqa: SLF001
                parent_fd,
                db_path,
                identities,
            )
    finally:
        os.close(parent_fd)

    quarantine = next(tmp_path.glob(".receiver.sqlite.purge-*"))
    assert (quarantine / db_path.name).read_bytes() == b""
    assert wal_path.read_bytes() == b"LATE_PRIVATE_WAL"
    assert caught.value.quarantine_path == quarantine
    assert caught.value.truncated_paths == (quarantine / db_path.name,)
    assert caught.value.residual_paths == (wal_path,)


def test_receiver_purge_cli_reports_structured_recovery_required(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    _ = db_path.write_bytes(b"database")
    quarantine = tmp_path / ".receiver.sqlite.purge-recovery"
    quarantined_db = quarantine / db_path.name
    late_wal = Path(f"{db_path}-wal")

    def require_recovery(_db: Path, _scope: tuple[Path, ...]) -> None:
        raise receiver_cli_module.PurgeRecoveryRequiredError(
            quarantine_path=quarantine,
            quarantined_paths=(quarantined_db,),
            truncated_paths=(quarantined_db,),
            residual_paths=(late_wal,),
        )

    monkeypatch.setattr(
        receiver_cli_module,
        "_purge_database_transaction",
        require_recovery,
    )

    with pytest.raises(typer.Exit) as caught:
        receiver_cli_module.purge_receiver_store(db=db_path, confirm=True)

    captured = capsys.readouterr()
    output = ReceiverPurgeCliOutput.model_validate_json(captured.out)
    assert caught.value.exit_code == 1
    assert output.status == "recovery-required"
    assert output.paths == [str(late_wal)]
    assert output.quarantine_path == str(quarantine)
    assert output.quarantined_paths == [str(quarantined_db)]
    assert output.truncated_paths == [str(quarantined_db)]
    assert "requires recovery" in captured.err
    assert "failed safely" not in captured.err


def test_purge_truncates_opened_inode_without_deleting_path_replacement(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    _ = db_path.write_bytes(b"database")
    parent_fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    identities = receiver_cli_module._validated_purge_identities(  # noqa: SLF001
        parent_fd,
        (db_path,),
    )
    real_open_validated = receiver_cli_module._open_validated_quarantined_paths  # noqa: SLF001

    def replace_after_open(
        quarantine_fd: int,
        expected: dict[str, tuple[int, int, int, int, int]],
    ) -> dict[str, int]:
        opened = real_open_validated(quarantine_fd, expected)
        os.rename(
            db_path.name,
            f"{db_path.name}.expected",
            src_dir_fd=quarantine_fd,
            dst_dir_fd=quarantine_fd,
        )
        replacement_fd = os.open(
            db_path.name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=quarantine_fd,
        )
        try:
            _ = os.write(replacement_fd, b"unrelated")
        finally:
            os.close(replacement_fd)
        return opened

    monkeypatch.setattr(
        receiver_cli_module,
        "_open_validated_quarantined_paths",
        replace_after_open,
    )
    try:
        receiver_cli_module._quarantine_and_delete(  # noqa: SLF001
            parent_fd,
            db_path,
            identities,
        )
    finally:
        os.close(parent_fd)

    quarantine = next(tmp_path.glob(".receiver.sqlite.purge-*"))
    assert (quarantine / db_path.name).read_bytes() == b"unrelated"
    assert (quarantine / f"{db_path.name}.expected").read_bytes() == b""


def test_purge_fails_closed_without_required_os_primitives(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delattr(os, "O_DIRECTORY")

    with pytest.raises(OSError, match="requires O_NOFOLLOW and O_DIRECTORY"):
        receiver_cli_module._require_safe_purge_primitives()  # noqa: SLF001


def test_receiver_create_token_cli_refuses_default_secret_stdout(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-token",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert "Refusing to print receiver bearer token" in result.stderr
    assert "--print-secret" in result.stderr
    assert "--output-secret" in result.stderr
    assert not db_path.exists()


def test_receiver_create_token_cli_prints_one_time_secret_only_with_explicit_flag(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-token",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--print-secret",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverTokenCliOutput.model_validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.label == "ios-companion"
    assert output.token.startswith("hb_")
    assert output.token_prefix == output.token[:11]
    assert "shown once" in output.warning

    with connect_database(db_path) as connection:
        row = RECEIVER_TOKEN_ROW_ADAPTER.validate_python(
            connection.execute(
                "select token_label, token_prefix, token_hash from receiver_tokens",
            ).fetchone(),
        )

    assert row is not None
    assert row[0] == "ios-companion"
    assert row[1] == output.token_prefix
    assert row[2] != output.token
    assert output.token not in row[2]


def test_receiver_create_token_cli_can_write_one_time_secret_to_private_file(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    secret_path = tmp_path / "private" / "receiver-token.json"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-token",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--output-secret",
            str(secret_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverTokenFileCliOutput.model_validate_json(result.stdout)
    secret_output = ReceiverTokenCliOutput.model_validate_json(
        secret_path.read_text(encoding="utf-8"),
    )

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.label == "ios-companion"
    assert output.secret_file == str(secret_path)
    assert output.token_prefix == secret_output.token_prefix
    assert '"token"' not in result.stdout
    assert secret_output.token.startswith("hb_")
    assert stat.S_IMODE(secret_path.stat().st_mode) == 0o600
    assert authenticate_receiver_token(db_path, secret_output.token)


def test_receiver_create_token_cli_rejects_unwritable_secret_path_before_issuing(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    secret_path = tmp_path / "not-a-file"
    secret_path.mkdir()

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-token",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--output-secret",
            str(secret_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert "Failed to open private token output file" in result.stderr
    assert not db_path.exists()


def test_receiver_create_token_cli_rejects_symlink_secret_output_path(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    symlink_target = tmp_path / "target.json"
    _ = symlink_target.write_text("existing target\n", encoding="utf-8")
    secret_path = tmp_path / "receiver-token.json"
    secret_path.symlink_to(symlink_target)

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-token",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--output-secret",
            str(secret_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert "Failed to open private token output file" in result.stderr
    assert symlink_target.read_text(encoding="utf-8") == "existing target\n"
    assert stat.S_IMODE(symlink_target.stat().st_mode) != 0o600
    assert not db_path.exists()


def test_receiver_create_token_cli_preserves_secret_file_if_token_creation_fails(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "db-directory"
    db_path.mkdir()
    secret_path = tmp_path / "receiver-token.json"
    _ = secret_path.write_text("existing secret\n", encoding="utf-8")

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-token",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--output-secret",
            str(secret_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode != 0
    assert secret_path.read_text(encoding="utf-8") == "existing secret\n"


def test_receiver_create_pairing_cli_requires_setup_page_or_explicit_secret_output(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    receiver_url = "https://health-bridge.example.test/v1/batches"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-pairing",
            "--db",
            str(db_path),
            "--label",
            "maintainer-iphone",
            "--receiver-url",
            receiver_url,
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert "--setup-page is required" in result.stderr
    assert not db_path.exists()


def test_receiver_create_pairing_cli_prints_secret_json_only_with_explicit_flag(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    receiver_url = "https://health-bridge.example.test/v1/batches"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-pairing",
            "--db",
            str(db_path),
            "--label",
            "maintainer-iphone",
            "--receiver-url",
            receiver_url,
            "--format",
            "json",
            "--print-secret",
            "--legacy-v1",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverPairingCliOutput.model_validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.schema_id == "health_bridge.receiver_pairing.v1"
    assert output.schema_version == "1.0.0"
    assert output.label == "maintainer-iphone"
    assert output.receiver_url == receiver_url
    assert output.bearer_token.startswith("hb_")
    assert output.token_prefix == output.bearer_token[:11]
    assert output.pairing_url.startswith("healthbridge://pair?payload=")
    assert "secret" in output.warning.lower()
    assert authenticate_receiver_token(db_path, output.bearer_token)
    decoded = pairing_bundle_from_deep_link(output.pairing_url)
    assert decoded.receiver_url == output.receiver_url
    assert decoded.bearer_token == output.bearer_token

    with connect_database(db_path) as connection:
        row = RECEIVER_TOKEN_ROW_ADAPTER.validate_python(
            connection.execute(
                "select token_label, token_prefix, token_hash from receiver_tokens",
            ).fetchone(),
        )

    assert row is not None
    assert row[0] == "maintainer-iphone"
    assert row[1] == output.token_prefix
    assert row[2] != output.bearer_token
    assert output.bearer_token not in row[2]


def test_receiver_create_pairing_cli_defaults_to_v2_invitation_json(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    receiver_url = "https://health-bridge.example.test/v1/batches"

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-pairing",
            "--db",
            str(db_path),
            "--label",
            "maintainer-iphone",
            "--receiver-url",
            receiver_url,
            "--format",
            "json",
            "--print-secret",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverPairingInvitationCliOutput.model_validate_json(result.stdout)

    assert result.returncode == 0, result.stderr
    assert output.schema_id == "health_bridge.receiver_pairing_invitation.v2"
    assert output.schema_version == "2.0.0"
    assert output.receiver_url == receiver_url
    assert output.redeem_url.endswith("/v1/pairing/redeem")
    assert output.invitation_secret.startswith("hbi_")
    assert re.fullmatch(
        r"[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}", output.invitation_code
    )
    decoded = pairing_invitation_from_deep_link(output.pairing_url)
    assert decoded.invitation_secret == output.invitation_secret
    assert output.invitation_code not in output.pairing_url
    with connect_database(db_path) as connection:
        receiver_token = RECEIVER_TOKEN_ROW_ADAPTER.validate_python(
            connection.execute(
                "select token_label, token_prefix, token_hash from receiver_tokens"
            ).fetchone()
        )
    assert receiver_token is None


def test_receiver_create_pairing_cli_can_emit_deep_link_only(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-pairing",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--receiver-url",
            "http://127.0.0.1:8765/v1/batches",
            "--format",
            "deeplink",
            "--print-secret",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverPairingDeepLinkCliOutput.model_validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert output.label == "ios-companion"
    assert output.pairing_schema_id == "health_bridge.receiver_pairing_invitation.v2"
    assert output.pairing_url.startswith("healthbridge://pair?payload=")
    decoded = pairing_invitation_from_deep_link(output.pairing_url)
    assert decoded.label == "ios-companion"
    assert decoded.expires_at == output.invitation_expires_at
    with connect_database(db_path) as connection:
        receiver_token = RECEIVER_TOKEN_ROW_ADAPTER.validate_python(
            connection.execute(
                "select token_label, token_prefix, token_hash from receiver_tokens"
            ).fetchone()
        )
    assert receiver_token is None


def test_receiver_create_pairing_cli_deep_link_requires_explicit_secret_flag(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-pairing",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--receiver-url",
            "http://127.0.0.1:8765/v1/batches",
            "--format",
            "deeplink",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert "requires --print-secret" in result.stderr
    assert not db_path.exists()


def test_receiver_create_pairing_cli_can_write_secret_setup_page(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    setup_page_path = tmp_path / "setup" / "pairing.html"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-pairing",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--receiver-url",
            "http://127.0.0.1:8765/v1/batches",
            "--format",
            "setup-page",
            "--setup-page",
            str(setup_page_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = ReceiverPairingSetupPageCliOutput.model_validate_json(result.stdout)
    html = setup_page_path.read_text(encoding="utf-8")
    pairing_url_match = re.search(r"healthbridge://pair\?payload=[A-Za-z0-9_-]+", html)
    assert pairing_url_match is not None
    decoded = pairing_invitation_from_deep_link(pairing_url_match.group(0))

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.label == "ios-companion"
    assert output.setup_page == str(setup_page_path)
    assert output.pairing_schema_id == "health_bridge.receiver_pairing_invitation.v2"
    assert output.invitation_expires_at == decoded.expires_at
    assert "bearer_token" not in result.stdout
    assert "pairing_url" not in result.stdout
    assert setup_page_path.exists()
    assert stat.S_IMODE(setup_page_path.stat().st_mode) == 0o600
    assert "<svg" in html
    assert "Use a code instead" in html
    assert (
        re.search(r"[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}", html)
        is not None
    )
    assert decoded.invitation_secret not in html
    with connect_database(db_path) as connection:
        receiver_token = RECEIVER_TOKEN_ROW_ADAPTER.validate_python(
            connection.execute(
                "select token_label, token_prefix, token_hash from receiver_tokens"
            ).fetchone()
        )
    assert receiver_token is None


def test_receiver_device_cli_lists_redacted_ref_and_revokes_v2_device(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    device_credential = "hb_" + "c" * 64
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health-bridge.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    _ = redeem_pairing_invitation(
        db_path,
        invitation_secret=invitation.invitation_secret,
        installation_id="00000000-0000-4000-8000-000000000003",
        device_credential=device_credential,
        platform="ios",
    )

    listed = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "list-devices",
            "--db",
            str(db_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert listed.returncode == 0
    listed_output = ReceiverDeviceListCliOutput.model_validate_json(listed.stdout)
    assert len(listed_output.devices) == 1
    device_ref = listed_output.devices[0].device_ref
    assert len(device_ref) == 12
    assert device_credential not in listed.stdout

    revoked = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "revoke-device",
            "--db",
            str(db_path),
            "--device-ref",
            device_ref,
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert revoked.returncode == 0
    revoked_output = ReceiverDeviceRevokeCliOutput.model_validate_json(revoked.stdout)
    assert revoked_output.revoked_device_ref == device_ref
    assert revoked_output.revoked_token_count == 1
    assert not authenticate_receiver_token(db_path, device_credential)

    second_revoke = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "revoke-device",
            "--db",
            str(db_path),
            "--device-ref",
            device_ref,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert second_revoke.returncode == 1
    assert device_credential not in second_revoke.stderr


@pytest.mark.parametrize(
    "command_args",
    [
        ["list-devices"],
        ["revoke-device", "--device-ref", "0123456789ab"],
    ],
    ids=["list-devices", "revoke-device"],
)
def test_receiver_device_cli_bounds_storage_errors_without_traceback(
    tmp_path: Path,
    command_args: list[str],
) -> None:
    db_directory = tmp_path / "receiver-db-directory"
    db_directory.mkdir()

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            *command_args,
            "--db",
            str(db_directory),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert result.stdout == ""
    assert "Receiver device storage is unavailable." in result.stderr
    assert "Traceback" not in result.stderr
    assert str(db_directory) not in result.stderr


def test_receiver_create_pairing_cli_setup_page_requires_output_path(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-pairing",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--receiver-url",
            "http://127.0.0.1:8765/v1/batches",
            "--format",
            "setup-page",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert "--setup-page is required" in result.stderr

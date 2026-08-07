from __future__ import annotations

import json
import os
import re
import sys
from subprocess import run
from typing import TYPE_CHECKING, Final

import pytest
from typer.testing import CliRunner

import health_bridge.cli_receiver as cli_receiver_module
from health_bridge.cli import app
from health_bridge.launchd import (
    LaunchctlAdapter,
    LaunchdServiceError,
    LaunchdServiceErrorCode,
    write_launch_agent_artifacts,
)
from health_bridge.launchd.adapters import LaunchctlResult
from health_bridge.launchd.models import LAUNCH_AGENT_LABEL
from health_bridge.mailbox.connections import MailboxConnectionStore
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.transports import PublicReceiverTransport, ReceiverTransport
from tests.launchd.support import service_request

if TYPE_CHECKING:
    from pathlib import Path

ANSI_SGR_PATTERN: Final = re.compile(r"\x1b\[[0-9;]*m")


def _service_args(tmp_path: Path) -> tuple[list[str], Path, Path]:
    home = tmp_path / "synthetic-home"
    home.mkdir(mode=0o700)
    executable = home / "bin/health-bridge"
    database = home / "private/health.sqlite"
    mailbox_root = (
        home
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion"
        / "Documents/HealthBridgeMailbox/v1"
    )
    executable.parent.mkdir(parents=True)
    _ = executable.write_text("synthetic executable", encoding="utf-8")
    executable.chmod(0o700)
    database.parent.mkdir(parents=True)
    database.touch(mode=0o600)
    mailbox_root.mkdir(parents=True)
    mailbox_root.chmod(0o700)
    for path in home.rglob("*"):
        if path.is_dir():
            path.chmod(0o700)
    return (
        [
            "--executable",
            str(executable),
            "--db",
            str(database),
            "--mailbox-root",
            str(mailbox_root),
            "--icloud-container-identifier",
            "iCloud.dev.example.HealthBridgeCompanion",
        ],
        home,
        database,
    )


def test_mailbox_service_help_exposes_explicit_operator_lifecycle() -> None:
    result = CliRunner().invoke(app, ["mailbox", "service", "--help"])

    plain = ANSI_SGR_PATTERN.sub("", result.stdout)
    assert result.exit_code == 0, (result.output, result.exception)
    assert "Explicitly install" in plain
    for command in (
        "validate",
        "install",
        "upgrade",
        "status",
        "restart",
        "uninstall",
    ):
        assert command in plain


def test_upgrade_help_exposes_explicit_reconfiguration_inputs() -> None:
    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "upgrade", "--help"],
    )

    plain = ANSI_SGR_PATTERN.sub("", result.stdout)
    assert result.exit_code == 0, (result.output, result.exception)
    for option in (
        "--executable",
        "--db",
        "--mailbox-root",
        "--icloud-container-identifier",
        "--json",
    ):
        assert option in plain


def test_validate_is_linux_safe_and_does_not_install(tmp_path: Path) -> None:
    args, home, _database = _service_args(tmp_path)

    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "validate", *args, "--json"],
        env={"HOME": str(home)},
    )

    assert result.exit_code == 0
    assert json.loads(result.stdout) == {"code": "valid"}
    assert not (home / "Library/LaunchAgents").exists()
    assert not (home / "Library/Application Support/HealthBridge/launchd").exists()


def test_install_fails_closed_on_linux_without_side_effects(tmp_path: Path) -> None:
    args, home, database = _service_args(tmp_path)
    before = sorted(str(path.relative_to(home)) for path in home.rglob("*"))

    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "install", *args],
        env={"HOME": str(home)},
    )

    after = sorted(str(path.relative_to(home)) for path in home.rglob("*"))
    assert result.exit_code == 1
    assert result.stderr.strip() == ("Mailbox LaunchAgent is unavailable on this host.")
    assert after == before
    assert database.is_file()


def test_lifecycle_actions_fail_closed_on_linux_with_fixed_error() -> None:
    runner = CliRunner()
    for command in ("status", "restart", "uninstall"):
        result = runner.invoke(app, ["mailbox", "service", command])
        assert result.exit_code == 1
        assert result.stderr.strip() == (
            "Mailbox LaunchAgent is unavailable on this host."
        )


def test_status_classifies_foreign_manifest_as_drift_without_private_output(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = tmp_path / "synthetic-home"
    manifest = home / "Library/LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"
    manifest.parent.mkdir(parents=True, mode=0o700)
    manifest.parent.chmod(0o700)
    _ = manifest.write_text("foreign synthetic manifest", encoding="utf-8")
    manifest.chmod(0o600)
    monkeypatch.setattr(sys, "platform", "darwin")

    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "status", "--json"],
        env={"HOME": str(home)},
    )

    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": "manifest_drift"}
    assert str(home) not in result.output
    assert "foreign synthetic manifest" not in result.output


def test_status_json_survives_missing_obsolete_runtime_targets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    request.executable.unlink()
    request.db_path.unlink()
    request.mailbox_root.rmdir()
    monkeypatch.setattr(sys, "platform", "darwin")

    def inspect_inactive(_adapter: LaunchctlAdapter) -> LaunchctlResult:
        return LaunchctlResult(returncode=3, stdout="", stderr="")

    monkeypatch.setattr(LaunchctlAdapter, "inspect", inspect_inactive)

    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "status", "--json"],
        env={"HOME": str(request.home)},
    )

    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": "installed_inactive"}
    assert result.stderr == ""
    assert str(request.home) not in result.output


@pytest.mark.parametrize(
    "code",
    [
        LaunchdServiceErrorCode.LAUNCHCTL_TIMEOUT,
        LaunchdServiceErrorCode.LAUNCHCTL_FAILED,
    ],
)
def test_status_json_emits_fixed_launchctl_error_code(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    code: LaunchdServiceErrorCode,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    monkeypatch.setattr(sys, "platform", "darwin")

    def inspect_failure(_adapter: LaunchctlAdapter) -> LaunchctlResult:
        raise LaunchdServiceError(code)

    monkeypatch.setattr(LaunchctlAdapter, "inspect", inspect_failure)

    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "status", "--json"],
        env={"HOME": str(request.home)},
    )

    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": code.value}
    assert result.stderr == ""
    assert str(request.home) not in result.output


def test_lifecycle_json_emits_fixed_unsupported_host_code() -> None:
    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "status", "--json"],
    )

    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": "unsupported_host"}
    assert result.stderr == ""


def test_uninstall_json_rejects_partial_service_state(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = service_request(tmp_path)
    request.paths.state_dir.mkdir(parents=True, mode=0o700)
    leftover = request.paths.stdout_log
    _ = leftover.write_text("synthetic leftover", encoding="utf-8")
    leftover.chmod(0o600)
    monkeypatch.setattr(sys, "platform", "darwin")

    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "uninstall", "--json"],
        env={"HOME": str(request.home)},
    )

    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": "manifest_drift"}
    assert result.stderr == ""
    assert leftover.read_text(encoding="utf-8") == "synthetic leftover"


def test_uninstall_json_rejects_dangling_service_state_symlink(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = service_request(tmp_path)
    request.paths.state_dir.parent.mkdir(parents=True, mode=0o700)
    request.paths.state_dir.symlink_to(
        tmp_path / "missing-synthetic-state",
        target_is_directory=True,
    )
    monkeypatch.setattr(sys, "platform", "darwin")

    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "uninstall", "--json"],
        env={"HOME": str(request.home)},
    )

    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": "manifest_drift"}
    assert result.stderr == ""
    assert request.paths.state_dir.is_symlink()


def test_receiver_start_loads_owned_service_config_into_supported_runtime(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    monkeypatch.setattr(sys, "platform", "darwin")
    captured: dict[str, Path | str | int | None] = {}

    def fake_serve_receiver(  # noqa: PLR0913 -- Mirrors the receiver server API.
        db_path: Path,
        host: str,
        port: int,
        *,
        mailbox_key_store: MailboxKeyStore | None,
        mailbox_connection_store: MailboxConnectionStore | None,
        mailbox_root: Path | None,
    ) -> None:
        del mailbox_key_store, mailbox_connection_store
        captured.update(
            db_path=db_path,
            host=host,
            port=port,
            mailbox_root=mailbox_root,
        )

    def select_mailbox(
        requested: PublicReceiverTransport,
        *,
        mailbox_root: Path | None,
        icloud_container_identifier: str | None,
    ) -> ReceiverTransport:
        del requested, mailbox_root, icloud_container_identifier
        return ReceiverTransport.MAILBOX

    monkeypatch.setattr(
        cli_receiver_module,
        "_select_transport_or_exit",
        select_mailbox,
    )
    monkeypatch.setattr(
        MailboxKeyStore,
        "production",
        lambda: None,
    )
    monkeypatch.setattr(
        MailboxConnectionStore,
        "production",
        lambda: None,
    )
    monkeypatch.setattr(cli_receiver_module, "serve_receiver", fake_serve_receiver)

    result = CliRunner().invoke(
        app,
        [
            "receiver",
            "start",
            "--service-config",
            str(request.paths.config),
        ],
        env={"HOME": str(request.home)},
    )

    assert result.exit_code == 0, (result.output, result.exception)
    assert captured == {
        "db_path": request.db_path,
        "host": "127.0.0.1",
        "port": 8765,
        "mailbox_root": request.mailbox_root,
    }


def test_direct_setup_does_not_create_launch_agent_state(tmp_path: Path) -> None:
    home = tmp_path / "synthetic-home"
    database = home / "private/health.sqlite"
    setup_page = home / "private/pair.html"
    home.mkdir(mode=0o700)
    env = os.environ.copy()
    env["HOME"] = str(home)

    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "setup",
            "--receiver-url",
            "https://receiver.healthbridge.internal/v1/batches",
            "--db",
            str(database),
            "--setup-page",
            str(setup_page),
            "--transport",
            "direct",
            "--json",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert not (home / "Library/LaunchAgents").exists()
    assert not (home / "Library/Application Support/HealthBridge/launchd").exists()

from __future__ import annotations

import re
from typing import TYPE_CHECKING, Final

import pytest
from typer.testing import CliRunner

import health_bridge.cli_receiver as cli_receiver_module
from health_bridge.cli import app
from health_bridge.launchd import LaunchdServiceError, LaunchdServiceErrorCode
from health_bridge.mailbox.connections import MailboxConnectionStore
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.transports import PublicReceiverTransport, ReceiverTransport

if TYPE_CHECKING:
    from pathlib import Path

ANSI_SGR_PATTERN: Final = re.compile(r"\x1b\[[0-9;]*m")


def test_receiver_start_help_preserves_supported_options() -> None:
    result = CliRunner().invoke(app, ["receiver", "start", "--help"])

    plain = ANSI_SGR_PATTERN.sub("", result.stdout)
    assert result.exit_code == 0, (result.output, result.exception)
    for option in (
        "--db",
        "--host",
        "--port",
        "--mailbox-root",
        "--icloud-container-identifier",
        "--service-config",
    ):
        assert option in plain


def test_receiver_start_preserves_direct_defaults_and_skips_mailbox_stores(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    database = tmp_path / "health.sqlite"
    captured: dict[str, object] = {}

    def select_transport(
        requested: PublicReceiverTransport,
        *,
        mailbox_root: Path | None,
        icloud_container_identifier: str | None,
    ) -> ReceiverTransport:
        captured.update(
            requested=requested,
            selected_mailbox_root=mailbox_root,
            selected_container=icloud_container_identifier,
        )
        return ReceiverTransport.DIRECT

    def forbidden_store() -> None:
        pytest.fail("Direct receiver start must not construct mailbox stores.")

    def serve_receiver(  # noqa: PLR0913 -- Mirrors the receiver server API.
        db_path: Path,
        host: str,
        port: int,
        *,
        mailbox_key_store: MailboxKeyStore | None,
        mailbox_connection_store: MailboxConnectionStore | None,
        mailbox_root: Path | None,
    ) -> None:
        captured.update(
            db_path=db_path,
            host=host,
            port=port,
            mailbox_key_store=mailbox_key_store,
            mailbox_connection_store=mailbox_connection_store,
            mailbox_root=mailbox_root,
        )

    monkeypatch.setattr(
        cli_receiver_module, "_select_transport_or_exit", select_transport
    )
    monkeypatch.setattr(MailboxKeyStore, "production", forbidden_store)
    monkeypatch.setattr(
        MailboxConnectionStore,
        "production",
        forbidden_store,
    )
    monkeypatch.setattr(cli_receiver_module, "serve_receiver", serve_receiver)

    result = CliRunner().invoke(app, ["receiver", "start", "--db", str(database)])

    assert result.exit_code == 0, (result.output, result.exception)
    assert captured == {
        "requested": "direct",
        "selected_mailbox_root": None,
        "selected_container": None,
        "db_path": database,
        "host": "127.0.0.1",
        "port": 8765,
        "mailbox_key_store": None,
        "mailbox_connection_store": None,
        "mailbox_root": None,
    }


def test_receiver_start_requires_resolved_database() -> None:
    result = CliRunner().invoke(app, ["receiver", "start"])

    assert result.exit_code == 2
    assert result.stderr.strip() == "Receiver start requires --db."


@pytest.mark.parametrize(
    "receiver_option",
    [
        ["--db", "/private/synthetic.sqlite"],
        ["--host", "127.0.0.2"],
        ["--port", "9876"],
        ["--mailbox-root", "/private/synthetic-mailbox"],
        ["--icloud-container-identifier", "iCloud.dev.example.Synthetic"],
    ],
)
def test_receiver_start_rejects_service_config_option_conflicts_before_loading(
    receiver_option: list[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def forbidden_loader(_path: Path) -> None:
        pytest.fail("Conflicting receiver options must fail before config loading.")

    monkeypatch.setattr(
        cli_receiver_module,
        "load_runnable_launch_agent_request",
        forbidden_loader,
    )

    result = CliRunner().invoke(
        app,
        [
            "receiver",
            "start",
            "--service-config",
            "/private/synthetic-service.json",
            *receiver_option,
        ],
    )

    assert result.exit_code == 2
    assert result.stderr.strip() == (
        "Service configuration cannot be combined with receiver options."
    )


def test_receiver_start_redacts_owned_config_loader_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fail_loader(_path: Path) -> None:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_PERMISSIONS)

    monkeypatch.setattr(
        cli_receiver_module,
        "load_runnable_launch_agent_request",
        fail_loader,
    )

    result = CliRunner().invoke(
        app,
        [
            "receiver",
            "start",
            "--service-config",
            "/private/synthetic-service.json",
        ],
    )

    assert result.exit_code == 1
    assert result.stderr.strip() == (
        "Mailbox LaunchAgent artifact permissions are unsafe."
    )
    assert "/private/synthetic-service.json" not in result.output


def test_receiver_start_maps_keyboard_interrupt_to_clean_exit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    database = tmp_path / "health.sqlite"

    def select_direct(
        requested: PublicReceiverTransport,
        *,
        mailbox_root: Path | None,
        icloud_container_identifier: str | None,
    ) -> ReceiverTransport:
        del requested, mailbox_root, icloud_container_identifier
        return ReceiverTransport.DIRECT

    monkeypatch.setattr(
        cli_receiver_module,
        "_select_transport_or_exit",
        select_direct,
    )

    def interrupt_receiver(*_args: object, **_kwargs: object) -> None:
        raise KeyboardInterrupt

    monkeypatch.setattr(cli_receiver_module, "serve_receiver", interrupt_receiver)

    result = CliRunner().invoke(app, ["receiver", "start", "--db", str(database)])

    assert result.exit_code == 0, (result.output, result.exception)
    assert result.stderr.strip() == (
        "health-bridge receiver listening on http://127.0.0.1:8765"
    )

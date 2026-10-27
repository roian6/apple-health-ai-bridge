from pathlib import Path

import pytest
from typer.testing import CliRunner

import health_bridge.cli_receiver as receiver_cli
from health_bridge.cli import app
from health_bridge.mailbox.native_ack_publication import (
    NativeAckPublisher,
    NativeAckPublisherConfig,
)
from health_bridge.receiver.transports import PublicReceiverTransport, ReceiverTransport


def test_explicit_native_pairing_cli_uses_existing_private_page(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    expected_root = (
        tmp_path
        / "Library/Mobile Documents/iCloud~com~example~synthetic"
        / "Documents/HealthBridgeMailbox/v1"
    )
    expected_container = "iCloud.com.example.synthetic"

    def selected(
        requested: PublicReceiverTransport,
        *,
        mailbox_root: Path | None,
        icloud_container_identifier: str | None,
        mailbox_allowed: bool = True,
    ) -> ReceiverTransport:
        assert requested == "icloud-mailbox"
        assert mailbox_root == expected_root
        assert icloud_container_identifier == expected_container
        assert mailbox_allowed
        return ReceiverTransport.MAILBOX

    def capability(_publisher: NativeAckPublisher) -> None:
        pass

    publisher = NativeAckPublisher(
        NativeAckPublisherConfig(
            helper_executable=tmp_path / "synthetic-helper",
            protocol_root=tmp_path / "protocol",
        )
    )
    monkeypatch.setattr(receiver_cli, "_select_transport_or_exit", selected)
    monkeypatch.setattr(NativeAckPublisher, "require_native_pairing", capability)
    monkeypatch.setattr(receiver_cli, "default_native_ack_publisher", lambda: publisher)
    result = CliRunner().invoke(
        app,
        [
            "receiver",
            "create-pairing",
            "--db",
            str(tmp_path / "health.sqlite"),
            "--label",
            "synthetic",
            "--transport",
            "icloud-mailbox",
            "--mailbox-root",
            str(expected_root),
            "--icloud-container-identifier",
            expected_container,
            "--setup-page",
            str(tmp_path / "pair.html"),
        ],
    )
    assert result.exit_code == 0, result.output
    page = (tmp_path / "pair.html").read_text()
    assert "Encrypted iCloud Mailbox" in page
    assert "Use a code instead" not in page
    assert "mailbox_bootstrap" not in result.output

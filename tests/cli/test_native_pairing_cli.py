import json
import struct
from pathlib import Path

import pytest
from pydantic import TypeAdapter
from typer.testing import CliRunner

import health_bridge.cli_receiver as receiver_cli
from health_bridge.cli import app
from health_bridge.mailbox.native_ack_publication import (
    NativeAckPublicationError,
    NativeAckPublisher,
    NativeAckPublisherConfig,
)
from health_bridge.receiver.transports import PublicReceiverTransport, ReceiverTransport


def ipc_publisher(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    failure: str | None = None,
) -> tuple[NativeAckPublisher, list[str]]:
    helper = tmp_path / "synthetic-helper"
    helper.touch(mode=0o700)
    publisher = NativeAckPublisher(NativeAckPublisherConfig(helper))
    operations: list[str] = []

    def exchange(
        _publisher: NativeAckPublisher, flag: str, frame: bytes, _deadline: float
    ) -> tuple[int, bytes]:
        if flag == "--publication-ipc-v1-capabilities":
            operations.append("discovery")
            if failure == "upgrade":
                return 3, b""
            return (
                0,
                b"publication-ipc-v1:ack,pairing,receiver_capabilities,storage_probe\n",
            )
        assert flag == "--publication-ipc-v1"
        size = int.from_bytes(frame[:4], "big")
        body = TypeAdapter(dict[str, str | int]).validate_json(frame[4 : 4 + size])
        assert body["operation"] == "storage_probe"
        assert frame[4 + size :] == b""
        operations.append("storage_probe")
        response = {**body, "status": "ok", "storageReady": True}
        if failure:
            response = {**body, "status": "error", "code": failure}
        encoded = json.dumps(response, sort_keys=True, separators=(",", ":")).encode()
        return (3 if failure else 0), struct.pack(">I", len(encoded)) + encoded

    monkeypatch.setattr(NativeAckPublisher, "_exchange", exchange)
    return publisher, operations


@pytest.mark.parametrize("with_url", [False, True])
def test_explicit_native_pairing_cli_uses_existing_private_page(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, with_url: bool
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

    publisher, operations = ipc_publisher(tmp_path, monkeypatch)
    monkeypatch.setattr(receiver_cli, "_select_transport_or_exit", selected)
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
            *(
                ["--receiver-url", "https://receiver.invalid/v1/batches"]
                if with_url
                else []
            ),
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
    if not with_url:
        assert "Encrypted iCloud Mailbox" in page
        assert "Use a code instead" not in page
    assert "mailbox_bootstrap" not in result.output
    assert operations == ["discovery", "storage_probe"]


@pytest.mark.parametrize("with_url", [False, True])
@pytest.mark.parametrize(
    ("failure", "expected"),
    [
        ("storage_access_denied", "helper_container_access_denied"),
        ("upgrade", "native_helper_upgrade_required"),
    ],
)
def test_issue154_native_pairing_denied_before_invitation_creation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    with_url: bool,
    failure: str,
    expected: str,
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    publisher, _ = ipc_publisher(tmp_path, monkeypatch, failure=failure)
    monkeypatch.setattr(receiver_cli, "default_native_ack_publisher", lambda: publisher)

    def forbidden_transport(*_args: object, **_kwargs: object) -> None:
        pytest.fail("Denied protocol storage must stop before invitation setup.")

    monkeypatch.setattr(receiver_cli, "_select_transport_or_exit", forbidden_transport)
    database = tmp_path / "health.sqlite"
    result = CliRunner().invoke(
        app,
        [
            "receiver",
            "create-pairing",
            "--db",
            str(database),
            "--label",
            "synthetic",
            *(
                ["--receiver-url", "https://receiver.invalid/v1/batches"]
                if with_url
                else []
            ),
            "--transport",
            "icloud-mailbox",
            "--setup-page",
            str(tmp_path / "pair.html"),
        ],
    )
    assert result.exit_code == 1
    assert result.stderr.strip() == expected
    assert not database.exists()
    assert not (tmp_path / "pair.html").exists()


def test_direct_pairing_bypasses_native_helper(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))

    def forbidden() -> None:
        pytest.fail("Direct pairing must not inspect the Mailbox helper.")

    monkeypatch.setattr(receiver_cli, "default_native_ack_publisher", forbidden)
    page = tmp_path / "pair.html"
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
            "direct",
            "--receiver-url",
            "https://receiver.invalid/v1/batches",
            "--setup-page",
            str(page),
        ],
    )
    assert result.exit_code == 0, result.output
    assert page.is_file()


@pytest.mark.parametrize(
    ("stage", "diagnostic"),
    [
        ("readiness", "native ACK helper is not ready"),
        ("capability", "native pairing helper capability unavailable"),
    ],
)
def test_native_pairing_preserves_safe_helper_diagnostics(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    stage: str,
    diagnostic: str,
) -> None:
    publisher = NativeAckPublisher(NativeAckPublisherConfig(tmp_path / "helper"))

    def configured() -> NativeAckPublisher:
        if stage == "readiness":
            raise NativeAckPublicationError(diagnostic)
        return publisher

    def capability(_publisher: NativeAckPublisher) -> None:
        raise NativeAckPublicationError(diagnostic)

    monkeypatch.setattr(receiver_cli, "default_native_ack_publisher", configured)
    monkeypatch.setattr(NativeAckPublisher, "probe_protocol_storage", capability)
    database = tmp_path / "health.sqlite"
    result = CliRunner().invoke(
        app,
        [
            "receiver",
            "create-pairing",
            "--db",
            str(database),
            "--label",
            "synthetic",
            "--transport",
            "icloud-mailbox",
            "--setup-page",
            str(tmp_path / "pair.html"),
        ],
    )
    assert result.exit_code == 1
    assert result.stderr.strip() == diagnostic
    assert not database.exists()
    assert not (tmp_path / "protocol").exists()

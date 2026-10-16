import json
import subprocess
import sys
from pathlib import Path

import pytest
import typer

from health_bridge import cli_setup_interactive as guided
from health_bridge import connect_wizard
from health_bridge.cli_setup import (
    SetupManifest,
    SetupRequest,
    build_setup_manifest,
    configure_mcp_clients,
)
from health_bridge.connect_adapters import ADAPTERS, Adapter
from health_bridge.ingest import ingest_fixture
from health_bridge.storage.database import initialize_database


@pytest.fixture
def connection_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[Path, Path]:
    config = tmp_path / "client.json"
    _ = config.write_text('{"unrelated":{"synthetic":true}}\n')
    db = tmp_path / "synthetic.sqlite"
    initialize_database(db)

    def approve(*_args: object, **_kwargs: object) -> bool:
        return True

    monkeypatch.setattr(connect_wizard, "terminal", lambda: True)
    monkeypatch.setattr(typer, "confirm", approve)
    return config, db


@pytest.mark.parametrize(
    "status", ["app_not_detected", "app_version_unverified", "app_version_unsupported"]
)
def test_openclaw_without_verified_capability_never_changes_config(
    connection_files: tuple[Path, Path],
    monkeypatch: pytest.MonkeyPatch,
    status: str,
) -> None:
    config, db = connection_files
    before = config.read_bytes()

    def app_status(_adapter: Adapter) -> str:
        return status

    monkeypatch.setattr(connect_wizard, "inspect_app", app_status)
    _ = connect_wizard.connect_one("openclaw", db, config)
    assert config.read_bytes() == before
    assert not list(config.parent.glob("*.health-bridge-backup-*"))


def test_openclaw_lifecycle_error_from_real_child_never_changes_config(
    connection_files: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    config, db = connection_files
    before = config.read_bytes()
    binary = config.parent / "openclaw"
    script = "\n".join(
        (
            f"#!{sys.executable}",
            "import sys",
            "print('synthetic package lifecycle incomplete', file=sys.stderr)",
            "sys.exit(1)",
            "",
        )
    )
    _ = binary.write_text(script)
    binary.chmod(0o700)
    monkeypatch.setenv("PATH", str(config.parent))
    assert connect_wizard.inspect_app(ADAPTERS["openclaw"]) == "app_version_unverified"
    _ = connect_wizard.connect_one("openclaw", db, config)
    assert config.read_bytes() == before
    assert not list(config.parent.glob("*.health-bridge-backup-*"))


@pytest.mark.parametrize("failure", ["readback", "timeout"])
def test_probe_failure_keeps_saved_entry_without_success_return(
    connection_files: tuple[Path, Path],
    monkeypatch: pytest.MonkeyPatch,
    failure: str,
) -> None:
    config, db = connection_files
    before_db = db.read_bytes()

    def fail_probe(_executable: str, _args: list[str]) -> str:
        if failure == "timeout":
            command = "synthetic-probe"
            raise subprocess.TimeoutExpired(command, 20)
        message = "synthetic readback failure"
        raise ValueError(message)

    monkeypatch.setattr(connect_wizard, "probe", fail_probe)
    result = connect_wizard.connect_one("cursor", db, config)
    assert "health-bridge" in json.loads(config.read_text())["mcpServers"]
    assert json.loads(config.read_text())["unrelated"] == {"synthetic": True}
    assert db.read_bytes() == before_db
    assert result is not True


def test_wizard_does_not_promote_saved_but_failed_probe_to_verified_client(
    connection_files: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    config, db = connection_files

    def fail_probe(_executable: str, _args: list[str]) -> str:
        message = "synthetic readback failure"
        raise ValueError(message)

    def selected_path(_adapter: Adapter, _path: Path | None) -> Path:
        return config

    monkeypatch.setattr(connect_wizard, "probe", fail_probe)
    monkeypatch.setattr(connect_wizard, "effective_path", selected_path)
    verified = connect_wizard.connection_wizard(db, ("cursor",))
    assert "cursor" not in verified
    assert "health-bridge" in json.loads(config.read_text())["mcpServers"]


def failed_setup(
    connection_files: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> SetupManifest:
    config, db = connection_files
    request = SetupRequest(
        db_path=db,
        label="synthetic phone",
        receiver_url="https://receiver.healthbridge.internal/v1/batches",
        setup_page_path=db.parent / "synthetic-pairing.html",
        receiver_host="127.0.0.1",
        receiver_port=8765,
        executable="health-bridge",
    )
    manifest = build_setup_manifest(request)

    def fail_probe(_executable: str, _args: list[str]) -> str:
        message = "synthetic readback failure"
        raise ValueError(message)

    def selected_path(_adapter: Adapter, _path: Path | None) -> Path:
        return config

    monkeypatch.setattr(connect_wizard, "probe", fail_probe)
    monkeypatch.setattr(connect_wizard, "effective_path", selected_path)
    return manifest


def test_setup_records_saved_configuration_without_verification_success(
    connection_files: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = failed_setup(connection_files, monkeypatch)
    result = configure_mcp_clients(manifest, ("cursor",))
    assert result.client_configuration_status == "configuration_prepared"
    assert result.configured_mcp_clients == ["cursor"]
    config, _db = connection_files
    assert "health-bridge" in json.loads(config.read_text())["mcpServers"]


def test_setup_never_announces_saved_and_checked_after_probe_failure(
    connection_files: tuple[Path, Path],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    manifest = failed_setup(connection_files, monkeypatch).model_copy(
        update={"data_receipt_status": "received"}
    )
    _config, db = connection_files
    _ = ingest_fixture(db, Path("fixtures/health_bridge_batch_v1.synthetic.json"))

    def received(value: SetupManifest) -> SetupManifest:
        return value

    monkeypatch.setattr(guided, "follow_connection", received)
    guided.finish_interactively(manifest, ("cursor",))
    output = capsys.readouterr().out
    assert "saved and checked" not in output
    assert "server_probe_failed" in output
    assert "settings were saved" in output
    assert db.is_file()


def test_mixed_client_probes_are_not_reported_as_all_verified(
    connection_files: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = failed_setup(connection_files, monkeypatch)
    config, _db = connection_files
    second = config.parent / "claude.json"
    _ = second.write_text('{"unrelated":{"synthetic":true}}\n')
    paths = {"cursor": config, "claude-code": second}

    def selected_path(adapter: Adapter, _path: Path | None) -> Path:
        return paths[adapter.name]

    monkeypatch.setattr(connect_wizard, "effective_path", selected_path)
    calls: list[str] = []

    def mixed_probe(_executable: str, _args: list[str]) -> str:
        calls.append("probe")
        if len(calls) == 2:
            message = "synthetic second-client readback failure"
            raise ValueError(message)
        return "server_probe_verified_app_reload_or_trust_needed"

    monkeypatch.setattr(connect_wizard, "probe", mixed_probe)
    result = configure_mcp_clients(manifest, ("cursor", "claude-code"))
    assert result.client_configuration_status == "configuration_prepared"
    assert result.configured_mcp_clients == ["cursor", "claude-code"]
    assert "health-bridge" in json.loads(config.read_text())["mcpServers"]
    assert "health-bridge" in json.loads(second.read_text())["mcpServers"]

import json
from pathlib import Path

import pytest
from ruamel.yaml.error import YAMLError
from typer.testing import CliRunner

from health_bridge import connect_adapters as adapters
from health_bridge import connect_config as owner
from health_bridge import connect_wizard
from health_bridge.cli import app
from health_bridge.cli_setup import validate_requested_clients
from health_bridge.connect_probe import probe
from health_bridge.ingest import ingest_fixture
from health_bridge.storage.database import initialize_database


def test_setup_compatibility_flag_recognizes_all_adapters() -> None:
    assert validate_requested_clients(adapters.ADAPTERS) == tuple(adapters.ADAPTERS)


def test_missing_native_app_is_distinct_from_probe_success(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PATH", "")
    assert connect_wizard.inspect_app(adapters.ADAPTERS["codex"]) == "app_not_detected"


def test_null_entry_conflict_is_not_overwritten(tmp_path: Path) -> None:
    config = tmp_path / "mcp.json"
    original = '{"mcpServers":{"health-bridge":null}}'
    _ = config.write_text(original)
    adapter = adapters.ADAPTERS["cursor"]
    with pytest.raises(ValueError, match="conflict"):
        _ = owner.preview(adapter, config, adapter.entry("/stable/health-bridge", []))
    assert config.read_text() == original


def test_yaml_comment_only_file_is_preserved(tmp_path: Path) -> None:
    config = tmp_path / "config.yaml"
    original = "# retained synthetic comment\n"
    _ = config.write_text(original)
    adapter = adapters.ADAPTERS["hermes"]
    change = owner.preview(adapter, config, adapter.entry("/stable/health-bridge", []))
    _ = owner.apply(change)
    assert config.read_text().startswith(original)


def test_yaml_alias_cannot_modify_an_unrelated_mapping(tmp_path: Path) -> None:
    config = tmp_path / "config.yaml"
    original = "shared: &shared\n  other: {command: fixture}\nmcp_servers: *shared\n"
    _ = config.write_text(original)
    adapter = adapters.ADAPTERS["hermes"]
    with pytest.raises(ValueError, match="alias"):
        _ = owner.preview(adapter, config, adapter.entry("/stable/health-bridge", []))
    assert config.read_text() == original


def test_invalid_yaml_render_never_replaces_existing_file(tmp_path: Path) -> None:
    config = tmp_path / "config.yaml"
    original = "null\n"
    _ = config.write_text(original)
    adapter = adapters.ADAPTERS["hermes"]
    change = owner.preview(adapter, config, adapter.entry("/stable/health-bridge", []))
    with pytest.raises(YAMLError):
        _ = owner.apply(change)
    assert config.read_text() == original


def test_duplicate_json_containers_are_refused(tmp_path: Path) -> None:
    config = tmp_path / "mcp.json"
    original = '{"mcpServers":{},"mcpServers":{"other":{"command":"fixture"}}}'
    _ = config.write_text(original)
    adapter = adapters.ADAPTERS["cursor"]
    with pytest.raises(ValueError, match="Duplicate"):
        _ = owner.preview(adapter, config, adapter.entry("/stable/health-bridge", []))
    assert config.read_text() == original


def test_cancel_connect_preserves_config_and_installation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    config = tmp_path / "mcp.json"
    original = '{"mcpServers":{"unrelated":{"command":"fixture"}}}'
    _ = config.write_text(original)
    db = tmp_path / "health.sqlite"
    initialize_database(db)
    before = db.read_bytes()
    monkeypatch.setattr(connect_wizard, "terminal", lambda: True)
    result = CliRunner().invoke(
        app,
        ["connect", "--client", "cursor", "--config", str(config), "--db", str(db)],
        input="n\n",
    )
    assert result.exit_code == 0, result.output
    assert config.read_text() == original
    assert db.read_bytes() == before
    assert not list(tmp_path.glob("*.health-bridge-backup-*"))


def test_stdio_probe_reads_synthetic_stored_record_without_mutation(
    tmp_path: Path,
) -> None:
    db = tmp_path / "health.sqlite"
    fixture = (
        Path(__file__).parents[2] / "fixtures/health_bridge_batch_v1.synthetic.json"
    )
    _ = ingest_fixture(db, fixture)
    before = db.read_bytes()
    status = probe(
        connect_wizard.stable_executable(), ["mcp", "start", "--db", str(db)]
    )
    assert status == "server_probe_verified_app_reload_or_trust_needed"
    assert db.read_bytes() == before


def test_connect_redirected_input_is_preview_only(tmp_path: Path) -> None:
    config = tmp_path / "cursor.json"
    result = CliRunner().invoke(
        app,
        [
            "connect",
            "--client",
            "cursor",
            "--config",
            str(config),
            "--db",
            str(tmp_path / "health.sqlite"),
        ],
        input="y\n",
    )
    assert result.exit_code == 0, result.output
    assert not config.exists()
    assert "preview" in result.output.lower()


def test_invalid_client_config_never_prints_unrelated_values(tmp_path: Path) -> None:
    config = tmp_path / "mcp.json"
    _ = config.write_text('{"unrelatedCredential":"synthetic-sensitive-marker", BROKEN')
    result = CliRunner().invoke(
        app,
        [
            "connect",
            "--client",
            "cursor",
            "--config",
            str(config),
            "--db",
            str(tmp_path / "health.sqlite"),
        ],
    )
    assert result.exit_code != 0
    assert "synthetic-sensitive-marker" not in result.output
    assert "unrelatedCredential" not in result.output


@pytest.mark.parametrize(
    "client",
    [
        "codex",
        "claude-code",
        "opencode",
        "hermes",
        "openclaw",
        "claude-desktop",
        "cursor",
        "vscode",
    ],
)
def test_each_adapter_preserves_unrelated_config_and_repeats(
    client: str, tmp_path: Path
) -> None:
    adapter = adapters.ADAPTERS[client]
    config = tmp_path / ("config." + adapter.format)
    originals = {
        "toml": '# keep\nmodel = "synthetic"\n',
        "yaml": "# keep\nmodel: synthetic\n",
        "jsonc": '{\n// keep\n"unrelated": {"fixture": true},\n}\n',
        "json": '{"unrelated":{"fixture":true}}\n',
    }
    original = originals[adapter.format]
    _ = config.write_text(original)
    entry = adapter.entry(
        "/stable/health-bridge", ["mcp", "start", "--db", "/synthetic/health.sqlite"]
    )
    plan = owner.preview(adapter, config, entry)
    assert config.read_text() == original
    result = owner.apply(plan)
    assert result == "configuration_prepared"
    assert (
        owner.preview(adapter, config, entry).before
        == owner.preview(adapter, config, entry).after
    )
    assert len(list(tmp_path.glob("*.health-bridge-backup-*"))) == 1
    assert (
        "keep" in config.read_text()
        if adapter.format != "json"
        else "unrelated" in config.read_text()
    )
    assert owner.apply(owner.preview(adapter, config, entry)) == "already_prepared"


def test_config_collision_and_concurrent_edit_leave_files_unchanged(
    tmp_path: Path,
) -> None:
    adapter = adapters.ADAPTERS["cursor"]
    config = tmp_path / "mcp.json"
    _ = config.write_text('{"mcpServers":{"health-bridge":{"command":"other"}}}')
    with pytest.raises(ValueError, match="conflict"):
        _ = owner.preview(adapter, config, adapter.entry("/stable/health-bridge", []))
    _ = config.write_text("{}")
    plan = owner.preview(adapter, config, adapter.entry("/stable/health-bridge", []))
    _ = config.write_text('{"concurrent":true}')
    with pytest.raises(ValueError, match="changed"):
        _ = owner.apply(plan)
    assert json.loads(config.read_text()) == {"concurrent": True}

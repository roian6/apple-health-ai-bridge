import ipaddress
import os
import re
import shutil
import stat
from pathlib import Path
from subprocess import CompletedProcess, run
from typing import ClassVar, Literal

import pytest
from pydantic import BaseModel, ConfigDict

import health_bridge.cli_setup as cli_setup_module


class AccessDescriptorOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    id: str
    protocol: Literal["mcp"]
    transport: Literal["stdio"]
    command: str
    args: list[str]
    cwd: str | None
    env_refs: dict[str, str]


class RegistrarPlanOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    name: str
    detected: bool
    add_command: list[str]
    verify_command: list[str]


class SetupCliOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    schema_id: Literal["health_bridge.onboarding"]
    schema_version: Literal[2]
    db: str
    receiver_url: str
    receiver_health_url: str
    setup_page: str
    pairing_schema_id: str
    invitation_expires_at: str
    receiver_start_command: list[str]
    access_descriptors: list[AccessDescriptorOutput]
    local_mcp_self_test_command: list[str]
    local_mcp_status: Literal["prepared", "verified"]
    registrar_plans: list[RegistrarPlanOutput]
    detected_mcp_clients: list[str]
    configured_mcp_clients: list[str]
    client_configuration_status: Literal["not_requested", "configured_and_verified"]
    next_steps: list[str]
    warning: str


def _assert_owner_only(path: Path) -> None:
    assert stat.S_IMODE(path.stat().st_mode) & 0o077 == 0


def _run_cli(*args: str, env: dict[str, str] | None = None) -> CompletedProcess[str]:
    return run(
        ["health-bridge", *args],
        capture_output=True,
        check=False,
        text=True,
        env=env,
    )


def _write_fake_client(bin_dir: Path, name: str, log_path: Path) -> None:
    executable = bin_dir / name
    _ = executable.write_text(
        '#!/bin/sh\nprintf \'%s\\n\' "$0|$*" >> "$HEALTH_BRIDGE_CLIENT_LOG"\n',
        encoding="utf-8",
    )
    executable.chmod(0o700)
    assert log_path.parent.exists()


def _client_env(tmp_path: Path, *names: str) -> tuple[dict[str, str], Path]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log_path = tmp_path / "client.log"
    for name in names:
        _write_fake_client(bin_dir, name, log_path)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["HEALTH_BRIDGE_CLIENT_LOG"] = str(log_path)
    return env, log_path


def _setup_args(tmp_path: Path) -> tuple[Path, Path, list[str]]:
    db_path = tmp_path / "private" / "health.sqlite"
    setup_page = tmp_path / "private" / "pair.html"
    return (
        db_path,
        setup_page,
        [
            "setup",
            "--receiver-url",
            "https://receiver.healthbridge.internal/v1/batches",
            "--db",
            str(db_path),
            "--setup-page",
            str(setup_page),
            "--json",
        ],
    )


def test_setup_default_detects_but_never_configures_clients(tmp_path: Path) -> None:
    env, log_path = _client_env(tmp_path, "hermes")
    db_path, setup_page, args = _setup_args(tmp_path)

    completed = _run_cli(*args, env=env)

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.schema_version == 2
    assert payload.db == str(db_path)
    assert payload.receiver_url == ("https://receiver.healthbridge.internal/v1/batches")
    assert payload.receiver_health_url == (
        "https://receiver.healthbridge.internal/health"
    )
    assert payload.receiver_start_command[-4:] == [
        "--host",
        "127.0.0.1",
        "--port",
        "8765",
    ]
    assert payload.local_mcp_status == "verified"
    assert payload.detected_mcp_clients == ["hermes"]
    assert payload.configured_mcp_clients == []
    assert payload.client_configuration_status == "not_requested"
    pairing_handoff = payload.next_steps[1]
    assert "receiver computer" in pairing_handoff
    assert "trusted screen" in pairing_handoff
    assert "iPhone Camera" in pairing_handoff
    assert "Open setup_page on the iPhone" not in pairing_handoff
    assert not log_path.exists()

    access = payload.access_descriptors[0]
    assert access.protocol == "mcp"
    assert access.transport == "stdio"
    assert access.args == ["mcp", "start", "--db", str(db_path)]
    assert access.cwd is None
    assert access.env_refs == {}

    assert db_path.is_file()
    assert setup_page.is_file()
    _assert_owner_only(db_path.parent)
    _assert_owner_only(db_path)
    _assert_owner_only(setup_page)
    setup_html = setup_page.read_text(encoding="utf-8")
    assert "healthbridge://pair?payload=" in setup_html
    assert "invitation_token" not in completed.stdout
    assert not re.search(r"hbi_[A-Za-z0-9_-]{20,}", completed.stdout)


def test_setup_configures_only_explicitly_selected_client(tmp_path: Path) -> None:
    env, log_path = _client_env(tmp_path, "hermes", "openclaw")
    _db_path, _setup_page, args = _setup_args(tmp_path)

    completed = _run_cli(
        *args,
        "--configure-client",
        "hermes",
        env=env,
    )

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.detected_mcp_clients == ["hermes", "openclaw"]
    assert payload.configured_mcp_clients == ["hermes"]
    assert payload.client_configuration_status == "configured_and_verified"
    logged = log_path.read_text(encoding="utf-8").splitlines()
    assert len(logged) == 2
    assert "hermes|mcp add health-bridge --command" in logged[0]
    assert "hermes|mcp test health-bridge" in logged[1]
    assert all("openclaw" not in line for line in logged)


def test_setup_accepts_repeated_explicit_client_configuration(tmp_path: Path) -> None:
    env, log_path = _client_env(tmp_path, "hermes", "openclaw")
    _db_path, _setup_page, args = _setup_args(tmp_path)

    completed = _run_cli(
        *args,
        "--configure-client",
        "hermes",
        "--configure-client",
        "openclaw",
        env=env,
    )

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.configured_mcp_clients == ["hermes", "openclaw"]
    logged = log_path.read_text(encoding="utf-8").splitlines()
    assert len(logged) == 4
    assert any("openclaw|mcp add health-bridge" in line for line in logged)
    assert any("openclaw|mcp probe health-bridge" in line for line in logged)


def test_unknown_client_is_rejected_before_core_side_effects(tmp_path: Path) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)

    completed = _run_cli(*args, "--configure-client", "cursor")

    assert completed.returncode == 1
    assert "No built-in registrar for: cursor" in completed.stderr
    assert "local stdio MCP" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()


def test_missing_explicit_client_cli_is_rejected_before_core_side_effects(
    tmp_path: Path,
) -> None:
    env = os.environ.copy()
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    health_bridge = shutil.which("health-bridge")
    assert health_bridge is not None
    env["PATH"] = f"{Path(health_bridge).parent}{os.pathsep}{empty_bin}"
    db_path, setup_page, args = _setup_args(tmp_path)

    completed = _run_cli(*args, "--configure-client", "openclaw", env=env)

    assert completed.returncode == 1
    assert "Requested MCP client CLI is not installed: openclaw" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()


def test_setup_human_output_states_that_configuration_is_not_automatic(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    args.remove("--json")

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    assert "Health Bridge core setup prepared." in completed.stdout
    assert "no configuration is automatic" in completed.stdout
    assert "Private pairing page (open on the receiver computer)" in completed.stdout
    assert "trusted screen" in completed.stdout
    assert "iPhone Camera" in completed.stdout
    assert "Open setup_page on the iPhone" not in completed.stdout
    assert str(db_path) not in completed.stdout
    assert str(setup_page) in completed.stdout


def test_setup_page_contains_custom_scheme_qr_and_manual_code(
    tmp_path: Path,
) -> None:
    _db_path, setup_page, args = _setup_args(tmp_path)

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    setup_html = setup_page.read_text(encoding="utf-8")
    assert 'href="healthbridge://pair?payload=' in setup_html
    assert "Scan with iPhone Camera" in setup_html
    assert "Use a code instead" in setup_html
    assert "temporary, single-use invitation" in setup_html


@pytest.mark.parametrize(
    "loopback_url",
    [
        "http://127.0.0.1:8765/v1/batches",
        "https://127.1/v1/batches",
        "https://127.0.1/v1/batches",
        "https://2130706433/v1/batches",
        "https://0x7f000001/v1/batches",
        "https://0177.0.0.1/v1/batches",
        "https://receiver.localhost/v1/batches",
        "https://deep.receiver.localhost.localdomain/v1/batches",
    ],
)
def test_setup_rejects_phone_loopback_url_before_private_side_effects(
    tmp_path: Path,
    loopback_url: str,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    args[args.index("--receiver-url") + 1] = loopback_url

    completed = _run_cli(*args)

    assert completed.returncode == 1
    assert "loopback" in completed.stderr.lower()
    assert "iPhone" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()


@pytest.mark.parametrize(
    "receiver_url",
    [
        "https://your-private-host.example/v1/batches",
        "https://receiver.example/v1/batches",
        "https://receiver.example.com/v1/batches",
        "https://receiver.example.net/v1/batches",
        "https://receiver.example.org/v1/batches",
        "https://receiver.invalid/v1/batches",
        "https://receiver.test/v1/batches",
    ],
)
def test_setup_rejects_documentation_hosts_before_private_side_effects(
    tmp_path: Path,
    receiver_url: str,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    args[args.index("--receiver-url") + 1] = receiver_url

    completed = _run_cli(*args)

    assert completed.returncode == 1
    assert "documentation or testing hostname" in completed.stderr
    assert "docs/setup.md" in completed.stderr
    assert not db_path.parent.exists()
    assert not db_path.exists()
    assert not setup_page.exists()


def test_setup_accepts_real_hostname_with_documentation_like_prefix(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    args[args.index("--receiver-url") + 1] = (
        "https://your-private-host.company/v1/batches"
    )

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    assert db_path.is_file()
    assert setup_page.is_file()


def test_setup_rejects_unusable_numeric_destinations_before_side_effects(
    tmp_path: Path,
) -> None:
    urls = (
        "http://0.0.0.0:8765/v1/batches",
        "http://0.1.2.3:8765/v1/batches",
        "http://192.0.2.1:8765/v1/batches",
        "http://198.51.100.1:8765/v1/batches",
        "http://203.0.113.1:8765/v1/batches",
        "http://[::]:8765/v1/batches",
        "http://[2001:db8::1]:8765/v1/batches",
        "http://224.0.0.1:8765/v1/batches",
        "http://[ff02::1]:8765/v1/batches",
        "http://255.255.255.255:8765/v1/batches",
    )
    for index, receiver_url in enumerate(urls):
        case_path = tmp_path / str(index)
        db_path, setup_page, args = _setup_args(case_path)
        args[args.index("--receiver-url") + 1] = receiver_url

        completed = _run_cli(*args)

        assert completed.returncode == 1
        assert "reachable unicast" in completed.stderr
        assert not db_path.exists()
        assert not setup_page.exists()


def test_setup_rejects_direct_lan_url_with_loopback_only_bind(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    args[args.index("--receiver-url") + 1] = (
        "http://health-bridge.local:8765/v1/batches"
    )

    completed = _run_cli(*args)

    assert completed.returncode == 1
    assert "--receiver-host" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()


def test_setup_accepts_numeric_lan_url_with_reachable_bind_and_guidance(
    tmp_path: Path,
) -> None:
    _db_path, _setup_page, args = _setup_args(tmp_path)
    private_host = ".".join(("192", "168", "50", "9"))  # noqa: FLY002
    args[args.index("--receiver-url") + 1] = f"http://{private_host}:8765/v1/batches"
    args.extend(("--receiver-host", "0.0.0.0"))  # noqa: S104 - test bind input
    args.append("--allow-nonlocal-receiver-address")

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.receiver_url == f"http://{private_host}:8765/v1/batches"
    assert "Numeric LAN addresses are supported" in payload.warning
    assert "Local Network access" in payload.warning


def test_setup_accepts_plain_http_shared_address_with_compatibility_warning(
    tmp_path: Path,
) -> None:
    _db_path, _setup_page, args = _setup_args(tmp_path)
    shared_host = ".".join(("100", "100", "50", "9"))  # noqa: FLY002
    args[args.index("--receiver-url") + 1] = f"http://{shared_host}:8765/v1/batches"
    args.extend(("--receiver-host", "0.0.0.0"))  # noqa: S104 - test bind input
    args.append("--allow-nonlocal-receiver-address")

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.receiver_url == f"http://{shared_host}:8765/v1/batches"
    assert "shared address space" in payload.warning
    assert "may reject plain HTTP" in payload.warning
    assert "HTTPS/MagicDNS" in payload.warning


def test_setup_rejects_nonlocal_numeric_http_receiver_before_side_effects(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    private_host = ".".join(("10", "0", "0", "104"))  # noqa: FLY002
    args[args.index("--receiver-url") + 1] = f"http://{private_host}:8765/v1/batches"
    args.extend(("--receiver-host", "0.0.0.0"))  # noqa: S104 - test bind input

    completed = _run_cli(*args)

    assert completed.returncode == 1
    assert "not assigned to this receiver host" in completed.stderr
    assert "--allow-nonlocal-receiver-address" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()


def test_setup_rejects_nonlocal_public_numeric_http_receiver(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    public_host = ".".join(("8", "8", "8", "8"))  # noqa: FLY002
    args[args.index("--receiver-url") + 1] = f"http://{public_host}:8765/v1/batches"
    args.extend(("--receiver-host", "0.0.0.0"))  # noqa: S104 - test bind input

    completed = _run_cli(*args)

    assert completed.returncode == 1
    assert "not assigned to this receiver host" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()


def test_numeric_address_ownership_uses_interface_inventory(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assigned = ipaddress.ip_address(
        ".".join(("192", "168", "10", "4"))  # noqa: FLY002
    )
    nonlocal_address = ipaddress.ip_address(
        ".".join(("192", "168", "10", "5"))  # noqa: FLY002
    )
    monkeypatch.setattr(
        cli_setup_module,
        "_local_interface_addresses",
        lambda: frozenset({assigned}),
    )
    assert cli_setup_module._is_locally_assigned_ip(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
        str(assigned)
    )
    assert not cli_setup_module._is_locally_assigned_ip(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
        str(nonlocal_address)
    )


def test_interface_inventory_does_not_merge_resolver_or_fallback_addresses(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assigned = ipaddress.ip_address(
        ".".join(("198", "51", "100", "7"))  # noqa: FLY002
    )
    fallback_only = ipaddress.ip_address(
        ".".join(("203", "0", "113", "9"))  # noqa: FLY002
    )
    monkeypatch.setattr(
        cli_setup_module,
        "_ip_command_addresses",
        lambda: {assigned},
    )
    monkeypatch.setattr(
        cli_setup_module,
        "_ifconfig_addresses",
        lambda: {fallback_only},
    )

    assert cli_setup_module._local_interface_addresses() == frozenset(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
        {assigned}
    )
    assert not hasattr(cli_setup_module, "_hostname_addresses")


def test_numeric_address_ownership_fails_closed_without_interface_inventory(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    candidate = ".".join(("203", "0", "113", "9"))  # noqa: FLY002
    monkeypatch.setattr(cli_setup_module, "_ip_command_addresses", set)
    monkeypatch.setattr(cli_setup_module, "_ifconfig_addresses", set)

    assert not cli_setup_module._is_locally_assigned_ip(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
        candidate
    )


def test_setup_rejects_direct_http_url_with_different_receiver_port(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    private_host = ".".join(("192", "168", "50", "9"))  # noqa: FLY002
    args[args.index("--receiver-url") + 1] = f"http://{private_host}:9999/v1/batches"
    args.extend(("--receiver-host", "0.0.0.0"))  # noqa: S104 - test bind input

    completed = _run_cli(*args)

    assert completed.returncode == 1
    assert "port" in completed.stderr.lower()
    assert "--receiver-port" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()


def test_setup_accepts_matching_custom_direct_http_port(tmp_path: Path) -> None:
    _db_path, _setup_page, args = _setup_args(tmp_path)
    private_host = ".".join(("192", "168", "50", "9"))  # noqa: FLY002
    args[args.index("--receiver-url") + 1] = f"http://{private_host}:9999/v1/batches"
    args.extend(
        (
            "--receiver-host",
            "0.0.0.0",  # noqa: S104 - test bind input
            "--receiver-port",
            "9999",
            "--allow-nonlocal-receiver-address",
        )
    )

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.receiver_start_command[-1] == "9999"


def test_setup_rejects_explicit_zero_url_port_before_private_side_effects(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    private_host = ".".join(("192", "168", "50", "9"))  # noqa: FLY002
    args[args.index("--receiver-url") + 1] = f"http://{private_host}:0/v1/batches"
    args.extend(
        (
            "--receiver-host",
            "0.0.0.0",  # noqa: S104 - test bind input
            "--receiver-port",
            "80",
        )
    )

    completed = _run_cli(*args)

    assert completed.returncode == 1
    assert "invalid port" in completed.stderr.lower()
    assert not db_path.exists()
    assert not setup_page.exists()


def test_setup_rejects_zero_receiver_bind_port_before_private_side_effects(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    args.extend(("--receiver-port", "0"))

    completed = _run_cli(*args)

    assert completed.returncode == 2
    assert "65535" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()

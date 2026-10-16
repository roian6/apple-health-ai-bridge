import ipaddress
import json
import multiprocessing
import os
import plistlib
import re
import shlex
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
from collections.abc import Iterator
from dataclasses import replace
from multiprocessing.connection import Connection
from pathlib import Path
from subprocess import CompletedProcess, run
from threading import Thread
from types import SimpleNamespace
from typing import ClassVar, Literal, cast
from urllib.request import Request

import pytest
from pydantic import BaseModel, ConfigDict, JsonValue, TypeAdapter
from typer.testing import CliRunner

import health_bridge.cli_setup as cli_setup_module
from health_bridge import __version__, cli_setup_runtime
from health_bridge import cli as cli_module
from health_bridge.cli import app
from health_bridge.cli_setup_runtime import run_control as native_run_control
from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.launchd.artifacts import (
    load_owned_launch_agent_request,
    load_runnable_launch_agent_request,
)
from health_bridge.launchd.models import LaunchdServiceRequest, service_paths
from health_bridge.mailbox.helper_lifecycle import HelperResult, HelperStatusCode
from health_bridge.receiver import transports
from health_bridge.receiver.invitations import redeem_pairing_invitation
from health_bridge.receiver.pairing_setup_page import (
    invitation_page_route,
    read_invitation_page,
)
from health_bridge.receiver.server import ReceiverHTTPServer, build_receiver_server
from tests.receiver.test_pairing_redeem_server import open_http_response
from tests.receiver.test_receiver_source_binding import post_batch, with_source_key

TEST_PRIVATE_BIND_HOST = ".".join(("192", "168", "50", "9"))  # noqa: FLY002


def ready_setup_helper(*, home: Path, expected_version: str) -> HelperResult:
    assert home == Path.home()
    assert expected_version == __version__
    return HelperResult(code=HelperStatusCode.READY)


@pytest.fixture(autouse=True)
def isolated_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv(
        "PATH", f"{Path(sys.executable).parent}{os.pathsep}{os.environ['PATH']}"
    )
    executable = home / "bin/health-bridge"
    executable.parent.mkdir(mode=0o700)
    _ = executable.write_bytes(
        (Path(sys.executable).parent / "health-bridge").read_bytes()
    )
    executable.chmod(0o700)
    monkeypatch.setattr(sys, "argv", [str(executable)])


def mac_control(
    command: list[str], servers: list[ReceiverHTTPServer], threads: list[Thread]
) -> CompletedProcess[str]:
    manifest = (
        Path.home() / "Library/LaunchAgents" / f"{command[-1].rsplit('/', 1)[-1]}.plist"
    )
    if command[1] == "print":
        return CompletedProcess(
            command,
            0 if servers else 113,
            f"path = {manifest}\nstate = running\npid = 12345\n" if servers else "",
            "",
        )
    assert command[1] == "bootstrap"
    document = TypeAdapter(dict[str, JsonValue]).validate_python(
        plistlib.loads(Path(command[-1]).read_bytes())
    )
    arguments = TypeAdapter(list[str]).validate_python(document["ProgramArguments"])
    request = load_runnable_launch_agent_request(Path(arguments[-1]))
    server = build_receiver_server(
        request.db_path,
        host=request.host,
        port=request.port,
        setup_page=request.setup_page,
    )
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    servers.append(server)
    threads.append(thread)
    return CompletedProcess(command, 0, "", "")


@pytest.fixture(autouse=True)
def control_plane(monkeypatch: pytest.MonkeyPatch) -> Iterator[list[list[str]]]:
    calls: list[list[str]] = []
    servers: list[ReceiverHTTPServer] = []
    threads: list[Thread] = []
    serve: dict[str, JsonValue] = {}

    def control(
        command: list[str],
        *,
        capture_output: bool,
        text: bool,
        timeout: float,
        check: bool,
    ) -> CompletedProcess[str]:
        if command[0] not in {"systemctl", "tailscale"}:
            if command[0] != "/bin/launchctl":
                return run(
                    command,
                    capture_output=capture_output,
                    text=text,
                    timeout=timeout,
                    check=check,
                )
            calls.append(command)
            return mac_control(command, servers, threads)
        calls.append(command)
        output = ""
        if command[:3] == ["tailscale", "status", "--json"]:
            output = json.dumps(
                {
                    "BackendState": "Running",
                    "Self": {"DNSName": "synthetic.tailnet.ts.net."},
                }
            )
        elif command[:3] == ["tailscale", "serve", "status"]:
            output = json.dumps(serve)
        elif command[:3] == ["tailscale", "serve", "--bg"]:
            port = command[3].split("=")[1]
            serve.update(
                {
                    "TCP": {port: {"HTTPS": True}},
                    "Web": {
                        f"synthetic.tailnet.ts.net:{port}": {
                            "Handlers": {"/": {"Proxy": command[-1]}}
                        }
                    },
                }
            )
        elif "show" in command:
            unit = Path.home() / ".config/systemd/user" / command[-1]
            output = (
                f"FragmentPath={unit if unit.exists() else ''}\nDropInPaths=\n"
                f"LoadState={'loaded' if unit.exists() else 'not-found'}\n"
            )
        elif "start" in command:
            unit = Path.home() / ".config/systemd/user" / command[-1]
            line = next(
                line
                for line in unit.read_text().splitlines()
                if line.startswith("ExecStart=")
            )
            argv = shlex.split(line.removeprefix("ExecStart="))
            server = build_receiver_server(
                Path(argv[argv.index("--db") + 1]),
                host="127.0.0.1",
                port=int(argv[argv.index("--port") + 1]),
                setup_page=Path(argv[argv.index("--setup-page") + 1]),
            )
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            servers.append(server)
            threads.append(thread)
        code = (
            int(not servers)
            if any(part in command for part in ("is-active", "is-enabled"))
            else 0
        )
        return CompletedProcess(command, code, output, "")

    monkeypatch.setattr(subprocess, "run", control)
    yield calls
    for server, thread in zip(servers, threads, strict=True):
        server.shutdown()
        server.server_close()
        thread.join()


def unused_receiver_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return TypeAdapter(tuple[str, int]).validate_python(listener.getsockname())[1]


def test_mac_control_uses_installed_tailscale_app_without_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sys, "platform", "darwin")
    binary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    def which(_: str) -> None:
        return None

    def is_file(path: Path) -> bool:
        return str(path) == binary

    monkeypatch.setattr(shutil, "which", which)
    monkeypatch.setattr(Path, "is_file", is_file)
    commands: list[list[str]] = []

    def run(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        commands.append(argv)
        return subprocess.CompletedProcess(argv, 0, "{}", "")

    monkeypatch.setattr(subprocess, "run", run)
    assert native_run_control(["tailscale", "status", "--json"]).returncode == 0
    assert commands == [[binary, "status", "--json"]]


def test_setup_m2_unit_passes_native_systemd_validation(tmp_path: Path) -> None:
    if sys.platform != "linux" or shutil.which("systemd-analyze") is None:
        pytest.skip("Native systemd validator is unavailable on this platform")
    _, _, args = _setup_args(tmp_path)
    assert _run_cli(*args).returncode == 0
    unit = Path.home() / ".config/systemd/user/health-bridge-receiver.service"
    result = run(
        ["systemd-analyze", "--user", "verify", str(unit)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_setup_m2_rerun_accepts_systemd_link_to_owned_unit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _, _, args = _setup_args(tmp_path)
    assert _run_cli(*args).returncode == 0
    unit = Path.home() / ".config/systemd/user/health-bridge-receiver.service"
    alias = Path.home() / "manager-linked.service"
    alias.symlink_to(unit)
    original = cli_setup_runtime.run_control

    def linked_fragment(command: list[str]) -> CompletedProcess[str]:
        result = original(command)
        if "show" in command:
            result.stdout = result.stdout.replace(
                f"FragmentPath={unit}", f"FragmentPath={alias}"
            )
        return result

    monkeypatch.setattr(cli_setup_runtime, "run_control", linked_fragment)
    result = _run_cli(*args)
    assert result.returncode == 0, result.stderr


def test_setup_explicit_unsupported_host_preserves_preparation_flow(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, control_plane: list[list[str]]
) -> None:
    monkeypatch.setattr(sys, "platform", "freebsd")
    _, _, args = _setup_args(tmp_path)
    result = _run_cli(*args)
    assert result.returncode == 0, result.stderr
    assert (
        SetupCliOutput.model_validate_json(result.stdout).receiver_service_status
        == "prepared"
    )
    assert not control_plane


@pytest.mark.parametrize("platform", ["linux", "darwin"])
def test_setup_m2_discovers_route_and_starts_supervised_receiver(
    tmp_path: Path,
    control_plane: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    platform: str,
) -> None:
    platform_context = SimpleNamespace(platform=platform, argv=sys.argv)
    monkeypatch.setattr(cli_module, "sys", platform_context)
    monkeypatch.setattr(cli_setup_runtime, "sys", platform_context)
    _, _, args = _setup_args(tmp_path)
    del args[1:3]
    result = _run_cli(*args)
    assert result.returncode == 0, result.stderr
    payload = SetupCliOutput.model_validate_json(result.stdout)
    assert payload.receiver_service_status == "supervised_healthy"
    assert payload.private_route_status == "ready"
    assert payload.pairing_status == "pending"
    assert payload.data_receipt_status == "not_received"
    assert payload.receiver_url.startswith("https://synthetic.tailnet.ts.net")
    assert any("enable" in call or "bootstrap" in call for call in control_plane)
    assert any("start" in call or "bootstrap" in call for call in control_plane)
    original_page = Path(payload.setup_page).read_bytes()
    control_plane.clear()
    rerun = _run_cli(*args)
    assert rerun.returncode == 0, rerun.stderr
    assert Path(payload.setup_page).read_bytes() == original_page
    assert not any(
        any(
            action in call
            for action in ("start", "--bg", "bootstrap", "kickstart", "bootout")
        )
        for call in control_plane
    )


def test_setup_explicit_mac_direct_starts_owned_service(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, control_plane: list[list[str]]
) -> None:
    platform_context = SimpleNamespace(platform="darwin", argv=sys.argv)
    monkeypatch.setattr(cli_module, "sys", platform_context)
    monkeypatch.setattr(cli_setup_runtime, "sys", platform_context)
    _, page, args = _setup_args(tmp_path)
    result = _run_cli(*args, "--service-name", "health-bridge-qa")
    assert result.returncode == 0, result.stderr
    assert (
        SetupCliOutput.model_validate_json(result.stdout).receiver_service_status
        == "supervised_healthy"
    )
    original = page.read_bytes()
    control_plane.clear()
    result = _run_cli(*args, "--service-name", "health-bridge-qa")
    assert result.returncode == 0, result.stderr
    assert page.read_bytes() == original
    assert all(call[1] == "print" for call in control_plane)
    args[args.index("--receiver-port") + 1] = str(unused_receiver_port())
    result = _run_cli(*args, "--service-name", "health-bridge-other")
    assert result.returncode == 1
    assert "another owned LaunchAgent" in result.stderr
    assert all(call[1] == "print" for call in control_plane)


def _overlapping_mac_setup(
    request: cli_setup_module.SetupRequest, channel: Connection, pause: bool
) -> None:
    real_scan = cli_setup_runtime.require_unique_agent_database
    service_name = "health-bridge-race-a" if pause else "health-bridge-race-b"
    bootstrapped: list[str] = []

    def scan(agent: LaunchdServiceRequest) -> None:
        real_scan(agent)
        channel.send_bytes(b"scanned")
        assert channel.poll(20), "parent did not release ownership scan"
        assert channel.recv_bytes() == b"release"

    def control(command: list[str], **_kwargs: JsonValue) -> CompletedProcess[str]:
        assert command[0] == "/bin/launchctl"
        if command[1] == "print":
            return CompletedProcess(command, 113, "", "")
        assert command[1] == "bootstrap"
        document = TypeAdapter(dict[str, JsonValue]).validate_python(
            plistlib.loads(Path(command[-1]).read_bytes())
        )
        arguments = TypeAdapter(list[str]).validate_python(document["ProgramArguments"])
        owned = load_runnable_launch_agent_request(Path(arguments[-1]))
        assert owned.db_path == request.db_path
        bootstrapped.append(owned.label)
        return CompletedProcess(command, 0, "", "")

    with channel, pytest.MonkeyPatch.context() as patch:
        patch.setattr(subprocess, "run", control)
        if pause:
            patch.setattr(cli_setup_runtime, "require_unique_agent_database", scan)
        try:
            _ = cli_setup_runtime.start_mac_agent(request, service_name)
        except (ValueError, RuntimeError) as exc:
            channel.send_bytes(f"rejected: {exc}".encode())
        else:
            assert bootstrapped == [service_name]
            channel.send_bytes(b"installed")


def test_mac_setup_serializes_same_database_across_processes(tmp_path: Path) -> None:
    # Given: distinct labels and free ports share one private home, DB and page.
    with socket.socket() as first, socket.socket() as second:
        first.bind(("127.0.0.1", 0))
        second.bind(("127.0.0.1", 0))
        ports = [
            TypeAdapter(tuple[str, int]).validate_python(listener.getsockname())[1]
            for listener in (first, second)
        ]
    request = cli_setup_module.SetupRequest(
        db_path=tmp_path / "private/health.sqlite",
        label="synthetic-phone",
        receiver_url="https://receiver.healthbridge.internal/v1/batches",
        setup_page_path=tmp_path / "private/pair.html",
        receiver_host="127.0.0.1",
        receiver_port=ports[0],
        executable=sys.argv[0],
    )
    context = multiprocessing.get_context("spawn")
    parent_a, child_a = context.Pipe()
    parent_b, child_b = context.Pipe()
    process_a = context.Process(
        target=_overlapping_mac_setup, args=(request, child_a, True)
    )
    process_b = context.Process(
        target=_overlapping_mac_setup,
        args=(replace(request, receiver_port=ports[1]), child_b, False),
    )

    # When: A pauses after its real scan; B attempts installation before A resumes.
    try:
        process_a.start()
        child_a.close()
        assert parent_a.poll(20), "A did not finish its ownership scan"
        assert parent_a.recv_bytes() == b"scanned"
        process_b.start()
        child_b.close()
        assert parent_b.poll(20), "B did not finish its installation attempt"
        outcome_b = parent_b.recv_bytes()
        parent_a.send_bytes(b"release")
        assert parent_a.poll(20), "A did not finish installation"
        outcome_a = parent_a.recv_bytes()
        for process in (process_a, process_b):
            process.join(5)
            assert process.exitcode == 0
    finally:
        for process in (process_a, process_b):
            if process.is_alive():
                process.terminate()
                process.join(5)
            if process.is_alive():
                process.kill()
                process.join(5)
            if process.pid is not None:
                process.close()
        for channel in (parent_a, child_a, parent_b, child_b):
            channel.close()

    # Then: ownership records and successful bootstrap agree on one installation.
    owned = [
        load_owned_launch_agent_request(config)
        for config in service_paths(Path.home()).state_dir.glob("*/receiver.json")
    ]
    assert len(owned) == 1, f"owned installations: {[agent.label for agent in owned]}"
    assert owned[0].db_path == request.db_path
    assert outcome_a == b"installed"
    assert outcome_b.startswith(b"rejected:"), outcome_b


@pytest.mark.parametrize("existing", ["foreign", "incompatible"])
def test_setup_m2_refuses_existing_service_without_replacing_it(
    tmp_path: Path, control_plane: list[list[str]], existing: str
) -> None:
    db, page, args = _setup_args(tmp_path)
    unit = Path.home() / ".config/systemd/user/health-bridge-receiver.service"
    if existing == "foreign":
        unit.parent.mkdir(parents=True)
        _ = unit.write_text("[Service]\nExecStart=/usr/bin/false\n")
    else:
        assert _run_cli(*args).returncode == 0
        args[args.index("--receiver-port") + 1] = str(unused_receiver_port())
    original_unit = unit.read_bytes()
    original_page = page.read_bytes() if page.exists() else None
    control_plane.clear()
    result = _run_cli(*args)
    assert result.returncode == 1
    assert unit.read_bytes() == original_unit
    assert (page.read_bytes() if page.exists() else None) == original_page
    assert not any("start" in call or "enable" in call for call in control_plane)
    if existing == "foreign":
        assert not db.exists()


def test_setup_m2_missing_tailscale_install_has_one_next_step(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def missing(_command: list[str], **_kwargs: JsonValue) -> CompletedProcess[str]:
        raise FileNotFoundError

    monkeypatch.setattr(subprocess, "run", missing)
    db, page, args = _setup_args(tmp_path)
    del args[1:3]
    result = _run_cli(*args)
    assert result.returncode == 1
    assert "Install Tailscale" in result.stderr
    assert not db.exists()
    assert not page.exists()


@pytest.mark.parametrize("upload", ["none", "empty", "health"])
def test_setup_m2_active_rerun_preserves_invitation_identity_and_service(
    tmp_path: Path, control_plane: list[list[str]], upload: str
) -> None:
    db, page, args = _setup_args(tmp_path)
    assert _run_cli(*args).returncode == 0
    original = page.read_bytes()
    _, invitation = read_invitation_page(page)
    _ = redeem_pairing_invitation(
        db,
        installation_id="00000000-0000-4000-8000-000000000001",
        device_credential="hb_" + "a" * 64,
        platform="ios",
        invitation_secret=invitation.invitation_secret,
    )
    origin = f"http://127.0.0.1:{args[args.index('--receiver-port') + 1]}"
    if upload != "none":
        batch = with_source_key(
            HealthBridgeBatchV1.model_validate_json(
                Path("fixtures/health_bridge_batch_v1.synthetic.json").read_bytes()
            ),
            "apple_health.phone",
        )
        if upload == "empty":
            batch = batch.model_copy(
                update={
                    "samples": (),
                    "workouts": (),
                    "sleep_sessions": (),
                }
            )
        assert post_batch(origin + "/v1/batches", "hb_" + "a" * 64, batch) == 202
    control_plane.clear()
    result = _run_cli(*args)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["pairing_status"] == "paired"
    receipt = "received" if upload == "health" else "not_received"
    assert json.loads(result.stdout)["data_receipt_status"] == receipt
    with open_http_response(
        Request(
            origin + invitation_page_route(invitation),
            headers={"Accept": "application/json"},
        )
    ) as response:
        assert json.loads(response.read()) == {
            "pairing_status": "paired",
            "data_receipt_status": receipt,
        }
    assert page.read_bytes() == original
    with sqlite3.connect(db) as connection:
        assert connection.execute(
            "select count(*) from pairing_invitations"
        ).fetchone() == (1,)
        assert connection.execute(
            "select count(*) from receiver_tokens where revoked_at is null"
        ).fetchone() == (1,)
    assert not any("start" in call or "restart" in call for call in control_plane)


@pytest.mark.parametrize("logged_in", [False, True])
def test_setup_m2_missing_login_or_occupied_route(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    control_plane: list[list[str]],
    logged_in: bool,
) -> None:
    original_run = subprocess.run
    occupied = {
        "TCP": {"443": {"HTTPS": True}},
        "Web": {
            "synthetic.tailnet.ts.net:443": {
                "Handlers": {"/other": {"Proxy": "http://127.0.0.1:34567"}}
            }
        },
    }

    def control(
        command: list[str],
        *,
        capture_output: bool,
        text: bool,
        timeout: float,
        check: bool,
    ) -> CompletedProcess[str]:
        if command[:3] == ["tailscale", "status", "--json"] and not logged_in:
            return CompletedProcess(command, 0, '{"BackendState":"NeedsLogin"}', "")
        if command[:3] == ["tailscale", "serve", "status"] and not any(
            "--bg" in call for call in control_plane
        ):
            return CompletedProcess(command, 0, json.dumps(occupied), "")
        return original_run(
            command,
            capture_output=capture_output,
            text=text,
            timeout=timeout,
            check=check,
        )

    monkeypatch.setattr(subprocess, "run", control)
    db, _, args = _setup_args(tmp_path)
    del args[1:3]
    result = _run_cli(*args)
    if logged_in:
        assert result.returncode == 0, result.stderr
        assert ":8443/" in json.loads(result.stdout)["receiver_url"]
        mutations = [call for call in control_plane if "--bg" in call]
        assert len(mutations) == 1
        assert "--https=8443" in mutations[0]
    else:
        assert result.returncode == 1
        assert "Log in to Tailscale" in result.stderr
        assert not db.exists()
        assert not any("--bg" in call or "start" in call for call in control_plane)


def test_setup_saves_database_and_reuses_pending_invitation(tmp_path: Path) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    first = _run_cli(*args)
    assert first.returncode == 0
    original_page = setup_page.read_bytes()
    second = _run_cli(*args)
    assert second.returncode == 0
    assert setup_page.read_bytes() == original_page
    implicit = _run_cli("status", "--json")
    explicit = _run_cli("status", "--json", "--db", str(db_path))
    assert implicit.returncode == 0
    assert implicit.stdout == explicit.stdout
    payload = SetupCliOutput.model_validate_json(second.stdout)
    assert "--setup-page" in payload.receiver_start_command


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
    selected_transport: Literal["direct", "mailbox"]
    receiver_start_command: list[str]
    access_descriptors: list[AccessDescriptorOutput]
    local_mcp_self_test_command: list[str]
    local_mcp_status: Literal["prepared", "verified"]
    registrar_plans: list[RegistrarPlanOutput]
    detected_mcp_clients: list[str]
    configured_mcp_clients: list[str]
    client_configuration_status: Literal[
        "not_requested", "configuration_prepared", "configured_and_verified"
    ]
    next_steps: list[str]
    warning: str
    receiver_service_status: Literal["prepared", "supervised_healthy"]
    private_route_status: Literal["ready", "explicit_unverified"]
    pairing_status: Literal["pending", "paired"]
    data_receipt_status: Literal["received", "not_received"]


def _assert_owner_only(path: Path) -> None:
    assert stat.S_IMODE(path.stat().st_mode) & 0o077 == 0


def _run_cli(*args: str, env: dict[str, str] | None = None) -> CompletedProcess[str]:
    result = CliRunner().invoke(app, list(args), env=env, catch_exceptions=False)
    return CompletedProcess(list(args), result.exit_code, result.stdout, result.stderr)


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
            "--receiver-port",
            str(unused_receiver_port()),
            "--json",
        ],
    )


@pytest.mark.parametrize(
    ("receiver_host", "expected"),
    [
        ("127.0.0.1", "http://127.0.0.1:8765/health"),
        ("0.0.0.0", "http://127.0.0.1:8765/health"),  # noqa: S104 - bind input
        (TEST_PRIVATE_BIND_HOST, f"http://{TEST_PRIVATE_BIND_HOST}:8765/health"),
        ("::", "http://[::1]:8765/health"),
        ("::1", "http://[::1]:8765/health"),
        ("fd00::123", "http://[fd00::123]:8765/health"),
        ("receiver.local", "http://receiver.local:8765/health"),
    ],
)
def test_local_receiver_health_url_matches_bind_host(
    receiver_host: str,
    expected: str,
) -> None:
    assert (
        cli_setup_module._local_receiver_health_url(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
            receiver_host,
            8765,
        )
        == expected
    )


def test_setup_default_detects_but_never_configures_clients(tmp_path: Path) -> None:
    env, log_path = _client_env(tmp_path, "hermes")
    db_path, setup_page, args = _setup_args(tmp_path)

    completed = _run_cli(*args, env=env)

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.schema_version == 2
    assert payload.selected_transport == "direct"
    assert payload.db == str(db_path)
    assert payload.receiver_url == ("https://receiver.healthbridge.internal/v1/batches")
    assert payload.receiver_health_url == (
        "https://receiver.healthbridge.internal/health"
    )
    assert payload.receiver_start_command[-4:] == [
        "--host",
        "127.0.0.1",
        "--port",
        args[args.index("--receiver-port") + 1],
    ]
    assert payload.local_mcp_status == "verified"
    assert payload.detected_mcp_clients == ["hermes"]
    assert payload.configured_mcp_clients == []
    assert payload.client_configuration_status == "not_requested"
    assert payload.receiver_service_status == "supervised_healthy"
    assert payload.private_route_status == "explicit_unverified"
    assert len(payload.next_steps) == 3
    pairing_handoff = payload.next_steps[0]
    assert "On a computer" in pairing_handoff
    assert "iPhone Camera" in pairing_handoff
    assert "Open setup_page on the iPhone" not in pairing_handoff
    assert "Allow Health Access" in payload.next_steps[1]
    assert "Automatic Sync" in payload.next_steps[1]
    assert "Start Automatic Sync" not in payload.next_steps[1]
    assert "MCP" in payload.next_steps[2]
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


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="exercises the unsupported Linux mailbox-host path",
)
def test_setup_rejects_explicit_mailbox_transport_on_linux_before_side_effects(
    tmp_path: Path,
) -> None:
    # Given
    db_path, setup_page, args = _setup_args(tmp_path)
    mailbox_root = (
        tmp_path
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion"
        / "Documents/HealthBridgeMailbox/v1"
    )

    # When
    completed = _run_cli(
        *args,
        "--transport",
        "icloud-mailbox",
        "--mailbox-root",
        str(mailbox_root),
    )

    # Then
    assert completed.returncode == 1
    assert completed.stderr.strip() == (
        "Encrypted iCloud Mailbox is unavailable on this host."
    )
    assert not db_path.exists()
    assert not setup_page.exists()


def test_setup_provisions_explicit_mailbox_only_on_supported_mac_topology(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = tmp_path / "synthetic-home"
    mailbox_root = (
        home
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion"
        / "Documents/HealthBridgeMailbox/v1"
    )
    mailbox_root.mkdir(parents=True)
    home.chmod(0o700)
    db_path = tmp_path / "private/health.sqlite"
    setup_page = tmp_path / "private/pair.html"
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setattr(
        cli_setup_module, "read_helper_status", ready_setup_helper, raising=False
    )

    manifest = cli_setup_module.build_setup_manifest(
        cli_setup_module.SetupRequest(
            db_path=db_path,
            label="synthetic-iphone",
            receiver_url="https://receiver.healthbridge.internal/v1/batches",
            setup_page_path=setup_page,
            receiver_host="127.0.0.1",
            receiver_port=8765,
            executable="health-bridge",
            transport="icloud-mailbox",
            mailbox_root=mailbox_root,
            icloud_container_identifier=("iCloud.dev.example.HealthBridgeCompanion"),
        )
    )

    assert manifest.selected_transport == "mailbox"
    assert manifest.receiver_start_command[-4:] == [
        "--mailbox-root",
        str(mailbox_root),
        "--icloud-container-identifier",
        "iCloud.dev.example.HealthBridgeCompanion",
    ]
    assert "iCloud Drive" in manifest.warning
    assert "after pairing" in manifest.warning
    assert "same Apple Account" in manifest.warning
    assert "Delivery may be delayed" in manifest.warning
    assert "iCloud deliveries can be saved" in manifest.next_steps[4]
    assert manifest.receiver_service_status == "prepared"
    summary = cli_setup_module.render_setup_summary(manifest)
    assert "not started" in summary
    assert shlex.join(manifest.receiver_start_command) in summary
    with sqlite3.connect(db_path) as connection:
        invitation = cast(
            "tuple[str] | None",
            connection.execute("SELECT transport FROM pairing_invitations").fetchone(),
        )
    assert invitation == ("mailbox",)


def test_prepare_mailbox_transport_without_receiver_url_with_ready_prerequisites(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given a ready helper and existing synthetic topology, isolate URL policy.
    mailbox_root = (
        Path.home()
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion"
        / "Documents/HealthBridgeMailbox/v1"
    )
    mailbox_root.mkdir(parents=True)
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(cli_setup_module, "read_helper_status", ready_setup_helper)
    request = cli_setup_module.SetupRequest(
        db_path=tmp_path / "private/health.sqlite",
        label="synthetic-iphone",
        receiver_url="",
        setup_page_path=tmp_path / "private/pair.html",
        receiver_host="127.0.0.1",
        receiver_port=8765,
        executable="health-bridge",
        transport="icloud-mailbox",
        mailbox_root=mailbox_root,
        icloud_container_identifier="iCloud.dev.example.HealthBridgeCompanion",
    )

    # When choosing mailbox without a phone-facing receiver route.
    selected = cli_setup_module.prepare_setup_transport(request)

    # Then ready mailbox prerequisites suffice to select the transport.
    assert selected is transports.ReceiverTransport.MAILBOX


def test_setup_waits_for_phone_to_create_mailbox_hierarchy(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = tmp_path / "synthetic-home"
    documents = (
        home
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion"
        / "Documents"
    )
    documents.mkdir(parents=True)
    home.chmod(0o700)
    mailbox_root = documents / "HealthBridgeMailbox/v1"
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setattr(
        cli_setup_module, "read_helper_status", ready_setup_helper, raising=False
    )

    manifest = cli_setup_module.build_setup_manifest(
        cli_setup_module.SetupRequest(
            db_path=tmp_path / "private/health.sqlite",
            label="synthetic-iphone",
            receiver_url="https://receiver.healthbridge.internal/v1/batches",
            setup_page_path=tmp_path / "private/pair.html",
            receiver_host="127.0.0.1",
            receiver_port=8765,
            executable="health-bridge",
            transport="icloud-mailbox",
            mailbox_root=mailbox_root,
            icloud_container_identifier="iCloud.dev.example.HealthBridgeCompanion",
        )
    )

    assert manifest.selected_transport == "mailbox"
    assert not mailbox_root.exists()


@pytest.mark.parametrize("missing", ["helper", "topology", "native-capability"])
def test_mailbox_setup_prerequisites_precede_all_private_side_effects(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    control_plane: list[list[str]],
    missing: str,
) -> None:
    monkeypatch.setattr(sys, "platform", "darwin")
    documents = (
        Path.home()
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion/Documents"
    )
    if missing != "topology":
        documents.mkdir(parents=True)
    else:
        documents.parent.mkdir(parents=True)
        documents.symlink_to(tmp_path, target_is_directory=True)
    if missing != "helper":
        monkeypatch.setattr(
            cli_setup_module, "read_helper_status", ready_setup_helper, raising=False
        )
    db = tmp_path / "private/health.sqlite"
    args = [
        "setup",
        "--json",
        "--db",
        str(db),
        "--transport",
        "icloud-mailbox",
        "--mailbox-root",
        str(documents / "HealthBridgeMailbox/v1"),
        "--icloud-container-identifier",
        "iCloud.dev.example.HealthBridgeCompanion",
    ]
    if missing != "native-capability":
        args.extend(
            ["--receiver-url", "https://receiver.healthbridge.internal/v1/batches"]
        )
    result = CliRunner().invoke(app, args)
    assert result.exit_code == 1, result.output
    assert "rerun" in result.output.lower()
    assert not db.parent.exists()
    assert not (documents / "HealthBridgeMailbox").exists()
    assert not (Path.home() / "Library/LaunchAgents").exists()
    assert not (
        Path.home() / "Library/Application Support/HealthBridge/launchd"
    ).exists()
    assert control_plane == []


def test_prepared_mailbox_setup_supervises_and_reuses_owned_agent(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    control_plane: list[list[str]],
) -> None:
    platform_context = SimpleNamespace(platform="darwin", argv=sys.argv)
    for module in (cli_module, cli_setup_module, cli_setup_runtime, transports):
        monkeypatch.setattr(module, "sys", platform_context)
    monkeypatch.setattr(
        cli_setup_module, "read_helper_status", ready_setup_helper, raising=False
    )
    root = (
        Path.home()
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion"
        / "Documents/HealthBridgeMailbox/v1"
    )
    root.mkdir(parents=True, mode=0o700)
    for directory in (Path.home() / "Library").rglob("*"):
        if directory.is_dir():
            directory.chmod(0o700)
    (Path.home() / "Library").chmod(0o700)
    db = tmp_path / "private/health.sqlite"
    args = [
        "setup",
        "--json",
        "--db",
        str(db),
        "--transport",
        "icloud-mailbox",
        "--mailbox-root",
        str(root),
        "--icloud-container-identifier",
        "iCloud.dev.example.HealthBridgeCompanion",
        "--receiver-url",
        "https://receiver.healthbridge.internal/v1/batches",
        "--receiver-port",
        str(unused_receiver_port()),
    ]
    result = CliRunner().invoke(app, args)
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["receiver_service_status"] == "supervised_healthy"
    paths = service_paths(Path.home(), "health-bridge-receiver")
    owned = load_owned_launch_agent_request(paths.config)
    assert owned.mailbox_root == root
    assert (
        owned.icloud_container_identifier == "iCloud.dev.example.HealthBridgeCompanion"
    )
    original = paths.config.read_bytes(), paths.manifest.read_bytes()
    control_plane.clear()
    resumed = CliRunner().invoke(app, ["setup", "--json"])
    assert resumed.exit_code == 0, resumed.output
    assert original == (paths.config.read_bytes(), paths.manifest.read_bytes())
    assert not any("bootstrap" in command for command in control_plane)


def test_setup_redirected_selected_client_does_not_auto_consent(tmp_path: Path) -> None:
    env, log_path = _client_env(tmp_path, "hermes", "openclaw")
    _db_path, _setup_page, args = _setup_args(tmp_path)
    args.remove("--json")

    completed = _run_cli(
        *args,
        "--configure-client",
        "hermes",
        env=env,
    )

    assert completed.returncode == 0, completed.stderr
    assert not log_path.exists()
    assert _db_path.is_file()
    assert _setup_page.is_file()


def test_setup_accepts_repeated_explicit_client_configuration(tmp_path: Path) -> None:
    env, log_path = _client_env(tmp_path, "hermes", "openclaw")
    _db_path, _setup_page, args = _setup_args(tmp_path)
    args.remove("--json")

    completed = _run_cli(
        *args,
        "--configure-client",
        "hermes",
        "--configure-client",
        "openclaw",
        env=env,
    )

    assert completed.returncode == 0, completed.stderr
    assert not log_path.exists()
    assert _db_path.is_file()
    assert _setup_page.is_file()


def test_unknown_client_is_rejected_before_core_side_effects(tmp_path: Path) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    args.remove("--json")

    completed = _run_cli(*args, "--configure-client", "unknown-fixture-client")

    assert completed.returncode == 1
    assert "No built-in registrar for: unknown-fixture-client" in completed.stderr
    assert "local stdio MCP" in completed.stderr
    assert not db_path.exists()
    assert not setup_page.exists()


def test_missing_client_does_not_prevent_core_setup_in_redirected_mode(
    tmp_path: Path,
) -> None:
    env = os.environ.copy()
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    health_bridge = shutil.which("health-bridge")
    assert health_bridge is not None
    env["PATH"] = f"{Path(health_bridge).parent}{os.pathsep}{empty_bin}"
    db_path, setup_page, args = _setup_args(tmp_path)
    args.remove("--json")

    completed = _run_cli(*args, "--configure-client", "openclaw", env=env)

    assert completed.returncode == 0
    assert db_path.is_file()
    assert setup_page.is_file()


def test_setup_captured_output_withholds_hosted_handoff(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    args.remove("--json")

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    assert "running" in completed.stdout.lower()
    assert "ACK" not in completed.stdout
    assert "supervised_healthy" not in completed.stdout
    assert str(db_path) not in completed.stdout
    assert str(setup_page) not in completed.stdout
    assert len(completed.stdout.splitlines()) <= 8
    assert not re.search(
        r"https://receiver.healthbridge.internal/setup/[a-f0-9]{64}", completed.stdout
    )


@pytest.mark.parametrize("failure", ["sqlite", "timeout"])
def test_setup_expected_readback_errors_preserve_prepared_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, failure: str
) -> None:
    db, page, args = _setup_args(tmp_path)

    def fail(
        _manifest: cli_setup_module.SetupManifest,
    ) -> cli_setup_module.SetupManifest:
        if failure == "sqlite":
            message = "synthetic private detail"
            raise sqlite3.OperationalError(message)
        raise subprocess.TimeoutExpired(["synthetic-private-command"], 30)

    monkeypatch.setattr(cli_module, "verify_local_mcp", fail)
    result = _run_cli(*args)

    assert result.returncode == 1
    assert "synthetic" not in result.stderr
    assert "original setup command" in result.stderr
    assert db.exists()
    assert page.exists()


def test_setup_page_contains_custom_scheme_qr_and_manual_code(
    tmp_path: Path,
) -> None:
    _db_path, setup_page, args = _setup_args(tmp_path)

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    setup_html = setup_page.read_text(encoding="utf-8")
    assert 'href="healthbridge://pair?payload=' in setup_html
    assert "Scan the QR code with iPhone Camera" in setup_html
    assert "To connect with a code" in setup_html
    assert "single-use invitation" in setup_html
    assert "Sharing it before use" in setup_html


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
    port = args[args.index("--receiver-port") + 1]
    args[args.index("--receiver-url") + 1] = f"http://{private_host}:{port}/v1/batches"
    args.extend(("--receiver-host", "0.0.0.0"))  # noqa: S104 - test bind input
    args.append("--allow-nonlocal-receiver-address")

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.receiver_url == f"http://{private_host}:{port}/v1/batches"
    assert "Numeric LAN addresses are supported" in payload.warning
    assert "Local Network access" in payload.warning


def test_setup_accepts_plain_http_shared_address_with_compatibility_warning(
    tmp_path: Path,
) -> None:
    _db_path, _setup_page, args = _setup_args(tmp_path)
    shared_host = ".".join(("100", "100", "50", "9"))  # noqa: FLY002
    port = args[args.index("--receiver-port") + 1]
    args[args.index("--receiver-url") + 1] = f"http://{shared_host}:{port}/v1/batches"
    args.extend(("--receiver-host", "0.0.0.0"))  # noqa: S104 - test bind input
    args.append("--allow-nonlocal-receiver-address")

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.receiver_url == f"http://{shared_host}:{port}/v1/batches"
    assert "shared address space" in payload.warning
    assert "may reject plain HTTP" in payload.warning
    assert "HTTPS/MagicDNS" in payload.warning


def test_setup_rejects_nonlocal_numeric_http_receiver_before_side_effects(
    tmp_path: Path,
) -> None:
    db_path, setup_page, args = _setup_args(tmp_path)
    private_host = ".".join(("10", "0", "0", "104"))  # noqa: FLY002
    port = args[args.index("--receiver-port") + 1]
    args[args.index("--receiver-url") + 1] = f"http://{private_host}:{port}/v1/batches"
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
    port = args[args.index("--receiver-port") + 1]
    args[args.index("--receiver-url") + 1] = f"http://{private_host}:{port}/v1/batches"
    args.extend(
        (
            "--receiver-host",
            "0.0.0.0",  # noqa: S104 - test bind input
            "--allow-nonlocal-receiver-address",
        )
    )

    completed = _run_cli(*args)

    assert completed.returncode == 0, completed.stderr
    payload = SetupCliOutput.model_validate_json(completed.stdout)
    assert payload.receiver_start_command[-1] == port


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

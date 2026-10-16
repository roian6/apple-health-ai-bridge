from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess  # nosec B404
import sys
import time
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path
from typing import TYPE_CHECKING, ClassVar

from pydantic import BaseModel, ConfigDict, Field, JsonValue

from health_bridge.cli_dev import (
    INVALID_SYSTEMD_SERVICE_NAME_MESSAGE,
    SYSTEMD_SERVICE_NAME_PATTERN,
    render_receiver_systemd_unit,
    systemd_argument,
)
from health_bridge.cli_setup import (
    SetupManifest,
    SetupRequest,
    build_setup_manifest,
    prepare_setup_transport,
    require_native_setup,
)
from health_bridge.launchd import LaunchctlAdapter, install_launch_agent
from health_bridge.launchd.artifacts import (
    active_launch_agent_artifacts_exist,
    load_owned_launch_agent_request,
    require_owned_artifacts,
)
from health_bridge.launchd.health_probe import LocalHealthProbe
from health_bridge.launchd.manifest import (
    render_launch_agent_plist,
    render_service_config,
)
from health_bridge.launchd.models import (
    LaunchdServiceError,
    LaunchdServiceRequest,
    LocalHealthStatus,
    service_paths,
)
from health_bridge.launchd.private_artifacts import PrivateDirectory
from health_bridge.launchd.validation import validate_launch_agent_structure
from health_bridge.private_files import ensure_private_directory, require_private_parent
from health_bridge.storage._database_lock_files import (
    DatabaseLockPlan,
    flock,
    flock_unlock,
    open_lock_file_fd,
    require_path_identity,
)

if TYPE_CHECKING:
    from collections.abc import Generator


class TailscaleSelf(BaseModel):
    dns_name: str = Field(default="", alias="DNSName")


class TailscaleStatus(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(hide_input_in_errors=True)
    state: str = Field(alias="BackendState")
    local: TailscaleSelf | None = Field(default=None, alias="Self")


class ServeConfig(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="allow", hide_input_in_errors=True
    )
    tcp: dict[str, dict[str, JsonValue]] = Field(default_factory=dict, alias="TCP")
    web: dict[str, dict[str, dict[str, dict[str, JsonValue]]]] = Field(
        default_factory=dict, alias="Web"
    )
    funnel: dict[str, bool] = Field(default_factory=dict, alias="AllowFunnel")
    foreground: dict[str, ServeConfig] = Field(default_factory=dict, alias="Foreground")

    def occupied(self, port: int) -> bool:
        return (
            str(port) in self.tcp
            or any(key.endswith(f":{port}") for key in self.web | self.funnel)
            or any(config.occupied(port) for config in self.foreground.values())
        )

    def matches(self, endpoint: str, target: str) -> bool:
        port = endpoint.rsplit(":", 1)[1]
        return (
            self.tcp.get(port) == {"HTTPS": True}
            and self.web.get(endpoint) == {"Handlers": {"/": {"Proxy": target}}}
            and not self.funnel.get(endpoint, False)
            and not any(
                config.occupied(int(port)) for config in self.foreground.values()
            )
        )


def run_control(command: list[str]) -> subprocess.CompletedProcess[str]:
    is_tailscale = command[0] == "tailscale"
    desktop_cli = Path("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    if (
        is_tailscale
        and sys.platform == "darwin"
        and shutil.which("tailscale") is None
        and desktop_cli.is_file()
    ):
        command = [str(desktop_cli), *command[1:]]
    try:
        return subprocess.run(  # noqa: S603  # nosec B603
            command, capture_output=True, text=True, timeout=30, check=False
        )
    except FileNotFoundError as exc:
        message = (
            "Install Tailscale, then rerun health-bridge setup."
            if is_tailscale
            else "A running user systemd manager is required for Direct setup."
        )
        raise RuntimeError(message) from exc
    except subprocess.TimeoutExpired as exc:
        message = (
            f"{command[0]} timed out; inspect its local status before retrying setup."
        )
        raise RuntimeError(message) from exc


def checked_control(command: list[str]) -> str:
    result = run_control(command)
    if result.returncode:
        message = (
            f"{command[0]} {' '.join(command[1:3])} failed; "
            "inspect its local status before retrying setup."
        )
        raise RuntimeError(message)
    return result.stdout


def read_serve() -> ServeConfig:
    raw = checked_control(["tailscale", "serve", "status", "--json"])
    return ServeConfig.model_validate_json("{}" if raw.strip() == "null" else raw)


def private_route(port: int) -> tuple[str, ServeConfig]:
    status = TailscaleStatus.model_validate_json(
        checked_control(["tailscale", "status", "--json"])
    )
    if status.state != "Running":
        message = (
            "Log in to Tailscale on this computer, then rerun health-bridge setup."
        )
        raise RuntimeError(message)
    dns = status.local.dns_name.rstrip(".") if status.local else ""
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", dns):
        message = (
            "Enable MagicDNS for this Tailscale login, then rerun health-bridge setup."
        )
        raise RuntimeError(message)
    config = read_serve()
    target = f"http://127.0.0.1:{port}"
    for endpoint in config.web:
        if endpoint.rsplit(":", 1)[0] == dns and config.matches(endpoint, target):
            return endpoint, config
    for https_port in (443, 8443, 10000):
        endpoint = f"{dns}:{https_port}"
        if config.matches(endpoint, target) or not config.occupied(https_port):
            return endpoint, config
    message = (
        "Tailscale Serve HTTPS ports are occupied; "
        "supply an existing private --receiver-url."
    )
    raise RuntimeError(message)


def require_durable_executable(request: SetupRequest) -> None:
    executable = Path(request.executable)
    if (
        not executable.is_absolute()
        or not executable.is_file()
        or not os.access(executable, os.X_OK)
        or executable.name != "health-bridge"
        or "_npx" in executable.parts
        or (".cache" in executable.parts and "uv" in executable.parts)
    ):
        message = "Install health-bridge in a durable environment before running setup."
        raise ValueError(message)


def prepare_unit(request: SetupRequest, service_name: str) -> tuple[Path, str, bool]:
    require_durable_executable(request)
    executable = Path(request.executable)
    if SYSTEMD_SERVICE_NAME_PATTERN.fullmatch(service_name) is None:
        raise ValueError(INVALID_SYSTEMD_SERVICE_NAME_MESSAGE)
    arguments = [
        str(executable),
        "receiver",
        "start",
        "--db",
        str(request.db_path),
        "--host",
        request.receiver_host,
        "--port",
        str(request.receiver_port),
        "--setup-page",
        str(request.setup_page_path),
    ]
    unit_text = render_receiver_systemd_unit(
        " ".join(systemd_argument(value) for value in arguments),
        str(request.db_path.parent).replace("%", "%%"),
        installed=True,
    )
    unit = Path.home() / ".config/systemd/user" / f"{service_name}.service"
    content = "# Owned by health-bridge setup\n" + unit_text
    exists = unit.exists()
    if unit.is_symlink() or (
        exists and (unit.stat().st_uid != os.geteuid() or unit.read_text() != content)
    ):
        message = (
            "Refusing incompatible or foreign receiver unit; "
            "retain its configuration and choose another --service-name."
        )
        raise ValueError(message)
    result = run_control(
        [
            "systemctl",
            "--user",
            "show",
            "--property=FragmentPath,DropInPaths,LoadState,NeedDaemonReload",
            unit.name,
        ]
    )
    properties = dict(
        line.split("=", 1) for line in result.stdout.splitlines() if "=" in line
    )
    if properties.get("LoadState") not in {
        "loaded",
        "not-found",
    } or result.returncode not in {0, 4}:
        message = "A running user systemd manager is required for Direct setup."
        raise RuntimeError(message)
    if properties.get("NeedDaemonReload") == "yes":
        message = (
            "Receiver unit changed on disk; inspect it and reload "
            "user systemd before retrying."
        )
        raise ValueError(message)
    fragment = properties.get("FragmentPath", "")
    if properties.get("DropInPaths") or (
        fragment and Path(fragment).resolve() != unit.resolve()
    ):
        message = "Refusing foreign receiver unit or systemd drop-in configuration."
        raise ValueError(message)
    active = (
        run_control(
            ["systemctl", "--user", "is-active", "--quiet", unit.name]
        ).returncode
        == 0
    )
    if active and not exists:
        message = (
            "Refusing an active receiver unit without matching owned configuration."
        )
        raise ValueError(message)
    if not active:
        with socket.socket() as listener:
            listener.bind((request.receiver_host, request.receiver_port))
    return unit, content, active


def start_unit(unit: Path, content: str, active: bool) -> None:
    if not unit.exists():
        ensure_private_directory(unit.parent)
        require_private_parent(unit.parent)
        descriptor = os.open(unit, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            _ = output.write(content)
    if not active:
        _ = checked_control(["systemctl", "--user", "link", "--runtime", str(unit)])
        _ = checked_control(["systemctl", "--user", "daemon-reload"])
    if run_control(
        ["systemctl", "--user", "is-enabled", "--quiet", unit.name]
    ).returncode:
        _ = checked_control(["systemctl", "--user", "enable", str(unit)])
    if not active:
        _ = checked_control(["systemctl", "--user", "start", unit.name])


def require_direct_platform(request: SetupRequest) -> None:
    if sys.platform not in {"linux", "darwin"}:
        message = (
            "Automatic Direct receiver installation requires Linux user systemd "
            "or macOS launchd; use the advanced receiver commands on this platform."
        )
        raise RuntimeError(message)
    if request.receiver_host not in {"127.0.0.1", "0.0.0.0"}:  # nosec B104 - validates opt-in LAN value, not a listener; # noqa: S104
        message = (
            "Persistent Direct setup requires --receiver-host 127.0.0.1 or 0.0.0.0."
        )
        raise ValueError(message)


@contextmanager
def mac_setup_transaction(home: Path) -> Generator[None, None, None]:
    with PrivateDirectory.open(
        service_paths(home).state_dir, create=True, owner_only=True
    ) as directory:
        lock_path = directory.path / "setup-transaction.lock"
        plan = DatabaseLockPlan(
            suffix="",
            exclusive=True,
            create=True,
            nonblocking=True,
            lock_database=False,
            optional_lock_file=False,
        )
        descriptor = open_lock_file_fd(lock_path, plan)
        if descriptor is None:
            message = "Mac setup transaction claim is unavailable."
            raise RuntimeError(message)
        with os.fdopen(descriptor, "r+b") as claim:
            try:
                flock(claim.fileno(), exclusive=True, nonblocking=True)
            except BlockingIOError as exc:
                message = (
                    "Another Mac setup is in progress; "
                    "let it finish, then rerun health-bridge setup."
                )
                raise RuntimeError(message) from exc
            try:
                directory.validate_attached()
                require_path_identity(lock_path, os.fstat(claim.fileno()))
                yield
            finally:
                flock_unlock(claim.fileno())


def start_mac_agent(
    request: SetupRequest, service_name: str
) -> tuple[SetupManifest, LaunchctlAdapter]:
    require_durable_executable(request)
    agent = LaunchdServiceRequest(
        executable=Path(request.executable),
        db_path=request.db_path,
        mailbox_root=request.mailbox_root,
        icloud_container_identifier=request.icloud_container_identifier,
        home=Path.home().resolve(strict=True),
        uid=os.geteuid(),
        host=request.receiver_host,
        port=request.receiver_port,
        label=service_name,
        setup_page=request.setup_page_path,
    )
    _ = validate_launch_agent_structure(agent)
    with mac_setup_transaction(agent.home):
        require_unique_agent_database(agent)
        owned = active_launch_agent_artifacts_exist(agent.paths)
        if owned:
            _ = require_owned_artifacts(
                agent, render_launch_agent_plist(agent), render_service_config(agent)
            )
        adapter = LaunchctlAdapter(
            launchctl=Path("/bin/launchctl"),
            uid=agent.uid,
            timeout_seconds=45,
            label=agent.label,
        )
        inspected = adapter.inspect()
        if inspected.returncode == 0 and (
            not owned
            or f"path = {agent.paths.manifest}"
            not in {line.strip() for line in inspected.stdout.splitlines()}
        ):
            message = (
                "Refusing a foreign loaded LaunchAgent; choose another --service-name."
            )
            raise ValueError(message)
        running = inspected.returncode == 0 and any(
            line.strip() == "state = running" for line in inspected.stdout.splitlines()
        )
        if not running:
            with socket.socket() as listener:
                listener.bind((request.receiver_host, request.receiver_port))
        manifest = build_setup_manifest(request)
        _ = install_launch_agent(agent, adapter)
        return manifest, adapter


def require_unique_agent_database(agent: LaunchdServiceRequest) -> None:
    paths = service_paths(agent.home)
    for config in (paths.config, *paths.state_dir.glob("*/receiver.json")):
        if config == agent.paths.config or not config.exists():
            continue
        try:
            existing = load_owned_launch_agent_request(config)
        except LaunchdServiceError:
            continue
        if existing.db_path.resolve() == agent.db_path.resolve():
            message = (
                "Database already belongs to another owned LaunchAgent; "
                "retain its service name."
            )
            raise ValueError(message)


def setup_direct(request: SetupRequest, service_name: str) -> SetupManifest:
    require_direct_platform(request)
    endpoint = ""
    snapshot = ServeConfig()
    if not request.receiver_url and (request.transport == "direct"):
        endpoint, snapshot = private_route(request.receiver_port)
        request = replace(request, receiver_url=f"https://{endpoint}/v1/batches")
    _ = prepare_setup_transport(request)
    require_native_setup(request)
    adapter: LaunchctlAdapter | None = None
    unit = Path()
    if sys.platform == "darwin":
        manifest, adapter = start_mac_agent(request, service_name)
    else:
        unit, content, active = prepare_unit(request, service_name)
        manifest = build_setup_manifest(request)
        start_unit(unit, content, active)
    probe = LocalHealthProbe(timeout_seconds=1)
    deadline = time.monotonic() + 10
    while probe.probe("127.0.0.1", request.receiver_port) is not LocalHealthStatus.OK:
        if time.monotonic() >= deadline:
            message = (
                "Receiver installed but local /health is not healthy; "
                "inspect the user service logs."
            )
            raise RuntimeError(message)
        time.sleep(0.1)
    if adapter is not None:
        inspected = adapter.inspect()
        active = inspected.returncode == 0 and any(
            line.strip() == "state = running" for line in inspected.stdout.splitlines()
        )
    else:
        active = (
            run_control(
                ["systemctl", "--user", "is-active", "--quiet", unit.name]
            ).returncode
            == 0
        )
    require_active_service(active)
    if endpoint:
        target = f"http://127.0.0.1:{request.receiver_port}"
        current = read_serve()
        if current != snapshot:
            message = (
                "Tailscale Serve changed during setup; "
                "rerun setup to preserve its routes."
            )
            raise RuntimeError(message)
        if not current.matches(endpoint, target):
            port = endpoint.rsplit(":", 1)[1]
            _ = checked_control(
                ["tailscale", "serve", "--bg", f"--https={port}", target]
            )
        if not read_serve().matches(endpoint, target):
            message = "Receiver healthy; private Tailscale Serve route is not ready."
            raise RuntimeError(message)
    return manifest.model_copy(
        update={
            "receiver_service_status": "supervised_healthy",
            "private_route_status": "ready"
            if endpoint
            else manifest.private_route_status,
            "next_steps": (
                manifest.next_steps[3:]
                if manifest.pairing_status == "pending"
                else [
                    (
                        "Continue Automatic Sync on the paired phone; "
                        "pairing credentials retained."
                    ),
                    manifest.next_steps[-1],
                ]
            ),
        }
    )


def require_active_service(active: bool) -> None:
    if not active:
        message = "Receiver local health responded but its owned service is inactive."
        raise RuntimeError(message)

from __future__ import annotations

import ipaddress
import json
import re
import shutil
import socket
import subprocess  # nosec B404
from dataclasses import dataclass
from typing import TYPE_CHECKING, ClassVar, Literal, cast
from urllib.parse import ParseResult, urlparse

from pydantic import BaseModel, ConfigDict, Field

from health_bridge.cli_dev import (
    DevDeviceSessionRequest,
    build_dev_device_session_manifest,
)

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable
    from pathlib import Path

ClientConfigurationStatus = Literal["not_requested", "configured_and_verified"]
LocalMcpStatus = Literal["prepared", "verified"]
MIN_RECEIVER_PORT = 1
MAX_RECEIVER_PORT = 65535
IPV4_TAILSCALE_NETWORK = ipaddress.ip_network((1681915904, 10))
IPV4_DIRECT_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in (
        (167772160, 8),
        (1681915904, 10),
        (2851995648, 16),
        (2886729728, 12),
        (3232235520, 16),
    )
)
IPV4_NONFORWARDABLE_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in (
        (0, 8),
        (3221225984, 24),
        (3325256704, 24),
        (3405803776, 24),
    )
)
IPV6_DIRECT_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in (
        (334965454937798799971759379190646833152, 7),
        (338288524927261089654018896841347694592, 10),
    )
)
IPV6_NONFORWARDABLE_NETWORKS = (
    ipaddress.ip_network((42540766411282592856903984951653826560, 32)),
)
DOCUMENTATION_HOST_SUFFIXES = (".example", ".invalid", ".test")
DOCUMENTATION_HOSTS = frozenset(
    {
        "example",
        "invalid",
        "test",
        "example.com",
        "example.net",
        "example.org",
    }
)


class AccessDescriptor(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)

    id: str = "health-bridge-local"
    protocol: Literal["mcp"] = "mcp"
    transport: Literal["stdio"] = "stdio"
    command: str
    args: list[str]
    cwd: str | None = None
    env_refs: dict[str, str] = Field(default_factory=dict)


class McpClientRegistrarPlan(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)

    name: str
    detected: bool
    add_command: list[str]
    verify_command: list[str]


class SetupManifest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)

    schema_id: str = "health_bridge.onboarding"
    schema_version: int = 2
    db: str
    receiver_url: str
    receiver_health_url: str
    setup_page: str
    pairing_schema_id: str
    invitation_expires_at: str
    receiver_start_command: list[str]
    access_descriptors: list[AccessDescriptor]
    local_mcp_self_test_command: list[str]
    local_mcp_status: LocalMcpStatus
    registrar_plans: list[McpClientRegistrarPlan]
    detected_mcp_clients: list[str]
    configured_mcp_clients: list[str]
    client_configuration_status: ClientConfigurationStatus
    next_steps: list[str]
    warning: str


@dataclass(frozen=True, slots=True)
class SetupRequest:
    db_path: Path
    label: str
    receiver_url: str
    setup_page_path: Path
    receiver_host: str
    receiver_port: int
    executable: str
    allow_nonlocal_receiver_address: bool = False


@dataclass(frozen=True, slots=True)
class _Registrar:
    name: str
    executable: str
    add_command: Callable[[AccessDescriptor], list[str]]
    verify_command: Callable[[], list[str]]


def _hermes_add_command(access: AccessDescriptor) -> list[str]:
    return [
        "hermes",
        "mcp",
        "add",
        "health-bridge",
        "--command",
        access.command,
        "--args",
        *access.args,
    ]


def _openclaw_add_command(access: AccessDescriptor) -> list[str]:
    command = [
        "openclaw",
        "mcp",
        "add",
        "health-bridge",
        "--command",
        access.command,
    ]
    command.extend(f"--arg={argument}" for argument in access.args)
    return command


_REGISTRARS: tuple[_Registrar, ...] = (
    _Registrar(
        name="hermes",
        executable="hermes",
        add_command=_hermes_add_command,
        verify_command=lambda: ["hermes", "mcp", "test", "health-bridge"],
    ),
    _Registrar(
        name="openclaw",
        executable="openclaw",
        add_command=_openclaw_add_command,
        verify_command=lambda: ["openclaw", "mcp", "probe", "health-bridge"],
    ),
)


def validate_requested_clients(requested: Iterable[str]) -> tuple[str, ...]:
    names = tuple(
        dict.fromkeys(name.strip().lower() for name in requested if name.strip())
    )
    available = {registrar.name: registrar for registrar in _REGISTRARS}
    unknown = [name for name in names if name not in available]
    if unknown:
        supported = ", ".join(sorted(available))
        message = (
            f"No built-in registrar for: {', '.join(unknown)}. "
            "Core setup supports local stdio MCP without modifying client config. "
            f"Built-in registrars: {supported}."
        )
        raise ValueError(message)
    missing = [
        name for name in names if shutil.which(available[name].executable) is None
    ]
    if missing:
        message = f"Requested MCP client CLI is not installed: {', '.join(missing)}"
        raise RuntimeError(message)
    return names


def _parsed_ip(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        pass

    # Some system resolvers accept historical IPv4 spellings such as 127.1,
    # one-part integers, octal, or hexadecimal. Normalize those numeric forms
    # without resolving ordinary DNS names so loopback checks cannot be bypassed.
    try:
        return ipaddress.ip_address(socket.inet_aton(host))
    except OSError:
        return None


def _is_loopback_host(host: str) -> bool:
    normalized = host.rstrip(".").lower()
    address = _parsed_ip(normalized)
    loopback_name = normalized in {"localhost", "localhost.localdomain"} or (
        normalized.endswith((".localhost", ".localhost.localdomain"))
    )
    return loopback_name or (address is not None and address.is_loopback)


def _is_documentation_host(host: str) -> bool:
    normalized = host.rstrip(".").lower()
    return (
        normalized in DOCUMENTATION_HOSTS
        or any(normalized.endswith(suffix) for suffix in DOCUMENTATION_HOST_SUFFIXES)
        or any(
            normalized.endswith(f".{reserved}")
            for reserved in ("example.com", "example.net", "example.org")
        )
    )


def _reject_documentation_host(host: str) -> None:
    if not _is_documentation_host(host):
        return
    message = (
        "Receiver URL uses a reserved documentation or testing hostname. "
        "Prepare the real phone-reachable private HTTPS route first, then retry "
        "with its exact /v1/batches URL. See "
        "https://github.com/roian6/apple-health-ai-bridge/blob/main/docs/setup.md."
    )
    raise ValueError(message)


def _is_direct_local_host(host: str) -> bool:
    normalized = host.rstrip(".").lower()
    if normalized.endswith(".local"):
        return True
    address = _parsed_ip(normalized)
    if address is None:
        return False
    networks = (
        IPV4_DIRECT_NETWORKS
        if isinstance(address, ipaddress.IPv4Address)
        else IPV6_DIRECT_NETWORKS
    )
    return any(address in network for network in networks)


def _is_locally_assigned_ip(host: str) -> bool:
    address = _parsed_ip(host.rstrip(".").lower())
    return address is not None and address in _local_interface_addresses()


def _local_interface_addresses() -> frozenset[
    ipaddress.IPv4Address | ipaddress.IPv6Address
]:
    addresses = _ip_command_addresses()
    if addresses:
        return frozenset(addresses)
    return frozenset(_ifconfig_addresses())


def _ip_command_addresses() -> set[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    ip_command = shutil.which("ip")
    if ip_command is None:
        return set()
    completed = subprocess.run(  # nosec B603  # noqa: S603
        [ip_command, "-j", "address", "show"],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    if completed.returncode != 0:
        return set()
    return _parse_ip_command_addresses(completed.stdout)


def _parse_ip_command_addresses(
    payload: str,
) -> set[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    addresses: set[ipaddress.IPv4Address | ipaddress.IPv6Address] = set()
    try:
        raw_interfaces = cast("object", json.loads(payload))
    except json.JSONDecodeError:
        return addresses
    if not isinstance(raw_interfaces, list):
        return addresses
    for raw_interface in cast("list[object]", raw_interfaces):
        if not isinstance(raw_interface, dict):
            continue
        interface = cast("dict[object, object]", raw_interface)
        raw_address_info = interface.get("addr_info")
        if not isinstance(raw_address_info, list):
            continue
        for raw_info in cast("list[object]", raw_address_info):
            if not isinstance(raw_info, dict):
                continue
            info = cast("dict[object, object]", raw_info)
            raw_local = info.get("local")
            if not isinstance(raw_local, str):
                continue
            candidate = _parsed_ip(raw_local)
            if candidate is not None:
                addresses.add(candidate)
    return addresses


def _ifconfig_addresses() -> set[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    addresses: set[ipaddress.IPv4Address | ipaddress.IPv6Address] = set()
    ifconfig_command = shutil.which("ifconfig")
    if ifconfig_command is None:
        return addresses
    completed = subprocess.run(  # nosec B603  # noqa: S603
        [ifconfig_command],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    if completed.returncode != 0:
        return addresses
    raw_addresses = cast(
        "list[str]",
        re.findall(
            r"\binet6?\s+([0-9A-Fa-f:.]+)(?:%\S+)?",
            completed.stdout,
        ),
    )
    for raw_address in raw_addresses:
        candidate = _parsed_ip(raw_address)
        if candidate is not None:
            addresses.add(candidate)
    return addresses


def _is_unusable_ip_destination(host: str) -> bool:
    address = _parsed_ip(host.rstrip(".").lower())
    if address is None:
        return False
    if address.is_unspecified or address.is_multicast or address.is_reserved:
        return True
    nonforwardable = (
        IPV4_NONFORWARDABLE_NETWORKS
        if isinstance(address, ipaddress.IPv4Address)
        else IPV6_NONFORWARDABLE_NETWORKS
    )
    if any(address in network for network in nonforwardable):
        return True
    direct = (
        IPV4_DIRECT_NETWORKS
        if isinstance(address, ipaddress.IPv4Address)
        else IPV6_DIRECT_NETWORKS
    )
    return not address.is_global and not any(address in network for network in direct)


def _numeric_http_notice(
    request: SetupRequest,
    *,
    scheme: str,
    host: str,
    address: ipaddress.IPv4Address | ipaddress.IPv6Address | None,
) -> str | None:
    if scheme != "http" or address is None:
        return None
    compatibility_notice = ""
    if isinstance(address, ipaddress.IPv4Address) and address in IPV4_TAILSCALE_NETWORK:
        compatibility_notice = (
            " This destination is in IPv4 shared address space, which does not by "
            "itself identify Tailscale. iOS transport policy may reject plain HTTP "
            "on some overlay-network routes; prefer HTTPS/MagicDNS when available."
        )
    if not request.allow_nonlocal_receiver_address and not _is_locally_assigned_ip(
        host
    ):
        message = (
            "Numeric HTTP receiver address is not assigned to this receiver host. "
            "Use this host's LAN or Tailscale address, or pass "
            "--allow-nonlocal-receiver-address only for an intentional proxy or "
            "ingress."
        )
        raise ValueError(message)
    notice = "Numeric HTTP receiver addresses must be reachable from the iPhone."
    if _is_direct_local_host(host):
        notice = (
            "Numeric LAN addresses are supported. The iPhone must allow Local "
            "Network access and have a reachable Wi-Fi or VPN route. DHCP may "
            "change the address; prefer stable DNS, Bonjour, or Tailscale when "
            "available."
        )
    if request.allow_nonlocal_receiver_address:
        notice += " Nonlocal receiver-address validation was explicitly bypassed."
    return notice + compatibility_notice


def _validated_url_port(request: SetupRequest, parsed: ParseResult) -> int | None:
    if not MIN_RECEIVER_PORT <= request.receiver_port <= MAX_RECEIVER_PORT:
        message = "Receiver bind port must be between 1 and 65535."
        raise ValueError(message)
    try:
        url_port = parsed.port
    except ValueError as exc:
        message = "Receiver URL has an invalid port."
        raise ValueError(message) from exc
    if url_port is not None and not MIN_RECEIVER_PORT <= url_port <= MAX_RECEIVER_PORT:
        message = "Receiver URL has an invalid port; use a value from 1 to 65535."
        raise ValueError(message)
    return url_port


def _setup_transport_notice(request: SetupRequest) -> str:
    parsed = urlparse(request.receiver_url)
    host = parsed.hostname
    url_port = _validated_url_port(request, parsed)
    if parsed.scheme not in {"http", "https"} or host is None:
        message = "Receiver URL must use http or https and include a host."
        raise ValueError(message)
    if parsed.username is not None or parsed.password is not None:
        message = "Receiver URL must not contain a username or password."
        raise ValueError(message)
    _reject_documentation_host(host)
    if parsed.path != "/v1/batches" or parsed.params or parsed.query or parsed.fragment:
        message = "Receiver URL must end at /v1/batches without query or fragment data."
        raise ValueError(message)
    if _is_loopback_host(host):
        message = (
            "Receiver URL cannot use a loopback host; it would point at the "
            "iPhone itself."
        )
        raise ValueError(message)
    if _is_unusable_ip_destination(host):
        message = "Receiver URL must use a reachable unicast destination."
        raise ValueError(message)
    if (
        parsed.scheme == "http"
        and _is_direct_local_host(host)
        and _is_loopback_host(request.receiver_host)
    ):
        message = (
            "A direct LAN receiver URL cannot use a loopback-only bind. Set "
            "--receiver-host to a reachable interface address or 0.0.0.0."
        )
        raise ValueError(message)
    if (
        parsed.scheme == "http"
        and _is_direct_local_host(host)
        and (url_port if url_port is not None else 80) != request.receiver_port
    ):
        message = (
            "A direct LAN HTTP receiver URL must use the same port as "
            "--receiver-port. Use an HTTPS proxy URL only when a separate proxy "
            "is intentionally routing to the receiver."
        )
        raise ValueError(message)
    address = _parsed_ip(host)
    numeric_notice = _numeric_http_notice(
        request,
        scheme=parsed.scheme,
        host=host,
        address=address,
    )
    if numeric_notice is not None:
        return numeric_notice
    if host.rstrip(".").lower().endswith(".local"):
        return (
            "Bonjour .local works only on a multicast-capable reachable LAN. The "
            "iPhone must allow Local Network access."
        )
    return "Verify this receiver URL is reachable from the iPhone before pairing."


def build_setup_manifest(request: SetupRequest) -> SetupManifest:
    transport_notice = _setup_transport_notice(request)
    session = build_dev_device_session_manifest(
        DevDeviceSessionRequest(
            db_path=request.db_path,
            label=request.label,
            receiver_url=request.receiver_url,
            setup_page_path=request.setup_page_path,
            receiver_host=request.receiver_host,
            receiver_port=request.receiver_port,
            watch_seconds=7200,
        )
    )
    receiver_start_command = [
        request.executable,
        "receiver",
        "start",
        "--db",
        str(request.db_path),
        "--host",
        request.receiver_host,
        "--port",
        str(request.receiver_port),
    ]
    local_receiver_health_url = f"http://127.0.0.1:{request.receiver_port}/health"
    access = AccessDescriptor(
        command=request.executable,
        args=["mcp", "start", "--db", str(request.db_path)],
    )
    registrar_plans = [
        McpClientRegistrarPlan(
            name=registrar.name,
            detected=shutil.which(registrar.executable) is not None,
            add_command=registrar.add_command(access),
            verify_command=registrar.verify_command(),
        )
        for registrar in _REGISTRARS
    ]
    return SetupManifest(
        db=str(request.db_path),
        receiver_url=session.receiver_url,
        receiver_health_url=session.receiver_health_url,
        setup_page=session.setup_page,
        pairing_schema_id=session.pairing_schema_id,
        invitation_expires_at=session.invitation_expires_at,
        receiver_start_command=receiver_start_command,
        access_descriptors=[access],
        local_mcp_self_test_command=[
            request.executable,
            "mcp",
            "smoke",
            "--db",
            str(request.db_path),
        ],
        local_mcp_status="prepared",
        registrar_plans=registrar_plans,
        detected_mcp_clients=[plan.name for plan in registrar_plans if plan.detected],
        configured_mcp_clients=[],
        client_configuration_status="not_requested",
        next_steps=[
            (
                "Put receiver_start_command under an approved service manager, "
                "then start the receiver."
            ),
            (
                'On the receiver host, require {"status":"ok"} from the local '
                f"health check at {local_receiver_health_url}."
            ),
            (
                "On the physical iPhone, require the same response from the exact "
                f"phone-facing health URL: {session.receiver_health_url}."
            ),
            (
                "Private pairing page (open only after both health checks pass): on "
                f"the receiver computer, open {session.setup_page} on a trusted "
                "screen, then scan its QR with iPhone Camera and open the setup link. "
                "If the receiver is headless, securely copy the HTML file to a trusted "
                "local screen; do not publish it or place it on a public web server."
            ),
            (
                "Connect the app, allow read access to all supported Apple Health "
                "types you want to share, enable Automatic Sync, and require the "
                "first receiver upload ACK."
            ),
            (
                "After the first receiver upload ACK, use access_descriptors for a "
                "same-host stdio MCP client, or query the database with the direct CLI."
            ),
        ],
        warning=(
            "The private setup page contains a temporary single-use invitation. "
            "Do not put it in chat, Git, logs, or a public web server; delete it "
            f"after pairing or expiry. {transport_notice}"
        ),
    )


def verify_local_mcp(manifest: SetupManifest) -> SetupManifest:
    _run_command(
        manifest.local_mcp_self_test_command,
        "Health Bridge local MCP self-test",
    )
    return manifest.model_copy(update={"local_mcp_status": "verified"})


def configure_mcp_clients(
    manifest: SetupManifest,
    requested: Iterable[str],
) -> SetupManifest:
    names = validate_requested_clients(requested)
    if not names:
        return manifest
    plans = {plan.name: plan for plan in manifest.registrar_plans}
    configured: list[str] = []
    for name in names:
        plan = plans[name]
        _run_command(plan.add_command, f"{name} MCP registration")
        _run_command(plan.verify_command, f"{name} MCP verification")
        configured.append(name)
    return manifest.model_copy(
        update={
            "configured_mcp_clients": configured,
            "client_configuration_status": "configured_and_verified",
        }
    )


def _run_command(command: list[str], action: str) -> None:
    result = subprocess.run(  # noqa: S603  # nosec B603
        command,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        message = f"{action} failed; existing core setup was not rolled back"
        raise RuntimeError(message)


def render_setup_summary(manifest: SetupManifest) -> str:
    detected = ", ".join(manifest.detected_mcp_clients) or "none"
    configured = ", ".join(manifest.configured_mcp_clients) or "none"
    lines = [
        "Health Bridge core setup prepared.",
        f"Configured phone-facing health URL: {manifest.receiver_health_url}",
        f"Local MCP self-test: {manifest.local_mcp_status}",
        f"Detected client adapters: {detected} (no configuration is automatic)",
        f"Configured clients: {configured}",
        "",
    ]
    lines.extend(
        f"{index}. {step}" for index, step in enumerate(manifest.next_steps, start=1)
    )
    lines.extend(("", manifest.warning))
    return "\n".join(lines)

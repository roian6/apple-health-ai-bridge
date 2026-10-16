from __future__ import annotations

import ipaddress
import json
import re
import shlex
import shutil
import socket
import subprocess  # nosec B404
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import TYPE_CHECKING, ClassVar, Literal, cast
from urllib.parse import ParseResult, urlparse

from pydantic import BaseModel, ConfigDict, Field

from health_bridge import __version__
from health_bridge.cli_dev import (
    DevDeviceSessionRequest,
    build_dev_device_session_manifest,
    receiver_health_url,
)
from health_bridge.connect_adapters import ADAPTERS
from health_bridge.connect_wizard import connection_wizard
from health_bridge.mailbox.helper_lifecycle import HelperStatusCode, read_helper_status
from health_bridge.mailbox.native_ack_publication import default_native_ack_publisher
from health_bridge.receiver.invitations import active_setup_pairings
from health_bridge.receiver.pairing import PAIRING_INVITATION_SCHEMA_ID
from health_bridge.receiver.pairing_setup_page import (
    invitation_page_route,
    read_invitation_page,
)
from health_bridge.receiver.transports import (
    MAILBOX_HOST_UNAVAILABLE_ERROR,
    PublicReceiverTransport,
    ReceiverTransport,
    ReceiverTransportSelectionError,
    select_receiver_transport,
)
from health_bridge.storage.database import (
    connect_readonly_database,
    initialize_database,
)

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable

ClientConfigurationStatus = Literal[
    "not_requested", "configuration_prepared", "configured_and_verified"
]
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


def require_native_setup(request: SetupRequest) -> None:
    if request.transport != "icloud-mailbox" or request.receiver_url:
        return
    if request.receiver_host != "127.0.0.1":
        message = "Native mailbox setup requires loopback access."
        raise ValueError(message)
    try:
        default_native_ack_publisher().require_native_pairing()
    except OSError as exc:
        message = "Rerun setup with a native-pairing helper and available iCloud Drive."
        raise ValueError(message) from exc


class SetupManifest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)

    schema_id: str = "health_bridge.onboarding"
    schema_version: int = 2
    db: str
    receiver_url: str | None
    receiver_health_url: str | None
    setup_page: str
    local_setup_url: str = Field(default="", exclude=True)
    paired_invitation_ids: tuple[str, ...] = Field(default=(), exclude=True)
    pairing_schema_id: str
    invitation_expires_at: str
    selected_transport: ReceiverTransport
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
    receiver_service_status: Literal["prepared", "supervised_healthy"] = "prepared"
    private_route_status: Literal["explicit_unverified", "ready", "not_required"] = (
        "explicit_unverified"
    )
    pairing_status: Literal["pending", "paired"] = "pending"
    data_receipt_status: Literal["not_received", "received"] = "not_received"


@dataclass(frozen=True, slots=True)
class SetupRequest:
    db_path: Path
    label: str
    receiver_url: str | None
    setup_page_path: Path
    receiver_host: str
    receiver_port: int
    executable: str
    allow_nonlocal_receiver_address: bool = False
    transport: PublicReceiverTransport = "direct"
    mailbox_root: Path | None = None
    icloud_container_identifier: str | None = None
    allow_loopback_receiver: bool = False


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
    available = ADAPTERS
    unknown = [name for name in names if name not in available]
    if unknown:
        supported = ", ".join(sorted(available))
        message = (
            f"No built-in registrar for: {', '.join(unknown)}. "
            "Core setup supports local stdio MCP without modifying client config. "
            f"Built-in registrars: {supported}."
        )
        raise ValueError(message)
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


def _loopback_notice(request: SetupRequest) -> str:
    if request.allow_loopback_receiver and request.receiver_url == (
        f"http://127.0.0.1:{request.receiver_port}/v1/batches"
    ):
        return "Loopback QA only: this URL cannot be reached from an iPhone."
    message = (
        "Receiver URL cannot use a loopback host; it would point at the iPhone itself."
    )
    raise ValueError(message)


def setup_transport_notice(request: SetupRequest) -> str:
    if request.transport == "icloud-mailbox" and not request.receiver_url:
        return "Initial pairing uses encrypted iCloud files."
    return _http_setup_transport_notice(request)


def _http_setup_transport_notice(request: SetupRequest) -> str:
    parsed = urlparse(request.receiver_url or "")
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
        return _loopback_notice(request)
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


def _local_receiver_health_url(receiver_host: str, receiver_port: int) -> str:
    address = _parsed_ip(receiver_host)
    if isinstance(address, ipaddress.IPv4Address):
        health_host = "127.0.0.1" if address.is_unspecified else str(address)
    elif isinstance(address, ipaddress.IPv6Address):
        health_host = "::1" if address.is_unspecified else str(address)
        health_host = f"[{health_host}]"
    else:
        health_host = receiver_host
    return f"http://{health_host}:{receiver_port}/health"


def prepare_setup_transport(request: SetupRequest) -> ReceiverTransport:
    if request.transport == "icloud-mailbox":
        if sys.platform != "darwin":
            raise ValueError(MAILBOX_HOST_UNAVAILABLE_ERROR)
        helper = read_helper_status(home=Path.home(), expected_version=__version__)
        if helper.code is not HelperStatusCode.READY:
            message = (
                "iCloud needs a verified signed helper matching Health Bridge "
                f"{__version__}. "
                "Rerun your original setup command in a terminal to select "
                "matching local "
                "release files or choose another connection. The matching helper "
                "release is not publicly available yet."
            )
            raise ValueError(message)
    _ = setup_transport_notice(request)
    try:
        return select_receiver_transport(
            request.transport,
            mailbox_root=request.mailbox_root,
            icloud_container_identifier=request.icloud_container_identifier,
        )
    except ReceiverTransportSelectionError as exc:
        if request.transport == "direct":
            raise
        message = (
            "Health Bridge's iCloud Drive folder is not ready on this Mac. "
            "Check that iCloud Drive is on and the app's Documents folder has "
            "appeared, then rerun your original setup command. "
            f"Details: {exc.message}"
        )
        raise ReceiverTransportSelectionError(message) from exc


def build_setup_manifest(request: SetupRequest) -> SetupManifest:
    selected_transport = prepare_setup_transport(request)
    native = (
        selected_transport is ReceiverTransport.MAILBOX and not request.receiver_url
    )
    if native:
        require_native_setup(request)
        request = replace(request, receiver_url=None)
    transport_notice = setup_transport_notice(request)
    if selected_transport is ReceiverTransport.MAILBOX:
        transport_notice = (
            "iCloud Drive will carry health data to this Mac after pairing. "
            "Use the same Apple Account on both devices and stay logged in on "
            f"the Mac. Delivery may be delayed. {transport_notice}"
        )
    initialize_database(request.db_path)
    with connect_readonly_database(request.db_path) as connection:
        paired = active_setup_pairings(connection)
        received = any(
            pair.progress.data_receipt_status == "received" for pair in paired
        )
    if paired and any(
        (pair.receiver_url, pair.transport)
        != (request.receiver_url, selected_transport.value)
        for pair in paired
    ):
        message = (
            "This iPhone already uses a different computer address or delivery choice. "
            "Rerun your original setup command without the new connection options "
            "to use your saved connection."
        )
        raise ValueError(message)
    session = (
        None
        if paired
        else build_dev_device_session_manifest(
            DevDeviceSessionRequest(
                db_path=request.db_path,
                label=request.label,
                receiver_url=request.receiver_url,
                setup_page_path=request.setup_page_path,
                receiver_host=request.receiver_host,
                receiver_port=request.receiver_port,
                watch_seconds=7200,
                transport=selected_transport,
                mailbox_root=request.mailbox_root,
                icloud_container_identifier=request.icloud_container_identifier,
            )
        )
    )
    receiver_start_command = [
        request.executable,
        "receiver",
        "start",
        "--db",
        str(request.db_path),
        "--setup-page",
        str(request.setup_page_path),
        "--host",
        request.receiver_host,
        "--port",
        str(request.receiver_port),
    ]
    if request.mailbox_root is not None:
        receiver_start_command.extend(("--mailbox-root", str(request.mailbox_root)))
    if request.icloud_container_identifier is not None:
        receiver_start_command.extend(
            (
                "--icloud-container-identifier",
                request.icloud_container_identifier,
            )
        )
    local_receiver_health_url = _local_receiver_health_url(
        request.receiver_host,
        request.receiver_port,
    )
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
    sync_step = (
        "In Health Bridge for AI (companion app), tap Allow Health Access, choose "
        "read permissions, then turn on Automatic Sync. Sync Now is optional."
    )
    if selected_transport is ReceiverTransport.MAILBOX:
        sync_step += (
            " Keep this Mac awake and logged in so iCloud deliveries can be saved."
        )
    return SetupManifest(
        db=str(request.db_path),
        receiver_url=request.receiver_url,
        receiver_health_url=receiver_health_url(request.receiver_url),
        setup_page=str(request.setup_page_path),
        local_setup_url=(
            local_receiver_health_url.removesuffix("/health")
            + invitation_page_route(read_invitation_page(request.setup_page_path)[1])
        )
        if native and session
        else "",
        pairing_schema_id=PAIRING_INVITATION_SCHEMA_ID,
        invitation_expires_at=session.invitation_expires_at if session else "",
        paired_invitation_ids=tuple(pair.invitation_id for pair in paired),
        pairing_status="paired" if paired else "pending",
        data_receipt_status="received" if received else "not_received",
        selected_transport=selected_transport,
        private_route_status="not_required" if native else "explicit_unverified",
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
                "Start Health Bridge's background process on this computer "
                "using receiver_start_command."
            ),
            (
                'On this computer, check for {"status":"ok"} at '
                f"{local_receiver_health_url}."
            ),
            (
                "".join(
                    (
                        "On your iPhone, open this address in Safari ",
                        "and check for the same ",
                        f"response: {receiver_health_url(request.receiver_url)}.",
                    )
                )
                if not native
                else "Scan this Mac's QR with your iPhone. Pairing uses iCloud Drive."
            ),
            (
                "Open the private connection page shown in your terminal. On "
                "a computer, "
                "scan its QR with iPhone Camera. On the iPhone, tap its Open button."
            ),
            sync_step,
            (
                "Run health-bridge query synced-metrics on this computer to see saved "
                "kinds of data and dates. To use AI, give it command access here and "
                "the Health Bridge Skill. Optional MCP settings are in "
                "access_descriptors."
            ),
        ],
        warning=(
            "Keep this single-use invitation private. Sharing it before use "
            "lets someone else connect an iPhone. Progress stays available "
            "until the link expires. "
            f"{transport_notice}"
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
    prepared: list[str] = []
    verified = connection_wizard(Path(manifest.db), names, prepared_clients=prepared)
    status: ClientConfigurationStatus = "not_requested"
    if prepared:
        status = (
            "configured_and_verified"
            if set(prepared) == set(verified)
            else "configuration_prepared"
        )
    return manifest.model_copy(
        update={
            "configured_mcp_clients": prepared,
            "client_configuration_status": status,
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


def render_setup_summary(
    manifest: SetupManifest, *, reveal_invitation: bool = True
) -> str:
    lines = [
        "Health Bridge is running."
        if manifest.receiver_service_status == "supervised_healthy"
        else "Health Bridge is prepared, but its background process has not started."
    ]
    if manifest.receiver_service_status == "prepared":
        message = (
            "Start saving data on this computer: "
            f"{shlex.join(manifest.receiver_start_command)}"
        )
        lines.append(message)
    if manifest.pairing_status == "pending" and reveal_invitation:
        _, invitation = read_invitation_page(Path(manifest.setup_page))
        origin = (manifest.receiver_health_url or "").removesuffix("/health")
        connection_url = manifest.local_setup_url or origin + invitation_page_route(
            invitation
        )
        lines.append(f"Open your private connection page: {connection_url}")
        message = (
            "On a computer screen, scan its QR with iPhone Camera. On your "
            "iPhone, tap its Open button."
        )
        lines.append(message)
    elif manifest.pairing_status == "pending":
        command = shlex.join([manifest.access_descriptors[0].command, "setup"])
        message = f"Run {command} in your terminal to open the iPhone connection page."
        lines.append(message)
    elif manifest.data_receipt_status == "received":
        lines.append("iPhone connected. Health records are saved on this computer.")
    else:
        lines.append("iPhone connected. No health records saved yet.")
        message = (
            "In Health Bridge for AI (companion app), tap Allow Health Access, "
            "choose the kinds of data it may read, then turn on Automatic Sync."
        )
        lines.append(message)
    if manifest.data_receipt_status == "received":
        command = shlex.join(
            [manifest.access_descriptors[0].command, "query", "synced-metrics"]
        )
        lines.append(f"See saved kinds of data and their dates: {command}")
    lines.append(
        "Your AI needs command access to this computer to use the Health Bridge Skill."
    )
    return "\n".join(lines)

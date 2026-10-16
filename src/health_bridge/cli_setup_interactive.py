import os
import queue
import shlex
import subprocess  # nosec B404 - only TimeoutExpired is handled here; no execution.
import sys
import threading
import time
import webbrowser
from collections.abc import Generator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import replace
from pathlib import Path
from typing import Final

import httpx2
import typer
from click import IntRange, getchar
from pydantic import TypeAdapter

from health_bridge import __version__
from health_bridge.cli_config import saved_configuration
from health_bridge.cli_setup import (
    SetupManifest,
    SetupRequest,
    configure_mcp_clients,
    setup_transport_notice,
)
from health_bridge.cli_setup_runtime import private_route
from health_bridge.connect_wizard import connection_wizard
from health_bridge.mailbox.helper_distribution_contract import (
    HELPER_RELEASE_MANIFEST_ADAPTER,
)
from health_bridge.mailbox.helper_download import install_published_helper
from health_bridge.mailbox.helper_lifecycle import (
    HelperError,
    HelperPaths,
    HelperStatusCode,
    install_helper,
    read_helper_status,
)
from health_bridge.mailbox.native_ack_publication import default_native_ack_publisher
from health_bridge.queries.catalog import list_synced_metrics
from health_bridge.receiver.invitations import (
    local_setup_pairing,
    pairing_setup_progress,
)
from health_bridge.receiver.pairing_setup_page import (
    invitation_page_route,
    read_invitation_page,
)

USE_PRIVATE_URL: Final = 2
LEAVE_PREREQUISITE: Final = 3
LAST_OF_THREE: Final = 2
browser_enabled: ContextVar[bool] = ContextVar("browser_enabled", default=True)


@contextmanager
def browser_policy(enabled: bool) -> Generator[None]:
    token = browser_enabled.set(enabled)
    try:
        yield
    finally:
        browser_enabled.reset(token)


def human_terminal() -> bool:
    return (
        sys.stdin.isatty()
        and sys.stdout.isatty()
        and not any(
            os.environ.get(name) for name in ("CI", "CODEX_THREAD_ID", "CLAUDECODE")
        )
    )


def require_client_mode(automatic: bool, clients: list[str] | None) -> None:
    if automatic and clients:
        message = (
            "Client configuration requires a separate invocation "
            "without --json or --no-input."
        )
        raise typer.BadParameter(message)


def guide_request(
    request: SetupRequest, enabled: bool, explicit: set[str] | None = None
) -> SetupRequest:
    if not enabled:
        return request
    prepared = prepare_interactively(request, explicit)
    if prepared is None:
        raise EOFError
    typer.echo("Starting Health Bridge on this computer to save the data you choose...")
    return prepared


def choose(title: str, options: tuple[str, ...]) -> int:
    typer.echo(title)
    for index, option in enumerate(options, 1):
        typer.echo(f"  {index}. {option}")
    if "NO_COLOR" in os.environ or os.environ.get("TERM", "dumb") == "dumb":
        return (
            TypeAdapter(int).validate_python(
                typer.prompt("Choice", default=1, type=IntRange(1, len(options)))
            )
            - 1
        )
    selected = 0
    typer.echo(f"> {options[selected]} (arrows, Enter; Esc to leave)", nl=False)
    while True:
        key = getchar()
        if key in {"\x1b", "\x04"}:
            raise EOFError
        if key in {"\r", "\n"}:
            typer.echo()
            return selected
        if key in {"\x1b[A", "\x1bOA"}:
            selected = (selected - 1) % len(options)
        if key in {"\x1b[B", "\x1bOB"}:
            selected = (selected + 1) % len(options)
        if key.isdigit() and 1 <= int(key) <= len(options):
            selected = int(key) - 1
        typer.echo(f"\r\x1b[2K> {options[selected]} (Enter to select)", nl=False)


def resume_request(request: SetupRequest, explicit: set[str]) -> SetupRequest:
    if not request.db_path.is_file():
        return request
    paired = local_setup_pairing(request.db_path)
    if paired is not None:
        return replace(
            request,
            receiver_url=request.receiver_url
            if "receiver_url" in explicit
            else request.receiver_url or paired.receiver_url,
            label=request.label if "label" in explicit else paired.label,
            transport=request.transport
            if "transport" in explicit
            else "icloud-mailbox"
            if paired.transport == "mailbox"
            else "direct",
        )
    if not request.setup_page_path.is_file():
        return request
    _, invitation = read_invitation_page(request.setup_page_path)
    progress = pairing_setup_progress(request.db_path, invitation.invitation_secret)
    if progress is None:
        return request
    return replace(
        request,
        receiver_url=request.receiver_url or invitation.receiver_url,
        label=request.label if "label" in explicit else invitation.label,
        transport=(
            request.transport
            if "transport" in explicit
            else "icloud-mailbox"
            if invitation.transport == "mailbox"
            else "direct"
        ),
    )


def saved_request(
    request: SetupRequest, explicit: set[str]
) -> tuple[SetupRequest, str | None]:
    try:
        config = saved_configuration()
    except typer.BadParameter:
        if "db" not in explicit:
            raise
        return request, None
    if config is None or config.setup is None or Path(config.db) != request.db_path:
        return request, None
    saved = config.setup
    return replace(
        saved,
        executable=request.executable,
        receiver_url=request.receiver_url
        if "receiver_url" in explicit
        else saved.receiver_url,
        label=request.label if "label" in explicit else saved.label,
        setup_page_path=request.setup_page_path
        if "setup_page" in explicit
        else saved.setup_page_path,
        receiver_host=request.receiver_host
        if "receiver_host" in explicit
        else saved.receiver_host,
        receiver_port=request.receiver_port
        if "receiver_port" in explicit
        else saved.receiver_port,
        transport=request.transport if "transport" in explicit else saved.transport,
        mailbox_root=request.mailbox_root
        if "mailbox_root" in explicit
        else saved.mailbox_root,
        icloud_container_identifier=request.icloud_container_identifier
        if "icloud_container_identifier" in explicit
        else saved.icloud_container_identifier,
        allow_loopback_receiver=request.allow_loopback_receiver
        if "allow_loopback_receiver" in explicit
        else saved.allow_loopback_receiver,
        allow_nonlocal_receiver_address=request.allow_nonlocal_receiver_address
        if "allow_nonlocal_receiver_address" in explicit
        else saved.allow_nonlocal_receiver_address,
    ), config.service_name


def choose_connection(request: SetupRequest, explicit: set[str]) -> SetupRequest | None:
    message = (
        "Tailscale is a connection app. Install it on this computer and your iPhone, "
        "sign in with the same account, and keep it connected on the iPhone."
    )
    typer.echo(message)
    options = ("Tailscale (Recommended)",)
    if sys.platform == "darwin":
        message = (
            "iCloud sends data through iCloud Drive using the same Apple Account "
            "on your Mac and iPhone. Stay logged in on the Mac; delivery can "
            "be delayed."
        )
        typer.echo(message)
        options += ("iCloud Mailbox (Mac only, Beta)",)
    options += ("More connection options", "Set up later")
    while True:
        selected = options[
            choose("How should your iPhone send data to this computer?", options)
        ]
        if selected == "Set up later":
            return None
        if selected == "iCloud Mailbox (Mac only, Beta)":
            try:
                mailbox = prepare_mailbox(replace(request, transport="icloud-mailbox"))
            except (OSError, ValueError) as exc:
                typer.echo(f"iCloud is not ready: {exc}")
                continue
            if mailbox is None:
                continue
            return mailbox
        if selected == "More connection options":
            prepared = existing_route(request, explicit)
            if prepared is None:
                continue
            return prepared
        return request


def prepare_mailbox(request: SetupRequest) -> SetupRequest | None:
    status = read_helper_status(home=Path.home(), expected_version=__version__)
    if status.code is not HelperStatusCode.READY:
        if status.code is not HelperStatusCode.NOT_INSTALLED:
            message = (
                "The installed iCloud helper does not match this Health Bridge release "
                "or has changed. It has been left in place. Choose another connection "
                "or pause until you have a verified matching installation."
            )
            typer.echo(message)
            return None
        if not install_mailbox_interactively():
            return None
    manifest = HELPER_RELEASE_MANIFEST_ADAPTER.validate_json(
        HelperPaths.production().manifest.read_bytes()
    )
    container = (
        request.icloud_container_identifier
        or manifest.bundle.icloud_container_identifier
    )
    if container != manifest.bundle.icloud_container_identifier:
        message = "The selected iCloud folder does not belong to the installed helper."
        raise ValueError(message)
    documents = (
        Path.home()
        / "Library/Mobile Documents"
        / container.replace(".", "~")
        / "Documents"
    )
    if not request.receiver_url:
        default_native_ack_publisher().require_native_pairing()
    return replace(
        request,
        receiver_url=request.receiver_url or None,
        icloud_container_identifier=container,
        mailbox_root=request.mailbox_root or documents / "HealthBridgeMailbox/v1",
    )


def install_mailbox_interactively() -> bool:
    choice = choose(
        "Prepare the signed iCloud helper matching this release",
        (
            "Download and verify the matching signed release",
            "Back to connection choices",
            "Set up later",
            "Advanced/offline: choose archive and manifest files",
        ),
    )
    if choice == LAST_OF_THREE:
        raise EOFError
    if choice == 1:
        return False
    if choice == 0:
        typer.echo(f"Verify and install the matching signed helper {__version__}.")
        if not typer.confirm("Download and install this helper?", default=False):
            return False
        try:
            _ = install_published_helper()
        except (HelperError, OSError, ValueError, httpx2.HTTPError):
            message = (
                "A matching signed helper is not available yet, or verification "
                "failed. Existing state was kept. Choose Tailscale, go back, "
                "or retry after the protected signed release is published."
            )
            typer.echo(message)
            return False
        return True
    return install_mailbox_offline()


def install_mailbox_offline() -> bool:
    message = (
        f"iCloud needs the signed Health Bridge helper {__version__} on this Mac "
        "to confirm delivery through iCloud Drive. Its matching release files "
        "are not publicly available yet. If you already have the matching archive "
        "and manifest, select them below; otherwise choose another connection or pause."
    )
    typer.echo(message)
    choice = choose(
        "Prepare the iCloud helper",
        (
            "Choose downloaded helper files",
            "Back to connection choices",
            "Set up later",
        ),
    )
    if choice == LAST_OF_THREE:
        raise EOFError
    if choice == 1:
        return False
    archive = (
        TypeAdapter(str)
        .validate_python(
            typer.prompt(
                (
                    "Helper archive path (.zip, for example "
                    "~/Downloads/helper.zip; blank to return)"
                ),
                default="",
            )
        )
        .strip()
    )
    if not archive:
        return False
    manifest_path = (
        TypeAdapter(str)
        .validate_python(
            typer.prompt(
                (
                    "Matching manifest path (.json, for example "
                    "~/Downloads/helper-manifest.json; blank to return)"
                ),
                default="",
            )
        )
        .strip()
    )
    if not manifest_path:
        return False
    message = (
        f"This installs the signed helper in {HelperPaths.production().helpers_dir}. "
        "It checks the release and signature before installation. "
        "This step does not start Health Bridge or log in to a network."
    )
    typer.echo(message)
    if not typer.confirm("Install this matching iCloud helper?", default=False):
        return False
    try:
        _ = install_helper(Path(archive).expanduser(), Path(manifest_path).expanduser())
    except HelperError:
        message = (
            "These files could not be installed as a verified matching helper. "
            "Existing files were kept. Select the matching signed archive and "
            "manifest, "
            "or use another connection while the release is unavailable."
        )
        typer.echo(message)
        return False
    return True


def existing_route(request: SetupRequest, explicit: set[str]) -> SetupRequest | None:
    options = (
        "Use my own secure connection (advanced)",
        "Same network only",
        "Back to connection choices",
    )
    selected = choose("Use a connection you have already prepared", options)
    if selected == LAST_OF_THREE:
        return None
    message = (
        "Use an already configured, phone-reachable secure route to THIS computer. "
        "This is not an ordinary website. Typing a URL does not create a route. "
        "If unsure, go back and choose guided Tailscale. "
        "Enter this computer's HTTPS address ending in /v1/batches. "
        "Format: https://your-computer.example/v1/batches (use your real address). "
        "The same address must also forward /health, /setup and /v1/pairing/redeem."
    )
    if selected == 1:
        message = (
            "Keep both devices on the same Wi-Fi network. Use this computer's "
            "address, "
            f"for example http://my-computer.local:{request.receiver_port}/v1/batches. "
            "Allow Local Network access on the iPhone when asked."
        )
    typer.echo(message)
    while True:
        url = (
            TypeAdapter(str)
            .validate_python(
                typer.prompt("Computer connection URL (blank to return)", default="")
            )
            .strip()
        )
        if not url:
            return None
        prepared = replace(request, receiver_url=url)
        if selected == 1 and "receiver_host" not in explicit:
            prepared = replace(prepared, receiver_host="0.0.0.0")  # nosec B104 - explicit LAN selection; # noqa: S104
        try:
            _ = setup_transport_notice(prepared)
        except ValueError as exc:
            typer.echo(str(exc))
        else:
            return prepared


def prepare_interactively(
    request: SetupRequest, explicit: set[str] | None = None
) -> SetupRequest | None:
    message = (
        "Save the Apple Health data you choose from your iPhone on this computer, "
        "where you and your AI can read it. Health access is read-only."
    )
    typer.echo(message)
    platform = {
        "darwin": "Mac",
        "linux": "Linux computer",
        "win32": "Windows computer",
    }.get(sys.platform, "computer")
    message = (
        f"Continue setup on this {platform}."
        if request.db_path.is_file()
        else f"Set up this {platform} to save your data."
    )
    typer.echo(message)
    explicit = explicit or set()
    if request.transport == "icloud-mailbox":
        prepared = prepare_mailbox(request)
        if prepared is None:
            selected = choose_connection(
                replace(
                    request,
                    transport="direct",
                    mailbox_root=None,
                    icloud_container_identifier=None,
                ),
                explicit,
            )
            if selected is None:
                return None
            return prepare_private_connection(selected, explicit)
        request = prepared
    if request.receiver_url:
        return request
    if "transport" not in explicit:
        selected = choose_connection(request, explicit)
        if selected is None:
            return None
        request = selected
    return prepare_private_connection(request, explicit)


def prepare_private_connection(
    request: SetupRequest, explicit: set[str]
) -> SetupRequest | None:
    if request.transport == "icloud-mailbox":
        return request
    while not request.receiver_url:
        try:
            _ = private_route(request.receiver_port)
        except (OSError, RuntimeError, ValueError) as exc:
            typer.echo(str(exc))
            choice = choose(
                (
                    "Install Tailscale on both devices, sign in with the same account, "
                    "and turn it on on your iPhone. Then retry here."
                ),
                (
                    "Open official Tailscale setup page",
                    "Retry detection",
                    "Use an existing private URL",
                    "Continue later",
                ),
            )
            if choice == 0:
                open_page("https://tailscale.com/download")
            if choice == USE_PRIVATE_URL:
                prepared = existing_route(request, explicit)
                if prepared is not None:
                    request = prepared
            if choice == LEAVE_PREREQUISITE:
                return None
        else:
            message = (
                "Tailscale is connected on this computer. Preparing its "
                "private connection next."
            )
            typer.echo(message)
            break
    return request


def open_browser_bounded(url: str, timeout: float = 3) -> bool:
    result: queue.Queue[bool] = queue.Queue(maxsize=1)

    def launch() -> None:
        try:
            result.put(webbrowser.open(url))
        except (OSError, webbrowser.Error):
            result.put(item=False)

    threading.Thread(target=launch, daemon=True).start()
    try:
        return result.get(timeout=timeout)
    except queue.Empty:
        return False


def open_page(url: str) -> None:
    desktop = sys.platform in {"darwin", "win32"} or bool(
        os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")
    )
    opened = False
    if desktop and browser_enabled.get() and not os.environ.get("SSH_CONNECTION"):
        opened = open_browser_bounded(url)
    message = (
        "Opened the page in your browser."
        if opened
        else "No local browser opened. Open this URL on a trusted screen:"
    )
    typer.echo(message)
    typer.echo(url)


def wait_tick() -> None:
    time.sleep(1)


def follow_connection(manifest: SetupManifest) -> SetupManifest:
    if manifest.data_receipt_status == "received":
        return manifest
    if manifest.receiver_service_status != "supervised_healthy":
        return manifest
    invitation = None
    if manifest.pairing_status == "pending":
        _, invitation = read_invitation_page(Path(manifest.setup_page))
        if manifest.local_setup_url:
            message = (
                "This iCloud setup URL is local-only: open it on this Mac's screen "
                "and scan its QR with your iPhone. On SSH or an unseen Mac Mini, "
                "use trusted screen sharing to this Mac; the loopback URL cannot "
                "be opened directly on your phone or another computer."
            )
            typer.echo(message)
        else:
            message = (
                "Open this private setup URL on your iPhone or another trusted "
                "computer using the configured network route. Keep Tailscale "
                "connected on both devices if selected."
            )
            typer.echo(message)
        open_page(
            manifest.local_setup_url
            or (manifest.receiver_health_url or "").removesuffix("/health")
            + invitation_page_route(invitation)
        )
        message = (
            "On a computer screen, scan the QR with iPhone Camera. On your "
            "iPhone, tap the page's Open button."
        )
        typer.echo(message)
    message = (
        "In Health Bridge for AI (companion app), tap Allow Health Access and "
        "choose which kinds of data it may read."
    )
    typer.echo(message)
    message = (
        "Turn on Automatic Sync to send that data to this computer. You can "
        "tap Sync Now to send it now."
    )
    typer.echo(message)
    message = (
        "Waiting up to 10 minutes for health records to be saved. Ctrl-C "
        "pauses this check; Health Bridge keeps running."
    )
    typer.echo(message)
    deadline = time.monotonic() + 600
    previous = None
    while time.monotonic() < deadline:
        try:
            secret = invitation.invitation_secret if invitation is not None else None
            paired = local_setup_pairing(
                Path(manifest.db),
                secret,
                invitation_ids=manifest.paired_invitation_ids
                if secret is None
                else None,
            )
            progress = (
                paired.progress
                if paired is not None
                else pairing_setup_progress(Path(manifest.db), secret)
                if secret is not None
                else None
            )
        except BlockingIOError:
            wait_tick()
            continue
        if progress is None:
            typer.echo("The connection page expired or is unavailable.")
            return manifest
        manifest = manifest.model_copy(
            update={
                "pairing_status": progress.pairing_status,
                "data_receipt_status": progress.data_receipt_status,
            }
        )
        if progress != previous:
            message = (
                "Health records saved. Checking that they can be read..."
                if progress.data_receipt_status == "received"
                else (
                    "iPhone connected. No health records saved yet. "
                    "Check Allow Health Access and Automatic Sync in the app."
                )
                if progress.pairing_status == "paired"
                else "Waiting for your iPhone to connect..."
            )
            typer.echo(message)
            previous = progress
        if progress.data_receipt_status == "received":
            return manifest
        wait_tick()
    message = (
        "No saved-record confirmation arrived before the timeout. Check the "
        "iPhone's network route, Health access and Sync Now. For iCloud, check "
        "the same Apple Account and iCloud Drive on both devices. Rerun setup "
        "to resume with the existing connection and data."
    )
    typer.echo(message)
    return manifest


def finish_interactively(manifest: SetupManifest, requested: tuple[str, ...]) -> None:
    executable = manifest.access_descriptors[0].command
    setup_command = shlex.join([executable, "setup"])
    paused = False
    try:
        manifest = follow_connection(manifest)
    except (EOFError, KeyboardInterrupt, typer.Abort):
        paused = True
    if paused or manifest.data_receipt_status != "received":
        message = (
            "Setup is paused. Health Bridge keeps running on this computer; "
            "your connection and any saved data are kept. Continue in the iPhone app, "
            f"then run {setup_command} to check for saved records."
        )
        if manifest.receiver_service_status != "supervised_healthy":
            message = (
                "Setup is prepared, but Health Bridge is not running. "
                f"Run {setup_command} on your Mac or Linux computer to start it."
            )
        typer.echo(message)
        return
    coverage = list_synced_metrics(Path(manifest.db))
    count = sum(metric.record_count > 0 for metric in coverage.metrics)
    if not count:
        message = (
            "Setup is not complete: the saved-data query returned no records. "
            "Your connection is kept. Tap Sync Now in the iPhone app, then run "
            f"{setup_command} to check again."
        )
        typer.echo(message)
        return
    kind = "kind" if count == 1 else "kinds"
    message = (
        "Setup complete. Health records are saved on this computer, and a "
        f"read-only query found {count} {kind} of data."
    )
    typer.echo(message)
    try:
        if requested:
            manifest = configure_mcp_clients(manifest, requested)
        else:
            _ = connection_wizard(Path(manifest.db))
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
        message = (
            "The selected AI app could not be connected. Check its MCP "
            "connection settings. "
            "Your records are saved and health-bridge commands still work."
        )
        typer.echo(message)
    if (
        manifest.configured_mcp_clients
        and manifest.client_configuration_status == "configured_and_verified"
    ):
        message = (
            "The selected AI app's connection settings were saved and checked. "
            "You can now try a question in that app."
        )
        typer.echo(message)
    elif manifest.client_configuration_status == "configuration_prepared":
        message = (
            "The selected AI app's connection settings were saved, but not all "
            "server checks passed. Your installation and records are kept. "
            "Fix the backend/database, then run health-bridge connect to retry."
        )
        typer.echo(message)
    command = shlex.join([executable, "query", "synced-metrics"])
    message = f"Run {command} to see the saved kinds of data and their dates."
    typer.echo(message)
    message = (
        "To use these records with AI, give your AI command access to this "
        "computer and the Health Bridge Skill."
    )
    typer.echo(message)

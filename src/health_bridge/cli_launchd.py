"""Fixed-output launchd CLI boundary kept as one auditable unit.

No-excuse size audit: # noqa: SIZE_OK — one boundary normalizes all CLI errors.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Annotated, Final, Never

import typer

from health_bridge.launchd import (
    LaunchctlAdapter,
    LaunchdServiceCode,
    LaunchdServiceError,
    LaunchdServiceRequest,
    LaunchdServiceResult,
    LocalHealthProbe,
    active_launch_agent_artifacts_exist,
    classify_launch_agent_status,
    install_launch_agent,
    load_owned_launch_agent_request,
    restart_launch_agent,
    uninstall_launch_agent,
    upgrade_launch_agent,
    validate_launch_agent,
)
from health_bridge.launchd.models import LaunchdServiceErrorCode, service_paths
from health_bridge.launchd.private_artifacts import path_entry_exists

LAUNCHCTL_PATH: Final = Path("/bin/launchctl")
# `kickstart -k` may wait for both launchd throttling and child ExitTimeOut.
# Keep a bounded margin beyond that manifest-level restart budget.
LAUNCHCTL_TIMEOUT_SECONDS: Final = 45.0
HEALTH_TIMEOUT_SECONDS: Final = 2.0
_DRIFT_ERROR_CODES: Final = frozenset(
    {
        LaunchdServiceErrorCode.FOREIGN_MANIFEST,
        LaunchdServiceErrorCode.MANIFEST_DRIFT,
        LaunchdServiceErrorCode.UNSAFE_FILESYSTEM,
        LaunchdServiceErrorCode.UNSAFE_PERMISSIONS,
    }
)

service_app = typer.Typer(
    add_completion=False,
    help=("Explicitly install and manage the per-user macOS mailbox receiver service."),
)


@service_app.command(
    "validate",
    help="Validate existing mailbox inputs without installing a service.",
)
def validate_service(
    executable: Annotated[
        Path,
        typer.Option("--executable", help="Absolute health-bridge executable path."),
    ],
    db: Annotated[
        Path,
        typer.Option("--db", help="Existing private receiver database path."),
    ],
    mailbox_root: Annotated[
        Path,
        typer.Option("--mailbox-root", help="Existing iCloud mailbox v1 root."),
    ],
    icloud_container_identifier: Annotated[
        str,
        typer.Option(
            "--icloud-container-identifier",
            help="Expected Health Bridge iCloud container identifier.",
        ),
    ],
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    request = LaunchdServiceRequest(
        executable=executable,
        db_path=db,
        mailbox_root=mailbox_root,
        icloud_container_identifier=icloud_container_identifier,
        home=Path.home(),
        uid=os.geteuid(),
    )
    try:
        result = validate_launch_agent(request)
    except LaunchdServiceError as exc:
        _exit_with_error(exc, json_output)
    _emit_result(result, json_output)


@service_app.command(
    "install",
    help="Explicitly install and start the per-user mailbox LaunchAgent.",
)
def install_service(
    executable: Annotated[
        Path,
        typer.Option("--executable", help="Absolute health-bridge executable path."),
    ],
    db: Annotated[
        Path,
        typer.Option("--db", help="Existing private receiver database path."),
    ],
    mailbox_root: Annotated[
        Path,
        typer.Option("--mailbox-root", help="Existing iCloud mailbox v1 root."),
    ],
    icloud_container_identifier: Annotated[
        str,
        typer.Option(
            "--icloud-container-identifier",
            help="Expected Health Bridge iCloud container identifier.",
        ),
    ],
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    _require_macos(json_output)
    request = LaunchdServiceRequest(
        executable=executable,
        db_path=db,
        mailbox_root=mailbox_root,
        icloud_container_identifier=icloud_container_identifier,
        home=Path.home(),
        uid=os.geteuid(),
    )
    try:
        result = install_launch_agent(request, _launchctl(request.uid))
    except LaunchdServiceError as exc:
        _exit_with_error(exc, json_output)
    _emit_result(result, json_output)


@service_app.command(
    "upgrade",
    help="Explicitly replace one owned mailbox LaunchAgent generation.",
)
def upgrade_service(
    executable: Annotated[
        Path,
        typer.Option("--executable", help="Absolute health-bridge executable path."),
    ],
    db: Annotated[
        Path,
        typer.Option("--db", help="Existing private receiver database path."),
    ],
    mailbox_root: Annotated[
        Path,
        typer.Option("--mailbox-root", help="Existing iCloud mailbox v1 root."),
    ],
    icloud_container_identifier: Annotated[
        str,
        typer.Option(
            "--icloud-container-identifier",
            help="Expected Health Bridge iCloud container identifier.",
        ),
    ],
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    _require_macos(json_output)
    desired = LaunchdServiceRequest(
        executable=executable,
        db_path=db,
        mailbox_root=mailbox_root,
        icloud_container_identifier=icloud_container_identifier,
        home=Path.home(),
        uid=os.geteuid(),
    )
    try:
        current = load_owned_launch_agent_request(service_paths(Path.home()).config)
        result = upgrade_launch_agent(
            current,
            desired,
            _launchctl(desired.uid),
        )
    except LaunchdServiceError as exc:
        _exit_with_error(exc, json_output)
    _emit_result(result, json_output)


@service_app.command(
    "status",
    help="Report one privacy-safe mailbox LaunchAgent state.",
)
def service_status(
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    _require_macos(json_output)
    try:
        paths = service_paths(Path.home())
        config_path = paths.config
        if not config_path.exists():
            code = (
                LaunchdServiceCode.MANIFEST_DRIFT
                if active_launch_agent_artifacts_exist(paths)
                else LaunchdServiceCode.NOT_INSTALLED
            )
            _emit_result(
                LaunchdServiceResult(code=code),
                json_output,
            )
            raise typer.Exit(code=1)
        request = load_owned_launch_agent_request(config_path)
        inspected = _launchctl(request.uid).inspect()
        launchctl_output = inspected.stdout if inspected.returncode == 0 else ""
        health = None
        if any(
            line.strip() == "state = running" for line in launchctl_output.splitlines()
        ):
            health = (
                LocalHealthProbe(timeout_seconds=HEALTH_TIMEOUT_SECONDS)
                .probe(request.host, request.port)
                .value
            )
        result = classify_launch_agent_status(
            request,
            launchctl_output=launchctl_output,
            health=health,
        )
    except LaunchdServiceError as exc:
        if exc.code in _DRIFT_ERROR_CODES:
            result = LaunchdServiceResult(code=LaunchdServiceCode.MANIFEST_DRIFT)
        else:
            _exit_with_error(exc, json_output)
    except OSError:
        _exit_with_error(
            LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM),
            json_output,
        )
    _emit_result(result, json_output)
    if result.code is not LaunchdServiceCode.RUNNING_HEALTHY:
        raise typer.Exit(code=1)


@service_app.command(
    "restart",
    help="Restart the service and run one bounded launchd recovery if needed.",
)
def restart_service(
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    _require_macos(json_output)
    try:
        request = load_owned_launch_agent_request(service_paths(Path.home()).config)
        result = restart_launch_agent(request, _launchctl(request.uid))
    except LaunchdServiceError as exc:
        _exit_with_error(exc, json_output)
    _emit_result(result, json_output)


@service_app.command(
    "uninstall",
    help="Stop the service and remove only Health Bridge-owned service files.",
)
def uninstall_service(
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    _require_macos(json_output)
    try:
        paths = service_paths(Path.home())
        config_path = paths.config
        if not active_launch_agent_artifacts_exist(paths):
            _emit_result(
                LaunchdServiceResult(code=LaunchdServiceCode.ALREADY_UNINSTALLED),
                json_output,
            )
            return
        if not path_entry_exists(config_path) or not path_entry_exists(paths.manifest):
            _exit_with_error(
                LaunchdServiceError(LaunchdServiceErrorCode.MANIFEST_DRIFT),
                json_output,
            )
        request = load_owned_launch_agent_request(config_path)
        result = uninstall_launch_agent(request, _launchctl(request.uid))
    except LaunchdServiceError as exc:
        _exit_with_error(exc, json_output)
    except OSError:
        _exit_with_error(
            LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM),
            json_output,
        )
    _emit_result(result, json_output)


def _launchctl(uid: int) -> LaunchctlAdapter:
    return LaunchctlAdapter(
        launchctl=LAUNCHCTL_PATH,
        uid=uid,
        timeout_seconds=LAUNCHCTL_TIMEOUT_SECONDS,
    )


def _require_macos(json_output: bool) -> None:
    if sys.platform != "darwin":
        _exit_with_error(
            LaunchdServiceError(LaunchdServiceErrorCode.UNSUPPORTED_HOST),
            json_output,
        )


def _exit_with_error(error: LaunchdServiceError, json_output: bool) -> Never:
    if json_output:
        typer.echo(json.dumps({"code": error.code.value}, sort_keys=True))
    else:
        typer.echo(str(error), err=True)
    raise typer.Exit(code=1)


def _emit_result(result: LaunchdServiceResult, json_output: bool) -> None:
    if json_output:
        typer.echo(json.dumps({"code": result.code.value}, sort_keys=True))
        return
    typer.echo(f"code: {result.code.value}")

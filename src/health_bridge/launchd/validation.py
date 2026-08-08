from __future__ import annotations

import os
import stat
from pathlib import Path
from typing import Final, Literal

from health_bridge.launchd.models import (
    MAX_TCP_PORT,
    LaunchdServiceCode,
    LaunchdServiceError,
    LaunchdServiceErrorCode,
    LaunchdServiceRequest,
    LaunchdServiceResult,
)
from health_bridge.private_files import require_private_parent

_CONTROL_CHARACTERS: Final = frozenset(chr(value) for value in (*range(32), 127))


def validate_launch_agent(request: LaunchdServiceRequest) -> LaunchdServiceResult:
    _ = validate_launch_agent_structure(request)
    _validate_existing_path(
        request.executable,
        kind="executable",
        allow_root_owner=True,
        owner_only=False,
    )
    _validate_existing_path(
        request.db_path,
        kind="file",
        allow_root_owner=False,
        owner_only=True,
    )
    _validate_existing_path(
        request.mailbox_root,
        kind="directory",
        allow_root_owner=False,
        owner_only=True,
    )
    return LaunchdServiceResult(code=LaunchdServiceCode.VALID)


def validate_launch_agent_structure(
    request: LaunchdServiceRequest,
) -> LaunchdServiceResult:
    _validate_request_values(request)
    _validate_existing_path(
        request.home,
        kind="directory",
        allow_root_owner=False,
        owner_only=False,
    )
    _validate_expected_mailbox_topology(request)
    _validate_artifact_topology(request)
    return LaunchdServiceResult(code=LaunchdServiceCode.VALID)


def _validate_request_values(request: LaunchdServiceRequest) -> None:
    if request.uid < 0 or request.uid != os.geteuid():
        raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
    if request.host != "127.0.0.1" or not 1 <= request.port <= MAX_TCP_PORT:
        raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
    for value in (
        str(request.executable),
        str(request.db_path),
        str(request.mailbox_root),
        str(request.home),
        request.icloud_container_identifier,
    ):
        if not value or any(character in _CONTROL_CHARACTERS for character in value):
            raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
    for path in (
        request.executable,
        request.db_path,
        request.mailbox_root,
        request.home,
    ):
        if not path.is_absolute():
            raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)


def _validate_existing_path(
    path: Path,
    *,
    kind: Literal["directory", "executable", "file"],
    allow_root_owner: bool,
    owner_only: bool,
) -> None:
    try:
        resolved = path.resolve(strict=True)
        entry = path.lstat()
        require_private_parent(path.parent)
    except PermissionError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_PERMISSIONS) from exc
    except (OSError, RuntimeError) as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    if path != resolved or stat.S_ISLNK(entry.st_mode):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
    expected_owner = {os.geteuid(), 0} if allow_root_owner else {os.geteuid()}
    prohibited_mode = 0o077 if owner_only else 0o022
    if entry.st_uid not in expected_owner or bool(entry.st_mode & prohibited_mode):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_PERMISSIONS)
    if kind == "directory" and not stat.S_ISDIR(entry.st_mode):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
    if kind in {"file", "executable"} and not stat.S_ISREG(entry.st_mode):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
    if kind == "executable" and not bool(entry.st_mode & 0o111):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_PERMISSIONS)


def _validate_expected_mailbox_topology(request: LaunchdServiceRequest) -> None:
    component = request.icloud_container_identifier.replace(".", "~")
    if Path(component).name != component or component in {"", ".", ".."}:
        raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
    expected = (
        request.home
        / "Library/Mobile Documents"
        / component
        / "Documents/HealthBridgeMailbox/v1"
    )
    if request.mailbox_root != expected:
        raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)


def _validate_artifact_topology(request: LaunchdServiceRequest) -> None:
    for path, owner_only in (
        (request.paths.state_dir, True),
        (request.paths.manifest.parent, False),
    ):
        if not path.exists():
            continue
        try:
            entry = path.lstat()
        except OSError as exc:
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.UNSAFE_FILESYSTEM
            ) from exc
        if stat.S_ISLNK(entry.st_mode) or not stat.S_ISDIR(entry.st_mode):
            raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
        prohibited_mode = 0o077 if owner_only else 0o022
        if entry.st_uid != os.geteuid() or bool(entry.st_mode & prohibited_mode):
            raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_PERMISSIONS)

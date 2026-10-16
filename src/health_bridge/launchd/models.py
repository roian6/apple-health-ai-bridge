from __future__ import annotations

import re
from dataclasses import dataclass
from enum import StrEnum, unique
from pathlib import Path
from typing import ClassVar, Final, Literal

from pydantic import BaseModel, ConfigDict
from typing_extensions import override

LAUNCH_AGENT_LABEL: Final = "dev.healthbridge.companion"
MAX_TCP_PORT: Final = 65_535
SERVICE_STATE_RELATIVE: Final = Path("Library/Application Support/HealthBridge/launchd")


@unique
class LaunchdServiceCode(StrEnum):
    VALID = "valid"
    INSTALLED = "installed"
    ALREADY_INSTALLED = "already_installed"
    NOT_INSTALLED = "not_installed"
    INSTALLED_INACTIVE = "installed_inactive"
    RUNNING_HEALTHY = "running_healthy"
    DEGRADED_RETRYABLE = "degraded_retryable"
    TERMINAL_FAILED = "terminal_failed"
    HELPER_NOT_READY = "helper_not_ready"
    HELPER_DRIFT = "helper_drift"
    MANIFEST_DRIFT = "manifest_drift"
    RESTARTED = "restarted"
    RESTART_RECOVERED = "restart_recovered"
    UNINSTALLED = "uninstalled"
    ALREADY_UNINSTALLED = "already_uninstalled"
    UPGRADED = "upgraded"
    ALREADY_CURRENT = "already_current"


@unique
class LaunchdServiceErrorCode(StrEnum):
    UNSUPPORTED_HOST = "unsupported_host"
    INVALID_CONFIGURATION = "invalid_configuration"
    UNSAFE_FILESYSTEM = "unsafe_filesystem"
    UNSAFE_PERMISSIONS = "unsafe_permissions"
    FOREIGN_MANIFEST = "foreign_manifest"
    MANIFEST_DRIFT = "manifest_drift"
    LAUNCHCTL_TIMEOUT = "launchctl_timeout"
    LAUNCHCTL_FAILED = "launchctl_failed"
    NOT_INSTALLED = "not_installed"
    UPGRADE_RECOVERY_REQUIRED = "upgrade_recovery_required"


@unique
class LocalHealthStatus(StrEnum):
    OK = "ok"
    DEGRADED = "degraded"
    UNAVAILABLE = "unavailable"
    TERMINAL = "terminal"


_ERROR_MESSAGES: Final[dict[LaunchdServiceErrorCode, str]] = {
    LaunchdServiceErrorCode.UNSUPPORTED_HOST: (
        "Mailbox LaunchAgent is unavailable on this host."
    ),
    LaunchdServiceErrorCode.INVALID_CONFIGURATION: (
        "Mailbox LaunchAgent configuration is invalid."
    ),
    LaunchdServiceErrorCode.UNSAFE_FILESYSTEM: (
        "Mailbox LaunchAgent filesystem is unsafe."
    ),
    LaunchdServiceErrorCode.UNSAFE_PERMISSIONS: (
        "Mailbox LaunchAgent artifact permissions are unsafe."
    ),
    LaunchdServiceErrorCode.FOREIGN_MANIFEST: (
        "Mailbox LaunchAgent manifest is not owned by Health Bridge."
    ),
    LaunchdServiceErrorCode.MANIFEST_DRIFT: (
        "Mailbox LaunchAgent artifacts have drifted."
    ),
    LaunchdServiceErrorCode.LAUNCHCTL_TIMEOUT: (
        "Mailbox LaunchAgent operation timed out."
    ),
    LaunchdServiceErrorCode.LAUNCHCTL_FAILED: ("Mailbox LaunchAgent operation failed."),
    LaunchdServiceErrorCode.NOT_INSTALLED: "Mailbox LaunchAgent is not installed.",
    LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED: (
        "Mailbox LaunchAgent upgrade recovery is required."
    ),
}


class LaunchdServiceError(Exception):
    def __init__(self, code: LaunchdServiceErrorCode) -> None:
        super().__init__()
        self.code: LaunchdServiceErrorCode = code

    @override
    def __str__(self) -> str:
        return _ERROR_MESSAGES[self.code]


@dataclass(frozen=True, slots=True)
class LaunchdServicePaths:
    state_dir: Path
    config: Path
    ownership: Path
    stdout_log: Path
    stderr_log: Path
    manifest: Path


@dataclass(frozen=True, slots=True)
class LaunchdServiceRequest:
    executable: Path
    db_path: Path
    mailbox_root: Path | None
    icloud_container_identifier: str | None
    home: Path
    uid: int
    host: str = "127.0.0.1"
    port: int = 8765
    label: str = LAUNCH_AGENT_LABEL
    setup_page: Path | None = None

    @property
    def paths(self) -> LaunchdServicePaths:
        return service_paths(self.home, self.label)


def service_paths(home: Path, label: str = LAUNCH_AGENT_LABEL) -> LaunchdServicePaths:
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", label) is None:
        raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
    state_dir = home / SERVICE_STATE_RELATIVE
    if label != LAUNCH_AGENT_LABEL:
        state_dir /= label
    return LaunchdServicePaths(
        state_dir=state_dir,
        config=state_dir / "receiver.json",
        ownership=state_dir / "ownership.json",
        stdout_log=state_dir / "receiver.stdout.log",
        stderr_log=state_dir / "receiver.stderr.log",
        manifest=home / "Library/LaunchAgents" / f"{label}.plist",
    )


class LaunchdServiceConfig(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    schema_id: Literal["health_bridge.launchd.receiver"]
    schema_version: Literal[1]
    executable: Path
    db_path: Path
    mailbox_root: Path | None
    icloud_container_identifier: str | None
    host: str
    port: int
    label: str = LAUNCH_AGENT_LABEL
    setup_page: Path | None = None


class LaunchdOwnershipRecord(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    schema_id: Literal["health_bridge.launchd.ownership"]
    schema_version: Literal[1]
    manifest_sha256: str
    config_sha256: str


class LaunchdServiceResult(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    code: LaunchdServiceCode

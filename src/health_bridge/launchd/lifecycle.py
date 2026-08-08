from __future__ import annotations

from typing import TYPE_CHECKING, Final

from health_bridge.launchd.artifacts import (
    active_launch_agent_artifacts_exist,
    artifacts_are_owned,
    launch_agent_artifact_transaction,
    owned_artifacts_match_request,
    remove_launch_agent_artifacts,
    replace_launch_agent_artifacts,
)
from health_bridge.launchd.models import (
    LaunchdServiceCode,
    LaunchdServiceError,
    LaunchdServiceErrorCode,
    LaunchdServiceRequest,
    LaunchdServiceResult,
    LocalHealthStatus,
)

if TYPE_CHECKING:
    from health_bridge.launchd.adapters import LaunchctlAdapter

_HEALTH_CODES: Final = {
    LocalHealthStatus.OK: LaunchdServiceCode.RUNNING_HEALTHY,
    LocalHealthStatus.DEGRADED: LaunchdServiceCode.DEGRADED_RETRYABLE,
    LocalHealthStatus.UNAVAILABLE: LaunchdServiceCode.DEGRADED_RETRYABLE,
    LocalHealthStatus.TERMINAL: LaunchdServiceCode.TERMINAL_FAILED,
}


def classify_launch_agent_status(
    request: LaunchdServiceRequest,
    *,
    launchctl_output: str | None,
    health: str | None,
) -> LaunchdServiceResult:
    paths = request.paths
    if not active_launch_agent_artifacts_exist(paths):
        return LaunchdServiceResult(code=LaunchdServiceCode.NOT_INSTALLED)
    if not artifacts_are_owned(request):
        return LaunchdServiceResult(code=LaunchdServiceCode.MANIFEST_DRIFT)
    running = launchctl_output is not None and any(
        line.strip() == "state = running" for line in launchctl_output.splitlines()
    )
    if not running:
        return LaunchdServiceResult(code=LaunchdServiceCode.INSTALLED_INACTIVE)
    if health is None:
        return LaunchdServiceResult(code=LaunchdServiceCode.DEGRADED_RETRYABLE)
    try:
        parsed_health = LocalHealthStatus(health)
    except ValueError:
        return LaunchdServiceResult(code=LaunchdServiceCode.DEGRADED_RETRYABLE)
    return LaunchdServiceResult(code=_HEALTH_CODES[parsed_health])


def restart_launch_agent(
    request: LaunchdServiceRequest,
    adapter: LaunchctlAdapter,
) -> LaunchdServiceResult:
    _require_owned(request)
    first = adapter.kickstart()
    if first.returncode == 0:
        return LaunchdServiceResult(code=LaunchdServiceCode.RESTARTED)
    current = adapter.inspect()
    if current.returncode == 0:
        stopped = adapter.bootout()
        if stopped.returncode != 0:
            raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED)
    bootstrap = adapter.bootstrap(request.paths.manifest)
    if bootstrap.returncode != 0:
        raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED)
    recovered = adapter.kickstart()
    if recovered.returncode != 0:
        raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED)
    return LaunchdServiceResult(code=LaunchdServiceCode.RESTART_RECOVERED)


def install_launch_agent(
    request: LaunchdServiceRequest,
    adapter: LaunchctlAdapter,
) -> LaunchdServiceResult:
    with launch_agent_artifact_transaction(request) as written:
        if written.code is LaunchdServiceCode.ALREADY_INSTALLED:
            current = adapter.inspect()
            if current.returncode == 0:
                return written
        bootstrapped = adapter.bootstrap(request.paths.manifest)
        if bootstrapped.returncode != 0:
            raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED)
        return LaunchdServiceResult(code=LaunchdServiceCode.INSTALLED)


def upgrade_launch_agent(
    current: LaunchdServiceRequest,
    desired: LaunchdServiceRequest,
    adapter: LaunchctlAdapter,
) -> LaunchdServiceResult:
    already_current = owned_artifacts_match_request(current, desired)
    inspected = adapter.inspect()
    if already_current:
        if inspected.returncode != 0:
            bootstrapped = adapter.bootstrap(desired.paths.manifest)
            if bootstrapped.returncode != 0:
                raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED)
        return LaunchdServiceResult(code=LaunchdServiceCode.ALREADY_CURRENT)
    was_loaded = inspected.returncode == 0
    if was_loaded:
        stopped = adapter.bootout()
        if stopped.returncode != 0:
            raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED)
    try:
        with replace_launch_agent_artifacts(current, desired):
            bootstrapped = adapter.bootstrap(desired.paths.manifest)
            _require_launchctl_success(bootstrapped.returncode)
    except LaunchdServiceError as exc:
        if was_loaded:
            if (
                exc.code is LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
                or not artifacts_are_owned(current)
            ):
                raise LaunchdServiceError(
                    LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
                ) from exc
            recovered = adapter.bootstrap(current.paths.manifest)
            if recovered.returncode != 0:
                raise LaunchdServiceError(
                    LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
                ) from exc
        raise
    return LaunchdServiceResult(code=LaunchdServiceCode.UPGRADED)


def uninstall_launch_agent(
    request: LaunchdServiceRequest,
    adapter: LaunchctlAdapter,
) -> LaunchdServiceResult:
    if not active_launch_agent_artifacts_exist(request.paths):
        return LaunchdServiceResult(code=LaunchdServiceCode.ALREADY_UNINSTALLED)
    _require_owned(request)
    current = adapter.inspect()
    if current.returncode == 0:
        stopped = adapter.bootout()
        if stopped.returncode != 0:
            raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED)
    return remove_launch_agent_artifacts(request, deactivate=False)


def _require_owned(request: LaunchdServiceRequest) -> None:
    if not artifacts_are_owned(request):
        raise LaunchdServiceError(LaunchdServiceErrorCode.NOT_INSTALLED)


def _require_launchctl_success(returncode: int) -> None:
    if returncode != 0:
        raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED)

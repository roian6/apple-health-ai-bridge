from __future__ import annotations

import subprocess  # nosec B404
from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol, final

from health_bridge.launchd.models import (
    LAUNCH_AGENT_LABEL,
    LaunchdServiceError,
    LaunchdServiceErrorCode,
)

if TYPE_CHECKING:
    from pathlib import Path


class SubprocessRunner(Protocol):
    def __call__(
        self,
        argv: list[str],
        *,
        capture_output: bool,
        text: bool,
        check: bool,
        timeout: float,
    ) -> subprocess.CompletedProcess[str]: ...


@dataclass(frozen=True, slots=True)
class LaunchctlResult:
    returncode: int
    stdout: str
    stderr: str


def _run_subprocess(
    argv: list[str],
    *,
    capture_output: bool,
    text: bool,
    check: bool,
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # nosec B603  # noqa: S603
        argv,
        capture_output=capture_output,
        text=text,
        check=check,
        timeout=timeout,
    )


@final
class LaunchctlAdapter:
    def __init__(
        self,
        *,
        launchctl: Path,
        uid: int,
        timeout_seconds: float,
        runner: SubprocessRunner = _run_subprocess,
    ) -> None:
        if not launchctl.is_absolute() or uid < 0 or timeout_seconds <= 0:
            raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
        self._launchctl = launchctl
        self._uid = uid
        self._timeout_seconds = timeout_seconds
        self._runner = runner

    def inspect(self) -> LaunchctlResult:
        return self._execute("print", self._service_domain())

    def bootstrap(self, manifest: Path) -> LaunchctlResult:
        return self._execute("bootstrap", self._user_domain(), str(manifest))

    def bootout(self) -> LaunchctlResult:
        return self._execute("bootout", self._service_domain())

    def kickstart(self) -> LaunchctlResult:
        return self._execute("kickstart", "-k", self._service_domain())

    def _user_domain(self) -> str:
        return f"gui/{self._uid}"

    def _service_domain(self) -> str:
        return f"{self._user_domain()}/{LAUNCH_AGENT_LABEL}"

    def _execute(self, *arguments: str) -> LaunchctlResult:
        try:
            completed = self._runner(
                [str(self._launchctl), *arguments],
                capture_output=True,
                text=True,
                check=False,
                timeout=self._timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.LAUNCHCTL_TIMEOUT
            ) from exc
        except OSError as exc:
            raise LaunchdServiceError(LaunchdServiceErrorCode.LAUNCHCTL_FAILED) from exc
        return LaunchctlResult(
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

from health_bridge.launchd import (
    LaunchctlAdapter,
    LaunchdServiceError,
    classify_launch_agent_status,
    install_launch_agent,
    restart_launch_agent,
    uninstall_launch_agent,
    write_launch_agent_artifacts,
)
from tests.launchd.support import service_request

if TYPE_CHECKING:
    from collections.abc import Callable


def _runner(
    calls: list[list[str]],
    results: list[subprocess.CompletedProcess[str]],
) -> Callable[..., subprocess.CompletedProcess[str]]:
    def run(
        argv: list[str],
        *,
        capture_output: bool,
        text: bool,
        check: bool,
        timeout: float,
    ) -> subprocess.CompletedProcess[str]:
        assert capture_output is True
        assert text is True
        assert check is False
        assert timeout == 1.5
        calls.append(argv)
        return results.pop(0)

    return run


def test_launchctl_adapter_uses_exact_gui_domain_vectors_without_shell(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    calls: list[list[str]] = []
    results = [
        subprocess.CompletedProcess([], 0, "state = running\n", "") for _ in range(4)
    ]
    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=_runner(calls, results),
    )

    _ = adapter.inspect()
    _ = adapter.bootstrap(request.paths.manifest)
    _ = adapter.bootout()
    _ = adapter.kickstart()

    service = f"gui/{request.uid}/dev.healthbridge.companion"
    assert calls == [
        ["/bin/launchctl", "print", service],
        [
            "/bin/launchctl",
            "bootstrap",
            f"gui/{request.uid}",
            str(request.paths.manifest),
        ],
        ["/bin/launchctl", "bootout", service],
        ["/bin/launchctl", "kickstart", "-k", service],
    ]


def test_launchctl_timeout_is_bounded_and_privacy_safe(tmp_path: Path) -> None:
    request = service_request(tmp_path)

    def timeout_runner(
        argv: list[str],
        *,
        capture_output: bool,
        text: bool,
        check: bool,
        timeout: float,
    ) -> subprocess.CompletedProcess[str]:
        del capture_output, text, check
        raise subprocess.TimeoutExpired(cmd=argv, timeout=timeout)

    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=timeout_runner,
    )

    with pytest.raises(LaunchdServiceError) as raised:
        _ = adapter.inspect()

    assert raised.value.code.value == "launchctl_timeout"
    assert str(request.uid) not in str(raised.value)
    assert str(request.paths.manifest) not in str(raised.value)


@pytest.mark.parametrize(
    ("launchctl_output", "health", "expected"),
    [
        (None, None, "not_installed"),
        ("", None, "installed_inactive"),
        ("state = running\n", "ok", "running_healthy"),
        ("state = running\n", "degraded", "degraded_retryable"),
        ("state = running\n", "unavailable", "degraded_retryable"),
        ("state = running\n", "terminal", "terminal_failed"),
    ],
)
def test_status_maps_launchctl_and_local_health_to_fixed_codes(
    tmp_path: Path,
    launchctl_output: str | None,
    health: str | None,
    expected: str,
) -> None:
    request = service_request(tmp_path)
    if launchctl_output is not None:
        _ = write_launch_agent_artifacts(request, activate=False)
    result = classify_launch_agent_status(
        request,
        launchctl_output=launchctl_output,
        health=health,
    )

    assert result.code.value == expected
    assert result.model_dump() == {"code": expected}


def test_status_reports_manifest_drift_before_launchctl_details(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    _ = request.paths.manifest.write_bytes(b"synthetic drift")
    request.paths.manifest.chmod(0o600)

    result = classify_launch_agent_status(
        request,
        launchctl_output="private raw launchctl output",
        health="ok",
    )

    assert result.model_dump() == {"code": "manifest_drift"}


def test_restart_recovers_once_with_bootout_bootstrap_and_kickstart(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    calls: list[list[str]] = []
    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=_runner(
            calls,
            [
                subprocess.CompletedProcess([], 3, "private", "private"),
                subprocess.CompletedProcess([], 0, "", ""),
                subprocess.CompletedProcess([], 0, "", ""),
                subprocess.CompletedProcess([], 0, "", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ],
        ),
    )

    result = restart_launch_agent(request, adapter)

    service = f"gui/{request.uid}/dev.healthbridge.companion"
    assert result.code.value == "restart_recovered"
    assert calls == [
        ["/bin/launchctl", "kickstart", "-k", service],
        ["/bin/launchctl", "print", service],
        ["/bin/launchctl", "bootout", service],
        [
            "/bin/launchctl",
            "bootstrap",
            f"gui/{request.uid}",
            str(request.paths.manifest),
        ],
        ["/bin/launchctl", "kickstart", "-k", service],
    ]


def test_restart_stops_after_registered_service_bootout_failure(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    calls: list[list[str]] = []
    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=_runner(
            calls,
            [
                subprocess.CompletedProcess([], 3, "", ""),
                subprocess.CompletedProcess([], 0, "state = running\n", ""),
                subprocess.CompletedProcess([], 5, "", ""),
            ],
        ),
    )

    with pytest.raises(LaunchdServiceError) as raised:
        _ = restart_launch_agent(request, adapter)

    service = f"gui/{request.uid}/dev.healthbridge.companion"
    assert raised.value.code.value == "launchctl_failed"
    assert calls == [
        ["/bin/launchctl", "kickstart", "-k", service],
        ["/bin/launchctl", "print", service],
        ["/bin/launchctl", "bootout", service],
    ]


def test_restart_bootstraps_without_bootout_when_service_is_unregistered(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    calls: list[list[str]] = []
    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=_runner(
            calls,
            [
                subprocess.CompletedProcess([], 3, "", ""),
                subprocess.CompletedProcess([], 3, "", ""),
                subprocess.CompletedProcess([], 0, "", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ],
        ),
    )

    result = restart_launch_agent(request, adapter)

    service = f"gui/{request.uid}/dev.healthbridge.companion"
    assert result.code.value == "restart_recovered"
    assert calls == [
        ["/bin/launchctl", "kickstart", "-k", service],
        ["/bin/launchctl", "print", service],
        [
            "/bin/launchctl",
            "bootstrap",
            f"gui/{request.uid}",
            str(request.paths.manifest),
        ],
        ["/bin/launchctl", "kickstart", "-k", service],
    ]


def test_install_bootstraps_once_and_identical_reinstall_only_inspects(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    calls: list[list[str]] = []
    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=_runner(
            calls,
            [
                subprocess.CompletedProcess([], 0, "", ""),
                subprocess.CompletedProcess([], 0, "state = running\n", ""),
            ],
        ),
    )

    installed = install_launch_agent(request, adapter)
    reinstalled = install_launch_agent(request, adapter)

    service = f"gui/{request.uid}/dev.healthbridge.companion"
    assert installed.code.value == "installed"
    assert reinstalled.code.value == "already_installed"
    assert calls == [
        [
            "/bin/launchctl",
            "bootstrap",
            f"gui/{request.uid}",
            str(request.paths.manifest),
        ],
        ["/bin/launchctl", "print", service],
    ]


def test_install_bootstrap_failure_rolls_back_new_generation_and_retries(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    calls: list[list[str]] = []
    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=_runner(
            calls,
            [
                subprocess.CompletedProcess([], 5, "", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ],
        ),
    )

    with pytest.raises(LaunchdServiceError) as raised:
        _ = install_launch_agent(request, adapter)

    assert raised.value.code.value == "launchctl_failed"
    assert request.paths.state_dir.is_dir()
    assert request.paths.manifest.parent.is_dir()
    assert request.db_path.is_file()
    assert request.mailbox_root.is_dir()

    recovered = install_launch_agent(request, adapter)

    assert recovered.code.value == "installed"


def test_uninstall_boots_out_owned_service_then_is_idempotent(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    calls: list[list[str]] = []
    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=_runner(
            calls,
            [
                subprocess.CompletedProcess([], 0, "state = running\n", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ],
        ),
    )

    uninstalled = uninstall_launch_agent(request, adapter)
    repeated = uninstall_launch_agent(request, adapter)

    service = f"gui/{request.uid}/dev.healthbridge.companion"
    assert uninstalled.code.value == "uninstalled"
    assert repeated.code.value == "already_uninstalled"
    assert calls == [
        ["/bin/launchctl", "print", service],
        ["/bin/launchctl", "bootout", service],
    ]


def test_uninstall_removes_service_after_runtime_targets_are_moved_or_deleted(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    moved_database = request.db_path.with_name("moved-health.sqlite")
    moved_mailbox = request.mailbox_root.with_name("moved-v1")
    _ = request.db_path.rename(moved_database)
    _ = request.mailbox_root.rename(moved_mailbox)
    request.executable.unlink()
    calls: list[list[str]] = []
    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request.uid,
        timeout_seconds=1.5,
        runner=_runner(
            calls,
            [
                subprocess.CompletedProcess([], 0, "state = running\n", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ],
        ),
    )

    result = uninstall_launch_agent(request, adapter)

    assert result.code.value == "uninstalled"
    assert moved_database.is_file()
    assert moved_mailbox.is_dir()
    assert not request.paths.manifest.exists()
    assert request.paths.state_dir.is_dir()

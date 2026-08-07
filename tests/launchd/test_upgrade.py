from __future__ import annotations

import os
import subprocess
from dataclasses import replace
from pathlib import Path
from typing import TYPE_CHECKING, Never

import pytest

import health_bridge.launchd.artifacts as artifacts_module
import health_bridge.launchd.lifecycle as lifecycle_module
import health_bridge.launchd.private_artifacts as private_artifacts_module
from health_bridge.launchd import (
    LaunchctlAdapter,
    LaunchdServiceError,
    LaunchdServiceErrorCode,
    LaunchdServiceRequest,
    classify_launch_agent_status,
    uninstall_launch_agent,
    write_launch_agent_artifacts,
)
from health_bridge.launchd.manifest import render_launch_agent_plist
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
        assert (capture_output, text, check, timeout) == (True, True, False, 1.5)
        calls.append(argv)
        return results.pop(0)

    return run


def _adapter(
    request_uid: int,
    calls: list[list[str]],
    returncodes: list[int],
) -> LaunchctlAdapter:
    return LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=request_uid,
        timeout_seconds=1.5,
        runner=_runner(
            calls,
            [subprocess.CompletedProcess([], code, "", "") for code in returncodes],
        ),
    )


def test_upgrade_replaces_changed_executable_when_old_executable_is_missing(
    tmp_path: Path,
) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    replacement_executable = current.executable.with_name("health-bridge-v2")
    _ = replacement_executable.write_text("synthetic v2", encoding="utf-8")
    replacement_executable.chmod(0o700)
    current.executable.unlink()
    desired = replace(current, executable=replacement_executable)
    calls: list[list[str]] = []

    result = lifecycle_module.upgrade_launch_agent(
        current,
        desired,
        _adapter(current.uid, calls, [0, 0, 0]),
    )

    service = f"gui/{current.uid}/dev.healthbridge.companion"
    assert result.code.value == "upgraded"
    assert (
        replacement_executable.as_posix().encode() in desired.paths.config.read_bytes()
    )
    assert (
        replacement_executable.as_posix().encode()
        in desired.paths.manifest.read_bytes()
    )
    assert calls == [
        ["/bin/launchctl", "print", service],
        ["/bin/launchctl", "bootout", service],
        [
            "/bin/launchctl",
            "bootstrap",
            f"gui/{current.uid}",
            str(current.paths.manifest),
        ],
    ]


def test_upgrade_applies_owned_renderer_generation_change(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    original_renderer = render_launch_agent_plist

    def next_renderer(request: LaunchdServiceRequest) -> bytes:
        return original_renderer(request) + b"\n"

    monkeypatch.setattr(artifacts_module, "render_launch_agent_plist", next_renderer)
    calls: list[list[str]] = []

    result = lifecycle_module.upgrade_launch_agent(
        current,
        current,
        _adapter(current.uid, calls, [0, 0, 0]),
    )

    assert result.code.value == "upgraded"
    assert current.paths.manifest.read_bytes().endswith(b"\n")


def test_status_accepts_internally_owned_previous_renderer_generation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    original_renderer = render_launch_agent_plist

    def next_renderer(request: LaunchdServiceRequest) -> bytes:
        return original_renderer(request) + b"\n"

    monkeypatch.setattr(artifacts_module, "render_launch_agent_plist", next_renderer)

    result = classify_launch_agent_status(
        current,
        launchctl_output="",
        health=None,
    )

    assert result.code.value == "installed_inactive"


def test_uninstall_accepts_internally_owned_previous_renderer_generation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    original_renderer = render_launch_agent_plist

    def next_renderer(request: LaunchdServiceRequest) -> bytes:
        return original_renderer(request) + b"\n"

    monkeypatch.setattr(artifacts_module, "render_launch_agent_plist", next_renderer)
    calls: list[list[str]] = []

    result = uninstall_launch_agent(
        current,
        _adapter(current.uid, calls, [3]),
    )

    assert result.code.value == "uninstalled"
    assert not current.paths.manifest.exists()


def test_upgrade_is_idempotent_for_current_owned_generation(tmp_path: Path) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    calls: list[list[str]] = []

    result = lifecycle_module.upgrade_launch_agent(
        current,
        current,
        _adapter(current.uid, calls, [0]),
    )

    service = f"gui/{current.uid}/dev.healthbridge.companion"
    assert result.code.value == "already_current"
    assert calls == [["/bin/launchctl", "print", service]]


def test_upgrade_refuses_drift_before_launchctl_or_mutation(tmp_path: Path) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    original_config = current.paths.config.read_bytes()
    _ = current.paths.manifest.write_bytes(b"synthetic drift")
    current.paths.manifest.chmod(0o600)
    calls: list[list[str]] = []

    with pytest.raises(LaunchdServiceError) as raised:
        _ = lifecycle_module.upgrade_launch_agent(
            current,
            current,
            _adapter(current.uid, calls, []),
        )

    assert raised.value.code.value == "manifest_drift"
    assert calls == []
    assert current.paths.config.read_bytes() == original_config
    assert current.paths.manifest.read_bytes() == b"synthetic drift"


def test_upgrade_rolls_back_and_reactivates_old_job_when_bootstrap_fails(
    tmp_path: Path,
) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    original = {
        path: path.read_bytes()
        for path in (
            current.paths.config,
            current.paths.ownership,
            current.paths.manifest,
        )
    }
    replacement_executable = current.executable.with_name("health-bridge-v2")
    _ = replacement_executable.write_text("synthetic v2", encoding="utf-8")
    replacement_executable.chmod(0o700)
    desired = replace(current, executable=replacement_executable)
    calls: list[list[str]] = []

    with pytest.raises(LaunchdServiceError) as raised:
        _ = lifecycle_module.upgrade_launch_agent(
            current,
            desired,
            _adapter(current.uid, calls, [0, 0, 5, 0]),
        )

    service = f"gui/{current.uid}/dev.healthbridge.companion"
    assert raised.value.code.value == "launchctl_failed"
    assert {path: path.read_bytes() for path in original} == original
    assert calls == [
        ["/bin/launchctl", "print", service],
        ["/bin/launchctl", "bootout", service],
        [
            "/bin/launchctl",
            "bootstrap",
            f"gui/{current.uid}",
            str(current.paths.manifest),
        ],
        [
            "/bin/launchctl",
            "bootstrap",
            f"gui/{current.uid}",
            str(current.paths.manifest),
        ],
    ]


@pytest.mark.parametrize("artifact_name", ["config", "ownership", "manifest"])
def test_upgrade_refuses_foreign_replacement_immediately_before_publication(
    tmp_path: Path,
    artifact_name: str,
) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    replacement_executable = current.executable.with_name("health-bridge-v2")
    _ = replacement_executable.write_text("synthetic v2", encoding="utf-8")
    replacement_executable.chmod(0o700)
    desired = replace(current, executable=replacement_executable)
    target = {
        "config": current.paths.config,
        "ownership": current.paths.ownership,
        "manifest": current.paths.manifest,
    }[artifact_name]
    original = target.read_bytes()
    displaced = target.with_name(f"displaced-{target.name}")
    foreign = b"synthetic foreign replacement"

    def replace_before_publish(boundary: str, path: Path) -> None:
        if boundary == "before_replace_retire" and path == target:
            _ = target.rename(displaced)
            _ = target.write_bytes(foreign)
            target.chmod(0o600)

    with (
        pytest.raises(LaunchdServiceError) as raised,
        artifacts_module.replace_launch_agent_artifacts(
            current,
            desired,
            mutation_hook=replace_before_publish,
        ),
    ):
        pass

    assert raised.value.code.value == "upgrade_recovery_required"
    assert target.read_bytes() == foreign
    assert displaced.read_bytes() == original
    backups = list(target.parent.glob(f".{target.name}.*.backup"))
    staged = list(target.parent.glob(f".{target.name}.*.staged"))
    assert len(backups) == 1
    assert len(staged) == 1
    assert backups[0].read_bytes() == original


@pytest.mark.parametrize("artifact_name", ["config", "ownership", "manifest"])
def test_upgrade_never_clobbers_foreign_entry_inserted_at_publication(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    artifact_name: str,
) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    replacement_executable = current.executable.with_name("health-bridge-v2")
    _ = replacement_executable.write_text("synthetic v2", encoding="utf-8")
    replacement_executable.chmod(0o700)
    desired = replace(current, executable=replacement_executable)
    target = {
        "config": current.paths.config,
        "ownership": current.paths.ownership,
        "manifest": current.paths.manifest,
    }[artifact_name]
    original = target.read_bytes()
    foreign = b"synthetic publication replacement"
    original_rename = private_artifacts_module.exclusive_rename
    inserted = False

    def insert_before_rename(
        source_dir_fd: int,
        source_name: str,
        destination_dir_fd: int,
        destination_name: str,
    ) -> None:
        nonlocal inserted
        if (
            destination_name == target.name
            and source_name.endswith(".staged")
            and not inserted
        ):
            inserted = True
            descriptor = os.open(
                destination_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=destination_dir_fd,
            )
            try:
                _ = os.write(descriptor, foreign)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        original_rename(
            source_dir_fd,
            source_name,
            destination_dir_fd,
            destination_name,
        )

    monkeypatch.setattr(
        private_artifacts_module,
        "exclusive_rename",
        insert_before_rename,
    )

    with (
        pytest.raises(LaunchdServiceError) as raised,
        artifacts_module.replace_launch_agent_artifacts(current, desired),
    ):
        pass

    assert raised.value.code.value == "upgrade_recovery_required"
    assert target.read_bytes() == foreign
    backups = list(target.parent.glob(f".{target.name}.*.backup"))
    assert len(backups) == 1
    assert backups[0].read_bytes() == original


def test_upgrade_does_not_bootstrap_unverified_manifest_after_recovery_error(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    replacement_executable = current.executable.with_name("health-bridge-v2")
    _ = replacement_executable.write_text("synthetic v2", encoding="utf-8")
    replacement_executable.chmod(0o700)
    desired = replace(current, executable=replacement_executable)
    calls: list[list[str]] = []

    class RecoveryRequiredContext:
        def __enter__(self) -> Never:
            raise LaunchdServiceError(LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED)

        def __exit__(self, *_args: object) -> None:
            return

    def recovery_required(
        _current: LaunchdServiceRequest,
        _desired: LaunchdServiceRequest,
    ) -> RecoveryRequiredContext:
        return RecoveryRequiredContext()

    monkeypatch.setattr(
        lifecycle_module,
        "replace_launch_agent_artifacts",
        recovery_required,
    )

    with pytest.raises(LaunchdServiceError) as raised:
        _ = lifecycle_module.upgrade_launch_agent(
            current,
            desired,
            _adapter(current.uid, calls, [0, 0]),
        )

    service = f"gui/{current.uid}/dev.healthbridge.companion"
    assert raised.value.code.value == "upgrade_recovery_required"
    assert calls == [
        ["/bin/launchctl", "print", service],
        ["/bin/launchctl", "bootout", service],
    ]

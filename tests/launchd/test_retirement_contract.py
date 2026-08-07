"""Regression contract for no-delete launchd retirement and recovery.

No-excuse size audit: # noqa: SIZE_OK — one contract groups the race scenarios.
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path
from typing import TYPE_CHECKING, TypeVar

import pytest

import health_bridge.launchd.artifacts as artifacts_module
import health_bridge.launchd.private_artifacts as private_artifacts_module
from health_bridge.launchd import (
    LaunchctlAdapter,
    LaunchdServiceError,
    LaunchdServiceErrorCode,
    remove_launch_agent_artifacts,
    upgrade_launch_agent,
    write_launch_agent_artifacts,
)
from tests.launchd.support import service_request

if TYPE_CHECKING:
    from collections.abc import Callable

_ResultT = TypeVar("_ResultT")


def _error_code(action: Callable[[], _ResultT]) -> str | None:
    try:
        _ = action()
    except LaunchdServiceError as exc:
        return exc.code.value
    return None


def _write_at(directory_fd: int, name: str, content: bytes) -> None:
    descriptor = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
        dir_fd=directory_fd,
    )
    try:
        _ = os.write(descriptor, content)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def test_directory_chain_closes_fds_and_leaves_only_empty_created_directories(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given a create=True chain whose final component always fails.
    target = tmp_path / "created-private" / "leaf"
    original_open = private_artifacts_module.open_directory_component

    def fail_leaf(parent_fd: int, name: str, *, create: bool) -> tuple[int, bool]:
        if name == "leaf":
            message = "synthetic denied component"
            raise PermissionError(message)
        return original_open(parent_fd, name, create=create)

    monkeypatch.setattr(
        private_artifacts_module,
        "open_directory_component",
        fail_leaf,
    )
    process_fds = Path("/proc/self/fd")
    before = len(tuple(process_fds.iterdir()))

    # When the same failing chain is opened repeatedly.
    for _ in range(32):
        with pytest.raises(LaunchdServiceError):
            _ = private_artifacts_module.PrivateDirectory.open(
                target,
                create=True,
                owner_only=True,
            )

    # Then acquired descriptors are closed and only an empty private dir remains.
    assert len(tuple(process_fds.iterdir())) == before
    assert list(target.parent.iterdir()) == []
    assert stat.S_IMODE(target.parent.stat().st_mode) == 0o700


def test_publication_preserves_source_replacement_under_recovery_name(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given a private publication whose temp name is replaced at the syscall boundary.
    directory = tmp_path / "private"
    directory.mkdir(mode=0o700)
    final = directory / "receiver.json"
    detached = directory / "detached-owned-temp"
    foreign = b"synthetic foreign publication entry"
    original_rename = private_artifacts_module.exclusive_rename
    swapped = False

    def replace_source_then_rename(
        source_dir_fd: int,
        source_name: str,
        destination_dir_fd: int,
        destination_name: str,
    ) -> None:
        nonlocal swapped
        if destination_name == final.name and not swapped:
            swapped = True
            os.rename(
                source_name,
                detached.name,
                src_dir_fd=source_dir_fd,
                dst_dir_fd=source_dir_fd,
            )
            _write_at(source_dir_fd, source_name, foreign)
        original_rename(
            source_dir_fd,
            source_name,
            destination_dir_fd,
            destination_name,
        )

    monkeypatch.setattr(
        private_artifacts_module,
        "exclusive_rename",
        replace_source_then_rename,
    )

    # When publication reaches that exclusive-rename boundary.
    code = _error_code(
        lambda: private_artifacts_module.atomic_create_private(final, b"owned secret")
    )

    # Then foreign bytes are recovered unchanged and never remain active.
    assert code == "unsafe_filesystem"
    assert not final.exists()
    preserved = [path for path in directory.iterdir() if path.read_bytes() == foreign]
    assert len(preserved) == 1
    assert stat.S_IMODE(preserved[0].stat().st_mode) == 0o600
    assert detached.read_bytes() == b""


def test_uninstall_preserves_replacement_at_exclusive_rename_boundary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given an owned config replaced immediately before retirement rename.
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    original_content = request.paths.config.read_bytes()
    detached = request.paths.config.with_name("detached-owned-config")
    foreign = b"synthetic foreign uninstall entry"
    original_rename = private_artifacts_module.exclusive_rename
    swapped = False

    def replace_source_then_rename(
        source_dir_fd: int,
        source_name: str,
        destination_dir_fd: int,
        destination_name: str,
    ) -> None:
        nonlocal swapped
        if source_name == request.paths.config.name and not swapped:
            swapped = True
            os.rename(
                source_name,
                detached.name,
                src_dir_fd=source_dir_fd,
                dst_dir_fd=source_dir_fd,
            )
            _write_at(source_dir_fd, source_name, foreign)
        original_rename(
            source_dir_fd,
            source_name,
            destination_dir_fd,
            destination_name,
        )

    monkeypatch.setattr(
        private_artifacts_module,
        "exclusive_rename",
        replace_source_then_rename,
    )

    # When uninstall retires the validated artifacts.
    code = _error_code(lambda: remove_launch_agent_artifacts(request, deactivate=False))

    # Then it fails closed without deleting, truncating, or chmodding the foreign inode.
    assert code == "unsafe_filesystem"
    assert not request.paths.config.exists()
    preserved = [
        path
        for path in request.paths.state_dir.iterdir()
        if path.is_file() and path.read_bytes() == foreign
    ]
    assert len(preserved) == 1
    assert stat.S_IMODE(preserved[0].stat().st_mode) == 0o600
    assert detached.read_bytes() == original_content


def test_upgrade_boundary_replacement_never_bootstraps_unverified_manifest(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given a loaded owned service and a config replacement at retirement rename.
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    next_executable = current.executable.with_name("health-bridge-v2")
    _ = next_executable.write_text("synthetic v2", encoding="utf-8")
    next_executable.chmod(0o700)
    desired = replace(current, executable=next_executable)
    detached = current.paths.config.with_name("detached-upgrade-config")
    foreign = b"synthetic foreign upgrade entry"
    original_rename = private_artifacts_module.exclusive_rename
    swapped = False
    calls: list[list[str]] = []

    def replace_source_then_rename(
        source_dir_fd: int,
        source_name: str,
        destination_dir_fd: int,
        destination_name: str,
    ) -> None:
        nonlocal swapped
        if source_name == current.paths.config.name and not swapped:
            swapped = True
            os.rename(
                source_name,
                detached.name,
                src_dir_fd=source_dir_fd,
                dst_dir_fd=source_dir_fd,
            )
            _write_at(source_dir_fd, source_name, foreign)
        original_rename(
            source_dir_fd,
            source_name,
            destination_dir_fd,
            destination_name,
        )

    monkeypatch.setattr(
        private_artifacts_module,
        "exclusive_rename",
        replace_source_then_rename,
    )

    def run_launchctl(
        argv: list[str],
        *,
        capture_output: bool,
        text: bool,
        check: bool,
        timeout: float,
    ) -> subprocess.CompletedProcess[str]:
        assert (capture_output, text, check, timeout) == (True, True, False, 1.5)
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "", "")

    adapter = LaunchctlAdapter(
        launchctl=Path("/bin/launchctl"),
        uid=current.uid,
        timeout_seconds=1.5,
        runner=run_launchctl,
    )

    # When the lifecycle attempts the upgrade.
    with pytest.raises(LaunchdServiceError) as raised:
        _ = upgrade_launch_agent(current, desired, adapter)

    # Then recovery is required before any active config can be trusted.
    assert raised.value.code is LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
    service = f"gui/{current.uid}/dev.healthbridge.companion"
    assert calls == [
        ["/bin/launchctl", "print", service],
        ["/bin/launchctl", "bootout", service],
    ]
    assert not current.paths.config.exists()
    assert any(
        path.is_file() and path.read_bytes() == foreign
        for path in current.paths.state_dir.iterdir()
    )


def test_prepare_upgrade_tracks_backup_before_staged_cleanup_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given an upgrade whose first staged create and backup retirement both fail.
    current = service_request(tmp_path)
    _ = write_launch_agent_artifacts(current, activate=False)
    next_executable = current.executable.with_name("health-bridge-v2")
    _ = next_executable.write_text("synthetic v2", encoding="utf-8")
    next_executable.chmod(0o700)
    desired = replace(current, executable=next_executable)
    original_create = artifacts_module.atomic_create_private

    def fail_staged_create(
        path: Path,
        content: bytes,
        *,
        directory: private_artifacts_module.PrivateDirectory | None = None,
    ) -> private_artifacts_module.CreatedArtifact:
        if path.name.endswith(".staged"):
            raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
        return original_create(path, content, directory=directory)

    def fail_backup_retirement(
        _directory: private_artifacts_module.PrivateDirectory,
        _artifact: private_artifacts_module.CreatedArtifact,
    ) -> private_artifacts_module.CreatedArtifact:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)

    monkeypatch.setattr(artifacts_module, "atomic_create_private", fail_staged_create)
    monkeypatch.setattr(
        artifacts_module,
        "retire_exact",
        fail_backup_retirement,
        raising=False,
    )

    # When preparation fails before the pair is complete.
    with (
        pytest.raises(LaunchdServiceError) as raised,
        artifacts_module.replace_launch_agent_artifacts(current, desired),
    ):
        pass

    # Then the tracked secret backup remains and recovery is explicitly required.
    assert raised.value.code is LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
    backups = list(current.paths.state_dir.glob(".*.backup"))
    assert len(backups) == 1
    assert backups[0].read_bytes() == current.paths.config.read_bytes()


def test_large_logs_are_never_read_for_status_or_uninstall(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given an owned installation with a large sparse stdout log.
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    with request.paths.stdout_log.open("r+b") as stream:
        _ = stream.truncate(64 * 1024 * 1024)
    original_read = os.read

    def reject_large_body_read(descriptor: int, size: int) -> bytes:
        if os.fstat(descriptor).st_size > 1024 * 1024:
            message = "large mutable log body was read"
            raise AssertionError(message)
        return original_read(descriptor, size)

    monkeypatch.setattr(os, "read", reject_large_body_read)

    # When status ownership and uninstall inspect the service artifacts.
    assert artifacts_module.artifacts_are_owned(request)
    result = remove_launch_agent_artifacts(request, deactivate=False)

    # Then active paths are gone and the retired log is only an empty private marker.
    assert result.code.value == "uninstalled"
    assert not request.paths.stdout_log.exists()
    retired_logs = list(request.paths.state_dir.glob(".receiver.stdout.log.*"))
    assert len(retired_logs) == 1
    assert retired_logs[0].stat().st_size == 0


def test_publication_fails_closed_when_exclusive_rename_is_unsupported(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given a platform without an approved exclusive rename primitive.
    directory = tmp_path / "private"
    directory.mkdir(mode=0o700)
    final = directory / "receiver.json"
    monkeypatch.setattr(sys, "platform", "unsupported-synthetic")

    # When a private artifact is published.
    code = _error_code(
        lambda: private_artifacts_module.atomic_create_private(final, b"owned secret")
    )

    # Then publication fails closed and no active file appears.
    assert code == "unsafe_filesystem"
    assert not final.exists()
    assert all(path.stat().st_size == 0 for path in directory.iterdir())


def test_publication_scrubs_retained_temp_when_active_name_exists(
    tmp_path: Path,
) -> None:
    # Given an existing private active name that publication must not replace.
    directory = tmp_path / "private"
    directory.mkdir(mode=0o700)
    final = directory / "receiver.json"
    foreign = b"synthetic existing active entry"
    _ = final.write_bytes(foreign)
    final.chmod(0o600)

    # When exclusive publication receives EEXIST.
    with pytest.raises(FileExistsError):
        _ = private_artifacts_module.atomic_create_private(final, b"owned secret")

    # Then the active bytes are unchanged and every temp remnant is empty.
    assert final.read_bytes() == foreign
    remnants = [path for path in directory.iterdir() if path != final]
    assert len(remnants) == 1
    assert remnants[0].stat().st_size == 0

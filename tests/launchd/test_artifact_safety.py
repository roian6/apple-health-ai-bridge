from __future__ import annotations

import os
import stat
from dataclasses import replace
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

import health_bridge.launchd.artifacts as artifacts_module
import health_bridge.launchd.private_artifacts as private_artifacts_module
from health_bridge.launchd import (
    LaunchdServiceError,
    load_owned_launch_agent_request,
    remove_launch_agent_artifacts,
    validate_launch_agent,
    write_launch_agent_artifacts,
)
from tests.launchd.support import service_request

if TYPE_CHECKING:
    from collections.abc import Callable


def _error_code(action: Callable[[], object]) -> str:
    with pytest.raises(LaunchdServiceError) as raised:
        _ = action()
    return raised.value.code.value


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("executable", Path("relative/health-bridge")),
        ("db_path", Path("relative/health.sqlite")),
        ("mailbox_root", Path("relative/mailbox")),
        ("icloud_container_identifier", "iCloud.dev.example\nInjected"),
    ],
)
def test_validation_rejects_path_and_argument_injection_before_mutation(
    tmp_path: Path,
    field: str,
    value: Path | str,
) -> None:
    request = replace(service_request(tmp_path), **{field: value})

    code = _error_code(lambda: validate_launch_agent(request))

    assert code == "invalid_configuration"
    assert not request.paths.state_dir.exists()
    assert not request.paths.manifest.exists()


def test_install_rejects_symlinked_state_directory_before_mutation(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    external = tmp_path / "external"
    external.mkdir()
    request.paths.state_dir.parent.mkdir(parents=True)
    request.paths.state_dir.symlink_to(external, target_is_directory=True)

    code = _error_code(
        lambda: write_launch_agent_artifacts(
            request,
            activate=False,
        )
    )

    assert code == "unsafe_filesystem"
    assert list(external.iterdir()) == []
    assert not request.paths.manifest.exists()


def test_validation_rejects_group_writable_input_parent_before_mutation(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    request.db_path.parent.chmod(0o770)

    code = _error_code(lambda: validate_launch_agent(request))

    assert code == "unsafe_permissions"
    assert not request.paths.state_dir.exists()
    assert not request.paths.manifest.exists()


def test_validation_rejects_group_readable_private_database_before_mutation(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    request.db_path.chmod(0o640)

    code = _error_code(lambda: validate_launch_agent(request))

    assert code == "unsafe_permissions"
    assert not request.paths.state_dir.exists()
    assert not request.paths.manifest.exists()


def test_validation_rejects_group_readable_private_state_directory(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    request.paths.state_dir.mkdir(parents=True, mode=0o750)
    request.paths.state_dir.chmod(0o750)

    code = _error_code(lambda: validate_launch_agent(request))

    assert code == "unsafe_permissions"
    assert not request.paths.manifest.exists()


def test_validation_rejects_non_regular_database_before_mutation(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    request.db_path.unlink()
    request.db_path.mkdir(mode=0o700)

    code = _error_code(lambda: validate_launch_agent(request))

    assert code == "unsafe_filesystem"
    assert not request.paths.state_dir.exists()
    assert not request.paths.manifest.exists()


def test_install_rejects_foreign_manifest_without_overwrite(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    request.paths.manifest.parent.mkdir(parents=True, mode=0o700)
    request.paths.manifest.parent.chmod(0o700)
    foreign = b"foreign synthetic manifest"
    _ = request.paths.manifest.write_bytes(foreign)
    request.paths.manifest.chmod(0o600)

    code = _error_code(
        lambda: write_launch_agent_artifacts(
            request,
            activate=False,
        )
    )

    assert code == "foreign_manifest"
    assert request.paths.manifest.read_bytes() == foreign
    assert not request.paths.config.exists()
    assert not request.paths.ownership.exists()


def test_reinstall_is_idempotent_but_owned_manifest_drift_fails_closed(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    original_config = request.paths.config.read_bytes()
    original_ownership = request.paths.ownership.read_bytes()
    _ = write_launch_agent_artifacts(request, activate=False)
    _ = request.paths.manifest.write_bytes(b"synthetic owner-only drift")
    request.paths.manifest.chmod(0o600)

    code = _error_code(
        lambda: write_launch_agent_artifacts(
            request,
            activate=False,
        )
    )

    assert code == "manifest_drift"
    assert request.paths.manifest.read_bytes() == b"synthetic owner-only drift"
    assert request.paths.config.read_bytes() == original_config
    assert request.paths.ownership.read_bytes() == original_ownership


def test_reinstall_rejects_group_writable_owned_artifact(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    request.paths.manifest.chmod(0o660)

    code = _error_code(
        lambda: write_launch_agent_artifacts(
            request,
            activate=False,
        )
    )

    assert code == "unsafe_permissions"
    assert stat.S_IMODE(request.paths.manifest.stat().st_mode) == 0o660


def test_uninstall_is_idempotent_and_retires_only_owned_service_state(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    sibling = request.paths.manifest.parent / "synthetic.foreign.plist"
    sibling.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    sibling.parent.chmod(0o700)
    _ = sibling.write_text("foreign", encoding="utf-8")
    health_db = request.db_path
    _ = write_launch_agent_artifacts(request, activate=False)

    _ = remove_launch_agent_artifacts(request, deactivate=False)
    _ = remove_launch_agent_artifacts(request, deactivate=False)

    assert sibling.read_text(encoding="utf-8") == "foreign"
    assert health_db.is_file()
    assert not request.paths.manifest.exists()
    assert request.paths.state_dir.is_dir()
    assert all(path.stat().st_size == 0 for path in request.paths.state_dir.iterdir())


def test_install_fails_closed_when_state_directory_is_replaced_before_publish(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    request.paths.state_dir.mkdir(parents=True, mode=0o700)
    detached = request.paths.state_dir.with_name("detached-launchd")
    replacement = request.paths.state_dir
    swapped = False

    def swap_before_publish(boundary: str, path: Path) -> None:
        nonlocal swapped
        if (
            boundary == "before_publish"
            and path == request.paths.config
            and not swapped
        ):
            swapped = True
            _ = replacement.rename(detached)
            replacement.mkdir(mode=0o700)

    code = _error_code(
        lambda: write_launch_agent_artifacts(
            request,
            activate=False,
            mutation_hook=swap_before_publish,
        )
    )

    assert code == "unsafe_filesystem"
    assert list(detached.iterdir()) == []
    assert list(replacement.iterdir()) == []
    assert not request.paths.manifest.exists()


def test_uninstall_preserves_foreign_replacement_before_identity_safe_retirement(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    original_config = request.paths.config.with_name("validated-config")
    foreign = b"synthetic foreign replacement"
    replaced = False

    def replace_after_validation(boundary: str, path: Path) -> None:
        nonlocal replaced
        if boundary == "before_retire" and path == request.paths.config:
            assert not replaced
            replaced = True
            _ = request.paths.config.rename(original_config)
            _ = request.paths.config.write_bytes(foreign)
            request.paths.config.chmod(0o600)

    code = _error_code(
        lambda: remove_launch_agent_artifacts(
            request,
            deactivate=False,
            mutation_hook=replace_after_validation,
        )
    )

    assert code == "unsafe_filesystem"
    assert request.paths.config.read_bytes() == foreign
    assert original_config.is_file()


def test_atomic_private_create_never_chmods_symlink_replacement_after_publish(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    directory = tmp_path / "private"
    directory.mkdir(mode=0o700)
    final = directory / "receiver.json"
    foreign_target = tmp_path / "foreign-target"
    _ = foreign_target.write_bytes(b"foreign")
    foreign_target.chmod(0o640)
    original_rename = private_artifacts_module.exclusive_rename
    detached = directory / "detached-owned-final"

    def replace_after_rename(
        source_dir_fd: int,
        source_name: str,
        destination_dir_fd: int,
        destination_name: str,
    ) -> None:
        original_rename(
            source_dir_fd,
            source_name,
            destination_dir_fd,
            destination_name,
        )
        if destination_name == final.name:
            os.rename(
                destination_name,
                detached.name,
                src_dir_fd=destination_dir_fd,
                dst_dir_fd=destination_dir_fd,
            )
            os.symlink(foreign_target, destination_name, dir_fd=destination_dir_fd)

    monkeypatch.setattr(
        private_artifacts_module,
        "exclusive_rename",
        replace_after_rename,
    )

    code = _error_code(
        lambda: private_artifacts_module.atomic_create_private(final, b"private")
    )

    assert code == "unsafe_filesystem"
    assert not final.exists()
    recovered_symlinks = [path for path in directory.iterdir() if path.is_symlink()]
    assert len(recovered_symlinks) == 1
    assert foreign_target.read_bytes() == b"foreign"
    assert stat.S_IMODE(foreign_target.stat().st_mode) == 0o640
    assert detached.read_bytes() == b""


def test_manifest_publication_failure_rolls_back_only_new_service_artifacts(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = service_request(tmp_path)
    sibling = request.paths.state_dir / "foreign-sibling"
    request.paths.state_dir.mkdir(parents=True, mode=0o700)
    _ = sibling.write_bytes(b"foreign")
    sibling.chmod(0o600)
    original_create = private_artifacts_module.atomic_create_private

    def fail_manifest(
        path: Path,
        content: bytes,
        *,
        directory: private_artifacts_module.PrivateDirectory | None = None,
    ) -> private_artifacts_module.CreatedArtifact:
        if path == request.paths.manifest:
            failure = "synthetic final publication failure"
            raise OSError(failure)
        return original_create(path, content, directory=directory)

    monkeypatch.setattr(artifacts_module, "atomic_create_private", fail_manifest)

    code = _error_code(lambda: write_launch_agent_artifacts(request, activate=False))

    assert code == "unsafe_filesystem"
    assert sibling.read_bytes() == b"foreign"
    assert request.db_path.is_file()
    assert request.mailbox_root.is_dir()
    for path in (
        request.paths.config,
        request.paths.ownership,
        request.paths.stdout_log,
        request.paths.stderr_log,
        request.paths.manifest,
    ):
        assert not path.exists()
    assert request.paths.state_dir.is_dir()
    assert request.paths.manifest.parent.is_dir()

    monkeypatch.setattr(artifacts_module, "atomic_create_private", original_create)
    result = write_launch_agent_artifacts(request, activate=False)
    assert result.code.value == "installed"


def test_fresh_manifest_publication_failure_leaves_empty_private_directories(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = service_request(tmp_path)
    original_create = private_artifacts_module.atomic_create_private

    def fail_manifest(
        path: Path,
        content: bytes,
        *,
        directory: private_artifacts_module.PrivateDirectory | None = None,
    ) -> private_artifacts_module.CreatedArtifact:
        if path == request.paths.manifest:
            failure = "synthetic final publication failure"
            raise OSError(failure)
        return original_create(path, content, directory=directory)

    monkeypatch.setattr(artifacts_module, "atomic_create_private", fail_manifest)

    code = _error_code(lambda: write_launch_agent_artifacts(request, activate=False))

    assert code == "unsafe_filesystem"
    assert request.paths.state_dir.is_dir()
    assert all(path.stat().st_size == 0 for path in request.paths.state_dir.iterdir())
    assert request.paths.manifest.parent.is_dir()
    assert request.db_path.is_file()
    assert request.mailbox_root.is_dir()


def test_owned_installation_load_ignores_missing_runtime_targets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = service_request(tmp_path)
    _ = write_launch_agent_artifacts(request, activate=False)
    request.executable.unlink()
    request.db_path.unlink()
    request.mailbox_root.rmdir()
    monkeypatch.setenv("HOME", str(request.home))

    loaded = load_owned_launch_agent_request(request.paths.config)

    assert loaded.executable == request.executable
    assert loaded.db_path == request.db_path
    assert loaded.mailbox_root == request.mailbox_root

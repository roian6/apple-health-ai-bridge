"""Launchd artifact transaction state machine kept as one auditable unit.

No-excuse size audit: # noqa: SIZE_OK — splitting would obscure recovery order.
"""

from __future__ import annotations

import hashlib
import os
import secrets
import stat
from collections.abc import Callable
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Self

from pydantic import ValidationError

from health_bridge.launchd.manifest import (
    render_launch_agent_plist,
    render_ownership_record,
    render_service_config,
)
from health_bridge.launchd.models import (
    LaunchdOwnershipRecord,
    LaunchdServiceCode,
    LaunchdServiceConfig,
    LaunchdServiceError,
    LaunchdServiceErrorCode,
    LaunchdServicePaths,
    LaunchdServiceRequest,
    LaunchdServiceResult,
    service_paths,
)
from health_bridge.launchd.private_artifacts import (
    ArtifactSnapshot,
    CreatedArtifact,
    PrivateDirectory,
    entry_exists,
    move_exact,
    path_entry_exists,
    read_owner_only_file_at,
    retire_exact,
    snapshot_owner_only_file_at,
    verify_exact,
)
from health_bridge.launchd.private_artifacts import (
    atomic_create_private as _atomic_create_private,
)
from health_bridge.launchd.validation import (
    validate_launch_agent,
    validate_launch_agent_structure,
)

if TYPE_CHECKING:
    from collections.abc import Generator
    from types import TracebackType


@dataclass(frozen=True, slots=True)
class ArtifactDirectories:
    state: PrivateDirectory
    manifests: PrivateDirectory

    @classmethod
    def open(cls, request: LaunchdServiceRequest, *, create: bool) -> Self:
        return cls.open_paths(request.paths, create=create)

    @classmethod
    def open_paths(cls, paths: LaunchdServicePaths, *, create: bool) -> Self:
        state = PrivateDirectory.open(
            paths.state_dir,
            create=create,
            owner_only=True,
        )
        try:
            manifests = PrivateDirectory.open(
                paths.manifest.parent,
                create=create,
                owner_only=False,
            )
        except LaunchdServiceError:
            state.close()
            raise
        return cls(state=state, manifests=manifests)

    def close(self) -> None:
        first_error: LaunchdServiceError | None = None
        for directory in (self.manifests, self.state):
            try:
                directory.close()
            except LaunchdServiceError as exc:
                if first_error is None:
                    first_error = exc
        if first_error is not None:
            raise first_error

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self,
        _exception_type: type[BaseException] | None,
        _exception: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        self.close()


@dataclass(frozen=True, slots=True)
class OwnedArtifacts:
    manifest: ArtifactSnapshot
    ownership: ArtifactSnapshot
    config: ArtifactSnapshot
    logs: tuple[CreatedArtifact, ...]


@dataclass(frozen=True, slots=True)
class _PreparedUpgrade:
    directory: PrivateDirectory
    original: ArtifactSnapshot
    backup: CreatedArtifact
    staged: CreatedArtifact


@dataclass(frozen=True, slots=True)
class _UpgradePreparation:
    items: tuple[_PreparedUpgrade, ...]
    inventory: tuple[tuple[PrivateDirectory, CreatedArtifact], ...]


ArtifactMutationHook = Callable[[str, Path], None]


def atomic_create_private(
    path: Path,
    content: bytes,
    *,
    directory: PrivateDirectory | None = None,
) -> CreatedArtifact:
    return _atomic_create_private(path, content, directory=directory)


def write_launch_agent_artifacts(
    request: LaunchdServiceRequest,
    *,
    activate: bool,
    mutation_hook: ArtifactMutationHook | None = None,
) -> LaunchdServiceResult:
    del activate
    with launch_agent_artifact_transaction(
        request,
        mutation_hook=mutation_hook,
    ) as result:
        return result


@contextmanager
def launch_agent_artifact_transaction(
    request: LaunchdServiceRequest,
    *,
    mutation_hook: ArtifactMutationHook | None = None,
) -> Generator[LaunchdServiceResult, None, None]:
    _ = validate_launch_agent(request)
    manifest = render_launch_agent_plist(request)
    config = render_service_config(request)
    ownership = render_ownership_record(manifest, config)
    with ArtifactDirectories.open(request, create=True) as directories:
        current = _installed_artifact_state(
            request,
            manifest,
            config,
            directories=directories,
        )
        if current is LaunchdServiceCode.ALREADY_INSTALLED:
            yield LaunchdServiceResult(code=current)
            return
        created: list[tuple[PrivateDirectory, CreatedArtifact]] = []
        try:
            for path, content, directory in (
                (request.paths.config, config, directories.state),
                (request.paths.stdout_log, b"", directories.state),
                (request.paths.stderr_log, b"", directories.state),
                (request.paths.ownership, ownership, directories.state),
                (request.paths.manifest, manifest, directories.manifests),
            ):
                if mutation_hook is not None:
                    mutation_hook("before_publish", path)
                artifact = atomic_create_private(
                    path,
                    content,
                    directory=directory,
                )
                created.append((directory, artifact))
        except (FileExistsError, LaunchdServiceError, OSError) as exc:
            rollback_error = _rollback_install(created, directories)
            if rollback_error is not None:
                raise rollback_error from exc
            if isinstance(exc, FileExistsError):
                raise LaunchdServiceError(
                    LaunchdServiceErrorCode.MANIFEST_DRIFT
                ) from exc
            if isinstance(exc, LaunchdServiceError):
                raise
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.UNSAFE_FILESYSTEM
            ) from exc
        try:
            yield LaunchdServiceResult(code=LaunchdServiceCode.INSTALLED)
        except (LaunchdServiceError, OSError) as exc:
            rollback_error = _rollback_install(created, directories)
            if rollback_error is not None:
                raise rollback_error from exc
            raise


def remove_launch_agent_artifacts(
    request: LaunchdServiceRequest,
    *,
    deactivate: bool,
    mutation_hook: ArtifactMutationHook | None = None,
) -> LaunchdServiceResult:
    del deactivate
    paths = request.paths
    if not active_launch_agent_artifacts_exist(paths):
        return LaunchdServiceResult(code=LaunchdServiceCode.ALREADY_UNINSTALLED)
    with ArtifactDirectories.open(request, create=False) as directories:
        owned = _read_owned_artifacts(request.paths, directories)
        _require_current_config(request, owned)
        removals = (
            (directories.manifests, owned.manifest),
            (directories.state, owned.ownership),
            (directories.state, owned.config),
            *((directories.state, log) for log in owned.logs),
        )
        if mutation_hook is not None:
            for _directory, artifact in removals:
                mutation_hook(
                    "before_remove_preflight", artifact_path(request, artifact)
                )
        for directory, artifact in removals:
            verify_exact(directory, artifact)
        for directory, artifact in removals:
            if mutation_hook is not None:
                mutation_hook("before_retire", artifact_path(request, artifact))
            _ = retire_exact(directory, artifact)
    return LaunchdServiceResult(code=LaunchdServiceCode.UNINSTALLED)


def active_launch_agent_artifacts_exist(paths: LaunchdServicePaths) -> bool:
    try:
        state_entry = paths.state_dir.lstat()
    except FileNotFoundError:
        state_entry = None
    except OSError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    if state_entry is not None and not stat.S_ISDIR(state_entry.st_mode):
        return True
    return any(
        path_entry_exists(path)
        for path in (
            paths.manifest,
            paths.config,
            paths.ownership,
            paths.stdout_log,
            paths.stderr_log,
        )
    )


def artifacts_are_owned(request: LaunchdServiceRequest) -> bool:
    try:
        with ArtifactDirectories.open(request, create=False) as directories:
            owned = _read_owned_artifacts(request.paths, directories)
            _require_current_config(request, owned)
    except LaunchdServiceError:
        return False
    return True


def load_owned_launch_agent_request(config_path: Path) -> LaunchdServiceRequest:
    home = Path.home().resolve(strict=True)
    paths = service_paths(home)
    if config_path != paths.config or not config_path.is_absolute():
        raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
    with ArtifactDirectories.open_paths(paths, create=False) as directories:
        owned = _read_owned_artifacts(paths, directories)
        request = _request_from_owned_config(owned.config.content, home)
        _ = validate_launch_agent_structure(request)
    return request


def load_runnable_launch_agent_request(config_path: Path) -> LaunchdServiceRequest:
    request = load_owned_launch_agent_request(config_path)
    _ = validate_launch_agent(request)
    return request


def owned_artifacts_match_request(
    current: LaunchdServiceRequest,
    desired: LaunchdServiceRequest,
) -> bool:
    _ = validate_launch_agent(desired)
    with ArtifactDirectories.open(current, create=False) as directories:
        owned = _read_owned_artifacts(current.paths, directories)
        _require_current_config(current, owned)
        return owned.manifest.content == render_launch_agent_plist(
            desired
        ) and owned.config.content == render_service_config(desired)


@contextmanager
def replace_launch_agent_artifacts(
    current: LaunchdServiceRequest,
    desired: LaunchdServiceRequest,
    *,
    mutation_hook: ArtifactMutationHook | None = None,
) -> Generator[None, None, None]:
    _ = validate_launch_agent(desired)
    with ArtifactDirectories.open(current, create=False) as directories:
        owned = _read_owned_artifacts(current.paths, directories)
        _require_current_config(current, owned)
        preparation = _prepare_upgrade(directories, owned, desired)
        replaced: list[
            tuple[
                PrivateDirectory,
                CreatedArtifact,
                CreatedArtifact,
            ]
        ] = []
        try:
            for item in preparation.items:
                if mutation_hook is not None:
                    mutation_hook(
                        "before_replace_retire",
                        artifact_path(current, item.original),
                    )
                _ = retire_exact(
                    item.directory,
                    item.original,
                    recovery_required=True,
                )
                installed = move_exact(
                    item.directory,
                    item.staged,
                    item.original.name,
                )
                replaced.append((item.directory, installed, item.backup))
        except LaunchdServiceError as exc:
            rollback_error = _rollback_replacements(replaced)
            if (
                exc.code is LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
                or rollback_error is not None
            ):
                raise LaunchdServiceError(
                    LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
                ) from exc
            cleanup_error = _cleanup_inventory(preparation.inventory)
            if cleanup_error is not None:
                raise LaunchdServiceError(
                    LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
                ) from exc
            raise
        try:
            yield
        except LaunchdServiceError as exc:
            rollback_error = _rollback_replacements(replaced)
            if rollback_error is not None:
                raise LaunchdServiceError(
                    LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
                ) from exc
            cleanup_error = _cleanup_inventory(preparation.inventory)
            if cleanup_error is not None:
                raise LaunchdServiceError(
                    LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
                ) from exc
            raise
        cleanup_error = _cleanup_inventory(preparation.inventory)
        if cleanup_error is not None:
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
            ) from cleanup_error


def _installed_artifact_state(
    request: LaunchdServiceRequest,
    manifest: bytes,
    config: bytes,
    *,
    directories: ArtifactDirectories,
) -> LaunchdServiceCode:
    paths = request.paths
    present = (
        entry_exists(directories.manifests, paths.manifest.name),
        entry_exists(directories.state, paths.ownership.name),
        entry_exists(directories.state, paths.config.name),
    )
    if present == (False, False, False):
        return LaunchdServiceCode.INSTALLED
    if present[0] and not present[1]:
        raise LaunchdServiceError(LaunchdServiceErrorCode.FOREIGN_MANIFEST)
    _ = require_owned_artifacts(
        request,
        manifest,
        config,
        directories=directories,
    )
    return LaunchdServiceCode.ALREADY_INSTALLED


def require_owned_artifacts(
    request: LaunchdServiceRequest,
    manifest: bytes,
    config: bytes,
    *,
    directories: ArtifactDirectories | None = None,
) -> OwnedArtifacts:
    owned_directories = directories is None
    bound = directories or ArtifactDirectories.open(request, create=False)
    try:
        owned = _read_owned_artifacts(request.paths, bound)
        if owned.manifest.content != manifest or owned.config.content != config:
            raise LaunchdServiceError(LaunchdServiceErrorCode.MANIFEST_DRIFT)
        return owned
    finally:
        if owned_directories:
            bound.close()


def _rollback_created(
    created: list[tuple[PrivateDirectory, CreatedArtifact]],
) -> LaunchdServiceError | None:
    first_error: LaunchdServiceError | None = None
    for directory, artifact in reversed(created):
        try:
            _ = retire_exact(directory, artifact)
        except LaunchdServiceError as exc:
            if first_error is None:
                first_error = exc
    return first_error


def _rollback_install(
    created: list[tuple[PrivateDirectory, CreatedArtifact]],
    directories: ArtifactDirectories,
) -> LaunchdServiceError | None:
    del directories
    return _rollback_created(created)


def _read_owned_artifacts(
    paths: LaunchdServicePaths,
    directories: ArtifactDirectories,
) -> OwnedArtifacts:
    manifest_exists = entry_exists(directories.manifests, paths.manifest.name)
    ownership_exists = entry_exists(directories.state, paths.ownership.name)
    config_exists = entry_exists(directories.state, paths.config.name)
    if manifest_exists and not ownership_exists:
        raise LaunchdServiceError(LaunchdServiceErrorCode.FOREIGN_MANIFEST)
    if not (manifest_exists and ownership_exists and config_exists):
        raise LaunchdServiceError(LaunchdServiceErrorCode.MANIFEST_DRIFT)
    manifest = read_owner_only_file_at(directories.manifests, paths.manifest.name)
    ownership = read_owner_only_file_at(directories.state, paths.ownership.name)
    config = read_owner_only_file_at(directories.state, paths.config.name)
    try:
        record = LaunchdOwnershipRecord.model_validate_json(ownership.content)
    except ValidationError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.MANIFEST_DRIFT) from exc
    if (
        record.manifest_sha256 != hashlib.sha256(manifest.content).hexdigest()
        or record.config_sha256 != hashlib.sha256(config.content).hexdigest()
    ):
        raise LaunchdServiceError(LaunchdServiceErrorCode.MANIFEST_DRIFT)
    logs = tuple(
        snapshot_owner_only_file_at(directories.state, path.name)
        for path in (paths.stdout_log, paths.stderr_log)
        if entry_exists(directories.state, path.name)
    )
    return OwnedArtifacts(
        manifest=manifest,
        ownership=ownership,
        config=config,
        logs=logs,
    )


def _request_from_owned_config(content: bytes, home: Path) -> LaunchdServiceRequest:
    try:
        config = LaunchdServiceConfig.model_validate_json(content)
    except ValidationError as exc:
        raise LaunchdServiceError(
            LaunchdServiceErrorCode.INVALID_CONFIGURATION
        ) from exc
    return LaunchdServiceRequest(
        executable=config.executable,
        db_path=config.db_path,
        mailbox_root=config.mailbox_root,
        icloud_container_identifier=config.icloud_container_identifier,
        home=home,
        uid=os.geteuid(),
        host=config.host,
        port=config.port,
    )


def _require_current_config(
    current: LaunchdServiceRequest,
    owned: OwnedArtifacts,
) -> None:
    if owned.config.content != render_service_config(current):
        raise LaunchdServiceError(LaunchdServiceErrorCode.MANIFEST_DRIFT)


def _prepare_upgrade(
    directories: ArtifactDirectories,
    owned: OwnedArtifacts,
    desired: LaunchdServiceRequest,
) -> _UpgradePreparation:
    desired_manifest = render_launch_agent_plist(desired)
    desired_config = render_service_config(desired)
    desired_ownership = render_ownership_record(desired_manifest, desired_config)
    prepared: list[_PreparedUpgrade] = []
    inventory: list[tuple[PrivateDirectory, CreatedArtifact]] = []
    try:
        for directory, original, content in (
            (directories.state, owned.config, desired_config),
            (directories.state, owned.ownership, desired_ownership),
            (directories.manifests, owned.manifest, desired_manifest),
        ):
            token = secrets.token_hex(16)
            backup_path = directory.path / f".{original.name}.{token}.backup"
            staged_path = directory.path / f".{original.name}.{token}.staged"
            backup = atomic_create_private(
                backup_path,
                original.content,
                directory=directory,
            )
            inventory.append((directory, backup))
            staged = atomic_create_private(
                staged_path,
                content,
                directory=directory,
            )
            inventory.append((directory, staged))
            prepared.append(
                _PreparedUpgrade(
                    directory=directory,
                    original=original,
                    backup=backup,
                    staged=staged,
                )
            )
    except (FileExistsError, LaunchdServiceError, OSError) as exc:
        cleanup_error = _cleanup_inventory(tuple(inventory))
        if cleanup_error is not None:
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
            ) from exc
        if isinstance(exc, LaunchdServiceError):
            raise
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    return _UpgradePreparation(items=tuple(prepared), inventory=tuple(inventory))


def _rollback_replacements(
    replaced: list[
        tuple[
            PrivateDirectory,
            CreatedArtifact,
            CreatedArtifact,
        ]
    ],
) -> LaunchdServiceError | None:
    first_error: LaunchdServiceError | None = None
    for directory, installed, backup in reversed(replaced):
        try:
            _ = retire_exact(
                directory,
                installed,
                recovery_required=True,
            )
            _ = move_exact(directory, backup, installed.name)
        except LaunchdServiceError as exc:
            if first_error is None:
                first_error = exc
    return first_error


def _cleanup_inventory(
    inventory: tuple[tuple[PrivateDirectory, CreatedArtifact], ...],
) -> LaunchdServiceError | None:
    first_error: LaunchdServiceError | None = None
    for directory, artifact in reversed(inventory):
        try:
            if entry_exists(directory, artifact.name):
                _ = retire_exact(directory, artifact)
        except LaunchdServiceError as exc:
            if first_error is None:
                first_error = exc
    return first_error


def artifact_path(
    request: LaunchdServiceRequest,
    artifact: ArtifactSnapshot | CreatedArtifact,
) -> Path:
    if artifact.name == request.paths.manifest.name:
        return request.paths.manifest
    return request.paths.state_dir / artifact.name

"""Dir-FD launchd artifact mutations kept as one auditable unit.

No-excuse size audit: # noqa: SIZE_OK — splitting would obscure mutation order.
"""

from __future__ import annotations

import os
import secrets
import stat
from dataclasses import dataclass
from typing import TYPE_CHECKING, Final, Self, final

from health_bridge.launchd.exclusive_rename import (
    exclusive_rename as _platform_exclusive_rename,
)
from health_bridge.launchd.models import (
    LaunchdServiceError,
    LaunchdServiceErrorCode,
)
from health_bridge.private_files import PRIVATE_FILE_MODE

if TYPE_CHECKING:
    from pathlib import Path
    from types import TracebackType

_DIRECTORY_FLAGS: Final = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_CLOEXEC", 0)
)
_READ_FLAGS: Final = (
    os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
)
_WRITE_FLAGS: Final = (
    os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
)
_CREATE_FLAGS: Final = (
    os.O_WRONLY
    | os.O_CREAT
    | os.O_EXCL
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_CLOEXEC", 0)
)


def exclusive_rename(
    source_dir_fd: int,
    source_name: str,
    destination_dir_fd: int,
    destination_name: str,
) -> None:
    _platform_exclusive_rename(
        source_dir_fd,
        source_name,
        destination_dir_fd,
        destination_name,
    )


@dataclass(frozen=True, slots=True)
class FileIdentity:
    device: int
    inode: int
    size: int
    modified_ns: int
    changed_ns: int


@dataclass(frozen=True, slots=True)
class ArtifactSnapshot:
    name: str
    content: bytes
    identity: FileIdentity


@dataclass(frozen=True, slots=True)
class CreatedArtifact:
    name: str
    identity: FileIdentity


@final
class PrivateDirectory:
    """Retain and validate one absolute directory's complete attachment chain."""

    def __init__(
        self,
        *,
        path: Path,
        descriptors: list[int],
        attachments: list[tuple[int, str, int, tuple[int, int]]],
        created_components: list[bool],
    ) -> None:
        self.path = path
        self._descriptors = descriptors
        self._attachments = attachments
        self._created_components = created_components
        self._closed = False

    @classmethod
    def open(
        cls,
        path: Path,
        *,
        create: bool,
        owner_only: bool,
    ) -> Self:
        absolute = path.absolute()
        if not absolute.is_absolute() or absolute.name in {"", ".", ".."}:
            raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
        descriptors: list[int] = []
        attachments: list[tuple[int, str, int, tuple[int, int]]] = []
        try:
            descriptors, attachments, created_components = _open_directory_chain(
                absolute,
                create=create,
            )
            _require_private_directory(os.fstat(descriptors[-1]), owner_only=owner_only)
            opened_directory = cls(
                path=absolute,
                descriptors=descriptors,
                attachments=attachments,
                created_components=created_components,
            )
            opened_directory.validate_attached()
        except LaunchdServiceError:
            _close_after_failure(descriptors)
            raise
        except OSError as exc:
            _close_after_failure(descriptors)
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.UNSAFE_FILESYSTEM
            ) from exc
        else:
            return opened_directory

    @property
    def fd(self) -> int:
        return self._descriptors[-1]

    @property
    def parent_fd(self) -> int:
        if not self._attachments:
            raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
        return self._attachments[-1][0]

    @property
    def name(self) -> str:
        return self.path.name

    @property
    def identity(self) -> tuple[int, int]:
        if not self._attachments:
            raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
        return self._attachments[-1][3]

    @property
    def created(self) -> bool:
        return bool(self._created_components and self._created_components[-1])

    def validate_attached(self) -> None:
        try:
            for parent_fd, name, opened_fd, expected in self._attachments:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                opened = os.fstat(opened_fd)
                if (
                    _entry_identity(current) != expected
                    or _entry_identity(opened) != expected
                    or not stat.S_ISDIR(current.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                ):
                    raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
        except OSError as exc:
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.UNSAFE_FILESYSTEM
            ) from exc

    def close(self) -> None:
        if self._closed:
            return
        first_error: OSError | None = None
        for descriptor in reversed(self._descriptors):
            if descriptor < 0:
                continue
            try:
                os.close(descriptor)
            except OSError as exc:
                if first_error is None:
                    first_error = exc
        self._descriptors.clear()
        self._closed = True
        if first_error is not None:
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.UNSAFE_FILESYSTEM
            ) from first_error

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self,
        _exception_type: type[BaseException] | None,
        _exception: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        self.close()


def entry_exists(directory: PrivateDirectory, name: str) -> bool:
    directory.validate_attached()
    try:
        _ = os.stat(name, dir_fd=directory.fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    return True


def path_entry_exists(path: Path) -> bool:
    try:
        _ = path.lstat()
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    return True


def read_owner_only_file(path: Path) -> bytes:
    with PrivateDirectory.open(
        path.parent,
        create=False,
        owner_only=False,
    ) as directory:
        return read_owner_only_file_at(directory, path.name).content


def read_owner_only_file_at(
    directory: PrivateDirectory,
    name: str,
) -> ArtifactSnapshot:
    directory.validate_attached()
    descriptor = -1
    try:
        initial = os.stat(name, dir_fd=directory.fd, follow_symlinks=False)
        _require_owner_only_regular(initial)
        descriptor = os.open(name, _READ_FLAGS, dir_fd=directory.fd)
        opened = os.fstat(descriptor)
        _require_owner_only_regular(opened)
        _require_identity(_file_identity(initial), _file_identity(opened))
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        final = os.fstat(descriptor)
        current = os.stat(name, dir_fd=directory.fd, follow_symlinks=False)
        identity = _file_identity(opened)
        _require_identity(identity, _file_identity(final), _file_identity(current))
        directory.validate_attached()
        return ArtifactSnapshot(
            name=name,
            content=b"".join(chunks),
            identity=identity,
        )
    except LaunchdServiceError:
        raise
    except OSError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def snapshot_owner_only_file_at(
    directory: PrivateDirectory,
    name: str,
) -> CreatedArtifact:
    directory.validate_attached()
    descriptor = -1
    try:
        descriptor = os.open(name, _READ_FLAGS, dir_fd=directory.fd)
        opened = os.fstat(descriptor)
        _require_owner_only_regular(opened)
        current = os.stat(name, dir_fd=directory.fd, follow_symlinks=False)
        identity = _file_identity(opened)
        _require_identity(identity, _file_identity(current))
        directory.validate_attached()
        return CreatedArtifact(name=name, identity=identity)
    except LaunchdServiceError:
        raise
    except OSError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def atomic_create_private(
    path: Path,
    content: bytes,
    *,
    directory: PrivateDirectory | None = None,
) -> CreatedArtifact:
    owned_directory = directory is None
    bound = directory or PrivateDirectory.open(
        path.parent,
        create=False,
        owner_only=False,
    )
    if bound.path != path.parent.absolute():
        if owned_directory:
            bound.close()
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)
    try:
        return _publish_private(bound, path.name, content)
    finally:
        if owned_directory:
            bound.close()


def _publish_private(
    directory: PrivateDirectory,
    final_name: str,
    content: bytes,
) -> CreatedArtifact:
    temporary_name = f".{final_name}.{secrets.token_hex(16)}.tmp"
    descriptor = -1
    try:
        directory.validate_attached()
        descriptor = os.open(
            temporary_name,
            _CREATE_FLAGS,
            PRIVATE_FILE_MODE,
            dir_fd=directory.fd,
        )
        _write_private_file(descriptor, content)
        directory.validate_attached()
        exclusive_rename(directory.fd, temporary_name, directory.fd, final_name)
        retained = _file_identity(os.fstat(descriptor))
        current = os.stat(final_name, dir_fd=directory.fd, follow_symlinks=False)
        if retained != _file_identity(current):
            recovery_name = _recovery_name(final_name)
            exclusive_rename(directory.fd, final_name, directory.fd, recovery_name)
            os.fsync(directory.fd)
            _scrub_descriptor(descriptor)
        _require_identity(retained, _file_identity(current))
        directory.validate_attached()
        os.fsync(directory.fd)
        final_identity = _file_identity(os.fstat(descriptor))
        verify_exact(
            directory,
            CreatedArtifact(name=final_name, identity=final_identity),
        )
        return CreatedArtifact(name=final_name, identity=final_identity)
    except FileExistsError:
        if descriptor >= 0:
            _scrub_descriptor(descriptor)
        raise
    except (LaunchdServiceError, OSError) as exc:
        if descriptor >= 0:
            _scrub_descriptor(descriptor)
        if isinstance(exc, OSError):
            raise LaunchdServiceError(
                LaunchdServiceErrorCode.UNSAFE_FILESYSTEM
            ) from exc
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def retire_exact(
    directory: PrivateDirectory,
    artifact: ArtifactSnapshot | CreatedArtifact,
    *,
    recovery_required: bool = False,
) -> CreatedArtifact:
    error_code = (
        LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
        if recovery_required
        else LaunchdServiceErrorCode.UNSAFE_FILESYSTEM
    )
    descriptor = -1
    recovery_name = _recovery_name(artifact.name)
    try:
        directory.validate_attached()
        descriptor = os.open(artifact.name, _WRITE_FLAGS, dir_fd=directory.fd)
        opened = os.fstat(descriptor)
        _require_owner_only_regular(opened)
        _require_artifact_identity(
            artifact.identity,
            _file_identity(opened),
            error_code,
        )
        directory.validate_attached()
        exclusive_rename(
            directory.fd,
            artifact.name,
            directory.fd,
            recovery_name,
        )
        retained = _file_identity(os.fstat(descriptor))
        moved = os.stat(recovery_name, dir_fd=directory.fd, follow_symlinks=False)
        _require_identity_with_code(retained, _file_identity(moved), error_code)
        _scrub_descriptor(descriptor)
        os.fsync(directory.fd)
        return CreatedArtifact(
            name=recovery_name,
            identity=_file_identity(os.fstat(descriptor)),
        )
    except FileExistsError as exc:
        raise LaunchdServiceError(error_code) from exc
    except LaunchdServiceError as exc:
        if exc.code is error_code:
            raise
        raise LaunchdServiceError(error_code) from exc
    except OSError as exc:
        raise LaunchdServiceError(error_code) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def move_exact(
    directory: PrivateDirectory,
    source: CreatedArtifact,
    destination_name: str,
) -> CreatedArtifact:
    descriptor = -1
    try:
        directory.validate_attached()
        descriptor = os.open(source.name, _READ_FLAGS, dir_fd=directory.fd)
        opened = os.fstat(descriptor)
        _require_owner_only_regular(opened)
        _require_artifact_identity(
            source.identity,
            _file_identity(opened),
            LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED,
        )
        directory.validate_attached()
        exclusive_rename(
            directory.fd,
            source.name,
            directory.fd,
            destination_name,
        )
        retained = _file_identity(os.fstat(descriptor))
        moved = os.stat(
            destination_name,
            dir_fd=directory.fd,
            follow_symlinks=False,
        )
        if retained != _file_identity(moved):
            recovery_name = _recovery_name(destination_name)
            exclusive_rename(
                directory.fd,
                destination_name,
                directory.fd,
                recovery_name,
            )
            os.fsync(directory.fd)
        _require_identity_with_code(
            retained,
            _file_identity(moved),
            LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED,
        )
        os.fsync(directory.fd)
        return CreatedArtifact(name=destination_name, identity=retained)
    except (FileExistsError, OSError, LaunchdServiceError) as exc:
        if (
            isinstance(exc, LaunchdServiceError)
            and exc.code is LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
        ):
            raise
        raise LaunchdServiceError(
            LaunchdServiceErrorCode.UPGRADE_RECOVERY_REQUIRED
        ) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def retire_if_present_exact(
    directory: PrivateDirectory,
    artifact: CreatedArtifact,
) -> CreatedArtifact | None:
    try:
        _ = os.stat(artifact.name, dir_fd=directory.fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    return retire_exact(directory, artifact)


def verify_exact(
    directory: PrivateDirectory,
    artifact: ArtifactSnapshot | CreatedArtifact,
) -> None:
    directory.validate_attached()
    try:
        current = os.stat(
            artifact.name,
            dir_fd=directory.fd,
            follow_symlinks=False,
        )
    except OSError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    _require_owner_only_regular(current)
    if not _matches_artifact_identity(artifact.identity, _file_identity(current)):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)


def _require_owner_only_regular(entry: os.stat_result) -> None:
    if (
        not stat.S_ISREG(entry.st_mode)
        or entry.st_uid != os.geteuid()
        or bool(entry.st_mode & 0o077)
    ):
        code = (
            LaunchdServiceErrorCode.UNSAFE_PERMISSIONS
            if stat.S_ISREG(entry.st_mode) and bool(entry.st_mode & 0o077)
            else LaunchdServiceErrorCode.UNSAFE_FILESYSTEM
        )
        raise LaunchdServiceError(code)


def _entry_identity(entry: os.stat_result) -> tuple[int, int]:
    return entry.st_dev, entry.st_ino


def _file_identity(entry: os.stat_result) -> FileIdentity:
    return FileIdentity(
        device=entry.st_dev,
        inode=entry.st_ino,
        size=entry.st_size,
        modified_ns=entry.st_mtime_ns,
        changed_ns=entry.st_ctime_ns,
    )


def _open_directory_chain(
    path: Path,
    *,
    create: bool,
) -> tuple[
    list[int],
    list[tuple[int, str, int, tuple[int, int]]],
    list[bool],
]:
    descriptors: list[int] = []
    attachments: list[tuple[int, str, int, tuple[int, int]]] = []
    created_components: list[bool] = []
    try:
        current = os.open(path.anchor, _DIRECTORY_FLAGS)
        descriptors.append(current)
        for component in path.parts[1:]:
            child, created = open_directory_component(
                current,
                component,
                create=create,
            )
            descriptors.append(child)
            opened = os.fstat(child)
            _require_directory(opened)
            attachments.append((current, component, child, _entry_identity(opened)))
            created_components.append(created)
            current = child
    except (LaunchdServiceError, OSError):
        _close_after_failure(descriptors)
        raise
    return descriptors, attachments, created_components


def _close_after_failure(descriptors: list[int]) -> None:
    for descriptor in reversed(descriptors):
        try:
            os.close(descriptor)
        except OSError:
            continue


def open_directory_component(
    parent_fd: int,
    name: str,
    *,
    create: bool,
) -> tuple[int, bool]:
    try:
        return os.open(name, _DIRECTORY_FLAGS, dir_fd=parent_fd), False
    except FileNotFoundError:
        if not create:
            raise
        os.mkdir(name, mode=0o700, dir_fd=parent_fd)
        return os.open(name, _DIRECTORY_FLAGS, dir_fd=parent_fd), True


def _require_directory(entry: os.stat_result) -> None:
    if not stat.S_ISDIR(entry.st_mode):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)


def _require_private_directory(entry: os.stat_result, *, owner_only: bool) -> None:
    _require_directory(entry)
    prohibited = 0o077 if owner_only else 0o022
    if entry.st_uid != os.geteuid() or bool(entry.st_mode & prohibited):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_PERMISSIONS)


def _require_identity(expected: FileIdentity, *observed: FileIdentity) -> None:
    if any(identity != expected for identity in observed):
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM)


def _require_identity_with_code(
    expected: FileIdentity,
    observed: FileIdentity,
    error_code: LaunchdServiceErrorCode,
) -> None:
    if observed != expected:
        raise LaunchdServiceError(error_code)


def _require_artifact_identity(
    expected: FileIdentity,
    observed: FileIdentity,
    error_code: LaunchdServiceErrorCode,
) -> None:
    if not _matches_artifact_identity(expected, observed):
        raise LaunchdServiceError(error_code)


def _matches_artifact_identity(expected: FileIdentity, observed: FileIdentity) -> bool:
    return (
        expected.device == observed.device
        and expected.inode == observed.inode
        and expected.size == observed.size
        and expected.modified_ns == observed.modified_ns
    )


def _write_private_file(descriptor: int, content: bytes) -> None:
    os.fchmod(descriptor, PRIVATE_FILE_MODE)
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        view = view[written:]
    os.fsync(descriptor)


def _scrub_descriptor(descriptor: int) -> None:
    os.ftruncate(descriptor, 0)
    os.fsync(descriptor)


def _recovery_name(active_name: str) -> str:
    return f".{active_name}.{secrets.token_hex(16)}.recovery"

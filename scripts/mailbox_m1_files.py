#!/usr/bin/env python3
from __future__ import annotations

import os
import stat
from pathlib import Path, PurePosixPath
from typing import Final

READ_FLAGS: Final = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
DIRECTORY_FLAGS: Final = READ_FLAGS | getattr(os, "O_DIRECTORY", 0)


def _path_parts(relative_path: str, required_prefix: str | None) -> tuple[str, ...]:
    path = PurePosixPath(relative_path)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        return ()
    if required_prefix is not None and not path.is_relative_to(
        PurePosixPath(required_prefix)
    ):
        return ()
    return path.parts


def _safe_primitives_available() -> bool:
    return (
        hasattr(os, "O_NOFOLLOW")
        and hasattr(os, "O_DIRECTORY")
        and hasattr(os, "O_NONBLOCK")
        and os.open in os.supports_dir_fd
        and os.stat in os.supports_dir_fd
        and os.stat in os.supports_follow_symlinks
    )


def _same_safe_file(*entries: os.stat_result) -> bool:
    identities = {(entry.st_dev, entry.st_ino) for entry in entries}
    return (
        len(identities) == 1
        and all(stat.S_ISREG(entry.st_mode) for entry in entries)
        and all(entry.st_nlink == 1 for entry in entries)
    )


def _read_from_directory(directory_fd: int, name: str) -> bytes | None:
    before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not _same_safe_file(before):
        return None
    file_fd = os.open(
        name,
        READ_FLAGS | os.O_NOFOLLOW | os.O_NONBLOCK,
        dir_fd=directory_fd,
    )
    with os.fdopen(file_fd, "rb") as artifact:
        opened = os.fstat(artifact.fileno())
        if not _same_safe_file(before, opened):
            return None
        content = artifact.read()
        after = os.fstat(artifact.fileno())
    current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not _same_safe_file(before, opened, after, current):
        return None
    if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ):
        return None
    return content


def read_scoped_regular_file(
    repository_root: Path,
    relative_path: str,
    required_prefix: str | None = None,
) -> bytes | None:
    parts = _path_parts(relative_path, required_prefix)
    if not parts or not _safe_primitives_available():
        return None
    try:
        resolved_root = repository_root.resolve(strict=True)
        if not repository_root.is_absolute() or resolved_root != repository_root:
            return None
        directory_fd = os.open(
            repository_root,
            DIRECTORY_FLAGS | os.O_NOFOLLOW,
        )
        try:
            for part in parts[:-1]:
                child_fd = os.open(
                    part,
                    DIRECTORY_FLAGS | os.O_NOFOLLOW,
                    dir_fd=directory_fd,
                )
                child = os.fstat(child_fd)
                if not stat.S_ISDIR(child.st_mode):
                    os.close(child_fd)
                    return None
                os.close(directory_fd)
                directory_fd = child_fd
            return _read_from_directory(directory_fd, parts[-1])
        finally:
            os.close(directory_fd)
    except OSError:
        return None


__all__ = ["read_scoped_regular_file"]

import os
from collections.abc import Generator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from pathlib import Path
from threading import RLock
from typing import Final


@dataclass(slots=True)
class _DescriptorLifetime:
    # Counts overlapping access scopes; descriptors retire only after SQLite closes.
    users: int = 0
    retired: list[int] = field(default_factory=list)


_MUTEX: Final = RLock()
_OWNERS: Final[dict[Path | tuple[int, int], _DescriptorLifetime]] = {}
_CURRENT: Final[ContextVar[_DescriptorLifetime | None]] = ContextVar(
    "database_descriptors",
    default=None,
)
_MAX_RETIRED: Final = 256


@contextmanager
def database_descriptor_lifetime(db_path: Path) -> Generator[None, None, None]:
    with _MUTEX:
        path = db_path.resolve()
        try:
            entry = db_path.stat(follow_symlinks=False)
            identity = (entry.st_dev, entry.st_ino)
        except FileNotFoundError:
            identity = None
        owner = _OWNERS.get(identity) if identity is not None else None
        owner = owner or _OWNERS.get(path) or _DescriptorLifetime()
        if owner.users + len(owner.retired) >= _MAX_RETIRED:
            message = "database descriptor lifetime is busy"
            raise BlockingIOError(message)
        owner.users += 1
        _OWNERS[path] = owner
        if identity is not None:
            _OWNERS[identity] = owner
    token = _CURRENT.set(owner)
    try:
        yield
    finally:
        _CURRENT.reset(token)
        with _MUTEX:
            owner.users -= 1
            if owner.users == 0:
                for fd in owner.retired:
                    os.close(fd)
                for key in [key for key, value in _OWNERS.items() if value is owner]:
                    del _OWNERS[key]


def register_database_descriptor(fd: int) -> None:
    owner = _CURRENT.get()
    if owner is None:
        return
    entry = os.fstat(fd)
    identity = (entry.st_dev, entry.st_ino)
    with _MUTEX:
        existing = _OWNERS.setdefault(identity, owner)
        if existing is not owner:
            message = "database identity changed during descriptor acquisition"
            raise OSError(message)


def retire_database_descriptor(fd: int, *, database_file: bool = True) -> None:
    # POSIX closes release *all* process record locks on this inode, including
    # SQLite's locks. Keep validation/flock descriptors until the last connection
    # and access scope has finished; SQLite manages its own descriptors separately.
    with _MUTEX:
        entry = os.fstat(fd)
        owner = _OWNERS.get((entry.st_dev, entry.st_ino))
        if owner is None and database_file:
            owner = _CURRENT.get()
        if owner is None:
            os.close(fd)
        else:
            owner.retired.append(fd)

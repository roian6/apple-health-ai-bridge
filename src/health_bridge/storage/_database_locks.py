import os
import sys
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from typing import Final

import health_bridge.storage._database_lock_files as database_lock_files
from health_bridge.storage._database_lock_files import (
    DatabaseLockPlan,
    open_database_lock_fd,
    open_lock_file_fd,
    prepare_darwin_stable_lock,
    require_darwin_lock_identities,
    require_path_identity,
)

DATABASE_LIFECYCLE_LOCK_SUFFIX: Final = ".lifecycle.lock"
DATABASE_ACCESS_LOCK_SUFFIX: Final = ".access.lock"


@contextmanager
def database_lifecycle_lock(
    db_path: Path,
    *,
    exclusive: bool,
    create: bool,
    nonblocking: bool = False,
) -> Generator[None, None, None]:
    with _database_file_lock(
        db_path,
        DatabaseLockPlan(
            suffix=DATABASE_LIFECYCLE_LOCK_SUFFIX,
            exclusive=exclusive,
            create=create,
            nonblocking=nonblocking,
            lock_database=False,
            optional_lock_file=False,
        ),
    ):
        yield


@contextmanager
def database_access_lock(
    db_path: Path,
    *,
    exclusive: bool,
    create: bool,
    nonblocking: bool = False,
) -> Generator[None, None, None]:
    with _database_file_lock(
        db_path,
        DatabaseLockPlan(
            suffix=DATABASE_ACCESS_LOCK_SUFFIX,
            exclusive=exclusive,
            create=create,
            nonblocking=nonblocking,
            lock_database=True,
            optional_lock_file=not create,
        ),
    ):
        yield


@contextmanager
def _database_file_lock(
    db_path: Path,
    plan: DatabaseLockPlan,
) -> Generator[None, None, None]:
    if os.name != "posix":
        message = "database file locking is unavailable on this platform"
        raise OSError(message)
    if not hasattr(os, "O_NOFOLLOW"):
        message = "database file locking requires O_NOFOLLOW"
        raise OSError(message)
    stable_lock = prepare_darwin_stable_lock(db_path, plan)
    stable_lock_path = stable_lock.path if stable_lock is not None else db_path
    stable_lock_fd = stable_lock.fd if stable_lock is not None else None
    try:
        with _held_path_flock(
            stable_lock_fd,
            stable_lock_path,
            exclusive=plan.exclusive,
            nonblocking=plan.nonblocking,
        ):
            if stable_lock is not None:
                require_darwin_lock_identities(db_path, stable_lock)
            lock_path = Path(f"{db_path}{plan.suffix}")
            lock_fd = open_lock_file_fd(lock_path, plan)
            try:
                with _held_path_flock(
                    lock_fd,
                    lock_path,
                    exclusive=plan.exclusive,
                    nonblocking=plan.nonblocking,
                ):
                    database_fd = (
                        open_database_lock_fd(db_path, create=plan.create)
                        if plan.lock_database and sys.platform != "darwin"
                        else None
                    )
                    try:
                        with _held_path_flock(
                            database_fd,
                            db_path,
                            exclusive=plan.exclusive,
                            nonblocking=plan.nonblocking,
                        ):
                            yield
                    finally:
                        if database_fd is not None:
                            os.close(database_fd)
            finally:
                if lock_fd is not None:
                    os.close(lock_fd)
    finally:
        if stable_lock is not None:
            os.close(stable_lock.fd)


@contextmanager
def _held_path_flock(
    fd: int | None,
    path: Path,
    *,
    exclusive: bool,
    nonblocking: bool,
) -> Generator[None, None, None]:
    if fd is None:
        yield
        return
    opened_stat = os.fstat(fd)
    require_path_identity(path, opened_stat)
    database_lock_files.flock(
        fd,
        exclusive=exclusive,
        nonblocking=nonblocking,
    )
    try:
        require_path_identity(path, opened_stat)
        yield
    finally:
        database_lock_files.flock_unlock(fd)

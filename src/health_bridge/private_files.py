import os
import stat
import tempfile
from pathlib import Path
from typing import Final, Never

PRIVATE_FILE_MODE: Final = 0o600
PRIVATE_DIRECTORY_MODE: Final = 0o700


def apply_private_file_mode(fd: int, path: Path) -> None:
    """Set owner-only permissions for an opened private file."""
    fchmod = getattr(os, "fchmod", None)
    if fchmod is not None:
        fchmod(fd, PRIVATE_FILE_MODE)
        return
    path.chmod(PRIVATE_FILE_MODE)


def _raise_symlink_error(path: Path) -> Never:
    msg = f"refusing to use private path through symlink: {path}"
    raise OSError(msg)


def _raise_path_changed(path: Path) -> Never:
    msg = f"private file path changed during open: {path}"
    raise OSError(msg)


def _missing_directory_chain(path: Path) -> tuple[Path, list[str]]:
    missing: list[str] = []
    current = path
    while not current.exists():
        if current.is_symlink():
            _raise_symlink_error(current)
        missing.append(current.name)
        parent = current.parent
        if parent == current:
            break
        current = parent
    if current.is_symlink():
        _raise_symlink_error(current)
    return current, list(reversed(missing))


def _create_private_directory_chain_posix(parent: Path, names: list[str]) -> None:
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    directory_fd = os.open(parent, directory_flags)
    try:
        for name in names:
            try:
                os.mkdir(name, PRIVATE_DIRECTORY_MODE, dir_fd=directory_fd)
            except FileExistsError as exc:
                msg = f"private directory path changed while creating: {name}"
                raise OSError(msg) from exc
            child_fd = os.open(name, directory_flags, dir_fd=directory_fd)
            try:
                os.fchmod(child_fd, PRIVATE_DIRECTORY_MODE)
            except OSError:
                os.close(child_fd)
                raise
            os.close(directory_fd)
            directory_fd = child_fd
    finally:
        os.close(directory_fd)


def ensure_private_directory(path: Path) -> None:
    """Create missing directory components with owner-only permissions.

    Existing parent directories are left unchanged because callers may place a
    database beneath a shared mount or another directory they do not own. POSIX
    creation uses directory descriptors and refuses symlink redirection. On
    Windows, inherited directory ACLs remain the authoritative access control.
    """
    if path.exists():
        if path.is_symlink():
            _raise_symlink_error(path)
        if not path.is_dir():
            msg = f"private directory path is not a directory: {path}"
            raise NotADirectoryError(msg)
        return

    existing_parent, missing_names = _missing_directory_chain(path)
    _assert_private_parent(existing_parent)
    if os.name == "posix":
        _create_private_directory_chain_posix(existing_parent, missing_names)
        return

    path.mkdir(parents=True, exist_ok=False)
    current = existing_parent
    for name in missing_names:
        current = current / name
        current.chmod(PRIVATE_DIRECTORY_MODE)


def require_private_parent(path: Path) -> None:
    """Validate an existing private-file parent chain without mutating it."""
    if path.is_symlink():
        _raise_symlink_error(path)
    if not path.is_dir():
        msg = f"private file parent is not a directory: {path}"
        raise NotADirectoryError(msg)
    _assert_private_parent(path)


def _assert_private_parent(path: Path) -> None:
    if os.name != "posix":
        return
    checked: set[tuple[int, int]] = set()
    for root in (path, path.resolve(strict=True)):
        current = root
        while True:
            entry = current.lstat()
            if stat.S_ISLNK(entry.st_mode) and entry.st_uid != 0:
                _raise_symlink_error(current)
            result = current.stat()
            identity = (result.st_dev, result.st_ino)
            if identity not in checked:
                checked.add(identity)
                writable_by_others = bool(result.st_mode & 0o022)
                sticky_directory = bool(result.st_mode & stat.S_ISVTX)
                trusted_sticky = sticky_directory and result.st_uid in {
                    0,
                    os.geteuid(),
                }
                if writable_by_others and not trusted_sticky:
                    msg = (
                        "private file parent must not be group/other writable: "
                        f"{current}"
                    )
                    raise PermissionError(msg)
            parent = current.parent
            if parent == current:
                break
            current = parent


def _private_open_flags(*, writable: bool) -> int:
    access = os.O_RDWR if writable else os.O_RDONLY
    return access | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)


def _open_existing_private_file(path: Path, *, writable: bool) -> int:
    initial = path.lstat()
    if stat.S_ISLNK(initial.st_mode):
        _raise_symlink_error(path)
    if not stat.S_ISREG(initial.st_mode):
        msg = f"private file path is not a regular file: {path}"
        raise OSError(msg)
    fd = os.open(path, _private_open_flags(writable=writable))
    try:
        opened = os.fstat(fd)
        current = path.lstat()
        initial_identity = (initial.st_dev, initial.st_ino)
        opened_identity = (opened.st_dev, opened.st_ino)
        current_identity = (current.st_dev, current.st_ino)
        if not (initial_identity == opened_identity == current_identity):
            _raise_path_changed(path)
    except OSError:
        os.close(fd)
        raise
    return fd


def _open_or_create_private_file(path: Path) -> int:
    try:
        return _open_existing_private_file(path, writable=True)
    except FileNotFoundError:
        flags = _private_open_flags(writable=True) | os.O_CREAT | os.O_EXCL
        try:
            fd = os.open(path, flags, PRIVATE_FILE_MODE)
        except FileExistsError as exc:
            msg = f"private file path changed during open: {path}"
            raise OSError(msg) from exc
        try:
            opened = os.fstat(fd)
            current = path.lstat()
        except OSError:
            os.close(fd)
            raise
        if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
            try:
                _raise_path_changed(path)
            finally:
                os.close(fd)
        return fd


def repair_private_file_mode(path: Path) -> None:
    """Repair an existing private file without following its final symlink."""
    fd = _open_existing_private_file(path, writable=False)
    try:
        apply_private_file_mode(fd, path)
    finally:
        os.close(fd)


def ensure_private_file(path: Path) -> tuple[int, int]:
    """Create or repair a private file and return its device/inode identity.

    POSIX systems receive mode 0600. Windows keeps its inherited ACL because
    POSIX mode bits do not represent Windows access-control semantics.
    """
    ensure_private_directory(path.parent)
    _assert_private_parent(path.parent)
    fd = _open_or_create_private_file(path)
    try:
        apply_private_file_mode(fd, path)
        result = os.fstat(fd)
        return result.st_dev, result.st_ino
    finally:
        os.close(fd)


def write_private_text_file(path: Path, content: str) -> None:
    """Atomically write secret-bearing text with owner-only permissions.

    The final file is created or replaced with mode 0600 regardless of process
    umask. Existing files are not truncated until a complete private temp file
    has been written and fsynced. Symlink destinations are rejected so setup
    pages and token files cannot accidentally overwrite or expose another path.
    """
    ensure_private_directory(path.parent)
    _assert_private_parent(path.parent)
    if path.is_symlink():
        msg = f"refusing to write private file through symlink: {path}"
        raise OSError(msg)

    fd = -1
    temp_path: Path | None = None
    try:
        fd, temp_name = tempfile.mkstemp(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            text=True,
        )
        temp_path = Path(temp_name)
        apply_private_file_mode(fd, temp_path)
        with os.fdopen(fd, "w", encoding="utf-8") as private_file:
            fd = -1
            _ = private_file.write(content)
            private_file.flush()
            os.fsync(private_file.fileno())
        _ = temp_path.replace(path)
        temp_path = None
        path.chmod(PRIVATE_FILE_MODE)
    finally:
        if fd >= 0:
            os.close(fd)
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)

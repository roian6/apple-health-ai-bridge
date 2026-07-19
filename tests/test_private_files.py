import os
import stat
from pathlib import Path

import pytest

from health_bridge.private_files import (
    ensure_private_directory,
    ensure_private_file,
    write_private_text_file,
)


def test_write_private_text_file_uses_owner_only_permissions(tmp_path: Path) -> None:
    # Given
    private_path = tmp_path / "setup.html"

    # When
    write_private_text_file(private_path, "secret setup page")

    # Then
    assert private_path.read_text(encoding="utf-8") == "secret setup page"
    assert stat.S_IMODE(private_path.stat().st_mode) == 0o600


def test_write_private_text_file_falls_back_when_fchmod_is_unavailable(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    private_path = tmp_path / "setup.html"
    monkeypatch.delattr(os, "fchmod")

    # When
    write_private_text_file(private_path, "secret setup page")

    # Then
    assert private_path.read_text(encoding="utf-8") == "secret setup page"
    assert stat.S_IMODE(private_path.stat().st_mode) == 0o600


def test_ensure_private_file_detects_symlink_swap_without_no_follow(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    target_path = tmp_path / "target.sqlite"
    _ = target_path.write_bytes(b"synthetic")
    private_path = tmp_path / "private.sqlite"
    real_open = os.open
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    swapped = False

    def swapping_open(path: Path, flags: int, mode: int = 0o777) -> int:
        nonlocal swapped
        if path == private_path and not swapped:
            swapped = True
            private_path.symlink_to(target_path)
            flags &= ~no_follow
        return real_open(path, flags, mode)

    monkeypatch.setattr(os, "open", swapping_open)

    # When / Then
    with pytest.raises(OSError, match="changed during open"):
        _ = ensure_private_file(private_path)


def test_ensure_private_file_detects_existing_regular_file_swap(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    private_path = tmp_path / "private.sqlite"
    _ = private_path.write_bytes(b"original")
    replacement_path = tmp_path / "replacement.sqlite"
    _ = replacement_path.write_bytes(b"replacement")
    real_open = os.open
    swapped = False

    def swapping_open(path: Path, flags: int, mode: int = 0o777) -> int:
        nonlocal swapped
        if path == private_path and not swapped:
            swapped = True
            private_path.unlink()
            _ = replacement_path.replace(private_path)
        return real_open(path, flags, mode)

    monkeypatch.setattr(os, "open", swapping_open)

    # When / Then
    with pytest.raises(OSError, match="changed during open"):
        _ = ensure_private_file(private_path)


def test_ensure_private_file_closes_fd_when_path_disappears_after_open(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    private_path = tmp_path / "private.sqlite"
    _ = private_path.write_bytes(b"synthetic")
    real_open = os.open
    real_lstat = Path.lstat
    opened_fds: list[int] = []
    lstat_calls = 0

    def recording_open(path: Path, flags: int, mode: int = 0o777) -> int:
        fd = real_open(path, flags, mode)
        if path == private_path:
            opened_fds.append(fd)
        return fd

    def disappearing_lstat(path: Path) -> os.stat_result:
        nonlocal lstat_calls
        if path == private_path:
            lstat_calls += 1
            if lstat_calls == 2:
                raise FileNotFoundError(private_path)
        return real_lstat(path)

    monkeypatch.setattr(os, "open", recording_open)
    monkeypatch.setattr(Path, "lstat", disappearing_lstat)

    # When
    with pytest.raises(OSError, match="changed during open"):
        _ = ensure_private_file(private_path)

    # Then
    assert len(opened_fds) == 1
    with pytest.raises(OSError, match="Bad file descriptor"):
        _ = os.fstat(opened_fds[0])


def test_ensure_private_directory_closes_child_fd_when_fchmod_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    private_directory = tmp_path / "private"
    real_open = os.open
    opened_fds: list[int] = []

    def recording_open(
        path: Path | str,
        flags: int,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> int:
        fd = real_open(path, flags, mode, dir_fd=dir_fd)
        opened_fds.append(fd)
        return fd

    def failing_fchmod(_fd: int, _mode: int) -> None:
        message = "synthetic fchmod failure"
        raise OSError(message)

    monkeypatch.setattr(os, "open", recording_open)
    monkeypatch.setattr(os, "fchmod", failing_fchmod)

    # When
    with pytest.raises(OSError, match="synthetic fchmod failure"):
        ensure_private_directory(private_directory)

    # Then
    assert len(opened_fds) == 2
    for fd in opened_fds:
        with pytest.raises(OSError, match="Bad file descriptor"):
            _ = os.fstat(fd)


def test_ensure_private_file_closes_new_fd_when_fstat_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    private_path = tmp_path / "private.sqlite"
    real_open = os.open
    opened_fds: list[int] = []

    def recording_open(path: Path, flags: int, mode: int = 0o777) -> int:
        fd = real_open(path, flags, mode)
        if path == private_path:
            opened_fds.append(fd)
        return fd

    def failing_fstat(_fd: int) -> os.stat_result:
        message = "synthetic fstat failure"
        raise OSError(message)

    monkeypatch.setattr(os, "open", recording_open)
    monkeypatch.setattr(os, "fstat", failing_fstat)

    # When
    with pytest.raises(OSError, match="synthetic fstat failure"):
        _ = ensure_private_file(private_path)

    # Then
    assert len(opened_fds) == 1
    with pytest.raises(OSError, match="Bad file descriptor"):
        os.close(opened_fds[0])

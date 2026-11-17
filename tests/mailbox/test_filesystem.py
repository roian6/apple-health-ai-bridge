from __future__ import annotations

import errno
import os
from typing import TYPE_CHECKING, Literal, assert_never

import pytest

from health_bridge.mailbox.filesystem import (
    FileSnapshot,
    MailboxFileError,
    MailboxFileErrorCode,
    read_final,
    read_final_at,
)

if TYPE_CHECKING:
    from pathlib import Path


def _read_snapshot(path: Path, *, relative: bool) -> FileSnapshot:
    if not relative:
        return read_final(path, maximum_bytes=128)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        return read_final_at(descriptor, path.name, maximum_bytes=128)
    finally:
        os.close(descriptor)


@pytest.mark.parametrize("relative", [False, True])
def test_final_read_accepts_stable_bytes(tmp_path: Path, relative: bool) -> None:
    path = tmp_path / "synthetic.hbp"
    _ = path.write_bytes(b"synthetic")

    snapshot = _read_snapshot(path, relative=relative)

    assert snapshot.content == b"synthetic"
    assert snapshot.identity.inode == path.stat().st_ino


@pytest.mark.parametrize("relative", [False, True])
@pytest.mark.parametrize("mutation", ["replace", "mtime", "ctime"])
def test_final_read_rejects_identity_changes_during_read(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    relative: bool,
    mutation: Literal["replace", "mtime", "ctime"],
) -> None:
    path = tmp_path / "synthetic.hbp"
    _ = path.write_bytes(b"synthetic")
    original_read = os.read
    changed = False

    def read_and_mutate(descriptor: int, size: int) -> bytes:
        nonlocal changed
        chunk = original_read(descriptor, size)
        if chunk and not changed:
            before = path.stat()
            changed = True
            match mutation:
                case "replace":
                    replacement = tmp_path / "replacement"
                    _ = replacement.write_bytes(b"synthetic")
                    _ = replacement.replace(path)
                    assert path.stat().st_ino != before.st_ino
                    return chunk
                case "mtime":
                    os.utime(
                        path, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000)
                    )
                    assert path.stat().st_mtime_ns != before.st_mtime_ns
                    return chunk
                case "ctime":
                    path.chmod(0o400)
                    after = path.stat()
                    assert after.st_mtime_ns == before.st_mtime_ns
                    assert after.st_ctime_ns != before.st_ctime_ns
                    return chunk
            assert_never(mutation)
        return chunk

    monkeypatch.setattr(os, "read", read_and_mutate)

    with pytest.raises(MailboxFileError) as raised:
        _ = _read_snapshot(path, relative=relative)

    assert changed
    assert raised.value.code is MailboxFileErrorCode.PATH_REPLACED


@pytest.mark.parametrize("relative", [False, True])
def test_final_read_rejects_replacement_between_stat_and_open(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, relative: bool
) -> None:
    path = tmp_path / "synthetic.hbp"
    _ = path.write_bytes(b"synthetic")
    replacement = tmp_path / "replacement"
    _ = replacement.write_bytes(b"synthetic")
    original_open = os.open

    def open_after_replacement(
        name: str | bytes | os.PathLike[str] | os.PathLike[bytes],
        flags: int,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> int:
        if name == path.name:
            _ = replacement.replace(path)
        return original_open(name, flags, mode, dir_fd=dir_fd)

    monkeypatch.setattr(os, "open", open_after_replacement)

    with pytest.raises(MailboxFileError) as raised:
        _ = _read_snapshot(path, relative=relative)

    assert raised.value.code is MailboxFileErrorCode.PATH_REPLACED


@pytest.mark.parametrize("relative", [False, True])
def test_final_read_propagates_dataless_read_error_and_closes_descriptor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, relative: bool
) -> None:
    path = tmp_path / "synthetic.hbp"
    _ = path.write_bytes(b"synthetic")
    descriptors: list[int] = []

    def denied_read(descriptor: int, _size: int) -> bytes:
        descriptors.append(descriptor)
        raise OSError(errno.EDEADLK, "synthetic dataless read denial")

    monkeypatch.setattr(os, "read", denied_read)

    with pytest.raises(OSError, match="synthetic dataless read denial") as raised:
        _ = _read_snapshot(path, relative=relative)

    assert raised.value.errno == errno.EDEADLK
    assert len(descriptors) == 1
    with pytest.raises(OSError, match="Bad file descriptor") as closed:
        _ = os.fstat(descriptors[0])
    assert closed.value.errno == errno.EBADF
    assert path.stat().st_size == len(b"synthetic")

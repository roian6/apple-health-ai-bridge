import os
import stat
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event, current_thread
from typing import Literal, assert_never

import pytest

from health_bridge.storage.database import connect_database, initialize_database
from health_bridge.storage.sqlite_rows import fetch_one_int


def _place_sidecar(
    kind: Literal["absent", "regular", "symlink", "hardlink", "fifo"],
    sidecar: Path,
    target: Path,
) -> bool:
    match kind:
        case "absent":
            return False
        case "regular":
            _ = sidecar.write_bytes(b"synthetic replacement")
            return True
        case "symlink":
            sidecar.symlink_to(target)
            return True
        case "hardlink":
            sidecar.hardlink_to(target)
            return True
        case "fifo":
            os.mkfifo(sidecar, 0o600)
            return True
    assert_never(kind)


@pytest.mark.parametrize("replacement", ["absent", "regular", "symlink", "hardlink"])
def test_real_commit_can_remove_opened_journal_but_cannot_replace_it(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    replacement: Literal["absent", "regular", "symlink", "hardlink"],
) -> None:
    db = tmp_path / "synthetic.sqlite"
    initialize_database(db)
    with connect_database(db) as connection:
        _ = connection.execute("create table synthetic_race (value integer)")
    journal = Path(f"{db}-journal")
    target = tmp_path / "synthetic-target"
    _ = target.write_bytes(b"synthetic unchanged target")
    target.chmod(0o640)
    opened, resume, descriptors, real_open = Event(), Event(), list[int](), os.open

    def pause_after_open(
        path: str | bytes | os.PathLike[str] | os.PathLike[bytes],
        flags: int,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> int:
        fd = real_open(path, flags, mode, dir_fd=dir_fd)
        if path == journal and current_thread().name.startswith("journal-race"):
            descriptors.append(fd)
            opened.set()
            assert resume.wait(10), "Reader did not reach the real journal-open barrier"
        return fd

    def reader() -> int:
        with connect_database(db) as connection:
            return fetch_one_int(connection, "select count(*) from synthetic_race")

    with connect_database(db) as writer:
        _ = writer.execute("insert into synthetic_race values (1)")
        assert journal.is_file()
        with monkeypatch.context() as patch:
            patch.setattr(os, "open", pause_after_open)
            with ThreadPoolExecutor(
                max_workers=1, thread_name_prefix="journal-race"
            ) as pool:
                future = pool.submit(reader)
                replacement_created = False
                try:
                    assert opened.wait(10), (
                        "Actual product sidecar open was not reached"
                    )
                    entry = os.fstat(descriptors[0])
                    assert stat.S_ISREG(entry.st_mode)
                    assert entry.st_nlink == 1
                    writer.commit()
                    assert not journal.exists()
                    assert os.fstat(descriptors[0]).st_nlink == 0
                    assert (
                        fetch_one_int(writer, "select count(*) from synthetic_race")
                        == 1
                    )
                    replacement_created = _place_sidecar(replacement, journal, target)
                    resume.set()
                    if replacement == "absent":
                        assert future.result(timeout=15) == 1
                    else:
                        with pytest.raises(
                            OSError, match=r"invalid database file|changed"
                        ):
                            _ = future.result(timeout=15)
                        assert target.read_bytes() == b"synthetic unchanged target"
                        assert stat.S_IMODE(target.stat().st_mode) == 0o640
                finally:
                    resume.set()
                    if replacement_created:
                        journal.unlink()
    with connect_database(db) as connection:
        assert fetch_one_int(connection, "select count(*) from synthetic_race") == 1


@pytest.mark.parametrize("kind", ["symlink", "hardlink", "fifo"])
def test_present_invalid_sidecar_is_not_treated_as_vanished(
    tmp_path: Path, kind: Literal["symlink", "hardlink", "fifo"]
) -> None:
    db = tmp_path / "synthetic.sqlite"
    initialize_database(db)
    target = tmp_path / "synthetic-target"
    _ = target.write_bytes(b"synthetic unchanged target")
    target.chmod(0o640)
    sidecar = Path(f"{db}-journal")
    assert _place_sidecar(kind, sidecar, target)
    with (
        pytest.raises(OSError, match=r"invalid database file|symbolic links"),
        connect_database(db),
    ):
        pytest.fail("An invalid present sidecar was admitted")
    assert target.read_bytes() == b"synthetic unchanged target"
    assert stat.S_IMODE(target.stat().st_mode) == 0o640


@pytest.mark.parametrize("role", ["database", "control"])
def test_unlinked_main_database_and_control_lock_remain_refused(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    role: Literal["database", "control"],
) -> None:
    db = tmp_path / "synthetic.sqlite"
    initialize_database(db)
    target = db if role == "database" else Path(f"{db}.access.lock")
    real_open = os.open
    removed = False

    def unlink_after_open(
        path: str | bytes | os.PathLike[str] | os.PathLike[bytes],
        flags: int,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> int:
        nonlocal removed
        fd = real_open(path, flags, mode, dir_fd=dir_fd)
        if path == target and not removed:
            assert os.fstat(fd).st_nlink == 1
            target.unlink()
            assert os.fstat(fd).st_nlink == 0
            removed = True
        return fd

    monkeypatch.setattr(os, "open", unlink_after_open)
    with (
        pytest.raises(OSError, match=r"invalid database (?:lock )?file"),
        connect_database(db),
    ):
        pytest.fail("A required unlinked file was admitted")
    assert removed

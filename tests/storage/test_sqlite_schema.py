import os
import shutil
import sqlite3
import stat
import sys
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
from typing import TYPE_CHECKING, cast

import pytest

import health_bridge.storage.database as database_module
from health_bridge.storage import initialize_database
from health_bridge.storage.database import (
    connect_database,
    connect_readonly_database,
    database_access_lock,
)
from health_bridge.storage.sqlite_rows import fetch_one_int, fetch_text_rows

if TYPE_CHECKING:
    from collections.abc import Callable

SLEEP_TOMBSTONES_QUERY = """
select client_record_id, deleted_at
from deleted_records
where record_family = ?
"""

POSIX_PERMISSION_TEST = pytest.mark.skipif(
    os.name != "posix",
    reason="POSIX mode bits do not represent Windows ACL semantics",
)

EXPECTED_TABLES = {
    "schema_migrations",
    "sync_runs",
    "sources",
    "health_types",
    "health_type_aliases",
    "samples",
    "workouts",
    "sleep_sessions",
    "sleep_stage_intervals",
    "deleted_records",
    "sync_cursors",
    "receiver_tokens",
    "pairing_invitations",
    "receiver_devices",
    "receiver_token_devices",
    "pairing_invitation_redemptions",
    "sleep_baseline_namespaces",
}


@POSIX_PERMISSION_TEST
def test_database_lock_rejects_hard_link_without_changing_target_mode(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    target = tmp_path / "unrelated.txt"
    _ = target.write_text("keep", encoding="utf-8")
    target.chmod(0o644)
    lifecycle_lock = Path(f"{db_path}.lifecycle.lock")
    os.link(target, lifecycle_lock)

    with (
        pytest.raises(OSError, match="invalid database lock file"),
        connect_database(db_path),
    ):
        pass

    assert stat.S_IMODE(target.stat().st_mode) == 0o644
    assert target.read_text(encoding="utf-8") == "keep"


@POSIX_PERMISSION_TEST
def test_database_lock_rejects_existing_insecure_mode_without_repair(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    lifecycle_lock = Path(f"{db_path}.lifecycle.lock")
    _ = lifecycle_lock.write_bytes(b"")
    lifecycle_lock.chmod(0o666)

    with (
        pytest.raises(OSError, match="permissions are not private"),
        connect_database(db_path),
    ):
        pass

    assert stat.S_IMODE(lifecycle_lock.stat().st_mode) == 0o666


@POSIX_PERMISSION_TEST
def test_database_lock_fails_closed_without_no_follow(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    monkeypatch.delattr(os, "O_NOFOLLOW")

    with (
        pytest.raises(OSError, match="requires O_NOFOLLOW"),
        connect_database(db_path),
    ):
        pass


@POSIX_PERMISSION_TEST
def test_access_lock_replacement_cannot_bypass_database_inode_lock(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    initialize_database(db_path)
    access_lock = Path(f"{db_path}.access.lock")
    displaced_lock = tmp_path / "displaced-access.lock"

    with database_access_lock(
        db_path,
        exclusive=True,
        create=False,
    ):
        _ = access_lock.rename(displaced_lock)
        _ = access_lock.write_bytes(b"")
        access_lock.chmod(0o600)

        with (
            pytest.raises(BlockingIOError),
            database_access_lock(
                db_path,
                exclusive=False,
                create=False,
                nonblocking=True,
            ),
        ):
            pass


@POSIX_PERMISSION_TEST
def test_access_lock_replacement_cannot_bypass_darwin_stable_lock(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    initialize_database(db_path)
    access_lock = Path(f"{db_path}.access.lock")
    displaced_lock = tmp_path / "displaced-darwin-access.lock"
    monkeypatch.setattr(sys, "platform", "darwin")

    with database_access_lock(
        db_path,
        exclusive=True,
        create=False,
    ):
        _ = access_lock.rename(displaced_lock)
        _ = access_lock.write_bytes(b"")
        access_lock.chmod(0o600)

        with (
            pytest.raises(BlockingIOError),
            database_access_lock(
                db_path,
                exclusive=False,
                create=False,
                nonblocking=True,
            ),
        ):
            pass


@POSIX_PERMISSION_TEST
def test_parent_replacement_cannot_bypass_darwin_stable_lock(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    database_directory = tmp_path / "database"
    database_directory.mkdir(mode=0o700)
    db_path = database_directory / "receiver.sqlite"
    initialize_database(db_path)
    displaced_directory = tmp_path / "displaced-database"
    stable_lock_path = tmp_path / "stable-locks" / "receiver.lock"

    def stable_lock_for_test(_db_path: Path) -> Path:
        return stable_lock_path

    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(
        database_module,
        "_stable_database_lock_path",
        stable_lock_for_test,
    )

    with database_access_lock(
        db_path,
        exclusive=True,
        create=False,
    ):
        _ = database_directory.rename(displaced_directory)
        database_directory.mkdir(mode=0o700)
        _ = shutil.copy2(displaced_directory / db_path.name, db_path)
        db_path.chmod(0o600)
        replacement_access_lock = Path(f"{db_path}.access.lock")
        _ = replacement_access_lock.write_bytes(b"")
        replacement_access_lock.chmod(0o600)

        with (
            pytest.raises(BlockingIOError),
            database_access_lock(
                db_path,
                exclusive=False,
                create=False,
                nonblocking=True,
            ),
        ):
            pass


@POSIX_PERMISSION_TEST
def test_darwin_stable_lock_namespace_is_global_per_user(tmp_path: Path) -> None:
    first = database_module._stable_database_lock_path(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
        tmp_path / "first.sqlite"
    )
    second = database_module._stable_database_lock_path(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
        tmp_path / "unrelated" / "second.sqlite"
    )

    assert first == second


@POSIX_PERMISSION_TEST
def test_darwin_stable_lock_root_is_repaired_to_owner_only(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    lock_root = tmp_path / "stable-lock-root"
    lock_root.mkdir(mode=0o700)
    lock_root.chmod(0o777)

    def stable_root_for_test() -> Path:
        return lock_root

    monkeypatch.setattr(
        database_module,
        "_darwin_stable_lock_root",
        stable_root_for_test,
    )
    lock_path, lock_fd = database_module._open_stable_database_lock_fd(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
        tmp_path / "receiver.sqlite"
    )
    os.close(lock_fd)

    assert lock_path.parent == lock_root
    assert stat.S_IMODE(lock_root.stat().st_mode) == 0o700
    assert lock_root.stat().st_uid == os.getuid()


@POSIX_PERMISSION_TEST
def test_equivalent_path_alias_cannot_bypass_darwin_stable_lock(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    initialize_database(db_path)
    alias_component = tmp_path / "alias-component"
    alias_component.mkdir(mode=0o700)
    alias_path = alias_component / ".." / db_path.name
    access_lock = Path(f"{db_path}.access.lock")
    displaced_lock = tmp_path / "displaced-alias-access.lock"
    monkeypatch.setattr(sys, "platform", "darwin")

    assert database_module._stable_database_lock_path(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
        db_path
    ) == database_module._stable_database_lock_path(alias_path)  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001

    with database_access_lock(
        db_path,
        exclusive=True,
        create=False,
    ):
        _ = access_lock.rename(displaced_lock)
        _ = access_lock.write_bytes(b"")
        access_lock.chmod(0o600)

        with (
            pytest.raises(BlockingIOError),
            database_access_lock(
                alias_path,
                exclusive=False,
                create=False,
                nonblocking=True,
            ),
        ):
            pass


@pytest.mark.skipif(
    sys.platform != "darwin",
    reason="requires default macOS path aliases",
)
def test_case_and_unicode_aliases_cannot_bypass_darwin_stable_lock(
    tmp_path: Path,
) -> None:
    canonical_directory = tmp_path / "CaseCafé"
    canonical_directory.mkdir(mode=0o700)
    db_path = canonical_directory / "receiver.sqlite"
    initialize_database(db_path)
    aliases = (
        tmp_path / "casecafé" / db_path.name,
        tmp_path
        / unicodedata.normalize("NFD", canonical_directory.name)
        / db_path.name,
    )
    if not all(alias.exists() for alias in aliases):
        pytest.skip("test volume is case- or normalization-sensitive")
    access_lock = Path(f"{db_path}.access.lock")
    displaced_lock = tmp_path / "displaced-case-unicode-access.lock"

    for alias in aliases:
        assert alias.samefile(db_path)
        assert database_module._stable_database_lock_path(  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
            alias
        ) == database_module._stable_database_lock_path(db_path)  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001

    with database_access_lock(
        db_path,
        exclusive=True,
        create=False,
    ):
        _ = access_lock.rename(displaced_lock)
        _ = access_lock.write_bytes(b"")
        access_lock.chmod(0o600)

        for alias in aliases:
            with (
                pytest.raises(BlockingIOError),
                database_access_lock(
                    alias,
                    exclusive=False,
                    create=False,
                    nonblocking=True,
                ),
            ):
                pass


@POSIX_PERMISSION_TEST
def test_parent_replacement_during_darwin_acquisition_fails_closed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    database_directory = tmp_path / "database"
    database_directory.mkdir(mode=0o700)
    db_path = database_directory / "receiver.sqlite"
    initialize_database(db_path)
    displaced_directory = tmp_path / "displaced-database"
    stable_lock_path = tmp_path / "stable-locks" / "receiver.lock"
    original_open = database_module._open_stable_database_lock_fd  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001

    def stable_lock_for_test(_db_path: Path) -> Path:
        return stable_lock_path

    def replace_parent_before_stable_lock(path: Path) -> tuple[Path, int]:
        _ = database_directory.rename(displaced_directory)
        database_directory.mkdir(mode=0o700)
        _ = shutil.copy2(displaced_directory / db_path.name, db_path)
        db_path.chmod(0o600)
        return original_open(path)

    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(
        database_module,
        "_stable_database_lock_path",
        stable_lock_for_test,
    )
    monkeypatch.setattr(
        database_module,
        "_open_stable_database_lock_fd",
        replace_parent_before_stable_lock,
    )

    with (
        pytest.raises(OSError, match="locked path changed during acquisition"),
        database_access_lock(
            db_path,
            exclusive=True,
            create=False,
        ),
    ):
        pass


@POSIX_PERMISSION_TEST
def test_database_initialization_avoids_inode_flock_on_darwin(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    lifecycle_lock = Path(f"{db_path}.lifecycle.lock")
    access_lock = Path(f"{db_path}.access.lock")
    original_flock = database_module._flock  # pyright: ignore[reportPrivateUsage]  # noqa: SLF001
    locked_paths: set[Path] = set()

    def darwin_flock(
        fd: int,
        *,
        exclusive: bool,
        nonblocking: bool,
    ) -> None:
        opened = os.fstat(fd)
        for path in (lifecycle_lock, access_lock, db_path):
            if not path.exists():
                continue
            current = path.stat(follow_symlinks=False)
            if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
                continue
            locked_paths.add(path)
            if path == db_path:
                error_message = "database is locked"
                raise sqlite3.OperationalError(error_message)
        original_flock(fd, exclusive=exclusive, nonblocking=nonblocking)

    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(database_module, "_flock", darwin_flock)

    initialize_database(db_path)

    assert lifecycle_lock in locked_paths
    assert access_lock in locked_paths
    assert db_path not in locked_paths


@POSIX_PERMISSION_TEST
def test_readonly_upgrade_path_needs_no_lock_files_or_filesystem_mutation(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    initialize_database(db_path)
    Path(f"{db_path}.lifecycle.lock").unlink()
    Path(f"{db_path}.access.lock").unlink()
    before = {path.name for path in tmp_path.iterdir()}

    with connect_readonly_database(db_path) as connection:
        assert connection.execute("select 1").fetchone() == (1,)

    assert {path.name for path in tmp_path.iterdir()} == before


def test_initialize_database_creates_core_tables_when_database_is_empty(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"

    # When
    initialize_database(db_path)

    # Then
    with sqlite3.connect(db_path) as connection:
        table_rows = fetch_text_rows(
            connection,
            "select name from sqlite_master where type = 'table'",
        )
        migration_rows = fetch_text_rows(
            connection,
            "select migration_id from schema_migrations order by migration_id",
        )

    assert {row[0] for row in table_rows} >= EXPECTED_TABLES
    assert migration_rows == [
        ("001_initial",),
        ("002_sync_window",),
        ("003_receiver_tokens",),
        ("004_pairing_invitations",),
        ("005_pairing_devices",),
        ("006_sleep_session_revisions",),
        ("007_sleep_baseline_namespaces",),
    ]


def test_initialize_database_is_idempotent_when_called_twice(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"

    # When
    initialize_database(db_path)
    initialize_database(db_path)

    # Then
    with sqlite3.connect(db_path) as connection:
        migration_count = fetch_one_int(
            connection,
            "select count(*) from schema_migrations",
        )

    assert migration_count == 7


def _create_legacy_sleep_revision_database(db_path: Path) -> None:
    migration_dir = Path("src/health_bridge/storage/migrations")
    legacy_migration_ids = (
        "001_initial",
        "002_sync_window",
        "003_receiver_tokens",
        "004_pairing_invitations",
        "005_pairing_devices",
    )
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute("pragma foreign_keys = on")
        for migration_id in legacy_migration_ids:
            _ = connection.executescript(
                (migration_dir / f"{migration_id}.sql").read_text(encoding="utf-8")
            )
            _ = connection.execute(
                "insert into schema_migrations (migration_id) values (?)",
                (migration_id,),
            )
        _ = connection.execute(
            """
            insert into sources (source_id, source_key, name, kind)
            values (1, ?, ?, ?)
            """,
            ("synthetic.watch", "Synthetic Watch", "watch"),
        )
        _ = connection.executemany(
            """
            insert into sleep_sessions
                (sleep_session_id, source_id, client_record_id, start_time, end_time)
            values (?, 1, ?, ?, ?)
            """,
            (
                (
                    1,
                    "synthetic-sleep-partial",
                    "2026-06-04T03:10:00Z",
                    "2026-06-04T07:00:00Z",
                ),
                (
                    2,
                    "synthetic-sleep-complete",
                    "2026-06-04T03:10:00Z",
                    "2026-06-04T10:45:00Z",
                ),
            ),
        )
        _ = connection.executemany(
            """
            insert into sleep_stage_intervals
                (sleep_session_id, stage, start_time, end_time)
            values (?, ?, ?, ?)
            """,
            (
                (1, "core", "2026-06-04T03:10:00Z", "2026-06-04T07:00:00Z"),
                (2, "core", "2026-06-04T03:10:00Z", "2026-06-04T10:45:00Z"),
            ),
        )


def test_sleep_baseline_namespace_migration_backfills_current_reset(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "legacy-sleep-baseline.sqlite"
    _create_legacy_sleep_revision_database(db_path)
    migration_dir = Path("src/health_bridge/storage/migrations")
    with sqlite3.connect(db_path) as connection:
        _ = connection.executescript(
            (migration_dir / "006_sleep_session_revisions.sql").read_text(
                encoding="utf-8"
            )
        )
        _ = connection.execute(
            "insert into schema_migrations (migration_id) values (?)",
            ("006_sleep_session_revisions",),
        )
        _ = connection.execute(
            (
                "insert into sync_cursors "
                "(source_id, cursor_kind, cursor_value) values (?, ?, ?)"
            ),
            (1, "anchored_sleep_baseline_reset", "synthetic-current-namespace"),
        )

    initialize_database(db_path)

    with sqlite3.connect(db_path) as connection:
        namespaces = fetch_text_rows(
            connection,
            "select namespace from sleep_baseline_namespaces",
        )
        authoritative_applied = fetch_one_int(
            connection,
            "select authoritative_applied from sleep_baseline_namespaces",
        )

    assert namespaces == [("synthetic-current-namespace",)]
    assert authoritative_applied == 1


def test_sleep_revision_migration_keeps_longest_same_start_session(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "legacy-sleep-revisions.sqlite"
    _create_legacy_sleep_revision_database(db_path)

    # When
    initialize_database(db_path)

    # Then
    with sqlite3.connect(db_path) as connection:
        session_rows = connection.execute(
            "select client_record_id, end_time from sleep_sessions"
        ).fetchall()
        interval_rows = connection.execute(
            "select sleep_session_id, end_time from sleep_stage_intervals"
        ).fetchall()
        index_rows = connection.execute(
            "select name from sqlite_master where type = 'index' and name = ?",
            ("sleep_sessions_source_start_unique",),
        ).fetchall()
        tombstone_rows = connection.execute(
            SLEEP_TOMBSTONES_QUERY,
            ("sleep_session",),
        ).fetchall()

    assert session_rows == [("synthetic-sleep-complete", "2026-06-04T10:45:00Z")]
    assert interval_rows == [(2, "2026-06-04T10:45:00Z")]
    assert index_rows == [("sleep_sessions_source_start_unique",)]
    assert tombstone_rows == [("synthetic-sleep-partial", "2026-06-04T10:45:00Z")]


def test_sleep_revision_migration_rolls_back_dedupe_when_index_creation_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "failed-sleep-revision-migration.sqlite"
    _create_legacy_sleep_revision_database(db_path)
    real_connect = sqlite3.connect

    def connect_with_denied_index(path: Path) -> sqlite3.Connection:
        connection = real_connect(path)

        def authorizer(
            action: int,
            _arg1: str | None,
            _arg2: str | None,
            _database_name: str | None,
            _trigger_name: str | None,
        ) -> int:
            if action == sqlite3.SQLITE_CREATE_INDEX:
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        _ = connection.set_authorizer(authorizer)
        return connection

    monkeypatch.setattr(sqlite3, "connect", connect_with_denied_index)

    # When / Then
    with pytest.raises(sqlite3.DatabaseError, match="not authorized"):
        initialize_database(db_path)

    with real_connect(db_path) as connection:
        session_count = fetch_one_int(connection, "select count(*) from sleep_sessions")
        migration_count = fetch_one_int(
            connection,
            "select count(*) from schema_migrations where migration_id = ?",
            ("006_sleep_session_revisions",),
        )

    assert session_count == 2
    assert migration_count == 0


def test_pending_migration_is_serialized_and_rechecked_under_write_lock(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "concurrent-sleep-revision-migration.sqlite"
    _create_legacy_sleep_revision_database(db_path)
    worker_count = 6
    prelock_barrier = Barrier(worker_count)
    original_migration_was_applied = cast(
        "Callable[[sqlite3.Connection, str], bool]",
        vars(database_module)["_migration_was_applied"],
    )

    def synchronized_migration_check(
        connection: sqlite3.Connection,
        migration_id: str,
    ) -> bool:
        was_applied = original_migration_was_applied(connection, migration_id)
        if (
            migration_id == "006_sleep_session_revisions"
            and not connection.in_transaction
        ):
            _ = prelock_barrier.wait(timeout=10)
        return was_applied

    monkeypatch.setattr(
        database_module,
        "_migration_was_applied",
        synchronized_migration_check,
    )

    # When
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        futures = [
            executor.submit(initialize_database, db_path) for _ in range(worker_count)
        ]
        for future in futures:
            _ = future.result()

    # Then
    with sqlite3.connect(db_path) as connection:
        migration_count = fetch_one_int(
            connection,
            "select count(*) from schema_migrations where migration_id = ?",
            ("006_sleep_session_revisions",),
        )
        session_count = fetch_one_int(connection, "select count(*) from sleep_sessions")

    assert migration_count == 1
    assert session_count == 1


@POSIX_PERMISSION_TEST
def test_initialize_database_creates_owner_only_database_under_common_umask(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    previous_umask = os.umask(0o022)

    try:
        # When
        initialize_database(db_path)
    finally:
        _ = os.umask(previous_umask)

    # Then
    assert stat.S_IMODE(db_path.stat().st_mode) == 0o600


@POSIX_PERMISSION_TEST
def test_initialize_database_repairs_existing_database_permissions(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute("create table existing_data (value text)")
    db_path.chmod(0o644)

    # When
    initialize_database(db_path)

    # Then
    assert stat.S_IMODE(db_path.stat().st_mode) == 0o600


@POSIX_PERMISSION_TEST
def test_initialize_database_protects_new_parent_directories(tmp_path: Path) -> None:
    # Given
    private_root = tmp_path / "private"
    nested_parent = private_root / "nested"
    db_path = nested_parent / "test.sqlite"
    previous_umask = os.umask(0o022)

    try:
        # When
        initialize_database(db_path)
    finally:
        _ = os.umask(previous_umask)

    # Then
    assert stat.S_IMODE(private_root.stat().st_mode) == 0o700
    assert stat.S_IMODE(nested_parent.stat().st_mode) == 0o700


@POSIX_PERMISSION_TEST
def test_connect_database_rejects_path_swap_before_sqlite_open(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    replacement_path = tmp_path / "replacement.sqlite"
    backup_path = tmp_path / "original.sqlite"
    with sqlite3.connect(db_path) as connection:
        _ = connection.execute("create table original_data (value text)")
    with sqlite3.connect(replacement_path) as connection:
        _ = connection.execute("create table replacement_data (value text)")
    real_connect = sqlite3.connect
    swapped = False

    def swapping_connect(path: Path) -> sqlite3.Connection:
        nonlocal swapped
        if path == db_path and not swapped:
            swapped = True
            _ = db_path.replace(backup_path)
            _ = replacement_path.replace(db_path)
        return real_connect(path)

    monkeypatch.setattr(sqlite3, "connect", swapping_connect)

    # When / Then
    with (
        pytest.raises(OSError, match="changed before SQLite open"),
        connect_database(db_path),
    ):
        pass


@POSIX_PERMISSION_TEST
def test_connect_database_rejects_symlink_database_path(tmp_path: Path) -> None:
    # Given
    target = tmp_path / "target.sqlite"
    with sqlite3.connect(target):
        pass
    symlink = tmp_path / "linked.sqlite"
    symlink.symlink_to(target)

    # When / Then
    with pytest.raises(OSError, match="symlink"), connect_database(symlink):
        pass


@POSIX_PERMISSION_TEST
def test_connect_database_rejects_symlinked_missing_parent(tmp_path: Path) -> None:
    # Given
    shared_parent = tmp_path / "shared"
    shared_parent.mkdir()
    linked_parent = tmp_path / "linked"
    linked_parent.symlink_to(shared_parent, target_is_directory=True)
    db_path = linked_parent / "nested" / "test.sqlite"

    # When / Then
    with pytest.raises(OSError, match="symlink"):
        initialize_database(db_path)
    assert not (shared_parent / "nested").exists()


@POSIX_PERMISSION_TEST
def test_initialize_database_rejects_existing_user_owned_parent_symlink(
    tmp_path: Path,
) -> None:
    # Given
    safe_root = tmp_path / "safe"
    safe_root.mkdir(mode=0o700)
    target_parent = tmp_path / "target" / "nested"
    target_parent.mkdir(parents=True, mode=0o700)
    target_parent.parent.chmod(0o700)
    linked_parent = safe_root / "linked"
    linked_parent.symlink_to(target_parent.parent, target_is_directory=True)
    db_path = linked_parent / "nested" / "test.sqlite"

    # When / Then
    with pytest.raises(OSError, match="symlink"):
        initialize_database(db_path)
    assert not (target_parent / "test.sqlite").exists()


@POSIX_PERMISSION_TEST
def test_initialize_database_rejects_user_symlink_with_writable_target_ancestor(
    tmp_path: Path,
) -> None:
    # Given
    safe_root = tmp_path / "safe"
    safe_root.mkdir(mode=0o700)
    writable_root = tmp_path / "writable"
    writable_root.mkdir()
    writable_root.chmod(0o777)
    target_parent = writable_root / "target" / "nested"
    target_parent.mkdir(parents=True, mode=0o700)
    target_parent.parent.chmod(0o700)
    linked_parent = safe_root / "linked"
    linked_parent.symlink_to(target_parent.parent, target_is_directory=True)
    db_path = linked_parent / "nested" / "test.sqlite"

    # When / Then
    with pytest.raises(OSError, match="symlink"):
        initialize_database(db_path)
    assert not (target_parent / "test.sqlite").exists()


@POSIX_PERMISSION_TEST
def test_initialize_database_rejects_writable_existing_ancestor(
    tmp_path: Path,
) -> None:
    # Given
    shared_ancestor = tmp_path / "shared"
    shared_ancestor.mkdir()
    shared_ancestor.chmod(0o777)
    db_path = shared_ancestor / "private" / "nested" / "test.sqlite"

    # When / Then
    with pytest.raises(PermissionError, match="group/other writable"):
        initialize_database(db_path)
    assert not (shared_ancestor / "private").exists()


@POSIX_PERMISSION_TEST
def test_initialize_database_rejects_group_writable_existing_parent(
    tmp_path: Path,
) -> None:
    # Given
    existing_parent = tmp_path / "shared"
    existing_parent.mkdir(mode=0o770)
    existing_parent.chmod(0o770)
    db_path = existing_parent / "test.sqlite"

    # When / Then
    with pytest.raises(PermissionError, match="group/other writable"):
        initialize_database(db_path)


@POSIX_PERMISSION_TEST
def test_initialize_database_leaves_existing_parent_mode_unchanged(
    tmp_path: Path,
) -> None:
    # Given
    existing_parent = tmp_path / "existing"
    existing_parent.mkdir(mode=0o750)
    db_path = existing_parent / "test.sqlite"

    # When
    initialize_database(db_path)

    # Then
    assert stat.S_IMODE(existing_parent.stat().st_mode) == 0o750


@POSIX_PERMISSION_TEST
def test_connect_database_repairs_existing_wal_sidecar_permissions(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    previous_umask = os.umask(0o022)

    try:
        with sqlite3.connect(db_path) as writer:
            journal_mode = cast(
                "tuple[str]",
                writer.execute("pragma journal_mode = wal").fetchone(),
            )
            assert journal_mode == ("wal",)
            _ = writer.execute("create table private_data (value text)")
            _ = writer.execute(
                "insert into private_data (value) values (?)",
                ("synthetic",),
            )
            writer.commit()
            sidecars = [
                path
                for suffix in ("-wal", "-shm")
                if (path := Path(f"{db_path}{suffix}")).exists()
            ]
            assert sidecars != []
            for path in sidecars:
                path.chmod(0o644)

            # When
            with connect_database(db_path):
                pass

            # Then
            assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in sidecars)
    finally:
        _ = os.umask(previous_umask)


@POSIX_PERMISSION_TEST
def test_connect_database_reapplies_private_mode_after_body_error(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"

    def fail_during_connection() -> None:
        message = "synthetic failure"
        with connect_database(db_path):
            db_path.chmod(0o644)
            raise RuntimeError(message)

    # When
    with pytest.raises(RuntimeError, match="synthetic failure"):
        fail_during_connection()

    # Then
    assert stat.S_IMODE(db_path.stat().st_mode) == 0o600


@POSIX_PERMISSION_TEST
def test_sqlite_wal_sidecars_are_owner_only(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    previous_umask = os.umask(0o022)

    try:
        # When
        with connect_database(db_path) as connection:
            journal_mode = cast(
                "tuple[str]",
                connection.execute("pragma journal_mode = wal").fetchone(),
            )
            assert journal_mode == ("wal",)
            _ = connection.execute("create table private_data (value text)")
            _ = connection.execute(
                "insert into private_data (value) values (?)",
                ("synthetic",),
            )
            connection.commit()
            sidecars = [
                path
                for suffix in ("-wal", "-shm")
                if (path := Path(f"{db_path}{suffix}")).exists()
            ]
            assert sidecars != []
            assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in sidecars)
    finally:
        _ = os.umask(previous_umask)

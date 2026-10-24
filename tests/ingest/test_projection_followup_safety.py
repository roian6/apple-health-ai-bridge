from pathlib import Path
from typing import Final

import pytest
from pydantic import TypeAdapter

from health_bridge.storage import database
from health_bridge.storage.sqlite_rows import fetch_text_rows
from tests.ingest import test_daily_projection_corrections as root

RECORD_ROWS: Final = TypeAdapter(list[tuple[str, str, str]])
FENCE_ROWS: Final = TypeAdapter(list[tuple[str, str]])


def test_existing_projection_state_gains_order_index_without_changing_values(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    db = tmp_path / "existing.sqlite"
    fence_migration = database.MIGRATION_IDS.index("011_daily_projection_fence_order")
    with monkeypatch.context() as patch:
        patch.setattr(
            database, "MIGRATION_IDS", database.MIGRATION_IDS[:fence_migration]
        )
        root.ingest_root_batch(
            db, root.root_batch((root.daily_sample(),), sequence=1, statistics=True)
        )
        root.ingest_root_batch(db, root.root_batch((root.raw_sample(),), sequence=2))
    with database.connect_database(db) as connection:
        assert (
            fetch_text_rows(
                connection,
                """select name from sqlite_master where type='index'
            and name='daily_projection_fence_order'""",
            )
            == []
        )
        before = RECORD_ROWS.validate_python(
            connection.execute(
                """select fingerprint, sequence, status from daily_projection_records
                order by client_record_id"""
            ).fetchall()
        )
        fences = FENCE_ROWS.validate_python(
            connection.execute(
                """select fingerprint, sequence from daily_projection_fences
                order by fingerprint"""
            ).fetchall()
        )
    database.initialize_database(db)
    database.initialize_database(db)
    with database.connect_database(db) as connection:
        assert (
            RECORD_ROWS.validate_python(
                connection.execute(
                    """select fingerprint, sequence, status
                    from daily_projection_records
                    order by client_record_id"""
                ).fetchall()
            )
            == before
        )
        assert (
            FENCE_ROWS.validate_python(
                connection.execute(
                    """select fingerprint, sequence from daily_projection_fences
                    order by fingerprint"""
                ).fetchall()
            )
            == fences
        )
        assert fetch_text_rows(
            connection,
            """select name from sqlite_master where type='index'
            and name='daily_projection_fence_order'""",
        ) == [("daily_projection_fence_order",)]
    assert root.current_total(db) is None
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(0.0),), sequence=3, statistics=True)
    )
    assert root.current_total(db) == 0.0


@pytest.mark.parametrize("sequence", [10, 2**63, 2**64 - 3])
def test_newer_indexed_fence_blocks_old_daily_but_allows_new_actual_zero(
    tmp_path: Path, sequence: int
) -> None:
    db = tmp_path / "order.sqlite"
    root.ingest_root_batch(
        db,
        root.root_batch((root.daily_sample(),), sequence=sequence - 1, statistics=True),
    )
    root.ingest_root_batch(
        db, root.root_batch((root.raw_sample(),), sequence=sequence + 1)
    )
    root.ingest_root_batch(
        db,
        root.root_batch((root.daily_sample(7.0),), sequence=sequence, statistics=True),
    )
    assert root.current_total(db) is None
    root.ingest_root_batch(
        db,
        root.root_batch(
            (root.daily_sample(0.0),), sequence=sequence + 2, statistics=True
        ),
    )
    assert root.current_total(db) == 0.0

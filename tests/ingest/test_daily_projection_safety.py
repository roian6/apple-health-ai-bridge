import json
import sqlite3
from pathlib import Path
from typing import Literal

import pytest

from health_bridge.queries import get_timeseries
from tests.ingest import test_daily_projection_corrections as root
from tests.mcp.committed_read_support import JSON_OBJECT


def _points(db: Path) -> list[tuple[float, str | None]]:
    return [
        (point.value, point.projection_status)
        for point in get_timeseries(
            db,
            ("steps",),
            root.START,
            root.END,
        ).points
    ]


def test_repeated_raw_content_advances_invalidation_before_stale_statistics(
    tmp_path: Path,
) -> None:
    db = tmp_path / "repeated-content.sqlite"
    root.ingest_root_batch(db, root.root_batch((root.raw_sample(),), sequence=1))
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(6.0),), sequence=2, statistics=True)
    )
    root.ingest_root_batch(db, root.root_batch((root.raw_sample(),), sequence=4))
    assert root.current_total(db) is None
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(7.0),), sequence=3, statistics=True)
    )
    assert root.current_total(db) is None
    assert (6.0, "last_known") in _points(db)
    assert all(value != 7.0 for value, _ in _points(db))


def test_repeated_deletion_content_preserves_its_newer_invalidation_order(
    tmp_path: Path,
) -> None:
    db = tmp_path / "repeated-deletion.sqlite"
    root.ingest_root_batch(db, root.root_batch((root.raw_sample(),), sequence=1))
    root.ingest_root_batch(
        db, root.root_batch(deleted=(root.raw_deletion(),), sequence=2)
    )
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(0.0),), sequence=3, statistics=True)
    )
    root.ingest_root_batch(
        db, root.root_batch(deleted=(root.raw_deletion(),), sequence=5)
    )
    assert root.current_total(db) is None
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(8.0),), sequence=4, statistics=True)
    )
    assert root.current_total(db) is None
    assert _points(db) == [(0.0, "last_known")]


@pytest.mark.parametrize("kind", ["raw", "daily"])
def test_identical_unordered_replay_preserves_the_order_fence(
    tmp_path: Path,
    kind: Literal["raw", "daily"],
) -> None:
    db = tmp_path / "safety.sqlite"
    sample = root.raw_sample(6.0) if kind == "raw" else root.daily_sample(6.0)
    root.ingest_root_batch(db, root.root_batch((sample,), sequence=5, statistics=True))
    root.ingest_root_batch(db, root.root_batch((sample,)))
    root.ingest_root_batch(
        db,
        root.root_batch(
            (sample.model_copy(update={"value": 1.0}),), sequence=4, statistics=True
        ),
    )
    assert [value for value, _ in _points(db)] == [6.0]


def test_stale_delete_is_rejected_before_record_or_validity_mutation(
    tmp_path: Path,
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(db, root.root_batch((root.raw_sample(),), sequence=5))
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(),), sequence=6, statistics=True)
    )
    root.ingest_root_batch(
        db, root.root_batch(deleted=(root.raw_deletion(),), sequence=4)
    )
    assert root.current_total(db) == 6.0
    assert sorted(value for value, _ in _points(db)) == [2.0, 6.0]


def test_unseen_older_raw_history_is_retained_without_invalidating_newer_statistics(
    tmp_path: Path,
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(),), sequence=5, statistics=True)
    )
    root.ingest_root_batch(db, root.root_batch((root.raw_sample(),), sequence=2))
    assert root.current_total(db) == 6.0
    assert sorted(value for value, _ in _points(db)) == [2.0, 6.0]


@pytest.mark.parametrize("value", [0.0, 6.0])
def test_actual_reaggregation_restores_only_its_observed_value(
    tmp_path: Path, value: float
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(
        db,
        root.root_batch(
            (root.daily_sample(10.0), root.raw_sample()), sequence=1, statistics=True
        ),
    )
    root.ingest_root_batch(
        db, root.root_batch(deleted=(root.raw_deletion(),), sequence=2)
    )
    assert root.current_total(db) is None
    root.ingest_root_batch(db, root.root_batch(sequence=3, statistics=True))
    assert root.current_total(db) is None
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(value),), sequence=4, statistics=True)
    )
    assert root.current_total(db) == value
    assert _points(db) == [(value, "current")]


def test_incomparable_namespace_cannot_restore_or_overwrite_current_data(
    tmp_path: Path,
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(
        db,
        root.root_batch(
            (root.raw_sample(), root.daily_sample()), sequence=1, statistics=True
        ),
    )
    foreign = root.root_batch((root.raw_sample(1.0),), sequence=20)
    cursor = foreign.sync.cursors[0]
    body = JSON_OBJECT.validate_json(cursor.cursor_value)
    body["namespace"] = "synthetic-incomparable-owner"
    foreign = foreign.model_copy(
        update={
            "sync": foreign.sync.model_copy(
                update={
                    "cursors": (
                        cursor.model_copy(update={"cursor_value": json.dumps(body)}),
                    ),
                }
            )
        }
    )
    root.ingest_root_batch(db, foreign)
    assert root.current_total(db) is None
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(7.0),), sequence=2, statistics=True)
    )
    assert root.current_total(db) is None
    assert any(value == 2.0 for value, _ in _points(db))


def test_equal_order_chunks_do_not_imply_global_record_admission(
    tmp_path: Path,
) -> None:
    db = tmp_path / "safety.sqlite"
    first = root.raw_sample()
    second = first.model_copy(
        update={"client_record_id": "synthetic-second", "value": 3.0}
    )
    root.ingest_root_batch(db, root.root_batch((first,), sequence=1))
    root.ingest_root_batch(db, root.root_batch((second,), sequence=1))
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(),), sequence=3, statistics=True)
    )
    third = first.model_copy(
        update={"client_record_id": "synthetic-third", "value": 4.0}
    )
    root.ingest_root_batch(db, root.root_batch((third,), sequence=1))
    assert root.current_total(db) == 6.0
    assert sorted(value for value, _ in _points(db)) == [2.0, 3.0, 4.0, 6.0]


def test_failed_chunk_rolls_back_order_and_invalidation_then_can_retry(
    tmp_path: Path,
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(
        db,
        root.root_batch(
            (root.raw_sample(), root.daily_sample()), sequence=1, statistics=True
        ),
    )
    changed = root.raw_sample(4.0)
    invalid = root.daily_sample(1.0).model_copy(
        update={"source_key": "synthetic.absent"}
    )
    with pytest.raises(sqlite3.IntegrityError):
        root.ingest_root_batch(db, root.root_batch((changed, invalid), sequence=2))
    assert root.current_total(db) == 6.0
    assert sorted(value for value, _ in _points(db)) == [2.0, 6.0]
    root.ingest_root_batch(db, root.root_batch((changed,), sequence=2))
    assert root.current_total(db) is None


def test_tombstoned_raw_replay_cannot_resurrect_or_invalidate_recollection(
    tmp_path: Path,
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(
        db,
        root.root_batch(
            (root.raw_sample(), root.daily_sample()), sequence=1, statistics=True
        ),
    )
    root.ingest_root_batch(
        db, root.root_batch(deleted=(root.raw_deletion(),), sequence=2)
    )
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(0.0),), sequence=3, statistics=True)
    )
    root.ingest_root_batch(db, root.root_batch((root.raw_sample(),), sequence=4))
    assert root.current_total(db) == 0.0
    assert _points(db) == [(0.0, "current")]


def test_uint64_order_is_not_narrowed_to_sqlite_signed_integer(tmp_path: Path) -> None:
    db = tmp_path / "safety.sqlite"
    maximum = 18_446_744_073_709_551_615
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(),), sequence=maximum, statistics=True)
    )
    root.ingest_root_batch(
        db,
        root.root_batch(
            (root.daily_sample(1.0),), sequence=maximum - 1, statistics=True
        ),
    )
    assert root.current_total(db) == 6.0


@pytest.mark.parametrize("malformation", ["sequence", "type_code", "raw_intervals"])
def test_malformed_evidence_fails_before_mutating_any_record(
    tmp_path: Path, malformation: str
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(
        db,
        root.root_batch(
            (root.daily_sample(), root.raw_sample()), sequence=1, statistics=True
        ),
    )
    batch = root.root_batch((root.raw_sample(1.0),), sequence=2)
    cursor = batch.sync.cursors[0]
    body = JSON_OBJECT.validate_json(cursor.cursor_value)
    body[malformation] = "invalid"
    malformed = batch.model_copy(
        update={
            "sync": batch.sync.model_copy(
                update={
                    "cursors": (
                        cursor.model_copy(update={"cursor_value": json.dumps(body)}),
                    ),
                }
            )
        }
    )
    with pytest.raises(ValueError, match=r"validation error|invalid projection"):
        root.ingest_root_batch(db, malformed)
    assert root.current_total(db) == 6.0


def test_client_metadata_cannot_assert_projection_currentness(tmp_path: Path) -> None:
    db = tmp_path / "safety.sqlite"
    daily = root.daily_sample().model_copy(
        update={
            "metadata": {
                **root.daily_sample().metadata,
                "projection_status": "current",
                "_bridge_daily_projection": "current",
            }
        }
    )
    root.ingest_root_batch(db, root.root_batch((daily,)))
    assert root.current_total(db) is None
    assert _points(db) == [(6.0, "unknown")]


def test_empty_observation_advances_unknown_fence_without_fabricating_zero(
    tmp_path: Path,
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(),), sequence=1, statistics=True)
    )
    root.ingest_root_batch(db, root.root_batch(sequence=8, statistics=True))
    assert root.current_total(db) is None
    assert _points(db) == [(6.0, "unknown")]
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(2.0),), sequence=7, statistics=True)
    )
    assert root.current_total(db) is None
    root.ingest_root_batch(
        db, root.root_batch((root.daily_sample(0.0),), sequence=9, statistics=True)
    )
    assert root.current_total(db) == 0.0


def test_changed_unordered_raw_cannot_allow_lower_order_new_projection_identity(
    tmp_path: Path,
) -> None:
    db = tmp_path / "safety.sqlite"
    root.ingest_root_batch(
        db,
        root.root_batch(
            (root.raw_sample(), root.daily_sample()), sequence=5, statistics=True
        ),
    )
    root.ingest_root_batch(db, root.root_batch((root.raw_sample(4.0),)))
    assert root.current_total(db) is None
    alternate = root.daily_sample(1.0).model_copy(
        update={"client_record_id": "synthetic-alternate"}
    )
    root.ingest_root_batch(
        db, root.root_batch((alternate,), sequence=4, statistics=True)
    )
    assert root.current_total(db) is None

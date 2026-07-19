from pathlib import Path

from health_bridge.ingest import ingest_fixture
from health_bridge.storage import initialize_database

FIXTURE_PATH = Path("fixtures/health_bridge_batch_v1.synthetic.json")


def initialized_fixture_db(tmp_path: Path) -> Path:
    db_path = tmp_path / "fixture.sqlite"
    initialize_database(db_path)
    _ = ingest_fixture(db_path, FIXTURE_PATH)
    return db_path

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import TimeWindow
from tests.fixture_helpers import FIXTURE_PATH


def catalogue_batch(day: int) -> HealthBridgeBatchV1:
    fixture = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    window = TimeWindow(
        start_time=f"2026-06-{day:02d}T00:00:00Z",
        end_time=f"2026-06-{day + 1:02d}T00:00:00Z",
    )
    sample = next(s for s in fixture.samples if s.type_code == "heart_rate")
    sample = sample.model_copy(
        update={
            "client_record_id": f"synthetic-catalogue-heart-{day}",
            "start_time": f"2026-06-{day:02d}T12:00:00Z",
            "end_time": f"2026-06-{day:02d}T12:00:05Z",
        }
    )

    return fixture.model_copy(
        update={
            "generated_at": window.end_time,
            "export_window": window,
            "sources": tuple(
                s for s in fixture.sources if s.source_key == sample.source_key
            ),
            "health_types": tuple(
                t for t in fixture.health_types if t.type_code == "heart_rate"
            ),
            "samples": (sample,),
            "workouts": (),
            "sleep_sessions": (),
            "deleted_records": (),
            "sync": fixture.sync.model_copy(
                update={"sync_window": window, "cursors": ()}
            ),
        }
    )

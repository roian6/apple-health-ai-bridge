from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class IngestResult:
    status: str
    source_count: int
    health_type_count: int
    sample_count: int
    workout_count: int
    sleep_session_count: int
    deleted_record_count: int
    sync_cursor_count: int
    error_summary: str | None = None


def failed_ingest_result(error_summary: str) -> IngestResult:
    return IngestResult(
        status="failed",
        source_count=0,
        health_type_count=0,
        sample_count=0,
        workout_count=0,
        sleep_session_count=0,
        deleted_record_count=0,
        sync_cursor_count=0,
        error_summary=error_summary,
    )

from typing import ClassVar

from pydantic import BaseModel, ConfigDict, Field


class QueryModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class Period(QueryModel):
    start: str
    end: str


class SourceUsed(QueryModel):
    source_key: str
    name: str
    kind: str


class Metric(QueryModel):
    type_code: str
    display_name: str
    category: str
    default_unit: str
    sensitivity: str
    record_count: int


class SyncedMetricsResult(QueryModel):
    period: Period
    metrics: tuple[Metric, ...]
    sources_used: tuple[SourceUsed, ...]
    missing_data_notes: tuple[str, ...]
    truncated: bool


class TimeseriesPoint(QueryModel):
    type_code: str
    start_time: str
    end_time: str
    value: float
    unit: str
    source: SourceUsed
    metadata: dict[str, object] = Field(default_factory=dict)


class TimeseriesResult(QueryModel):
    period: Period
    requested_types: tuple[str, ...]
    points: tuple[TimeseriesPoint, ...]
    sources_used: tuple[SourceUsed, ...]
    missing_data_notes: tuple[str, ...]
    truncated: bool


class WorkoutObservation(QueryModel):
    workout_type: str
    start_time: str
    end_time: str
    duration_seconds: int
    energy_kcal: float | None
    distance_meters: float | None
    source: SourceUsed


class WorkoutsResult(QueryModel):
    period: Period
    workouts: tuple[WorkoutObservation, ...]
    sources_used: tuple[SourceUsed, ...]
    missing_data_notes: tuple[str, ...]
    truncated: bool


class SleepSummaryResult(QueryModel):
    period: Period
    session_count: int
    stage_seconds: dict[str, int]
    sources_used: tuple[SourceUsed, ...]
    missing_data_notes: tuple[str, ...]
    truncated: bool


class DailySampleStatistic(QueryModel):
    unit: str
    aggregation: str
    count: int
    total: float | None
    average: float | None
    minimum: float | None
    maximum: float | None
    latest: float | None
    latest_time: str | None


class DailyObservation(QueryModel):
    date: str
    sample_totals: dict[str, float]
    sample_total_semantics: dict[str, str]
    daily_activity_totals: dict[str, float]
    sample_counts: dict[str, int]
    sample_statistics: dict[str, DailySampleStatistic]
    workout_count: int
    sleep_session_count: int


class DailySummaryResult(QueryModel):
    period: Period
    days: tuple[DailyObservation, ...]
    sources_used: tuple[SourceUsed, ...]
    missing_data_notes: tuple[str, ...]
    truncated: bool


class SourceDetail(QueryModel):
    source_key: str
    name: str
    kind: str
    bundle_id: str | None
    device_model: str | None


class SyncCursorDetail(QueryModel):
    source_key: str
    cursor_kind: str
    updated_at: str


class SourcesResult(QueryModel):
    period: Period
    sources: tuple[SourceDetail, ...]
    sync_cursors: tuple[SyncCursorDetail, ...]
    sources_used: tuple[SourceUsed, ...]
    missing_data_notes: tuple[str, ...]
    truncated: bool

from datetime import UTC, date, datetime, time, timedelta
from typing import ClassVar, Final, Literal, Self
from zoneinfo import ZoneInfo

from pydantic import ConfigDict, Field, field_validator, model_validator

from health_bridge.contract.batch_v1 import UtcTimestamp, utc_datetime
from health_bridge.queries.latest_sleep_models import (
    LatestSleepArgs,
    SleepPeriod,
    sleep_period,
)
from health_bridge.queries.models import QueryModel, SourceUsed
from health_bridge.queries.sleep_evidence import SleepIntervalEvidence

SLEEP_INPUT_NOTE: Final = (
    "Receiver stage names describe received data. The phone maps HealthKit "
    "asleepUnspecified to core before storage; core is not an exact preserved "
    "Apple stage. Raw HealthKit origin metadata is unavailable for source priority."
)
SLEEP_REPORT_NOTE: Final = (
    "All received observed periods ending on this local date are reported, including "
    "fragmented sleep and naps. Gaps are not filled. Recorded totals include only "
    "known intervals; unknown periods are not zero. Coverage describes stored stage "
    "evidence, not total biological sleep, physiological completion, freshness, "
    "sync completeness or Health permission."
)


def current_utc_timestamp() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class SleepReportArgs(QueryModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, strict=True, extra="forbid"
    )
    timezone: str
    local_date: str | None = None
    reference_time: UtcTimestamp = Field(default_factory=current_utc_timestamp)
    include_intervals: bool = False

    @field_validator("timezone")
    @classmethod
    def require_timezone(cls, value: str) -> str:
        return LatestSleepArgs.require_timezone(value)

    @field_validator("local_date")
    @classmethod
    def require_date(cls, value: str | None) -> str | None:
        if value is not None and date.fromisoformat(value).isoformat() != value:
            message = "local_date must use YYYY-MM-DD"
            raise ValueError(message)
        return value

    @model_validator(mode="after")
    def require_representable_day(self) -> Self:
        try:
            _ = utc_datetime(self.reference_time).astimezone(ZoneInfo(self.timezone))
            _ = self.day_bounds()
        except (OverflowError, ValueError) as exc:
            message = "reference_time and local_date must permit local day bounds"
            raise ValueError(message) from exc
        return self

    def effective_date(self) -> str:
        return (
            self.local_date
            or utc_datetime(self.reference_time)
            .astimezone(ZoneInfo(self.timezone))
            .date()
            .isoformat()
        )

    def day_bounds(self) -> SleepPeriod:
        zone = ZoneInfo(self.timezone)
        day = date.fromisoformat(self.effective_date())
        start = datetime.combine(day, time.min, tzinfo=zone).astimezone(UTC)
        end = datetime.combine(
            day + timedelta(days=1), time.min, tzinfo=zone
        ).astimezone(UTC)
        return sleep_period(
            start.isoformat().replace("+00:00", "Z"),
            end.isoformat().replace("+00:00", "Z"),
            zone,
        )


class SleepReportPeriod(QueryModel):
    period: SleepPeriod
    session_count: int
    sources_used: tuple[SourceUsed, ...]
    duration_status: Literal["recorded", "unknown", "withheld"] = "withheld"
    asleep_seconds: int | None = None
    awake_seconds: int | None = None
    in_bed_seconds: int | None = None
    stage_seconds: dict[str, int] | None = None
    stage_coverage_seconds: int | None = None
    uncovered_seconds: int | None = None
    evidence_incomplete: bool | None = None
    evidence: SleepIntervalEvidence | None = None


class SleepReportResult(QueryModel):
    timezone: str
    requested_local_date: str | None
    local_date: str
    reference_time: str
    day_bounds: SleepPeriod
    include_intervals: bool
    status: Literal["recorded", "no_eligible_periods", "withheld"] = "withheld"
    withheld_reason: Literal["session_limit", "stage_limit"] | None = None
    periods: tuple[SleepReportPeriod, ...] = ()
    recorded_asleep_seconds: int | None = None
    recorded_awake_seconds: int | None = None
    recorded_in_bed_seconds: int | None = None
    unknown_duration_period_count: int | None = None
    incomplete_evidence_period_count: int | None = None
    omitted_after_reference_count: int | None = None
    other_wake_date_count: int | None = None
    sources_used: tuple[SourceUsed, ...] = ()
    missing_data_notes: tuple[str, ...]
    truncated: bool = False

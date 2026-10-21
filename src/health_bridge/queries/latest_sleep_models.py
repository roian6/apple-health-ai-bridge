from datetime import UTC, datetime, time, timedelta
from typing import ClassVar, Final, Self
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import ConfigDict, field_validator, model_validator

from health_bridge.contract.batch_v1 import UtcTimestamp, utc_datetime
from health_bridge.queries.models import Period, QueryModel, SourceUsed

SLEEP_OBSERVATION_NOTE: Final = (
    "Observed periods join overlapping or touching session envelopes across sources; "
    "latest may be a nap. An end at or before reference_time is only an observed "
    "end, not physiological completion or evidence of complete sync."
)
SLEEP_DURATION_NOTE: Final = (
    "Asleep is the elapsed union of core/deep/rem, clipped to each session. "
    "Per-stage unions can overlap and must not be summed as asleep time. "
    "Awake and in_bed are separate claims, may conflict with asleep, and are not "
    "subtracted; no source is preferred. Missing categories are null, not zero. "
    "Unknown stages do not count as asleep; gaps and missing stages remain unknown."
)


class SleepPeriod(Period):
    local_start: str
    local_end: str
    local_end_date: str


def sleep_period(start: str, end: str, zone: ZoneInfo) -> SleepPeriod:
    local_end = utc_datetime(end).astimezone(zone)
    return SleepPeriod(
        start=start,
        end=end,
        local_start=utc_datetime(start).astimezone(zone).isoformat(),
        local_end=local_end.isoformat(),
        local_end_date=local_end.date().isoformat(),
    )


class LatestSleepArgs(QueryModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, strict=True, extra="forbid"
    )
    timezone: str
    reference_time: UtcTimestamp

    @field_validator("timezone")
    @classmethod
    def require_timezone(cls, value: str) -> str:
        try:
            _ = ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            message = "timezone must be an available IANA timezone key"
            raise ValueError(message) from exc
        return value

    @model_validator(mode="after")
    def require_representable_window(self) -> Self:
        try:
            _ = self.search_window()
        except (OverflowError, ValueError) as exc:
            message = "reference_time must permit the seven-local-date search window"
            raise ValueError(message) from exc
        return self

    def search_window(self) -> SleepPeriod:
        zone = ZoneInfo(self.timezone)
        local_reference = utc_datetime(self.reference_time).astimezone(zone)
        first_date = local_reference.date() - timedelta(days=6)
        start = datetime.combine(first_date, time.min, tzinfo=zone).astimezone(UTC)
        return sleep_period(
            start.isoformat().replace("+00:00", "Z"), self.reference_time, zone
        )


class SleepSessionEvidence(QueryModel):
    start: str
    end: str
    source: SourceUsed


class SleepStageEvidence(Period):
    session_index: int
    stage: str


class LatestSleepPeriodResult(QueryModel):
    timezone: str
    reference_time: str
    search_window: SleepPeriod
    selected_period: SleepPeriod | None = None
    sessions: tuple[SleepSessionEvidence, ...] = ()
    stage_intervals: tuple[SleepStageEvidence, ...] = ()
    asleep_intervals: tuple[Period, ...] = ()
    asleep_seconds: int | None = None
    awake_seconds: int | None = None
    in_bed_seconds: int | None = None
    stage_seconds: dict[str, int]
    sources_used: tuple[SourceUsed, ...] = ()
    missing_data_notes: tuple[str, ...]
    truncated: bool = False

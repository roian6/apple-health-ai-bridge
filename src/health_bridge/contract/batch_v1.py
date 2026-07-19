import re
from datetime import UTC, datetime
from typing import Annotated, ClassVar, Final, Literal, Self, TypeAlias

from pydantic import (
    AfterValidator,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
    model_validator,
)
from pydantic_core import PydanticCustomError

SCHEMA_MAJOR_ERROR_TYPE: Final = "unsupported_schema_major"
SCHEMA_MAJOR_ERROR_MESSAGE: Final = "schema_version must match major version 1"
EXPLICIT_NULL_ERROR_TYPE: Final = "explicit_null_not_allowed"
EXPLICIT_NULL_ERROR_MESSAGE: Final = "field may be omitted but cannot be null"
ALIASES_UNIQUE_ERROR_TYPE: Final = "aliases_not_unique"
ALIASES_UNIQUE_ERROR_MESSAGE: Final = "aliases must be unique"
SCHEMA_VERSION_PATTERN: Final = re.compile(r"^1\.\d+\.\d+$")
UTC_TIMESTAMP_PATTERN: Final = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"
SYNTHETIC_SOURCE_PATTERN: Final = r"^(synthetic|apple_health)\.[a-z0-9_.-]+$"
SYNTHETIC_RECORD_PATTERN: Final = r"^(synthetic|hk)-[a-z0-9-]+$"
TYPE_CODE_PATTERN: Final = r"^[a-z][a-z0-9_]*$"


def validate_utc_timestamp(value: str) -> str:
    try:
        _ = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    except ValueError as exc:
        error_type = "invalid_utc_timestamp"
        error_message = "timestamp must be a valid UTC timestamp"
        raise PydanticCustomError(
            error_type,
            error_message,
        ) from exc
    return value


def utc_datetime(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def validate_order(start_time: str, end_time: str) -> None:
    if utc_datetime(start_time) > utc_datetime(end_time):
        message = "start_time must not be after end_time"
        raise ValueError(message)


UtcTimestamp: TypeAlias = Annotated[
    str,
    StringConstraints(pattern=UTC_TIMESTAMP_PATTERN),
    AfterValidator(validate_utc_timestamp),
]
SyntheticSourceKey: TypeAlias = Annotated[
    str,
    StringConstraints(pattern=SYNTHETIC_SOURCE_PATTERN),
]
SyntheticRecordId: TypeAlias = Annotated[
    str,
    StringConstraints(pattern=SYNTHETIC_RECORD_PATTERN),
]
TypeCode: TypeAlias = Annotated[str, StringConstraints(pattern=TYPE_CODE_PATTERN)]
NonEmptyString: TypeAlias = Annotated[str, StringConstraints(min_length=1)]
NonNegativeFloat: TypeAlias = Annotated[float, Field(ge=0)]
NonNegativeInt: TypeAlias = Annotated[int, Field(ge=0)]
JsonNumber: TypeAlias = int | float


def reject_explicit_null_string(value: str | None) -> str | None:
    if value is None:
        raise PydanticCustomError(EXPLICIT_NULL_ERROR_TYPE, EXPLICIT_NULL_ERROR_MESSAGE)
    return value


def reject_explicit_null_number(value: JsonNumber | None) -> JsonNumber | None:
    if value is None:
        raise PydanticCustomError(EXPLICIT_NULL_ERROR_TYPE, EXPLICIT_NULL_ERROR_MESSAGE)
    return value


OmittableString: TypeAlias = Annotated[
    str | None,
    BeforeValidator(reject_explicit_null_string),
]
OmittableNonNegativeFloat: TypeAlias = Annotated[
    NonNegativeFloat | None,
    BeforeValidator(reject_explicit_null_number),
]


class StrictModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        allow_inf_nan=False,
        extra="forbid",
        frozen=True,
        strict=True,
    )


class TimeWindow(StrictModel):
    start_time: UtcTimestamp
    end_time: UtcTimestamp

    @model_validator(mode="after")
    def reject_reversed_window(self) -> Self:
        validate_order(self.start_time, self.end_time)
        return self


class Source(StrictModel):
    source_key: SyntheticSourceKey
    name: NonEmptyString
    kind: Literal["phone", "watch", "app", "manual"]
    bundle_id: OmittableString = None
    device_model: OmittableString = None


class HealthType(StrictModel):
    type_code: TypeCode
    display_name: NonEmptyString
    category: Literal[
        "activity",
        "blood_respiratory",
        "body",
        "environmental",
        "fitness",
        "heart",
        "other",
        "provider_specific",
        "sleep",
        "workout",
    ]
    default_unit: NonEmptyString
    sensitivity: Literal["low", "moderate", "high"]
    aliases: tuple[NonEmptyString, ...]

    @field_validator("aliases")
    @classmethod
    def reject_duplicate_aliases(
        cls,
        value: tuple[NonEmptyString, ...],
    ) -> tuple[NonEmptyString, ...]:
        if len(value) == len(set(value)):
            return value
        raise PydanticCustomError(
            ALIASES_UNIQUE_ERROR_TYPE,
            ALIASES_UNIQUE_ERROR_MESSAGE,
        )


class Sample(StrictModel):
    client_record_id: SyntheticRecordId
    source_key: SyntheticSourceKey
    type_code: TypeCode
    start_time: UtcTimestamp
    end_time: UtcTimestamp
    value: float
    unit: NonEmptyString
    metadata: dict[str, str] = Field(default_factory=dict)

    @model_validator(mode="after")
    def reject_reversed_interval(self) -> Self:
        validate_order(self.start_time, self.end_time)
        return self


class Workout(StrictModel):
    client_record_id: SyntheticRecordId
    source_key: SyntheticSourceKey
    workout_type: NonEmptyString
    start_time: UtcTimestamp
    end_time: UtcTimestamp
    duration_seconds: NonNegativeInt
    energy_kcal: OmittableNonNegativeFloat = None
    distance_meters: OmittableNonNegativeFloat = None

    @model_validator(mode="after")
    def reject_inconsistent_duration(self) -> Self:
        validate_order(self.start_time, self.end_time)
        elapsed_seconds = int(
            (
                utc_datetime(self.end_time) - utc_datetime(self.start_time)
            ).total_seconds()
        )
        if self.duration_seconds > elapsed_seconds:
            message = "duration_seconds must not exceed workout interval"
            raise ValueError(message)
        return self


class SleepStageInterval(StrictModel):
    stage: Literal["in_bed", "awake", "core", "deep", "rem"]
    start_time: UtcTimestamp
    end_time: UtcTimestamp

    @model_validator(mode="after")
    def reject_reversed_interval(self) -> Self:
        validate_order(self.start_time, self.end_time)
        return self


class SleepSession(StrictModel):
    client_record_id: SyntheticRecordId
    source_key: SyntheticSourceKey
    start_time: UtcTimestamp
    end_time: UtcTimestamp
    stage_intervals: tuple[SleepStageInterval, ...]

    @model_validator(mode="after")
    def reject_out_of_bounds_stages(self) -> Self:
        validate_order(self.start_time, self.end_time)
        session_start = utc_datetime(self.start_time)
        session_end = utc_datetime(self.end_time)
        if any(
            utc_datetime(stage.start_time) < session_start
            or utc_datetime(stage.end_time) > session_end
            for stage in self.stage_intervals
        ):
            message = "sleep stage must be contained within its session"
            raise ValueError(message)
        return self


class DeletedRecord(StrictModel):
    record_family: Literal["sample", "workout", "sleep_session"]
    source_key: SyntheticSourceKey
    client_record_id: SyntheticRecordId
    deleted_at: UtcTimestamp


class SyncCursor(StrictModel):
    source_key: SyntheticSourceKey
    cursor_kind: NonEmptyString
    cursor_value: NonEmptyString


class SyncContext(StrictModel):
    sync_window: TimeWindow
    cursors: tuple[SyncCursor, ...]


class HealthBridgeBatchV1(StrictModel):
    schema_id: Literal["health_bridge.batch.v1"]
    schema_version: str
    generated_at: UtcTimestamp
    export_window: TimeWindow
    sources: tuple[Source, ...] = Field(min_length=1)
    health_types: tuple[HealthType, ...] = Field(min_length=1)
    samples: tuple[Sample, ...]
    workouts: tuple[Workout, ...]
    sleep_sessions: tuple[SleepSession, ...]
    deleted_records: tuple[DeletedRecord, ...]
    sync: SyncContext

    @field_validator("schema_version")
    @classmethod
    def reject_unknown_major_version(cls, value: str) -> str:
        if SCHEMA_VERSION_PATTERN.fullmatch(value):
            return value
        raise PydanticCustomError(
            SCHEMA_MAJOR_ERROR_TYPE,
            SCHEMA_MAJOR_ERROR_MESSAGE,
        )

    @model_validator(mode="after")
    def reject_sync_window_outside_export_window(self) -> Self:
        export_start = utc_datetime(self.export_window.start_time)
        export_end = utc_datetime(self.export_window.end_time)
        sync_start = utc_datetime(self.sync.sync_window.start_time)
        sync_end = utc_datetime(self.sync.sync_window.end_time)
        if sync_start < export_start or sync_end > export_end:
            message = "sync window must be contained within export window"
            raise ValueError(message)
        return self

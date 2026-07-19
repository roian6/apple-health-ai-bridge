"""Supported wearable timeseries metadata.

This module intentionally contains metadata only: no provider calls, no HealthKit
reads, and no raw health values. It gives local query/agent surfaces stable type
codes and aggregation semantics while the iOS companion keeps live permissions
explicit, read-only, and Apple Health-faithful.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import ClassVar, Final, Literal

from pydantic import BaseModel, ConfigDict

Aggregation = Literal["sum", "min_max_average", "latest"]
IosSupportStatus = Literal[
    "live_readable",
    "runtime_gated",
    "derived_required",
    "provider_specific",
    "workout_context",
    "metadata_only",
]


@dataclass(frozen=True, slots=True)
class TimeseriesType:
    type_code: str
    unit: str
    category: str
    description: str
    aggregation: Aggregation


class TimeseriesCatalogModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class TimeseriesTypeSummary(TimeseriesCatalogModel):
    type_code: str
    unit: str
    category: str
    description: str
    aggregation: Aggregation
    ios_support_status: IosSupportStatus
    ios_support_note: str
    ios_live_readable: bool
    ios_background_eligible: bool


class SupportedTimeseriesCatalog(TimeseriesCatalogModel):
    schema_id: str = "health_bridge.supported_timeseries_catalog.v2"
    total_type_count: int
    ios_live_readable_type_count: int
    ios_background_eligible_type_count: int
    returned_type_count: int
    returned_ios_live_readable_type_count: int
    returned_ios_background_eligible_type_count: int
    types: tuple[TimeseriesTypeSummary, ...]
    missing_data_notes: tuple[str, ...]


# Curated wearable-timeseries vocabulary for local query/agent surfaces. The set
# is intentionally broader than direct iOS HealthKit quantities. A type code being
# present here means the receiver/query layer can represent it safely; the iOS
# support fields below distinguish direct unified sync coverage from provider,
# derived, or workout-context metadata.
TIMESERIES_TYPES: Final[tuple[TimeseriesType, ...]] = (
    TimeseriesType("heart_rate", "bpm", "heart", "Heart rate", "min_max_average"),
    TimeseriesType(
        "resting_heart_rate", "bpm", "heart", "Resting heart rate", "min_max_average"
    ),
    TimeseriesType(
        "heart_rate_variability_sdnn",
        "ms",
        "heart",
        "HRV (SDNN method)",
        "min_max_average",
    ),
    TimeseriesType(
        "heart_rate_variability_rmssd",
        "ms",
        "heart",
        "HRV (RMSSD method)",
        "min_max_average",
    ),
    TimeseriesType(
        "heart_rate_recovery_one_minute",
        "count/min",
        "heart",
        "HR recovery after 1 minute",
        "min_max_average",
    ),
    TimeseriesType(
        "walking_heart_rate_average",
        "count/min",
        "heart",
        "Average HR while walking",
        "min_max_average",
    ),
    TimeseriesType("recovery_score", "score", "heart", "Recovery score", "latest"),
    TimeseriesType(
        "oxygen_saturation",
        "%",
        "blood_respiratory",
        "SpO2 blood oxygen",
        "min_max_average",
    ),
    TimeseriesType(
        "blood_glucose",
        "mg/dL",
        "blood_respiratory",
        "Blood glucose level",
        "min_max_average",
    ),
    TimeseriesType(
        "blood_pressure_systolic",
        "mmHg",
        "blood_respiratory",
        "Systolic blood pressure",
        "min_max_average",
    ),
    TimeseriesType(
        "blood_pressure_diastolic",
        "mmHg",
        "blood_respiratory",
        "Diastolic blood pressure",
        "min_max_average",
    ),
    TimeseriesType(
        "respiratory_rate",
        "brpm",
        "blood_respiratory",
        "Breathing rate",
        "min_max_average",
    ),
    TimeseriesType(
        "sleeping_breathing_disturbances",
        "count",
        "blood_respiratory",
        "Sleep breathing disturbances",
        "sum",
    ),
    TimeseriesType(
        "blood_alcohol_content",
        "%",
        "blood_respiratory",
        "Blood alcohol content",
        "min_max_average",
    ),
    TimeseriesType(
        "peripheral_perfusion_index",
        "%",
        "blood_respiratory",
        "Peripheral perfusion index",
        "min_max_average",
    ),
    TimeseriesType(
        "forced_vital_capacity",
        "liters",
        "blood_respiratory",
        "Forced vital capacity",
        "latest",
    ),
    TimeseriesType(
        "forced_expiratory_volume_1",
        "liters",
        "blood_respiratory",
        "Forced expiratory volume (1s)",
        "latest",
    ),
    TimeseriesType(
        "peak_expiratory_flow_rate",
        "L/min",
        "blood_respiratory",
        "Peak expiratory flow rate",
        "latest",
    ),
    TimeseriesType("height", "cm", "body", "Height", "latest"),
    TimeseriesType("weight", "kg", "body", "Weight", "latest"),
    TimeseriesType("body_fat_percentage", "%", "body", "Body fat percentage", "latest"),
    TimeseriesType("body_mass_index", "kg/m²", "body", "BMI", "latest"),
    TimeseriesType("lean_body_mass", "kg", "body", "Lean body mass", "latest"),
    TimeseriesType(
        "body_temperature", "°C", "body", "Body temperature", "min_max_average"
    ),
    TimeseriesType(
        "skin_temperature", "°C", "body", "Skin temperature", "min_max_average"
    ),
    TimeseriesType(
        "waist_circumference", "cm", "body", "Waist circumference", "latest"
    ),
    TimeseriesType("body_fat_mass", "kg", "body", "Body fat mass", "latest"),
    TimeseriesType(
        "skeletal_muscle_mass", "kg", "body", "Skeletal muscle mass", "latest"
    ),
    TimeseriesType("vo2_max", "mL/kg/min", "fitness", "VO2 max", "latest"),
    TimeseriesType(
        "six_minute_walk_test_distance",
        "m",
        "fitness",
        "6-minute walk test",
        "latest",
    ),
    TimeseriesType("steps", "count", "activity", "Step count", "sum"),
    TimeseriesType("energy", "kcal", "activity", "Active energy burned", "sum"),
    TimeseriesType("basal_energy", "kcal", "activity", "Basal/resting energy", "sum"),
    TimeseriesType("stand_time", "minutes", "activity", "Time spent standing", "sum"),
    TimeseriesType("exercise_time", "minutes", "activity", "Exercise duration", "sum"),
    TimeseriesType(
        "physical_effort",
        "kcal/kg/hr",
        "activity",
        "Physical effort score",
        "min_max_average",
    ),
    TimeseriesType(
        "flights_climbed", "count", "activity", "Floors/flights climbed", "sum"
    ),
    TimeseriesType(
        "average_met",
        "MET",
        "activity",
        "Average metabolic equivalent",
        "min_max_average",
    ),
    TimeseriesType(
        "distance_walking_running",
        "m",
        "activity",
        "Walking/running distance",
        "sum",
    ),
    TimeseriesType("distance_cycling", "m", "activity", "Cycling distance", "sum"),
    TimeseriesType("distance_swimming", "m", "activity", "Swimming distance", "sum"),
    TimeseriesType(
        "distance_downhill_snow_sports",
        "m",
        "activity",
        "Skiing/snowboarding distance",
        "sum",
    ),
    TimeseriesType("distance_other", "meters", "activity", "Other distance", "sum"),
    TimeseriesType(
        "walking_step_length",
        "cm",
        "activity",
        "Average step length",
        "min_max_average",
    ),
    TimeseriesType(
        "walking_speed", "m/s", "activity", "Walking speed", "min_max_average"
    ),
    TimeseriesType(
        "walking_double_support_percentage",
        "%",
        "activity",
        "Double support time",
        "min_max_average",
    ),
    TimeseriesType(
        "walking_asymmetry_percentage",
        "%",
        "activity",
        "Gait asymmetry",
        "min_max_average",
    ),
    TimeseriesType(
        "walking_steadiness",
        "%",
        "activity",
        "Walking steadiness score",
        "min_max_average",
    ),
    TimeseriesType(
        "stair_descent_speed",
        "m/s",
        "activity",
        "Stair descent speed",
        "min_max_average",
    ),
    TimeseriesType(
        "stair_ascent_speed", "m/s", "activity", "Stair ascent speed", "min_max_average"
    ),
    TimeseriesType(
        "running_power", "watts", "activity", "Running power", "min_max_average"
    ),
    TimeseriesType(
        "running_speed", "m/s", "activity", "Running speed", "min_max_average"
    ),
    TimeseriesType(
        "running_vertical_oscillation",
        "cm",
        "activity",
        "Vertical oscillation",
        "min_max_average",
    ),
    TimeseriesType(
        "running_ground_contact_time",
        "ms",
        "activity",
        "Ground contact time",
        "min_max_average",
    ),
    TimeseriesType(
        "running_stride_length",
        "cm",
        "activity",
        "Running stride length",
        "min_max_average",
    ),
    TimeseriesType(
        "swimming_stroke_count", "count", "activity", "Swimming strokes", "sum"
    ),
    TimeseriesType(
        "underwater_depth", "m", "activity", "Underwater depth", "min_max_average"
    ),
    TimeseriesType("cadence", "rpm", "activity", "Cadence", "min_max_average"),
    TimeseriesType("power", "watts", "activity", "Power output", "min_max_average"),
    TimeseriesType("speed", "m/s", "activity", "Speed", "min_max_average"),
    TimeseriesType(
        "workout_effort_score",
        "apple_effort_score",
        "activity",
        "Workout effort score",
        "latest",
    ),
    TimeseriesType(
        "estimated_workout_effort_score",
        "apple_effort_score",
        "activity",
        "Estimated workout effort score",
        "latest",
    ),
    TimeseriesType(
        "environmental_audio_exposure",
        "dBASPL",
        "environmental",
        "Environmental noise",
        "min_max_average",
    ),
    TimeseriesType(
        "headphone_audio_exposure",
        "dBASPL",
        "environmental",
        "Headphone volume",
        "min_max_average",
    ),
    TimeseriesType("uv_exposure", "count", "environmental", "UV exposure", "sum"),
    TimeseriesType("inhaler_usage", "count", "environmental", "Inhaler usage", "sum"),
    TimeseriesType(
        "weather_temperature",
        "°C",
        "environmental",
        "Weather temperature",
        "min_max_average",
    ),
    TimeseriesType(
        "weather_humidity", "%", "environmental", "Weather humidity", "min_max_average"
    ),
    TimeseriesType(
        "garmin_stress_level",
        "score",
        "provider_specific",
        "Garmin stress score",
        "min_max_average",
    ),
    TimeseriesType(
        "garmin_skin_temperature",
        "°C",
        "provider_specific",
        "Garmin skin temperature deviation",
        "min_max_average",
    ),
    TimeseriesType(
        "garmin_fitness_age",
        "years",
        "provider_specific",
        "Garmin fitness age estimate",
        "latest",
    ),
    TimeseriesType(
        "garmin_body_battery",
        "%",
        "provider_specific",
        "Garmin body battery",
        "min_max_average",
    ),
    TimeseriesType(
        "electrodermal_activity",
        "S",
        "other",
        "Electrodermal activity",
        "min_max_average",
    ),
    TimeseriesType("push_count", "count", "other", "Push count", "sum"),
    TimeseriesType(
        "atrial_fibrillation_burden",
        "%",
        "other",
        "Atrial fibrillation burden",
        "min_max_average",
    ),
    TimeseriesType("insulin_delivery", "IU", "other", "Insulin delivery", "sum"),
    TimeseriesType("number_of_times_fallen", "count", "other", "Fall count", "sum"),
    TimeseriesType(
        "number_of_alcoholic_beverages", "count", "other", "Alcoholic beverages", "sum"
    ),
    TimeseriesType("nike_fuel", "count", "other", "Nike Fuel", "sum"),
    TimeseriesType("hydration", "mL", "other", "Hydration", "sum"),
)

# Legacy Apple Health Bridge codes kept query-compatible while new work can use
# canonical names. Do not remove without a migration.
LEGACY_TYPE_CODE_AGGREGATION_ALIASES: Final[dict[str, Aggregation]] = {
    "active_energy": "sum",
    "body_mass": "latest",
}
LEGACY_SAMPLE_TYPE_CODE_ALIASES: Final[dict[str, str]] = {
    "active_energy": "energy",
    "body_mass": "weight",
}
LEGACY_SAMPLE_RECORD_PREFIX_ALIASES: Final[dict[str, str]] = {
    "hk-quantity-active-energy-": "hk-quantity-energy-",
    "hk-quantity-body-mass-": "hk-quantity-weight-",
}


def canonical_sample_type_code(type_code: str) -> str:
    """Return the canonical stored sample type code for legacy aliases."""
    return LEGACY_SAMPLE_TYPE_CODE_ALIASES.get(type_code, type_code)


def canonical_sample_client_record_id(type_code: str, client_record_id: str) -> str:
    """Return a legacy-alias-safe sample record id for canonical storage."""
    if type_code in LEGACY_SAMPLE_TYPE_CODE_ALIASES:
        return canonical_deleted_sample_client_record_id(client_record_id)
    return client_record_id


def canonical_deleted_sample_client_record_id(client_record_id: str) -> str:
    """Canonicalize exact legacy sample-id prefixes retained for upgrades."""
    for legacy_prefix, canonical_prefix in LEGACY_SAMPLE_RECORD_PREFIX_ALIASES.items():
        if client_record_id.startswith(legacy_prefix):
            return client_record_id.replace(legacy_prefix, canonical_prefix, 1)
    return client_record_id


def compatible_deleted_sample_client_record_ids(
    client_record_id: str,
) -> tuple[str, ...]:
    """Return canonical plus legacy IDs that may exist before alias migrations."""
    canonical_id = canonical_deleted_sample_client_record_id(client_record_id)
    candidates = [canonical_id]
    for legacy_prefix, canonical_prefix in LEGACY_SAMPLE_RECORD_PREFIX_ALIASES.items():
        if canonical_id.startswith(canonical_prefix):
            candidates.append(canonical_id.replace(canonical_prefix, legacy_prefix, 1))
    return tuple(dict.fromkeys(candidates))


def canonical_sync_cursor_kind(cursor_kind: str) -> str:
    """Canonicalize cursor kinds that end with a legacy sample type code."""
    canonical_kind = cursor_kind
    for (
        legacy_type_code,
        canonical_type_code,
    ) in LEGACY_SAMPLE_TYPE_CODE_ALIASES.items():
        canonical_kind = canonical_kind.replace(
            f"foreground_quantity_sync:{legacy_type_code}",
            f"foreground_quantity_sync:{canonical_type_code}",
            1,
        )
    return canonical_kind


TIMESERIES_BY_TYPE_CODE: Final = {entry.type_code: entry for entry in TIMESERIES_TYPES}

IOS_METADATA_ONLY_TIMESERIES_TYPE_CODES: Final[frozenset[str]] = frozenset(
    {
        "heart_rate_variability_rmssd",
        "recovery_score",
        "body_fat_mass",
        "skeletal_muscle_mass",
        "average_met",
        "distance_other",
        "cadence",
        "power",
        "speed",
        "weather_temperature",
        "weather_humidity",
        "garmin_stress_level",
        "garmin_skin_temperature",
        "garmin_fitness_age",
        "garmin_body_battery",
    }
)
IOS_SUPPORT_STATUS_BY_TYPE_CODE: Final[dict[str, IosSupportStatus]] = {
    "heart_rate_variability_rmssd": "derived_required",
    "body_fat_mass": "derived_required",
    "recovery_score": "provider_specific",
    "skeletal_muscle_mass": "provider_specific",
    "garmin_stress_level": "provider_specific",
    "garmin_skin_temperature": "provider_specific",
    "garmin_fitness_age": "provider_specific",
    "garmin_body_battery": "provider_specific",
    "average_met": "workout_context",
    "distance_other": "workout_context",
    "cadence": "workout_context",
    "power": "workout_context",
    "speed": "workout_context",
    "weather_temperature": "workout_context",
    "weather_humidity": "workout_context",
}
IOS_SUPPORT_NOTE_BY_TYPE_CODE: Final[dict[str, str]] = {
    "heart_rate_variability_rmssd": (
        "Apple Health's standard HRV quantity is SDNN; RMSSD needs provider/raw "
        "beat-interval data and must not be aliased to SDNN."
    ),
    "body_fat_mass": (
        "Derived from weight and body fat percentage only after a provenance "
        "policy exists; there is no direct HealthKit body-fat-mass quantity."
    ),
    "recovery_score": (
        "Provider algorithm output, not Apple workout effort score; requires "
        "provider ingest or an explicit derived-score policy."
    ),
    "skeletal_muscle_mass": (
        "Smart-scale/provider metric with no direct Apple Health quantity; do "
        "not alias to lean body mass."
    ),
    "average_met": (
        "Workout-context or derived metric. Apple Physical Effort is MET-like "
        "but already represented separately as physical_effort."
    ),
    "distance_other": (
        "Workout-context distance for unmapped activity types; deriving it must "
        "avoid double-counting walking/running/cycling/swimming distances."
    ),
    "cadence": (
        "Potential cycling cadence mapping only; generic cadence needs explicit "
        "workout-context semantics before live sync."
    ),
    "power": (
        "Potential cycling power mapping only; running power is already a "
        "separate direct HealthKit type."
    ),
    "speed": (
        "Potential cycling speed mapping only; walking/running speed are already "
        "separate direct HealthKit types."
    ),
    "weather_temperature": (
        "Workout metadata value, not a standalone HealthKit quantity sample; "
        "requires workout-context serialization."
    ),
    "weather_humidity": (
        "Workout metadata value, not a standalone HealthKit quantity sample; "
        "requires workout-context serialization."
    ),
    "garmin_stress_level": "Garmin provider-only metric; requires provider ingest.",
    "garmin_skin_temperature": (
        "Garmin provider-only metric; do not alias to Apple skin temperature."
    ),
    "garmin_fitness_age": "Garmin provider-only metric; requires provider ingest.",
    "garmin_body_battery": "Garmin provider-only metric; requires provider ingest.",
}
IOS_LIVE_READABLE_TIMESERIES_TYPE_CODES: Final[frozenset[str]] = (
    frozenset(TIMESERIES_BY_TYPE_CODE)
    - IOS_METADATA_ONLY_TIMESERIES_TYPE_CODES
    - frozenset(
        type_code
        for type_code, status in IOS_SUPPORT_STATUS_BY_TYPE_CODE.items()
        if status == "runtime_gated"
    )
)
IOS_BACKGROUND_ELIGIBLE_TIMESERIES_TYPE_CODES: Final[frozenset[str]] = (
    IOS_LIVE_READABLE_TIMESERIES_TYPE_CODES
)


def _ios_support_status_for(type_code: str) -> IosSupportStatus:
    if type_code in IOS_LIVE_READABLE_TIMESERIES_TYPE_CODES:
        return "live_readable"
    return IOS_SUPPORT_STATUS_BY_TYPE_CODE.get(type_code, "metadata_only")


def _ios_support_note_for(type_code: str) -> str:
    if type_code in IOS_LIVE_READABLE_TIMESERIES_TYPE_CODES:
        return "Direct HealthKit quantity supported by the iOS companion."
    return IOS_SUPPORT_NOTE_BY_TYPE_CODE.get(
        type_code,
        "Metadata-only until a matching iOS reader, schema, and privacy review exist.",
    )


def timeseries_aggregation_for(type_code: str) -> Aggregation | None:
    """Return daily aggregation semantics for a supported timeseries type code."""
    if type_code in LEGACY_TYPE_CODE_AGGREGATION_ALIASES:
        return LEGACY_TYPE_CODE_AGGREGATION_ALIASES[type_code]
    entry = TIMESERIES_BY_TYPE_CODE.get(type_code)
    if entry is None:
        return None
    return entry.aggregation


def list_supported_timeseries_types(
    *,
    category: str | None = None,
) -> SupportedTimeseriesCatalog:
    """Return redaction-safe supported timeseries metadata."""
    entries = TIMESERIES_TYPES
    if category is not None:
        entries = tuple(entry for entry in entries if entry.category == category)
    summary_entries = tuple(
        TimeseriesTypeSummary(
            type_code=entry.type_code,
            unit=entry.unit,
            category=entry.category,
            description=entry.description,
            aggregation=entry.aggregation,
            ios_support_status=_ios_support_status_for(entry.type_code),
            ios_support_note=_ios_support_note_for(entry.type_code),
            ios_live_readable=entry.type_code
            in IOS_LIVE_READABLE_TIMESERIES_TYPE_CODES,
            ios_background_eligible=entry.type_code
            in IOS_BACKGROUND_ELIGIBLE_TIMESERIES_TYPE_CODES,
        )
        for entry in entries
    )
    return SupportedTimeseriesCatalog(
        total_type_count=len(TIMESERIES_TYPES),
        ios_live_readable_type_count=len(IOS_LIVE_READABLE_TIMESERIES_TYPE_CODES),
        ios_background_eligible_type_count=len(
            IOS_BACKGROUND_ELIGIBLE_TIMESERIES_TYPE_CODES
        ),
        returned_type_count=len(summary_entries),
        returned_ios_live_readable_type_count=sum(
            1 for entry in summary_entries if entry.ios_live_readable
        ),
        returned_ios_background_eligible_type_count=sum(
            1 for entry in summary_entries if entry.ios_background_eligible
        ),
        types=summary_entries,
        missing_data_notes=(
            (
                "This is metadata only: local availability is unknown until "
                "matching records are present in the user-owned SQLite store."
            ),
            (
                "Live HealthKit permission and upload use the unified set of "
                "platform-supported types; Apple Health still controls access "
                "to each type."
            ),
        ),
    )


TIMESERIES_SUM_TYPE_CODES: Final = frozenset(
    entry.type_code for entry in TIMESERIES_TYPES if entry.aggregation == "sum"
) | frozenset(
    type_code
    for type_code, aggregation in LEGACY_TYPE_CODE_AGGREGATION_ALIASES.items()
    if aggregation == "sum"
)

TIMESERIES_LATEST_TYPE_CODES: Final = frozenset(
    entry.type_code for entry in TIMESERIES_TYPES if entry.aggregation == "latest"
) | frozenset(
    type_code
    for type_code, aggregation in LEGACY_TYPE_CODE_AGGREGATION_ALIASES.items()
    if aggregation == "latest"
)

TIMESERIES_MIN_MAX_AVERAGE_TYPE_CODES: Final = frozenset(
    entry.type_code
    for entry in TIMESERIES_TYPES
    if entry.aggregation == "min_max_average"
)

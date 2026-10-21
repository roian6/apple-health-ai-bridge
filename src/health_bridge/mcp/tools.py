import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import ClassVar, Final, Self, TypeAlias

from pydantic import BaseModel, ConfigDict, field_validator, model_validator

from health_bridge.contract.batch_v1 import (
    UTC_TIMESTAMP_PATTERN,
    UtcTimestamp,
    utc_datetime,
)
from health_bridge.mcp.types import JsonMapping, JsonObject
from health_bridge.queries import (
    explain_sources,
    get_daily_summary,
    get_latest_sleep_period,
    get_sleep_report,
    get_sleep_summary,
    get_timeseries,
    get_workouts,
    list_synced_metrics,
)
from health_bridge.queries.latest_sleep_models import LatestSleepArgs
from health_bridge.queries.sleep_report_models import SleepReportArgs
from health_bridge.status import read_status_markdown, read_status_snapshot
from health_bridge.timeseries_catalog import list_supported_timeseries_types

ToolResult: TypeAlias = BaseModel | str
ToolCaller: TypeAlias = Callable[[Path, JsonMapping], ToolResult]


class McpModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )


class EmptyArgs(McpModel):
    pass


class TimeseriesArgs(McpModel):
    type_codes: list[str]
    start_time: UtcTimestamp
    end_time: UtcTimestamp

    @model_validator(mode="after")
    def require_ordered_interval(self) -> Self:
        if utc_datetime(self.start_time) > utc_datetime(self.end_time):
            message = "start_time must not be after end_time"
            raise ValueError(message)
        return self


class SupportedTimeseriesArgs(McpModel):
    category: str | None = None


class DateRangeArgs(McpModel):
    start_date: str
    end_date: str

    @field_validator("start_date", "end_date")
    @classmethod
    def require_iso_date(cls, value: str) -> str:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value) is None:
            message = "date must use YYYY-MM-DD"
            raise ValueError(message)
        _ = date.fromisoformat(value)
        return value

    @model_validator(mode="after")
    def require_ordered_dates(self) -> Self:
        if date.fromisoformat(self.start_date) > date.fromisoformat(self.end_date):
            message = "start_date must not be after end_date"
            raise ValueError(message)
        return self


@dataclass(frozen=True, slots=True)
class ToolDefinition:
    name: str
    description: str
    input_schema: JsonMapping


EMPTY_INPUT_SCHEMA: Final[JsonObject] = {
    "type": "object",
    "properties": {},
    "additionalProperties": False,
}
DATE_RANGE_INPUT_SCHEMA: Final[JsonObject] = {
    "type": "object",
    "properties": {
        "start_date": {
            "type": "string",
            "format": "date",
            "pattern": r"^\d{4}-\d{2}-\d{2}$",
            "description": (
                "Inclusive start date (YYYY-MM-DD), at 00:00:00 UTC for "
                "start-time filtering. Daily samples use calendar_day metadata "
                "when present, otherwise their UTC start date."
            ),
        },
        "end_date": {
            "type": "string",
            "format": "date",
            "pattern": r"^\d{4}-\d{2}-\d{2}$",
            "description": (
                "Exclusive end date (YYYY-MM-DD), at 00:00:00 UTC for "
                "start-time filtering; this calendar day is not included. "
                "Must be on or after start_date; equal dates give an empty range."
            ),
        },
    },
    "required": ["start_date", "end_date"],
    "additionalProperties": False,
}
TIMESERIES_INPUT_SCHEMA: Final[JsonObject] = {
    "type": "object",
    "properties": {
        "type_codes": {
            "type": "array",
            "items": {"type": "string"},
            "description": (
                "Sample type codes, e.g. steps, heart_rate, weight, energy. "
                "Discover vocabulary with list_supported_timeseries_types and "
                "local record counts with list_synced_metrics. Legacy body_mass "
                "and active_energy aliases are accepted. Unmatched codes yield "
                "no points; an empty list returns none. Use dedicated tools for "
                "workout and sleep_analysis sessions."
            ),
        },
        "start_time": {
            "type": "string",
            "format": "date-time",
            "pattern": UTC_TIMESTAMP_PATTERN,
            "description": (
                "Inclusive sample start-time lower bound in UTC, "
                "YYYY-MM-DDTHH:MM:SSZ (no offsets or fractional seconds); "
                "runtime validation also rejects "
                "nonexistent calendar dates."
            ),
        },
        "end_time": {
            "type": "string",
            "format": "date-time",
            "pattern": UTC_TIMESTAMP_PATTERN,
            "description": (
                "Exclusive sample start-time upper bound in UTC, "
                "YYYY-MM-DDTHH:MM:SSZ (no offsets or fractional seconds); "
                "must be on or after start_time. Equal timestamps give an empty "
                "range; runtime validation also rejects nonexistent calendar dates."
            ),
        },
    },
    "required": ["type_codes", "start_time", "end_time"],
    "additionalProperties": False,
}
SUPPORTED_TIMESERIES_INPUT_SCHEMA: Final[JsonObject] = {
    "type": "object",
    "properties": {
        "category": {
            "type": "string",
            "description": (
                "Optional exact, case-sensitive category filter, e.g. heart, "
                "activity, body. Omit to discover all categories in types[].category; "
                "an unknown category returns an empty types list."
            ),
        },
    },
    "additionalProperties": False,
}
MCP_TOOL_DEFINITIONS: Final[tuple[ToolDefinition, ...]] = (
    ToolDefinition(
        name="get_bridge_status",
        description=(
            "Read-only operational snapshot as JSON text: store counts, latest "
            "sync, receiver token presence, and per-metric freshness. Use to "
            "check sync health or data coverage before querying observations. "
            "Omits sample values, cursor values, and token material."
        ),
        input_schema=EMPTY_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_bridge_context_markdown",
        description=(
            "Read-only Markdown rendering of get_bridge_status for assistant "
            "context or a wiki. Choose get_bridge_status for machine-readable "
            "fields. Includes counts and sync freshness, not sample values, "
            "cursor values, or token material."
        ),
        input_schema=EMPTY_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="list_supported_timeseries_types",
        description=(
            "Read-only static catalog of timeseries type codes, categories, units, "
            "aggregation rules, and iOS support status. Use to choose type_codes "
            "for get_timeseries; omit category to discover filters. Catalog "
            "support does not imply permission or local records: check "
            "list_synced_metrics for availability. Does not read health values."
        ),
        input_schema=SUPPORTED_TIMESERIES_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="list_synced_metrics",
        description=(
            "Read-only local metric catalog with record counts, units, sensitivity, "
            "and source provenance. Use to discover stored types before querying; "
            "catalog entries can have zero records. Use get_workouts and "
            "get_sleep_summary for workout and sleep_analysis sessions. Missing "
            "records mean unknown availability, not zero activity."
        ),
        input_schema=EMPTY_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_timeseries",
        description=(
            "Read-only stored sample observations with units, metadata, and source "
            "provenance. Selects start_time >= the inclusive UTC lower bound and "
            "start_time < the exclusive upper bound, not interval overlap; "
            "sample end times are not clipped. Returns at most 500 points in "
            "start-time order; check truncated and missing_data_notes. "
            "Receiver-owned projection_status distinguishes current, last_known "
            "and unknown daily projections; raw points have no projection status. "
            "No clinical interpretation."
        ),
        input_schema=TIMESERIES_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_workouts",
        description=(
            "Read-only workout sessions with source provenance for "
            "[start_date, end_date) at UTC midnight. Selects by workout start: "
            "earlier overlapping workouts are excluded; selected workouts keep "
            "their full duration even beyond end_date. Returns at most 500 "
            "workouts in start-time order; check truncated and missing_data_notes."
        ),
        input_schema=DATE_RANGE_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_sleep_summary",
        description=(
            "Read-only session count and summed seconds per sleep stage with "
            "source provenance for [start_date, end_date) at UTC midnight. "
            "Selects by session start, not wake date or overlap: earlier "
            "overlapping sessions are excluded. Selected sessions contribute "
            "all stage intervals without clipping or overlap deduplication. "
            "Check missing_data_notes; stage totals have no clinical interpretation."
        ),
        input_schema=DATE_RANGE_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_latest_sleep_period",
        description=(
            "Read-only latest observed sleep period ending by reference_time in a "
            "seven-local-date window in timezone. Joins overlapping/touching session "
            "envelopes across sources; ongoing groups excluded, naps included. "
            "Returns UTC/local timestamps, clipped stage evidence and core/deep/rem "
            "elapsed union, with awake/in_bed separate. No physiological completion "
            "or source priority. At most 500 candidate sessions and 500 selected "
            "stage intervals; check truncated and missing_data_notes."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "timezone": {
                    "type": "string",
                    "description": (
                        "IANA timezone key, e.g. Asia/Kolkata; "
                        "must be available locally."
                    ),
                },
                "reference_time": {
                    "type": "string",
                    "format": "date-time",
                    "pattern": UTC_TIMESTAMP_PATTERN,
                    "description": (
                        "Inclusive observed-end cutoff in UTC YYYY-MM-DDTHH:MM:SSZ. "
                        "Required; no implicit clock. Runtime validates calendar "
                        "dates and representable local window."
                    ),
                },
            },
            "required": ["timezone", "reference_time"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="get_daily_summary",
        description=(
            "Read-only daily observations for [start_date, end_date). Samples "
            "group by calendar_day metadata when present, otherwise UTC start "
            "date; calendar_day can include samples starting outside the UTC "
            "range. Workouts and sleep sessions count on their UTC start date, "
            "not overlap or wake date. Returns sum-safe sample_totals and "
            "type-aware sample_statistics; inspect sample_total_semantics before "
            "treating sums as daily activity. daily_activity_totals requires "
            "completed calendar-day coverage and includes only current projections. "
            "Retained statistics carry receiver-owned projection_status "
            "(current, last_known or unknown) separately from calendar coverage; "
            "raw sums may overlap projections. Empty days do not prove zero "
            "activity; consult source provenance and missing_data_notes. "
            "No clinical interpretation."
        ),
        input_schema=DATE_RANGE_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_sleep_report",
        description=(
            "Recommended read-only daily sleep briefing: all received observed periods "
            "ending on a local wake-date, retaining fragmented sleep and naps. "
            "No older-date fallback or main-sleep classification. Returns recorded "
            "overlap-safe asleep contributions, separate awake/in_bed claims, "
            "coverage and omission counts. Complete connected membership is required; "
            "global 500-session/stage caps withhold results on exhaustion. "
            "Use include_intervals for calculation evidence; "
            "not biological total sleep."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "required": ["timezone"],
            "properties": {
                "timezone": {
                    "type": "string",
                    "description": "Available IANA timezone key.",
                },
                "local_date": {
                    "type": ["string", "null"],
                    "format": "date",
                    "pattern": r"^\d{4}-\d{2}-\d{2}$",
                    "description": (
                        "Wake-date YYYY-MM-DD; omit or null for reference's local "
                        "date. No older-day fallback."
                    ),
                },
                "reference_time": {
                    "type": "string",
                    "format": "date-time",
                    "pattern": UTC_TIMESTAMP_PATTERN,
                    "description": (
                        "UTC observed-end cutoff YYYY-MM-DDTHH:MM:SSZ; "
                        "omit to capture current UTC once."
                    ),
                },
                "include_intervals": {
                    "type": "boolean",
                    "default": False,
                    "description": (
                        "Include bounded sessions, clipped stages and merged "
                        "asleep evidence; otherwise evidence is null."
                    ),
                },
            },
        },
    ),
    ToolDefinition(
        name="explain_sources",
        description=(
            "Read-only source provenance: source names, kinds, bundle IDs, device "
            "models, and sync cursor kinds/update times, without cursor values. "
            "Use to identify which app/device supplied records or investigate "
            "source gaps; use get_bridge_status for receiver and sync health. "
            "Includes missing-data caveats, not sample values."
        ),
        input_schema=EMPTY_INPUT_SCHEMA,
    ),
)
TOOL_ARGUMENT_MODELS: Final[dict[str, type[BaseModel]]] = {
    "get_bridge_status": EmptyArgs,
    "get_bridge_context_markdown": EmptyArgs,
    "list_supported_timeseries_types": SupportedTimeseriesArgs,
    "list_synced_metrics": EmptyArgs,
    "get_timeseries": TimeseriesArgs,
    "get_workouts": DateRangeArgs,
    "get_sleep_summary": DateRangeArgs,
    "get_latest_sleep_period": LatestSleepArgs,
    "get_sleep_report": SleepReportArgs,
    "get_daily_summary": DateRangeArgs,
    "explain_sources": EmptyArgs,
}


def _call_bridge_status(db_path: Path, _args: JsonMapping) -> BaseModel:
    return read_status_snapshot(db_path)


def _call_bridge_context_markdown(db_path: Path, _args: JsonMapping) -> str:
    return read_status_markdown(db_path)


def _call_supported_timeseries_types(
    _db_path: Path,
    args: JsonMapping,
) -> BaseModel:
    parsed = SupportedTimeseriesArgs.model_validate(args)
    return list_supported_timeseries_types(category=parsed.category)


def _call_list_synced_metrics(db_path: Path, _args: JsonMapping) -> BaseModel:
    return list_synced_metrics(db_path)


def _call_timeseries(db_path: Path, args: JsonMapping) -> BaseModel:
    parsed = TimeseriesArgs.model_validate(args)
    return get_timeseries(
        db_path,
        type_codes=tuple(parsed.type_codes),
        start_time=parsed.start_time,
        end_time=parsed.end_time,
    )


def _call_workouts(db_path: Path, args: JsonMapping) -> BaseModel:
    parsed = DateRangeArgs.model_validate(args)
    return get_workouts(db_path, start_date=parsed.start_date, end_date=parsed.end_date)


def _call_sleep_summary(db_path: Path, args: JsonMapping) -> BaseModel:
    parsed = DateRangeArgs.model_validate(args)
    return get_sleep_summary(
        db_path,
        start_date=parsed.start_date,
        end_date=parsed.end_date,
    )


def _call_daily_summary(db_path: Path, args: JsonMapping) -> BaseModel:
    parsed = DateRangeArgs.model_validate(args)
    return get_daily_summary(
        db_path,
        start_date=parsed.start_date,
        end_date=parsed.end_date,
    )


def _call_latest_sleep_period(db_path: Path, args: JsonMapping) -> BaseModel:
    return get_latest_sleep_period(db_path, LatestSleepArgs.model_validate(args))


def _call_sleep_report(db_path: Path, args: JsonMapping) -> BaseModel:
    return get_sleep_report(db_path, SleepReportArgs.model_validate(args))


def _call_explain_sources(db_path: Path, _args: JsonMapping) -> BaseModel:
    return explain_sources(db_path)


TOOL_CALLERS: Final[dict[str, ToolCaller]] = {
    "get_bridge_status": _call_bridge_status,
    "get_bridge_context_markdown": _call_bridge_context_markdown,
    "list_supported_timeseries_types": _call_supported_timeseries_types,
    "list_synced_metrics": _call_list_synced_metrics,
    "get_timeseries": _call_timeseries,
    "get_workouts": _call_workouts,
    "get_sleep_summary": _call_sleep_summary,
    "get_latest_sleep_period": _call_latest_sleep_period,
    "get_sleep_report": _call_sleep_report,
    "get_daily_summary": _call_daily_summary,
    "explain_sources": _call_explain_sources,
}

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
    get_sleep_summary,
    get_timeseries,
    get_workouts,
    list_synced_metrics,
)
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
        },
        "end_date": {
            "type": "string",
            "format": "date",
            "pattern": r"^\d{4}-\d{2}-\d{2}$",
        },
    },
    "required": ["start_date", "end_date"],
    "additionalProperties": False,
}
TIMESERIES_INPUT_SCHEMA: Final[JsonObject] = {
    "type": "object",
    "properties": {
        "type_codes": {"type": "array", "items": {"type": "string"}},
        "start_time": {
            "type": "string",
            "format": "date-time",
            "pattern": UTC_TIMESTAMP_PATTERN,
            "description": (
                "Fixed-UTC RFC 3339 lexical form; runtime validation also rejects "
                "nonexistent calendar dates."
            ),
        },
        "end_time": {
            "type": "string",
            "format": "date-time",
            "pattern": UTC_TIMESTAMP_PATTERN,
            "description": (
                "Fixed-UTC RFC 3339 lexical form; runtime validation also rejects "
                "nonexistent calendar dates."
            ),
        },
    },
    "required": ["type_codes", "start_time", "end_time"],
    "additionalProperties": False,
}
SUPPORTED_TIMESERIES_INPUT_SCHEMA: Final[JsonObject] = {
    "type": "object",
    "properties": {"category": {"type": "string"}},
    "additionalProperties": False,
}
MCP_TOOL_DEFINITIONS: Final[tuple[ToolDefinition, ...]] = (
    ToolDefinition(
        name="get_bridge_status",
        description=(
            "Read-only redacted bridge and receiver sync status for local agents; "
            "omits sample values, cursor values, and token material; no clinical "
            "interpretation."
        ),
        input_schema=EMPTY_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_bridge_context_markdown",
        description=(
            "Read-only redacted Markdown bridge context for local agents/wiki; "
            "omits sample values, cursor values, token material, and clinical "
            "interpretation."
        ),
        input_schema=EMPTY_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="list_supported_timeseries_types",
        description=(
            "Read-only supported timeseries type metadata; metadata "
            "only, no local health values, no cursor values, and no clinical "
            "interpretation."
        ),
        input_schema=SUPPORTED_TIMESERIES_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="list_synced_metrics",
        description=(
            "Read-only catalog observation listing synced metric types, provenance, "
            "and missing-data caveats; no clinical interpretation."
        ),
        input_schema=EMPTY_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_timeseries",
        description=(
            "Read-only time-series observations for selected metric types with "
            "source provenance and missing-data caveats; no clinical interpretation."
        ),
        input_schema=TIMESERIES_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_workouts",
        description=(
            "Read-only workout observations for a date range with source provenance "
            "and missing-data caveats; no clinical interpretation."
        ),
        input_schema=DATE_RANGE_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_sleep_summary",
        description=(
            "Read-only sleep-stage summary observations for a date range with "
            "source provenance and missing-data caveats; no clinical interpretation."
        ),
        input_schema=DATE_RANGE_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="get_daily_summary",
        description=(
            "Read-only daily observation summaries for a date range with source "
            "provenance, missing-data caveats, sum-safe sample_totals, and "
            "type-aware sample_statistics for non-summable metrics; no clinical "
            "interpretation."
        ),
        input_schema=DATE_RANGE_INPUT_SCHEMA,
    ),
    ToolDefinition(
        name="explain_sources",
        description=(
            "Read-only provenance summary for local sources and sync cursors with "
            "missing-data caveats; no clinical interpretation."
        ),
        input_schema=EMPTY_INPUT_SCHEMA,
    ),
)
TOOL_ARGUMENT_MODELS: Final[dict[str, type[McpModel]]] = {
    "get_bridge_status": EmptyArgs,
    "get_bridge_context_markdown": EmptyArgs,
    "list_supported_timeseries_types": SupportedTimeseriesArgs,
    "list_synced_metrics": EmptyArgs,
    "get_timeseries": TimeseriesArgs,
    "get_workouts": DateRangeArgs,
    "get_sleep_summary": DateRangeArgs,
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
    "get_daily_summary": _call_daily_summary,
    "explain_sources": _call_explain_sources,
}

"""Causal, interval-scoped freshness within existing sample/cursor storage."""

from __future__ import annotations

import json
from datetime import UTC, date, datetime, time, timedelta
from typing import TYPE_CHECKING, ClassVar, Final, TypeAlias, final
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError

from health_bridge.storage.catalog import source_id
from health_bridge.storage.tombstones import record_is_tombstoned
from health_bridge.timeseries_catalog import (
    canonical_deleted_sample_client_record_id,
    canonical_sample_client_record_id,
    canonical_sample_type_code,
)

if TYPE_CHECKING:
    import sqlite3

    from health_bridge.contract import HealthBridgeBatchV1
    from health_bridge.contract.batch_v1 import Sample


OBSERVATION_PREFIX: Final = "daily_projection_observation:"
STATE_KEY: Final = "_bridge_daily_projection"
RAW_ORDER_KEY: Final = "_bridge_raw_observation"
INDEX_PREFIX: Final = "daily_projection_raw_interval:"
BASELINE_PREFIX: Final = "daily_projection_raw_coverage:"
UNRESOLVED_PREFIX: Final = "daily_projection_unresolved:"


class Interval(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(strict=True, extra="forbid")
    start_time: str
    end_time: str


class RawInterval(Interval):
    client_record_id: str


class Observation(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(strict=True, extra="forbid")
    namespace: str = Field(min_length=1, max_length=128)
    sequence: int = Field(ge=1, le=18_446_744_073_709_551_615)
    type_code: str
    raw_intervals: list[RawInterval] = Field(default_factory=list)
    raw_baseline: Interval | None = None
    statistics_window: Interval | None = None

    def order(self) -> dict[str, object]:
        return {"namespace": self.namespace, "sequence": self.sequence}


def _interval(start: str, end: str) -> tuple[datetime, datetime] | None:
    try:
        first, last = datetime.fromisoformat(start), datetime.fromisoformat(end)
    except ValueError:
        return None
    if first.tzinfo is None or last.tzinfo is None or first > last:
        return None
    return first.astimezone(UTC), last.astimezone(UTC)


def projection_interval(
    start: str, end: str, metadata: dict[str, object]
) -> tuple[datetime, datetime] | None:
    if (
        metadata.get("sample_kind") != "daily_aggregate"
        or metadata.get("aggregation") != "daily_sum"
        or metadata.get("aggregation_completeness") != "complete"
        or metadata.get("source_resolution") != "healthkit_statistics_merged_sources"
    ):
        return None
    day, zone = metadata.get("calendar_day"), metadata.get("time_zone_identifier")
    if not isinstance(day, str) or not isinstance(zone, str):
        return None
    return completed_day_interval(start, end, day, zone)


def completed_day_interval(
    start_time: str, end_time: str, calendar_day: str, zone_identifier: str
) -> tuple[datetime, datetime] | None:
    """Validate exact calendar coverage independently of projection confidence."""
    try:
        day = date.fromisoformat(calendar_day)
        if day.isoformat() != calendar_day:
            return None
        zone = ZoneInfo(zone_identifier)
        start = datetime.combine(day, time.min, tzinfo=zone).astimezone(UTC)
        end = datetime.combine(
            day + timedelta(days=1), time.min, tzinfo=zone
        ).astimezone(UTC)
        # Round trips reject skipped days and boundaries that are not the first
        # instant of the local day, including unusual midnight transitions.
        if (
            start >= end
            or start.astimezone(zone).date() != day
            or (start - timedelta(microseconds=1)).astimezone(zone).date() >= day
            or (end - timedelta(microseconds=1)).astimezone(zone).date() != day
            or end.astimezone(zone).date() <= day
        ):
            return None
    except (ValueError, OverflowError, ZoneInfoNotFoundError):
        return None
    if (start_time, end_time) != (
        start.isoformat(timespec="seconds").replace("+00:00", "Z"),
        end.isoformat(timespec="seconds").replace("+00:00", "Z"),
    ):
        return None
    return start, end


NAMESPACES: Final = TypeAdapter(list[str])


def _namespaces(value: object) -> list[str]:
    try:
        return NAMESPACES.validate_python(value)
    except ValidationError:
        return []


JSON_ADAPTER: Final = TypeAdapter(dict[str, object])
CURSOR_ROW: Final[TypeAdapter[tuple[str] | None]] = TypeAdapter(tuple[str] | None)
SAMPLE_ROW: Final[TypeAdapter[tuple[str, str, str, float, str] | None]] = TypeAdapter(
    tuple[str, str, str, float, str] | None
)
PROJECTION_ROWS: Final = TypeAdapter(list[tuple[str, str, str, str]])
Preimage: TypeAlias = tuple[str, str, str, float, dict[str, object]]


def _map(value: object) -> dict[str, object]:
    try:
        return JSON_ADAPTER.validate_python(value)
    except ValidationError:
        return {}


def _json(value: str | None) -> dict[str, object]:
    try:
        return JSON_ADAPTER.validate_json(value or "{}")
    except ValidationError:
        return {}


def projection_status(
    metadata: dict[str, object], unresolved: str | None = None
) -> str:
    state = _map(metadata.get(STATE_KEY))
    status = state.get("status")
    status = (
        status
        if isinstance(status, str)
        and status in {"fresh", "stale", "unknown", "legacy_unknown"}
        else "legacy_unknown"
    )
    marker = _map(_json(unresolved).get("order"))
    order = _map(state.get("order"))
    if status == "fresh" and marker and marker != state.get("unresolved_order"):
        sequence, observed = marker.get("sequence"), order.get("sequence")
        if marker.get("namespace") != order.get("namespace") or (
            isinstance(sequence, int)
            and isinstance(observed, int)
            and sequence > observed
        ):
            return "unknown"
    return status


def _cursor(
    connection: sqlite3.Connection, source: int, kind: str
) -> dict[str, object]:
    row = CURSOR_ROW.validate_python(
        connection.execute(
            "select cursor_value from sync_cursors where source_id=? and cursor_kind=?",
            (source, kind),
        ).fetchone()
    )
    return _json(row[0]) if row else {}


def _save_cursor(
    connection: sqlite3.Connection, source: int, kind: str, value: dict[str, object]
) -> None:
    _ = connection.execute(
        (
            "insert into sync_cursors (source_id,cursor_kind,cursor_value) "
            "values (?,?,?) on conflict(source_id,cursor_kind) do update set "
            "cursor_value=excluded.cursor_value"
        ),
        (source, kind, json.dumps(value, sort_keys=True, separators=(",", ":"))),
    )


def _newer(observation: Observation, previous: object, *, equal: bool = False) -> bool:
    previous = _map(previous)
    if not previous:
        return True
    sequence = previous.get("sequence")
    return (
        previous.get("namespace") == observation.namespace
        and isinstance(sequence, int)
        and (
            observation.sequence >= sequence
            if equal
            else observation.sequence > sequence
        )
    )


def _overlaps(
    left: tuple[datetime, datetime], right: tuple[datetime, datetime]
) -> bool:
    if right[0] == right[1]:
        return left[0] <= right[0] < left[1]
    return left[0] < right[1] and right[0] < left[1]


def _deletion_matches_type(identifier: str, type_code: str) -> bool:
    identifier = canonical_deleted_sample_client_record_id(identifier)
    if identifier.startswith("hk-step-sample-"):
        return type_code == "steps"
    if identifier.startswith("hk-quantity-"):
        return identifier.startswith("hk-quantity-" + type_code.replace("_", "-") + "-")
    return True


def observations(batch: HealthBridgeBatchV1) -> dict[tuple[int, str], Observation]:
    # The source component is resolved by the transaction caller below.
    result: dict[tuple[int, str], Observation] = {}
    for index, cursor in enumerate(batch.sync.cursors):
        if not cursor.cursor_kind.startswith(OBSERVATION_PREFIX):
            continue
        try:
            observation = Observation.model_validate_json(cursor.cursor_value)
        except ValidationError:
            continue
        type_code = canonical_sample_type_code(observation.type_code)
        if (
            canonical_sample_type_code(cursor.cursor_kind[len(OBSERVATION_PREFIX) :])
            != type_code
        ):
            continue
        result[index, type_code] = observation
    return result


@final
class DailyProjectionIngest:
    """Transaction-local adapter; durable ownership stays in SQLite records/cursors."""

    def __init__(
        self, connection: sqlite3.Connection, batch: HealthBridgeBatchV1
    ) -> None:
        self.connection = connection
        self.batch = batch
        self.by_source_type = {
            (
                source_id(connection, batch.sync.cursors[index].source_key),
                type_code,
            ): observation
            for (index, type_code), observation in observations(batch).items()
        }
        identifiers = {
            (
                source_id(connection, sample.source_key),
                canonical_sample_client_record_id(
                    sample.type_code, sample.client_record_id
                ),
            )
            for sample in batch.samples
        } | {
            (source_id(connection, deleted.source_key), deleted.client_record_id)
            for deleted in batch.deleted_records
            if deleted.record_family == "sample"
        }
        self.rejected: set[tuple[int, str]] = set()
        self.old: dict[tuple[int, str], Preimage] = {}
        for source, identifier in identifiers:
            row = SAMPLE_ROW.validate_python(
                connection.execute(
                    (
                        "select type_code,start_time,end_time,value,metadata_json "
                        "from samples "
                        "where source_id=? and client_record_id=?"
                    ),
                    (source, identifier),
                ).fetchone()
            )
            if row is not None:
                self.old[source, identifier] = (*row[:4], _json(row[4]))

    def _invalidate(
        self,
        source: int,
        type_code: str,
        interval: tuple[datetime, datetime],
        observation: Observation | None,
        status: str = "stale",
    ) -> None:
        rows = PROJECTION_ROWS.validate_python(
            self.connection.execute(
                (
                    "select client_record_id,start_time,end_time,metadata_json "
                    "from samples "
                    "where source_id=? and type_code=? "
                    "and json_extract(metadata_json, '$.sample_kind')='daily_aggregate'"
                ),
                (source, type_code),
            ).fetchall()
        )
        for row in rows:
            metadata = _json(row[3])
            daily = projection_interval(row[1], row[2], metadata)
            if daily is None or not _overlaps(daily, interval):
                continue
            previous = _map(metadata.get(STATE_KEY))
            if observation is not None and not self._accept_order(
                source, type_code, observation, previous.get("order")
            ):
                continue
            metadata[STATE_KEY] = {
                "status": status,
                "order": observation.order()
                if observation
                else previous.get("order", {}),
                "reason": "raw_mutation" if status == "stale" else "statistics_unknown",
            }
            _ = self.connection.execute(
                (
                    "update samples set metadata_json=? "
                    "where source_id=? and client_record_id=?"
                ),
                (json.dumps(metadata, sort_keys=True), source, row[0]),
            )

    def _register_lineages(self) -> None:
        for (source, type_code), observation in self.by_source_type.items():
            prior = _cursor(self.connection, source, BASELINE_PREFIX + type_code)
            prior_order = _map(prior.get("order"))
            namespace = prior_order.get("namespace")
            retired = _namespaces(prior.get("retired_namespaces"))
            window = observation.statistics_window
            has_scope = bool(
                observation.raw_baseline
                or observation.raw_intervals
                or (window and _interval(window.start_time, window.end_time))
                or any(
                    deletion.record_family == "sample"
                    and source_id(self.connection, deletion.source_key) == source
                    and _deletion_matches_type(deletion.client_record_id, type_code)
                    for deletion in self.batch.deleted_records
                )
            )
            if observation.namespace in retired or (
                namespace is not None
                and namespace != observation.namespace
                and not has_scope
            ):
                self.rejected.add((source, type_code))
                continue
            baseline = observation.raw_baseline
            if (
                (namespace != observation.namespace and has_scope)
                or (baseline and _interval(baseline.start_time, baseline.end_time))
            ) and (
                namespace != observation.namespace or _newer(observation, prior_order)
            ):
                if isinstance(namespace, str) and namespace != observation.namespace:
                    retired = [*retired, namespace]
                _save_cursor(
                    self.connection,
                    source,
                    BASELINE_PREFIX + type_code,
                    {
                        **(baseline.model_dump() if baseline else {}),
                        "order": observation.order(),
                        "retired_namespaces": retired,
                    },
                )
        self.by_source_type = {
            key: value
            for key, value in self.by_source_type.items()
            if key not in self.rejected
        }

    def _accept_order(
        self,
        source: int,
        type_code: str,
        observation: Observation | None,
        previous: object,
    ) -> bool:
        if observation is None:
            return not _map(previous)
        if _newer(observation, previous):
            return True
        prior_namespace = _map(previous).get("namespace")
        baseline = _cursor(self.connection, source, BASELINE_PREFIX + type_code)
        return (
            _map(baseline.get("order")).get("namespace") == observation.namespace
            and prior_namespace != observation.namespace
            and prior_namespace in _namespaces(baseline.get("retired_namespaces"))
        )

    def prepare(self) -> None:
        self._register_lineages()
        self._prepare_raw_samples()
        self._index_raw_intervals()
        self._prepare_deletions()
        self._prepare_statistics()

    def _prepare_raw_samples(self) -> None:
        for sample in self.batch.samples:
            if sample.metadata.get("sample_kind") != "raw_quantity":
                continue
            source = source_id(self.connection, sample.source_key)
            type_code = canonical_sample_type_code(sample.type_code)
            identifier = canonical_sample_client_record_id(
                sample.type_code, sample.client_record_id
            )
            if (source, type_code) in self.rejected:
                continue
            old = self.old.get((source, identifier))
            observation = self.by_source_type.get((source, type_code))
            if old and not self._accept_order(
                source, type_code, observation, old[4].get(RAW_ORDER_KEY)
            ):
                continue
            if old and (old[1], old[2], old[3]) == (
                sample.start_time,
                sample.end_time,
                sample.value,
            ):
                continue
            for interval in ([(_interval(old[1], old[2]))] if old else []) + [
                _interval(sample.start_time, sample.end_time)
            ]:
                if interval:
                    self._invalidate(source, type_code, interval, observation)

    def _index_raw_intervals(self) -> None:
        for (source, type_code), observation in self.by_source_type.items():
            for incoming in observation.raw_intervals:
                identifier = canonical_sample_client_record_id(
                    type_code, incoming.client_record_id
                )
                old_index = _cursor(self.connection, source, INDEX_PREFIX + identifier)
                if not self._accept_order(
                    source, type_code, observation, old_index.get("order")
                ):
                    continue
                if old_index and (
                    old_index.get("start_time"),
                    old_index.get("end_time"),
                ) != (incoming.start_time, incoming.end_time):
                    interval = _interval(
                        str(old_index.get("start_time", "")),
                        str(old_index.get("end_time", "")),
                    )
                    if interval:
                        self._invalidate(source, type_code, interval, observation)
                interval = _interval(incoming.start_time, incoming.end_time)
                if (
                    interval
                    and (old_index.get("start_time"), old_index.get("end_time"))
                    != (incoming.start_time, incoming.end_time)
                    and identifier
                    not in {s.client_record_id for s in self.batch.samples}
                ):
                    self._invalidate(source, type_code, interval, observation)
                _save_cursor(
                    self.connection,
                    source,
                    INDEX_PREFIX + identifier,
                    {
                        "start_time": incoming.start_time,
                        "end_time": incoming.end_time,
                        "type_code": type_code,
                        "order": observation.order(),
                    },
                )

    def _prepare_deletions(self) -> None:
        for deletion in self.batch.deleted_records:
            if deletion.record_family != "sample":
                continue
            source = source_id(self.connection, deletion.source_key)
            if record_is_tombstoned(
                self.connection,
                source_id_value=source,
                record_family="sample",
                client_record_id=deletion.client_record_id,
            ):
                continue
            old = self.old.get((source, deletion.client_record_id))
            index = _cursor(
                self.connection, source, INDEX_PREFIX + deletion.client_record_id
            )
            type_code = old[0] if old else index.get("type_code")
            if not isinstance(type_code, str):
                # Unknown day scope changes query confidence, never a day row.
                self._note_unresolved(source, deletion.client_record_id)
                continue
            type_code = canonical_sample_type_code(type_code)
            if (source, type_code) in self.rejected:
                continue
            observation = self.by_source_type.get((source, type_code))
            interval = (
                _interval(old[1], old[2])
                if old
                else _interval(
                    str(index.get("start_time", "")), str(index.get("end_time", ""))
                )
            )
            if interval:
                self._invalidate(source, type_code, interval, observation)
                if observation and self._accept_order(
                    source, type_code, observation, index.get("order")
                ):
                    _save_cursor(
                        self.connection,
                        source,
                        INDEX_PREFIX + deletion.client_record_id,
                        {
                            "start_time": interval[0].isoformat(),
                            "end_time": interval[1].isoformat(),
                            "type_code": type_code,
                            "order": observation.order(),
                        },
                    )

    def _note_unresolved(self, source: int, identifier: str) -> None:
        types = TypeAdapter(list[tuple[str]]).validate_python(
            self.connection.execute(
                (
                    "select distinct type_code from samples where source_id=? "
                    "and json_extract(metadata_json, '$.sample_kind')='daily_aggregate'"
                ),
                (source,),
            ).fetchall()
        )
        for (stored_type,) in types:
            candidate_type = canonical_sample_type_code(stored_type)
            if (
                (source, candidate_type) in self.by_source_type
                or (source, candidate_type) in self.rejected
                or not _deletion_matches_type(identifier, candidate_type)
            ):
                continue
            # Without an observation order, invalidate existing confidence only;
            # never infer a deletion day, raw interval, or causal sequence.
            _ = self.connection.execute(
                (
                    "update samples set metadata_json=json_set(metadata_json,?,?,?,?) "
                    "where source_id=? and type_code=? "
                    "and json_extract(metadata_json, '$.sample_kind')='daily_aggregate'"
                ),
                (
                    f"$.{STATE_KEY}.status",
                    "unknown",
                    f"$.{STATE_KEY}.reason",
                    "raw_scope_unknown",
                    source,
                    stored_type,
                ),
            )
        for (
            candidate_source,
            candidate_type,
        ), observation in self.by_source_type.items():
            if candidate_source == source and _deletion_matches_type(
                identifier, candidate_type
            ):
                prior = _cursor(
                    self.connection, source, UNRESOLVED_PREFIX + candidate_type
                )
                if self._accept_order(
                    source, candidate_type, observation, prior.get("order")
                ):
                    _save_cursor(
                        self.connection,
                        source,
                        UNRESOLVED_PREFIX + candidate_type,
                        {
                            "status": "unresolved_scope",
                            "order": observation.order(),
                        },
                    )

    def _scoped_raw_precedes(
        self,
        source: int,
        type_code: str,
        interval: tuple[datetime, datetime],
        observation: Observation,
    ) -> bool:
        rows = TypeAdapter(list[tuple[str]]).validate_python(
            self.connection.execute(
                (
                    "select cursor_value from sync_cursors where source_id=? "
                    "and cursor_kind like ? "
                    "and json_extract(cursor_value, '$.type_code')=?"
                ),
                (source, INDEX_PREFIX + "%", type_code),
            ).fetchall()
        )
        for row in rows:
            evidence = _json(row[0])
            raw = _interval(
                str(evidence.get("start_time", "")), str(evidence.get("end_time", ""))
            )
            if (
                raw
                and _overlaps(interval, raw)
                and not (
                    _newer(observation, evidence.get("order"), equal=True)
                    or self._accept_order(
                        source, type_code, observation, evidence.get("order")
                    )
                )
            ):
                return False
        return True

    def _prepare_statistics(self) -> None:
        # A successful statistics read may have unknown buckets. It does not prove zero.
        for (source, type_code), observation in self.by_source_type.items():
            window = observation.statistics_window
            if window and (interval := _interval(window.start_time, window.end_time)):
                self._invalidate(source, type_code, interval, observation, "unknown")

    def metadata(self, sample: Sample) -> dict[str, object] | None:
        source = source_id(self.connection, sample.source_key)
        type_code = canonical_sample_type_code(sample.type_code)
        identifier = canonical_sample_client_record_id(
            sample.type_code, sample.client_record_id
        )
        old = self.old.get((source, identifier))
        observation = self.by_source_type.get((source, type_code))
        if (source, type_code) in self.rejected or (
            old and observation is None and _map(old[4].get(STATE_KEY)).get("order")
        ):
            return None
        metadata: dict[str, object] = {
            key: value
            for key, value in sample.metadata.items()
            if key not in {STATE_KEY, RAW_ORDER_KEY}
        }
        if metadata.get("sample_kind") == "raw_quantity":
            if old and not self._accept_order(
                source, type_code, observation, old[4].get(RAW_ORDER_KEY)
            ):
                return None
            if observation:
                metadata[RAW_ORDER_KEY] = observation.order()
            return metadata
        if metadata.get("sample_kind") != "daily_aggregate":
            return metadata
        interval = projection_interval(sample.start_time, sample.end_time, metadata)
        if (
            old
            and observation
            and not self._accept_order(
                source, type_code, observation, _map(old[4].get(STATE_KEY)).get("order")
            )
        ):
            return None
        unresolved_order = _map(
            _cursor(self.connection, source, UNRESOLVED_PREFIX + type_code).get("order")
        )
        window = observation.statistics_window if observation else None
        statistics = _interval(window.start_time, window.end_time) if window else None
        fresh = (
            observation is not None
            and interval is not None
            and statistics is not None
            and statistics[0] <= interval[0] < interval[1] <= statistics[1]
            and sample.value >= 0
            and self._scoped_raw_precedes(source, type_code, interval, observation)
            and (
                unresolved_order.get("namespace") != observation.namespace
                or _newer(observation, unresolved_order, equal=True)
            )
        )
        metadata[STATE_KEY] = {
            "status": "fresh" if fresh else "legacy_unknown",
            "order": observation.order() if observation else {},
            "unresolved_order": unresolved_order if fresh else {},
            "reason": "authoritative_statistics"
            if fresh
            else "causal_coverage_unknown",
        }
        return metadata

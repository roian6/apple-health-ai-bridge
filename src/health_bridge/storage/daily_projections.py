import hashlib
import json
import math
import sqlite3
from typing import ClassVar, Final, Literal, Self

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, model_validator

from health_bridge.contract.batch_v1 import (
    DeletedRecord,
    HealthBridgeBatchV1,
    Sample,
    SyntheticRecordId,
    TimeWindow,
)
from health_bridge.queries.calendar_coverage import completed_day_interval
from health_bridge.storage.catalog import source_id
from health_bridge.storage.tombstones import record_is_tombstoned
from health_bridge.timeseries_catalog import (
    canonical_deleted_sample_client_record_id,
    canonical_sample_client_record_id,
    canonical_sample_type_code,
    compatible_deleted_sample_client_record_ids,
)

OBSERVATION_PREFIX: Final = "daily_projection_observation:"
ProjectionStatus = Literal["current", "last_known", "unknown"]


class ProjectionObservationInvalidError(ValueError):
    pass


class RawInterval(TimeWindow):
    client_record_id: SyntheticRecordId


class Observation(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, strict=True, extra="forbid"
    )
    namespace: str = Field(min_length=1, max_length=128)
    sequence: int = Field(ge=1, le=18_446_744_073_709_551_615)
    type_code: str
    raw_intervals: tuple[RawInterval, ...] = ()
    statistics_window: TimeWindow | None = None

    @model_validator(mode="after")
    def require_unique_intervals(self) -> Self:
        identities = [item.client_record_id for item in self.raw_intervals]
        if len(identities) != len(set(identities)):
            message = "duplicate raw observation interval"
            raise ValueError(message)
        return self

    @property
    def order(self) -> str:
        return f"{self.sequence:020d}"


class Record(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)
    type_code: str
    client_record_id: str
    kind: Literal["raw", "daily"]
    namespace: str | None
    sequence: str | None
    fingerprint: str
    start_time: str
    end_time: str
    status: ProjectionStatus


RECORDS: Final = TypeAdapter(list[Record])
FENCES: Final = TypeAdapter(
    list[tuple[str | None, str | None, str | None, str | None, int]]
)
STRING_ROW: Final[TypeAdapter[tuple[str] | None]] = TypeAdapter(tuple[str] | None)
STRING_ROWS: Final = TypeAdapter(list[tuple[str]])
RECORD_ROWS: Final = TypeAdapter(
    list[
        tuple[
            str,
            str,
            Literal["raw", "daily"],
            str | None,
            str | None,
            str,
            str,
            str,
            ProjectionStatus,
        ]
    ]
)
RECORD_SQL: Final = (
    "select type_code, client_record_id, kind, namespace, sequence, fingerprint, "
    "start_time, end_time, status from daily_projection_records where source_id=?"
)


def is_projection(sample: Sample) -> bool:
    return projection_metadata(sample.metadata)


def projection_metadata(metadata: dict[str, str]) -> bool:
    return (
        metadata.get("aggregation") == "daily_sum"
        or metadata.get("sample_kind") == "daily_aggregate"
        or metadata.get("healthkit_query") == "HKStatisticsCollectionQuery"
    )


def _records(
    connection: sqlite3.Connection,
    owner: int,
    code: str = "",
    identity: str = "",
    daily: bool = False,
) -> list[Record]:
    columns = tuple(Record.model_fields)
    sql = RECORD_SQL
    parameters: list[str | int] = [owner]
    if code:
        sql += " and type_code=?"
        parameters.append(code)
    if identity:
        sql += " and client_record_id=?"
        parameters.append(identity)
    if daily:
        sql += " and kind='daily'"
    return RECORDS.validate_python(
        [
            dict(zip(columns, row, strict=True))
            for row in RECORD_ROWS.validate_python(
                connection.execute(sql, parameters).fetchall()
            )
        ]
    )


def _fingerprint(value: Sample | DeletedRecord) -> str:
    payload = value.model_dump(mode="json")
    if isinstance(value, Sample):
        payload["type_code"] = canonical_sample_type_code(value.type_code)
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def parse_observations(
    batch: HealthBridgeBatchV1,
) -> dict[tuple[str, str], Observation]:
    observations: dict[tuple[str, str], Observation] = {}
    for cursor in batch.sync.cursors:
        if not cursor.cursor_kind.startswith(OBSERVATION_PREFIX):
            continue
        observation = Observation.model_validate_json(cursor.cursor_value)
        code = canonical_sample_type_code(observation.type_code)
        key = (cursor.source_key, code)
        if cursor.cursor_kind != OBSERVATION_PREFIX + code or key in observations:
            message = "invalid projection observation scope"
            raise ProjectionObservationInvalidError(message)
        raw = {
            sample.client_record_id: sample
            for sample in batch.samples
            if sample.source_key == cursor.source_key
            and canonical_sample_type_code(sample.type_code) == code
            and not is_projection(sample)
        }
        deleted = {
            item.client_record_id
            for item in batch.deleted_records
            if item.source_key == cursor.source_key and item.record_family == "sample"
        }
        for interval in observation.raw_intervals:
            sample = raw.get(interval.client_record_id)
            if sample is not None:
                if (interval.start_time, interval.end_time) == (
                    sample.start_time,
                    sample.end_time,
                ):
                    continue
            elif interval.client_record_id in deleted:
                continue
            message = "raw observation interval does not match its record"
            raise ProjectionObservationInvalidError(message)
        observations[key] = observation
    return observations


def _comparable(
    connection: sqlite3.Connection,
    owner: int,
    code: str,
    observation: Observation | None,
) -> bool:
    if observation is None:
        return False
    _ = connection.execute(
        "insert into daily_projection_owners values (?, ?, ?) on conflict do nothing",
        (owner, code, observation.namespace),
    )
    row = STRING_ROW.validate_python(
        connection.execute(
            """select namespace from daily_projection_owners
            where source_id=? and type_code=?""",
            (owner, code),
        ).fetchone()
    )
    return row is not None and row[0] == observation.namespace


def _save(connection: sqlite3.Connection, owner: int, record: Record) -> None:
    _ = connection.execute(
        """insert into daily_projection_records values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        on conflict(source_id,type_code,client_record_id) do update set
        kind=excluded.kind, namespace=excluded.namespace, sequence=excluded.sequence,
        fingerprint=excluded.fingerprint, start_time=excluded.start_time,
        end_time=excluded.end_time, status=excluded.status""",
        (owner, *record.model_dump().values()),
    )


def _overlaps(first: str, last: str, start: str | None, end: str | None) -> bool:
    if start is None or end is None:
        return True
    if start == end:
        return first <= start < last
    return first < end and last > start


def _projection_fences(
    connection: sqlite3.Connection, owner: int, code: str
) -> list[tuple[str | None, str | None, str | None, str | None, int]]:
    return FENCES.validate_python(
        connection.execute(
            """select namespace, sequence, start_time, end_time, uncertain
            from daily_projection_fences where source_id=? and type_code=?""",
            (owner, code),
        ).fetchall()
    )


def _has_newer_fence(
    connection: sqlite3.Connection,
    scope: tuple[int, str],
    start: str,
    end: str,
    observation: Observation | None,
) -> bool:
    if observation is None:
        return False
    return (
        connection.execute(
            """select 1 from daily_projection_fences
            where source_id=? and type_code=? and namespace=? and sequence>?
              and (start_time is null or end_time is null
                or (start_time=end_time and ?<=start_time and start_time<?)
                or (start_time<>end_time and ?<end_time and ?>start_time))
            limit 1""",
            (*scope, observation.namespace, observation.order, start, end, start, end),
        ).fetchone()
        is not None
    )


def _fence(
    connection: sqlite3.Connection,
    key: tuple[int, str, str],
    observation: Observation | None,
    intervals: tuple[tuple[str, str], ...],
    *,
    unknown: bool = False,
) -> None:
    owner, code, fingerprint = key
    scope = (owner, code)
    bounds: tuple[tuple[str | None, str | None], ...] = intervals or ((None, None),)
    namespace = observation.namespace if observation else None
    sequence = observation.order if observation else None
    uncertain = int(unknown or observation is None or not intervals)
    if observation is None:
        pinned = STRING_ROW.validate_python(
            connection.execute(
                """select namespace from daily_projection_owners
                where source_id=? and type_code=?""",
                scope,
            ).fetchone()
        )
        if pinned is not None:
            namespace = pinned[0]
            floor = STRING_ROW.validate_python(
                connection.execute(
                    """select coalesce(max(sequence), '00000000000000000000')
                    from daily_projection_records where source_id=? and type_code=?""",
                    scope,
                ).fetchone()
            )
            sequence = floor[0] if floor is not None else None
    event = hashlib.sha256(
        json.dumps([fingerprint, namespace, sequence]).encode()
    ).hexdigest()
    for index, (start, end) in enumerate(bounds):
        _ = connection.execute(
            """insert into daily_projection_fences values (?, ?, ?, ?, ?, ?, ?, ?)
            on conflict do nothing""",
            (
                owner,
                code,
                event + f":{index}",
                namespace,
                sequence,
                start,
                end,
                uncertain,
            ),
        )
    for record in _records(connection, owner, code=code, daily=True):
        if _has_newer_fence(
            connection, scope, record.start_time, record.end_time, observation
        ):
            continue
        if record.kind != "daily" or record.type_code != code:
            continue
        if not any(
            _overlaps(record.start_time, record.end_time, start, end)
            for start, end in bounds
        ):
            continue
        comparable = (
            observation is not None and record.namespace == observation.namespace
        )
        if (
            observation is not None
            and comparable
            and record.sequence is not None
            and record.sequence >= observation.order
        ):
            continue
        status: ProjectionStatus = (
            "last_known" if comparable and intervals and not uncertain else "unknown"
        )
        _save(connection, owner, record.model_copy(update={"status": status}))


def _status(
    connection: sqlite3.Connection,
    owner: int,
    sample: Sample,
    observation: Observation | None,
    comparable: bool,
) -> ProjectionStatus:
    if not comparable or observation is None or observation.statistics_window is None:
        return "unknown"
    window = observation.statistics_window
    if not _completed_sample(sample, window):
        return "unknown"
    fences = _projection_fences(
        connection, owner, canonical_sample_type_code(sample.type_code)
    )
    for namespace, sequence, start, end, uncertain in fences:
        if not _overlaps(sample.start_time, sample.end_time, start, end):
            continue
        if namespace is None:
            continue
        if namespace != observation.namespace:
            return "unknown"
        if sequence is not None and (
            sequence > observation.order
            or (uncertain and sequence == observation.order)
        ):
            return "last_known" if start is not None and not uncertain else "unknown"
    return "current"


def _completed_sample(sample: Sample, window: TimeWindow) -> bool:
    day = sample.metadata.get("calendar_day", sample.start_time[:10])
    zone = sample.metadata.get("time_zone_identifier", "UTC")
    return not (
        not math.isfinite(sample.value)
        or sample.value < 0
        or sample.metadata.get("aggregation_completeness", "complete") != "complete"
        or ("calendar_day" in sample.metadata)
        != ("time_zone_identifier" in sample.metadata)
        or completed_day_interval(sample.start_time, sample.end_time, day, zone) is None
        or sample.start_time < window.start_time
        or sample.end_time > window.end_time
    )


def _without_interval(
    gaps: list[tuple[str, str]], sample: Sample
) -> list[tuple[str, str]]:
    remaining: list[tuple[str, str]] = []
    for start, end in gaps:
        if not _overlaps(start, end, sample.start_time, sample.end_time):
            remaining.append((start, end))
            continue
        if start < sample.start_time:
            remaining.append((start, sample.start_time))
        if sample.end_time < end:
            remaining.append((sample.end_time, end))
    return remaining


def _unknown_windows(
    connection: sqlite3.Connection,
    batch: HealthBridgeBatchV1,
    observations: dict[tuple[str, str], Observation],
) -> None:
    for (source, code), observation in observations.items():
        window = observation.statistics_window
        if window is None:
            continue
        owner = source_id(connection, source)
        _ = _comparable(connection, owner, code, observation)
        gaps = [(window.start_time, window.end_time)]
        for sample in batch.samples:
            if (
                sample.source_key != source
                or canonical_sample_type_code(sample.type_code) != code
                or not is_projection(sample)
                or not _completed_sample(sample, window)
            ):
                continue
            gaps = _without_interval(gaps, sample)
        for start, end in gaps:
            fingerprint = hashlib.sha256(
                (observation.model_dump_json() + start + end).encode()
            ).hexdigest()
            _fence(
                connection,
                (owner, code, fingerprint),
                observation,
                ((start, end),),
                unknown=True,
            )
            for record in _records(connection, owner, code=code, daily=True):
                if _has_newer_fence(
                    connection,
                    (owner, code),
                    record.start_time,
                    record.end_time,
                    observation,
                ):
                    continue
                if _overlaps(record.start_time, record.end_time, start, end) and (
                    record.namespace != observation.namespace
                    or record.sequence is None
                    or record.sequence <= observation.order
                ):
                    _save(
                        connection,
                        owner,
                        record.model_copy(update={"status": "unknown"}),
                    )


def _seen(connection: sqlite3.Connection, owner: int, fingerprint: str) -> bool:
    return (
        connection.execute(
            """select 1 from daily_projection_replays
            where source_id=? and fingerprint=?""",
            (owner, fingerprint),
        ).fetchone()
        is not None
    )


def _remember(connection: sqlite3.Connection, owner: int, fingerprint: str) -> None:
    _ = connection.execute(
        "insert into daily_projection_replays values (?, ?) on conflict do nothing",
        (owner, fingerprint),
    )


def _admit(
    previous: Record | None, observation: Observation | None, comparable: bool
) -> bool:
    if previous is None or previous.sequence is None:
        return True
    return (
        comparable
        and observation is not None
        and previous.namespace == observation.namespace
        and observation.order > previous.sequence
    )


def _sample(
    connection: sqlite3.Connection, sample: Sample, observation: Observation | None
) -> bool:
    owner = source_id(connection, sample.source_key)
    code = canonical_sample_type_code(sample.type_code)
    if any(
        record_is_tombstoned(
            connection,
            source_id_value=owner,
            record_family="sample",
            client_record_id=identity,
        )
        for identity in compatible_deleted_sample_client_record_ids(
            sample.client_record_id
        )
    ):
        return True
    fingerprint = _fingerprint(sample)
    if observation is None and _seen(connection, owner, fingerprint):
        return False
    previous = next(
        iter(_records(connection, owner, code=code, identity=sample.client_record_id)),
        None,
    )
    comparable = _comparable(connection, owner, code, observation)
    daily = is_projection(sample)
    if (
        daily
        and comparable
        and _has_newer_fence(
            connection, (owner, code), sample.start_time, sample.end_time, observation
        )
    ):
        return False
    admitted = _admit(previous, observation, comparable)
    if not admitted:
        if observation is None or not comparable:
            _fence(
                connection,
                (owner, code, fingerprint),
                observation,
                ((sample.start_time, sample.end_time),),
            )
        _remember(connection, owner, fingerprint)
        return False
    if not daily:
        intervals = ((sample.start_time, sample.end_time),)
        if previous is not None:
            intervals += ((previous.start_time, previous.end_time),)
        _fence(connection, (owner, code, fingerprint), observation, intervals)
    _save(
        connection,
        owner,
        Record(
            type_code=code,
            client_record_id=sample.client_record_id,
            kind="daily" if daily else "raw",
            namespace=observation.namespace if observation else None,
            sequence=observation.order if observation else None,
            fingerprint=fingerprint,
            start_time=sample.start_time,
            end_time=sample.end_time,
            status=_status(connection, owner, sample, observation, comparable)
            if daily
            else "unknown",
        ),
    )
    _remember(connection, owner, fingerprint)
    return True


def _delete(
    connection: sqlite3.Connection,
    item: DeletedRecord,
    observations: dict[tuple[str, str], Observation],
) -> bool:
    if item.record_family != "sample":
        return True
    owner = source_id(connection, item.source_key)
    fingerprint = _fingerprint(item)
    previous = _records(connection, owner, identity=item.client_record_id)
    scoped = {
        code: obs for (key, code), obs in observations.items() if key == item.source_key
    }
    codes = (
        {row.type_code for row in previous}
        or set(scoped)
        or {
            row[0]
            for row in STRING_ROWS.validate_python(
                connection.execute(
                    "select distinct type_code from samples where source_id=?", (owner,)
                ).fetchall()
            )
        }
    )
    if not scoped and _seen(connection, owner, fingerprint):
        return False
    admitted = False
    for code in codes:
        observation = scoped.get(code)
        comparable = _comparable(connection, owner, code, observation)
        old = next((row for row in previous if row.type_code == code), None)
        if not _admit(old, observation, comparable):
            if observation is None or not comparable:
                _fence(connection, (owner, code, fingerprint), observation, ())
            continue
        bounds = tuple(
            (row.start_time, row.end_time)
            for row in previous
            if row.type_code == code and row.start_time and row.end_time
        )
        if not bounds and observation:
            bounds = tuple(
                (interval.start_time, interval.end_time)
                for interval in observation.raw_intervals
                if interval.client_record_id == item.client_record_id
            )
        _fence(connection, (owner, code, fingerprint), observation, bounds)
        _save(
            connection,
            owner,
            Record(
                type_code=code,
                client_record_id=item.client_record_id,
                kind=old.kind if old else "raw",
                namespace=observation.namespace if comparable and observation else None,
                sequence=observation.order if comparable and observation else None,
                fingerprint=fingerprint,
                start_time=old.start_time if old else "",
                end_time=old.end_time if old else "",
                status="unknown",
            ),
        )
        admitted = True
    _remember(connection, owner, fingerprint)
    return admitted or not codes


def prepare_batch(
    connection: sqlite3.Connection, batch: HealthBridgeBatchV1
) -> HealthBridgeBatchV1:
    observations = parse_observations(batch)
    samples: list[Sample] = []
    for incoming in sorted(batch.samples, key=is_projection):
        sample = incoming.model_copy(
            update={
                "type_code": canonical_sample_type_code(incoming.type_code),
                "client_record_id": canonical_sample_client_record_id(
                    incoming.type_code, incoming.client_record_id
                ),
            }
        )
        if _sample(
            connection,
            sample,
            observations.get(
                (sample.source_key, canonical_sample_type_code(sample.type_code))
            ),
        ):
            samples.append(sample)
    deletions = (
        item.model_copy(
            update={
                "client_record_id": canonical_deleted_sample_client_record_id(
                    item.client_record_id
                )
            }
        )
        if item.record_family == "sample"
        else item
        for item in batch.deleted_records
    )
    deleted = tuple(
        item for item in deletions if _delete(connection, item, observations)
    )
    _unknown_windows(connection, batch, observations)
    return batch.model_copy(
        update={"samples": tuple(samples), "deleted_records": deleted}
    )

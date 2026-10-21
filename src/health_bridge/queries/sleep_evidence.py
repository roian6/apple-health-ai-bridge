from collections.abc import Sequence
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.contract.batch_v1 import UtcTimestamp
from health_bridge.queries._common import seconds_between, source_from_row
from health_bridge.queries.latest_sleep_models import (
    SleepSessionEvidence,
    SleepStageEvidence,
)
from health_bridge.queries.models import Period, QueryModel

SessionRow: TypeAlias = tuple[int, UtcTimestamp, UtcTimestamp, str, str, str]
StageRow: TypeAlias = tuple[int, str, UtcTimestamp, UtcTimestamp]
SESSION_ROWS: Final = TypeAdapter(list[SessionRow])
STAGE_ROWS: Final = TypeAdapter(list[StageRow])
ASLEEP_STAGES: Final = frozenset(("core", "deep", "rem"))
KNOWN_STAGES: Final = ASLEEP_STAGES | {"awake", "in_bed"}


class SleepIntervalEvidence(QueryModel):
    sessions: tuple[SleepSessionEvidence, ...]
    stage_intervals: tuple[SleepStageEvidence, ...]
    asleep_intervals: tuple[Period, ...]


class SleepCalculation(QueryModel):
    evidence: SleepIntervalEvidence
    asleep_seconds: int | None
    awake_seconds: int | None
    in_bed_seconds: int | None
    stage_seconds: dict[str, int]
    stage_coverage_seconds: int
    uncovered_seconds: int
    evidence_incomplete: bool


def session_evidence(rows: list[SessionRow]) -> tuple[SleepSessionEvidence, ...]:
    return tuple(
        SleepSessionEvidence(
            start=row[1], end=row[2], source=source_from_row((row[3], row[4], row[5]))
        )
        for row in rows
    )


def calculate_sleep(
    sessions: list[SessionRow], stages: list[StageRow]
) -> SleepCalculation:
    evidence = _stage_evidence(sessions, stages)
    by_stage: dict[str, list[Period]] = {}
    for interval in evidence:
        by_stage.setdefault(interval.stage, []).append(interval)
    stage_seconds = {
        stage: _seconds(_union(intervals))
        for stage, intervals in sorted(by_stage.items())
    }
    asleep = _union(
        [interval for interval in evidence if interval.stage in ASLEEP_STAGES]
    )
    known = [interval for interval in evidence if interval.stage in KNOWN_STAGES]
    coverage = _seconds(_union(known))
    elapsed = seconds_between(
        min(row[1] for row in sessions), max(row[2] for row in sessions)
    )
    return SleepCalculation(
        evidence=SleepIntervalEvidence(
            sessions=session_evidence(sessions),
            stage_intervals=evidence,
            asleep_intervals=asleep,
        ),
        asleep_seconds=_seconds(asleep) if asleep else None,
        awake_seconds=stage_seconds.get("awake"),
        in_bed_seconds=stage_seconds.get("in_bed"),
        stage_seconds=stage_seconds,
        stage_coverage_seconds=coverage,
        uncovered_seconds=elapsed - coverage,
        evidence_incomplete=(
            not asleep
            or coverage < elapsed
            or bool(by_stage.keys() - KNOWN_STAGES)
            or len({interval.session_index for interval in known}) < len(sessions)
        ),
    )


def _stage_evidence(
    sessions: list[SessionRow], stages: list[StageRow]
) -> tuple[SleepStageEvidence, ...]:
    by_id = {row[0]: (index, row[1], row[2]) for index, row in enumerate(sessions)}
    intervals: list[SleepStageEvidence] = []
    for session_id, stage, start, end in stages:
        index, session_start, session_end = by_id[session_id]
        clipped_start, clipped_end = max(start, session_start), min(end, session_end)
        if clipped_start < clipped_end:
            intervals.append(
                SleepStageEvidence(
                    session_index=index,
                    stage=stage,
                    start=clipped_start,
                    end=clipped_end,
                )
            )
    return tuple(
        sorted(
            intervals,
            key=lambda item: (item.session_index, item.start, item.end, item.stage),
        )
    )


def _union(intervals: Sequence[Period]) -> tuple[Period, ...]:
    merged: list[Period] = []
    for interval in sorted(intervals, key=lambda item: (item.start, item.end)):
        if merged and interval.start <= merged[-1].end:
            merged[-1] = Period(
                start=merged[-1].start, end=max(merged[-1].end, interval.end)
            )
        else:
            merged.append(Period(start=interval.start, end=interval.end))
    return tuple(merged)


def _seconds(intervals: tuple[Period, ...]) -> int:
    return sum(seconds_between(interval.start, interval.end) for interval in intervals)

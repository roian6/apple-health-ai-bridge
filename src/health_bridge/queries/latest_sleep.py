from pathlib import Path
from typing import Final
from zoneinfo import ZoneInfo

from health_bridge.queries._common import (
    DEFAULT_LIMIT,
    EMPTY_RESULT_NOTE,
    LIMITED_STORE_NOTE,
    connect_readonly,
    unique_sources,
)
from health_bridge.queries.latest_sleep_models import (
    SLEEP_DURATION_NOTE,
    SLEEP_OBSERVATION_NOTE,
    LatestSleepArgs,
    LatestSleepPeriodResult,
    sleep_period,
)
from health_bridge.queries.sleep_evidence import (
    SESSION_ROWS,
    STAGE_ROWS,
    SessionRow,
    calculate_sleep,
    session_evidence,
)

SESSION_SQL: Final = """
select s.sleep_session_id, s.start_time, s.end_time,
       sources.source_key, sources.name, sources.kind
from sleep_sessions s join sources using (source_id)
where s.start_time < ? and s.end_time > ? and s.start_time < s.end_time
order by s.start_time, s.end_time, sources.source_key, s.client_record_id
limit ?
"""
STAGE_SQL: Final = """
select i.sleep_session_id, i.stage, i.start_time, i.end_time
from sleep_stage_intervals i join sleep_sessions s using (sleep_session_id)
where s.start_time >= ? and s.end_time <= ? and s.end_time > ?
      and s.start_time < s.end_time
order by s.start_time, s.end_time, s.source_id, s.client_record_id,
         i.start_time, i.end_time, i.stage
limit ?
"""


def get_latest_sleep_period(
    db_path: Path, args: LatestSleepArgs
) -> LatestSleepPeriodResult:
    window = args.search_window()
    notes = (LIMITED_STORE_NOTE, SLEEP_OBSERVATION_NOTE, SLEEP_DURATION_NOTE)
    result = LatestSleepPeriodResult(
        timezone=args.timezone,
        reference_time=args.reference_time,
        search_window=window,
        stage_seconds={},
        missing_data_notes=notes,
    )
    with connect_readonly(db_path) as connection:
        rows = SESSION_ROWS.validate_python(
            connection.execute(
                SESSION_SQL, (args.reference_time, window.start, DEFAULT_LIMIT + 1)
            ).fetchall()
        )
        if len(rows) > DEFAULT_LIMIT:
            return result.model_copy(
                update={
                    "truncated": True,
                    "missing_data_notes": (
                        *notes,
                        "More than 500 candidate sessions; selection withheld.",
                    ),
                }
            )
        selected = _latest_completed(rows, args.reference_time)
        if not selected:
            return result.model_copy(
                update={"missing_data_notes": (*notes, EMPTY_RESULT_NOTE)}
            )
        start = selected[0][1]
        end = max(row[2] for row in selected)
        sessions = session_evidence(selected)
        result = result.model_copy(
            update={
                "selected_period": sleep_period(start, end, ZoneInfo(args.timezone)),
                "sessions": sessions,
                "sources_used": unique_sources(session.source for session in sessions),
            }
        )
        stages = STAGE_ROWS.validate_python(
            connection.execute(
                STAGE_SQL, (start, end, window.start, DEFAULT_LIMIT + 1)
            ).fetchall()
        )
    if len(stages) > DEFAULT_LIMIT:
        return result.model_copy(
            update={
                "truncated": True,
                "missing_data_notes": (
                    *notes,
                    "More than 500 stage intervals; evidence and totals withheld.",
                ),
            }
        )
    calculation = calculate_sleep(selected, stages)
    return result.model_copy(
        update={
            "stage_intervals": calculation.evidence.stage_intervals,
            "asleep_intervals": calculation.evidence.asleep_intervals,
            "asleep_seconds": calculation.asleep_seconds,
            "awake_seconds": calculation.awake_seconds,
            "in_bed_seconds": calculation.in_bed_seconds,
            "stage_seconds": calculation.stage_seconds,
        }
    )


def _latest_completed(rows: list[SessionRow], reference: str) -> list[SessionRow]:
    selected: list[SessionRow] = []
    group: list[SessionRow] = []
    group_end = ""
    for row in rows:
        if group and row[1] > group_end:
            if group_end <= reference:
                selected = group
            group = []
            group_end = ""
        group.append(row)
        group_end = max(group_end, row[2])
    if group and group_end <= reference:
        selected = group
    return selected

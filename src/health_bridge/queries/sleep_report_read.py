import sqlite3
from typing import Final

from health_bridge.queries._common import DEFAULT_LIMIT
from health_bridge.queries.models import Period
from health_bridge.queries.sleep_evidence import (
    SESSION_ROWS,
    STAGE_ROWS,
    SessionRow,
    StageRow,
)

REPORT_SESSIONS_SQL: Final = """
select s.sleep_session_id, s.start_time, s.end_time,
       sources.source_key, sources.name, sources.kind
from sleep_sessions s join sources using (source_id)
where s.start_time <= ? and s.end_time >= ? and s.start_time < s.end_time
      and (? is null or s.start_time > ? or s.end_time < ?)
order by s.start_time, s.end_time, sources.source_key, s.client_record_id
limit ?
"""
REPORT_STAGES_SQL: Final = """
select i.sleep_session_id, i.stage, i.start_time, i.end_time
from sleep_stage_intervals i join sleep_sessions s using (sleep_session_id)
where s.start_time >= ? and s.end_time <= ? and s.start_time < s.end_time
order by s.start_time, s.end_time, s.source_id, s.client_record_id,
         i.start_time, i.end_time, i.stage
limit ?
"""


def read_connected_sessions(
    connection: sqlite3.Connection, day: Period
) -> list[SessionRow] | None:
    start, end = day.start, day.end
    previous_start: str | None = None
    previous_end: str | None = None
    rows: list[SessionRow] = []
    while True:
        added = SESSION_ROWS.validate_python(
            connection.execute(
                REPORT_SESSIONS_SQL,
                (
                    end,
                    start,
                    previous_start,
                    previous_end,
                    previous_start,
                    DEFAULT_LIMIT + 1 - len(rows),
                ),
            ).fetchall()
        )
        rows.extend(added)
        if len(rows) > DEFAULT_LIMIT:
            return None
        expanded_start = min((row[1] for row in added), default=start)
        expanded_end = max((row[2] for row in added), default=end)
        expanded_start, expanded_end = (
            min(start, expanded_start),
            max(end, expanded_end),
        )
        if (expanded_start, expanded_end) == (start, end):
            return sorted(rows, key=lambda row: (row[1], row[2], row[3], row[0]))
        previous_start, previous_end = start, end
        start, end = expanded_start, expanded_end


def observed_groups(rows: list[SessionRow]) -> list[list[SessionRow]]:
    groups: list[list[SessionRow]] = []
    end = ""
    for row in rows:
        if not groups or row[1] > end:
            groups.append([])
        groups[-1].append(row)
        end = max(end, row[2])
    return groups


def read_group_stages(
    connection: sqlite3.Connection, groups: list[list[SessionRow]]
) -> list[list[StageRow]] | None:
    stages: list[list[StageRow]] = []
    count = 0
    for group in groups:
        rows = STAGE_ROWS.validate_python(
            connection.execute(
                REPORT_STAGES_SQL,
                (group[0][1], max(row[2] for row in group), DEFAULT_LIMIT + 1 - count),
            ).fetchall()
        )
        count += len(rows)
        if count > DEFAULT_LIMIT:
            return None
        stages.append(rows)
    return stages

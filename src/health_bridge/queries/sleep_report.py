from pathlib import Path
from zoneinfo import ZoneInfo

from health_bridge.queries._common import (
    LIMITED_STORE_NOTE,
    connect_readonly,
    unique_sources,
)
from health_bridge.queries.latest_sleep_models import SLEEP_DURATION_NOTE, sleep_period
from health_bridge.queries.sleep_evidence import (
    SessionRow,
    calculate_sleep,
    session_evidence,
)
from health_bridge.queries.sleep_report_models import (
    SLEEP_INPUT_NOTE,
    SLEEP_REPORT_NOTE,
    SleepReportArgs,
    SleepReportPeriod,
    SleepReportResult,
)
from health_bridge.queries.sleep_report_read import (
    observed_groups,
    read_connected_sessions,
    read_group_stages,
)


def get_sleep_report(db_path: Path, args: SleepReportArgs) -> SleepReportResult:
    day = args.day_bounds()
    notes = (
        LIMITED_STORE_NOTE,
        SLEEP_REPORT_NOTE,
        SLEEP_DURATION_NOTE,
        SLEEP_INPUT_NOTE,
    )
    result = SleepReportResult(
        timezone=args.timezone,
        requested_local_date=args.local_date,
        local_date=args.effective_date(),
        reference_time=args.reference_time,
        day_bounds=day,
        include_intervals=args.include_intervals,
        missing_data_notes=notes,
    )
    with connect_readonly(db_path) as connection:
        rows = read_connected_sessions(connection, day) if day.start < day.end else []
        if rows is None:
            return result.model_copy(
                update={
                    "truncated": True,
                    "withheld_reason": "session_limit",
                    "missing_data_notes": (
                        *notes,
                        (
                            "Session limit exceeded; complete membership, selection "
                            "and totals withheld."
                        ),
                    ),
                }
            )
        selected: list[list[SessionRow]] = []
        summaries: list[SleepReportPeriod] = []
        after_reference = other_date = 0
        for group in observed_groups(rows):
            period = sleep_period(
                group[0][1], max(row[2] for row in group), ZoneInfo(args.timezone)
            )
            if period.end > args.reference_time:
                after_reference += 1
            elif period.local_end_date != result.local_date:
                other_date += 1
            else:
                selected.append(group)
                summaries.append(
                    SleepReportPeriod(
                        period=period,
                        session_count=len(group),
                        sources_used=unique_sources(
                            item.source for item in session_evidence(group)
                        ),
                    )
                )
        result = result.model_copy(
            update={
                "periods": tuple(summaries),
                "omitted_after_reference_count": after_reference,
                "other_wake_date_count": other_date,
                "sources_used": unique_sources(
                    source for summary in summaries for source in summary.sources_used
                ),
            }
        )
        stages = read_group_stages(connection, selected)
    if stages is None:
        return result.model_copy(
            update={
                "truncated": True,
                "withheld_reason": "stage_limit",
                "missing_data_notes": (
                    *notes,
                    (
                        "Global stage limit exceeded; all period evidence "
                        "and totals withheld."
                    ),
                ),
            }
        )
    periods: list[SleepReportPeriod] = []
    for summary, group, intervals in zip(summaries, selected, stages, strict=True):
        measured = calculate_sleep(group, intervals)
        periods.append(
            summary.model_copy(
                update={
                    "duration_status": "recorded"
                    if measured.asleep_seconds is not None
                    else "unknown",
                    "asleep_seconds": measured.asleep_seconds,
                    "awake_seconds": measured.awake_seconds,
                    "in_bed_seconds": measured.in_bed_seconds,
                    "stage_seconds": measured.stage_seconds,
                    "stage_coverage_seconds": measured.stage_coverage_seconds,
                    "uncovered_seconds": measured.uncovered_seconds,
                    "evidence_incomplete": measured.evidence_incomplete,
                    "evidence": measured.evidence if args.include_intervals else None,
                }
            )
        )
    return result.model_copy(
        update={
            "status": "recorded" if periods else "no_eligible_periods",
            "periods": tuple(periods),
            "recorded_asleep_seconds": _known_total(
                [period.asleep_seconds for period in periods]
            ),
            "recorded_awake_seconds": _known_total(
                [period.awake_seconds for period in periods]
            ),
            "recorded_in_bed_seconds": _known_total(
                [period.in_bed_seconds for period in periods]
            ),
            "unknown_duration_period_count": sum(
                period.asleep_seconds is None for period in periods
            ),
            "incomplete_evidence_period_count": sum(
                period.evidence_incomplete is True for period in periods
            ),
            "missing_data_notes": notes
            if periods
            else (
                *notes,
                (
                    "No eligible received sleep periods end on the requested local "
                    "date; no older date was substituted."
                ),
            ),
        }
    )


def _known_total(values: list[int | None]) -> int | None:
    known = [value for value in values if value is not None]
    return sum(known) if known else None

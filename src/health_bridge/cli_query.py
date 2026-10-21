from pathlib import Path
from typing import Annotated

import typer
from pydantic import BaseModel, ValidationError

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
from health_bridge.timeseries_catalog import list_supported_timeseries_types

query_app = typer.Typer(help="Read source-grounded observations from local data.")


def echo_json(model: BaseModel) -> None:
    typer.echo(model.model_dump_json())


@query_app.command("synced-metrics")
def synced_metrics(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
) -> None:
    echo_json(list_synced_metrics(db))


@query_app.command("supported-timeseries-types")
def supported_timeseries_types(
    category: Annotated[
        str | None,
        typer.Option(
            "--category",
            help="Optional supported metric category filter for metadata-only output.",
        ),
    ] = None,
) -> None:
    echo_json(list_supported_timeseries_types(category=category))


@query_app.command()
def timeseries(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
    types: Annotated[
        str,
        typer.Option("--types", help="Comma-separated metric type codes."),
    ],
    start_time: Annotated[
        str,
        typer.Option("--start-time", help="Inclusive UTC observation start."),
    ],
    end_time: Annotated[
        str,
        typer.Option("--end-time", help="Exclusive UTC observation end."),
    ],
) -> None:
    type_codes = tuple(part.strip() for part in types.split(",") if part.strip())
    echo_json(
        get_timeseries(
            db,
            type_codes=type_codes,
            start_time=start_time,
            end_time=end_time,
        ),
    )


@query_app.command()
def workouts(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
    start_date: Annotated[
        str,
        typer.Option("--start-date", help="Inclusive observation date."),
    ],
    end_date: Annotated[
        str,
        typer.Option("--end-date", help="Exclusive observation date."),
    ],
) -> None:
    echo_json(get_workouts(db, start_date=start_date, end_date=end_date))


@query_app.command("sleep-summary")
def sleep_summary(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
    start_date: Annotated[
        str,
        typer.Option("--start-date", help="Inclusive observation date."),
    ],
    end_date: Annotated[
        str,
        typer.Option("--end-date", help="Exclusive observation date."),
    ],
) -> None:
    echo_json(get_sleep_summary(db, start_date=start_date, end_date=end_date))


@query_app.command("daily-summary")
def daily_summary(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
    start_date: Annotated[
        str,
        typer.Option("--start-date", help="Inclusive observation date."),
    ],
    end_date: Annotated[
        str,
        typer.Option("--end-date", help="Exclusive observation date."),
    ],
) -> None:
    echo_json(get_daily_summary(db, start_date=start_date, end_date=end_date))


@query_app.command("latest-sleep-period")
def latest_sleep_period(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
    timezone: Annotated[str, typer.Option("--timezone", help="IANA timezone key.")],
    reference_time: Annotated[
        str,
        typer.Option("--reference-time", help="UTC reference YYYY-MM-DDTHH:MM:SSZ."),
    ],
) -> None:
    try:
        args = LatestSleepArgs(timezone=timezone, reference_time=reference_time)
    except ValidationError as exc:
        message = "Invalid latest sleep arguments."
        raise typer.BadParameter(message) from exc
    echo_json(get_latest_sleep_period(db, args))


@query_app.command("explain-sources")
def source_explanation(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
) -> None:
    echo_json(explain_sources(db))


@query_app.command("sleep-report")
def sleep_report(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
    timezone: Annotated[str, typer.Option("--timezone", help="IANA timezone key.")],
    local_date: Annotated[
        str | None,
        typer.Option(
            "--local-date",
            help="Local wake date YYYY-MM-DD; default reference's local date.",
        ),
    ] = None,
    reference_time: Annotated[
        str | None,
        typer.Option(
            "--reference-time",
            help="UTC cutoff YYYY-MM-DDTHH:MM:SSZ; default captured current UTC.",
        ),
    ] = None,
    include_intervals: Annotated[
        bool,
        typer.Option(
            "--include-intervals", help="Include bounded calculation evidence."
        ),
    ] = False,
) -> None:
    try:
        args = SleepReportArgs.model_validate(
            {
                "timezone": timezone,
                "local_date": local_date,
                "include_intervals": include_intervals,
                **(
                    {"reference_time": reference_time}
                    if reference_time is not None
                    else {}
                ),
            }
        )
    except ValidationError as exc:
        message = "Invalid sleep report arguments."
        raise typer.BadParameter(message) from exc
    echo_json(get_sleep_report(db, args))

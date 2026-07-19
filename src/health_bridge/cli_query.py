from pathlib import Path
from typing import Annotated

import typer
from pydantic import BaseModel

from health_bridge.queries import (
    explain_sources,
    get_daily_summary,
    get_sleep_summary,
    get_timeseries,
    get_workouts,
    list_synced_metrics,
)
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


@query_app.command("explain-sources")
def source_explanation(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
) -> None:
    echo_json(explain_sources(db))

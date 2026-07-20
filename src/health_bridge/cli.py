import sqlite3
import sys
from pathlib import Path
from typing import Annotated, Final

import typer
from pydantic import ValidationError

from health_bridge import __version__
from health_bridge.cli_dev import (
    AppReviewDemoRequest,
    DevDeviceSessionRequest,
    app_review_demo_manifest_json,
    build_app_review_demo_manifest,
    build_dev_device_session_manifest,
    build_dev_receiver_systemd_manifest,
    manifest_json,
    receiver_systemd_manifest_json,
    watch_event_json,
    watch_sync_run_events,
)
from health_bridge.cli_mcp import mcp_app
from health_bridge.cli_query import query_app
from health_bridge.cli_receiver import receiver_app
from health_bridge.cli_setup import (
    SetupRequest,
    build_setup_manifest,
    configure_mcp_clients,
    render_setup_summary,
    validate_requested_clients,
    verify_local_mcp,
)
from health_bridge.dev_validation import (
    anchored_step_validation_json,
    read_anchored_step_validation_snapshot,
)
from health_bridge.ingest import MALFORMED_JSON_SUMMARY
from health_bridge.ingest import ingest_fixture as ingest_fixture_batch
from health_bridge.status import read_status, read_status_markdown, read_status_snapshot
from health_bridge.storage import initialize_database

app = typer.Typer(
    add_completion=False,
    help="Local-first Apple Health context bridge for read-only CLI and MCP access.",
    invoke_without_command=True,
)
app.add_typer(query_app, name="query")
app.add_typer(mcp_app, name="mcp")
app.add_typer(receiver_app, name="receiver")
dev_app = typer.Typer(
    add_completion=False,
    help="Developer and private-device setup helpers.",
)
app.add_typer(dev_app, name="dev")
DEFAULT_DEVICE_SESSION_SETUP_PAGE: Final = Path(
    ".tmp/health-bridge-device-session.html"
)
DEFAULT_APP_REVIEW_DEMO_SETUP_PAGE: Final = Path(
    ".tmp/health-bridge-app-review-demo.html"
)
DEFAULT_APP_REVIEW_DEMO_FIXTURE: Final = Path(
    "fixtures/health_bridge_batch_v1.synthetic.json"
)
DEFAULT_USER_DB: Final = Path.home() / ".local/share/health-bridge/health.sqlite"
DEFAULT_USER_SETUP_PAGE: Final = Path.home() / ".local/share/health-bridge/pairing.html"


@app.callback()
def main(
    version: Annotated[
        bool,
        typer.Option("--version", help="Show the installed version and exit."),
    ] = False,
) -> None:
    if version:
        typer.echo(f"health-bridge {__version__}")
        raise typer.Exit


@app.command()
def init(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
) -> None:
    try:
        initialize_database(db)
    except PermissionError as exc:
        if "private file parent must not be group/other writable" not in str(exc):
            raise
        unsafe_location = "group/other-writable directory"
        recovery = "Choose an owner-only directory (chmod 700) and retry."
        message = (
            f"Cannot create a private database below a {unsafe_location}. {recovery}"
        )
        typer.echo(message, err=True)
        raise typer.Exit(code=1) from None
    typer.echo(f"initialized: {db}")


@app.command()
def setup(  # noqa: PLR0913 - Typer exposes each setup input as an option.
    receiver_url: Annotated[
        str,
        typer.Option(
            "--receiver-url",
            help=(
                "Exact phone-reachable /v1/batches URL from a configured private "
                "route; documentation hostnames are rejected."
            ),
        ),
    ],
    db: Annotated[
        Path,
        typer.Option("--db", help="Private local Apple Health SQLite path."),
    ] = DEFAULT_USER_DB,
    setup_page: Annotated[
        Path,
        typer.Option("--setup-page", help="Private iPhone pairing page path."),
    ] = DEFAULT_USER_SETUP_PAGE,
    label: Annotated[
        str,
        typer.Option("--label", help="Human-readable iPhone label."),
    ] = "iPhone",
    receiver_host: Annotated[
        str,
        typer.Option("--receiver-host", help="Receiver bind host."),
    ] = "127.0.0.1",
    receiver_port: Annotated[
        int,
        typer.Option(
            "--receiver-port",
            min=1,
            max=65535,
            help="Receiver bind port (1-65535).",
        ),
    ] = 8765,
    allow_nonlocal_receiver_address: Annotated[
        bool,
        typer.Option(
            "--allow-nonlocal-receiver-address",
            help=(
                "Allow an intentional numeric HTTP proxy address not assigned "
                "to this host."
            ),
        ),
    ] = False,
    configure_clients: Annotated[
        list[str] | None,
        typer.Option(
            "--configure-client",
            help=(
                "Explicitly configure and verify this MCP client. Repeat for more "
                "than one; omission never modifies client settings."
            ),
        ),
    ] = None,
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit a secret-redacted setup manifest."),
    ] = False,
) -> None:
    executable = str(Path(sys.argv[0]).resolve(strict=False))
    try:
        requested_clients = validate_requested_clients(configure_clients or ())
        manifest = build_setup_manifest(
            SetupRequest(
                db_path=db,
                label=label,
                receiver_url=receiver_url,
                setup_page_path=setup_page,
                receiver_host=receiver_host,
                receiver_port=receiver_port,
                executable=executable,
                allow_nonlocal_receiver_address=allow_nonlocal_receiver_address,
            )
        )
        manifest = verify_local_mcp(manifest)
        manifest = configure_mcp_clients(manifest, requested_clients)
    except (RuntimeError, ValueError) as exc:
        typer.echo(str(exc), err=True)
        raise typer.Exit(code=1) from exc
    output = (
        manifest.model_dump_json() if json_output else render_setup_summary(manifest)
    )
    typer.echo(output)


@app.command("ingest-fixture")
def ingest_fixture(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    input_path: Annotated[
        Path,
        typer.Option("--input", help="Synthetic health bridge batch JSON fixture."),
    ],
) -> None:
    try:
        result = ingest_fixture_batch(db, input_path)
    except ValidationError as exc:
        summary = _summary_for_validation_error(exc)
        typer.echo(f"Fixture ingest failed: {summary}", err=True)
        raise typer.Exit(code=1) from exc
    except sqlite3.Error as exc:
        typer.echo("Fixture ingest failed: records could not be stored.", err=True)
        raise typer.Exit(code=1) from exc
    output_parts = [
        "ingested:",
        f"sources={result.source_count}",
        f"health_types={result.health_type_count}",
        f"samples={result.sample_count}",
        f"workouts={result.workout_count}",
        f"sleep_sessions={result.sleep_session_count}",
        f"deleted_records={result.deleted_record_count}",
        f"sync_cursors={result.sync_cursor_count}",
    ]
    typer.echo(" ".join(output_parts))


@app.command()
def status(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    json_output: Annotated[
        bool,
        typer.Option(
            "--json",
            help="Emit a structured redacted status snapshot for local agents.",
        ),
    ] = False,
    markdown_output: Annotated[
        bool,
        typer.Option(
            "--markdown",
            help="Emit a redacted Markdown context snapshot for local agents/wiki.",
        ),
    ] = False,
    output: Annotated[
        Path | None,
        typer.Option(
            "--output",
            help="Write --json or --markdown output to this file instead of stdout.",
        ),
    ] = None,
) -> None:
    if json_output and markdown_output:
        typer.echo("Choose only one of --json or --markdown.", err=True)
        raise typer.Exit(code=1)
    if output is not None and not (json_output or markdown_output):
        typer.echo("--output requires --json or --markdown.", err=True)
        raise typer.Exit(code=1)
    if json_output:
        _emit_or_write(read_status_snapshot(db).model_dump_json(), output)
        return
    if markdown_output:
        _emit_or_write(read_status_markdown(db), output)
        return
    bridge_status = read_status(db)
    for table_name, count in bridge_status.counts.items():
        typer.echo(f"{table_name}: {count}")
    typer.echo(f"last_sync_status: {bridge_status.last_sync_status or 'none'}")
    if bridge_status.last_sync_error is not None:
        typer.echo(f"last_sync_error: {bridge_status.last_sync_error}")


@app.command("dev-receiver-systemd", hidden=True)
@dev_app.command("receiver-systemd")
def dev_receiver_systemd(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path for receiver."),
    ],
    host: Annotated[
        str,
        typer.Option("--host", help="Bind host for the receiver service."),
    ] = "127.0.0.1",
    port: Annotated[
        int,
        typer.Option("--port", help="Bind port for the receiver service."),
    ] = 8765,
    working_directory: Annotated[
        Path | None,
        typer.Option(
            "--working-directory",
            help="WorkingDirectory for uv/project resolution; defaults to cwd.",
        ),
    ] = None,
    service_name: Annotated[
        str,
        typer.Option("--service-name", help="User-level systemd service name."),
    ] = "health-bridge-receiver",
) -> None:
    try:
        manifest = build_dev_receiver_systemd_manifest(
            db_path=db,
            host=host,
            port=port,
            working_directory=Path.cwd()
            if working_directory is None
            else working_directory,
            service_name=service_name,
        )
    except ValueError as exc:
        typer.echo(str(exc), err=True)
        raise typer.Exit(code=1) from exc
    typer.echo(receiver_systemd_manifest_json(manifest))


@app.command("dev-device-session", hidden=True)
@dev_app.command("device-session")
def dev_device_session(  # noqa: PLR0913 - Typer exposes each CLI option as a parameter.
    db: Annotated[
        Path,
        typer.Option(
            "--db", help="User-owned SQLite database path for the device session."
        ),
    ],
    label: Annotated[
        str,
        typer.Option("--label", help="Human-readable iPhone/companion label."),
    ] = "ios-companion",
    receiver_url: Annotated[
        str,
        typer.Option(
            "--receiver-url", help="Receiver /v1/batches URL the iPhone should use."
        ),
    ] = "http://127.0.0.1:8765/v1/batches",
    setup_page: Annotated[
        Path,
        typer.Option(
            "--setup-page", help="Path for the generated secret pairing setup page."
        ),
    ] = DEFAULT_DEVICE_SESSION_SETUP_PAGE,
    receiver_host: Annotated[
        str,
        typer.Option(
            "--receiver-host", help="Bind host for the receiver start command."
        ),
    ] = "127.0.0.1",
    receiver_port: Annotated[
        int,
        typer.Option(
            "--receiver-port", help="Bind port for the receiver start command."
        ),
    ] = 8765,
    watch_seconds: Annotated[
        int,
        typer.Option(
            "--watch-seconds",
            help="Timeout for the generated sync-run watcher command.",
        ),
    ] = 7200,
) -> None:
    manifest = build_dev_device_session_manifest(
        DevDeviceSessionRequest(
            db_path=db,
            label=label,
            receiver_url=receiver_url,
            setup_page_path=setup_page,
            receiver_host=receiver_host,
            receiver_port=receiver_port,
            watch_seconds=watch_seconds,
        )
    )
    typer.echo(manifest_json(manifest))


@app.command("dev-app-review-demo", hidden=True)
@dev_app.command("app-review-demo", hidden=True)
def dev_app_review_demo(  # noqa: PLR0913 - Typer exposes each CLI option as a parameter.
    db: Annotated[
        Path,
        typer.Option("--db", help="Synthetic reviewer-demo SQLite database path."),
    ],
    fixture: Annotated[
        Path,
        typer.Option(
            "--fixture", help="Synthetic fixture to preload into the demo DB."
        ),
    ] = DEFAULT_APP_REVIEW_DEMO_FIXTURE,
    label: Annotated[
        str,
        typer.Option("--label", help="Human-readable reviewer/demo receiver label."),
    ] = "app-review-demo",
    receiver_url: Annotated[
        str,
        typer.Option("--receiver-url", help="Reviewer-demo receiver /v1/batches URL."),
    ] = "http://127.0.0.1:8765/v1/batches",
    setup_page: Annotated[
        Path,
        typer.Option(
            "--setup-page",
            help="Path for the generated secret reviewer-demo pairing page.",
        ),
    ] = DEFAULT_APP_REVIEW_DEMO_SETUP_PAGE,
    receiver_host: Annotated[
        str,
        typer.Option(
            "--receiver-host", help="Bind host for the demo receiver start command."
        ),
    ] = "127.0.0.1",
    receiver_port: Annotated[
        int,
        typer.Option(
            "--receiver-port", help="Bind port for the demo receiver start command."
        ),
    ] = 8765,
    watch_seconds: Annotated[
        int,
        typer.Option(
            "--watch-seconds",
            help="Timeout for the generated reviewer-demo sync-run watcher command.",
        ),
    ] = 3600,
) -> None:
    manifest = build_app_review_demo_manifest(
        AppReviewDemoRequest(
            db_path=db,
            fixture_path=fixture,
            label=label,
            receiver_url=receiver_url,
            setup_page_path=setup_page,
            receiver_host=receiver_host,
            receiver_port=receiver_port,
            watch_seconds=watch_seconds,
        )
    )
    typer.echo(app_review_demo_manifest_json(manifest))


@app.command("dev-validate-anchored-steps", hidden=True)
@dev_app.command("validate-anchored-steps")
def dev_validate_anchored_steps(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path to validate."),
    ],
    source_key: Annotated[
        str,
        typer.Option(
            "--source-key",
            help="Apple Health source key to validate without exposing cursor values.",
        ),
    ] = "apple_health.phone",
) -> None:
    snapshot = read_anchored_step_validation_snapshot(db, source_key=source_key)
    typer.echo(anchored_step_validation_json(snapshot))


@app.command("dev-watch-sync-runs", hidden=True)
@dev_app.command("watch-sync-runs")
def dev_watch_sync_runs(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path to watch."),
    ],
    after_sync_run_id: Annotated[
        int,
        typer.Option("--after-sync-run-id", help="Only emit sync runs after this ID."),
    ],
    timeout_seconds: Annotated[
        int,
        typer.Option("--timeout-seconds", help="Stop after this many seconds."),
    ] = 7200,
    poll_seconds: Annotated[
        float,
        typer.Option("--poll-seconds", help="Polling interval for SQLite checks."),
    ] = 2.0,
) -> None:
    for event in watch_sync_run_events(
        db_path=db,
        after_sync_run_id=after_sync_run_id,
        timeout_seconds=timeout_seconds,
        poll_interval_seconds=poll_seconds,
    ):
        typer.echo(watch_event_json(event))


def _emit_or_write(content: str, output: Path | None) -> None:
    if output is None:
        typer.echo(content)
        return
    if output.is_dir():
        typer.echo(f"Cannot write status output to directory: {output}", err=True)
        raise typer.Exit(code=1)
    if output.parent.exists() and not output.parent.is_dir():
        typer.echo(
            f"Cannot create status output directory: {output.parent}",
            err=True,
        )
        raise typer.Exit(code=1)
    output.parent.mkdir(parents=True, exist_ok=True)
    _ = output.write_text(content, encoding="utf-8")
    typer.echo(f"wrote: {output}")


def _summary_for_validation_error(exc: ValidationError) -> str:
    if MALFORMED_JSON_SUMMARY in str(exc) or "Invalid JSON" in str(exc):
        return "malformed JSON fixture."
    return "fixture does not match health_bridge.batch.v1 schema."


def run() -> None:
    app()

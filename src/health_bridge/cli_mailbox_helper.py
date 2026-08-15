from __future__ import annotations

import json
from pathlib import Path  # noqa: TC003 -- Typer evaluates command annotations.
from typing import Annotated, Never

import typer

from health_bridge import __version__
from health_bridge.mailbox.helper_lifecycle import (
    HelperError,
    HelperResult,
    HelperStatusCode,
    install_helper,
    read_helper_status,
    uninstall_helper,
    validate_helper_release,
)

helper_app = typer.Typer(
    add_completion=False,
    help="Verify and explicitly manage the signed macOS mailbox ACK helper.",
)


@helper_app.command(
    "verify",
    help="Structurally verify a downloaded helper archive and public manifest.",
)
def verify_helper(
    archive: Annotated[
        Path,
        typer.Option("--archive", help="Downloaded signed helper zip."),
    ],
    manifest: Annotated[
        Path,
        typer.Option("--manifest", help="Downloaded public helper manifest."),
    ],
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    try:
        _ = validate_helper_release(archive, manifest, expected_version=__version__)
    except HelperError as exc:
        _exit_with_error(exc, json_output)
    _emit_result(HelperResult(code=HelperStatusCode.VALID), json_output)


@helper_app.command(
    "install",
    help="Verify and install one exact signed helper without replacing content.",
)
def install_mailbox_helper(
    archive: Annotated[
        Path,
        typer.Option("--archive", help="Downloaded signed helper zip."),
    ],
    manifest: Annotated[
        Path,
        typer.Option("--manifest", help="Downloaded public helper manifest."),
    ],
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    try:
        result = install_helper(archive, manifest)
    except HelperError as exc:
        _exit_with_error(exc, json_output)
    _emit_result(result, json_output)


@helper_app.command(
    "status",
    help="Report one privacy-safe installed-helper readiness code.",
)
def mailbox_helper_status(
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    result = read_helper_status()
    _emit_result(result, json_output)
    if result.code is not HelperStatusCode.READY:
        raise typer.Exit(code=1)


@helper_app.command(
    "uninstall",
    help="Retire only an exact Health Bridge-owned helper generation.",
)
def uninstall_mailbox_helper(
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit one fixed machine-readable status code."),
    ] = False,
) -> None:
    try:
        result = uninstall_helper()
    except HelperError as exc:
        _exit_with_error(exc, json_output)
    _emit_result(result, json_output)


def _exit_with_error(error: HelperError, json_output: bool) -> Never:
    if json_output:
        typer.echo(json.dumps({"code": error.code.value}, sort_keys=True))
    else:
        typer.echo(str(error), err=True)
    raise typer.Exit(code=1)


def _emit_result(result: HelperResult, json_output: bool) -> None:
    if json_output:
        typer.echo(json.dumps({"code": result.code.value}, sort_keys=True))
        return
    typer.echo(f"code: {result.code.value}")

from __future__ import annotations

import json
import sys
import tempfile
import time
from pathlib import Path
from typing import TYPE_CHECKING, Annotated, ClassVar

import typer
from pydantic import BaseModel, ConfigDict

from health_bridge.cli_launchd import service_app
from health_bridge.cli_mailbox_helper import helper_app
from health_bridge.mailbox.connections import (
    MailboxConnectionError,
    MailboxConnectionStore,
)
from health_bridge.mailbox.filesystem import MailboxFileError
from health_bridge.mailbox.importer import (
    MailboxBusyError,
    MailboxImportConfig,
    MailboxImporter,
)
from health_bridge.mailbox.models import MailboxImportResult
from health_bridge.mailbox.native_ack_publication import default_native_ack_publisher
from health_bridge.receiver._mailbox_key_models import (
    MailboxKeyStoreErrorCode,
)
from health_bridge.receiver._mailbox_key_policy import (
    FilesystemKind,
    filesystem_kind,
    reject_prohibited_path,
)
from health_bridge.receiver.mailbox_keys import MailboxKeyStore, MailboxKeyStoreError
from health_bridge.storage.database import initialize_database

if TYPE_CHECKING:
    from health_bridge.mailbox.filesystem import MailboxDirectoryHandle

mailbox_app = typer.Typer(
    add_completion=False,
    help="Manage private local mailbox state.",
)
keys_app = typer.Typer(
    add_completion=False,
    help="Inspect the local receiver mailbox identity.",
)
mailbox_app.add_typer(keys_app, name="keys")
mailbox_app.add_typer(helper_app, name="helper")
mailbox_app.add_typer(service_app, name="service")


class MailboxKeysDoctorResult(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    status: str
    state: str | None = None
    signing_key_id: str | None = None
    agreement_key_id: str | None = None
    error_code: str | None = None


@mailbox_app.command("import")
def import_mailbox(
    db: Annotated[
        Path,
        typer.Option("--db", help="Private local Apple Health SQLite path."),
    ],
    mailbox: Annotated[
        Path,
        typer.Option("--mailbox", help="Resolved per-device mailbox directory."),
    ],
    once: Annotated[
        bool,
        typer.Option("--once", help="Run one bounded import pass and exit."),
    ] = False,
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit aggregate redacted counts."),
    ] = False,
) -> None:
    if not once:
        typer.echo("Mailbox import requires --once.", err=True)
        raise typer.Exit(code=2)
    try:
        result = production_importer(db, mailbox).import_once()
    except MailboxBusyError:
        _emit_import_result(MailboxImportResult(retryable=1), json_output)
        raise typer.Exit(code=2) from None
    except (
        MailboxConnectionError,
        MailboxFileError,
        MailboxKeyStoreError,
        OSError,
    ):
        _emit_import_result(MailboxImportResult(retryable=1), json_output)
        raise typer.Exit(code=2) from None
    _emit_import_result(result, json_output)


def production_importer(
    db: Path,
    mailbox: Path,
    *,
    directory: MailboxDirectoryHandle | None = None,
) -> MailboxImporter:
    initialize_database(db)
    connections = MailboxConnectionStore.production()
    return MailboxImporter(
        MailboxImportConfig(
            db_path=db,
            mailbox_path=mailbox,
            lock_path=connections.lock_path(mailbox),
            connection=connections.load(mailbox),
            clock_ms=lambda: time.time_ns() // 1_000_000,
            directory=directory,
            ack_publisher=(
                default_native_ack_publisher() if sys.platform == "darwin" else None
            ),
        )
    )


def _emit_import_result(result: MailboxImportResult, json_output: bool) -> None:
    values = {
        "imported": result.imported,
        "idempotent": result.idempotent,
        "quarantined": result.quarantined,
        "retryable": result.retryable,
        "conflict": result.conflict,
        "skipped": result.skipped,
    }
    if json_output:
        typer.echo(json.dumps(values, sort_keys=True, separators=(",", ":")))
        return
    typer.echo(" ".join(f"{key}={value}" for key, value in values.items()))


@keys_app.command("doctor")
def mailbox_keys_doctor(
    state_dir: Annotated[
        Path | None,
        typer.Option(
            "--state-dir",
            help="Use an isolated temporary key directory for synthetic QA only.",
        ),
    ] = None,
    json_output: Annotated[
        bool,
        typer.Option("--json", help="Emit a public-only JSON health result."),
    ] = False,
) -> None:
    try:
        store = _doctor_store(state_dir)
        _ = store.load_or_create()
        summary = store.public_summary()
    except MailboxKeyStoreError as exc:
        result = MailboxKeysDoctorResult(status="error", error_code=exc.code.value)
        typer.echo(result.model_dump_json(exclude_none=True), err=not json_output)
        raise typer.Exit(code=2) from None

    result = MailboxKeysDoctorResult(
        status="ok",
        state=summary.state.value,
        signing_key_id=summary.signing_key_id,
        agreement_key_id=summary.agreement_key_id,
    )
    if json_output:
        typer.echo(result.model_dump_json(exclude_none=True))
        return
    typer.echo(f"status: {result.status}")
    typer.echo(f"state: {result.state}")
    typer.echo(f"signing_key_id: {result.signing_key_id}")
    typer.echo(f"agreement_key_id: {result.agreement_key_id}")


def _doctor_store(state_dir: Path | None) -> MailboxKeyStore:
    if state_dir is None:
        return MailboxKeyStore.production()
    reject_prohibited_path(state_dir)
    temporary_root = Path(tempfile.gettempdir()).resolve(strict=True)
    requested = state_dir.resolve(strict=False)
    try:
        relative = requested.relative_to(temporary_root)
    except ValueError as exc:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.PROHIBITED_STORAGE) from exc
    if not relative.parts:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.PROHIBITED_STORAGE)
    kind = filesystem_kind(requested)
    if kind is not FilesystemKind.LOCAL:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.PROHIBITED_STORAGE)
    return MailboxKeyStore.for_testing(
        state_dir=requested,
        anchor_dir=requested.parent / f"{requested.name}.anchor",
        filesystem_kind=kind.value,
    )

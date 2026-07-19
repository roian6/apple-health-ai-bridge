import json
import os
import secrets
import sqlite3
import stat
from contextlib import suppress
from pathlib import Path
from typing import TYPE_CHECKING, Annotated, Final, Literal, TypeAlias, cast
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

import typer
from pydantic import TypeAdapter

from health_bridge.private_files import (
    ensure_private_directory,
    write_private_text_file,
)
from health_bridge.receiver.invitations import (
    ReceiverDeviceSelectionError,
    list_receiver_devices,
    revoke_pairing_invitation,
    revoke_receiver_device,
)
from health_bridge.receiver.pairing import (
    ReceiverPairingInvitationBundle,
    create_receiver_pairing_bundle,
    create_receiver_pairing_invitation_bundle,
    pairing_deep_link,
)
from health_bridge.receiver.pairing_setup_page import render_pairing_setup_page
from health_bridge.receiver.server import serve_receiver
from health_bridge.receiver.tokens import create_receiver_token, revoke_receiver_token
from health_bridge.storage.database import database_access_lock, database_lifecycle_lock

if TYPE_CHECKING:
    from http.client import HTTPResponse

receiver_app = typer.Typer(
    add_completion=False,
    help="User-owned local receiver commands for HealthKit companion sync.",
)
REFUSE_STDOUT_MESSAGE: Final = (
    "Refusing to print receiver bearer token to stdout by default. "
    "Re-run with --print-secret to print it once, or --output-secret <path> "
    "to write the secret JSON to a private file."
)
MUTUALLY_EXCLUSIVE_OUTPUT_MESSAGE: Final = (
    "Use only one secret destination: --print-secret or --output-secret."
)
PAIRING_FORMAT_REQUIRES_FLAG_MESSAGE: Final = (
    "Pairing output format requires --print-secret because it contains a "
    "bearer-token secret. Use --format setup-page --setup-page <path> for "
    "agent-safe onboarding."
)
WRITE_FAILURE_MESSAGE: Final = (
    "Failed to write private token output file; the issued token was revoked. "
    "Re-run the command with a writable private path."
)
SETUP_PAGE_WRITE_FAILURE_MESSAGE: Final = (
    "Failed to write private pairing setup page; the issued token was revoked. "
    "Re-run the command with a writable private path."
)
SmokeResponseValue: TypeAlias = int | str
SmokeResponse: TypeAlias = dict[str, SmokeResponseValue]
PurgeIdentity: TypeAlias = tuple[int, int, int, int, int]
SMOKE_RESPONSE_ADAPTER: Final[TypeAdapter[SmokeResponse]] = TypeAdapter(SmokeResponse)
PURGE_SIDECAR_SUFFIXES: Final = ("", "-journal", "-wal", "-shm")
PURGE_WARNING: Final = (
    "Stop the receiver before confirming. This removes only the local Health Bridge "
    "SQLite database and its sidecars; it does not delete Apple Health data."
)


class PurgeRecoveryRequiredError(OSError):
    def __init__(
        self,
        *,
        quarantine_path: Path,
        quarantined_paths: tuple[Path, ...],
        truncated_paths: tuple[Path, ...],
        residual_paths: tuple[Path, ...],
    ) -> None:
        super().__init__("receiver database purge requires manual recovery")
        self.quarantine_path: Path = quarantine_path
        self.quarantined_paths: tuple[Path, ...] = quarantined_paths
        self.truncated_paths: tuple[Path, ...] = truncated_paths
        self.residual_paths: tuple[Path, ...] = residual_paths


@receiver_app.command("purge")
def purge_receiver_store(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    confirm: Annotated[
        bool,
        typer.Option(
            "--confirm",
            help="Delete the listed local database files after safety checks.",
        ),
    ] = False,
) -> None:
    scope = tuple(Path(f"{db}{suffix}") for suffix in PURGE_SIDECAR_SUFFIXES)
    _validate_purge_scope(scope)

    existing = tuple(path for path in scope if path.exists())
    if not confirm:
        _echo_purge_result(
            status="dry-run",
            db=db,
            paths=existing,
            confirm_required=True,
        )
        return
    if not existing:
        _echo_purge_result(
            status="already-absent",
            db=db,
            paths=(),
            confirm_required=False,
        )
        return
    _validate_purge_parent(db)

    try:
        with (
            database_lifecycle_lock(
                db,
                exclusive=True,
                create=True,
                nonblocking=True,
            ),
            database_access_lock(
                db,
                exclusive=True,
                create=True,
                nonblocking=True,
            ),
        ):
            existing = _purge_database_transaction(db, scope)
    except BlockingIOError as exc:
        typer.echo("Receiver database is unavailable or still in use.", err=True)
        raise typer.Exit(code=1) from exc
    except PurgeRecoveryRequiredError as exc:
        _echo_purge_result(
            status="recovery-required",
            db=db,
            paths=exc.residual_paths,
            confirm_required=False,
            recovery=exc,
        )
        message = (
            "Receiver database purge requires recovery. Do not restart the receiver; "
        )
        message += "review the reported source and quarantine paths."
        typer.echo(message, err=True)
        raise typer.Exit(code=1) from exc
    except (OSError, sqlite3.Error) as exc:
        typer.echo("Receiver database purge failed safely.", err=True)
        raise typer.Exit(code=1) from exc

    _echo_purge_result(
        status="purged" if existing else "already-absent",
        db=db,
        paths=existing,
        confirm_required=False,
    )


def _validate_purge_scope(scope: tuple[Path, ...]) -> None:
    for path in scope:
        if path.is_symlink():
            typer.echo(f"Refusing to purge symlink path: {path}", err=True)
            raise typer.Exit(code=1)
        if path.is_dir():
            typer.echo(f"Refusing to purge directory path: {path}", err=True)
            raise typer.Exit(code=1)


def _validate_purge_parent(db_path: Path) -> None:
    absolute_parent = db_path.absolute().parent
    try:
        resolved_parent = absolute_parent.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        typer.echo("Refusing to purge through an unavailable parent path.", err=True)
        raise typer.Exit(code=1) from exc
    if resolved_parent != absolute_parent:
        typer.echo("Refusing to purge through a symlinked parent path.", err=True)
        raise typer.Exit(code=1)


def _purge_database_transaction(
    db_path: Path,
    scope: tuple[Path, ...],
) -> tuple[Path, ...]:
    if os.name != "posix":
        message = "safe receiver purge is unavailable on this platform"
        raise OSError(message)
    _require_safe_purge_primitives()
    parent = db_path.parent
    parent_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    parent_fd = os.open(parent, parent_flags)
    connection: sqlite3.Connection | None = None
    try:
        identities = _validated_purge_identities(parent_fd, scope)
        if db_path.exists():
            uri = f"{db_path.resolve(strict=True).as_uri()}?mode=rw"
            connection = sqlite3.connect(
                uri,
                uri=True,
                timeout=0,
                isolation_level=None,
            )
            _ = connection.execute("begin exclusive")
        locked_identities = _validated_purge_identities(parent_fd, scope)
        if locked_identities != identities:
            message = "purge targets changed while acquiring database lock"
            raise OSError(message)
        if not identities:
            return ()
        _quarantine_and_delete(parent_fd, db_path, identities)
        return tuple(path for path in scope if path.name in identities)
    finally:
        if connection is not None:
            connection.rollback()
            connection.close()
        os.close(parent_fd)


def _validated_purge_identities(
    parent_fd: int,
    scope: tuple[Path, ...],
) -> dict[str, PurgeIdentity]:
    identities: dict[str, PurgeIdentity] = {}
    for path in scope:
        try:
            path_stat = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(path_stat.st_mode):
            message = f"purge target is not a regular file: {path.name}"
            raise OSError(message)
        if hasattr(os, "getuid") and path_stat.st_uid != os.getuid():
            message = f"purge target is not owned by this user: {path.name}"
            raise OSError(message)
        if path_stat.st_nlink != 1:
            message = f"purge target has an unsafe link count: {path.name}"
            raise OSError(message)
        identities[path.name] = _purge_identity(path_stat)
    return identities


def _quarantine_and_delete(
    parent_fd: int,
    db_path: Path,
    identities: dict[str, PurgeIdentity],
) -> None:
    quarantine_name = f".{db_path.name}.purge-{secrets.token_hex(8)}"
    quarantine_path = db_path.parent / quarantine_name
    os.mkdir(quarantine_name, mode=0o700, dir_fd=parent_fd)
    quarantine_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    quarantine_fd = os.open(quarantine_name, quarantine_flags, dir_fd=parent_fd)
    moved: list[str] = []
    opened: dict[str, int] = {}
    truncated: list[str] = []
    purged = False
    try:
        _move_paths_to_quarantine(
            parent_fd,
            quarantine_fd,
            identities,
            moved,
        )
        _require_absent_source_paths(parent_fd, db_path)
        opened = _open_validated_quarantined_paths(quarantine_fd, identities)
        _require_absent_source_paths(parent_fd, db_path)
        deletion_order = [name for name in identities if name != db_path.name]
        if db_path.name in identities:
            deletion_order.append(db_path.name)
        for name in deletion_order:
            os.ftruncate(opened[name], 0)
            truncated.append(name)
            os.fsync(opened[name])
        _require_no_residual_after_purge(
            parent_fd,
            db_path,
            quarantine_path,
            moved,
            truncated,
        )
        purged = True
    except PurgeRecoveryRequiredError:
        raise
    except Exception as exc:
        if truncated:
            raise _purge_recovery_error(
                quarantine_path,
                moved,
                truncated,
                _present_source_paths(parent_fd, db_path),
            ) from exc
        unrestored = _rollback_quarantine(parent_fd, quarantine_fd, moved, identities)
        if unrestored:
            raise PurgeRecoveryRequiredError(
                quarantine_path=quarantine_path,
                quarantined_paths=tuple(quarantine_path / name for name in unrestored),
                truncated_paths=(),
                residual_paths=_present_source_paths(parent_fd, db_path),
            ) from exc
        raise
    finally:
        for fd in opened.values():
            os.close(fd)
        os.close(quarantine_fd)
        if not purged and not truncated:
            with suppress(OSError):
                os.rmdir(quarantine_name, dir_fd=parent_fd)


def _purge_recovery_error(
    quarantine_path: Path,
    moved: list[str],
    truncated: list[str],
    residual_paths: tuple[Path, ...],
) -> PurgeRecoveryRequiredError:
    return PurgeRecoveryRequiredError(
        quarantine_path=quarantine_path,
        quarantined_paths=tuple(quarantine_path / name for name in moved),
        truncated_paths=tuple(quarantine_path / name for name in truncated),
        residual_paths=residual_paths,
    )


def _require_no_residual_after_purge(
    parent_fd: int,
    db_path: Path,
    quarantine_path: Path,
    moved: list[str],
    truncated: list[str],
) -> None:
    residual_paths = _present_source_paths(parent_fd, db_path)
    if residual_paths:
        raise _purge_recovery_error(
            quarantine_path,
            moved,
            truncated,
            residual_paths,
        )


def _move_paths_to_quarantine(
    parent_fd: int,
    quarantine_fd: int,
    identities: dict[str, PurgeIdentity],
    moved: list[str],
) -> None:
    for name, identity in identities.items():
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if _purge_identity(current) != identity:
            message = f"purge target changed before quarantine: {name}"
            raise OSError(message)
        os.rename(
            name,
            name,
            src_dir_fd=parent_fd,
            dst_dir_fd=quarantine_fd,
        )
        moved.append(name)
        moved_stat = os.stat(name, dir_fd=quarantine_fd, follow_symlinks=False)
        if _purge_identity(moved_stat) != identity:
            message = f"purge target changed during quarantine: {name}"
            raise OSError(message)


def _require_absent_source_paths(
    parent_fd: int,
    db_path: Path,
) -> None:
    present = _present_source_paths(parent_fd, db_path)
    if present:
        message = f"purge target reappeared during quarantine: {present[0].name}"
        raise OSError(message)


def _present_source_paths(
    parent_fd: int,
    db_path: Path,
) -> tuple[Path, ...]:
    present: list[Path] = []
    for suffix in PURGE_SIDECAR_SUFFIXES:
        name = Path(f"{db_path}{suffix}").name
        try:
            _ = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        present.append(db_path.parent / name)
    return tuple(present)


def _open_validated_quarantined_paths(
    quarantine_fd: int,
    identities: dict[str, PurgeIdentity],
) -> dict[str, int]:
    opened: dict[str, int] = {}
    flags = os.O_WRONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    for name, identity in identities.items():
        try:
            fd = os.open(name, flags, dir_fd=quarantine_fd)
            _require_opened_purge_identity(fd, name, identity)
            opened[name] = fd
        except Exception:
            for opened_fd in opened.values():
                os.close(opened_fd)
            raise
    return opened


def _require_opened_purge_identity(
    fd: int,
    name: str,
    identity: PurgeIdentity,
) -> None:
    if _purge_identity(os.fstat(fd)) != identity:
        message = f"quarantined purge target changed: {name}"
        raise OSError(message)


def _rollback_quarantine(
    parent_fd: int,
    quarantine_fd: int,
    moved: list[str],
    identities: dict[str, PurgeIdentity],
) -> tuple[str, ...]:
    unrestored: list[str] = []
    for name in reversed(moved):
        try:
            quarantined = os.stat(name, dir_fd=quarantine_fd, follow_symlinks=False)
        except FileNotFoundError:
            unrestored.append(name)
            continue
        if _purge_identity(quarantined) != identities[name]:
            unrestored.append(name)
            continue
        try:
            _ = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            os.rename(
                name,
                name,
                src_dir_fd=quarantine_fd,
                dst_dir_fd=parent_fd,
            )
            restored = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if _purge_identity(restored) != identities[name]:
                unrestored.append(name)
        else:
            unrestored.append(name)
    return tuple(reversed(unrestored))


def _require_safe_purge_primitives() -> None:
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        message = "safe receiver purge requires O_NOFOLLOW and O_DIRECTORY"
        raise OSError(message)
    for function in (os.open, os.stat, os.rename, os.mkdir, os.rmdir):
        if function not in os.supports_dir_fd:
            message = "safe receiver purge requires directory-relative operations"
            raise OSError(message)
    if os.stat not in os.supports_follow_symlinks:
        message = "safe receiver purge requires no-follow stat operations"
        raise OSError(message)


def _purge_identity(path_stat: os.stat_result) -> PurgeIdentity:
    return (
        path_stat.st_dev,
        path_stat.st_ino,
        path_stat.st_mode,
        path_stat.st_uid,
        path_stat.st_nlink,
    )


def _echo_purge_result(
    *,
    status: str,
    db: Path,
    paths: tuple[Path, ...],
    confirm_required: bool,
    recovery: PurgeRecoveryRequiredError | None = None,
) -> None:
    payload: dict[str, object] = {
        "status": status,
        "database": str(db),
        "paths": [str(path) for path in paths],
        "confirm_required": confirm_required,
        "warning": PURGE_WARNING,
    }
    if recovery is not None:
        payload["quarantine_path"] = str(recovery.quarantine_path)
        payload["quarantined_paths"] = [
            str(path) for path in recovery.quarantined_paths
        ]
        payload["truncated_paths"] = [str(path) for path in recovery.truncated_paths]
    typer.echo(
        json.dumps(
            payload,
            sort_keys=True,
        )
    )


@receiver_app.command("create-token")
def create_token(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    label: Annotated[
        str,
        typer.Option("--label", help="Human-readable device or companion label."),
    ],
    print_secret: Annotated[
        bool,
        typer.Option(
            "--print-secret",
            help="Print the one-time receiver bearer token to stdout.",
        ),
    ] = False,
    output_secret: Annotated[
        Path | None,
        typer.Option(
            "--output-secret",
            help="Write one-time receiver bearer token JSON to this private file.",
        ),
    ] = None,
) -> None:
    if print_secret and output_secret is not None:
        typer.echo(MUTUALLY_EXCLUSIVE_OUTPUT_MESSAGE, err=True)
        raise typer.Exit(code=1)
    if not print_secret and output_secret is None:
        typer.echo(REFUSE_STDOUT_MESSAGE, err=True)
        raise typer.Exit(code=1)

    if output_secret is not None:
        try:
            _validate_private_secret_output_path(output_secret)
        except OSError as exc:
            typer.echo(
                f"Failed to open private token output file: {exc.strerror}",
                err=True,
            )
            raise typer.Exit(code=1) from exc

    issued = create_receiver_token(db, label=label)
    secret_payload = {
        "label": issued.label,
        "token": issued.token,
        "token_prefix": issued.token_prefix,
        "warning": (
            "Store this token now; it is shown once and only a hash is kept locally."
        ),
    }
    if output_secret is not None:
        secret_text = json.dumps(secret_payload, sort_keys=True) + "\n"
        try:
            write_private_text_file(output_secret, secret_text)
        except OSError as exc:
            revoke_receiver_token(db, issued.token_prefix)
            typer.echo(WRITE_FAILURE_MESSAGE, err=True)
            raise typer.Exit(code=1) from exc
        typer.echo(
            json.dumps(
                {
                    "label": issued.label,
                    "secret_file": str(output_secret),
                    "token_prefix": issued.token_prefix,
                    "warning": (
                        "Secret token JSON was written to the requested private "
                        "file. Keep it out of chat, Git, wiki, and logs."
                    ),
                },
                sort_keys=True,
            ),
        )
        return

    typer.echo(json.dumps(secret_payload, sort_keys=True))


def _validate_private_secret_output_path(path: Path) -> None:
    ensure_private_directory(path.parent)
    if path.is_symlink():
        msg = f"refusing to write private token file through symlink: {path}"
        raise OSError(msg)
    if path.is_dir():
        raise IsADirectoryError(str(path))


@receiver_app.command("create-pairing")
def create_pairing(  # noqa: PLR0912, PLR0913 - Typer exposes CLI branches/options.
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    label: Annotated[
        str,
        typer.Option("--label", help="Human-readable device or companion label."),
    ],
    receiver_url: Annotated[
        str,
        typer.Option(
            "--receiver-url", help="Receiver /v1/batches URL for the companion."
        ),
    ],
    output_format: Annotated[
        Literal["json", "deeplink", "setup-page"],
        typer.Option(
            "--format",
            help=(
                "Output secret JSON, secret deep-link summary, or a private "
                "setup page. Secret stdout formats require --print-secret."
            ),
        ),
    ] = "setup-page",
    setup_page: Annotated[
        Path | None,
        typer.Option("--setup-page", help="Path for --format setup-page HTML output."),
    ] = None,
    print_secret: Annotated[
        bool,
        typer.Option(
            "--print-secret",
            help="Allow secret-bearing pairing output on stdout for expert use.",
        ),
    ] = False,
    legacy_v1: Annotated[
        bool,
        typer.Option(
            "--legacy-v1",
            help="Issue a legacy long-lived bearer-token pairing bundle.",
        ),
    ] = False,
) -> None:
    if output_format == "setup-page" and setup_page is None:
        typer.echo("--setup-page is required when --format setup-page.", err=True)
        raise typer.Exit(code=1)
    if output_format in {"json", "deeplink"} and not print_secret:
        typer.echo(PAIRING_FORMAT_REQUIRES_FLAG_MESSAGE, err=True)
        raise typer.Exit(code=1)

    if legacy_v1:
        bundle = create_receiver_pairing_bundle(
            db,
            label=label,
            receiver_url=receiver_url,
        )
    else:
        bundle = create_receiver_pairing_invitation_bundle(
            db,
            label=label,
            receiver_url=receiver_url,
        )
    deep_link = pairing_deep_link(bundle)
    if output_format == "deeplink":
        if isinstance(bundle, ReceiverPairingInvitationBundle):
            output = {
                "label": bundle.label,
                "pairing_url": deep_link,
                "pairing_schema_id": bundle.schema_id,
                "invitation_expires_at": bundle.expires_at,
                "warning": bundle.warning,
            }
        else:
            output = {
                "label": bundle.label,
                "pairing_url": deep_link,
                "token_prefix": bundle.token_prefix,
                "warning": bundle.warning,
            }
    elif output_format == "setup-page":
        setup_page_path = cast("Path", setup_page)
        try:
            write_private_text_file(
                setup_page_path,
                render_pairing_setup_page(bundle, deep_link),
            )
        except OSError as exc:
            if isinstance(bundle, ReceiverPairingInvitationBundle):
                revoke_pairing_invitation(db, bundle.invitation_id)
            else:
                revoke_receiver_token(db, bundle.token_prefix)
            typer.echo(SETUP_PAGE_WRITE_FAILURE_MESSAGE, err=True)
            raise typer.Exit(code=1) from exc
        if isinstance(bundle, ReceiverPairingInvitationBundle):
            output = {
                "label": bundle.label,
                "setup_page": str(setup_page_path),
                "pairing_schema_id": bundle.schema_id,
                "invitation_expires_at": bundle.expires_at,
                "warning": (
                    "Setup page contains a temporary, single-use pairing invitation. "
                    "Open it on your own device and delete it after pairing."
                ),
            }
        else:
            output = {
                "label": bundle.label,
                "setup_page": str(setup_page_path),
                "token_prefix": bundle.token_prefix,
                "warning": (
                    "Legacy setup page contains a pairing secret. Open it on your "
                    "own device and delete it after pairing."
                ),
            }
    else:
        output = bundle.model_dump(mode="json")
        output["pairing_url"] = deep_link
    typer.echo(json.dumps(output, sort_keys=True))


@receiver_app.command("list-devices")
def list_devices(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    include_revoked: Annotated[
        bool,
        typer.Option("--include-revoked", help="Include previously revoked devices."),
    ] = False,
) -> None:
    try:
        devices = list_receiver_devices(db, include_revoked=include_revoked)
    except (sqlite3.Error, OSError) as exc:
        typer.echo("Receiver device storage is unavailable.", err=True)
        raise typer.Exit(code=1) from exc
    output = {
        "devices": [
            {
                "device_ref": device.device_ref,
                "label": device.label,
                "platform": device.platform,
                "last_paired_at": device.last_paired_at,
                "revoked_at": device.revoked_at,
            }
            for device in devices
        ]
    }
    typer.echo(json.dumps(output, sort_keys=True))


@receiver_app.command("revoke-device")
def revoke_device(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    device_ref: Annotated[
        str,
        typer.Option(
            "--device-ref",
            help="Redacted reference returned by receiver list-devices.",
        ),
    ],
) -> None:
    try:
        revoked_token_count = revoke_receiver_device(db, device_ref)
    except ReceiverDeviceSelectionError as exc:
        typer.echo("Device reference is invalid or unavailable.", err=True)
        raise typer.Exit(code=1) from exc
    except (sqlite3.Error, OSError) as exc:
        typer.echo("Receiver device storage is unavailable.", err=True)
        raise typer.Exit(code=1) from exc
    typer.echo(
        json.dumps(
            {
                "revoked_device_ref": device_ref.strip().lower(),
                "revoked_token_count": revoked_token_count,
            },
            sort_keys=True,
        )
    )


@receiver_app.command("revoke-token")
def revoke_token(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    token_prefix: Annotated[
        str,
        typer.Option("--token-prefix", help="Prefix returned by create-token."),
    ],
) -> None:
    revoke_receiver_token(db, token_prefix)
    typer.echo(json.dumps({"revoked_token_prefix": token_prefix}, sort_keys=True))


@receiver_app.command("start")
def start(
    db: Annotated[
        Path,
        typer.Option("--db", help="User-owned SQLite database path."),
    ],
    host: Annotated[
        str,
        typer.Option("--host", help="Bind host. Keep 127.0.0.1 for local-only."),
    ] = "127.0.0.1",
    port: Annotated[
        int,
        typer.Option("--port", help="Bind port."),
    ] = 8765,
) -> None:
    typer.echo(
        f"health-bridge receiver listening on http://{host}:{port}",
        err=True,
    )
    try:
        serve_receiver(db_path=db, host=host, port=port)
    except KeyboardInterrupt:
        raise typer.Exit(code=0) from None


@receiver_app.command("smoke")
def smoke(
    input_path: Annotated[
        Path,
        typer.Option("--input", help="health_bridge.batch.v1 JSON payload."),
    ],
    token: Annotated[
        str,
        typer.Option("--token", help="Receiver bearer token."),
    ],
    url: Annotated[
        str,
        typer.Option("--url", help="Receiver /v1/batches endpoint."),
    ] = "http://127.0.0.1:8765/v1/batches",
) -> None:
    _validate_receiver_url(url)
    request = Request(  # noqa: S310 - URL scheme is validated above.
        url,
        data=input_path.read_bytes(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        # `_validate_receiver_url` above restricts this request to HTTP(S).
        with cast(
            "HTTPResponse",
            urlopen(request, timeout=10),  # noqa: S310  # nosec B310
        ) as response:
            body = SMOKE_RESPONSE_ADAPTER.validate_json(response.read())
            status = response.status
    except HTTPError as exc:
        typer.echo(f"Receiver smoke failed: HTTP {exc.code}.", err=True)
        raise typer.Exit(code=1) from exc
    except URLError as exc:
        typer.echo("Receiver smoke failed: receiver was not reachable.", err=True)
        raise typer.Exit(code=1) from exc
    body["http_status"] = status
    typer.echo(json.dumps(body, sort_keys=True))


def _validate_receiver_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        typer.echo("Receiver smoke failed: URL must use http or https.", err=True)
        raise typer.Exit(code=1)

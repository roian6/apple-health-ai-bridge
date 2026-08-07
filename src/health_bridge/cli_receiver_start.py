from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Final, Protocol

import typer

from health_bridge.launchd import LaunchdServiceError
from health_bridge.receiver.transports import ReceiverTransport

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

    from health_bridge.launchd import LaunchdServiceRequest
    from health_bridge.mailbox.connections import MailboxConnectionStore
    from health_bridge.receiver.mailbox_keys import MailboxKeyStore
    from health_bridge.receiver.transports import PublicReceiverTransport

DEFAULT_RECEIVER_HOST: Final = "127.0.0.1"
DEFAULT_RECEIVER_PORT: Final = 8765


class TransportSelector(Protocol):
    def __call__(
        self,
        requested: PublicReceiverTransport,
        *,
        mailbox_root: Path | None,
        icloud_container_identifier: str | None,
    ) -> ReceiverTransport: ...


class ReceiverServer(Protocol):
    def __call__(  # noqa: PLR0913 -- Mirrors the established receiver server API.
        self,
        db_path: Path,
        host: str,
        port: int,
        *,
        mailbox_key_store: MailboxKeyStore | None,
        mailbox_connection_store: MailboxConnectionStore | None,
        mailbox_root: Path | None,
    ) -> None: ...


@dataclass(frozen=True, slots=True)
class ReceiverStartOptions:
    db: Path | None
    host: str
    port: int
    mailbox_root: Path | None
    icloud_container_identifier: str | None
    service_config: Path | None


@dataclass(frozen=True, slots=True)
class ReceiverStartDependencies:
    load_service_config: Callable[[Path], LaunchdServiceRequest]
    select_transport: TransportSelector
    create_key_store: Callable[[], MailboxKeyStore]
    create_connection_store: Callable[[], MailboxConnectionStore]
    serve: ReceiverServer


def run_receiver_start(
    options: ReceiverStartOptions,
    dependencies: ReceiverStartDependencies,
) -> None:
    db = options.db
    host = options.host
    port = options.port
    mailbox_root = options.mailbox_root
    container_identifier = options.icloud_container_identifier
    if options.service_config is not None:
        if (
            db is not None
            or mailbox_root is not None
            or container_identifier is not None
            or host != DEFAULT_RECEIVER_HOST
            or port != DEFAULT_RECEIVER_PORT
        ):
            typer.echo(
                "Service configuration cannot be combined with receiver options.",
                err=True,
            )
            raise typer.Exit(code=2)
        try:
            service_request = dependencies.load_service_config(options.service_config)
        except LaunchdServiceError as exc:
            typer.echo(str(exc), err=True)
            raise typer.Exit(code=1) from None
        db = service_request.db_path
        host = service_request.host
        port = service_request.port
        mailbox_root = service_request.mailbox_root
        container_identifier = service_request.icloud_container_identifier
    if db is None:
        typer.echo("Receiver start requires --db.", err=True)
        raise typer.Exit(code=2)
    selected_transport = dependencies.select_transport(
        "icloud-mailbox" if mailbox_root is not None else "direct",
        mailbox_root=mailbox_root,
        icloud_container_identifier=container_identifier,
    )
    mailbox_key_store = (
        dependencies.create_key_store()
        if selected_transport is ReceiverTransport.MAILBOX
        else None
    )
    mailbox_connection_store = (
        dependencies.create_connection_store()
        if selected_transport is ReceiverTransport.MAILBOX
        else None
    )
    typer.echo(
        f"health-bridge receiver listening on http://{host}:{port}",
        err=True,
    )
    try:
        dependencies.serve(
            db_path=db,
            host=host,
            port=port,
            mailbox_key_store=mailbox_key_store,
            mailbox_connection_store=mailbox_connection_store,
            mailbox_root=mailbox_root,
        )
    except KeyboardInterrupt:
        raise typer.Exit(code=0) from None

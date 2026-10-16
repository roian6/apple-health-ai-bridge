import os
import stat
import sys
from enum import StrEnum
from pathlib import Path
from typing import Final, Literal, assert_never

PublicReceiverTransport = Literal["direct", "icloud-mailbox"]
DIRECT_MAILBOX_CONFIGURATION_ERROR: Final = (
    "Mailbox configuration requires --transport icloud-mailbox."
)
MAILBOX_CONFIGURATION_REQUIRED_ERROR: Final = (
    "Encrypted iCloud Mailbox requires --mailbox-root."
)
MAILBOX_CONTAINER_IDENTIFIER_REQUIRED_ERROR: Final = (
    "Encrypted iCloud Mailbox requires --icloud-container-identifier."
)
MAILBOX_HOST_UNAVAILABLE_ERROR: Final = (
    "Encrypted iCloud Mailbox is unavailable on this host."
)
MAILBOX_TOPOLOGY_UNAVAILABLE_ERROR: Final = (
    "Encrypted iCloud Mailbox topology is unavailable."
)
MAILBOX_INVITATION_REQUIRED_ERROR: Final = (
    "Encrypted iCloud Mailbox requires temporary invitation pairing."
)
_DIRECTORY_FLAGS: Final = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class ReceiverTransport(StrEnum):
    DIRECT = "direct"
    MAILBOX = "mailbox"


class ReceiverTransportSelectionError(ValueError):
    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message: str = message


def select_receiver_transport(  # noqa: PLR0913 - policy inputs stay explicit.
    requested: PublicReceiverTransport,
    *,
    mailbox_root: Path | None,
    icloud_container_identifier: str | None = None,
    platform: str | None = None,
    home: Path | None = None,
    mailbox_allowed: bool = True,
) -> ReceiverTransport:
    match requested:
        case "direct":
            if mailbox_root is not None or icloud_container_identifier is not None:
                raise ReceiverTransportSelectionError(
                    DIRECT_MAILBOX_CONFIGURATION_ERROR
                )
            return ReceiverTransport.DIRECT
        case "icloud-mailbox":
            if not mailbox_allowed:
                raise ReceiverTransportSelectionError(MAILBOX_INVITATION_REQUIRED_ERROR)
            host_platform = sys.platform if platform is None else platform
            if host_platform != "darwin":
                raise ReceiverTransportSelectionError(MAILBOX_HOST_UNAVAILABLE_ERROR)
            if mailbox_root is None:
                raise ReceiverTransportSelectionError(
                    MAILBOX_CONFIGURATION_REQUIRED_ERROR
                )
            if not icloud_container_identifier:
                raise ReceiverTransportSelectionError(
                    MAILBOX_CONTAINER_IDENTIFIER_REQUIRED_ERROR
                )
            _require_supported_mailbox_root(
                mailbox_root,
                Path.home() if home is None else home,
                icloud_container_identifier,
            )
            return ReceiverTransport.MAILBOX
    assert_never(requested)


def _require_supported_mailbox_root(
    mailbox_root: Path,
    home: Path,
    icloud_container_identifier: str,
) -> None:
    container_component = icloud_container_identifier.replace(".", "~")
    if (
        container_component in {"", ".", ".."}
        or Path(container_component).name != container_component
    ):
        raise ReceiverTransportSelectionError(MAILBOX_TOPOLOGY_UNAVAILABLE_ERROR)
    expected_root = (
        home
        / "Library/Mobile Documents"
        / container_component
        / "Documents/HealthBridgeMailbox/v1"
    ).absolute()
    if mailbox_root.absolute() != expected_root:
        raise ReceiverTransportSelectionError(MAILBOX_TOPOLOGY_UNAVAILABLE_ERROR)
    try:
        descriptor = os.open(home.absolute(), _DIRECTORY_FLAGS)
        try:
            for component in expected_root.relative_to(home.absolute()).parts:
                try:
                    child = _open_directory_at(descriptor, component)
                except FileNotFoundError:
                    return
                os.close(descriptor)
                descriptor = child
        finally:
            os.close(descriptor)
    except (OSError, ValueError) as exc:
        raise ReceiverTransportSelectionError(
            MAILBOX_TOPOLOGY_UNAVAILABLE_ERROR
        ) from exc


def _open_directory_at(parent_fd: int, name: str) -> int:
    descriptor = os.open(name, _DIRECTORY_FLAGS, dir_fd=parent_fd)
    if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise OSError
    return descriptor

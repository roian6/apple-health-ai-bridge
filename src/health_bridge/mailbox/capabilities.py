"""Best-effort metadata publication for an already trusted mailbox connection."""

from __future__ import annotations

from enum import StrEnum
from typing import TYPE_CHECKING, cast

from health_bridge.contract._delivery_common import DeliveryProtocolError
from health_bridge.contract.mailbox_capabilities import (
    CAPABILITIES_FILENAME,
    MAX_CAPABILITIES_BYTES,
    create_mailbox_capabilities,
)
from health_bridge.contract.receiver_capabilities import (
    RECEIVER_CAPABILITIES,
    ReceiverCapabilitiesV1,
)
from health_bridge.mailbox.connections import MailboxConnectionError
from health_bridge.mailbox.filesystem import (
    MailboxFileError,
    MailboxFileErrorCode,
    read_final_at,
)
from health_bridge.receiver._mailbox_key_models import MailboxKeyStoreError

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

    from health_bridge.contract._hbjcs1 import JsonValue
    from health_bridge.mailbox.filesystem import MailboxDirectoryHandle
    from health_bridge.receiver.delivery_acceptance import DeliveryTrustedConnection


class CapabilityPublicationResult(StrEnum):
    UNCHANGED = "unchanged"
    STORED = "stored"
    UNAVAILABLE = "unavailable"


def publish_receiver_capabilities(
    directory: MailboxDirectoryHandle,
    *,
    load_connection: Callable[[Path], DeliveryTrustedConnection],
    publish: Callable[[MailboxDirectoryHandle, bytes], None],
    capabilities: ReceiverCapabilitiesV1 = RECEIVER_CAPABILITIES,
) -> CapabilityPublicationResult:
    """Use existing trust only; failures consume no extra maintenance opportunity."""
    directory.validate_attached()
    try:
        connection = load_connection(directory.path)
        if (
            connection.sender_key_revoked
            or connection.receiver_id.hex() != directory.receiver_name
            or connection.device_id.hex() != directory.device_name
        ):
            return CapabilityPublicationResult.UNAVAILABLE
        fields = cast("dict[str, JsonValue]", capabilities.model_dump(mode="json"))
        payload = create_mailbox_capabilities(
            receiver_id=connection.receiver_id,
            device_id=connection.device_id,
            connection_generation=connection.connection_generation,
            receiver_signing_private_key=connection.receiver_signing_private_key,
            capabilities=fields,
        )
        directory.validate_attached()
        try:
            current = read_final_at(
                directory.mailbox_fd,
                CAPABILITIES_FILENAME,
                maximum_bytes=MAX_CAPABILITIES_BYTES,
            )
        except MailboxFileError as exc:
            if not isinstance(exc.__cause__, FileNotFoundError):
                raise
        else:
            directory.validate_attached()
            if current.content == payload:
                return CapabilityPublicationResult.UNCHANGED
        publish(directory, payload)
        directory.validate_attached()
    except MailboxFileError as exc:
        if exc.code is MailboxFileErrorCode.PATH_REPLACED:
            raise
        return CapabilityPublicationResult.UNAVAILABLE
    except (
        MailboxConnectionError,
        MailboxKeyStoreError,
        DeliveryProtocolError,
        OSError,
    ):
        return CapabilityPublicationResult.UNAVAILABLE
    else:
        return CapabilityPublicationResult.STORED

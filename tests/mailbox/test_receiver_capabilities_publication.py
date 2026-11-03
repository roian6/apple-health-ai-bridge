from __future__ import annotations

from dataclasses import replace
from typing import TYPE_CHECKING

import pytest

from health_bridge.contract.receiver_capabilities import RECEIVER_CAPABILITIES
from health_bridge.mailbox.capabilities import publish_receiver_capabilities
from health_bridge.mailbox.connections import (
    MailboxConnectionError,
    MailboxConnectionErrorCode,
)
from health_bridge.mailbox.filesystem import MailboxFileError, open_mailbox_directory
from health_bridge.mailbox.native_ack_publication import (
    NativeAckPublicationError,
)
from tests.mailbox.test_native_ack_publication import native_publisher
from tests.receiver.delivery_acceptance_support import connection

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.mailbox.filesystem import MailboxDirectoryHandle
    from health_bridge.receiver.delivery_acceptance import DeliveryTrustedConnection


def _mailbox(root: Path) -> Path:
    mailbox = root / ("02" * 16) / ("03" * 16)
    for lane in ("deliveries", "acks", "quarantine"):
        (mailbox / lane).mkdir(parents=True, exist_ok=True)
    return mailbox


@pytest.mark.parametrize(
    "failure",
    [
        "ok",
        "digest",
        "identity",
        "operation",
        "provider_bytes",
        "duplicate",
        "boolean",
        "nested",
        "nested_field",
        "float",
        "flag_integer",
        "noncanonical",
        "wrong_exit",
        "unbound",
    ],
)
def test_capability_ipc_binds_receipt_and_rereads_fixed_target(
    tmp_path: Path,
    failure: str,
) -> None:
    mailbox = _mailbox(tmp_path)
    publisher = native_publisher(tmp_path, failure)
    payload = b'{"synthetic":"signed metadata"}'
    with open_mailbox_directory(mailbox) as directory:
        if failure == "ok":
            publisher.publish_capabilities(directory, payload)
            assert (mailbox / "receiver-capabilities.json").read_bytes() == payload
        else:
            with pytest.raises(NativeAckPublicationError):
                publisher.publish_capabilities(directory, payload)
    assert not (tmp_path / "protocol").exists()


def test_publication_same_content_no_rewrite_changed_content_replaces(
    tmp_path: Path,
) -> None:

    mailbox = _mailbox(tmp_path / "mailboxes")
    payloads: list[bytes] = []

    def publish(directory: MailboxDirectoryHandle, payload: bytes) -> None:
        payloads.append(payload)
        _ = (directory.path / "receiver-capabilities.json").write_bytes(payload)

    with open_mailbox_directory(mailbox) as directory:
        for _ in range(2):
            _ = publish_receiver_capabilities(
                directory, load_connection=lambda _: connection(), publish=publish
            )
        assert len(payloads) == 1
        _ = publish_receiver_capabilities(
            directory,
            load_connection=lambda _: connection(),
            publish=publish,
            capabilities=RECEIVER_CAPABILITIES.model_copy(
                update={"nutrition_supported": False}
            ),
        )
        assert len(payloads) == 2
        assert payloads[0] != payloads[1]


@pytest.mark.parametrize(
    "refusal", ["revoked", "wrong_device", "untrusted", "symlink", "detached"]
)
def test_publication_refuses_untrusted_or_unsafe_target(
    tmp_path: Path, refusal: str
) -> None:

    mailbox = _mailbox(tmp_path / "mailboxes")
    calls: list[bytes] = []
    trusted = connection(revoked=refusal == "revoked")
    if refusal == "wrong_device":
        trusted = replace(trusted, device_id=b"x" * 16)

    def load(_path: Path) -> DeliveryTrustedConnection:
        if refusal == "untrusted":
            raise MailboxConnectionError(MailboxConnectionErrorCode.UNAVAILABLE)
        return trusted

    with open_mailbox_directory(mailbox) as directory:
        if refusal == "symlink":
            target = tmp_path / "target"
            _ = target.write_bytes(b"synthetic")
            (mailbox / "receiver-capabilities.json").symlink_to(target)
        if refusal == "detached":
            _ = mailbox.rename(mailbox.with_name("detached"))
            with pytest.raises(MailboxFileError):
                _ = publish_receiver_capabilities(
                    directory,
                    load_connection=load,
                    publish=lambda _d, p: calls.append(p),
                )
        else:
            _ = publish_receiver_capabilities(
                directory, load_connection=load, publish=lambda _d, p: calls.append(p)
            )
    assert calls == []

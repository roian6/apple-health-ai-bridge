from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import replace
from typing import TYPE_CHECKING, cast

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
    NativeAckPublisher,
    NativeAckPublisherConfig,
)
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


def _publisher(root: Path) -> NativeAckPublisher:
    executable = root / "synthetic-helper"
    _ = executable.write_bytes(b"synthetic")
    executable.chmod(0o700)
    return NativeAckPublisher(
        NativeAckPublisherConfig(executable, root / "protocol", 1)
    )


@pytest.mark.parametrize(
    "failure",
    [
        None,
        "unsupported",
        "timeout",
        "digest",
        "identity",
        "operation",
        "bytes",
        "duplicate",
        "boolean",
        "nested",
        "nested_field",
        "float",
    ],
)
def test_capability_ipc_binds_receipt_and_rereads_fixed_target(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    failure: str | None,
) -> None:
    mailbox = _mailbox(tmp_path / "mailboxes")
    publisher = _publisher(tmp_path)
    payload = b'{"synthetic":"signed metadata"}'

    def run(argv: list[str], **_kwargs: object) -> subprocess.CompletedProcess[bytes]:
        operation, request_id = argv[1].split(":")
        assert operation == "capabilities"
        root = tmp_path / "protocol"
        request = cast(
            "dict[str, object]",
            json.loads((root / "requests" / f"{request_id}.json").read_text()),
        )
        assert request == {
            "version": 1,
            "operation": "receiver_capabilities",
            "requestID": request_id,
            "receiver": "02" * 16,
            "device": "03" * 16,
            "byteCount": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
        assert (root / "staging" / f"{request_id}.json").read_bytes() == payload
        if failure == "timeout":
            raise subprocess.TimeoutExpired(argv, 1)
        if failure == "unsupported":
            return subprocess.CompletedProcess(argv, 1)
        receipt = {**request, "stored": True, "exactBytes": True, "isUbiquitous": True}
        mutations: dict[str, dict[str, object]] = {
            "digest": {"sha256": "00" * 32},
            "identity": {"device": "04" * 16},
            "operation": {"operation": "ack"},
            "boolean": {"stored": 1},
            "float": {"version": 1.0},
        }
        receipt.update(mutations.get(failure or "", {}))
        encoded = json.dumps(receipt, sort_keys=True, separators=(",", ":"))
        if failure == "nested":
            encoded = "[" * 1500 + "]" * 1500
        if failure == "nested_field":
            # Decoding succeeds; the scalar comparison must reject this value
            # without traversing or serializing its nested contents.
            encoded = encoded.replace(
                '"stored":true', '"stored":' + "[" * 64 + "]" * 64
            )
        if failure == "duplicate":
            encoded = encoded.replace('"stored":true', '"stored":false,"stored":true')
        path = root / "receipts" / f"{request_id}.json"
        _ = path.write_text(encoded)
        path.chmod(0o600)
        _ = (mailbox / "receiver-capabilities.json").write_bytes(
            b"wrong" if failure == "bytes" else payload
        )
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(subprocess, "run", run)
    with open_mailbox_directory(mailbox) as directory:
        if failure is None:
            publisher.publish_capabilities(directory, payload)
        else:
            with pytest.raises(NativeAckPublicationError):
                publisher.publish_capabilities(directory, payload)
    for lane in ("requests", "staging", "receipts"):
        assert not list((tmp_path / "protocol" / lane).iterdir())


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

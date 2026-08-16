from __future__ import annotations

import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path
from typing import cast

import pytest

from health_bridge.mailbox.filesystem import open_mailbox_directory
from health_bridge.mailbox.native_ack_publication import (
    NativeAckPublicationError,
    NativeAckPublisher,
    NativeAckPublisherConfig,
)
from health_bridge.mailbox.publication import PublicationState

RECEIVER = "11" * 16
DEVICE = "22" * 16
FINAL_NAME = f"{'33' * 16}.hba"
PAYLOAD = b"signed-ack"


def _mailbox(tmp_path: Path) -> Path:
    mailbox = tmp_path / RECEIVER / DEVICE
    for lane in ("deliveries", "acks", "quarantine"):
        (mailbox / lane).mkdir(parents=True, exist_ok=True)
    return mailbox


def _publisher(tmp_path: Path) -> NativeAckPublisher:
    helper = tmp_path / "helper"
    _ = helper.write_bytes(b"helper")
    helper.chmod(0o700)
    return NativeAckPublisher(
        NativeAckPublisherConfig(
            helper_executable=helper,
            protocol_root=tmp_path / "protocol",
            timeout_seconds=1,
        )
    )


def test_production_config_derives_protocol_root_from_installed_bundle(
    tmp_path: Path,
) -> None:
    bundle_id = "com.example.HealthBridgeMailboxAckPublisher"
    app = (
        tmp_path
        / "Library/Application Support/HealthBridge/helpers"
        / "HealthBridgeMailboxAckPublisher.app"
    )
    contents = app / "Contents"
    contents.mkdir(parents=True)
    _ = (contents / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleIdentifier": bundle_id})
    )

    config = NativeAckPublisherConfig.production(home=tmp_path)

    assert config.protocol_root == (
        tmp_path
        / "Library/Containers"
        / bundle_id
        / "Data/Library/Application Support/HealthBridgeAckPublisher"
    )


@pytest.mark.parametrize(
    "bundle_id",
    [None, "", "../escape", "contains space", "a" * 256],
)
def test_production_config_rejects_invalid_installed_bundle_identity(
    tmp_path: Path,
    bundle_id: object,
) -> None:
    app = (
        tmp_path
        / "Library/Application Support/HealthBridge/helpers"
        / "HealthBridgeMailboxAckPublisher.app"
    )
    contents = app / "Contents"
    contents.mkdir(parents=True)
    payload = {} if bundle_id is None else {"CFBundleIdentifier": bundle_id}
    _ = (contents / "Info.plist").write_bytes(plistlib.dumps(payload))

    with pytest.raises(NativeAckPublicationError, match="bundle identity"):
        _ = NativeAckPublisherConfig.production(home=tmp_path)


def test_macos_production_config_refuses_unowned_helper_before_publication(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = (
        tmp_path
        / "Library/Application Support/HealthBridge/helpers"
        / "HealthBridgeMailboxAckPublisher.app"
    )
    contents = app / "Contents"
    contents.mkdir(parents=True)
    _ = (contents / "Info.plist").write_bytes(
        plistlib.dumps(
            {"CFBundleIdentifier": "com.example.HealthBridgeMailboxAckPublisher"}
        )
    )
    monkeypatch.setattr(sys, "platform", "darwin")

    with pytest.raises(NativeAckPublicationError, match="not ready"):
        _ = NativeAckPublisherConfig.production(home=tmp_path)


@pytest.mark.parametrize("symlink_component", ["app", "contents", "info"])
def test_production_config_rejects_symlinked_bundle_path_component(
    tmp_path: Path,
    symlink_component: str,
) -> None:
    helpers = tmp_path / "Library/Application Support/HealthBridge/helpers"
    real_app = tmp_path / "real-helper.app"
    real_contents = real_app / "Contents"
    real_contents.mkdir(parents=True)
    _ = (real_contents / "Info.plist").write_bytes(
        plistlib.dumps(
            {"CFBundleIdentifier": "com.example.HealthBridgeMailboxAckPublisher"}
        )
    )
    app = helpers / "HealthBridgeMailboxAckPublisher.app"
    helpers.mkdir(parents=True)
    if symlink_component == "app":
        app.symlink_to(real_app, target_is_directory=True)
    elif symlink_component == "contents":
        app.mkdir()
        (app / "Contents").symlink_to(real_contents, target_is_directory=True)
    else:
        contents = app / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").symlink_to(real_contents / "Info.plist")

    with pytest.raises(NativeAckPublicationError, match="bundle identity"):
        _ = NativeAckPublisherConfig.production(home=tmp_path)


def test_native_helper_has_no_destructive_cleanup_command() -> None:
    source = (
        Path(__file__).resolve().parents[2]
        / "macos/HealthBridgeMailboxAckPublisher/main.swift"
    ).read_text()

    assert '"--cleanup"' not in source
    assert "removeItem(at: urls.receiver)" not in source
    assert "SecTaskCopyValueForEntitlement" in source


def test_publishes_only_after_bound_success_receipt(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mailbox = _mailbox(tmp_path)
    publisher = _publisher(tmp_path)

    def run_helper(
        *args: object, **kwargs: object
    ) -> subprocess.CompletedProcess[bytes]:
        del kwargs
        command_value = args[0]
        assert isinstance(command_value, list)
        command_items = cast("list[object]", command_value)
        assert all(isinstance(item, str) for item in command_items)
        command = cast("list[str]", command_items)
        request_id = command[1]
        protocol = tmp_path / "protocol"
        request = cast(
            "dict[str, object]",
            json.loads((protocol / "requests" / f"{request_id}.json").read_text()),
        )
        source = protocol / "staging" / f"{request_id}.hba"
        content = source.read_bytes()
        final = mailbox / "acks" / FINAL_NAME
        _ = source.replace(final)
        receipt = {
            **request,
            "published": True,
            "exactBytes": True,
            "isUbiquitous": True,
            "uploadErrorAbsent": True,
            "sourceOutsideProvider": True,
            "errorDomain": None,
            "errorCode": None,
        }
        receipt_path = protocol / "receipts" / f"{request_id}.json"
        _ = receipt_path.write_text(json.dumps(receipt))
        receipt_path.chmod(0o600)
        assert content == PAYLOAD
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(subprocess, "run", run_helper)
    with open_mailbox_directory(mailbox) as directory:
        result = publisher(directory, FINAL_NAME, PAYLOAD)

    assert result is PublicationState.CREATED
    assert (mailbox / "acks" / FINAL_NAME).read_bytes() == PAYLOAD
    assert list((tmp_path / "protocol" / "requests").iterdir()) == []
    assert list((tmp_path / "protocol" / "staging").iterdir()) == []
    assert list((tmp_path / "protocol" / "receipts").iterdir()) == []


def test_helper_failure_is_retryable_and_cleans_protocol_files(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mailbox = _mailbox(tmp_path)
    publisher = _publisher(tmp_path)

    def fail_helper(
        *args: object, **kwargs: object
    ) -> subprocess.CompletedProcess[bytes]:
        del kwargs
        command_value = args[0]
        assert isinstance(command_value, list)
        command_items = cast("list[object]", command_value)
        assert all(isinstance(item, str) for item in command_items)
        command = cast("list[str]", command_items)
        request_id = command[1]
        request = cast(
            "dict[str, object]",
            json.loads(
                (tmp_path / "protocol" / "requests" / f"{request_id}.json").read_text()
            ),
        )
        assert request["sha256"] == hashlib.sha256(PAYLOAD).hexdigest()
        return subprocess.CompletedProcess(command, 3)

    monkeypatch.setattr(subprocess, "run", fail_helper)
    with (
        open_mailbox_directory(mailbox) as directory,
        pytest.raises(NativeAckPublicationError),
    ):
        _ = publisher(directory, FINAL_NAME, PAYLOAD)

    assert list((mailbox / "acks").iterdir()) == []
    assert list((tmp_path / "protocol" / "requests").iterdir()) == []
    assert list((tmp_path / "protocol" / "staging").iterdir()) == []
    assert list((tmp_path / "protocol" / "receipts").iterdir()) == []

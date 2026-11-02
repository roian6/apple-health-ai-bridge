from __future__ import annotations

import errno
import hashlib
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

from health_bridge.mailbox import helper_distribution_contract, helper_lifecycle
from health_bridge.mailbox.filesystem import (
    open_mailbox_directory,
)
from health_bridge.mailbox.helper_lifecycle import HelperError, HelperErrorCode
from health_bridge.mailbox.native_ack_publication import (
    NativeAckPublicationError,
    NativeAckPublisher,
    NativeAckPublisherConfig,
)
from health_bridge.mailbox.publication import PublicationState
from health_bridge.receiver.mailbox_bootstrap import (
    PairingCancellation,
    canonical_model,
)
from tests.mailbox import test_helper_distribution_contract as fixtures

if TYPE_CHECKING:
    from collections.abc import Callable

    from health_bridge.mailbox.helper_distribution_verifier import (
        DistributionVerificationRequest,
    )

RECEIVER = "11" * 16
DEVICE = "22" * 16
FINAL_NAME = f"{'33' * 16}.hba"
PAYLOAD = b"signed-ack"


def _mailbox(tmp_path: Path) -> Path:
    mailbox = tmp_path / RECEIVER / DEVICE
    for lane in ("deliveries", "acks", "quarantine"):
        (mailbox / lane).mkdir(parents=True, exist_ok=True)
    return mailbox


def native_publisher(
    tmp_path: Path, mode: str = "ok", *, timeout: float = 2
) -> NativeAckPublisher:
    helper = tmp_path / "helper"
    _ = helper.write_text(
        f"#!{sys.executable}\nMODE = {mode!r}\n" + _HELPER,
        encoding="utf-8",
    )
    helper.chmod(0o700)
    return NativeAckPublisher(
        NativeAckPublisherConfig(
            helper_executable=helper,
            timeout_seconds=timeout,
        )
    )


_HELPER = r"""
import hashlib
import json
import os
import signal
import struct
import sys
from pathlib import Path

root = Path(__file__).parent
flag = sys.argv[1]
with (root / "calls").open("a") as calls:
    calls.write(flag + "\n")
if flag == "--publication-ipc-v1-capabilities":
    assert sys.stdin.buffer.read() == b""
    if MODE == "old":
        sys.exit(3)
    if MODE == "incompatible":
        sys.stdout.buffer.write(b"native-pairing-cancellation-v1:available\n")
    elif MODE == "discovery_overflow":
        sys.stdout.buffer.write(b"x" * 129)
    elif MODE == "discovery_signal":
        os.kill(os.getpid(), signal.SIGKILL)
    elif MODE == "discovery_timeout":
        signal.pause()
    else:
        sys.stdout.buffer.write(
            b"publication-ipc-v1:ack,pairing,receiver_capabilities,storage_probe\n"
        )
    sys.exit(0)
assert flag == "--publication-ipc-v1"
if MODE == "broken_pipe":
    os.close(0)
    sys.exit(0)
if MODE == "backpressure":
    # Fill stdout before reading stdin; the parent must drain while writing.
    os.write(1, b"x" * 1_048_576)
    signal.pause()
if MODE == "timeout":
    signal.pause()
def read_exact(size):
    result = bytearray()
    while len(result) < size:
        chunk = os.read(0, size - len(result))
        assert chunk
        result.extend(chunk)
    return bytes(result)

header_size = struct.unpack(">I", read_exact(4))[0]
assert 1 <= header_size <= 8192
header = read_exact(header_size)
request = json.loads(header)
assert json.dumps(request, sort_keys=True, separators=(",", ":")).encode() == header
payload = read_exact(request["byteCount"])
assert os.read(0, 1) == b""
assert request["sha256"] == hashlib.sha256(payload).hexdigest()
assert request["version"] == 1
assert len(request["requestID"]) == 32
operation = request["operation"]
common = {"version", "operation", "requestID", "byteCount", "sha256"}
targets = {
    "ack": {"receiver", "device", "finalName"},
    "pairing": {"invitationID", "finalName"},
    "receiver_capabilities": {"receiver", "device"},
    "storage_probe": set(),
}
assert set(request) == common | targets[operation]
receipt = {**request, "status": "ok"}
if operation == "storage_probe":
    assert payload == b""
    receipt["storageReady"] = True
elif operation == "ack":
    target = (root / request["receiver"] / request["device"]
              / "acks" / request["finalName"])
    receipt.update(published=True, exactBytes=True, isUbiquitous=True,
                   uploadErrorAbsent=True, sourceOutsideProvider=True,
                   errorDomain=None, errorCode=None)
elif operation == "pairing":
    target = root / request["invitationID"] / request["finalName"]
    receipt.update(published=True, bootstrapVersion=1)
elif operation == "receiver_capabilities":
    target = (root / request["receiver"] / request["device"]
              / "receiver-capabilities.json")
    receipt.update(stored=True, exactBytes=True, isUbiquitous=True)
else:
    raise AssertionError(operation)
if operation != "storage_probe":
    target.write_bytes(b"wrong" if MODE == "provider_bytes" else payload)
exit_code = 0
if MODE.startswith("error:"):
    receipt = {**request, "status": "error", "code": MODE.split(":")[1]}
    exit_code = 3
if MODE == "wrong_exit":
    exit_code = 3
if MODE == "error_zero":
    receipt = {**request, "status": "error", "code": "storage_access_denied"}
if MODE == "unbound":
    receipt = dict(version=1, operation=None, requestID=None,
                   status="error", code="invalid_request")
    exit_code = 3
mutations = {
    "digest": {"sha256": "00" * 32}, "identity": {"requestID": "00" * 16},
    "target": {"device": "00" * 16}, "operation": {"operation": "other"},
    "boolean": {"byteCount": True}, "float": {"version": 1.0},
    "extra": {"extra": True},
    "missing": {"status": None}, "nested_field": {"status": [[]]},
}
receipt.update(mutations.get(MODE.rsplit(":", 1)[-1], {}))
if MODE == "flag_integer":
    key = {"ack": "published", "pairing": "bootstrapVersion",
           "receiver_capabilities": "stored",
           "storage_probe": "storageReady"}[operation]
    receipt[key] = True if key == "bootstrapVersion" else 1
encoded = json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()
if MODE == "duplicate":
    encoded = encoded.replace(b'"version":1', b'"version":0,"version":1')
if MODE == "noncanonical":
    encoded = b" " + encoded
if MODE == "escaped":
    encoded = encoded.replace(b'"ok"', b'"\\u006fk"')
if MODE == "exponent":
    encoded = encoded.replace(b'"version":1', b'"version":1e0')
if MODE == "nested":
    encoded = b"[" * 1500 + b"]" * 1500
if MODE == "nan":
    encoded = encoded.replace(b'"version":1', b'"version":NaN')
frame = struct.pack(">I", len(encoded)) + encoded
if MODE == "empty":
    frame = b"\0\0\0\0"
if MODE == "oversize_header":
    frame = struct.pack(">I", 8193)
if MODE == "truncated":
    frame = frame[:-1]
if MODE == "trailing":
    frame += b"\n"
if MODE == "overflow":
    frame = b"x" * 8197
if MODE == "partial":
    for byte in frame:
        os.write(1, bytes([byte]))
else:
    sys.stdout.buffer.write(frame)
    sys.stdout.buffer.flush()
if MODE == "exit_timeout":
    os.close(1)
    signal.pause()
sys.exit(exit_code)
"""


@pytest.fixture
def installed_helper(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[Path, list[Path]]:
    # Keep real installation/ownership validation; only signing is synthetic.
    for name, value in (
        (
            "SIGNING_AUTHORITY",
            f"Developer ID Application: {fixtures.PUBLISHER} ({fixtures.TEAM_ID})",
        ),
        ("TEAM_IDENTIFIER", fixtures.TEAM_ID),
        ("BUNDLE_IDENTIFIER", fixtures.BUNDLE_ID),
        ("ICLOUD_CONTAINER_IDENTIFIER", fixtures.CONTAINER_ID),
    ):
        monkeypatch.setattr(
            helper_distribution_contract,
            f"_APPROVED_{name}_SHA256",
            hashlib.sha256(value.encode()).hexdigest(),
        )
    verified_apps: list[Path] = []

    def verify_distribution(request: DistributionVerificationRequest) -> None:
        assert request.bundle_identifier == fixtures.BUNDLE_ID
        assert request.icloud_container_identifier == fixtures.CONTAINER_ID
        assert request.bundle_version == fixtures.VERSION
        assert request.bundle_build == "1"
        assert request.distribution.team_identifier == fixtures.TEAM_ID
        verified_apps.append(request.app)

    monkeypatch.setattr(helper_lifecycle, "__version__", fixtures.VERSION)
    monkeypatch.setattr(
        helper_lifecycle, "verify_macos_distribution", verify_distribution
    )
    archive, manifest = fixtures.write_release(tmp_path, schema_version=2)
    home = tmp_path / "home"
    _ = helper_lifecycle.install_helper(archive, manifest, home=home, platform="darwin")
    return home, verified_apps


@pytest.mark.parametrize("platform", ["linux", "darwin"])
def test_production_config_checks_bundle_without_container_configuration(
    installed_helper: tuple[Path, list[Path]],
    monkeypatch: pytest.MonkeyPatch,
    platform: str,
) -> None:
    # Given: an installation with real manifest and ownership receipts.
    home, verified_apps = installed_helper
    monkeypatch.setattr(sys, "platform", platform)

    # When: production resolves its configuration.
    config = NativeAckPublisherConfig.production(home=home)

    # Then: the checked executable is the only configured filesystem target.
    assert not hasattr(config, "protocol_root")
    assert config.helper_executable == (
        helper_lifecycle.HelperPaths.production(home).app
        / "Contents/MacOS/HealthBridgeMailboxAckPublisher"
    )
    assert len(verified_apps) == (2 if platform == "darwin" else 1)


@pytest.mark.parametrize(
    ("platform", "error_message"),
    [("linux", "bundle identity"), ("darwin", "not ready")],
)
@pytest.mark.parametrize(
    "bundle_id",
    [None, "", "../escape", "contains space", "a" * 256],
)
def test_production_config_rejects_invalid_installed_bundle_identity(
    tmp_path: Path,
    bundle_id: object,
    monkeypatch: pytest.MonkeyPatch,
    platform: str,
    error_message: str,
) -> None:
    app = helper_lifecycle.HelperPaths.production(tmp_path).app
    contents = app / "Contents"
    contents.mkdir(parents=True)
    payload = {} if bundle_id is None else {"CFBundleIdentifier": bundle_id}
    _ = (contents / "Info.plist").write_bytes(plistlib.dumps(payload))
    monkeypatch.setattr(sys, "platform", platform)

    with pytest.raises(NativeAckPublicationError, match=error_message) as raised:
        _ = NativeAckPublisherConfig.production(home=tmp_path)

    if platform == "darwin":
        assert isinstance(raised.value.__cause__, HelperError)
        assert raised.value.__cause__.code is HelperErrorCode.HELPER_DRIFT


def test_macos_production_config_refuses_unowned_helper_before_publication(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = helper_lifecycle.HelperPaths.production(tmp_path).app
    contents = app / "Contents"
    contents.mkdir(parents=True)
    _ = (contents / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleIdentifier": fixtures.BUNDLE_ID})
    )
    monkeypatch.setattr(sys, "platform", "darwin")

    with pytest.raises(NativeAckPublicationError, match="not ready"):
        _ = NativeAckPublisherConfig.production(home=tmp_path)


def test_macos_production_config_rejects_drifted_owned_helper(
    installed_helper: tuple[Path, list[Path]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given: a real owned installation whose executable no longer matches its receipt.
    home, verified_apps = installed_helper
    app = helper_lifecycle.HelperPaths.production(home).app
    _ = (app / "Contents/MacOS/HealthBridgeMailboxAckPublisher").write_bytes(b"drift")
    monkeypatch.setattr(sys, "platform", "darwin")

    # When: production attempts to resolve the drifted installation.
    with pytest.raises(NativeAckPublicationError, match="not ready") as raised:
        _ = NativeAckPublisherConfig.production(home=home)

    # Then: ownership rejects it before a second platform-signature verification.
    assert isinstance(raised.value.__cause__, HelperError)
    assert raised.value.__cause__.code is HelperErrorCode.HELPER_DRIFT
    assert len(verified_apps) == 1


@pytest.mark.parametrize(
    ("platform", "error_message"),
    [("linux", "bundle identity"), ("darwin", "not ready")],
)
@pytest.mark.parametrize("symlink_component", ["app", "contents", "info"])
def test_production_config_rejects_symlinked_bundle_path_component(
    tmp_path: Path,
    symlink_component: str,
    monkeypatch: pytest.MonkeyPatch,
    platform: str,
    error_message: str,
) -> None:
    helpers = tmp_path / "Library/Application Support/HealthBridge/helpers"
    real_app = tmp_path / "real-helper.app"
    real_contents = real_app / "Contents"
    real_contents.mkdir(parents=True)
    _ = (real_contents / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleIdentifier": fixtures.BUNDLE_ID})
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

    monkeypatch.setattr(sys, "platform", platform)

    with pytest.raises(NativeAckPublicationError, match=error_message) as raised:
        _ = NativeAckPublisherConfig.production(home=tmp_path)

    if platform == "darwin":
        assert isinstance(raised.value.__cause__, HelperError)
        assert raised.value.__cause__.code is HelperErrorCode.HELPER_DRIFT


def test_native_helper_has_no_destructive_cleanup_command() -> None:
    source = (
        Path(__file__).resolve().parents[2]
        / "macos/HealthBridgeMailboxAckPublisher/main.swift"
    ).read_text()

    assert '"--cleanup"' not in source
    assert "removeItem(at: urls.receiver)" not in source
    assert "SecTaskCopyValueForEntitlement" in source


@pytest.mark.parametrize("mode", ["ok", "partial"])
def test_publishes_only_after_bound_success_receipt(tmp_path: Path, mode: str) -> None:
    mailbox = _mailbox(tmp_path)
    publisher = native_publisher(tmp_path, mode)
    with open_mailbox_directory(mailbox) as directory:
        result = publisher(directory, FINAL_NAME, PAYLOAD)
    assert result is PublicationState.CREATED
    assert (mailbox / "acks" / FINAL_NAME).read_bytes() == PAYLOAD
    assert not (tmp_path / "protocol").exists()


@pytest.mark.parametrize(
    "mode",
    [
        "digest",
        "identity",
        "target",
        "operation",
        "boolean",
        "float",
        "extra",
        "missing",
        "nested_field",
        "duplicate",
        "flag_integer",
        "noncanonical",
        "escaped",
        "exponent",
        "nested",
        "nan",
        "empty",
        "oversize_header",
        "truncated",
        "trailing",
        "overflow",
        "wrong_exit",
        "error_zero",
        "unbound",
        "provider_bytes",
    ],
)
def test_ack_rejects_unbound_or_malformed_receipts(tmp_path: Path, mode: str) -> None:
    mailbox = _mailbox(tmp_path)
    publisher = native_publisher(tmp_path, mode)
    with (
        open_mailbox_directory(mailbox) as directory,
        pytest.raises(NativeAckPublicationError),
    ):
        _ = publisher(directory, FINAL_NAME, PAYLOAD)


@pytest.mark.parametrize("mode", ["old", "incompatible"])
@pytest.mark.parametrize(
    "operation", ["setup", "probe", "ack", "pairing", "capabilities"]
)
def test_unsupported_helper_requires_upgrade_without_legacy_fallback(
    tmp_path: Path,
    mode: str,
    operation: str,
) -> None:
    publisher = native_publisher(tmp_path, mode)
    mailbox = _mailbox(tmp_path)
    invitation = tmp_path / ("44" * 16)
    invitation.mkdir()
    with open_mailbox_directory(mailbox) as directory:
        actions: dict[str, Callable[[], None | PublicationState]] = {
            "setup": publisher.require_native_pairing,
            "probe": publisher.probe_protocol_storage,
            "ack": lambda: publisher(directory, FINAL_NAME, PAYLOAD),
            "pairing": lambda: publisher.publish_pairing(invitation, PAYLOAD),
            "capabilities": lambda: publisher.publish_capabilities(directory, PAYLOAD),
        }
        action = actions[operation]
        with pytest.raises(
            NativeAckPublicationError, match=r"^native_helper_upgrade_required$"
        ):
            _ = action()
    assert (tmp_path / "calls").read_text().splitlines() == [
        "--publication-ipc-v1-capabilities"
    ]
    assert not (tmp_path / "protocol").exists()


def test_helper_replacement_is_rediscovered_before_publication(tmp_path: Path) -> None:
    publisher = native_publisher(tmp_path)
    publisher.require_native_pairing()
    _ = native_publisher(tmp_path, "old")
    with pytest.raises(
        NativeAckPublicationError, match=r"^native_helper_upgrade_required$"
    ):
        publisher.probe_protocol_storage()
    assert (tmp_path / "calls").read_text().splitlines() == [
        "--publication-ipc-v1-capabilities",
        "--publication-ipc-v1-capabilities",
    ]


@pytest.mark.parametrize("mode", ["discovery_overflow", "discovery_signal"])
def test_operational_discovery_failures_are_not_upgrade_diagnoses(
    tmp_path: Path, mode: str
) -> None:
    publisher = native_publisher(tmp_path, mode)
    with pytest.raises(NativeAckPublicationError) as raised:
        publisher.require_native_pairing()
    assert str(raised.value) == "native_pairing_publication_failed"


@pytest.mark.parametrize(
    "code",
    [
        "invalid_request",
        "unsafe_storage",
        "storage_access_denied",
        "storage_io_failed",
        "helper_busy",
        "provider_unavailable",
        "destination_conflict",
        "publication_failed",
        "unknown",
    ],
)
def test_probe_maps_only_bound_helper_storage_denial(tmp_path: Path, code: str) -> None:
    publisher = native_publisher(tmp_path, "error:" + code)
    with pytest.raises(NativeAckPublicationError) as raised:
        publisher.probe_protocol_storage()
    expected = (
        "helper_container_access_denied"
        if code == "storage_access_denied"
        else "native_pairing_publication_failed"
    )
    assert str(raised.value) == expected


@pytest.mark.parametrize("mutation", ["identity", "digest", "boolean"])
def test_unbound_storage_denial_is_never_permission_diagnosis(
    tmp_path: Path,
    mutation: str,
) -> None:
    publisher = native_publisher(tmp_path, "error:storage_access_denied:" + mutation)
    with pytest.raises(NativeAckPublicationError) as raised:
        publisher.probe_protocol_storage()
    assert str(raised.value) == "native_pairing_publication_failed"


def test_spawn_failure_is_operational_not_helper_upgrade(tmp_path: Path) -> None:
    publisher = native_publisher(tmp_path)
    _ = (tmp_path / "helper").write_bytes(b"invalid executable format")
    with pytest.raises(NativeAckPublicationError) as raised:
        publisher.require_native_pairing()
    assert str(raised.value) == "native_pairing_publication_failed"


@pytest.mark.parametrize("mode", ["ok", "flag_integer"])
def test_storage_probe_and_setup_negotiate_current_executable(
    tmp_path: Path, mode: str
) -> None:
    publisher = native_publisher(tmp_path, mode)
    publisher.require_native_pairing()
    if mode == "ok":
        publisher.probe_protocol_storage()
    else:
        with pytest.raises(NativeAckPublicationError):
            publisher.probe_protocol_storage()
    assert (tmp_path / "calls").read_text().splitlines() == [
        "--publication-ipc-v1-capabilities",
        "--publication-ipc-v1-capabilities",
        "--publication-ipc-v1",
    ]


def test_pairing_publishes_and_independently_rereads(tmp_path: Path) -> None:
    invitation = tmp_path / ("44" * 16)
    invitation.mkdir()
    publisher = native_publisher(tmp_path)
    publisher.publish_pairing(invitation, b"synthetic-completion")
    assert (invitation / "completion.hbp").read_bytes() == b"synthetic-completion"


def test_pairing_rejects_provider_bytes_even_with_success_receipt(
    tmp_path: Path,
) -> None:
    invitation = tmp_path / ("44" * 16)
    invitation.mkdir()
    publisher = native_publisher(tmp_path, "provider_bytes")
    with pytest.raises(NativeAckPublicationError):
        publisher.publish_pairing(invitation, b"synthetic-completion")


@pytest.mark.parametrize(
    "mode",
    [
        "timeout",
        "exit_timeout",
        "discovery_timeout",
        "overflow",
        "backpressure",
        "broken_pipe",
    ],
)
def test_transport_failure_kills_and_reaps_real_child(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    mode: str,
) -> None:
    mailbox = _mailbox(tmp_path)
    publisher = native_publisher(tmp_path, mode, timeout=1)
    children: list[subprocess.Popen[bytes]] = []
    popen = subprocess.Popen

    def capture(args: list[str], **kwargs: int | bool) -> subprocess.Popen[bytes]:
        child = popen(
            args,
            stdin=kwargs["stdin"],
            stdout=kwargs["stdout"],
            stderr=kwargs["stderr"],
            close_fds=bool(kwargs["close_fds"]),
            bufsize=int(kwargs["bufsize"]),
        )
        children.append(child)
        return child

    monkeypatch.setattr(subprocess, "Popen", capture)
    with (
        open_mailbox_directory(mailbox) as directory,
        pytest.raises(NativeAckPublicationError) as raised,
    ):
        _ = publisher(directory, FINAL_NAME, b"x" * 1_048_576)
    assert str(raised.value) == "native_pairing_publication_failed"
    assert len(children) == (1 if mode == "discovery_timeout" else 2)
    for child in children:
        assert child.returncode is not None
        assert child.stdout is not None
        assert child.stdout.closed
        assert child.stdin is None or child.stdin.closed
        with pytest.raises(ChildProcessError):
            _ = os.waitpid(child.pid, os.WNOHANG)


@pytest.mark.parametrize("timeout", [0, -1, float("nan"), float("inf")])
def test_timeout_must_be_finite_positive(tmp_path: Path, timeout: float) -> None:
    with pytest.raises(ValueError, match=r"^$"):
        _ = native_publisher(tmp_path, timeout=timeout)


def test_discovery_and_exchange_share_one_capped_deadline(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    publisher = native_publisher(tmp_path, timeout=180)
    now = [100.0]
    deadlines: list[float] = []

    def exchange(
        _self: NativeAckPublisher,
        flag: str,
        frame: bytes,
        deadline: float,
    ) -> tuple[int, bytes]:
        deadlines.append(deadline)
        if flag == "--publication-ipc-v1-capabilities":
            now[0] = 189.0
            return (
                0,
                b"publication-ipc-v1:ack,pairing,receiver_capabilities,storage_probe\n",
            )
        assert len(frame) > 4
        now[0] = 191.0
        return 0, b""

    monkeypatch.setattr(time, "monotonic", lambda: now[0])
    monkeypatch.setattr(NativeAckPublisher, "_exchange", exchange)
    with pytest.raises(NativeAckPublicationError):
        publisher.probe_protocol_storage()
    assert deadlines == [190.0, 190.0]


@pytest.mark.parametrize("mode", ["ok", "flag_integer"])
def test_pairing_cancellation_preserves_terminal_target_and_types(
    tmp_path: Path,
    mode: str,
) -> None:
    invitation = tmp_path / ("44" * 16)
    invitation.mkdir()
    publisher = native_publisher(tmp_path, mode)
    payload = canonical_model(
        PairingCancellation(
            kind="cancelled",
            invitation_id=invitation.name,
            request_sha256="55" * 32,
            sender_signing_public_key="synthetic",
            signature="synthetic",
        )
    )
    if mode == "ok":
        publisher.publish_pairing(invitation, payload)
        assert (invitation / "cancelled.hbp").read_bytes() == payload
        assert not (invitation / "completion.hbp").exists()
    else:
        with pytest.raises(NativeAckPublicationError):
            publisher.publish_pairing(invitation, payload)


def test_maximum_ack_survives_real_pipe_backpressure(tmp_path: Path) -> None:
    mailbox = _mailbox(tmp_path)
    publisher = native_publisher(tmp_path)
    payload = b"x" * 1_048_576
    with open_mailbox_directory(mailbox) as directory:
        assert publisher(directory, FINAL_NAME, payload) is PublicationState.CREATED
    assert (mailbox / "acks" / FINAL_NAME).read_bytes() == payload


def test_issue154_all_operations_succeed_with_parent_container_io_denied(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mailbox = _mailbox(tmp_path)
    invitation = tmp_path / ("44" * 16)
    invitation.mkdir()
    publisher = native_publisher(tmp_path)
    original_open = os.open
    attempted: list[str] = []

    def deny(
        path: str | bytes | os.PathLike[str] | os.PathLike[bytes],
        flags: int,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> int:
        path_parts = Path(os.fsdecode(path)).parts
        if "Containers" in path_parts or "protocol" in path_parts:
            attempted.append("private open")
            raise PermissionError(errno.EACCES, "synthetic denial")
        return original_open(path, flags, mode, dir_fd=dir_fd)

    monkeypatch.setattr(os, "open", deny)
    publisher.probe_protocol_storage()
    publisher.publish_pairing(invitation, b"synthetic")
    with open_mailbox_directory(mailbox) as directory:
        assert publisher(directory, FINAL_NAME, PAYLOAD) is PublicationState.CREATED
        publisher.publish_capabilities(directory, b"synthetic-metadata")
    assert attempted == []
    assert (invitation / "completion.hbp").read_bytes() == b"synthetic"
    assert (
        mailbox / "receiver-capabilities.json"
    ).read_bytes() == b"synthetic-metadata"

import errno
import hashlib
import json
import os
import sqlite3
import subprocess
from collections.abc import Callable, Generator
from contextlib import contextmanager
from http.client import HTTPConnection
from pathlib import Path
from threading import Event, Thread
from uuid import UUID

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import TypeAdapter
from typer.testing import CliRunner
from typing_extensions import override

import health_bridge.mailbox.native_ack_publication as publication_module
import health_bridge.receiver.mailbox_runtime as runtime_module
from health_bridge.cli import app
from health_bridge.contract._delivery_common import b64decode, b64encode, derive_key
from health_bridge.contract._hbjcs1 import hbjcs1_decode
from health_bridge.mailbox.filesystem import MailboxFileError, MailboxFileErrorCode
from health_bridge.mailbox.native_ack_publication import (
    NativeAckPublisher,
    NativeAckPublisherConfig,
)
from health_bridge.mailbox.publication import publish_final
from health_bridge.queries.models import SyncedMetricsResult
from health_bridge.receiver import invitations as invitations_module
from health_bridge.receiver.delivery_acceptance import DeliveryAcceptanceService
from health_bridge.receiver.mailbox_bootstrap import (
    PAIRING_DOMAIN,
    BootstrapDescriptor,
    NativePairingRequest,
    PairingCompletionEnvelope,
    canonical_model,
    seal_pairing_request,
)
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.mailbox_runtime import MailboxRuntimeWorker
from health_bridge.receiver.pairing import create_receiver_pairing_invitation_bundle
from health_bridge.receiver.server import build_receiver_server, server_port
from health_bridge.storage.database import (
    connect_live_readonly_database,
    initialize_database,
)
from tests.receiver.delivery_acceptance_support import NOW_MS, counts
from tests.receiver.native_pairing_support import LegacyPeer, stage_native


def publish_completion(directory: Path, content: bytes) -> None:
    _ = publish_final(directory, "completion.hbp", content)


def open_completion(
    encoded: bytes,
    request: bytes,
    descriptor: BootstrapDescriptor,
    device: MailboxKeyStore,
) -> bytes:
    envelope = PairingCompletionEnvelope.model_validate(hbjcs1_decode(encoded))
    assert envelope.request_sha256 == hashlib.sha256(request).hexdigest()
    assert envelope.invitation_id == descriptor.invitation_id
    assert envelope.sender_signing_public_key == descriptor.receiver_signing_public_key
    Ed25519PublicKey.from_public_bytes(
        b64decode(descriptor.receiver_signing_public_key, length=32)
    ).verify(
        b64decode(envelope.signature, length=64),
        PAIRING_DOMAIN
        + b"completion/signature\0"
        + canonical_model(envelope, exclude={"signature"}),
    )
    salt = bytes.fromhex(descriptor.invitation_id) + hashlib.sha256(request).digest()
    shared = device.exchange(
        b64decode(descriptor.receiver_agreement_public_key, length=32)
    )
    return AESGCM(derive_key(shared, salt, PAIRING_DOMAIN + b"completion/key")).decrypt(
        b64decode(envelope.nonce, length=12),
        b64decode(envelope.ciphertext),
        PAIRING_DOMAIN
        + b"completion/aad\0"
        + canonical_model(envelope, exclude={"ciphertext", "signature"}),
    )


@pytest.mark.parametrize("response_loss", [False, True])
def test_native_worker_pairs_then_authenticates_nonempty_health_and_normal_query(
    tmp_path: Path,
    response_loss: bool,
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    publications: list[bytes] = []

    def publish(directory: Path, content: bytes) -> None:
        publish_completion(directory, content)
        publications.append(content)
        if response_loss and len(publications) == 1:
            message = "synthetic lost publication confirmation"
            raise OSError(message)

    worker = MailboxRuntimeWorker(
        capability_publisher=lambda _directory: None,
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish,
    )
    worker.run_once()
    assert not root.exists()
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    worker.run_once()
    assert (directory / "completion.hbp").exists(), "native request was not completed"
    response = (directory / "completion.hbp").read_bytes()
    assert b'"receiver_url":null' in open_completion(
        response, request, descriptor, peer.device
    )
    if response_loss:
        (directory / "completion.hbp").unlink()
        worker = MailboxRuntimeWorker(
            capability_publisher=lambda _directory: None,
            db_path=peer.db,
            mailbox_root=root,
            pairing_keys=peer.receiver,
            pairing_connections=peer.connections,
            pairing_publisher=publish,
        )
    worker.run_once()
    assert (directory / "completion.hbp").read_bytes() == response
    assert all(value == response for value in publications)
    trusted = peer.trusted()
    assert (
        DeliveryAcceptanceService(peer.db, trusted, lambda: NOW_MS)
        .accept(peer.upload(trusted))
        .receipt.result
        == "committed"
    )
    assert counts(peer.db) == (1, 1, 1)
    queried = CliRunner().invoke(app, ["query", "synced-metrics", "--db", str(peer.db)])
    assert queried.exit_code == 0, queried.output
    assert (
        SyncedMetricsResult.model_validate_json(queried.output).metrics[0].record_count
        == 1
    )


@pytest.mark.parametrize("boundary", ["root", "database"])
@pytest.mark.parametrize("error_type", [PermissionError, OSError])
def test_bootstrap_storage_failure_keeps_worker_available_and_recovers(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    boundary: str,
    error_type: type[OSError],
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    unavailable = True
    original_lstat = Path.lstat

    def lstat(path: Path) -> os.stat_result:
        if unavailable and boundary == "root" and path == root:
            raise error_type
        return original_lstat(path)

    @contextmanager
    def reader(path: Path) -> Generator[sqlite3.Connection, None, None]:
        if unavailable and boundary == "database":
            raise error_type
        with connect_live_readonly_database(path) as database:
            yield database

    monkeypatch.setattr(Path, "lstat", lstat)
    monkeypatch.setattr(runtime_module, "connect_live_readonly_database", reader)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish_completion,
        capability_publisher=lambda _directory: None,
    )

    # The synchronous boundary first proves the precise retry classification.
    with pytest.raises(runtime_module.MailboxDiscoveryError) as raised:
        worker.run_once()
    assert (
        raised.value.code
        is runtime_module.MailboxDiscoveryErrorCode.STORAGE_UNAVAILABLE
    )
    assert isinstance(raised.value.__cause__, error_type)

    failed, resume, recovered = Event(), Event(), Event()

    class CycleGate(Event):
        @override
        def wait(self, timeout: float | None = None) -> bool:
            if not failed.is_set():
                failed.set()
                assert resume.wait(5), "test did not release retryable cycle"
                return self.is_set()
            recovered.set()
            return super().wait(timeout)

    monkeypatch.setattr(worker, "_stop", CycleGate())
    try:
        worker.start()
        assert failed.wait(5), "worker did not complete the failing cycle"
        assert worker.is_alive()
        assert not worker.terminal_error()
        assert worker.health_error() == "mailbox_discovery_storage_unavailable"
        unavailable = False
        resume.set()
        assert recovered.wait(5), "worker did not complete the recovery cycle"
        assert worker.is_alive()
        assert worker.health_error() is None
        assert open_completion(
            (directory / "completion.hbp").read_bytes(),
            request,
            descriptor,
            peer.device,
        )
        assert not peer.trusted().sender_key_revoked
    finally:
        resume.set()
        stopped = worker.stop()
    assert stopped


@pytest.mark.parametrize("awaiting", [False, True])
def test_bootstrap_missing_root_preserves_awaiting_policy(
    tmp_path: Path, awaiting: bool
) -> None:
    peer = LegacyPeer(tmp_path)
    if awaiting:
        _ = stage_native(peer)
    else:
        initialize_database(peer.db)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=tmp_path / "absent",
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        capability_publisher=lambda _directory: None,
    )
    if awaiting:
        worker.run_once()
    else:
        with pytest.raises(runtime_module.MailboxDiscoveryError) as raised:
            worker.run_once()
        assert (
            raised.value.code
            is runtime_module.MailboxDiscoveryErrorCode.ROOT_UNAVAILABLE
        )


@pytest.mark.parametrize("boundary", ["root", "database"])
def test_bootstrap_blocking_io_defers_without_discovery(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, boundary: str
) -> None:
    peer = LegacyPeer(tmp_path)
    _ = stage_native(peer)
    root = tmp_path / "provider"
    original_lstat = Path.lstat

    def lstat(path: Path) -> os.stat_result:
        if boundary == "root" and path == root:
            raise BlockingIOError
        return original_lstat(path)

    @contextmanager
    def reader(path: Path) -> Generator[sqlite3.Connection, None, None]:
        if boundary == "database":
            raise BlockingIOError
        with connect_live_readonly_database(path) as database:
            yield database

    monkeypatch.setattr(Path, "lstat", lstat)
    monkeypatch.setattr(runtime_module, "connect_live_readonly_database", reader)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        capability_publisher=lambda _directory: None,
    )

    worker.run_once()

    assert worker.health_error() is None


def _native_pairing_publisher(
    tmp_path: Path, directory: Path, monkeypatch: pytest.MonkeyPatch
) -> NativeAckPublisher:
    protocol = tmp_path / "protocol"
    helper = tmp_path / "helper"
    helper.touch(mode=0o700)
    publisher = NativeAckPublisher(NativeAckPublisherConfig(helper, protocol))

    def run(argv: list[str], **_kwargs: object) -> subprocess.CompletedProcess[bytes]:
        if argv[1].startswith("--"):
            return subprocess.CompletedProcess(
                argv, 0, b"native-pairing-cancellation-v1:available"
            )
        request_id = argv[1].removeprefix("pairing:")
        body = TypeAdapter(dict[str, str | int]).validate_json(
            (protocol / "requests" / f"{request_id}.json").read_bytes()
        )
        payload = (protocol / "staging" / f"{request_id}.hbp").read_bytes()
        publish_completion(directory, payload)
        receipt = protocol / "receipts" / f"{request_id}.json"
        _ = receipt.write_text(
            json.dumps({**body, "published": True, "bootstrapVersion": 1})
        )
        receipt.chmod(0o600)
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(subprocess, "run", run)
    return publisher


@contextmanager
def _gated_worker_health(
    worker: MailboxRuntimeWorker, db_path: Path, monkeypatch: pytest.MonkeyPatch
) -> Generator[
    tuple[list[Event], list[Event], Callable[[], tuple[int, str]]], None, None
]:
    completed = [Event() for _ in range(4)]
    release = [Event() for _ in range(4)]

    class CycleGate(Event):
        cycle: int = 0

        @override
        def wait(self, timeout: float | None = None) -> bool:
            del timeout
            cycle = self.cycle
            self.cycle += 1
            if cycle < len(completed):
                completed[cycle].set()
                assert release[cycle].wait(5), "cycle not released"
            return self.is_set()

    stop = CycleGate()
    monkeypatch.setattr(worker, "_stop", stop)
    server = build_receiver_server(db_path, host="127.0.0.1", port=0)
    server.mailbox_worker = worker
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def health() -> tuple[int, str]:
        connection = HTTPConnection("127.0.0.1", server_port(server), timeout=5)
        try:
            connection.request("GET", "/health")
            response = connection.getresponse()
            body = TypeAdapter(dict[str, str | bool]).validate_json(response.read())
            status = body["status"]
            assert isinstance(status, str)
            return response.status, status
        finally:
            connection.close()

    try:
        worker.start()
        yield completed, release, health
    finally:
        stop.set()
        for event in release:
            event.set()
        assert worker.stop()
        server.shutdown()
        server.server_close()
        thread.join(5)


@pytest.mark.parametrize(
    ("number", "expected"),
    [
        (errno.EACCES, "helper_container_access_denied"),
        (errno.EIO, "native_pairing_publication_failed"),
    ],
)
def test_issue154_publication_failure_degrades_and_recovers(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    number: int,
    expected: str,
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    publisher = _native_pairing_publisher(tmp_path, directory, monkeypatch)
    denied = True
    original = os.replace

    def replace(source: Path, destination: Path) -> None:
        if denied and destination.parent == tmp_path / "protocol/staging":
            raise OSError(number, "synthetic-secret-private-path")
        original(source, destination)

    monkeypatch.setattr(os, "replace", replace)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publisher.publish_pairing,
        capability_publisher=lambda _: None,
    )
    with _gated_worker_health(worker, peer.db, monkeypatch) as (
        completed,
        release,
        health,
    ):
        assert completed[0].wait(5)
        assert worker.is_alive()
        assert not worker.terminal_error()
        assert worker.health_error() == expected
        assert health() == (503, "degraded")
        assert not (directory / "completion.hbp").exists()
        first_diagnostic = capsys.readouterr().err
        assert first_diagnostic.strip() == expected
        release[0].set()
        assert completed[1].wait(5)
        assert capsys.readouterr().err == ""
        denied = False
        release[1].set()
        assert completed[2].wait(5)
        assert worker.health_error() == expected
        release[2].set()
        assert completed[3].wait(5)
        assert worker.health_error() is None
        assert health() == (200, "ok")
        assert open_completion(
            (directory / "completion.hbp").read_bytes(),
            request,
            descriptor,
            peer.device,
        )
        with connect_live_readonly_database(peer.db) as database:
            assert database.execute(
                "select count(*) from receiver_devices"
            ).fetchone() == (1,)
            assert database.execute(
                "select count(*) from receiver_tokens"
            ).fetchone() == (1,)
            assert database.execute(
                "select count(*) from pairing_invitations where redeemed_at is not null"
            ).fetchone() == (1,)


def test_issue154_unrelated_invitation_cannot_mask_publication_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    peer = LegacyPeer(tmp_path)
    identifiers = iter(
        [UUID(int=1), UUID(int=255), *(UUID(int=i) for i in range(2, 129))]
    )
    monkeypatch.setattr(invitations_module, "uuid4", lambda: next(identifiers))
    invitations: list[tuple[BootstrapDescriptor, bytes]] = []
    for number in (1, 2):
        bundle = create_receiver_pairing_invitation_bundle(
            peer.db,
            label=f"synthetic-{number}",
            receiver_url=None,
            transport="mailbox",
            mailbox_key_store=peer.receiver,
        )
        descriptor = bundle.mailbox_bootstrap
        assert descriptor is not None
        device = MailboxKeyStore.for_testing(
            state_dir=tmp_path / f"device-{number}",
            anchor_dir=tmp_path / f"anchor-{number}",
        )
        identity = device.load_or_create()
        request = seal_pairing_request(
            NativePairingRequest(
                invitation_secret=bundle.invitation_secret,
                installation_id=str(UUID(int=number, version=4)),
                device_credential="hb_" + descriptor.invitation_id * 2,
                platform="ios",
                device_signing_public_key=b64encode(identity.signing_public_key),
                device_agreement_public_key=b64encode(identity.agreement_public_key),
            ),
            descriptor,
            device,
        )
        invitations.append((descriptor, request))
    for number in range(127):
        _ = invitations_module.create_pairing_invitation(
            peer.db, label=f"unrelated-{number}", receiver_url=None, transport="mailbox"
        )
    root = tmp_path / "provider"
    for descriptor, request in invitations:
        directory = root / "pairing" / descriptor.invitation_id
        directory.mkdir(parents=True)
        _ = publish_final(directory, "request.hbp", request)
    failed_id = invitations[0][0].invitation_id
    denied = True

    def publish(directory: Path, payload: bytes) -> None:
        if denied and directory.name == failed_id:
            raise OSError(errno.EIO, "synthetic")
        publish_completion(directory, payload)

    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish,
        capability_publisher=lambda _: None,
    )
    worker.run_once()
    assert worker.health_error() == "native_pairing_publication_failed"
    worker.run_once()
    assert (
        root / "pairing" / invitations[1][0].invitation_id / "completion.hbp"
    ).exists()
    assert worker.health_error() == "native_pairing_publication_failed"
    denied = False
    worker.run_once()
    assert worker.health_error() == "native_pairing_publication_failed"
    worker.run_once()
    assert worker.health_error() == "native_pairing_publication_failed"
    worker.run_once()
    assert worker.health_error() is None


@pytest.mark.parametrize(
    "fault",
    [
        "capability",
        "helper_spawn",
        "timeout",
        "nonzero",
        "provider",
        "provider_wrapped",
        "receipt_invalid",
        "mismatch",
    ],
)
def test_issue154_nonprotocol_failures_do_not_fabricate_container_denial(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    fault: str,
) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, request = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", request)
    publisher = _native_pairing_publisher(tmp_path, directory, monkeypatch)
    original = subprocess.run

    def run(argv: list[str], **_kwargs: object) -> subprocess.CompletedProcess[bytes]:
        capability = argv[1].startswith("--")
        if (capability, fault) in {(True, "capability"), (False, "helper_spawn")}:
            raise PermissionError(errno.EACCES, "synthetic-private-path")
        if capability:
            return subprocess.CompletedProcess(
                argv, 0, b"native-pairing-cancellation-v1:available"
            )
        if fault == "timeout":
            raise subprocess.TimeoutExpired(argv, 1)
        if fault == "nonzero":
            return subprocess.CompletedProcess(argv, 3)
        result = original(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=1,
            check=False,
        )
        if fault == "receipt_invalid":
            request_id = argv[1].removeprefix("pairing:")
            path = tmp_path / "protocol/receipts" / f"{request_id}.json"
            _ = path.write_bytes(b"not-json")
        if fault == "mismatch":
            _ = (directory / "completion.hbp").write_bytes(b"wrong-bytes")
        return result

    provider_errors = {
        "provider": PermissionError(errno.EACCES, "synthetic-private-path"),
        "provider_wrapped": MailboxFileError(MailboxFileErrorCode.STORAGE_UNAVAILABLE),
    }

    def read(*_args: object, **_kwargs: object) -> None:
        raise provider_errors[fault] from PermissionError(
            errno.EACCES, "synthetic-private-path"
        )

    monkeypatch.setattr(subprocess, "run", run)
    if fault in {"provider", "provider_wrapped"}:
        monkeypatch.setattr(publication_module, "read_final", read)
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publisher.publish_pairing,
        capability_publisher=lambda _: None,
    )
    worker.run_once()
    assert worker.health_error() == "native_pairing_publication_failed"
    assert not worker.terminal_error()
    assert capsys.readouterr().err.strip() == "native_pairing_publication_failed"


def test_issue154_malformed_request_remains_nonfatal(tmp_path: Path) -> None:
    peer = LegacyPeer(tmp_path)
    descriptor, _ = stage_native(peer)
    root = tmp_path / "provider"
    directory = root / "pairing" / descriptor.invitation_id
    directory.mkdir(parents=True)
    _ = publish_final(directory, "request.hbp", b"not-json")
    worker = MailboxRuntimeWorker(
        db_path=peer.db,
        mailbox_root=root,
        pairing_keys=peer.receiver,
        pairing_connections=peer.connections,
        pairing_publisher=publish_completion,
        capability_publisher=lambda _: None,
    )
    worker.run_once()
    assert worker.health_error() is None
    assert not worker.terminal_error()
    assert not (directory / "completion.hbp").exists()

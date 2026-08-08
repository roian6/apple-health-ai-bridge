from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import shutil
import signal
import sqlite3
import time
from http import HTTPStatus
from http.client import HTTPConnection
from pathlib import Path
from typing import TYPE_CHECKING, ClassVar, Final, Literal, NoReturn
from urllib.parse import urlencode

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from pydantic import BaseModel, ConfigDict, TypeAdapter

from health_bridge.mailbox.connections import MailboxConnectionStore
from health_bridge.mailbox.importer import MailboxImportConfig, MailboxImporter
from health_bridge.mailbox_qa.qa_runtime import QAReceiverRuntime, serve_qa_receiver
from health_bridge.private_files import (
    ensure_private_directory,
    write_private_text_file,
)
from health_bridge.receiver.invitations import create_pairing_invitation
from health_bridge.receiver.mailbox_keys import MailboxKeyStore
from health_bridge.receiver.tokens import (
    create_receiver_token,
    hash_receiver_token,
)
from health_bridge.storage.database import initialize_database

if TYPE_CHECKING:
    from collections.abc import Mapping
    from types import FrameType

    from health_bridge.mailbox_qa.receiver import QAReceiverConfig

ED25519_PRIVATE_KEY_BYTES = 32
TOKEN_PREFIX_LENGTH: Final = 11
TOKEN_HASH_ROWS: Final[TypeAdapter[list[tuple[str]]]] = TypeAdapter(list[tuple[str]])


class QAReceiverState(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    v: Literal[1]
    kind: Literal["health_bridge.mailbox_qa_receiver_state.v1"]
    status: Literal["prepared", "serving", "stopped"]
    namespace: str
    port: int
    pid: int | None


def prepare_receiver(config: QAReceiverConfig) -> QAReceiverState:
    ensure_private_directory(config.runtime_root / "private")
    if config.mailbox_root_override is None:
        ensure_private_directory(config.mailbox_root)
    if config.state_path.exists():
        current = _read_state(config)
        if (
            current.namespace != config.namespace
            or current.port != config.port
            or current.pid is not None
            or current.status == "serving"
        ):
            raise RuntimeError
        token = config.token_path.read_text(encoding="utf-8")
        if not token or not _receiver_token_is_active(config, token):
            raise RuntimeError
        _ = receiver_receipt_private_key(config)
        prepared = current.model_copy(update={"status": "prepared", "pid": None})
        write_receiver_state(config, prepared)
        return prepared
    if (
        config.token_path.exists()
        or config.receipt_key_path.exists()
        or config.database_path.exists()
    ):
        raise RuntimeError
    initialize_database(config.database_path)
    token = create_receiver_token(
        config.database_path,
        label=f"{config.namespace}-ephemeral",
    )
    write_private_text_file(config.token_path, token.token)
    if config.receipt_key_path.exists():
        _ = receiver_receipt_private_key(config)
    else:
        write_private_text_file(
            config.receipt_key_path,
            base64.urlsafe_b64encode(Ed25519PrivateKey.generate().private_bytes_raw())
            .rstrip(b"=")
            .decode("ascii"),
        )
    state = QAReceiverState(
        v=1,
        kind="health_bridge.mailbox_qa_receiver_state.v1",
        status="prepared",
        namespace=config.namespace,
        port=config.port,
        pid=None,
    )
    write_receiver_state(config, state)
    return state


def _receiver_token_is_active(config: QAReceiverConfig, token: str) -> bool:
    uri = f"{config.database_path.as_uri()}?mode=ro"
    select = "select token_hash from receiver_tokens where token_prefix = ?"
    predicate = "and revoked_at is null"
    with sqlite3.connect(uri, uri=True) as connection:
        rows = TOKEN_HASH_ROWS.validate_python(
            connection.execute(
                f"{select} {predicate}",
                (token[:TOKEN_PREFIX_LENGTH],),
            ).fetchall()
        )
    candidate = hash_receiver_token(token)
    return any(hmac.compare_digest(row[0], candidate) for row in rows)


def serve_receiver(config: QAReceiverConfig) -> None:
    current = _read_state(config)
    if current.status == "stopped" and current.pid is None:
        current = prepare_receiver(config)
    if current.status != "prepared" or current.pid is not None:
        raise RuntimeError
    serving = current.model_copy(update={"status": "serving", "pid": os.getpid()})
    write_receiver_state(config, serving)
    previous_handler = signal.signal(signal.SIGTERM, _exit_after_cleanup)
    try:
        serve_qa_receiver(
            config.host,
            config.port,
            QAReceiverRuntime(
                db_path=config.database_path,
                runtime_root=config.runtime_root,
                mailbox_root=config.mailbox_root,
                namespace=config.namespace,
            ),
        )
    finally:
        _ = signal.signal(signal.SIGTERM, previous_handler)
        write_receiver_state(
            config,
            serving.model_copy(update={"status": "stopped", "pid": None}),
        )


def health_receiver(config: QAReceiverConfig) -> bool:
    connection = HTTPConnection(config.host, config.port, timeout=5)
    try:
        connection.request("GET", "/health")
        return connection.getresponse().status == HTTPStatus.OK
    except OSError:
        return False
    finally:
        connection.close()


def create_pairing_material(
    config: QAReceiverConfig,
    *,
    run_id: str,
    challenge: str,
    source_commit: str,
) -> Path:
    invitation = create_pairing_invitation(
        config.database_path,
        label=f"{config.namespace}-device",
        receiver_url=f"http://{config.host}:{config.port}/v1/batches",
    )
    request = {
        "v": 1,
        "kind": "health_bridge.mailbox_qa_invocation.v1",
        "action": "pair",
        "run_id": run_id,
        "challenge": challenge,
        "source_commit": source_commit,
        "bundle_identifier": config.bundle_identifier,
        "container_identifier": config.container_identifier,
        "keychain_service": f"{config.bundle_identifier}.mailboxqa",
        "outbox_root": config.outbox_root,
        "namespace": config.namespace,
        "redeem_url": f"http://{config.host}:{config.port}/qa/v1/pairing/redeem",
        "invitation_secret": invitation.invitation_secret,
    }
    return _write_invocation_material(
        config,
        request,
        "qa-invocation-pair",
    )


def create_action_material(  # noqa: PLR0913
    config: QAReceiverConfig,
    *,
    action: Literal["advance", "scan_finalize", "signed_report", "cleanup"],
    run_id: str,
    challenge: str,
    source_commit: str,
    fault: Literal["publisher_enospc"] | None = None,
) -> Path:
    if fault is not None and action != "advance":
        raise ValueError
    request = {
        "v": 1,
        "kind": "health_bridge.mailbox_qa_invocation.v1",
        "action": action,
        "run_id": run_id,
        "challenge": challenge,
        "source_commit": source_commit,
        "bundle_identifier": config.bundle_identifier,
        "container_identifier": config.container_identifier,
        "keychain_service": config.keychain_service,
        "outbox_root": config.outbox_root,
        "namespace": config.namespace,
    }
    if fault is not None:
        request["fault"] = fault
    return _write_invocation_material(
        config,
        request,
        f"qa-invocation-{action}",
    )


def _write_invocation_material(
    config: QAReceiverConfig,
    request: Mapping[str, object],
    stem: str,
) -> Path:
    encoded = json.dumps(request, sort_keys=True, separators=(",", ":"))
    path = config.runtime_root / f"private/{stem}.json"
    write_private_text_file(
        path,
        encoded,
    )
    invocation_url = f"{config.url_scheme}://invoke?" + urlencode(
        {"request": base64.b64encode(encoded.encode("utf-8")).decode("ascii")}
    )
    write_private_text_file(
        config.runtime_root / f"private/{stem}.url",
        invocation_url,
    )
    return path


def import_once(config: QAReceiverConfig) -> tuple[int, int, int, int, int, int]:
    mailbox_path = _single_mailbox_path(config)
    key_store = MailboxKeyStore.for_testing(
        state_dir=config.runtime_root / "private/receiver-keys",
        anchor_dir=config.runtime_root / "private/receiver-anchor",
    )
    connections = MailboxConnectionStore.for_testing(
        config.runtime_root / "private/connections",
        key_store,
    )
    importer = MailboxImporter(
        MailboxImportConfig(
            db_path=config.database_path,
            mailbox_path=mailbox_path,
            lock_path=connections.lock_path(mailbox_path),
            connection=connections.load(mailbox_path),
            clock_ms=lambda: time.time_ns() // 1_000_000,
            path_replacement_retry_limit=(
                1 if config.mailbox_root_override is not None else 0
            ),
        )
    )
    return importer.import_once().counts()


def acknowledgment_ready(config: QAReceiverConfig) -> bool:
    mailbox_path = _single_mailbox_path(config)
    acknowledgments = mailbox_path / "acks"
    return sum(1 for path in acknowledgments.iterdir() if path.suffix == ".hba") == 1


def receiver_receipt_private_key(
    config: QAReceiverConfig,
) -> Ed25519PrivateKey:
    encoded = config.receipt_key_path.read_text(encoding="ascii")
    raw = base64.urlsafe_b64decode(encoded + "=")
    canonical = base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")
    if len(raw) != ED25519_PRIVATE_KEY_BYTES or canonical != encoded:
        raise RuntimeError
    return Ed25519PrivateKey.from_private_bytes(raw)


def stop_receiver(config: QAReceiverConfig) -> None:
    state = _read_state(config)
    if state.status != "serving" or state.pid is None:
        raise RuntimeError
    config.require_owner_process(state.pid)
    process = process_command_for_pid(state.pid)
    expected = str(config.runtime_root).encode()
    if b"mailbox-qa-receiver.py" not in process or expected not in process:
        raise RuntimeError
    os.kill(state.pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if _read_state(config).status == "stopped":
            return
        time.sleep(0.05)
    raise RuntimeError


def process_command_for_pid(pid: int) -> bytes:
    proc_command = Path(f"/proc/{pid}/cmdline")
    if proc_command.is_file():
        try:
            return proc_command.read_bytes()
        except OSError as exc:
            raise RuntimeError from exc
    read_fd, write_fd = os.pipe()
    try:
        child_pid = os.posix_spawn(
            "/bin/ps",
            ("/bin/ps", "-p", str(pid), "-o", "command="),
            os.environ,
            file_actions=(
                (os.POSIX_SPAWN_DUP2, write_fd, 1),
                (os.POSIX_SPAWN_CLOSE, read_fd),
                (os.POSIX_SPAWN_CLOSE, write_fd),
            ),
        )
    except OSError as exc:
        os.close(read_fd)
        os.close(write_fd)
        raise RuntimeError from exc
    os.close(write_fd)
    chunks: list[bytes] = []
    try:
        while chunk := os.read(read_fd, 4096):
            chunks.append(chunk)
    finally:
        os.close(read_fd)
    waited_pid, status = os.waitpid(child_pid, 0)
    output = b"".join(chunks)
    if waited_pid != child_pid or status != 0 or not output.strip():
        raise RuntimeError
    return output


def cleanup_receiver(config: QAReceiverConfig, receipt_path: Path) -> None:
    if receipt_path.absolute().is_relative_to(config.runtime_root):
        raise RuntimeError
    state = _read_state(config)
    if state.status == "serving":
        raise RuntimeError
    run_reference = hashlib.sha256(config.namespace.encode()).hexdigest()[:16]
    shutil.rmtree(config.runtime_root)
    write_private_text_file(
        receipt_path,
        json.dumps(
            {
                "v": 1,
                "kind": "health_bridge.mailbox_qa_cleanup_receipt.v1",
                "status": "complete",
                "run_reference": run_reference,
            },
            sort_keys=True,
            separators=(",", ":"),
        ),
    )


def _single_mailbox_path(config: QAReceiverConfig) -> Path:
    candidates = [
        device
        for receiver in config.mailbox_root.iterdir()
        if receiver.is_dir() and not receiver.is_symlink()
        for device in receiver.iterdir()
        if device.is_dir() and not device.is_symlink()
    ]
    if len(candidates) != 1:
        raise RuntimeError
    return candidates[0]


def _exit_after_cleanup(_signal: int, _frame: FrameType | None) -> NoReturn:
    raise SystemExit(0)


def write_receiver_state(config: QAReceiverConfig, state: QAReceiverState) -> None:
    write_private_text_file(
        config.state_path,
        state.model_dump_json(),
    )


def _read_state(config: QAReceiverConfig) -> QAReceiverState:
    return QAReceiverState.model_validate_json(config.state_path.read_bytes())


__all__ = [
    "QAReceiverState",
    "acknowledgment_ready",
    "cleanup_receiver",
    "create_action_material",
    "create_pairing_material",
    "health_receiver",
    "import_once",
    "prepare_receiver",
    "process_command_for_pid",
    "receiver_receipt_private_key",
    "serve_receiver",
    "stop_receiver",
    "write_receiver_state",
]

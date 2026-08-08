from __future__ import annotations

import secrets
import socket
import subprocess
import sys
import time
from contextlib import closing, contextmanager
from http.client import HTTPConnection, RemoteDisconnected
from pathlib import Path
from typing import TYPE_CHECKING, Final

from pydantic import TypeAdapter

from health_bridge.receiver.tokens import create_receiver_token
from tests.receiver.test_legacy_http_contract import (
    FIXTURE_PATH,
    HttpObservation,
    post_raw_batch,
)

if TYPE_CHECKING:
    from collections.abc import Generator

STARTUP_TIMEOUT_SECONDS: Final = 10.0
REQUEST_TIMEOUT_SECONDS: Final = 1.0
SOCKET_ADDRESS_ADAPTER: Final[TypeAdapter[tuple[str, int]]] = TypeAdapter(
    tuple[str, int]
)


def _available_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        address = SOCKET_ADDRESS_ADAPTER.validate_python(listener.getsockname())
    return address[1]


def _health_status(port: int) -> int:
    with closing(
        HTTPConnection("127.0.0.1", port, timeout=REQUEST_TIMEOUT_SECONDS)
    ) as connection:
        connection.request("GET", "/health")
        response = connection.getresponse()
        _ = response.read()
        return response.status


def _wait_until_healthy(process: subprocess.Popen[bytes], port: int) -> None:
    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if process.poll() is not None:
            message = f"receiver CLI exited before health check: {process.returncode}"
            raise RuntimeError(message)
        try:
            if _health_status(port) == 200:
                return
        except (OSError, RemoteDisconnected):
            continue
    message = "receiver CLI did not become healthy before the bounded deadline"
    raise TimeoutError(message)


def _post_without_authorization(port: int) -> tuple[int, bytes]:
    with closing(
        HTTPConnection("127.0.0.1", port, timeout=REQUEST_TIMEOUT_SECONDS)
    ) as connection:
        connection.request(
            "POST",
            "/v1/batches",
            body=b"{}",
            headers={"Content-Type": "application/json"},
        )
        response = connection.getresponse()
        return response.status, response.read()


@contextmanager
def _running_receiver_cli(db_path: Path, port: int) -> Generator[None, None, None]:
    executable = Path(sys.executable).with_name("health-bridge")
    process = subprocess.Popen(
        [
            str(executable),
            "receiver",
            "start",
            "--db",
            str(db_path),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        _wait_until_healthy(process, port)
        yield
    finally:
        process.terminate()
        try:
            _ = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            _ = process.wait(timeout=5)


def test_shipped_cli_accepts_authenticated_post_while_lifetime_lock_is_held(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    token = f"hb_{secrets.token_urlsafe(24)}"
    _ = create_receiver_token(db_path, label="cli-lifecycle-red", token=token)
    port = _available_port()

    # When
    with _running_receiver_cli(db_path, port):
        health_status = _health_status(port)
        unauthorized = _post_without_authorization(port)
        try:
            authenticated: HttpObservation | None = post_raw_batch(
                port,
                token,
                FIXTURE_PATH.read_bytes(),
            )
        except TimeoutError:
            authenticated = None

    # Then
    assert health_status == 200
    assert unauthorized == (401, b'{"error":"unauthorized"}')
    assert authenticated is not None, "authenticated POST timed out under CLI lock"
    assert authenticated.status == 202

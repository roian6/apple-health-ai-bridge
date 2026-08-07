from __future__ import annotations

import socket
import time
from collections.abc import Callable
from http import HTTPStatus
from http.client import HTTPConnection, HTTPException, HTTPResponse
from typing import (
    TYPE_CHECKING,
    ClassVar,
    Final,
    Literal,
    Protocol,
    Self,
    TypeAlias,
    final,
)

from pydantic import BaseModel, ConfigDict, ValidationError
from typing_extensions import override

from health_bridge.launchd.models import (
    MAX_TCP_PORT,
    LaunchdServiceError,
    LaunchdServiceErrorCode,
    LocalHealthStatus,
)

if TYPE_CHECKING:
    from _typeshed import ReadableBuffer, WriteableBuffer

MAX_HEALTH_BODY_BYTES: Final = 4_096
_READ_CHUNK_BYTES: Final = 1_024
_MAX_IO_TIMEOUT_SECONDS: Final = 0.25


class _HealthBody(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="ignore",
        frozen=True,
        strict=True,
    )

    status: Literal["ok", "degraded", "error"]


class HealthResponse(Protocol):
    status: int

    def getheader(self, name: str) -> str | None: ...

    def read1(self, amount: int) -> bytes: ...

    def close(self) -> None: ...


class HealthConnection(Protocol):
    def request(self, method: str, target: str) -> None: ...

    def getresponse(self) -> HealthResponse: ...

    def close(self) -> None: ...

    def __enter__(self) -> Self: ...

    def __exit__(self, *_args: object) -> None: ...


Clock: TypeAlias = Callable[[], float]
ConnectionFactory: TypeAlias = Callable[[str, int, float, Clock], HealthConnection]


class _UnavailableResponseError(Exception):
    pass


@final
class _DeadlineSocket(socket.socket):
    def __init__(self, *, deadline: float, monotonic: Clock) -> None:
        super().__init__(socket.AF_INET, socket.SOCK_STREAM)
        self._deadline = deadline
        self._monotonic = monotonic

    def prepare_io(self) -> None:
        remaining = self._deadline - self._monotonic()
        if remaining <= 0:
            raise TimeoutError
        self.settimeout(min(remaining, _MAX_IO_TIMEOUT_SECONDS))

    @override
    def recv_into(
        self,
        buffer: WriteableBuffer,
        nbytes: int = 0,
        flags: int = 0,
    ) -> int:
        self.prepare_io()
        return super().recv_into(buffer, nbytes, flags)

    @override
    def sendall(self, data: ReadableBuffer, flags: int = 0) -> None:
        self.prepare_io()
        super().sendall(data, flags)


@final
class _DeadlineHTTPConnection(HTTPConnection):
    def __init__(
        self,
        host: str,
        port: int,
        deadline: float,
        monotonic: Clock,
    ) -> None:
        super().__init__(host=host, port=port, timeout=deadline - monotonic())
        self._deadline = deadline
        self._monotonic = monotonic

    @override
    def connect(self) -> None:
        connected = _DeadlineSocket(
            deadline=self._deadline,
            monotonic=self._monotonic,
        )
        try:
            connected.prepare_io()
            connected.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            connected.connect((self.host, self.port))
        except OSError:
            connected.close()
            raise
        self.sock = connected


@final
class _HTTPResponseAdapter:
    def __init__(self, response: HTTPResponse) -> None:
        self._response = response
        self.status = response.status

    def getheader(self, name: str) -> str | None:
        return self._response.getheader(name)

    def read1(self, amount: int) -> bytes:
        return self._response.read1(amount)

    def close(self) -> None:
        self._response.close()


@final
class _HTTPConnectionAdapter:
    def __init__(self, connection: _DeadlineHTTPConnection) -> None:
        self._connection = connection

    def request(self, method: str, target: str) -> None:
        self._connection.request(method, target)

    def getresponse(self) -> HealthResponse:
        return _HTTPResponseAdapter(self._connection.getresponse())

    def close(self) -> None:
        self._connection.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()


def _connection_factory(
    host: str,
    port: int,
    deadline: float,
    monotonic: Clock,
) -> HealthConnection:
    return _HTTPConnectionAdapter(
        _DeadlineHTTPConnection(host, port, deadline, monotonic)
    )


@final
class LocalHealthProbe:
    def __init__(
        self,
        *,
        timeout_seconds: float,
        monotonic: Clock = time.monotonic,
        connection_factory: ConnectionFactory = _connection_factory,
    ) -> None:
        if timeout_seconds <= 0:
            raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
        self._timeout_seconds = timeout_seconds
        self._monotonic = monotonic
        self._connection_factory = connection_factory

    def probe(self, host: str, port: int) -> LocalHealthStatus:
        if host != "127.0.0.1" or not 1 <= port <= MAX_TCP_PORT:
            raise LaunchdServiceError(LaunchdServiceErrorCode.INVALID_CONFIGURATION)
        deadline = self._monotonic() + self._timeout_seconds
        try:
            with self._connection_factory(
                host,
                port,
                deadline,
                self._monotonic,
            ) as connection:
                connection.request("GET", "/health")
                response = connection.getresponse()
                try:
                    payload = _read_bounded(response, deadline, self._monotonic)
                    status = response.status
                finally:
                    response.close()
        except (_UnavailableResponseError, HTTPException, OSError):
            return LocalHealthStatus.UNAVAILABLE
        try:
            body = _HealthBody.model_validate_json(payload)
        except ValidationError:
            return LocalHealthStatus.UNAVAILABLE
        return _classify_health(status, body.status)


def _read_bounded(
    response: HealthResponse,
    deadline: float,
    monotonic: Clock,
) -> bytes:
    declared = _parse_content_length(response.getheader("Content-Length"))
    chunks: list[bytes] = []
    received = 0
    while received <= MAX_HEALTH_BODY_BYTES:
        if monotonic() >= deadline:
            raise _UnavailableResponseError
        requested = min(
            _READ_CHUNK_BYTES,
            MAX_HEALTH_BODY_BYTES + 1 - received,
        )
        chunk = response.read1(requested)
        if monotonic() >= deadline:
            raise _UnavailableResponseError
        if len(chunk) > requested:
            raise _UnavailableResponseError
        if not chunk:
            break
        chunks.append(chunk)
        received += len(chunk)
    if received > MAX_HEALTH_BODY_BYTES:
        raise _UnavailableResponseError
    if declared is not None and received != declared:
        raise _UnavailableResponseError
    return b"".join(chunks)


def _parse_content_length(header: str | None) -> int | None:
    if header is None:
        return None
    try:
        declared = int(header)
    except ValueError as exc:
        raise _UnavailableResponseError from exc
    if declared < 0 or declared > MAX_HEALTH_BODY_BYTES:
        raise _UnavailableResponseError
    return declared


def _classify_health(status: int, body_status: str) -> LocalHealthStatus:
    if status == HTTPStatus.OK and body_status == "ok":
        return LocalHealthStatus.OK
    if status == HTTPStatus.SERVICE_UNAVAILABLE and body_status == "degraded":
        return LocalHealthStatus.DEGRADED
    if status >= HTTPStatus.INTERNAL_SERVER_ERROR and body_status == "error":
        return LocalHealthStatus.TERMINAL
    return LocalHealthStatus.UNAVAILABLE

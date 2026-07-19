import json
import sqlite3
import time
from collections import OrderedDict, deque
from collections.abc import Callable
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from typing import ClassVar, Final, Self, TypeAlias, cast, final
from urllib.parse import urlparse

from pydantic import BaseModel, ConfigDict, ValidationError, model_validator
from typing_extensions import override

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.ingest import ingest_batch
from health_bridge.receiver.invitations import (
    PairingInvitationError,
    redeem_pairing_invitation,
)
from health_bridge.receiver.source_binding import (
    SourcePrincipalMismatchError,
    bind_batch_to_principal,
)
from health_bridge.receiver.tokens import (
    ReceiverTokenPrincipal,
    authenticate_receiver_token_principal,
)
from health_bridge.storage.database import (
    database_access_lock,
    database_lifecycle_lock,
    initialize_database,
)
from health_bridge.storage.models import IngestResult
from health_bridge.storage.sleep import StaleOrderedSleepBaselineResetError

MAX_BATCH_BYTES: Final = 5_000_000
MAX_PAIRING_REDEEM_BYTES: Final = 4_096
PAIRING_REDEEM_LIMIT: Final = 5
PAIRING_REDEEM_WINDOW_SECONDS: Final = 60
PAIRING_REDEEM_MAX_CLIENTS: Final = 1_024
JsonPayloadValue: TypeAlias = bool | int | str
JsonPayload: TypeAlias = dict[str, JsonPayloadValue]


class PairingRedeemRequest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", frozen=True)

    invitation_secret: str | None = None
    invitation_code: str | None = None
    installation_id: str
    device_credential: str
    platform: str

    @model_validator(mode="after")
    def exactly_one_credential(self) -> Self:
        if (self.invitation_secret is None) == (self.invitation_code is None):
            message = "exactly one invitation credential is required"
            raise ValueError(message)
        return self


@final
class PairingRedeemRateLimiter:
    def __init__(
        self,
        *,
        max_attempts: int = PAIRING_REDEEM_LIMIT,
        window_seconds: float = PAIRING_REDEEM_WINDOW_SECONDS,
        max_clients: int = PAIRING_REDEEM_MAX_CLIENTS,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self.max_attempts = max_attempts
        self.window_seconds = window_seconds
        self.max_clients = max_clients
        self.clock = time.monotonic if clock is None else clock
        self._attempts: OrderedDict[str, deque[float]] = OrderedDict()
        self._lock = Lock()

    def allow(self, client_key: str) -> bool:
        now = self.clock()
        cutoff = now - self.window_seconds
        with self._lock:
            attempts = self._attempts.get(client_key)
            if attempts is None:
                if len(self._attempts) >= self.max_clients:
                    _ = self._attempts.popitem(last=False)
                attempts = deque[float]()
                self._attempts[client_key] = attempts
            else:
                self._attempts.move_to_end(client_key)
            while attempts and attempts[0] <= cutoff:
                _ = attempts.popleft()
            if len(attempts) >= self.max_attempts:
                return False
            attempts.append(now)
            return True


class ReceiverHTTPServer(ThreadingHTTPServer):
    def __init__(self, host: str, port: int, db_path: Path) -> None:
        self.db_path: Path = db_path
        self.pairing_redeem_limiter: PairingRedeemRateLimiter = (
            PairingRedeemRateLimiter()
        )
        super().__init__((host, port), ReceiverRequestHandler)

    @override
    def handle_error(self, request: object, client_address: object) -> None:
        """Suppress socketserver's default traceback and client-address dump."""


class ReceiverRequestHandler(BaseHTTPRequestHandler):
    @property
    def receiver_server(self) -> ReceiverHTTPServer:
        return cast("ReceiverHTTPServer", self.server)

    @override
    def log_message(
        self,
        format: str,
        *_args: object,
    ) -> None:
        """Keep request paths and client addresses out of default stderr logs."""

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path != "/health":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        self._send_json(
            HTTPStatus.OK,
            {
                "status": "ok",
                "service": "health-bridge-receiver",
                "local_first_default": True,
            },
        )

    def do_POST(self) -> None:  # noqa: PLR0911
        path = urlparse(self.path).path
        if path == "/v1/pairing/redeem":
            self._handle_pairing_redeem()
            return
        if path != "/v1/batches":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        principal = self._authorize_batch_request()
        if principal is None:
            return
        body = self._read_body()
        if body is None:
            return
        try:
            batch = HealthBridgeBatchV1.model_validate_json(body)
        except ValidationError:
            self._send_json(
                HTTPStatus.UNPROCESSABLE_ENTITY,
                {"error": "payload does not match health_bridge.batch.v1 schema"},
            )
            return
        try:
            batch = bind_batch_to_principal(batch, principal)
        except SourcePrincipalMismatchError:
            self._send_json(
                HTTPStatus.FORBIDDEN,
                {"error": "source_principal_mismatch"},
            )
            return
        result = self._ingest_batch_or_send_error(batch)
        if result is None:
            return
        self._send_json(
            HTTPStatus.ACCEPTED,
            _response_for_ingest_result(result),
        )

    def _ingest_batch_or_send_error(
        self,
        batch: HealthBridgeBatchV1,
    ) -> IngestResult | None:
        try:
            return ingest_batch(
                self.receiver_server.db_path, batch, source_name="receiver"
            )
        except StaleOrderedSleepBaselineResetError as exc:
            self._send_json(
                HTTPStatus.CONFLICT,
                {
                    "error": "sleep_baseline_reset_epoch_conflict",
                    "minimum_reset_epoch": exc.current_epoch,
                },
            )
            return None
        except (sqlite3.Error, OSError):
            self._send_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": "records could not be stored"},
            )
            return None

    def _handle_pairing_redeem(self) -> None:
        client_key = self.client_address[0]
        if not self.receiver_server.pairing_redeem_limiter.allow(client_key):
            self._send_json(
                HTTPStatus.TOO_MANY_REQUESTS,
                {"error": "pairing_rate_limited"},
                extra_headers={"Retry-After": str(PAIRING_REDEEM_WINDOW_SECONDS)},
            )
            return
        body = self._read_body(
            max_bytes=MAX_PAIRING_REDEEM_BYTES,
            too_large_error="pairing_request_too_large",
        )
        if body is None:
            return
        try:
            payload = PairingRedeemRequest.model_validate_json(body)
            completion = redeem_pairing_invitation(
                self.receiver_server.db_path,
                invitation_secret=payload.invitation_secret,
                invitation_code=payload.invitation_code,
                installation_id=payload.installation_id,
                device_credential=payload.device_credential,
                platform=payload.platform,
            )
        except (PairingInvitationError, ValidationError):
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "pairing_invitation_invalid"},
            )
            return
        except (sqlite3.Error, OSError):
            self._send_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": "pairing_temporarily_unavailable"},
            )
            return
        self._send_json(
            HTTPStatus.OK,
            {
                "schema_id": "health_bridge.receiver_pairing_completion.v1",
                "schema_version": "1.0.0",
                "label": completion.label,
                "receiver_url": completion.receiver_url,
            },
        )

    def _authorize_batch_request(self) -> ReceiverTokenPrincipal | None:
        try:
            principal = self._authenticated_principal()
        except (sqlite3.Error, OSError):
            self._send_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": "authentication_temporarily_unavailable"},
            )
            return None
        if principal is not None:
            return principal
        self._send_json(
            HTTPStatus.UNAUTHORIZED,
            {"error": "unauthorized"},
            extra_headers={"WWW-Authenticate": "Bearer"},
        )
        return None

    def _authenticated_principal(self) -> ReceiverTokenPrincipal | None:
        authorization = self.headers.get("Authorization", "")
        scheme, separator, token = authorization.partition(" ")
        # This is an empty parsed header field, not a credential literal.
        empty_token = token == ""  # nosec B105
        if separator == "" or scheme.lower() != "bearer" or empty_token:
            return None
        return authenticate_receiver_token_principal(
            self.receiver_server.db_path,
            token,
        )

    def _read_body(
        self,
        *,
        max_bytes: int = MAX_BATCH_BYTES,
        too_large_error: str = "batch_too_large",
    ) -> bytes | None:
        content_length_header = self.headers.get("Content-Length")
        if content_length_header is None:
            self._send_json(
                HTTPStatus.LENGTH_REQUIRED,
                {"error": "content_length_required"},
            )
            return None
        try:
            content_length = int(content_length_header)
        except ValueError:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "invalid_content_length"},
            )
            return None
        if content_length < 0:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "invalid_content_length"},
            )
            return None
        if content_length > max_bytes:
            self._send_json(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"error": too_large_error},
            )
            return None
        return self.rfile.read(content_length)

    def _send_json(
        self,
        status: HTTPStatus,
        payload: JsonPayload,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        response_body = json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response_body)))
            if extra_headers is not None:
                for header_name, header_value in extra_headers.items():
                    self.send_header(header_name, header_value)
            self.end_headers()
            _ = self.wfile.write(response_body)
        except (BrokenPipeError, ConnectionResetError):
            return


def build_receiver_server(db_path: Path, host: str, port: int) -> ReceiverHTTPServer:
    initialize_database(db_path)
    return ReceiverHTTPServer(host=host, port=port, db_path=db_path)


def serve_receiver(db_path: Path, host: str, port: int) -> None:
    initialize_database(db_path)
    with (
        database_lifecycle_lock(db_path, exclusive=False, create=False),
        database_access_lock(db_path, exclusive=False, create=False),
        ReceiverHTTPServer(host=host, port=port, db_path=db_path) as server,
    ):
        server.serve_forever()


def _response_for_ingest_result(result: IngestResult) -> dict[str, str | int]:
    return {
        "status": result.status,
        "source": "receiver",
        "source_count": result.source_count,
        "health_type_count": result.health_type_count,
        "sample_count": result.sample_count,
        "workout_count": result.workout_count,
        "sleep_session_count": result.sleep_session_count,
        "deleted_record_count": result.deleted_record_count,
        "sync_cursor_count": result.sync_cursor_count,
    }


def server_port(server: ReceiverHTTPServer) -> int:
    return cast("tuple[str, int]", server.server_address)[1]

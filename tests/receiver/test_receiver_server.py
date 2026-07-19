from http.client import HTTPResponse
from io import BufferedIOBase
from pathlib import Path
from threading import Thread
from typing import Self, cast, final
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest
from pydantic import BaseModel
from typing_extensions import override

import health_bridge.receiver.server as receiver_server_module
from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import SyncCursor
from health_bridge.queries.timeseries import get_timeseries
from health_bridge.receiver.server import (
    ReceiverRequestHandler,
    build_receiver_server,
    server_port,
)
from health_bridge.receiver.tokens import create_receiver_token
from health_bridge.storage import initialize_database
from health_bridge.storage.database import database_lifecycle_lock


class ReceiverIngestResponse(BaseModel):
    status: str
    source: str
    sample_count: int


class SleepEpochConflictResponse(BaseModel):
    error: str
    minimum_reset_epoch: int


def test_receiver_holds_lifecycle_lock_while_idle(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    checked = False

    @final
    class IdleServer:
        def __init__(self, *, host: str, port: int, db_path: Path) -> None:
            del host, port
            self.db_path = db_path

        def __enter__(self) -> Self:
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def serve_forever(self) -> None:
            nonlocal checked
            with (
                pytest.raises(BlockingIOError),
                database_lifecycle_lock(
                    self.db_path,
                    exclusive=True,
                    create=False,
                    nonblocking=True,
                ),
            ):
                pass
            checked = True

    monkeypatch.setattr(receiver_server_module, "ReceiverHTTPServer", IdleServer)

    receiver_server_module.serve_receiver(db_path, "127.0.0.1", 0)

    assert checked


def test_receiver_returns_current_sleep_epoch_floor_for_stale_baseline(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    batch = HealthBridgeBatchV1.model_validate_json(
        Path("fixtures/health_bridge_batch_v1.synthetic.json").read_bytes()
    )
    sleep = batch.sleep_sessions[0]

    def sleep_reset_batch(epoch: int) -> HealthBridgeBatchV1:
        return batch.model_copy(
            update={
                "samples": (),
                "workouts": (),
                "sleep_sessions": (sleep,),
                "deleted_records": (),
                "sync": batch.sync.model_copy(
                    update={
                        "cursors": (
                            SyncCursor(
                                source_key=sleep.source_key,
                                cursor_kind="anchored_sleep_sync",
                                cursor_value=f"anchor-{epoch}",
                            ),
                            SyncCursor(
                                source_key=sleep.source_key,
                                cursor_kind="anchored_sleep_baseline_reset",
                                cursor_value=f"v2:{epoch}",
                            ),
                        )
                    }
                ),
            }
        )

    initialize_database(db_path)
    token = create_receiver_token(
        db_path, label="ios-companion", token="hb_receiver_secret"
    ).token
    server = build_receiver_server(db_path, host="127.0.0.1", port=0)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server_port(server)}/v1/batches"

        def request_for(epoch: int) -> Request:
            return Request(
                url,
                data=sleep_reset_batch(epoch).model_dump_json(by_alias=True).encode(),
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )

        with open_http_response(request_for(200)) as response:
            assert response.status == 202
        with pytest.raises(HTTPError) as exc_info:
            open_request_for_error(request_for(100))
        error = exc_info.value
        body = SleepEpochConflictResponse.model_validate_json(error.read())
        error.close()

        assert error.code == 409
        assert body.error == "sleep_baseline_reset_epoch_conflict"
        assert body.minimum_reset_epoch == 200
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_receiver_accepts_authorized_batch_and_ingests_records(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    fixture_path = Path("fixtures/health_bridge_batch_v1.synthetic.json")
    initialize_database(db_path)
    token = create_receiver_token(
        db_path,
        label="ios-companion",
        token="hb_receiver_secret",
    ).token
    server = build_receiver_server(db_path, host="127.0.0.1", port=0)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        url = f"http://127.0.0.1:{server_port(server)}/v1/batches"
        request = Request(
            url,
            data=fixture_path.read_bytes(),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )

        # When
        with open_http_response(request) as response:
            status_code = response.status
            body = ReceiverIngestResponse.model_validate_json(response.read())

        points = get_timeseries(
            db_path,
            type_codes=("steps",),
            start_time="2026-06-01T00:00:00Z",
            end_time="2026-06-08T00:00:00Z",
        ).points

        # Then
        assert status_code == 202
        assert body.status == "succeeded"
        assert body.source == "receiver"
        assert body.sample_count == 3
        assert points[0].type_code == "steps"
        assert points[0].value == 4321.0
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_receiver_rejects_unauthorized_batches_without_ingest(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    fixture_path = Path("fixtures/health_bridge_batch_v1.synthetic.json")
    initialize_database(db_path)
    _ = create_receiver_token(
        db_path, label="ios-companion", token="hb_receiver_secret"
    )
    server = build_receiver_server(db_path, host="127.0.0.1", port=0)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        url = f"http://127.0.0.1:{server_port(server)}/v1/batches"
        request = Request(
            url,
            data=fixture_path.read_bytes(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        # When / Then
        with pytest.raises(HTTPError) as exc_info:
            open_request_for_error(request)
        exc_info.value.close()
        assert exc_info.value.code == 401
        assert (
            get_timeseries(
                db_path,
                type_codes=("steps",),
                start_time="2026-06-01T00:00:00Z",
                end_time="2026-06-08T00:00:00Z",
            ).points
            == ()
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_receiver_json_response_ignores_disconnected_client() -> None:
    # Given
    handler = object.__new__(DisconnectedReceiverRequestHandler)
    handler.path = "/health"
    handler.wfile = BrokenPipeWriter()

    # When / Then
    handler.do_GET()


@final
class DisconnectedReceiverRequestHandler(ReceiverRequestHandler):
    @override
    def send_response(self, code: int, message: str | None = None) -> None:
        pass

    @override
    def send_header(self, keyword: str, value: str) -> None:
        pass

    @override
    def end_headers(self) -> None:
        pass


@final
class BrokenPipeWriter(BufferedIOBase):
    @override
    def write(self, _data: object) -> int:
        raise BrokenPipeError


def open_request_for_error(request: Request) -> None:
    response = open_http_response(request)
    response.close()


def open_http_response(request: Request) -> HTTPResponse:
    return cast("HTTPResponse", urlopen(request, timeout=5))

import json
import sqlite3
from collections.abc import Generator
from contextlib import contextmanager
from http.client import HTTPResponse, RemoteDisconnected
from pathlib import Path
from threading import Thread
from typing import ClassVar, cast
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest
from pydantic import BaseModel, ConfigDict, TypeAdapter

import health_bridge.receiver.server as receiver_server_module
from health_bridge.receiver.invitations import create_pairing_invitation
from health_bridge.receiver.server import (
    PairingRedeemRateLimiter,
    build_receiver_server,
    server_port,
)
from health_bridge.receiver.tokens import authenticate_receiver_token_principal

SYNTHETIC_INSTALLATION_ID = "00000000-0000-4000-8000-000000000001"
SYNTHETIC_DEVICE_CREDENTIAL = "hb_" + "a" * 64
SECOND_DEVICE_CREDENTIAL = "hb_" + "b" * 64


class PairingCompletionResponse(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid")

    schema_id: str
    schema_version: str
    label: str
    receiver_url: str


@contextmanager
def running_receiver(db_path: Path) -> Generator[str, None, None]:
    server = build_receiver_server(db_path, host="127.0.0.1", port=0)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server_port(server)}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def redeem_body(
    *,
    installation_id: str = SYNTHETIC_INSTALLATION_ID,
    device_credential: str = SYNTHETIC_DEVICE_CREDENTIAL,
    platform: str = "ios",
    **grant: str,
) -> bytes:
    return json.dumps(
        {
            **grant,
            "installation_id": installation_id,
            "device_credential": device_credential,
            "platform": platform,
        }
    ).encode()


def test_receiver_redeems_invitation_secret_for_staged_device_credential(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    with running_receiver(db_path) as origin:
        body = redeem_body(invitation_secret=invitation.invitation_secret)
        request = Request(
            f"{origin}/v1/pairing/redeem",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with open_http_response(request) as response:
            status_code = response.status
            response_bytes = response.read()

    completion = PairingCompletionResponse.model_validate_json(response_bytes)
    assert status_code == 200
    assert completion.schema_id == "health_bridge.receiver_pairing_completion.v1"
    assert completion.schema_version == "1.0.0"
    assert completion.receiver_url == invitation.receiver_url
    assert authenticate_receiver_token_principal(db_path, SYNTHETIC_DEVICE_CREDENTIAL)
    assert SYNTHETIC_DEVICE_CREDENTIAL.encode() not in response_bytes
    assert invitation.invitation_secret.encode() not in response_bytes
    assert invitation.invitation_code.encode() not in response_bytes


def test_receiver_redeems_normalized_invitation_code(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    with running_receiver(db_path) as origin:
        request = Request(
            f"{origin}/v1/pairing/redeem",
            data=redeem_body(invitation_code="abcde fghjk mnpqr"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with open_http_response(request) as response:
            completion = PairingCompletionResponse.model_validate_json(response.read())

    assert completion.label == invitation.label
    assert authenticate_receiver_token_principal(db_path, SYNTHETIC_DEVICE_CREDENTIAL)


def test_receiver_redeem_retry_is_idempotent_after_response_loss(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    body = redeem_body(invitation_secret=invitation.invitation_secret)

    with running_receiver(db_path) as origin:
        for _attempt in range(2):
            request = Request(
                f"{origin}/v1/pairing/redeem",
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with open_http_response(request) as response:
                assert response.status == 200
                _ = PairingCompletionResponse.model_validate_json(response.read())

    with sqlite3.connect(db_path) as connection:
        active_mapped_tokens = TypeAdapter(tuple[int]).validate_python(
            connection.execute(
                """
                select count(*)
                from receiver_token_devices mapping
                join receiver_tokens token
                  on token.receiver_token_id = mapping.receiver_token_id
                where token.revoked_at is null
                """
            ).fetchone()
        )[0]
    assert active_mapped_tokens == 1
    assert authenticate_receiver_token_principal(db_path, SYNTHETIC_DEVICE_CREDENTIAL)


def test_receiver_repair_replaces_previous_v2_credential_for_same_installation(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    first = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_first_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    with running_receiver(db_path) as origin:

        def redeem(invitation_secret: str, credential: str) -> None:
            request = Request(
                f"{origin}/v1/pairing/redeem",
                data=redeem_body(
                    invitation_secret=invitation_secret,
                    device_credential=credential,
                ),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with open_http_response(request) as response:
                assert response.status == 200
                _ = response.read()

        redeem(first.invitation_secret, SYNTHETIC_DEVICE_CREDENTIAL)
        second = create_pairing_invitation(
            db_path,
            label="personal-iphone",
            receiver_url="https://health.example.test/v1/batches",
            invitation_secret="hbi_second_synthetic_secret",
            invitation_code="RSTUV-WXYZ2-34567",
        )
        redeem(second.invitation_secret, SECOND_DEVICE_CREDENTIAL)

    assert not authenticate_receiver_token_principal(
        db_path, SYNTHETIC_DEVICE_CREDENTIAL
    )
    assert authenticate_receiver_token_principal(db_path, SECOND_DEVICE_CREDENTIAL)


@pytest.mark.parametrize(
    "body",
    [
        b"not-json",
        b"{}",
        redeem_body(
            invitation_secret="hbi_synthetic_secret",
            invitation_code="ABCDE-FGHJK-MNPQR",
        ),
        json.dumps(
            {
                **json.loads(redeem_body(invitation_code="ABCDE-FGHJK-MNPQR")),
                "unexpected": True,
            }
        ).encode(),
    ],
)
def test_receiver_rejects_malformed_or_ambiguous_redeem_body(
    tmp_path: Path,
    body: bytes,
) -> None:
    db_path = tmp_path / "receiver.sqlite"

    with running_receiver(db_path) as origin:
        error = open_http_error(
            Request(
                f"{origin}/v1/pairing/redeem",
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
        )

    assert error.code == 400
    assert json.loads(error.read()) == {"error": "pairing_invitation_invalid"}
    error.close()


def test_receiver_rejects_oversized_redeem_body(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"

    with running_receiver(db_path) as origin:
        error = open_http_error(
            Request(
                f"{origin}/v1/pairing/redeem",
                data=b"x" * 4097,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
        )

    assert error.code == 413
    assert json.loads(error.read()) == {"error": "pairing_request_too_large"}
    error.close()


def test_receiver_returns_generic_error_for_unavailable_invitation(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"

    with running_receiver(db_path) as origin:
        error = open_http_error(
            Request(
                f"{origin}/v1/pairing/redeem",
                data=redeem_body(invitation_code="ABCDE-FGHJK-MNPQR"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
        )

    assert error.code == 400
    assert json.loads(error.read()) == {"error": "pairing_invitation_invalid"}
    error.close()


@pytest.mark.parametrize(
    "storage_error",
    [
        sqlite3.OperationalError("synthetic pairing storage failure"),
        PermissionError("synthetic pairing storage permission failure"),
    ],
    ids=["sqlite", "filesystem-permission"],
)
def test_receiver_returns_safe_error_without_traceback_for_pairing_storage_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    storage_error: Exception,
) -> None:
    db_path = tmp_path / "receiver.sqlite"

    def fail_redeem(*_args: object, **_kwargs: object) -> None:
        raise storage_error

    monkeypatch.setattr(
        receiver_server_module,
        "redeem_pairing_invitation",
        fail_redeem,
    )
    with running_receiver(db_path) as origin:
        error = open_http_error(
            Request(
                f"{origin}/v1/pairing/redeem",
                data=redeem_body(invitation_code="ABCDE-FGHJK-MNPQR"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
        )
        response_body = TypeAdapter(dict[str, str]).validate_python(
            json.loads(error.read())
        )
        error.close()

    captured = capsys.readouterr()
    assert error.code == 500
    assert response_body == {"error": "pairing_temporarily_unavailable"}
    assert "synthetic pairing storage failure" not in captured.err
    assert "127.0.0.1" not in captured.err


@pytest.mark.parametrize(
    "storage_error",
    [
        sqlite3.OperationalError("synthetic auth storage failure"),
        PermissionError("synthetic auth storage permission failure"),
    ],
    ids=["sqlite", "filesystem-permission"],
)
def test_receiver_returns_safe_error_without_traceback_for_auth_storage_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    storage_error: Exception,
) -> None:
    db_path = tmp_path / "receiver.sqlite"

    def fail_authenticate(*_args: object, **_kwargs: object) -> bool:
        raise storage_error

    monkeypatch.setattr(
        receiver_server_module,
        "authenticate_receiver_token_principal",
        fail_authenticate,
    )
    with running_receiver(db_path) as origin:
        error = open_http_error(
            Request(
                f"{origin}/v1/batches",
                data=b"{}",
                headers={
                    "Authorization": "Bearer synthetic-invalid-token",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
        )
        response_body = TypeAdapter(dict[str, str]).validate_python(
            json.loads(error.read())
        )
        error.close()

    captured = capsys.readouterr()
    assert error.code == 500
    assert response_body == {"error": "authentication_temporarily_unavailable"}
    assert "synthetic auth storage" not in captured.err
    assert "Traceback" not in captured.err
    assert "127.0.0.1" not in captured.err


def test_receiver_suppresses_default_socketserver_traceback_for_unexpected_error(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    db_path = tmp_path / "receiver.sqlite"

    error_message = "synthetic unexpected handler failure"

    def fail_unexpectedly(*_args: object, **_kwargs: object) -> bool:
        raise RuntimeError(error_message)

    monkeypatch.setattr(
        receiver_server_module,
        "authenticate_receiver_token_principal",
        fail_unexpectedly,
    )
    with running_receiver(db_path) as origin, pytest.raises(RemoteDisconnected):
        _ = open_http_response(
            Request(
                f"{origin}/v1/batches",
                data=b"{}",
                headers={"Authorization": "Bearer synthetic-invalid-token"},
                method="POST",
            )
        )

    captured = capsys.readouterr()
    assert "synthetic unexpected handler failure" not in captured.err
    assert "Traceback" not in captured.err
    assert "127.0.0.1" not in captured.err


def test_receiver_does_not_emit_pairing_access_logs(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    db_path = tmp_path / "receiver.sqlite"

    with running_receiver(db_path) as origin:
        error = open_http_error(
            Request(
                f"{origin}/v1/pairing/redeem",
                data=redeem_body(invitation_code="ABCDE-FGHJK-MNPQR"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
        )
        error.close()

    captured = capsys.readouterr()
    assert "/v1/pairing/redeem" not in captured.err
    assert "127.0.0.1" not in captured.err


def test_pairing_rate_limiter_bounds_client_buckets_with_lru_eviction() -> None:
    limiter = PairingRedeemRateLimiter(
        max_attempts=1,
        window_seconds=60,
        max_clients=2,
        clock=lambda: 10.0,
    )

    assert limiter.allow("client-a")
    assert limiter.allow("client-b")
    assert limiter.allow("client-c")
    assert limiter.allow("client-a")


def test_receiver_rate_limits_pairing_redeem_per_client(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"

    with running_receiver(db_path) as origin:
        url = f"{origin}/v1/pairing/redeem"
        for _index in range(5):
            error = open_http_error(
                Request(
                    url,
                    data=redeem_body(invitation_code="ABCDE-FGHJK-MNPQR"),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
            )
            assert error.code == 400
            error.close()
        limited = open_http_error(
            Request(
                url,
                data=redeem_body(invitation_code="ABCDE-FGHJK-MNPQR"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
        )

    assert limited.code == 429
    assert limited.headers.get("Retry-After") == "60"
    assert json.loads(limited.read()) == {"error": "pairing_rate_limited"}
    limited.close()


def open_http_error(request: Request) -> HTTPError:
    with pytest.raises(HTTPError) as exc_info:
        _ = open_http_response(request)
    return exc_info.value


def open_http_response(request: Request) -> HTTPResponse:
    return cast("HTTPResponse", urlopen(request, timeout=5))

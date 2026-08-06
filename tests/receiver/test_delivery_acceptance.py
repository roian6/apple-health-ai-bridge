from __future__ import annotations

import hashlib
import multiprocessing
import sqlite3
from typing import TYPE_CHECKING

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.receiver import _delivery_acceptance_crypto as acceptance_crypto
from health_bridge.receiver.delivery_acceptance import (
    DeliveryAcceptanceFaultPoint,
    DeliveryAcceptanceRequest,
)
from tests.contract.delivery_v1_support import BATCH, authenticated_oversize_envelope
from tests.receiver.delivery_acceptance_support import (
    BINDING,
    PRINCIPAL,
    RequestSpec,
    alternate_batch,
    counts,
    fault_at,
    opened_receipt,
    race_worker,
    request,
    service,
    with_phone_source,
)

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.contract._delivery_models import (
        AckSealParams,
        DeliveryAckV1,
        DeliveryReceiptV1,
    )


def test_exact_bytes_commit_once_and_replay_byte_identical_ack(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "accept.sqlite"
    acceptance = service(db_path)
    delivery_request = request()
    # When
    first = acceptance.accept(delivery_request)
    second = acceptance.accept(delivery_request)
    # Then
    assert first.ack_bytes == second.ack_bytes
    assert first.replayed is False
    assert second.replayed is True
    assert (
        opened_receipt(first.ack_bytes).payload_sha256
        == hashlib.sha256(BATCH).hexdigest()
    )
    assert counts(db_path) == (1, 1, 1)


def test_alternate_exact_bytes_under_new_id_follow_inner_idempotence(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "alternate.sqlite"
    acceptance = service(db_path)
    # When
    first = acceptance.accept(request())
    alternate = acceptance.accept(
        request(RequestSpec(payload=alternate_batch(), envelope_byte=2))
    )
    # Then
    assert first.ack_bytes != alternate.ack_bytes
    assert counts(db_path) == (1, 2, 2)
    with sqlite3.connect(db_path) as database:
        digests = database.execute(
            "select payload_sha256 from delivery_receipts order by receipt_id"
        ).fetchall()
    assert digests == [
        (hashlib.sha256(BATCH).digest(),),
        (hashlib.sha256(alternate_batch()).digest(),),
    ]


@pytest.mark.parametrize(
    "payload",
    [
        b"\xff",
        b'{"schema_id":',
        BATCH + b" trailing",
        BATCH.replace(
            b'{"deleted_records":[]',
            b'{"schema_id":"health_bridge.batch.v1","deleted_records":[]',
        ),
        BATCH.replace(
            b'{"end_time":"2026-06-09T00:00:00Z","start_time"',
            b"".join(
                (
                    b'{"end_time":"2026-06-09T00:00:00Z",',
                    b'"end_time":"2026-06-09T00:00:00Z","start_time"',
                )
            ),
            1,
        ),
        BATCH.replace(
            b'{"client_record_id":"synthetic-sample-1"',
            b'{"unit":"count","client_record_id":"synthetic-sample-1"',
            1,
        ),
        BATCH.replace(b'"value":1.25', b'"value":NaN'),
        BATCH.replace(b'"value":1.25', b'"value":Infinity'),
        BATCH.replace(b'"value":1.25', b'"value":-Infinity'),
        BATCH.replace(b'"schema_version":"1.0.0"', b'"schema_version":"2.0.0"'),
    ],
    ids=[
        "utf8",
        "malformed",
        "trailing",
        "duplicate",
        "duplicate-nested",
        "duplicate-array-object",
        "nan",
        "infinity",
        "negative-infinity",
        "strict-schema",
    ],
)
def test_authenticated_inner_lexical_failures_return_closed_terminal_ack(
    tmp_path: Path, payload: bytes
) -> None:
    # Given
    db_path = tmp_path / "invalid.sqlite"
    acceptance = service(db_path)
    # When
    result = acceptance.accept(request(RequestSpec(payload=payload)))
    # Then
    receipt = opened_receipt(result.ack_bytes)
    assert (receipt.result, receipt.error_code) == ("terminal", "payload_invalid")
    assert counts(db_path) == (0, 0, 0)


def test_authenticated_oversize_returns_closed_terminal_ack(tmp_path: Path) -> None:
    db_path = tmp_path / "oversize.sqlite"
    acceptance = service(db_path)
    oversized = DeliveryAcceptanceRequest(
        envelope_bytes=authenticated_oversize_envelope(b" " * 1_048_577),
        device_principal=PRINCIPAL,
        opaque_binding=BINDING,
    )
    result = acceptance.accept(oversized)
    assert opened_receipt(result.ack_bytes).error_code == "payload_oversize"
    assert counts(db_path) == (0, 0, 0)


@pytest.mark.parametrize(
    ("case", "code"),
    [
        ("principal", "principal_mismatch"),
        ("binding", "binding_mismatch"),
        ("generation", "generation_mismatch"),
        ("revoked", "key_revoked"),
        ("source", "principal_mismatch"),
    ],
)
def test_authenticated_identity_failures_are_closed(
    tmp_path: Path, case: str, code: str
) -> None:
    requests: dict[str, DeliveryAcceptanceRequest] = {
        "principal": request(
            RequestSpec(principal=delivery.DevicePrincipal("synthetic.other"))
        ),
        "binding": request(RequestSpec(binding=delivery.OpaqueBinding(b"\x88" * 32))),
        "generation": request(RequestSpec(generation=6)),
        "revoked": request(),
        "source": request(RequestSpec(payload=with_phone_source(BATCH))),
    }
    acceptance = service(tmp_path / f"{code}.sqlite", revoked=code == "key_revoked")
    result = acceptance.accept(requests[case])
    assert (
        opened_receipt(
            result.ack_bytes,
            generation=6 if code == "generation_mismatch" else 7,
        ).error_code
        == code
    )


def test_wrong_outer_key_is_unauthenticated_and_gets_no_ack(tmp_path: Path) -> None:
    acceptance = service(tmp_path / "wrong-key.sqlite")
    wrong = Ed25519PrivateKey.from_private_bytes(b"\x99" * 32)
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = acceptance.accept(request(RequestSpec(sender=wrong)))
    assert exc.value.code == "authentication_failed"


def test_same_envelope_different_exact_digest_is_terminal_conflict(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "conflict.sqlite"
    acceptance = service(db_path)
    _ = acceptance.accept(request())
    conflict = acceptance.accept(request(RequestSpec(payload=alternate_batch())))
    assert opened_receipt(conflict.ack_bytes).error_code == "duplicate_conflict"
    assert counts(db_path) == (1, 1, 1)


def test_concurrent_processes_serialize_same_id_different_digests(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "race.sqlite"
    _ = service(db_path)
    context = multiprocessing.get_context("spawn")
    barrier = context.Barrier(2)
    sink = context.Queue()
    workers = [
        context.Process(target=race_worker, args=(str(db_path), payload, barrier, sink))
        for payload in (BATCH, alternate_batch())
    ]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join(timeout=30)
        assert worker.exitcode == 0
    assert sorted((sink.get(timeout=5), sink.get(timeout=5))) == [
        "committed",
        "duplicate_conflict",
    ]
    assert counts(db_path) == (1, 1, 1)


@pytest.mark.parametrize(
    "point_name",
    [
        "before_claim",
        "after_claim",
        "during_ingest",
        "before_commit",
        "after_commit",
        "before_ack_publication",
    ],
)
def test_crash_boundaries_restart_without_partial_or_duplicate_commit(
    tmp_path: Path, point_name: str
) -> None:
    db_path = tmp_path / f"{point_name}.sqlite"
    acceptance = service(db_path)
    point = DeliveryAcceptanceFaultPoint(point_name)
    with pytest.raises(RuntimeError, match=point_name):
        _ = acceptance.accept(request(), fault_at(point))
    committed_before_retry = point_name in {"after_commit", "before_ack_publication"}
    assert counts(db_path) == ((1, 1, 1) if committed_before_retry else (0, 0, 0))
    restarted = service(db_path).accept(request())
    assert opened_receipt(restarted.ack_bytes).result == "committed"
    assert counts(db_path) == (1, 1, 1)


def test_ack_construction_does_not_run_before_transaction_commit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls = 0
    original = acceptance_crypto.build_delivery_ack

    def counted(receipt: DeliveryReceiptV1, params: AckSealParams) -> DeliveryAckV1:
        nonlocal calls
        calls += 1
        return original(receipt, params)

    monkeypatch.setattr(acceptance_crypto, "build_delivery_ack", counted)
    with pytest.raises(RuntimeError, match="before_commit"):
        _ = service(tmp_path / "no-early-ack.sqlite").accept(
            request(),
            fault_at(DeliveryAcceptanceFaultPoint.BEFORE_COMMIT),
        )
    assert calls == 0

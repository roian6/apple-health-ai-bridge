import hashlib
import json
import sqlite3
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from threading import Thread
from typing import TYPE_CHECKING, cast
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest
from pydantic import TypeAdapter

if TYPE_CHECKING:
    from http.client import HTTPResponse

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.ingest import ingest_batch, ingest_fixture
from health_bridge.receiver import invitations
from health_bridge.receiver.invitations import (
    create_pairing_invitation,
    redeem_pairing_invitation,
)
from health_bridge.receiver.server import build_receiver_server, server_port
from health_bridge.receiver.tokens import create_receiver_token

INSTALLATION_A = "00000000-0000-4000-8000-000000000001"
INSTALLATION_B = "00000000-0000-4000-8000-000000000002"
TOKEN_A = "hb_" + "a" * 64
TOKEN_B = "hb_" + "b" * 64
ERROR_BODY_ADAPTER = TypeAdapter(dict[str, str])
COUNT_ROW_ADAPTER = TypeAdapter(tuple[int])


@pytest.mark.parametrize(
    "kind",
    [
        "samples",
        "workouts",
        "sleep_sessions",
        "empty",
        "cursor",
        "deletion",
        "tombstoned",
        "fixture",
        "fixture_connection_source",
        "fixture_then_empty",
        "fixture_then_other_device",
        "fixture_then_authenticated",
        "other_device",
        "failed",
    ],
)
def test_setup_progress_requires_connection_observations(
    tmp_path: Path, kind: str
) -> None:
    db = tmp_path / "receiver.sqlite"
    pair(db, installation_id=INSTALLATION_A, token=TOKEN_A, suffix="a")
    pair(db, installation_id=INSTALLATION_B, token=TOKEN_B, suffix="b")
    fixture = HealthBridgeBatchV1.model_validate_json(
        Path("fixtures/health_bridge_batch_v1.synthetic.json").read_bytes()
    )
    batch = with_source_key(fixture, "apple_health.phone")
    if kind == "tombstoned":
        batch = batch.model_copy(
            update={
                "samples": batch.samples[:1],
                "workouts": (),
                "sleep_sessions": (),
                "deleted_records": (
                    batch.deleted_records[0].model_copy(
                        update={
                            "client_record_id": batch.samples[0].client_record_id,
                        }
                    ),
                ),
            }
        )
    if kind in {"samples", "workouts", "sleep_sessions", "empty", "cursor", "deletion"}:
        batch = batch.model_copy(
            update={
                "samples": batch.samples if kind == "samples" else (),
                "workouts": batch.workouts if kind == "workouts" else (),
                "sleep_sessions": batch.sleep_sessions
                if kind == "sleep_sessions"
                else (),
                "deleted_records": batch.deleted_records if kind == "deletion" else (),
                "sync": batch.sync.model_copy(
                    update={"cursors": batch.sync.cursors if kind == "cursor" else ()}
                ),
            }
        )
    if kind in {
        "fixture_connection_source",
        "fixture_then_empty",
        "fixture_then_other_device",
        "fixture_then_authenticated",
    }:
        input_path = tmp_path / "synthetic-connection-fixture.json"
        _ = input_path.write_text(
            with_source_key(
                fixture, canonical_source_key(INSTALLATION_A)
            ).model_dump_json()
        )
        _ = ingest_fixture(db, input_path)
        if kind != "fixture_connection_source":
            if kind == "fixture_then_empty":
                batch = batch.model_copy(
                    update={
                        "samples": (),
                        "workouts": (),
                        "sleep_sessions": (),
                        "deleted_records": (),
                    }
                )
            with running_receiver(db) as url:
                token = TOKEN_B if kind == "fixture_then_other_device" else TOKEN_A
                assert post_batch(url, token, batch) == 202
    elif kind == "fixture":
        _ = ingest_batch(db, fixture, "synthetic.json")
    else:
        with running_receiver(db) as url:
            if kind == "failed":
                with pytest.raises(HTTPError) as error:
                    _ = post_batch(url, TOKEN_A, fixture)
                assert error.value.code == 403
                error.value.close()
            else:
                assert (
                    post_batch(
                        url, TOKEN_B if kind == "other_device" else TOKEN_A, batch
                    )
                    == 202
                )

    progress = invitations.pairing_setup_progress(db, "hbi_a_synthetic_secret")

    assert progress is not None
    assert progress.pairing_status == "paired"
    assert progress.data_receipt_status == (
        "received"
        if kind
        in {"samples", "workouts", "sleep_sessions", "fixture_then_authenticated"}
        else "not_received"
    )


def canonical_source_key(installation_id: str) -> str:
    digest = hashlib.sha256(
        f"health-bridge-pairing:installation:{installation_id}".encode()
    ).hexdigest()
    return f"apple_health.phone.{digest}"


@contextmanager
def running_receiver(db_path: Path) -> Generator[str, None, None]:
    server = build_receiver_server(db_path, host="127.0.0.1", port=0)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server_port(server)}/v1/batches"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def pair(db_path: Path, *, installation_id: str, token: str, suffix: str) -> None:
    invitation = create_pairing_invitation(
        db_path,
        label=f"iphone-{suffix}",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret=f"hbi_{suffix}_synthetic_secret",
        invitation_code=("ABCDE-FGHJK-MNPQR" if suffix == "a" else "RSTUV-WXYZ2-34567"),
    )
    _ = redeem_pairing_invitation(
        db_path,
        installation_id=installation_id,
        device_credential=token,
        platform="ios",
        invitation_secret=invitation.invitation_secret,
    )


def with_source_key(batch: HealthBridgeBatchV1, source_key: str) -> HealthBridgeBatchV1:
    return batch.model_copy(
        update={
            "sources": tuple(
                source.model_copy(update={"source_key": source_key})
                for source in batch.sources
            ),
            "samples": tuple(
                sample.model_copy(update={"source_key": source_key})
                for sample in batch.samples
            ),
            "workouts": tuple(
                workout.model_copy(update={"source_key": source_key})
                for workout in batch.workouts
            ),
            "sleep_sessions": tuple(
                session.model_copy(update={"source_key": source_key})
                for session in batch.sleep_sessions
            ),
            "deleted_records": tuple(
                deleted.model_copy(update={"source_key": source_key})
                for deleted in batch.deleted_records
            ),
            "sync": batch.sync.model_copy(
                update={
                    "cursors": tuple(
                        cursor.model_copy(update={"source_key": source_key})
                        for cursor in batch.sync.cursors
                    )
                }
            ),
        }
    )


def post_batch(url: str, token: str, batch: HealthBridgeBatchV1) -> int:
    request = Request(
        url,
        data=batch.model_dump_json().encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with cast("HTTPResponse", urlopen(request, timeout=5)) as response:
        _ = response.read()
        return int(response.status)


def test_v2_tokens_bind_all_claimed_sources_to_the_paired_installation(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    pair(db_path, installation_id=INSTALLATION_A, token=TOKEN_A, suffix="a")
    pair(db_path, installation_id=INSTALLATION_B, token=TOKEN_B, suffix="b")
    fixture = HealthBridgeBatchV1.model_validate_json(
        Path("fixtures/health_bridge_batch_v1.synthetic.json").read_bytes()
    )
    shared_claim = with_source_key(fixture, "apple_health.phone")

    with running_receiver(db_path) as url:
        assert post_batch(url, TOKEN_A, shared_claim) == 202
        assert post_batch(url, TOKEN_B, shared_claim) == 202

        mismatched_claim = with_source_key(
            fixture,
            f"apple_health.phone.{INSTALLATION_A}",
        )
        try:
            _ = post_batch(url, TOKEN_B, mismatched_claim)
        except HTTPError as error:
            mismatch_status = error.code
            mismatch_body = ERROR_BODY_ADAPTER.validate_python(json.loads(error.read()))
            error.close()
        else:
            message = "cross-installation source claim unexpectedly succeeded"
            raise AssertionError(message)

        target_id = fixture.samples[0].client_record_id
        b_delete = with_source_key(
            fixture.model_copy(
                update={
                    "samples": (),
                    "workouts": (),
                    "sleep_sessions": (),
                    "deleted_records": (
                        fixture.deleted_records[0].model_copy(
                            update={"client_record_id": target_id}
                        ),
                    ),
                    "sync": fixture.sync.model_copy(update={"cursors": ()}),
                }
            ),
            "apple_health.phone",
        )
        assert post_batch(url, TOKEN_B, b_delete) == 202

    with sqlite3.connect(db_path) as connection:
        source_keys = connection.execute(
            "select source_key from sources order by source_key"
        ).fetchall()
        samples_by_source = connection.execute(
            """
            select sources.source_key, count(*)
            from samples join sources using (source_id)
            group by sources.source_key order by sources.source_key
            """
        ).fetchall()
        a_target_count = COUNT_ROW_ADAPTER.validate_python(
            connection.execute(
                """
                select count(*)
                from samples join sources using (source_id)
                where samples.client_record_id = ?
                  and sources.source_key = ?
                """,
                (target_id, canonical_source_key(INSTALLATION_A)),
            ).fetchone()
        )

    assert mismatch_status == 403
    assert mismatch_body == {"error": "source_principal_mismatch"}
    assert source_keys == sorted(
        [
            (canonical_source_key(INSTALLATION_A),),
            (canonical_source_key(INSTALLATION_B),),
        ]
    )
    assert len(samples_by_source) == 2
    assert a_target_count == (1,)


def test_unmapped_legacy_token_cannot_claim_private_phone_namespace(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    token = "hb_" + "c" * 64
    _ = create_receiver_token(db_path, label="legacy", token=token)
    fixture = HealthBridgeBatchV1.model_validate_json(
        Path("fixtures/health_bridge_batch_v1.synthetic.json").read_bytes()
    )
    phone_claim = with_source_key(fixture, "apple_health.phone")

    with running_receiver(db_path) as url:
        try:
            _ = post_batch(url, token, phone_claim)
        except HTTPError as error:
            status = error.code
            body = ERROR_BODY_ADAPTER.validate_python(json.loads(error.read()))
            error.close()
        else:
            message = "legacy token unexpectedly claimed private phone namespace"
            raise AssertionError(message)

    assert status == 403
    assert body == {"error": "source_principal_mismatch"}

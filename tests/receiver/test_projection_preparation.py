from pathlib import Path

from health_bridge.receiver.batch_acceptance import (
    BatchAcceptanceCore,
    BatchAcceptanceInput,
    PreparedBatch,
)
from health_bridge.receiver.tokens import ReceiverTokenPrincipal
from tests.ingest import test_daily_projection_corrections as root
from tests.receiver.delivery_acceptance_support import (
    RequestSpec,
    counts,
    opened_receipt,
    request,
    service,
)


def test_authenticated_envelope_refuses_reserved_invalid_json_then_accepts_control(
    tmp_path: Path,
) -> None:
    db = tmp_path / "envelope.sqlite"
    acceptance = service(db)
    valid = root.root_batch((root.daily_sample(),), sequence=1, statistics=True)
    cursor = valid.sync.cursors[0]
    malformed = valid.model_copy(
        update={
            "sync": valid.sync.model_copy(
                update={"cursors": (cursor.model_copy(update={"cursor_value": "{"}),)}
            )
        }
    )
    refused = acceptance.accept(
        request(RequestSpec(payload=malformed.model_dump_json().encode()))
    )
    assert opened_receipt(refused.ack_bytes).error_code == "payload_invalid"
    assert counts(db) == (0, 0, 0)
    accepted = acceptance.accept(
        request(RequestSpec(payload=valid.model_dump_json().encode(), envelope_byte=2))
    )
    assert opened_receipt(accepted.ack_bytes, envelope_byte=2).result == "committed"
    assert root.current_total(db) == 6.0


def test_unreserved_opaque_cursor_is_preserved_at_common_preparation() -> None:
    batch = root.root_batch((root.raw_sample(),), sequence=1)
    cursor = batch.sync.cursors[0].model_copy(
        update={"cursor_kind": "synthetic_opaque_cursor", "cursor_value": "{not-json"}
    )
    batch = batch.model_copy(
        update={"sync": batch.sync.model_copy(update={"cursors": (cursor,)})}
    )
    exact = batch.model_dump_json().encode()
    prepared = BatchAcceptanceCore.prepare(
        BatchAcceptanceInput(
            exact_bytes=exact,
            principal=ReceiverTokenPrincipal(installation_id_hash=None),
        )
    )
    assert isinstance(prepared, PreparedBatch)
    assert prepared.exact_bytes == exact
    assert prepared.batch.sync.cursors == (cursor,)

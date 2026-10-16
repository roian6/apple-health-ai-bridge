from __future__ import annotations

from dataclasses import replace
from typing import TYPE_CHECKING

import pytest

from health_bridge.receiver import batch_acceptance
from health_bridge.receiver.delivery_acceptance import (
    DeliveryAcceptanceFaultPoint,
    DeliveryAcceptanceService,
)
from health_bridge.receiver.source_binding import SourcePrincipalMismatchError
from health_bridge.receiver.tokens import ReceiverTokenPrincipal, create_receiver_token
from health_bridge.storage.database import (
    connect_readonly_database,
    initialize_database,
)
from tests.contract.delivery_v1_support import BATCH
from tests.receiver.delivery_acceptance_support import (
    NOW_MS,
    RequestSpec,
    connection,
    enroll_connection,
    fault_at,
    opened_receipt,
    request,
    service,
    with_phone_source,
)
from tests.receiver.test_legacy_http_contract import (
    FIXTURE_PATH,
    LEGACY_TOKEN,
    post_raw_batch,
    running_receiver,
)

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.contract import HealthBridgeBatchV1


@pytest.mark.parametrize("rollback", [False, True])
def test_mailbox_commits_installation_association_atomically(
    tmp_path: Path, rollback: bool
) -> None:
    db = tmp_path / "receiver.sqlite"
    initialize_database(db)
    principal = ReceiverTokenPrincipal(installation_id_hash="a" * 64)
    trusted = replace(connection(), source_principal=principal)
    enroll_connection(db, trusted)
    acceptance = DeliveryAcceptanceService(db, trusted, lambda: NOW_MS)
    upload = request(RequestSpec(payload=with_phone_source(BATCH)))

    if rollback:
        with pytest.raises(RuntimeError, match="before_commit"):
            _ = acceptance.accept(
                upload, fault_at(DeliveryAcceptanceFaultPoint.BEFORE_COMMIT)
            )
    else:
        assert opened_receipt(acceptance.accept(upload).ack_bytes).result == "committed"

    with connect_readonly_database(db) as database:
        assert database.execute(
            "select receiver_installation_id_hash from sync_runs"
        ).fetchall() == ([] if rollback else [("a" * 64,)])
        assert database.execute("select count(*) from samples").fetchone() == (
            0 if rollback else 1,
        )


def test_direct_and_envelope_flows_share_the_batch_binding_boundary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    direct_db = tmp_path / "direct.sqlite"
    envelope_db = tmp_path / "envelope.sqlite"
    _ = create_receiver_token(
        direct_db,
        label="shared-core-red",
        token=LEGACY_TOKEN,
    )
    envelope_acceptance = service(envelope_db)

    def reject_at_shared_boundary(
        batch: HealthBridgeBatchV1,
        _principal: ReceiverTokenPrincipal,
    ) -> HealthBridgeBatchV1:
        raise SourcePrincipalMismatchError(batch.sources[0].source_key)

    monkeypatch.setattr(
        batch_acceptance,
        "bind_batch_to_principal",
        reject_at_shared_boundary,
    )

    # When
    with running_receiver(direct_db) as port:
        direct = post_raw_batch(port, LEGACY_TOKEN, FIXTURE_PATH.read_bytes())
    envelope = envelope_acceptance.accept(request(RequestSpec(payload=BATCH)))

    # Then
    assert direct.status == 403
    assert opened_receipt(envelope.ack_bytes).error_code == "principal_mismatch"

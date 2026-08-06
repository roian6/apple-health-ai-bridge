from __future__ import annotations

from typing import TYPE_CHECKING

from health_bridge.receiver import batch_acceptance
from health_bridge.receiver.source_binding import SourcePrincipalMismatchError
from health_bridge.receiver.tokens import create_receiver_token
from tests.contract.delivery_v1_support import BATCH
from tests.receiver.delivery_acceptance_support import (
    RequestSpec,
    opened_receipt,
    request,
    service,
)
from tests.receiver.test_legacy_http_contract import (
    FIXTURE_PATH,
    LEGACY_TOKEN,
    post_raw_batch,
    running_receiver,
)

if TYPE_CHECKING:
    from pathlib import Path

    import pytest

    from health_bridge.contract import HealthBridgeBatchV1
    from health_bridge.receiver.tokens import ReceiverTokenPrincipal


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

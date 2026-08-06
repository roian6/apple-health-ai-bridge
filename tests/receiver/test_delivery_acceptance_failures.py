from __future__ import annotations

from typing import TYPE_CHECKING, Never

from health_bridge.receiver import delivery_acceptance as acceptance_module
from tests.receiver.delivery_acceptance_support import (
    counts,
    opened_receipt,
    request,
    service,
)

if TYPE_CHECKING:
    from pathlib import Path

    import pytest


def test_authenticated_storage_failure_returns_closed_retryable_ack(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "unavailable.sqlite"
    acceptance = service(db_path)

    def unavailable(_db_path: Path) -> Never:
        raise OSError

    monkeypatch.setattr(acceptance_module, "connect_database", unavailable)
    # When
    result = acceptance.accept(request())
    # Then
    receipt = opened_receipt(result.ack_bytes)
    assert (receipt.result, receipt.error_code) == (
        "retryable",
        "storage_unavailable",
    )
    assert counts(db_path) == (0, 0, 0)

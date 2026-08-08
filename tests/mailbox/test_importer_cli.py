from __future__ import annotations

import json
from typing import TYPE_CHECKING

from tests.mailbox.importer_support import (
    BATCH,
    IMPORTED_COUNTS,
    configured_importer,
    environment,
    invoke_import_cli,
    write_delivery,
)

if TYPE_CHECKING:
    from pathlib import Path

    import pytest


def test_cli_json_is_aggregate_only(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    value = environment(tmp_path)
    _ = write_delivery(value)
    result = invoke_import_cli(value, configured_importer(value), monkeypatch)

    assert result.exit_code == 0
    assert json.loads(result.stdout) == IMPORTED_COUNTS
    assert str(value.mailbox_path) not in result.stdout
    assert BATCH.decode() not in result.stdout

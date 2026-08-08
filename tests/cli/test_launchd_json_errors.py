from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Never

from typer.testing import CliRunner

import health_bridge.launchd.artifacts as launchd_artifacts_module
from health_bridge.cli import app
from health_bridge.launchd.models import service_paths
from tests.launchd.support import service_request

if TYPE_CHECKING:
    from pathlib import Path as TypedPath

    import pytest


def test_status_json_normalizes_permission_error_from_initial_probe(
    tmp_path: TypedPath,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given a macOS status probe whose initial config existence check is denied.
    request = service_request(tmp_path)
    config = service_paths(request.home).config
    original_exists = Path.exists

    def deny_config_probe(path: Path) -> bool:
        if path == config:
            message = "synthetic private path denied"
            raise PermissionError(message)
        return original_exists(path)

    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(Path, "exists", deny_config_probe)

    # When status is requested as JSON.
    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "status", "--json"],
        env={"HOME": str(request.home)},
    )

    # Then exactly one fixed privacy-safe object is emitted.
    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": "unsafe_filesystem"}
    assert result.stdout.count("\n") == 1
    assert result.stderr == ""
    assert str(request.home) not in result.output


def test_uninstall_json_normalizes_permission_error_from_initial_probe(
    tmp_path: TypedPath,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given a macOS uninstall whose first filesystem probe is denied.
    request = service_request(tmp_path)

    def deny_probe(_path: Path) -> Never:
        message = "synthetic private path denied"
        raise PermissionError(message)

    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(launchd_artifacts_module, "path_entry_exists", deny_probe)

    # When uninstall is requested as JSON.
    result = CliRunner().invoke(
        app,
        ["mailbox", "service", "uninstall", "--json"],
        env={"HOME": str(request.home)},
    )

    # Then exactly one fixed privacy-safe object is emitted.
    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": "unsafe_filesystem"}
    assert result.stdout.count("\n") == 1
    assert result.stderr == ""
    assert str(request.home) not in result.output

from __future__ import annotations

import json
import plistlib
import stat
from dataclasses import replace
from typing import TYPE_CHECKING, cast

from health_bridge.cli_launchd import LAUNCHCTL_TIMEOUT_SECONDS
from health_bridge.launchd import (
    render_launch_agent_plist,
    write_launch_agent_artifacts,
)
from health_bridge.launchd.artifacts import load_runnable_launch_agent_request
from tests.launchd.support import service_request

if TYPE_CHECKING:
    from pathlib import Path

    import pytest


def test_direct_config_round_trips_scoped_owned_artifacts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    request = service_request(tmp_path)
    page = request.db_path.parent / "pairing.html"
    page.touch(mode=0o600)
    request = replace(
        request,
        mailbox_root=None,
        icloud_container_identifier=None,
        label="health-bridge-qa",
        setup_page=page,
    )
    monkeypatch.setenv("HOME", str(request.home))

    _ = write_launch_agent_artifacts(request, activate=False)

    assert load_runnable_launch_agent_request(request.paths.config) == request
    assert request.paths.manifest.name == "health-bridge-qa.plist"
    assert request.paths.state_dir.name == "health-bridge-qa"
    assert str(page).encode() not in request.paths.manifest.read_bytes()


def test_rendered_launch_agent_uses_private_config_and_shell_free_argv(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)

    rendered = render_launch_agent_plist(request)
    document = cast("dict[str, object]", plistlib.loads(rendered))

    assert document["Label"] == "dev.healthbridge.companion"
    assert document["ProgramArguments"] == [
        str(request.executable),
        "receiver",
        "start",
        "--service-config",
        str(request.paths.config),
    ]
    assert document["WorkingDirectory"] == str(request.paths.state_dir)
    assert document["RunAtLoad"] is True
    assert document["KeepAlive"] == {"SuccessfulExit": False}
    assert document["ThrottleInterval"] == 30
    assert document["ExitTimeOut"] == 10
    assert document["Umask"] == 0o077


def test_launchctl_timeout_exceeds_child_exit_timeout(tmp_path: Path) -> None:
    request = service_request(tmp_path)
    document = cast(
        "dict[str, object]",
        plistlib.loads(render_launch_agent_plist(request)),
    )

    restart_delay = cast("int", document["ThrottleInterval"]) + cast(
        "int", document["ExitTimeOut"]
    )
    assert restart_delay < LAUNCHCTL_TIMEOUT_SECONDS


def test_rendered_launch_agent_contains_no_private_receiver_configuration(
    tmp_path: Path,
) -> None:
    request = service_request(tmp_path)

    rendered = render_launch_agent_plist(request)

    assert str(request.db_path).encode() not in rendered
    assert str(request.mailbox_root).encode() not in rendered
    assert request.icloud_container_identifier is not None
    assert request.icloud_container_identifier.encode() not in rendered
    assert b"token" not in rendered.lower()
    assert b"receiver_id" not in rendered.lower()
    assert b"device_id" not in rendered.lower()


def test_service_artifacts_render_as_parseable_owner_only_files(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = service_request(tmp_path)
    monkeypatch.setenv("HOME", str(request.home))
    _ = write_launch_agent_artifacts(request, activate=False)
    legacy_config = json.dumps(
        {
            "schema_id": "health_bridge.launchd.receiver",
            "schema_version": 1,
            "executable": str(request.executable),
            "db_path": str(request.db_path),
            "mailbox_root": str(request.mailbox_root),
            "icloud_container_identifier": request.icloud_container_identifier,
            "host": request.host,
            "port": request.port,
        },
        separators=(",", ":"),
    ).encode()
    assert request.paths.config.read_bytes() == legacy_config
    original = request.paths.ownership.read_bytes()
    loaded = load_runnable_launch_agent_request(request.paths.config)
    _ = write_launch_agent_artifacts(loaded, activate=False)
    assert request.paths.ownership.read_bytes() == original

    _ = cast(
        "dict[str, object]",
        plistlib.loads(request.paths.manifest.read_bytes()),
    )
    for path in (
        request.paths.manifest,
        request.paths.config,
        request.paths.ownership,
        request.paths.stdout_log,
        request.paths.stderr_log,
    ):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600

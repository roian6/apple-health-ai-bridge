from __future__ import annotations

import os
from typing import TYPE_CHECKING

from health_bridge.launchd import LaunchdServiceRequest

if TYPE_CHECKING:
    from pathlib import Path

CONTAINER_IDENTIFIER = "iCloud.dev.example.HealthBridgeCompanion"


def service_request(tmp_path: Path) -> LaunchdServiceRequest:
    home = tmp_path / "synthetic-home"
    home.mkdir(mode=0o700)
    executable = home / "bin/health-bridge"
    database = home / "private/health.sqlite"
    mailbox_root = (
        home
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion"
        / "Documents/HealthBridgeMailbox/v1"
    )
    executable.parent.mkdir(parents=True)
    _ = executable.write_text("synthetic executable", encoding="utf-8")
    executable.chmod(0o700)
    database.parent.mkdir(parents=True)
    database.touch(mode=0o600)
    mailbox_root.mkdir(parents=True)
    mailbox_root.chmod(0o700)
    for path in home.rglob("*"):
        if path.is_dir():
            path.chmod(0o700)
    return LaunchdServiceRequest(
        executable=executable,
        db_path=database,
        mailbox_root=mailbox_root,
        icloud_container_identifier=CONTAINER_IDENTIFIER,
        home=home,
        uid=os.geteuid(),
    )

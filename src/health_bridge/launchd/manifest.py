from __future__ import annotations

import hashlib
import plistlib
from typing import Final

from health_bridge.launchd.models import (
    LAUNCH_AGENT_LABEL,
    LaunchdOwnershipRecord,
    LaunchdServiceConfig,
    LaunchdServiceRequest,
)

RESTART_THROTTLE_SECONDS: Final = 30
EXIT_TIMEOUT_SECONDS: Final = 10


def service_config(request: LaunchdServiceRequest) -> LaunchdServiceConfig:
    return LaunchdServiceConfig(
        schema_id="health_bridge.launchd.receiver",
        schema_version=1,
        executable=request.executable,
        db_path=request.db_path,
        mailbox_root=request.mailbox_root,
        icloud_container_identifier=request.icloud_container_identifier,
        host=request.host,
        port=request.port,
        label=request.label,
        setup_page=request.setup_page,
    )


def render_service_config(request: LaunchdServiceRequest) -> bytes:
    excluded = set[str]()
    if request.label == LAUNCH_AGENT_LABEL:
        excluded.add("label")
    if request.setup_page is None:
        excluded.add("setup_page")
    return service_config(request).model_dump_json(exclude=excluded).encode()


def render_launch_agent_plist(request: LaunchdServiceRequest) -> bytes:
    document = {
        "Label": request.label,
        "ProgramArguments": [
            str(request.executable),
            "receiver",
            "start",
            "--service-config",
            str(request.paths.config),
        ],
        "WorkingDirectory": str(request.paths.state_dir),
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": RESTART_THROTTLE_SECONDS,
        "ExitTimeOut": EXIT_TIMEOUT_SECONDS,
        "Umask": 0o077,
        "ProcessType": "Background",
        "StandardOutPath": str(request.paths.stdout_log),
        "StandardErrorPath": str(request.paths.stderr_log),
    }
    return plistlib.dumps(document, fmt=plistlib.FMT_XML, sort_keys=True)


def render_ownership_record(
    manifest: bytes,
    config: bytes,
) -> bytes:
    record = LaunchdOwnershipRecord(
        schema_id="health_bridge.launchd.ownership",
        schema_version=1,
        manifest_sha256=hashlib.sha256(manifest).hexdigest(),
        config_sha256=hashlib.sha256(config).hexdigest(),
    )
    return record.model_dump_json().encode()

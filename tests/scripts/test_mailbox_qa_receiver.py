from __future__ import annotations

import os
import subprocess
import sys
from ipaddress import IPv4Address
from typing import TYPE_CHECKING

import pytest
from pydantic import ValidationError

from health_bridge.mailbox_qa.lifecycle import (
    QAReceiverState,
    prepare_receiver,
    process_command_for_pid,
    write_receiver_state,
)
from health_bridge.mailbox_qa.production_seal import (
    load_production_identity_seal,
    production_seal_fingerprint,
)
from health_bridge.mailbox_qa.receiver import QAReceiverConfig
from tests.scripts.production_seal_support import (
    synthetic_qa_request,
    write_synthetic_production_seal,
)

if TYPE_CHECKING:
    from pathlib import Path


def test_process_identity_lookup_is_platform_portable() -> None:
    assert process_command_for_pid(os.getpid())
    with pytest.raises(RuntimeError):
        _ = process_command_for_pid(2_147_483_647)


def _config(runtime: Path) -> QAReceiverConfig:
    seal_path = runtime.parent / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(seal_path)
    seal = load_production_identity_seal(seal_path, anchor)
    qa = synthetic_qa_request(runtime)
    return QAReceiverConfig(
        runtime_root=runtime,
        host="127.0.0.1",
        port=qa.receiver_port,
        namespace="qa-run-001",
        bundle_identifier=qa.bundle_identifier,
        container_identifier=qa.container_identifier,
        url_scheme=qa.url_scheme,
        keychain_service=qa.keychain_service,
        keychain_access_groups=qa.keychain_access_groups,
        outbox_root=qa.outbox_root,
        display_identity=qa.display_identity,
        database_namespace=qa.database_namespace,
        app_path=qa.app_path,
        production_seal=seal,
        production_seal_fingerprint=production_seal_fingerprint(seal),
    )


def test_receiver_config_accepts_only_isolated_qa_values(tmp_path: Path) -> None:
    # Given: a private caller-owned runtime root outside the repository.
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)

    # When: an isolated QA receiver configuration is parsed.
    config = _config(runtime)

    # Then: its state stays under the caller root and distinct from production.
    assert config.database_path == runtime / "receiver.sqlite"
    assert config.token_path == runtime / "private/token"
    assert config.mailbox_root == runtime / "mailbox-qa"


def test_receiver_config_accepts_tailnet_cgnat_host(tmp_path: Path) -> None:
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    values = _config(runtime).model_dump()
    tailnet_host = str(IPv4Address(0x64400001))
    values["host"] = tailnet_host

    assert QAReceiverConfig.model_validate(values).host == tailnet_host


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("port", 28765),
        ("host", "8.8.8.8"),
        ("namespace", "production"),
        ("bundle_identifier", "dev.example.healthbridge"),
        ("container_identifier", "iCloud.dev.example.healthbridge"),
        ("url_scheme", "healthbridge"),
    ],
)
def test_receiver_config_rejects_production_like_values(
    tmp_path: Path,
    field: str,
    value: str | int,
) -> None:
    # Given: one production-like receiver identity value.
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    values = _config(runtime).model_dump()
    values[field] = value

    # When / Then: configuration parsing fails before any process or file mutation.
    with pytest.raises(ValidationError):
        _ = QAReceiverConfig.model_validate(values)


def test_prepare_receiver_keeps_runtime_token_private(tmp_path: Path) -> None:
    # Given: a validated caller-private QA receiver root.
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    config = _config(runtime)

    # When: the ephemeral receiver state is prepared.
    state = prepare_receiver(config)

    # Then: token, DB, and state exist only below the QA root with private mode.
    assert state.status == "prepared"
    assert config.database_path.is_file()
    assert config.token_path.is_file()
    assert config.token_path.stat().st_mode & 0o777 == 0o600
    assert config.state_path.stat().st_mode & 0o777 == 0o600


def test_prepare_receiver_restarts_without_rotating_durable_identity(
    tmp_path: Path,
) -> None:
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    config = _config(runtime)
    prepared = prepare_receiver(config)
    token = config.token_path.read_bytes()
    database = config.database_path.read_bytes()
    receipt_key = config.receipt_key_path.read_bytes()
    write_receiver_state(
        config,
        prepared.model_copy(update={"status": "stopped", "pid": None}),
    )

    restarted = prepare_receiver(config)

    assert restarted == QAReceiverState(
        v=1,
        kind="health_bridge.mailbox_qa_receiver_state.v1",
        status="prepared",
        namespace=config.namespace,
        port=config.port,
        pid=None,
    )
    assert config.token_path.read_bytes() == token
    assert config.database_path.read_bytes() == database
    assert config.receipt_key_path.read_bytes() == receipt_key


def test_receiver_dry_run_validates_without_creating_runtime_state(
    tmp_path: Path,
) -> None:
    # Given: a private empty runtime root and explicit QA-only identities.
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    seal_path = tmp_path / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(seal_path)
    qa = synthetic_qa_request(runtime)

    # When: lifecycle preparation is invoked in dry-run mode.
    result = subprocess.run(
        [
            sys.executable,
            "scripts/mailbox-qa-receiver.py",
            "prepare",
            "--runtime-root",
            str(runtime),
            "--host",
            "127.0.0.1",
            "--port",
            str(qa.receiver_port),
            "--namespace",
            "qa-run-001",
            "--bundle-identifier",
            qa.bundle_identifier,
            "--container-identifier",
            qa.container_identifier,
            "--url-scheme",
            "healthbridgeqa",
            "--keychain-service",
            qa.keychain_service,
            "--keychain-access-group",
            qa.keychain_access_groups[0],
            "--outbox-root",
            qa.outbox_root,
            "--display-identity",
            qa.display_identity,
            "--database-namespace",
            qa.database_namespace,
            "--app-path",
            str(qa.app_path),
            "--production-seal",
            str(seal_path),
            "--production-seal-anchor-sha256",
            anchor,
            "--dry-run",
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    # Then: only a redacted validation receipt is emitted and no state exists.
    assert result.returncode == 0
    assert result.stdout == (
        '{"action":"prepare","kind":"health_bridge.mailbox_qa_lifecycle_receipt.v1",'
        '"status":"validated","v":1}\n'
    )
    assert list(runtime.iterdir()) == []


def test_receiver_cli_redacts_rejected_identity_values(tmp_path: Path) -> None:
    # Given: an otherwise valid dry-run configured with a public receiver host.
    runtime = tmp_path / "qa-runtime"
    runtime.mkdir(mode=0o700)
    seal_path = tmp_path / "production-seal.hbjcs1"
    anchor, _ = write_synthetic_production_seal(seal_path)
    qa = synthetic_qa_request(runtime)

    # When: the lifecycle boundary rejects the non-private host.
    result = subprocess.run(
        [
            sys.executable,
            "scripts/mailbox-qa-receiver.py",
            "prepare",
            "--runtime-root",
            str(runtime),
            "--host",
            "8.8.8.8",
            "--port",
            str(qa.receiver_port),
            "--namespace",
            "qa-run-001",
            "--bundle-identifier",
            qa.bundle_identifier,
            "--container-identifier",
            qa.container_identifier,
            "--url-scheme",
            "healthbridgeqa",
            "--keychain-service",
            qa.keychain_service,
            "--keychain-access-group",
            qa.keychain_access_groups[0],
            "--outbox-root",
            qa.outbox_root,
            "--display-identity",
            qa.display_identity,
            "--database-namespace",
            qa.database_namespace,
            "--app-path",
            str(qa.app_path),
            "--production-seal",
            str(seal_path),
            "--production-seal-anchor-sha256",
            anchor,
            "--dry-run",
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    # Then: exit 1 contains only the redacted machine-readable rejection.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        (
            '{"action":"prepare","kind":'
            '"health_bridge.mailbox_qa_lifecycle_receipt.v1",'
            '"status":"rejected","v":1}\n'
        ),
        "",
    )

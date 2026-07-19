import re
import stat
from pathlib import Path
from subprocess import run
from typing import Final, Literal

import pytest
from pydantic import BaseModel, TypeAdapter

from health_bridge.cli_dev import AppReviewDemoRequest, build_app_review_demo_manifest
from health_bridge.receiver.pairing import (
    pairing_bundle_from_deep_link,
    pairing_invitation_from_deep_link,
)
from health_bridge.receiver.tokens import (
    authenticate_receiver_token,
    create_receiver_token,
)
from health_bridge.storage.database import connect_database


class DevDeviceSessionCliOutput(BaseModel):
    db: str
    label: str
    receiver_url: str
    receiver_health_url: str
    setup_page: str
    pairing_schema_id: str
    invitation_expires_at: str
    baseline_sync_run_id: int
    receiver_start_command: list[str]
    receiver_systemd_command: list[str]
    watch_new_sync_runs_command: list[str]
    validate_anchored_steps_command: list[str]
    next_steps: list[str]
    warning: str


class AppReviewDemoCliOutput(BaseModel):
    db: str
    fixture: str
    label: str
    receiver_url: str
    receiver_health_url: str
    setup_page: str
    pairing_schema_id: str
    invitation_expires_at: str | None
    demo_data_summary: dict[str, int]
    receiver_start_command: list[str]
    watch_new_sync_runs_command: list[str]
    revoke_reviewer_access_command: list[str]
    app_review_notes_template: str
    healthkit_read_types_disclosure: str
    next_steps: list[str]
    warning: str


class NewSyncRunCliOutput(BaseModel):
    event: Literal["new_sync_run"]
    sync_run_id: int
    status: str
    sample_count: int
    workout_count: int
    sleep_session_count: int
    deleted_record_count: int
    sync_cursor_count: int


class WatchTimeoutCliOutput(BaseModel):
    event: Literal["watch_timeout"]
    after_sync_run_id: int
    seen_sync_run_ids: list[int]
    elapsed_seconds: int


class DevReceiverSystemdCliOutput(BaseModel):
    service_name: str
    unit_path: str
    unit_text: str
    write_unit_command: list[str]
    enable_now_command: list[str]
    restart_command: list[str]
    stop_command: list[str]
    health_check_command: list[str]
    warning: str


PAIRING_URL_PATTERN: Final = r"healthbridge://pair\?payload=[A-Za-z0-9_-]+"
STDOUT_FORBIDDEN_SECRET_KEYS: Final = (
    "bearer_token",
    "pairing_url",
    "invitation_secret",
    "invitation_code",
)
OUTPUT_ADAPTER: Final[TypeAdapter[DevDeviceSessionCliOutput]] = TypeAdapter(
    DevDeviceSessionCliOutput,
)
APP_REVIEW_DEMO_ADAPTER: Final[TypeAdapter[AppReviewDemoCliOutput]] = TypeAdapter(
    AppReviewDemoCliOutput,
)
NEW_SYNC_RUN_ADAPTER: Final[TypeAdapter[NewSyncRunCliOutput]] = TypeAdapter(
    NewSyncRunCliOutput,
)
WATCH_TIMEOUT_ADAPTER: Final[TypeAdapter[WatchTimeoutCliOutput]] = TypeAdapter(
    WatchTimeoutCliOutput,
)
SYSTEMD_OUTPUT_ADAPTER: Final[TypeAdapter[DevReceiverSystemdCliOutput]] = TypeAdapter(
    DevReceiverSystemdCliOutput,
)
ACTIVE_TOKEN_PREFIXES_ADAPTER: Final[TypeAdapter[list[tuple[str]]]] = TypeAdapter(
    list[tuple[str]],
)
ACTIVE_TOKEN_PREFIXES_SQL: Final = "select token_prefix from receiver_tokens where revoked_at is null order by token_prefix"  # noqa: E501


def test_dev_receiver_systemd_cli_emits_redacted_user_service_manifest(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "stage-live.sqlite"
    workdir = tmp_path / "repo"
    workdir.mkdir()

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev",
            "receiver-systemd",
            "--db",
            str(db_path),
            "--host",
            "192.0.2.42",
            "--port",
            "8765",
            "--working-directory",
            str(workdir),
            "--service-name",
            "health-bridge-local",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = SYSTEMD_OUTPUT_ADAPTER.validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.service_name == "health-bridge-local"
    assert output.unit_path.endswith("/health-bridge-local.service")
    assert "[Unit]" in output.unit_text
    assert "[Service]" in output.unit_text
    assert "[Install]" in output.unit_text
    assert f"WorkingDirectory={workdir}" in output.unit_text
    assert (
        "ExecStart=uv run health-bridge receiver start "
        f"--db {db_path} --host 192.0.2.42 --port 8765"
    ) in output.unit_text
    assert "Restart=on-failure" in output.unit_text
    assert output.write_unit_command == [
        "sh",
        "-c",
        f"mkdir -p ~/.config/systemd/user && cat > {output.unit_path}",
    ]
    assert output.enable_now_command == [
        "systemctl",
        "--user",
        "enable",
        "--now",
        "health-bridge-local.service",
    ]
    assert output.restart_command == [
        "systemctl",
        "--user",
        "restart",
        "health-bridge-local.service",
    ]
    assert output.stop_command == [
        "systemctl",
        "--user",
        "stop",
        "health-bridge-local.service",
    ]
    assert output.health_check_command == [
        "curl",
        "-fsS",
        "http://192.0.2.42:8765/health",
    ]
    assert "does not install" in output.warning
    for forbidden_key in STDOUT_FORBIDDEN_SECRET_KEYS:
        assert forbidden_key not in result.stdout


def test_dev_receiver_systemd_cli_rejects_space_containing_paths(
    tmp_path: Path,
) -> None:
    # Given
    db_dir = tmp_path / "path with spaces"
    db_dir.mkdir()
    db_path = db_dir / "stage live.sqlite"
    workdir = tmp_path / "repo with spaces"
    workdir.mkdir()

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev",
            "receiver-systemd",
            "--db",
            str(db_path),
            "--working-directory",
            str(workdir),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert "paths with whitespace" in result.stderr.lower()


def test_dev_receiver_systemd_cli_rejects_unsafe_service_name(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "stage-live.sqlite"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev",
            "receiver-systemd",
            "--db",
            str(db_path),
            "--service-name",
            "../health-bridge",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert "invalid service name" in result.stderr.lower()


def test_dev_app_review_demo_cli_preloads_synthetic_data_and_redacts_pairing(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "reviewer-demo.sqlite"
    setup_page_path = tmp_path / "reviewer" / "setup.html"
    receiver_url = "https://reviewer-demo.tailnet.test:8766/v1/batches"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev-app-review-demo",
            "--db",
            str(db_path),
            "--fixture",
            "fixtures/health_bridge_batch_v1.synthetic.json",
            "--label",
            "app-review-demo",
            "--receiver-url",
            receiver_url,
            "--setup-page",
            str(setup_page_path),
            "--receiver-host",
            "192.0.2.42",
            "--receiver-port",
            "8766",
            "--watch-seconds",
            "1800",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = APP_REVIEW_DEMO_ADAPTER.validate_json(result.stdout)
    setup_html = setup_page_path.read_text(encoding="utf-8")
    pairing_match = re.search(PAIRING_URL_PATTERN, setup_html)
    assert pairing_match is not None
    decoded = pairing_bundle_from_deep_link(pairing_match.group(0))

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.db == str(db_path)
    assert output.fixture == "fixtures/health_bridge_batch_v1.synthetic.json"
    assert output.label == "app-review-demo"
    assert output.receiver_url == receiver_url
    assert (
        output.receiver_health_url == "https://reviewer-demo.tailnet.test:8766/health"
    )
    assert output.setup_page == str(setup_page_path)
    assert output.pairing_schema_id == "health_bridge.receiver_pairing.v1"
    assert output.invitation_expires_at is None
    assert output.demo_data_summary == {
        "sources": 2,
        "health_types": 4,
        "samples": 3,
        "workouts": 1,
        "sleep_sessions": 1,
        "deleted_records": 1,
        "sync_cursors": 2,
    }
    assert output.receiver_start_command == [
        "uv",
        "run",
        "health-bridge",
        "receiver",
        "start",
        "--db",
        str(db_path),
        "--host",
        "192.0.2.42",
        "--port",
        "8766",
    ]
    assert output.watch_new_sync_runs_command == [
        "uv",
        "run",
        "health-bridge",
        "dev",
        "watch-sync-runs",
        "--db",
        str(db_path),
        "--after-sync-run-id",
        "1",
        "--timeout-seconds",
        "1800",
    ]
    assert output.revoke_reviewer_access_command == [
        "uv",
        "run",
        "health-bridge",
        "receiver",
        "revoke-token",
        "--db",
        str(db_path),
        "--token-prefix",
        decoded.token_prefix,
    ]
    assert (
        output.app_review_notes_template
        == "docs/maintainers/app-review-notes-template.example.md"
    )
    assert output.healthkit_read_types_disclosure == "docs/supported-health-data.md"
    assert any("synthetic demo" in step.lower() for step in output.next_steps)
    assert "does not expire automatically" in output.warning.lower()
    assert "revoke" in output.warning.lower()
    assert stat.S_IMODE(setup_page_path.stat().st_mode) == 0o600
    assert decoded.receiver_url == receiver_url
    assert decoded.bearer_token not in setup_html
    for forbidden_key in STDOUT_FORBIDDEN_SECRET_KEYS:
        assert forbidden_key not in result.stdout


def test_dev_app_review_demo_cli_rotates_only_the_previous_reviewer_page(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "reviewer-demo.sqlite"
    setup_path = tmp_path / "reviewer" / "setup.html"
    ordinary = create_receiver_token(
        db_path,
        label="app-review-demo",
        token="hb_unrelated_companion_secret",
    )
    common_command = [
        "uv",
        "run",
        "health-bridge",
        "dev-app-review-demo",
        "--db",
        str(db_path),
        "--fixture",
        "fixtures/health_bridge_batch_v1.synthetic.json",
        "--label",
        "app-review-demo",
        "--receiver-url",
        "https://reviewer-demo.tailnet.test:8766/v1/batches",
        "--setup-page",
        str(setup_path),
    ]

    first_result = run(
        common_command,
        capture_output=True,
        text=True,
        check=False,
    )
    assert first_result.returncode == 0, first_result.stderr
    first_match = re.search(
        PAIRING_URL_PATTERN,
        setup_path.read_text(encoding="utf-8"),
    )
    assert first_match is not None
    first_bundle = pairing_bundle_from_deep_link(first_match.group(0))
    assert authenticate_receiver_token(db_path, ordinary.token)
    assert authenticate_receiver_token(db_path, first_bundle.bearer_token)

    second_result = run(
        common_command,
        capture_output=True,
        text=True,
        check=False,
    )
    assert second_result.returncode == 0, second_result.stderr
    second_match = re.search(
        PAIRING_URL_PATTERN,
        setup_path.read_text(encoding="utf-8"),
    )
    assert second_match is not None
    second_bundle = pairing_bundle_from_deep_link(second_match.group(0))

    assert authenticate_receiver_token(db_path, ordinary.token)
    assert not authenticate_receiver_token(db_path, first_bundle.bearer_token)
    assert authenticate_receiver_token(db_path, second_bundle.bearer_token)


def test_dev_app_review_demo_cli_rotates_previous_page_across_databases(
    tmp_path: Path,
) -> None:
    first_db_path = tmp_path / "first-reviewer.sqlite"
    second_db_path = tmp_path / "second-reviewer.sqlite"
    setup_path = tmp_path / "reviewer" / "setup.html"
    command_prefix = [
        "uv",
        "run",
        "health-bridge",
        "dev-app-review-demo",
        "--fixture",
        "fixtures/health_bridge_batch_v1.synthetic.json",
        "--receiver-url",
        "https://reviewer-demo.tailnet.test:8766/v1/batches",
        "--setup-page",
        str(setup_path),
    ]

    first_result = run(
        [*command_prefix, "--db", str(first_db_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert first_result.returncode == 0, first_result.stderr
    first_match = re.search(PAIRING_URL_PATTERN, setup_path.read_text(encoding="utf-8"))
    assert first_match is not None
    first_bundle = pairing_bundle_from_deep_link(first_match.group(0))

    second_result = run(
        [*command_prefix, "--db", str(second_db_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert second_result.returncode == 0, second_result.stderr
    second_match = re.search(
        PAIRING_URL_PATTERN, setup_path.read_text(encoding="utf-8")
    )
    assert second_match is not None
    second_bundle = pairing_bundle_from_deep_link(second_match.group(0))

    assert not authenticate_receiver_token(first_db_path, first_bundle.bearer_token)
    assert authenticate_receiver_token(second_db_path, second_bundle.bearer_token)


def test_dev_app_review_demo_cli_refuses_unreadable_existing_reviewer_page(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "reviewer-demo.sqlite"
    setup_path = tmp_path / "reviewer" / "setup.html"
    command = [
        "uv",
        "run",
        "health-bridge",
        "dev-app-review-demo",
        "--db",
        str(db_path),
        "--fixture",
        "fixtures/health_bridge_batch_v1.synthetic.json",
        "--receiver-url",
        "https://reviewer-demo.tailnet.test:8766/v1/batches",
        "--setup-page",
        str(setup_path),
    ]
    first_result = run(command, capture_output=True, text=True, check=False)
    assert first_result.returncode == 0, first_result.stderr
    first_match = re.search(PAIRING_URL_PATTERN, setup_path.read_text(encoding="utf-8"))
    assert first_match is not None
    first_bundle = pairing_bundle_from_deep_link(first_match.group(0))
    invalid_page = b"\xff\xfeinvalid reviewer page"
    _ = setup_path.write_bytes(invalid_page)
    replacement_db_path = tmp_path / "replacement-reviewer.sqlite"
    replacement_command = [
        str(replacement_db_path) if value == str(db_path) else value
        for value in command
    ]

    second_result = run(
        replacement_command,
        capture_output=True,
        text=True,
        check=False,
    )

    assert second_result.returncode != 0
    assert setup_path.read_bytes() == invalid_page
    assert not replacement_db_path.exists()
    assert authenticate_receiver_token(db_path, first_bundle.bearer_token)
    with connect_database(db_path) as connection:
        active_prefixes = ACTIVE_TOKEN_PREFIXES_ADAPTER.validate_python(
            connection.execute(ACTIVE_TOKEN_PREFIXES_SQL).fetchall()
        )
    assert active_prefixes == [(first_bundle.token_prefix,)]


def test_dev_app_review_demo_preserves_previous_page_when_replacement_write_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "reviewer-demo.sqlite"
    setup_path = tmp_path / "reviewer" / "setup.html"
    request = AppReviewDemoRequest(
        db_path=db_path,
        fixture_path=Path("fixtures/health_bridge_batch_v1.synthetic.json"),
        label="app-review-demo",
        receiver_url="https://reviewer-demo.tailnet.test:8766/v1/batches",
        setup_page_path=setup_path,
        receiver_host="127.0.0.1",
        receiver_port=8766,
        watch_seconds=60,
    )
    _ = build_app_review_demo_manifest(request)
    first_match = re.search(PAIRING_URL_PATTERN, setup_path.read_text(encoding="utf-8"))
    assert first_match is not None
    first_bundle = pairing_bundle_from_deep_link(first_match.group(0))

    def fail_private_write(_path: Path, _content: str) -> None:
        msg = "synthetic write failure"
        raise OSError(msg)

    monkeypatch.setattr(
        "health_bridge.cli_dev.write_private_text_file",
        fail_private_write,
    )
    with pytest.raises(RuntimeError, match="pairing credential was revoked"):
        _ = build_app_review_demo_manifest(request)

    assert authenticate_receiver_token(db_path, first_bundle.bearer_token)
    with connect_database(db_path) as connection:
        active_prefixes = ACTIVE_TOKEN_PREFIXES_ADAPTER.validate_python(
            connection.execute(ACTIVE_TOKEN_PREFIXES_SQL).fetchall()
        )
    assert active_prefixes == [(first_bundle.token_prefix,)]


def test_dev_device_session_cli_writes_secret_setup_page_and_redacted_manifest(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "stage-device.sqlite"
    setup_page_path = tmp_path / "pairing" / "device-session.html"
    receiver_url = "https://example-device.tailnet.test:8766/v1/batches?debug=1"

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev-device-session",
            "--db",
            str(db_path),
            "--label",
            "maintainer-iphone",
            "--receiver-url",
            receiver_url,
            "--setup-page",
            str(setup_page_path),
            "--receiver-host",
            "192.0.2.42",
            "--receiver-port",
            "8765",
            "--watch-seconds",
            "3600",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = OUTPUT_ADAPTER.validate_json(result.stdout)
    setup_html = setup_page_path.read_text(encoding="utf-8")
    pairing_match = re.search(PAIRING_URL_PATTERN, setup_html)
    assert pairing_match is not None
    decoded = pairing_invitation_from_deep_link(pairing_match.group(0))

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.db == str(db_path)
    assert output.label == "maintainer-iphone"
    assert output.receiver_url == receiver_url
    assert (
        output.receiver_health_url == "https://example-device.tailnet.test:8766/health"
    )
    assert output.setup_page == str(setup_page_path)
    assert output.pairing_schema_id == "health_bridge.receiver_pairing_invitation.v2"
    assert output.invitation_expires_at == decoded.expires_at
    assert output.baseline_sync_run_id == 0
    assert output.receiver_start_command == [
        "uv",
        "run",
        "health-bridge",
        "receiver",
        "start",
        "--db",
        str(db_path),
        "--host",
        "192.0.2.42",
        "--port",
        "8765",
    ]
    assert output.receiver_systemd_command == [
        "uv",
        "run",
        "health-bridge",
        "dev",
        "receiver-systemd",
        "--db",
        str(db_path),
        "--host",
        "192.0.2.42",
        "--port",
        "8765",
    ]
    assert output.watch_new_sync_runs_command == [
        "uv",
        "run",
        "health-bridge",
        "dev",
        "watch-sync-runs",
        "--db",
        str(db_path),
        "--after-sync-run-id",
        "0",
        "--timeout-seconds",
        "3600",
    ]
    assert output.validate_anchored_steps_command == [
        "uv",
        "run",
        "health-bridge",
        "dev",
        "validate-anchored-steps",
        "--db",
        str(db_path),
    ]
    assert any("Open the setup page" in step for step in output.next_steps)
    assert any("anchored Step Count" in step for step in output.next_steps)
    assert any("validate_anchored_steps_command" in step for step in output.next_steps)
    assert "secret" in output.warning.lower()
    assert stat.S_IMODE(setup_page_path.stat().st_mode) == 0o600
    assert decoded.receiver_url == receiver_url
    assert decoded.invitation_secret not in setup_html
    for forbidden_key in STDOUT_FORBIDDEN_SECRET_KEYS:
        assert forbidden_key not in result.stdout


def test_dev_watch_sync_runs_cli_emits_existing_post_baseline_runs(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "stage-device.sqlite"
    ingest_result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "ingest-fixture",
            "--db",
            str(db_path),
            "--input",
            "fixtures/health_bridge_batch_v1.synthetic.json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert ingest_result.returncode == 0, ingest_result.stderr

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev",
            "watch-sync-runs",
            "--db",
            str(db_path),
            "--after-sync-run-id",
            "0",
            "--timeout-seconds",
            "0",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    stdout_lines = result.stdout.splitlines()
    sync_event = NEW_SYNC_RUN_ADAPTER.validate_json(stdout_lines[0])
    timeout_event = WATCH_TIMEOUT_ADAPTER.validate_json(stdout_lines[-1])

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert sync_event.sync_run_id == 1
    assert sync_event.status == "succeeded"
    assert sync_event.sample_count == 3
    assert sync_event.workout_count == 1
    assert sync_event.sleep_session_count == 1
    assert sync_event.deleted_record_count == 1
    assert sync_event.sync_cursor_count == 2
    assert timeout_event.after_sync_run_id == 0
    assert timeout_event.seen_sync_run_ids == [1]

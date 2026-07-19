import base64
import re
import sqlite3
import time
from binascii import Error as BinasciiError
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar, Final, TypeAlias
from urllib.parse import urlparse, urlunparse

from pydantic import BaseModel, ConfigDict, TypeAdapter, ValidationError

from health_bridge.ingest import ingest_fixture
from health_bridge.private_files import write_private_text_file
from health_bridge.receiver.invitations import revoke_pairing_invitation
from health_bridge.receiver.pairing import (
    create_receiver_pairing_bundle,
    create_receiver_pairing_invitation_bundle,
    pairing_deep_link,
)
from health_bridge.receiver.pairing_setup_page import render_pairing_setup_page
from health_bridge.receiver.tokens import revoke_receiver_token
from health_bridge.storage.database import connect_database, initialize_database

DEFAULT_WATCH_POLL_INTERVAL_SECONDS: Final = 2.0
SETUP_PAGE_WRITE_FAILURE_MESSAGE: Final = (
    "failed to write private pairing setup page; issued pairing credential was revoked"
)
APP_REVIEW_SETUP_PAGE_MARKER_PREFIX: Final = "<!-- health-bridge-app-review-demo:"
APP_REVIEW_SETUP_PAGE_MARKER_SUFFIX: Final = " -->"
INVALID_APP_REVIEW_SETUP_PAGE_MESSAGE: Final = (
    "refusing to replace an existing App Review setup page without a valid "
    "rotation marker"
)
APP_REVIEW_ROTATION_FAILURE_MESSAGE: Final = (
    "failed to revoke the previous App Review credential; restored the previous "
    "setup page and revoked the replacement credential"
)
INVALID_SYSTEMD_SERVICE_NAME_MESSAGE: Final = "invalid service name"
INVALID_SYSTEMD_WHITESPACE_PATH_MESSAGE: Final = (
    "systemd receiver manifest paths with whitespace are not supported"
)
SYSTEMD_SERVICE_NAME_PATTERN: Final = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$",
)
MAX_SYNC_RUN_SQL: Final = "select coalesce(max(sync_run_id), 0) from sync_runs"
WATCH_SYNC_RUNS_SQL: Final = """
select sync_run_id, started_at, finished_at, status, fixture_name,
       sample_count, workout_count, sleep_session_count, deleted_record_count,
       sync_cursor_count, error_summary, sync_window_start, sync_window_end
from sync_runs
where sync_run_id > ?
order by sync_run_id
"""
MaxSyncRunRow: TypeAlias = tuple[int]
SyncRunWatchRow: TypeAlias = tuple[
    int,
    str | None,
    str | None,
    str,
    str | None,
    int,
    int,
    int,
    int,
    int,
    str | None,
    str | None,
    str | None,
]
MAX_SYNC_RUN_ROW_ADAPTER: Final[TypeAdapter[MaxSyncRunRow | None]] = TypeAdapter(
    MaxSyncRunRow | None,
)
SYNC_RUN_WATCH_ROWS_ADAPTER: Final[TypeAdapter[list[SyncRunWatchRow]]] = TypeAdapter(
    list[SyncRunWatchRow],
)


class DevDeviceSessionManifest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

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


class AppReviewDemoManifest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

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


class AppReviewSetupPageMarker(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", frozen=True)

    db_path: Path
    token_prefix: str


class ExistingAppReviewSetupPage(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    marker: AppReviewSetupPageMarker
    content: str


class DevReceiverSystemdManifest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    service_name: str
    unit_path: str
    unit_text: str
    write_unit_command: list[str]
    enable_now_command: list[str]
    restart_command: list[str]
    stop_command: list[str]
    health_check_command: list[str]
    warning: str


class SyncRunWatchEvent(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    event: str = "new_sync_run"
    sync_run_id: int
    started_at: str | None
    finished_at: str | None
    status: str
    fixture_name: str | None
    sample_count: int
    workout_count: int
    sleep_session_count: int
    deleted_record_count: int
    sync_cursor_count: int
    error_summary: str | None
    sync_window_start: str | None
    sync_window_end: str | None


class SyncRunWatchTimeoutEvent(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    event: str = "watch_timeout"
    after_sync_run_id: int
    seen_sync_run_ids: list[int]
    elapsed_seconds: int


@dataclass(frozen=True, slots=True)
class DevDeviceSessionRequest:
    db_path: Path
    label: str
    receiver_url: str
    setup_page_path: Path
    receiver_host: str
    receiver_port: int
    watch_seconds: int


@dataclass(frozen=True, slots=True)
class AppReviewDemoRequest:
    db_path: Path
    fixture_path: Path
    label: str
    receiver_url: str
    setup_page_path: Path
    receiver_host: str
    receiver_port: int
    watch_seconds: int
    app_review_notes_template: Path = Path(
        "docs/maintainers/app-review-notes-template.example.md"
    )
    healthkit_read_types_disclosure: Path = Path("docs/supported-health-data.md")


def build_dev_device_session_manifest(
    request: DevDeviceSessionRequest,
) -> DevDeviceSessionManifest:
    initialize_database(request.db_path)
    baseline_sync_run_id = max_sync_run_id(request.db_path)
    bundle = create_receiver_pairing_invitation_bundle(
        request.db_path,
        label=request.label,
        receiver_url=request.receiver_url,
    )
    deep_link = pairing_deep_link(bundle)
    try:
        write_private_text_file(
            request.setup_page_path,
            render_pairing_setup_page(bundle, deep_link),
        )
    except OSError as exc:
        revoke_pairing_invitation(request.db_path, bundle.invitation_id)
        raise RuntimeError(SETUP_PAGE_WRITE_FAILURE_MESSAGE) from exc

    receiver_start_command = [
        "uv",
        "run",
        "health-bridge",
        "receiver",
        "start",
        "--db",
        str(request.db_path),
        "--host",
        request.receiver_host,
        "--port",
        str(request.receiver_port),
    ]
    receiver_systemd_command = [
        "uv",
        "run",
        "health-bridge",
        "dev",
        "receiver-systemd",
        "--db",
        str(request.db_path),
        "--host",
        request.receiver_host,
        "--port",
        str(request.receiver_port),
    ]
    watch_command = [
        "uv",
        "run",
        "health-bridge",
        "dev",
        "watch-sync-runs",
        "--db",
        str(request.db_path),
        "--after-sync-run-id",
        str(baseline_sync_run_id),
        "--timeout-seconds",
        str(request.watch_seconds),
    ]
    validate_anchored_steps_command = [
        "uv",
        "run",
        "health-bridge",
        "dev",
        "validate-anchored-steps",
        "--db",
        str(request.db_path),
    ]
    return DevDeviceSessionManifest(
        db=str(request.db_path),
        label=request.label,
        receiver_url=request.receiver_url,
        receiver_health_url=receiver_health_url(request.receiver_url),
        setup_page=str(request.setup_page_path),
        pairing_schema_id=bundle.schema_id,
        invitation_expires_at=bundle.expires_at,
        baseline_sync_run_id=baseline_sync_run_id,
        receiver_start_command=receiver_start_command,
        receiver_systemd_command=receiver_systemd_command,
        watch_new_sync_runs_command=watch_command,
        validate_anchored_steps_command=validate_anchored_steps_command,
        next_steps=[
            "Start the receiver with receiver_start_command.",
            (
                "Use receiver_systemd_command to render a user-service manifest "
                "when you want the receiver to persist across shells."
            ),
            (
                "Open the setup page from any trusted screen the iPhone can reach; "
                "scan the QR, tap the in-page button on iPhone, or paste the "
                "copy fallback."
            ),
            (
                "Run foreground anchored Step Count and anchored Workout sync "
                "once before waiting."
            ),
            (
                "Start watch_new_sync_runs_command after foreground sync to observe "
                "new receiver sync runs."
            ),
            (
                "Run validate_anchored_steps_command after anchored Step Count sync "
                "to inspect redacted receiver evidence."
            ),
        ],
        warning=(
            "Setup page contains a temporary, single-use pairing invitation. Keep it "
            "out of chat, Git, wiki, and logs; delete it after pairing or expiry. The "
            "manifest is secret-redacted but may still include private receiver URLs "
            "and local paths."
        ),
    )


def _encode_app_review_setup_page_marker(
    db_path: Path,
    token_prefix: str,
) -> str:
    marker = AppReviewSetupPageMarker(
        db_path=db_path.resolve(strict=False),
        token_prefix=token_prefix,
    )
    encoded = base64.urlsafe_b64encode(marker.model_dump_json().encode("utf-8")).decode(
        "ascii"
    )
    payload = encoded.rstrip("=")
    return (
        f"{APP_REVIEW_SETUP_PAGE_MARKER_PREFIX}{payload}"
        f"{APP_REVIEW_SETUP_PAGE_MARKER_SUFFIX}"
    )


def _decode_app_review_setup_page_marker(line: str) -> AppReviewSetupPageMarker:
    payload = line[
        len(APP_REVIEW_SETUP_PAGE_MARKER_PREFIX) : -len(
            APP_REVIEW_SETUP_PAGE_MARKER_SUFFIX
        )
    ]
    padding = "=" * (-len(payload) % 4)
    try:
        decoded = base64.urlsafe_b64decode(payload + padding).decode("utf-8")
        marker = AppReviewSetupPageMarker.model_validate_json(decoded)
    except (BinasciiError, UnicodeError, ValidationError, ValueError) as exc:
        raise RuntimeError(INVALID_APP_REVIEW_SETUP_PAGE_MESSAGE) from exc
    if not marker.token_prefix.startswith("hb_"):
        raise RuntimeError(INVALID_APP_REVIEW_SETUP_PAGE_MESSAGE)
    return marker


def _existing_app_review_setup_page(
    setup_page_path: Path,
) -> ExistingAppReviewSetupPage | None:
    try:
        existing_page = setup_page_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError) as exc:
        raise RuntimeError(INVALID_APP_REVIEW_SETUP_PAGE_MESSAGE) from exc
    marker_lines = [
        line.strip()
        for line in existing_page.splitlines()
        if line.strip().startswith(APP_REVIEW_SETUP_PAGE_MARKER_PREFIX)
        and line.strip().endswith(APP_REVIEW_SETUP_PAGE_MARKER_SUFFIX)
    ]
    if len(marker_lines) != 1:
        raise RuntimeError(INVALID_APP_REVIEW_SETUP_PAGE_MESSAGE)
    marker = _decode_app_review_setup_page_marker(marker_lines[0])
    if not marker.db_path.is_file():
        raise RuntimeError(INVALID_APP_REVIEW_SETUP_PAGE_MESSAGE)
    return ExistingAppReviewSetupPage(marker=marker, content=existing_page)


def build_app_review_demo_manifest(
    request: AppReviewDemoRequest,
) -> AppReviewDemoManifest:
    existing_reviewer_page = _existing_app_review_setup_page(request.setup_page_path)
    result = ingest_fixture(request.db_path, request.fixture_path)
    bundle = create_receiver_pairing_bundle(
        request.db_path,
        label=request.label,
        receiver_url=request.receiver_url,
    )
    deep_link = pairing_deep_link(bundle)
    marker = _encode_app_review_setup_page_marker(
        request.db_path,
        bundle.token_prefix,
    )
    try:
        write_private_text_file(
            request.setup_page_path,
            f"{marker}\n{render_pairing_setup_page(bundle, deep_link)}",
        )
    except OSError as exc:
        revoke_receiver_token(request.db_path, bundle.token_prefix)
        raise RuntimeError(SETUP_PAGE_WRITE_FAILURE_MESSAGE) from exc
    if existing_reviewer_page is not None:
        try:
            revoke_receiver_token(
                existing_reviewer_page.marker.db_path,
                existing_reviewer_page.marker.token_prefix,
            )
        except (OSError, sqlite3.Error) as exc:
            revoke_receiver_token(request.db_path, bundle.token_prefix)
            try:
                write_private_text_file(
                    request.setup_page_path,
                    existing_reviewer_page.content,
                )
            except OSError as restore_exc:
                raise RuntimeError(APP_REVIEW_ROTATION_FAILURE_MESSAGE) from restore_exc
            raise RuntimeError(APP_REVIEW_ROTATION_FAILURE_MESSAGE) from exc
    receiver_start_command = [
        "uv",
        "run",
        "health-bridge",
        "receiver",
        "start",
        "--db",
        str(request.db_path),
        "--host",
        request.receiver_host,
        "--port",
        str(request.receiver_port),
    ]
    watch_command = [
        "uv",
        "run",
        "health-bridge",
        "dev",
        "watch-sync-runs",
        "--db",
        str(request.db_path),
        "--after-sync-run-id",
        str(max_sync_run_id(request.db_path)),
        "--timeout-seconds",
        str(request.watch_seconds),
    ]
    revoke_reviewer_access_command = [
        "uv",
        "run",
        "health-bridge",
        "receiver",
        "revoke-token",
        "--db",
        str(request.db_path),
        "--token-prefix",
        bundle.token_prefix,
    ]
    return AppReviewDemoManifest(
        db=str(request.db_path),
        fixture=str(request.fixture_path),
        label=request.label,
        receiver_url=request.receiver_url,
        receiver_health_url=receiver_health_url(request.receiver_url),
        setup_page=str(request.setup_page_path),
        pairing_schema_id=bundle.schema_id,
        invitation_expires_at=None,
        demo_data_summary={
            "sources": result.source_count,
            "health_types": result.health_type_count,
            "samples": result.sample_count,
            "workouts": result.workout_count,
            "sleep_sessions": result.sleep_session_count,
            "deleted_records": result.deleted_record_count,
            "sync_cursors": result.sync_cursor_count,
        },
        receiver_start_command=receiver_start_command,
        watch_new_sync_runs_command=watch_command,
        revoke_reviewer_access_command=revoke_reviewer_access_command,
        app_review_notes_template=str(request.app_review_notes_template),
        healthkit_read_types_disclosure=str(request.healthkit_read_types_disclosure),
        next_steps=[
            "Start the receiver with receiver_start_command.",
            (
                "Open the synthetic demo setup page from any trusted screen "
                "the review device can reach; "
                "scan the QR, tap the in-page button, or paste the copy fallback."
            ),
            (
                "Use app_review_notes_template as the reviewer-notes packet; paste the "
                "complete healthkit_read_types_disclosure list and fill all private "
                "support/privacy/demo placeholders before submission."
            ),
            (
                "Run revoke_reviewer_access_command immediately after review or if "
                "the private setup page is exposed."
            ),
            (
                "Keep generated setup pages and pairing links out of chat, Git, "
                "wiki, and logs."
            ),
        ],
        warning=(
            "Setup page contains a revocable legacy reviewer credential for the "
            "synthetic demo receiver. It does not expire automatically, so keep it "
            "out of chat, Git, wiki, and logs and revoke it immediately after review. "
            "Generating another reviewer packet at the same setup-page path revokes "
            "only the credential embedded by the previous reviewer packet. The "
            "manifest is secret-redacted but may still include private receiver URLs, "
            "a non-secret token prefix, and local paths."
        ),
    )


def build_dev_receiver_systemd_manifest(
    *,
    db_path: Path,
    host: str,
    port: int,
    working_directory: Path,
    service_name: str = "health-bridge-receiver",
) -> DevReceiverSystemdManifest:
    if SYSTEMD_SERVICE_NAME_PATTERN.fullmatch(service_name) is None:
        raise ValueError(INVALID_SYSTEMD_SERVICE_NAME_MESSAGE)
    if _has_whitespace(db_path) or _has_whitespace(working_directory):
        raise ValueError(INVALID_SYSTEMD_WHITESPACE_PATH_MESSAGE)
    service_file_name = f"{service_name}.service"
    unit_path = f"~/.config/systemd/user/{service_file_name}"
    unit_text = "\n".join(
        [
            "[Unit]",
            "Description=Health Bridge local receiver",
            "After=network-online.target",
            "",
            "[Service]",
            "Type=simple",
            f"WorkingDirectory={working_directory}",
            (
                "ExecStart=uv run health-bridge receiver start "
                f"--db {db_path} --host {host} --port {port}"
            ),
            "Restart=on-failure",
            "RestartSec=5",
            "",
            "[Install]",
            "WantedBy=default.target",
            "",
        ]
    )
    return DevReceiverSystemdManifest(
        service_name=service_name,
        unit_path=unit_path,
        unit_text=unit_text,
        write_unit_command=[
            "sh",
            "-c",
            f"mkdir -p ~/.config/systemd/user && cat > {unit_path}",
        ],
        enable_now_command=[
            "systemctl",
            "--user",
            "enable",
            "--now",
            service_file_name,
        ],
        restart_command=["systemctl", "--user", "restart", service_file_name],
        stop_command=["systemctl", "--user", "stop", service_file_name],
        health_check_command=["curl", "-fsS", f"http://{host}:{port}/health"],
        warning=(
            "This helper only renders a user-level systemd unit manifest; it does "
            "not install, enable, restart, or stop services. Review unit_text "
            "before use."
        ),
    )


def _has_whitespace(value: Path | str) -> bool:
    return any(character.isspace() for character in str(value))


def receiver_health_url(receiver_url: str) -> str:
    parsed = urlparse(receiver_url)
    return urlunparse((parsed.scheme, parsed.netloc, "/health", "", "", ""))


def max_sync_run_id(db_path: Path) -> int:
    initialize_database(db_path)
    with connect_database(db_path) as connection:
        row = MAX_SYNC_RUN_ROW_ADAPTER.validate_python(
            connection.execute(MAX_SYNC_RUN_SQL).fetchone(),
        )
    return 0 if row is None else row[0]


def iter_new_sync_run_events(
    *,
    db_path: Path,
    after_sync_run_id: int,
) -> Iterator[SyncRunWatchEvent]:
    initialize_database(db_path)
    with connect_database(db_path) as connection:
        rows = SYNC_RUN_WATCH_ROWS_ADAPTER.validate_python(
            connection.execute(WATCH_SYNC_RUNS_SQL, (after_sync_run_id,)).fetchall(),
        )
    for row in rows:
        yield SyncRunWatchEvent(
            sync_run_id=row[0],
            started_at=row[1],
            finished_at=row[2],
            status=row[3],
            fixture_name=row[4],
            sample_count=row[5],
            workout_count=row[6],
            sleep_session_count=row[7],
            deleted_record_count=row[8],
            sync_cursor_count=row[9],
            error_summary=row[10],
            sync_window_start=row[11],
            sync_window_end=row[12],
        )


def watch_sync_run_events(
    *,
    db_path: Path,
    after_sync_run_id: int,
    timeout_seconds: int,
    poll_interval_seconds: float = DEFAULT_WATCH_POLL_INTERVAL_SECONDS,
) -> Iterator[SyncRunWatchEvent | SyncRunWatchTimeoutEvent]:
    start = time.monotonic()
    deadline = start + max(0, timeout_seconds)
    seen_sync_run_ids: set[int] = set()
    while True:
        for event in iter_new_sync_run_events(
            db_path=db_path,
            after_sync_run_id=after_sync_run_id,
        ):
            if event.sync_run_id in seen_sync_run_ids:
                continue
            seen_sync_run_ids.add(event.sync_run_id)
            yield event
        if time.monotonic() >= deadline:
            break
        time.sleep(max(0.1, poll_interval_seconds))
    yield SyncRunWatchTimeoutEvent(
        after_sync_run_id=after_sync_run_id,
        seen_sync_run_ids=sorted(seen_sync_run_ids),
        elapsed_seconds=int(time.monotonic() - start),
    )


def manifest_json(manifest: DevDeviceSessionManifest) -> str:
    return manifest.model_dump_json()


def app_review_demo_manifest_json(manifest: AppReviewDemoManifest) -> str:
    return manifest.model_dump_json()


def receiver_systemd_manifest_json(manifest: DevReceiverSystemdManifest) -> str:
    return manifest.model_dump_json()


def watch_event_json(event: SyncRunWatchEvent | SyncRunWatchTimeoutEvent) -> str:
    return event.model_dump_json()

import json
import sqlite3
import subprocess
import sys
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from inspect import signature
from pathlib import Path
from types import SimpleNamespace
from urllib.request import Request

import pytest
import typer
from typer.testing import CliRunner

from health_bridge import __version__, cli, cli_setup, cli_setup_runtime
from health_bridge import cli_setup_interactive as guided
from health_bridge.cli_config import InstalledDatabase, config_path
from health_bridge.cli_setup import SetupManifest, SetupRequest, build_setup_manifest
from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.ingest import ingest_fixture
from health_bridge.mailbox.helper_lifecycle import HelperPaths
from health_bridge.private_files import write_private_text_file
from health_bridge.queries.catalog import list_synced_metrics
from health_bridge.queries.models import SyncedMetricsResult
from health_bridge.receiver import invitations, transports
from health_bridge.receiver.invitations import redeem_pairing_invitation
from health_bridge.receiver.pairing_setup_page import (
    invitation_page_route,
    read_invitation_page,
)
from tests.cli.test_setup_cli import (
    control_plane,
    isolated_home,
    ready_setup_helper,
    unused_receiver_port,
)
from tests.mailbox.test_helper_distribution_contract import (
    CONTAINER_ID,
    manifest_payload,
)
from tests.receiver.test_pairing_redeem_server import open_http_error
from tests.receiver.test_receiver_source_binding import post_batch, with_source_key

__all__ = ["control_plane", "isolated_home"]


def test_fresh_mac_icloud_menu_prepares_native_pairing_without_public_root(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    control_plane: list[list[str]],
) -> None:
    # Given a matching helper seam and no public iCloud Documents directory.
    platform = SimpleNamespace(platform="darwin", argv=sys.argv)
    for module in (cli, cli_setup, cli_setup_runtime, guided, transports):
        monkeypatch.setattr(module, "sys", platform)
    monkeypatch.setattr(cli_setup, "read_helper_status", ready_setup_helper)
    monkeypatch.setattr(guided, "read_helper_status", ready_setup_helper)
    archive = tmp_path / "synthetic.zip"
    _ = archive.write_bytes(b"synthetic metadata only; not a signed helper")
    helper = HelperPaths.production()
    helper.helpers_dir.mkdir(parents=True, mode=0o700)
    _ = helper.manifest.write_text(
        json.dumps(manifest_payload(archive, schema_version=2, version=__version__))
    )
    documents = (
        Path.home()
        / "Library/Mobile Documents"
        / CONTAINER_ID.replace(".", "~")
        / "Documents"
    )
    ready_native = SimpleNamespace(require_native_pairing=lambda: None)
    monkeypatch.setattr(cli_setup, "default_native_ack_publisher", lambda: ready_native)
    monkeypatch.setattr(guided, "default_native_ack_publisher", lambda: ready_native)
    port = unused_receiver_port()
    selections = iter((1,))

    def choose(_title: str, _options: tuple[str, ...]) -> int:
        return next(selections)

    monkeypatch.setattr(guided, "choose", choose)
    monkeypatch.setattr(cli, "human_terminal", lambda: True)
    completed: list[SetupManifest] = []

    def finish(value: SetupManifest, _clients: tuple[str, ...]) -> None:
        completed.append(value)

    monkeypatch.setattr(cli, "finish_interactively", finish)
    # When iCloud is selected for fresh setup.
    result = CliRunner().invoke(cli.app, ["setup", "--receiver-port", str(port)])
    # Then the owned service and local QR require no phone-facing route.
    assert result.exit_code == 0, result.output
    assert len(completed) == 1
    assert completed[0].private_route_status == "not_required"
    assert completed[0].receiver_url is None
    assert completed[0].receiver_health_url is None
    assert completed[0].local_setup_url.startswith(f"http://127.0.0.1:{port}/setup/")
    assert completed[0].selected_transport.value == "mailbox"
    assert not any(command[0] == "tailscale" for command in control_plane)
    assert not documents.exists()
    _, invitation = read_invitation_page(Path(completed[0].setup_page))
    assert invitation.mailbox_bootstrap is not None
    assert invitation.receiver_url is None
    captured = CliRunner().invoke(cli.app, ["setup", "--json"])
    assert captured.exit_code == 0, captured.output
    assert "local_setup_url" not in json.loads(captured.output)
    assert completed[0].local_setup_url not in captured.output


def test_missing_mac_helper_can_return_and_pause_without_service_changes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, control_plane: list[list[str]]
) -> None:
    # Given a fresh Mac with no helper and no service.
    monkeypatch.setattr(sys, "platform", "darwin")
    request = SetupRequest(
        tmp_path / "private/health.sqlite",
        "iPhone",
        "",
        tmp_path / "private/pair.html",
        "127.0.0.1",
        8765,
        "health-bridge",
    )
    selections = iter((1, 1, 3))
    menus: list[tuple[str, ...]] = []

    def select(_title: str, options: tuple[str, ...]) -> int:
        menus.append(options)
        return next(selections)

    monkeypatch.setattr(guided, "choose", select)
    # When the user returns to connection choices and pauses.
    prepared = guided.prepare_interactively(request)
    # Then no service, invitation, database or helper installation was created.
    assert prepared is None
    assert len(menus) == 3
    assert control_plane == []
    assert not request.db_path.parent.exists()
    assert not HelperPaths.production().helpers_dir.exists()
    assert not (Path.home() / "Library/LaunchAgents").exists()


@pytest.mark.parametrize("mode", ["decline", "missing_files", "foreign_helper"])
def test_helper_install_choice_preserves_prior_state_on_unusable_inputs(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    control_plane: list[list[str]],
    mode: str,
) -> None:
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(cli, "human_terminal", lambda: True)

    def reject_online_download() -> None:
        pytest.fail("Offline helper test must not select an online download")

    monkeypatch.setattr(guided, "install_published_helper", reject_online_download)
    helper = HelperPaths.production()
    marker = helper.app
    if mode == "foreign_helper":
        helper.helpers_dir.mkdir(parents=True)
        _ = marker.write_text("synthetic pre-existing file")
        answers = "2\n4\n"
    else:
        answers = (
            f"2\n4\n1\n{tmp_path / 'missing.zip'}\n{tmp_path / 'missing.json'}\n"
            + ("y\n" if mode == "missing_files" else "n\n")
            + "4\n"
        )
    db = tmp_path / "private/health.sqlite"
    result = CliRunner().invoke(
        cli.app, ["setup", "--db", str(db)], input=answers, env={"TERM": "dumb"}
    )
    assert result.exit_code == 0, result.output
    assert control_plane == []
    assert not db.parent.exists()
    assert not (Path.home() / "Library/LaunchAgents").exists()
    if mode == "foreign_helper":
        assert marker.read_text() == "synthetic pre-existing file"
        assert list(helper.helpers_dir.iterdir()) == [marker]
    else:
        assert not helper.helpers_dir.exists()
        assert "Helper archive path" in result.output


@pytest.fixture
def legacy_clock_and_port(
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[list[datetime], int]:
    port = unused_receiver_port()
    original_signature = signature(cli.setup)
    monkeypatch.setattr(
        cli.setup,
        "__signature__",
        original_signature.replace(
            parameters=[
                parameter.replace(default=port)
                if name == "receiver_port"
                else parameter
                for name, parameter in original_signature.parameters.items()
            ]
        ),
        raising=False,
    )
    clock = [datetime.now(UTC) - timedelta(hours=1)]

    def now(value: datetime | None) -> datetime:
        return clock[0] if value is None else value

    monkeypatch.setattr(invitations, "_normalized_now", now)
    return clock, port


@pytest.mark.parametrize("already_received", [False, True])
@pytest.mark.parametrize("page_removed", [False, True])
def test_legacy_paired_resume_after_page_expiry(
    monkeypatch: pytest.MonkeyPatch,
    control_plane: list[list[str]],
    legacy_clock_and_port: tuple[list[datetime], int],
    already_received: bool,
    page_removed: bool,
) -> None:
    clock, port = legacy_clock_and_port
    url = "https://receiver.healthbridge.internal/v1/batches"
    initial = CliRunner().invoke(
        cli.app,
        [
            "setup",
            "--json",
            "--receiver-url",
            url,
            "--label",
            "synthetic retained phone",
        ],
    )
    assert initial.exit_code == 0, initial.output
    db = Path.home() / ".local/share/health-bridge/health.sqlite"
    page = db.parent / "pairing.html"
    _, invitation = read_invitation_page(page)
    token = "hb_" + "a" * 64
    _ = redeem_pairing_invitation(
        db,
        installation_id="00000000-0000-4000-8000-000000000001",
        device_credential=token,
        platform="ios",
        invitation_secret=invitation.invitation_secret,
        now=clock[0],
    )
    _ = ingest_fixture(db, Path("fixtures/health_bridge_batch_v1.synthetic.json"))
    batch = with_source_key(
        HealthBridgeBatchV1.model_validate_json(
            Path("fixtures/health_bridge_batch_v1.synthetic.json").read_bytes()
        ),
        "apple_health.phone",
    )
    endpoint = f"http://127.0.0.1:{port}/v1/batches"
    if already_received:
        assert post_batch(endpoint, token, batch) == 202
    clock[0] = datetime.now(UTC)
    write_private_text_file(config_path(), json.dumps({"db": str(db)}))
    unit = Path.home() / ".config/systemd/user/health-bridge-receiver.service"
    original_page, original_unit = (page.read_bytes(), unit.read_bytes())
    _ = page.unlink() if page_removed else None
    with sqlite3.connect(db) as connection:
        identity = connection.execute(
            "select receiver_token_id, token_hash, revoked_at from receiver_tokens"
        ).fetchall()
        database_identity = connection.execute(
            "select * from pairing_invitations"
        ).fetchall()
    ticks: list[int] = []

    def advance() -> None:
        ticks.append(len(ticks))
        assert len(ticks) <= 2
        upload = (
            batch
            if len(ticks) == 2
            else batch.model_copy(
                update={"samples": (), "workouts": (), "sleep_sessions": ()}
            )
        )
        assert post_batch(endpoint, token, upload) == 202

    monkeypatch.setattr(cli, "human_terminal", lambda: True)
    monkeypatch.setattr(guided, "wait_tick", advance)
    control_plane.clear()
    result = CliRunner().invoke(
        cli.app, ["setup"], input="1\n1\n1\n", env={"TERM": "dumb"}
    )
    assert result.exit_code == 0, result.output
    assert not any(command[0] == "tailscale" for command in control_plane)
    assert not any("start" in command or "stop" in command for command in control_plane)
    assert len(ticks) == (0 if already_received else 2)
    assert "Setup complete. Health records are saved" in result.output
    assert "read-only query found" in result.output
    assert all(word not in result.output for word in ("Set up Health Bridge", "Choice"))
    assert (not page.exists()) if page_removed else page.read_bytes() == original_page
    assert unit.read_bytes() == original_unit
    with sqlite3.connect(db) as connection:
        assert (
            connection.execute(
                "select receiver_token_id, token_hash, revoked_at from receiver_tokens"
            ).fetchall()
            == identity
        )
        assert (
            connection.execute("select * from pairing_invitations").fetchall()
            == database_identity
        )
    assert invitations.pairing_setup_progress(db, invitation.invitation_secret) is None
    with open_http_error(
        Request(
            f"http://127.0.0.1:{port}" + invitation_page_route(invitation),
            headers={"Accept": "application/json"},
        )
    ) as response:
        assert response.code == 404


def test_human_cancellation_precedes_mutation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Given a human terminal and a fresh destination.
    monkeypatch.setattr(cli, "human_terminal", lambda: True, raising=False)
    db = tmp_path / "private/health.sqlite"
    # When the person leaves at the first choice.
    result = CliRunner().invoke(
        cli.app,
        ["setup", "--db", str(db), "--receiver-port", str(unused_receiver_port())],
        input="3\n",
        env={"TERM": "dumb"},
    )
    # Then discovery has not prepared a receiver or identity.
    assert result.exit_code == 0, result.output
    assert not db.exists()


@pytest.mark.parametrize("mode", ["--json", "--no-input"])
def test_automation_rejects_client_writes_before_preparation(
    tmp_path: Path, mode: str
) -> None:
    # Given an automation invocation with conflicting client intent.
    db = tmp_path / "private/health.sqlite"
    # When setup receives the conflicting flags.
    result = CliRunner().invoke(
        cli.app, ["setup", "--db", str(db), mode, "--configure-client", "hermes"]
    )
    # Then no client or receiver state is prepared.
    assert result.exit_code == 2
    assert not db.exists()


def test_captured_output_has_no_invitation(tmp_path: Path) -> None:
    # Given captured output and isolated external controls.
    db = tmp_path / "private/health.sqlite"
    # When noninteractive setup prepares the receiver.
    result = CliRunner().invoke(
        cli.app,
        ["setup", "--db", str(db), "--receiver-port", str(unused_receiver_port())],
    )
    # Then only a redacted summary is captured.
    assert result.exit_code == 0, result.output
    assert "/setup/" not in result.output
    assert "healthbridge://" not in result.output


def test_discovery_and_resume_preserve_explicit_and_saved_context(
    tmp_path: Path,
) -> None:
    # Given a real pending invitation prepared by the existing owner.

    request = SetupRequest(
        db_path=tmp_path / "private/health.sqlite",
        label="synthetic phone",
        receiver_url="https://receiver.healthbridge.internal/v1/batches",
        setup_page_path=tmp_path / "private/pairing.html",
        receiver_host="127.0.0.1",
        receiver_port=8765,
        executable="health-bridge",
    )
    _ = build_setup_manifest(request)
    before = request.db_path.read_bytes()
    page = request.setup_page_path.read_bytes()
    # When omitted route and label are recovered read-only.

    resumed = guided.resume_request(
        replace(request, receiver_url="", label="iPhone"), set()
    )
    # Then saved context is reused without changing the database or invitation.
    assert resumed == request
    assert request.db_path.read_bytes() == before
    assert request.setup_page_path.read_bytes() == page
    explicit = guided.resume_request(replace(request, label="explicit"), {"label"})
    assert explicit.label == "explicit"


@pytest.mark.parametrize("platform", ["linux", "darwin"])
def test_fresh_menu_discloses_prerequisites_before_selection(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    platform: str,
) -> None:
    monkeypatch.setattr(sys, "platform", platform)
    request = SetupRequest(
        db_path=tmp_path / "private/health.sqlite",
        label="synthetic phone",
        receiver_url="",
        setup_page_path=tmp_path / "private/pair.html",
        receiver_host="127.0.0.1",
        receiver_port=8765,
        executable="health-bridge",
    )

    def leave(_title: str, options: tuple[str, ...]) -> int:
        prerequisites = capsys.readouterr().out
        assert "Tailscale" in prerequisites
        assert "iPhone" in prerequisites
        assert "connected" in prerequisites
        assert options[0] == "Tailscale (Recommended)"
        assert options[-2:] == ("More connection options", "Set up later")
        assert ("iCloud Mailbox (Mac only, Beta)" in options) == (platform == "darwin")
        if platform == "darwin":
            assert "Apple Account" in prerequisites
            assert "logged in" in prerequisites
            assert "delayed" in prerequisites
        return len(options) - 1

    monkeypatch.setattr(guided, "choose", leave)
    assert guided.prepare_interactively(request) is None
    assert not request.db_path.parent.exists()


def test_explicit_connection_bypasses_fresh_menu(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = SetupRequest(
        db_path=tmp_path / "private/health.sqlite",
        label="synthetic phone",
        receiver_url="https://receiver.healthbridge.internal/v1/batches",
        setup_page_path=tmp_path / "private/pair.html",
        receiver_host="127.0.0.1",
        receiver_port=8765,
        executable="health-bridge",
    )

    def unexpected(_title: str, _options: tuple[str, ...]) -> int:
        pytest.fail("Explicit connection must not offer a new-install menu")

    monkeypatch.setattr(guided, "choose", unexpected)
    assert guided.prepare_interactively(request) == request


def test_arrow_choice_and_eof_cancel(monkeypatch: pytest.MonkeyPatch) -> None:
    # Given a terminal with arrow keys.
    monkeypatch.delenv("NO_COLOR", raising=False)
    monkeypatch.setenv("TERM", "xterm")
    keys = iter(["\x1b[B", "\r"])
    monkeypatch.setattr(guided, "getchar", lambda: next(keys))
    # When down and Enter are pressed, the second real action is selected.
    assert guided.choose("Action", ("First", "Second")) == 1
    monkeypatch.setenv("TERM", "dumb")

    def eof(*_args: str, **_kwargs: int) -> str:
        raise EOFError

    monkeypatch.setattr(typer, "prompt", eof)
    with pytest.raises(EOFError):
        _ = guided.choose("Action", ("First", "Second"))


@pytest.mark.parametrize("explicit_host", [False, True])
def test_same_network_choice_preserves_explicit_bind(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, explicit_host: bool
) -> None:
    request = SetupRequest(
        db_path=tmp_path / "private/health.sqlite",
        label="synthetic phone",
        receiver_url="",
        setup_page_path=tmp_path / "private/pair.html",
        receiver_host="127.0.0.1",
        receiver_port=8765,
        executable="health-bridge",
    )
    selections = iter(["More connection options", "Same network only", "Set up later"])

    def select(_title: str, options: tuple[str, ...]) -> int:
        return options.index(next(selections))

    monkeypatch.setattr(guided, "choose", select)

    urls = iter(("http://receiver.local:8765/v1/batches", ""))

    def url(_prompt: str, *, default: str = "") -> str:
        assert default == ""
        return next(urls)

    monkeypatch.setattr(typer, "prompt", url)
    prepared = guided.prepare_interactively(
        request, {"receiver_host"} if explicit_host else set()
    )
    if explicit_host:
        assert prepared is None
        assert not request.db_path.parent.exists()
        return
    assert prepared == replace(
        request,
        receiver_url="http://receiver.local:8765/v1/batches",
        receiver_host="127.0.0.1" if explicit_host else "0.0.0.0",  # noqa: S104 - test bind input
    )
    assert not request.db_path.parent.exists()


def test_guided_cli_waits_for_authenticated_observations_and_queries(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, control_plane: list[list[str]]
) -> None:
    # Given real isolated storage, loopback HTTP and stubbed OS controls.
    db = tmp_path / "private/health.sqlite"
    page = db.parent / "pairing.html"
    port = unused_receiver_port()
    token = "hb_" + "a" * 64
    batch = with_source_key(
        HealthBridgeBatchV1.model_validate_json(
            Path("fixtures/health_bridge_batch_v1.synthetic.json").read_bytes()
        ),
        "apple_health.phone",
    )
    ticks: list[int] = []
    queries: list[SyncedMetricsResult] = []
    opened: list[str] = []

    def advance() -> None:
        ticks.append(len(ticks))
        if len(ticks) == 1:
            _, invitation = read_invitation_page(page)
            _ = redeem_pairing_invitation(
                db,
                installation_id="00000000-0000-4000-8000-000000000001",
                device_credential=token,
                platform="ios",
                invitation_secret=invitation.invitation_secret,
            )
        else:
            upload = (
                batch
                if len(ticks) == 3
                else batch.model_copy(
                    update={"samples": (), "workouts": (), "sleep_sessions": ()}
                )
            )
            assert (
                post_batch(f"http://127.0.0.1:{port}/v1/batches", token, upload) == 202
            )
        assert len(ticks) <= 3

    def query(path: Path) -> SyncedMetricsResult:
        result = list_synced_metrics(path)
        queries.append(result)
        return result

    monkeypatch.setattr(cli, "human_terminal", lambda: True)
    monkeypatch.setattr(guided, "wait_tick", advance, raising=False)
    monkeypatch.setattr(guided, "list_synced_metrics", query, raising=False)
    monkeypatch.setattr(guided, "open_page", opened.append)

    def unexpected_client(*_args: object) -> SetupManifest:
        pytest.fail("Default setup must not invoke a client registrar")

    monkeypatch.setattr(guided, "configure_mcp_clients", unexpected_client)
    # When a person follows setup and keeps the terminal connected to phone progress.
    result = CliRunner().invoke(
        cli.app,
        ["setup", "--db", str(db), "--receiver-port", str(port)],
        input="1\n",
        env={"TERM": "dumb"},
    )
    # Then an empty upload did not finish setup, and real stored coverage was queried.
    assert result.exit_code == 0, result.output
    assert len(ticks) == 3
    assert len(queries) == 1
    assert "Follow phone progress" not in result.output
    assert "Configure hermes" not in result.output
    assert any(metric.record_count > 0 for metric in queries[0].metrics)
    assert len(opened) == 1
    assert sum("start" in command for command in control_plane) == 1
    with sqlite3.connect(db) as connection:
        assert connection.execute(
            "select count(*) from pairing_invitations"
        ).fetchone() == (1,)


def test_plain_rerun_reuses_owned_custom_context(tmp_path: Path) -> None:
    # Given a prepared receiver with nondefault service, page and bind port.
    db = tmp_path / "private/health.sqlite"
    page = db.parent / "custom.html"
    first = CliRunner().invoke(
        cli.app,
        [
            "setup",
            "--json",
            "--db",
            str(db),
            "--setup-page",
            str(page),
            "--receiver-port",
            str(unused_receiver_port()),
            "--service-name",
            "synthetic-custom",
            "--receiver-url",
            "https://receiver.healthbridge.internal/v1/batches",
        ],
    )
    assert first.exit_code == 0, first.output
    before = page.read_bytes()
    # When setup is rerun without repeating the custom options.
    result = CliRunner().invoke(cli.app, ["setup", "--json"])
    # Then the original runtime and invitation are retained.
    assert result.exit_code == 0, result.output
    assert page.read_bytes() == before
    assert not (db.parent / "pairing.html").exists()


def test_selected_client_timeout_retains_readonly_access(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    request = SetupRequest(
        db_path=tmp_path / "private/health.sqlite",
        label="synthetic phone",
        receiver_url="https://receiver.healthbridge.internal/v1/batches",
        setup_page_path=tmp_path / "private/pairing.html",
        receiver_host="127.0.0.1",
        receiver_port=8765,
        executable="health-bridge",
    )
    manifest = build_setup_manifest(request)
    _ = ingest_fixture(
        request.db_path, Path("fixtures/health_bridge_batch_v1.synthetic.json")
    )
    selected: list[tuple[str, ...]] = []

    def timeout(_manifest: SetupManifest, requested: tuple[str, ...]) -> SetupManifest:
        selected.append(requested)
        command = "synthetic-client"
        raise subprocess.TimeoutExpired(command, 30)

    def received(value: SetupManifest) -> SetupManifest:
        return value.model_copy(
            update={
                "data_receipt_status": "received",
                "detected_mcp_clients": ["hermes"],
            }
        )

    def select(_title: str, _options: tuple[str, ...]) -> int:
        return 1

    monkeypatch.setattr(guided, "follow_connection", received)
    monkeypatch.setattr(guided, "choose", select)
    monkeypatch.setattr(guided, "configure_mcp_clients", timeout)
    guided.finish_interactively(manifest, ("hermes",))
    assert selected == [("hermes",)]
    assert request.db_path.exists()


@pytest.mark.parametrize("received", [True, False])
def test_followup_uses_actual_executable(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], received: bool
) -> None:
    request = SetupRequest(
        db_path=tmp_path / "private/health.sqlite",
        label="synthetic",
        receiver_url="https://receiver.healthbridge.internal/v1/batches",
        setup_page_path=tmp_path / "private/pair.html",
        receiver_host="127.0.0.1",
        receiver_port=8765,
        executable="/opt/Health Bridge/bin/health-bridge",
    )
    manifest = build_setup_manifest(request).model_copy(
        update={"data_receipt_status": "received" if received else "not_received"}
    )
    _ = ingest_fixture(
        request.db_path, Path("fixtures/health_bridge_batch_v1.synthetic.json")
    )
    guided.finish_interactively(manifest, ())
    command = "query synced-metrics to see" if received else "setup on your"
    assert (
        f"Run '/opt/Health Bridge/bin/health-bridge' {command}"
        in capsys.readouterr().out
    )


def test_empty_saved_query_cannot_finish_or_configure_client(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    request = SetupRequest(
        tmp_path / "private/health.sqlite",
        "iPhone",
        "https://receiver.healthbridge.internal/v1/batches",
        tmp_path / "private/pair.html",
        "127.0.0.1",
        8765,
        "health-bridge",
    )
    manifest = build_setup_manifest(request).model_copy(
        update={"data_receipt_status": "received"}
    )

    def follow(value: SetupManifest) -> SetupManifest:
        return value

    monkeypatch.setattr(guided, "follow_connection", follow)
    selected: list[tuple[str, ...]] = []

    def configure(value: SetupManifest, requested: tuple[str, ...]) -> SetupManifest:
        selected.append(requested)
        return value

    monkeypatch.setattr(guided, "configure_mcp_clients", configure)
    guided.finish_interactively(manifest, ("hermes",))
    assert selected == []


def test_cancel_wait_retains_running_receiver(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, control_plane: list[list[str]]
) -> None:
    db = tmp_path / "private/health.sqlite"
    monkeypatch.setattr(cli, "human_terminal", lambda: True)
    opened: list[str] = []
    monkeypatch.setattr(guided, "open_page", opened.append)

    def interrupt() -> None:
        raise KeyboardInterrupt

    monkeypatch.setattr(guided, "wait_tick", interrupt)
    result = CliRunner().invoke(
        cli.app,
        [
            "setup",
            "--db",
            str(db),
            "--receiver-port",
            str(unused_receiver_port()),
        ],
        input="1\n1\n",
        env={"TERM": "dumb"},
    )
    assert result.exit_code == 0, result.output
    assert db.is_file()
    assert (db.parent / "pairing.html").is_file()
    assert not any(
        "stop" in command or "disable" in command for command in control_plane
    )


@pytest.mark.parametrize("invalid_config", ["malformed", "missing-database"])
def test_explicit_healthy_setup_ignores_invalid_global_database(
    tmp_path: Path, invalid_config: str
) -> None:
    db = tmp_path / "selected/health.sqlite"
    args = [
        "setup",
        "--json",
        "--db",
        str(db),
        "--receiver-port",
        str(unused_receiver_port()),
        "--receiver-url",
        "https://receiver.healthbridge.internal/v1/batches",
    ]
    first = CliRunner().invoke(cli.app, args)
    assert first.exit_code == 0, first.output
    original = InstalledDatabase.model_validate_json(
        config_path().read_text()
    ).model_copy(update={"db": str(tmp_path / "obsolete/missing.sqlite")})
    write_private_text_file(
        config_path(),
        "{" if invalid_config == "malformed" else original.model_dump_json(),
    )
    with sqlite3.connect(db) as database:
        before = list(database.iterdump())
    resumed = CliRunner().invoke(cli.app, args)
    assert resumed.exit_code == 0, resumed.output
    with sqlite3.connect(db) as database:
        assert list(database.iterdump()) == before

import sys
from pathlib import Path
from subprocess import CompletedProcess, run
from typing import ClassVar, TypeVar

import pytest
from click import unstyle
from pydantic import BaseModel, ConfigDict
from typer.testing import CliRunner

from health_bridge.cli import app
from tests.cli import test_setup_cli
from tests.fixture_helpers import initialized_fixture_db


class CliModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class CommonQueryOutput(CliModel):
    missing_data_notes: tuple[str, ...]


class TimeseriesPointOutput(CliModel):
    type_code: str


class TimeseriesOutput(CommonQueryOutput):
    points: tuple[TimeseriesPointOutput, ...]


class SupportedTimeseriesTypeOutput(CliModel):
    type_code: str
    category: str
    aggregation: str


class SupportedTimeseriesOutput(CommonQueryOutput):
    total_type_count: int
    types: tuple[SupportedTimeseriesTypeOutput, ...]


class DailySampleStatisticOutput(CliModel):
    total: float | None
    aggregation: str


class DailyObservationOutput(CliModel):
    sample_totals: dict[str, float]
    sample_total_semantics: dict[str, str]
    daily_activity_totals: dict[str, float]
    daily_projection_status: dict[str, str]
    sample_statistics: dict[str, DailySampleStatisticOutput]


class DailySummaryOutput(CommonQueryOutput):
    days: tuple[DailyObservationOutput, ...]


ModelT = TypeVar("ModelT", bound=BaseModel)
setup_control_plane = test_setup_cli.control_plane


def _run_health_bridge(args: list[str]) -> CompletedProcess[str]:
    return run(
        ["uv", "run", "health-bridge", *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _parse_output(result: CompletedProcess[str], model: type[ModelT]) -> ModelT:
    return model.model_validate_json(result.stdout)


@pytest.mark.parametrize(
    "config",
    [None, "broken", '{"db":"relative.sqlite"}', '{"db":"/missing/health.sqlite"}'],
)
def test_missing_or_invalid_config_never_creates_database_and_override_works(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, config: str | None
) -> None:
    db_path = initialized_fixture_db(tmp_path)
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    monkeypatch.setenv("HOME", str(home))
    if config is not None:
        config_file = home / ".config/health-bridge/config.json"
        config_file.parent.mkdir(parents=True, mode=0o700)
        _ = config_file.write_text(config)
        config_file.chmod(0o600)
    before = set(home.rglob("*"))
    for command in (["status", "--json"], ["query", "synced-metrics"]):
        implicit = CliRunner().invoke(app, command)
        assert implicit.exit_code != 0
        assert "--db" in unstyle(implicit.output)
        explicit = CliRunner().invoke(app, [*command, "--db", str(db_path)])
        assert explicit.exit_code == 0
    assert set(home.rglob("*")) == before


@pytest.mark.parametrize("implicit_db", [False, True])
def test_query_cli_outputs_json_for_documented_commands(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, *, implicit_db: bool
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(
        sys, "argv", [str(Path(sys.executable).with_name("health-bridge"))]
    )
    if implicit_db:
        setup = CliRunner().invoke(
            app,
            [
                "setup",
                "--receiver-url",
                "https://receiver.healthbridge.internal/v1/batches",
                "--db",
                str(db_path),
                "--setup-page",
                str(tmp_path / "pair.html"),
                "--receiver-port",
                str(test_setup_cli.unused_receiver_port()),
                "--json",
            ],
        )
        assert setup.exit_code == 0, setup.output

    # When
    commands = (
        ["query", "synced-metrics", "--db", str(db_path)],
        ["query", "supported-timeseries-types", "--category", "body"],
        [
            "query",
            "timeseries",
            "--db",
            str(db_path),
            "--types",
            "steps,heart_rate",
            "--start-time",
            "2026-06-01T00:00:00Z",
            "--end-time",
            "2026-06-08T00:00:00Z",
        ],
        [
            "query",
            "workouts",
            "--db",
            str(db_path),
            "--start-date",
            "2026-06-01",
            "--end-date",
            "2026-06-08",
        ],
        [
            "query",
            "sleep-summary",
            "--db",
            str(db_path),
            "--start-date",
            "2026-06-01",
            "--end-date",
            "2026-06-08",
        ],
        [
            "query",
            "daily-summary",
            "--db",
            str(db_path),
            "--start-date",
            "2026-06-01",
            "--end-date",
            "2026-06-08",
        ],
        ["query", "explain-sources", "--db", str(db_path)],
    )
    outputs = [
        _run_health_bridge(
            [arg for arg in command if arg not in {"--db", str(db_path)}]
            if implicit_db
            else command
        )
        for command in commands
    ]
    common_outputs = [_parse_output(output, CommonQueryOutput) for output in outputs]
    supported_output = _parse_output(outputs[1], SupportedTimeseriesOutput)
    timeseries_output = _parse_output(outputs[2], TimeseriesOutput)
    daily_output = _parse_output(outputs[5], DailySummaryOutput)

    # Then
    assert [output.returncode for output in outputs] == [0, 0, 0, 0, 0, 0, 0]
    assert all(output.stderr == "" for output in outputs)
    assert all(output.missing_data_notes != () for output in common_outputs)
    assert supported_output.total_type_count == 80
    assert {entry.type_code for entry in supported_output.types} == {
        "body_fat_mass",
        "body_fat_percentage",
        "body_mass_index",
        "body_temperature",
        "height",
        "lean_body_mass",
        "skeletal_muscle_mass",
        "skin_temperature",
        "waist_circumference",
        "weight",
    }
    assert timeseries_output.points[0].type_code == "steps"
    day = daily_output.days[0]
    assert "steps" not in day.sample_totals
    assert "steps" not in day.daily_activity_totals
    assert day.sample_total_semantics["steps"] == "daily_aggregate"
    assert day.daily_projection_status["steps"] == "legacy_unknown"
    assert day.sample_statistics["steps"].total == 4321.0
    assert day.sample_statistics["steps"].aggregation == "sum"


def test_query_cli_returns_missing_data_caveat_when_no_rows(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = _run_health_bridge(
        [
            "query",
            "timeseries",
            "--db",
            str(db_path),
            "--types",
            "steps",
            "--start-time",
            "2026-06-20T00:00:00Z",
            "--end-time",
            "2026-06-21T00:00:00Z",
        ],
    )
    output = _parse_output(result, TimeseriesOutput)

    # Then
    assert result.returncode == 0
    assert result.stderr == ""
    assert output.points == ()
    assert "availability is unknown" in output.missing_data_notes[0]

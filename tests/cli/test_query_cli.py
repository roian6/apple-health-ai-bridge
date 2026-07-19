from pathlib import Path
from subprocess import CompletedProcess, run
from typing import ClassVar, TypeVar

from pydantic import BaseModel, ConfigDict

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


class DailyObservationOutput(CliModel):
    sample_totals: dict[str, float]
    sample_total_semantics: dict[str, str]
    daily_activity_totals: dict[str, float]


class DailySummaryOutput(CommonQueryOutput):
    days: tuple[DailyObservationOutput, ...]


ModelT = TypeVar("ModelT", bound=BaseModel)


def _run_health_bridge(args: list[str]) -> CompletedProcess[str]:
    return run(
        ["uv", "run", "health-bridge", *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _parse_output(result: CompletedProcess[str], model: type[ModelT]) -> ModelT:
    return model.model_validate_json(result.stdout)


def test_query_cli_outputs_json_for_documented_commands(tmp_path: Path) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

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
    outputs = [_run_health_bridge(command) for command in commands]
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
    assert daily_output.days[0].sample_totals["steps"] == 4321.0
    assert daily_output.days[0].sample_total_semantics["steps"] == "daily_aggregate"
    assert daily_output.days[0].daily_activity_totals["steps"] == 4321.0


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

import subprocess
import sys
from pathlib import Path

import pytest
from scripts.fuzz.campaign import (
    engine_command,
    require_mutation_evidence,
    run_engine,
)
from scripts.fuzz.engine import require_fresh_imports


def test_engine_commands_bound_resources_and_use_explicit_artifacts(
    tmp_path: Path,
) -> None:
    # When
    command = engine_command("batch", tmp_path, mutation=True)
    # Then
    assert command[:4] == [
        sys.executable,
        "-m",
        "scripts.fuzz.engine",
        "batch",
    ]
    assert str(tmp_path / "corpus") in command
    assert f"-artifact_prefix={tmp_path / 'artifacts'}/" in command
    assert {
        "-max_total_time=45",
        "-timeout=5",
        "-rss_limit_mb=512",
        "-max_len=4096",
    } <= set(command)
    assert "-runs=0" not in command


def test_initialization_replays_copied_seeds(tmp_path: Path) -> None:
    # When
    command = engine_command("mcp_dates", tmp_path, mutation=False)
    # Then
    assert "-runs=0" in command
    assert not any(arg.startswith("-max_total_time=") for arg in command)


@pytest.mark.parametrize(
    "log",
    [
        "",
        "#4 INITED cov: 12 ft: 14\n#4 DONE cov: 12 ft: 14\n",
        "#4 INITED cov: 12 ft: 14\n#50 NEW cov: 12 ft: 14\n#99 DONE cov: 12 ft: 14\n",
        "#4 INITED cov: 0 ft: 0\n#50 NEW cov: 0 ft: 1\n#99 DONE cov: 0 ft: 1\n",
    ],
)
def test_launch_only_or_flat_coverage_fails(log: str) -> None:
    # When / Then
    with pytest.raises(RuntimeError, match="mutation"):
        require_mutation_evidence(log)


def test_feature_growth_proves_mutation() -> None:
    # Given: synthetic libFuzzer output, not a native execution claim.
    log = "#4 INITED cov: 12 ft: 14\n#50 NEW cov: 13 ft: 16\n#99 DONE cov: 13 ft: 16\n"
    # When / Then
    require_mutation_evidence(log)


def test_crashing_child_fails_and_preserves_log(tmp_path: Path) -> None:
    # Given: a real subprocess failure, without substituting an Atheris module.
    command = [sys.executable, "-c", "raise RuntimeError('synthetic failure')"]
    log = tmp_path / "failure.log"
    # When / Then
    with pytest.raises(subprocess.CalledProcessError):
        run_engine(command, log)
    assert "synthetic failure" in log.read_text()


def test_already_imported_product_code_is_refused() -> None:
    # Given
    import health_bridge.contract.batch_v1  # noqa: PLC0415

    assert health_bridge.contract.batch_v1
    # When / Then
    with pytest.raises(RuntimeError, match="fresh"):
        require_fresh_imports()

from collections.abc import Callable
from pathlib import Path
from typing import Final

import pytest
from scripts.fuzz.targets import MAX_INPUT_BYTES, batch, mcp_dates

from health_bridge.contract.batch_v1 import HealthBridgeBatchV1
from health_bridge.mcp.tools import DateRangeArgs

CORPUS: Final = Path("scripts/fuzz/corpus")


@pytest.mark.parametrize("target", ["batch", "mcp_dates"])
def test_synthetic_seeds_reach_product_validation(target: str) -> None:
    # Given
    path = CORPUS / target / "valid.synthetic.json"
    data = path.read_bytes()
    # When / Then
    if target == "batch":
        parsed = HealthBridgeBatchV1.model_validate_json(data)
        assert parsed.sources[0].source_key.startswith("synthetic.")
        assert parsed.sync.cursors == ()
        assert batch(data)
    else:
        parsed_dates = DateRangeArgs.model_validate_json(data)
        assert parsed_dates.start_date == "2026-06-01"
        assert mcp_dates(data)


@pytest.mark.parametrize("target", [batch, mcp_dates])
@pytest.mark.parametrize("data", [b"", b"{", b"[]", b"null", b"\xff", b"{}"])
def test_malformed_inputs_are_expected_rejections(
    target: Callable[[bytes], bool], data: bytes
) -> None:
    # When / Then
    assert not target(data)


@pytest.mark.parametrize("target", [batch, mcp_dates])
def test_oversized_inputs_do_not_enter_validator(
    target: Callable[[bytes], bool], monkeypatch: pytest.MonkeyPatch
) -> None:
    # Given
    def unexpected(_data: bytes) -> None:
        pytest.fail("oversized input reached product validation")

    monkeypatch.setattr(HealthBridgeBatchV1, "model_validate_json", unexpected)
    monkeypatch.setattr(DateRangeArgs, "model_validate_json", unexpected)
    # When / Then
    assert not target(b" " * (MAX_INPUT_BYTES + 1))


@pytest.mark.parametrize("error", [RuntimeError, AssertionError, TypeError])
@pytest.mark.parametrize("target", [batch, mcp_dates])
def test_unexpected_validator_failures_escape(
    target: Callable[[bytes], bool],
    error: type[Exception],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    def unexpected(_data: bytes) -> None:
        raise error

    monkeypatch.setattr(HealthBridgeBatchV1, "model_validate_json", unexpected)
    monkeypatch.setattr(DateRangeArgs, "model_validate_json", unexpected)
    # When / Then
    with pytest.raises(error):
        _ = target(b"{}")


@pytest.mark.parametrize("target", ["batch", "mcp_dates"])
def test_seed_corpus_includes_semantic_rejections(target: str) -> None:
    # Given
    callback = {"batch": batch, "mcp_dates": mcp_dates}[target]
    seeds = sorted((CORPUS / target).iterdir())
    # When / Then
    assert seeds
    for seed in seeds:
        assert ".synthetic." in seed.name
        data = seed.read_bytes()
        assert len(data) <= MAX_INPUT_BYTES
        assert callback(data) is seed.name.startswith("valid")


@pytest.mark.parametrize("target", [batch, mcp_dates])
def test_length_limit_is_inclusive(target: Callable[[bytes], bool]) -> None:
    # Given
    name = "batch" if target is batch else "mcp_dates"
    data = (CORPUS / name / "valid.synthetic.json").read_bytes()
    # When / Then
    assert target(data.ljust(MAX_INPUT_BYTES))

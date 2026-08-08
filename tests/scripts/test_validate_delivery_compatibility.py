from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from shutil import copyfile

VALIDATOR = Path("scripts/validate-delivery-compatibility.py")
MATRIX = Path("fixtures/delivery_compatibility_v1.synthetic.json")
RAW_BATCH = Path("fixtures/health_bridge_batch_v1.synthetic.json")
SWIFT_VECTOR = Path("fixtures/delivery_v1_swift.synthetic.json")
HTTP_BODY_ROW = "python_http_v1_raw_batch"
HTTP_BODY_SHA256 = "63bd969e3b0844c4c58af1a8c538a34e316e59166377178bdb2d2efacc03a3bf"


def test_strict_validator_rejects_missing_approved_baseline(tmp_path: Path) -> None:
    # Given: a fixtures directory without the approved compatibility matrix.
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()

    # When: the strict compatibility validator is invoked.
    result = subprocess.run(
        [sys.executable, str(VALIDATOR), "--fixtures", str(fixtures), "--strict"],
        check=False,
        capture_output=True,
        text=True,
    )

    # Then: validation fails closed at the missing approved baseline boundary.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL compatibility missing_approved_baseline\n",
        "",
    )


def test_strict_validator_accepts_approved_matrix() -> None:
    # Given: the repository's approved synthetic compatibility matrix.
    # When: the strict validator checks every recorded row.
    result = subprocess.run(
        [sys.executable, str(VALIDATOR), "--fixtures", "fixtures", "--strict"],
        check=False,
        capture_output=True,
        text=True,
    )

    # Then: the complete matrix passes without diagnostics.
    assert (result.returncode, result.stdout, result.stderr) == (
        0,
        "PASS compatibility\n",
        "",
    )


def test_strict_validator_names_mutated_http_body_row(tmp_path: Path) -> None:
    # Given: an isolated approved matrix with one expected HTTP body hash changed.
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()
    _ = copyfile(RAW_BATCH, fixtures / RAW_BATCH.name)
    _ = copyfile(SWIFT_VECTOR, fixtures / SWIFT_VECTOR.name)
    matrix = MATRIX.read_bytes().replace(
        HTTP_BODY_SHA256.encode(),
        ("0" * 64).encode(),
        1,
    )
    _ = (fixtures / MATRIX.name).write_bytes(matrix)

    # When: strict compatibility validation checks the mutation.
    result = subprocess.run(
        [sys.executable, str(VALIDATOR), "--fixtures", str(fixtures), "--strict"],
        check=False,
        capture_output=True,
        text=True,
    )

    # Then: the exact mutated row is named and validation exits one.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        f"FAIL compatibility {HTTP_BODY_ROW}\n",
        "",
    )


def test_strict_validator_rejects_coordinated_baseline_edit(tmp_path: Path) -> None:
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()
    _ = copyfile(RAW_BATCH, fixtures / RAW_BATCH.name)
    _ = copyfile(SWIFT_VECTOR, fixtures / SWIFT_VECTOR.name)
    matrix = MATRIX.read_bytes() + b"\n"
    _ = (fixtures / MATRIX.name).write_bytes(matrix)

    result = subprocess.run(
        [sys.executable, str(VALIDATOR), "--fixtures", str(fixtures), "--strict"],
        check=False,
        capture_output=True,
        text=True,
    )

    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL compatibility approved_baseline_digest\n",
        "",
    )

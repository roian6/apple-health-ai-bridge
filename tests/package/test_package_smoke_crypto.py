from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Protocol, runtime_checkable

if TYPE_CHECKING:
    import pytest

CRYPTO_IMPORT = (
    "from cryptography.hazmat.primitives.asymmetric import ed25519,x25519; "
    "from cryptography.hazmat.primitives.ciphers.aead import AESGCM"
)
PACKAGE_SMOKE = Path("scripts/package-smoke.py")


@runtime_checkable
class PackageSmokeModule(Protocol):
    def verify_crypto_primitives(self, python: Path, *, cwd: Path) -> None: ...


def _load_package_smoke() -> PackageSmokeModule:
    spec = importlib.util.spec_from_file_location("package_smoke_crypto", PACKAGE_SMOKE)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert isinstance(module, PackageSmokeModule)
    return module


def test_fresh_venv_python_imports_required_crypto_primitives(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    # Given: a fresh-environment Python executable and the package smoke runner.
    package_smoke = _load_package_smoke()
    python = tmp_path / "venv" / "bin" / "python"
    calls: list[tuple[list[str], Path]] = []

    def record_run(
        command: list[str], *, cwd: Path
    ) -> subprocess.CompletedProcess[str]:
        calls.append((command, cwd))
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(package_smoke, "run", record_run)

    # When: the package smoke verifies its installed cryptography dependency.
    package_smoke.verify_crypto_primitives(python, cwd=tmp_path)

    # Then: the installed interpreter imports every required primitive directly.
    assert calls == [([str(python), "-c", CRYPTO_IMPORT], tmp_path)]


def test_unsupported_crypto_platform_fails_before_package_startup(
    tmp_path: Path,
) -> None:
    # Given: an existing artifact directory and the synthetic unsupported marker.
    command = [
        sys.executable,
        str(PACKAGE_SMOKE),
        "--dist-dir",
        str(tmp_path),
        "--crypto-platform-marker",
        "synthetic-unsupported",
    ]

    # When: package smoke is invoked for the unsupported platform.
    result = subprocess.run(command, check=False, capture_output=True, text=True)

    # Then: dependency support fails before artifact inspection or app startup.
    output = result.stdout + result.stderr
    assert result.returncode != 0
    assert "cryptography dependency unavailable" in output
    assert "dist directory must contain" not in output


def test_malformed_crypto_platform_marker_is_rejected_closed(tmp_path: Path) -> None:
    # Given: a marker outside the package smoke's closed platform-marker set.
    command = [
        sys.executable,
        str(PACKAGE_SMOKE),
        "--dist-dir",
        str(tmp_path),
        "--crypto-platform-marker",
        "malformed-marker",
    ]

    # When: package smoke parses the malformed marker.
    result = subprocess.run(command, check=False, capture_output=True, text=True)

    # Then: argument parsing rejects it without entering package startup.
    assert result.returncode != 0
    assert "invalid choice" in result.stderr

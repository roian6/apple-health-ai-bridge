import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AUDIT_PATH = ROOT / "scripts/public-release-audit.py"


def run_strict_audit(
    tmp_path: Path,
    candidate_text: str,
    *,
    candidate_path: str = "candidate.txt",
) -> subprocess.CompletedProcess[str]:
    git = shutil.which("git")
    assert git is not None
    script = tmp_path / "scripts/public-release-audit.py"
    script.parent.mkdir(parents=True)
    _ = shutil.copy2(AUDIT_PATH, script)
    candidate = tmp_path / candidate_path
    candidate.parent.mkdir(parents=True, exist_ok=True)
    _ = candidate.write_text(
        candidate_text,
        encoding="utf-8",
    )
    _ = subprocess.run([git, "init", "-q"], cwd=tmp_path, check=True)
    _ = subprocess.run(
        [git, "add", "scripts/public-release-audit.py", candidate_path],
        cwd=tmp_path,
        check=True,
    )
    return subprocess.run(
        [sys.executable, str(script), "--strict", "--max-marker-lines", "0"],
        cwd=tmp_path,
        check=False,
        text=True,
        capture_output=True,
    )


def test_strict_audit_blocks_and_redacts_literal_device_credential(
    tmp_path: Path,
) -> None:
    credential = "hb_" + ("Z" * 48)

    result = run_strict_audit(tmp_path, f"device_credential={credential}\n")

    assert result.returncode == 3
    assert "literal-device-credential" in result.stdout
    assert credential not in result.stdout
    assert "[REDACTED local denylist match]" in result.stdout


def test_strict_audit_blocks_synthetic_prefix_extension(tmp_path: Path) -> None:
    placeholder = "hb_synthetic_" + ("Z" * 40)

    result = run_strict_audit(tmp_path, f"device_credential={placeholder}\n")

    assert result.returncode == 3
    assert "literal-device-credential" in result.stdout
    assert placeholder not in result.stdout


def test_strict_audit_allows_exact_official_mcp_registry_name(
    tmp_path: Path,
) -> None:
    registry_owner = "github.roian6"
    registry_name = f"io.{registry_owner}/health-bridge"

    result = run_strict_audit(
        tmp_path,
        f'{{"name":"{registry_name}"}}\n',
        candidate_path="server.json",
    )

    assert result.returncode == 0
    assert "strict_blockers=0" in result.stdout


def test_strict_audit_still_blocks_other_registry_like_names(
    tmp_path: Path,
) -> None:
    registry_owner = "github.someone-else"
    registry_name = f"io.{registry_owner}/health-bridge"

    result = run_strict_audit(
        tmp_path,
        f'{{"name":"{registry_name}"}}\n',
        candidate_path="server.json",
    )

    assert result.returncode == 3
    assert "non-neutral-bundle-literal" in result.stdout

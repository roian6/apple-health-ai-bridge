import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

ROOT = Path(__file__).parents[2]
RELEASE_TOOL = ROOT / "scripts/release_tools.py"
XCODE_PROJECT = Path(
    "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
)


@dataclass(frozen=True, slots=True)
class ReleaseTree:
    receiver_version: str
    release_tag: str
    release_scope: Literal["receiver", "coordinated"] | None
    ios_version: str
    ios_build: str
    batch_version: str
    include_batch_compatibility: bool = True
    notes_scope: Literal["receiver", "coordinated"] | None = None


def git_output(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        check=False,
        text=True,
    )
    assert completed.returncode == 0, completed.stderr
    return completed.stdout.strip()


def commit_release_tree(repo: Path, message: str) -> str:
    _ = git_output(repo, "add", ".")
    _ = git_output(
        repo,
        "-c",
        "user.name=Synthetic Release Test",
        "-c",
        "user.email=synthetic-release-test",
        "commit",
        "-m",
        message,
    )
    return git_output(repo, "rev-parse", "HEAD")


def write_release_tree(
    repo: Path,
    release: ReleaseTree,
) -> None:
    xcode = repo / XCODE_PROJECT
    xcode.parent.mkdir(parents=True, exist_ok=True)
    _ = xcode.write_text(
        (
            f"MARKETING_VERSION = {release.ios_version};\n"
            f"CURRENT_PROJECT_VERSION = {release.ios_build};\n"
        ),
        encoding="utf-8",
    )
    _ = (repo / "pyproject.toml").write_text(
        (
            f'[project]\nversion = "{release.receiver_version}"\n'
            'requires-python = ">=3.11"\n'
        ),
        encoding="utf-8",
    )
    fixture = repo / "fixtures/health_bridge_batch_v1.synthetic.json"
    fixture.parent.mkdir(parents=True, exist_ok=True)
    _ = fixture.write_text(
        json.dumps(
            {
                "schema_id": "health_bridge.batch.v1",
                "schema_version": release.batch_version,
            }
        ),
        encoding="utf-8",
    )
    component_index: dict[str, object] = {
        "batch_protocol": {
            "schema_id": "health_bridge.batch.v1",
            "version": release.batch_version,
        },
        "ios_companion": {
            "build": release.ios_build,
            "marketing_version": release.ios_version,
        },
        "receiver_cli": {
            "release_tag": release.release_tag,
            "version": release.receiver_version,
        },
        "schema_id": "health_bridge.component_versions.v1",
    }
    if release.release_scope is not None:
        component_index["release_scope"] = release.release_scope
    _ = (repo / "component-versions.json").write_text(
        json.dumps(component_index, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    notes = repo / ".github/release" / f"notes-{release.release_tag}.md"
    notes.parent.mkdir(parents=True, exist_ok=True)
    effective_notes_scope = release.notes_scope or release.release_scope
    scope_marker = (
        "Coordinated release"
        if effective_notes_scope == "coordinated"
        else "Receiver-only release"
    )
    no_testflight = (
        "\nNo TestFlight update is required"
        if effective_notes_scope != "coordinated"
        else ""
    )
    batch_compatibility_label = "Compatible Batch Protocol: `{} ({})`".format(
        "health_bridge.batch.v1",
        release.batch_version,
    )
    batch_compatibility = (
        f"\n{batch_compatibility_label}" if release.include_batch_compatibility else ""
    )
    _ = notes.write_text(
        (
            f"# {release.release_tag}\n"
            f"@{release.release_tag}\n"
            f"{scope_marker}\n"
            f"Compatible iOS Companion: `{release.ios_version} ({release.ios_build})`"
            f"{batch_compatibility}"
            f"{no_testflight}\n"
        ),
        encoding="utf-8",
    )


def init_release_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _ = git_output(repo, "init", "-b", "main")
    return repo


def validate_transition(
    repo: Path,
    *,
    tag: str,
    tag_target: str,
    default_main: str,
    baseline: str,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(RELEASE_TOOL),
            "validate",
            "--repo",
            str(repo),
            "--tag",
            tag,
            "--tag-target-commit",
            tag_target,
            "--default-main-commit",
            default_main,
            "--baseline-commit",
            baseline,
        ],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Final, Literal

import pytest

ROOT: Final = Path(__file__).resolve().parents[2]
SCRIPT: Final = ROOT / "scripts/ci-scope.sh"
METADATA: Final = (
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/feature_request.yml",
    ".github/ISSUE_TEMPLATE/setup_feedback.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/pull_request_template.md",
)
SCOPED: Final = (
    ("README.md", "maintenance"),
    (".github/SUPPORT.md", "maintenance"),
    (".coderabbit.yaml", "maintenance"),
    (".github/labeler.yml", "maintenance"),
    (".github/workflows/labels.yml", "maintenance"),
    ("assets/brand/health-bridge-lockup.svg", "maintenance"),
    ("assets/brand/build.py", "full"),
    ("docs/examples/demo.py", "full"),
    ("docs/reference/cli.md", "maintenance"),
    ("src/health_bridge/queries/daily.py", "python"),
    ("src/health_bridge/mcp/server.py", "python"),
    ("tests/queries/test_date_boundaries.py", "python"),
    ("ios/HealthBridgeCompanion/App/ContentView.swift", "native"),
    ("scripts/generate_brand_assets.py", "native"),
    (".github/linters/swiftlint.yml", "native"),
    ("src/health_bridge/mcp/types.py", "full"),
    ("ios/HealthBridgeCompanion/Sources/DeliveryProtocolV1.swift", "full"),
    ("ios/HealthBridgeCompanion/Package.swift", "full"),
    ("macos/HealthBridgeMailboxAckPublisher/Sources/main.swift", "full"),
)
UNCLASSIFIED: Final = (
    "src/health_bridge/__init__.py",
    "pyproject.toml",
    ".github/workflows/python.yml",
    "docs/reference/batch-v1.md",
    ".github/release/criteria.md",
    ".github/ISSUE_TEMPLATE/unlisted.yml",
    ".github/ISSUE_TEMPLATE/setup_feedback.yml\nextra",
)


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        env={
            **os.environ,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "Synthetic",
            "GIT_AUTHOR_EMAIL": "synthetic",
            "GIT_COMMITTER_NAME": "Synthetic",
            "GIT_COMMITTER_EMAIL": "synthetic",
        },
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()


def _commit(repo: Path) -> str:
    _ = _git(repo, "add", "--all")
    _ = _git(repo, "commit", "-qm", "synthetic change")
    return _git(repo, "rev-parse", "HEAD")


def _scope(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/bash", str(SCRIPT), *args],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )


@pytest.fixture
def history(tmp_path: Path) -> tuple[Path, str]:
    repo = tmp_path / "repo"
    repo.mkdir()
    _ = _git(repo, "init", "--template=", "-b", "main")
    _ = _git(repo, "config", "core.filemode", "true")
    for name in (*METADATA, *UNCLASSIFIED, *(name for name, _ in SCOPED)):
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        _ = path.write_text("synthetic original\n")
    return repo, _commit(repo)


@pytest.mark.parametrize("name", METADATA)
def test_existing_metadata_modification_selects_light_checks(
    history: tuple[Path, str], name: str
) -> None:
    # Given: one ordinary modification in a real committed Git history.
    repo, base = history
    _ = (repo / name).write_text("synthetic updated\n")
    head = _commit(repo)
    # When: the production classifier reads the complete diff.
    result = _scope(repo, "classify", "pull_request", base, head)
    # Then: this PR may use the metadata lane.
    assert (result.returncode, result.stdout) == (0, "maintenance\n"), result.stderr


@pytest.mark.parametrize(
    "name",
    UNCLASSIFIED,
)
def test_mixed_or_unknown_change_keeps_full_checks(
    history: tuple[Path, str], name: str
) -> None:
    # Given: metadata alongside a runtime, configuration, or unknown path.
    repo, base = history
    _ = (repo / METADATA[0]).write_text("synthetic updated\n")
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text("synthetic change\n")
    head = _commit(repo)
    # When: classification runs with both changes present.
    result = _scope(repo, "classify", "pull_request", base, head)
    # Then: no unrecognized change can take the light lane.
    assert (result.returncode, result.stdout) == (0, "full\n"), result.stderr


@pytest.mark.parametrize("change", ["delete", "rename", "executable", "symlink"])
def test_metadata_path_without_ordinary_file_modification_keeps_full_checks(
    history: tuple[Path, str],
    change: Literal["delete", "rename", "executable", "symlink"],
) -> None:
    # Given: a known path with a non-content-only change.
    repo, base = history
    path = repo / METADATA[0]
    match change:
        case "delete":
            path.unlink()
        case "rename":
            _ = path.rename(path.with_name("renamed.yml"))
        case "executable":
            path.chmod(0o755)
        case "symlink":
            path.unlink()
            path.symlink_to("setup_feedback.yml")
    head = _commit(repo)
    # When: Git reports deletion, rename, mode change, or symlink replacement.
    result = _scope(repo, "classify", "pull_request", base, head)
    # Then: filename membership alone is insufficient.
    assert (result.returncode, result.stdout) == (0, "full\n"), result.stderr


def test_new_allowlisted_file_keeps_full_checks(history: tuple[Path, str]) -> None:
    # Given: the known filename did not exist in the base revision.
    repo, _ = history
    path = repo / METADATA[0]
    path.unlink()
    base = _commit(repo)
    _ = path.write_text("synthetic new file\n")
    head = _commit(repo)
    # When: the filename is added rather than modified.
    result = _scope(repo, "classify", "pull_request", base, head)
    # Then: additions retain complete validation.
    assert (result.returncode, result.stdout) == (0, "full\n"), result.stderr


def test_empty_diff_keeps_full_checks(history: tuple[Path, str]) -> None:
    # Given: there is no affirmative metadata-only change.
    repo, base = history
    # When: both revisions are identical.
    result = _scope(repo, "classify", "pull_request", base, base)
    # Then: an empty selection cannot skip validation.
    assert (result.returncode, result.stdout) == (0, "full\n"), result.stderr


@pytest.mark.parametrize(
    "event", ["push", "workflow_dispatch", "schedule", "pull_request_target", ""]
)
def test_non_pr_event_keeps_full_checks(history: tuple[Path, str], event: str) -> None:
    # Given: a push, tag push, manual run, or unrecognized event has no PR refs.
    repo, _ = history
    # When: classification runs without PR-only data.
    result = _scope(repo, "classify", event, "", "")
    # Then: these events always retain all existing gates.
    assert (result.returncode, result.stdout) == (0, "full\n"), result.stderr


@pytest.mark.parametrize("head", ["", "main", "0" * 40, "main; echo metadata"])
def test_invalid_pr_ref_fails_closed(history: tuple[Path, str], head: str) -> None:
    # Given: a PR ref is missing, malformed, or absent from the repository.
    repo, base = history
    # When: the production classifier attempts to inspect it.
    result = _scope(repo, "classify", "pull_request", base, head)
    # Then: it fails rather than manufacturing a successful light selection.
    assert result.returncode != 0
    assert result.stdout not in {"maintenance\n", "python\n", "native\n"}


@pytest.mark.parametrize(("name", "expected"), SCOPED)
def test_component_profiles_follow_reviewed_consumers(
    history: tuple[Path, str], name: str, expected: str
) -> None:
    # Given: an existing reviewed component path and ordinary content modification.
    repo, base = history
    _ = (repo / name).write_text("synthetic updated\n")
    head = _commit(repo)
    # When: the same classifier used in CI processes its committed diff.
    result = _scope(repo, "classify", "pull_request", base, head)
    # Then: shared/native-generator inputs are not mistaken for passive docs.
    assert (result.returncode, result.stdout) == (0, f"{expected}\n"), result.stderr


@pytest.mark.parametrize(
    ("component", "expected"),
    [
        ("src/health_bridge/queries/daily.py", "python"),
        ("ios/HealthBridgeCompanion/App/ContentView.swift", "native"),
    ],
)
def test_local_selection_includes_committed_staged_and_unstaged_changes(
    history: tuple[Path, str], component: str, expected: str
) -> None:
    # Given: committed docs, staged support copy, and an unstaged component change.
    repo, base = history
    _ = (repo / "README.md").write_text("synthetic committed\n")
    _ = _commit(repo)
    _ = (repo / ".github/SUPPORT.md").write_text("synthetic staged\n")
    _ = _git(repo, "add", ".github/SUPPORT.md")
    _ = (repo / component).write_text("synthetic unstaged\n")
    # When: local validation is selected against the PR base.
    result = _scope(repo, "local", base)
    # Then: it includes all three layers rather than inspecting only HEAD.
    assert (result.returncode, result.stdout) == (0, f"{expected}\n"), result.stderr


def test_mixed_python_and_native_changes_require_full_validation(
    history: tuple[Path, str],
) -> None:
    # Given: both components change, with ordinary metadata in the same PR.
    repo, base = history
    for name in (
        "README.md",
        "src/health_bridge/queries/daily.py",
        "ios/HealthBridgeCompanion/App/ContentView.swift",
    ):
        _ = (repo / name).write_text("synthetic updated\n")
    head = _commit(repo)
    # When: the whole committed diff is classified.
    result = _scope(repo, "classify", "pull_request", base, head)
    # Then: the shared integration path is retained.
    assert (result.returncode, result.stdout) == (0, "full\n"), result.stderr


def test_untracked_local_inputs_fail_closed_to_full(history: tuple[Path, str]) -> None:
    # Given: a local file is not represented by the tracked diff.
    repo, base = history
    _ = (repo / "untracked.py").write_text("synthetic change\n")
    # When: the local selector includes untracked inputs.
    result = _scope(repo, "local", base)
    # Then: it cannot issue a scoped pass while ignoring that file.
    assert (result.returncode, result.stdout) == (0, "full\n"), result.stderr

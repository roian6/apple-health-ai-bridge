import subprocess
from pathlib import Path

ROOT = Path(__file__).parents[2]
RELEASE_CRITERIA = ROOT / ".github/release/criteria.md"
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"


def test_legacy_tag_namespace_blocks_stale_release_workflows() -> None:
    # Given: the current release policy and immutable historical workflow.
    criteria = RELEASE_CRITERIA.read_text(encoding="utf-8")
    workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
    historical = subprocess.run(
        ["git", "show", "v1.0.1:.github/workflows/release.yml"],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )

    # When: governance evaluates both publication paths.
    assert historical.returncode == 0, historical.stderr

    # Then: legacy creation has no bypass and cannot enter the release environment.
    assert 'tags: ["v*"]' in historical.stdout
    assert "environment: github-release" in historical.stdout
    assert 'tags: ["receiver-v*"]' in workflow
    assert "environment: github-release" in workflow
    assert "deployment tag rule matching `receiver-v*`" in criteria
    assert "active tag ruleset targeting `refs/tags/v*`" in criteria
    assert "no bypass actors" in criteria
    assert "preserves existing `v1.0.0` and `v1.0.1`" in criteria


def test_receiver_tag_namespace_has_a_separate_protected_creation_path() -> None:
    # Given: the release criteria for future Receiver/CLI artifacts.
    criteria = RELEASE_CRITERIA.read_text(encoding="utf-8")

    # When: governance evaluates the component-scoped tag path.
    receiver_ruleset = "active tag ruleset targeting `refs/tags/receiver-v*`"

    # Then: receiver creation is restricted independently from legacy denial.
    assert receiver_ruleset in criteria
    assert "Restrict creations" in criteria
    assert "release maintainer role needed to create a new signed tag" in criteria


def test_tagged_workflow_pins_default_main_and_transition_baseline() -> None:
    # Given: the component-scoped tagged release workflow.
    workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

    # When: governance inspects the trusted transition inputs.
    required_markers = (
        "default_main_commit_sha:",
        "baseline_commit_sha:",
        'test "$target_sha" = "$default_main_sha"',
        'git rev-parse "${target_sha}^1"',
        "--tag-target-commit",
        "--default-main-commit",
        "--baseline-commit",
    )

    # Then: the workflow cannot validate only the tagged checkout.
    for marker in required_markers:
        assert marker in workflow


def test_tagged_workflow_uses_first_parent_without_rejecting_merge_commits() -> None:
    workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

    assert 'git rev-parse "${target_sha}^1"' in workflow
    assert "git rev-list --parents" not in workflow
    assert "wc -w" not in workflow


def test_maintainer_tag_instructions_match_github_squash_merge_identity() -> None:
    criteria = RELEASE_CRITERIA.read_text(encoding="utf-8")

    assert '.committer.login == "web-flow"' in criteria
    assert '.author.login == "roian6"' in criteria
    assert "git verify-commit HEAD" not in criteria

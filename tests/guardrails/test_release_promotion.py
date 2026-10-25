from pathlib import Path

from tests.guardrails.release_git_fixtures import synthetic_release_base
from tests.guardrails.release_version_fixtures import commit_release_tree, git_output


def test_repeated_main_promotions_preserve_release_hotfix_and_forward_port(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    _ = synthetic_release_base(repo, "main")
    _ = git_output(repo, "config", "user.name", "Synthetic Promotion")
    _ = git_output(repo, "config", "user.email", "synthetic-promotion")
    _ = git_output(repo, "branch", "release")
    _ = (repo / "feature-one.txt").write_text("first feature\n")
    _ = commit_release_tree(repo, "synthetic feature one")
    _ = git_output(repo, "checkout", "release")
    _ = git_output(repo, "merge", "--no-ff", "main", "-m", "reviewed first promotion")
    first = git_output(repo, "rev-parse", "HEAD")
    _ = (repo / "hotfix.txt").write_text("stable repair\n")
    fix = commit_release_tree(repo, "synthetic stable repair")
    _ = git_output(repo, "checkout", "main")
    _ = git_output(repo, "cherry-pick", fix)
    _ = (repo / "feature-two.txt").write_text("second feature\n")
    promoted = commit_release_tree(repo, "synthetic feature two")
    _ = git_output(repo, "checkout", "release")
    _ = git_output(repo, "merge", "--no-ff", "main", "-m", "reviewed second promotion")
    assert git_output(repo, "show", "-s", "--format=%P", "HEAD").split() == [
        fix,
        promoted,
    ]
    assert git_output(repo, "merge-base", first, "HEAD") == first
    assert (repo / "hotfix.txt").read_text() == "stable repair\n"
    assert (repo / "feature-one.txt").read_text() == "first feature\n"
    assert (repo / "feature-two.txt").read_text() == "second feature\n"

"""Minimal synthetic histories; never import the caller's objects or refs."""

from pathlib import Path

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    git_output,
    write_release_tree,
)


def synthetic_release_base(repo: Path, branch: str) -> str:
    repo.mkdir()
    _ = git_output(repo, "init", "--template=", "-b", branch)
    _ = git_output(repo, "config", "commit.gpgsign", "false")
    _ = git_output(repo, "config", "tag.gpgsign", "false")
    _ = git_output(repo, "config", "core.hooksPath", str(repo / ".git/hooks"))
    write_release_tree(
        repo,
        ReleaseTree("1.1.3", "receiver-v1.1.3", "receiver", "1.1.1", "50", "1.0.0"),
    )
    base = commit_release_tree(repo, "synthetic published receiver baseline")
    _ = git_output(
        repo,
        "-c",
        "user.name=Synthetic",
        "-c",
        "user.email=synthetic",
        "tag",
        "-a",
        "receiver-v1.1.3",
        "-m",
        "synthetic published baseline",
    )
    _ = git_output(repo, "remote", "add", "origin", str(repo))
    return base

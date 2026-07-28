from pathlib import Path

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    git_output,
    init_release_repo,
    validate_transition,
    write_release_tree,
)


def test_receiver_transition_advances_receiver_only(tmp_path: Path) -> None:
    # Given: a trusted predecessor and a receiver-only candidate.
    repo = init_release_repo(tmp_path)
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.1",
            release_tag="v1.0.1",
            release_scope="receiver",
            ios_version="1.0.0",
            ios_build="15",
            batch_version="1.0.0",
        ),
    )
    baseline = commit_release_tree(repo, "baseline")
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.2",
            release_tag="receiver-v1.0.2",
            release_scope="receiver",
            ios_version="1.0.0",
            ios_build="15",
            batch_version="1.0.0",
        ),
    )
    candidate = commit_release_tree(repo, "receiver release")

    # When: the CLI validates the pinned target against main and its parent.
    completed = validate_transition(
        repo,
        tag="receiver-v1.0.2",
        tag_target=candidate,
        default_main=candidate,
        baseline=baseline,
    )

    # Then: the exact receiver-only transition is accepted.
    assert completed.returncode == 0, completed.stderr


def test_tag_target_must_equal_trusted_default_main(tmp_path: Path) -> None:
    # Given: a self-consistent release commit that is now behind main.
    repo = init_release_repo(tmp_path)
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.1",
            release_tag="v1.0.1",
            release_scope="receiver",
            ios_version="1.0.0",
            ios_build="15",
            batch_version="1.0.0",
        ),
    )
    baseline = commit_release_tree(repo, "baseline")
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.2",
            release_tag="receiver-v1.0.2",
            release_scope="receiver",
            ios_version="1.0.0",
            ios_build="15",
            batch_version="1.0.0",
        ),
    )
    stale_target = commit_release_tree(repo, "stale release")
    _ = (repo / "README.md").write_text("new main state\n", encoding="utf-8")
    default_main = commit_release_tree(repo, "advance main")
    _ = git_output(repo, "checkout", "--detach", stale_target)

    # When: the stale target is compared with the trusted main SHA.
    completed = validate_transition(
        repo,
        tag="receiver-v1.0.2",
        tag_target=stale_target,
        default_main=default_main,
        baseline=baseline,
    )

    # Then: validation fails before artifact publication.
    assert completed.returncode == 1
    assert "tag target must equal the trusted default-main commit" in completed.stderr


def test_transition_rejects_regressing_component_metadata(tmp_path: Path) -> None:
    # Given: a candidate whose local sources agree while iOS and Batch regress.
    repo = init_release_repo(tmp_path)
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.1",
            release_tag="v1.0.1",
            release_scope="receiver",
            ios_version="1.1.0",
            ios_build="16",
            batch_version="1.1.0",
        ),
    )
    baseline = commit_release_tree(repo, "baseline")
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.2",
            release_tag="receiver-v1.0.2",
            release_scope="coordinated",
            ios_version="1.0.0",
            ios_build="15",
            batch_version="1.0.0",
        ),
    )
    candidate = commit_release_tree(repo, "regressing release")

    # When: transition validation compares the tagged tree with its baseline.
    completed = validate_transition(
        repo,
        tag="receiver-v1.0.2",
        tag_target=candidate,
        default_main=candidate,
        baseline=baseline,
    )

    # Then: self-consistent but regressing component metadata is rejected.
    assert completed.returncode == 1
    assert "component versions must not regress from the baseline" in completed.stderr


def test_receiver_scope_preserves_baseline_ios_and_batch(tmp_path: Path) -> None:
    # Given: an explicitly receiver-scoped candidate that also changes iOS.
    repo = init_release_repo(tmp_path)
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.1",
            release_tag="v1.0.1",
            release_scope="receiver",
            ios_version="1.0.0",
            ios_build="15",
            batch_version="1.0.0",
        ),
    )
    baseline = commit_release_tree(repo, "baseline")
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.2",
            release_tag="receiver-v1.0.2",
            release_scope="receiver",
            ios_version="1.1.0",
            ios_build="16",
            batch_version="1.0.0",
        ),
    )
    candidate = commit_release_tree(repo, "invalid receiver release")

    # When: the scoped transition is validated.
    completed = validate_transition(
        repo,
        tag="receiver-v1.0.2",
        tag_target=candidate,
        default_main=candidate,
        baseline=baseline,
    )

    # Then: receiver scope cannot hide a simultaneous component update.
    assert completed.returncode == 1
    assert (
        "receiver scope must preserve baseline iOS and Batch Protocol"
        in completed.stderr
    )

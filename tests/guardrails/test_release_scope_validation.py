from pathlib import Path

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    init_release_repo,
    validate_transition,
    write_release_tree,
)


def test_component_index_requires_explicit_release_scope(tmp_path: Path) -> None:
    repo = init_release_repo(tmp_path)
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.0.2",
            release_tag="receiver-v1.0.2",
            release_scope=None,
            ios_version="1.1.0",
            ios_build="16",
            batch_version="1.0.0",
        ),
    )
    baseline = commit_release_tree(repo, "baseline without scope")

    completed = validate_transition(
        repo,
        tag="receiver-v1.0.2",
        tag_target=baseline,
        default_main=baseline,
        baseline=baseline,
    )

    assert completed.returncode == 1
    assert "component version index release_scope must be explicit" in completed.stderr


def test_coordinated_scope_accepts_explicit_multi_component_update(
    tmp_path: Path,
) -> None:
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
            receiver_version="1.1.0",
            release_tag="receiver-v1.1.0",
            release_scope="coordinated",
            ios_version="1.1.0",
            ios_build="16",
            batch_version="1.0.0",
        ),
    )
    candidate = commit_release_tree(repo, "coordinated release")

    completed = validate_transition(
        repo,
        tag="receiver-v1.1.0",
        tag_target=candidate,
        default_main=candidate,
        baseline=baseline,
    )

    assert completed.returncode == 0, completed.stderr


def test_coordinated_scope_requires_an_additional_component_update(
    tmp_path: Path,
) -> None:
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
            release_scope="coordinated",
            ios_version="1.0.0",
            ios_build="15",
            batch_version="1.0.0",
        ),
    )
    candidate = commit_release_tree(repo, "false coordinated release")

    completed = validate_transition(
        repo,
        tag="receiver-v1.0.2",
        tag_target=candidate,
        default_main=candidate,
        baseline=baseline,
    )

    assert completed.returncode == 1
    assert "coordinated scope must advance iOS or Batch Protocol" in completed.stderr


def test_release_notes_require_exact_batch_compatibility(tmp_path: Path) -> None:
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
            include_batch_compatibility=False,
        ),
    )
    candidate = commit_release_tree(repo, "missing compatibility note")

    completed = validate_transition(
        repo,
        tag="receiver-v1.0.2",
        tag_target=candidate,
        default_main=candidate,
        baseline=baseline,
    )

    assert completed.returncode == 1
    assert (
        "release notes must state exact compatible Batch Protocol" in completed.stderr
    )


def test_release_notes_scope_marker_matches_component_index(tmp_path: Path) -> None:
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
            receiver_version="1.1.0",
            release_tag="receiver-v1.1.0",
            release_scope="coordinated",
            ios_version="1.1.0",
            ios_build="16",
            batch_version="1.0.0",
            notes_scope="receiver",
        ),
    )
    candidate = commit_release_tree(repo, "mismatched notes")

    completed = validate_transition(
        repo,
        tag="receiver-v1.1.0",
        tag_target=candidate,
        default_main=candidate,
        baseline=baseline,
    )

    assert completed.returncode == 1
    assert "release notes do not match release_scope" in completed.stderr

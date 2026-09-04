import json
from pathlib import Path

import pytest

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    init_release_repo,
    validate_transition,
    write_release_tree,
)


def _baseline() -> ReleaseTree:
    return ReleaseTree(
        receiver_version="1.1.1",
        release_tag="receiver-v1.1.1",
        release_scope="receiver",
        ios_version="1.1.0",
        ios_build="39",
        batch_version="1.0.0",
    )


def _ios_candidate(
    *,
    receiver_version: str = "1.1.1",
    release_tag: str = "receiver-v1.1.1",
    ios_version: str = "1.1.1",
    ios_build: str = "41",
    batch_version: str = "1.0.0",
) -> ReleaseTree:
    return ReleaseTree(
        receiver_version=receiver_version,
        release_tag=release_tag,
        release_scope="ios",
        ios_version=ios_version,
        ios_build=ios_build,
        batch_version=batch_version,
    )


@pytest.mark.parametrize(
    ("candidate", "tag"),
    [
        (_ios_candidate(), "ios-v1.1.1-build.41"),
        (
            _ios_candidate(ios_version="1.1.0", ios_build="40"),
            "ios-v1.1.0-build.40",
        ),
    ],
    ids=("marketing-and-build", "build-only"),
)
def test_ios_scope_accepts_monotonic_app_only_transition(
    tmp_path: Path,
    candidate: ReleaseTree,
    tag: str,
) -> None:
    # Given: a receiver release baseline and an iOS-only candidate without notes.
    repo = init_release_repo(tmp_path)
    write_release_tree(repo, _baseline())
    baseline = commit_release_tree(repo, "published receiver baseline")
    receiver_notes = repo / ".github/release/notes-receiver-v1.1.1.md"
    published_notes = receiver_notes.read_bytes()
    write_release_tree(repo, candidate)
    assert receiver_notes.read_bytes() == published_notes
    candidate_commit = commit_release_tree(repo, "iOS source checkpoint")

    # When: the iOS checkpoint is validated against its first parent.
    completed = validate_transition(
        repo,
        tag=tag,
        tag_target=candidate_commit,
        default_main=candidate_commit,
        baseline=baseline,
    )

    # Then: the app-only identity is accepted without receiver release ceremony.
    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout)["release_scope"] == "ios"


@pytest.mark.parametrize(
    ("baseline_tree", "candidate", "expected_error"),
    [
        (
            _baseline(),
            _ios_candidate(
                receiver_version="1.1.2",
                release_tag="receiver-v1.1.2",
            ),
            "ios scope must preserve baseline Receiver/CLI and Batch Protocol",
        ),
        (
            _baseline(),
            _ios_candidate(batch_version="1.0.1"),
            "ios scope must preserve baseline Receiver/CLI and Batch Protocol",
        ),
        (
            ReleaseTree(
                receiver_version="1.1.1",
                release_tag="receiver-v1.1.1",
                release_scope="receiver",
                ios_version="1.1.1",
                ios_build="40",
                batch_version="1.0.0",
            ),
            _ios_candidate(ios_version="1.1.0", ios_build="41"),
            "component versions must not regress from the baseline",
        ),
        (
            _baseline(),
            _ios_candidate(ios_build="38"),
            "component versions must not regress from the baseline",
        ),
        (
            _baseline(),
            _ios_candidate(ios_version="1.1.0", ios_build="39"),
            "ios scope must advance iOS Companion version or build",
        ),
        (
            _baseline(),
            _ios_candidate(ios_build="39"),
            "iOS component updates must advance the build number",
        ),
    ],
    ids=(
        "receiver-change",
        "batch-change",
        "marketing-regression",
        "build-regression",
        "unchanged-app",
        "marketing-without-build",
    ),
)
def test_ios_scope_rejects_invalid_component_transition(
    tmp_path: Path,
    baseline_tree: ReleaseTree,
    candidate: ReleaseTree,
    expected_error: str,
) -> None:
    # Given: a baseline and an invalid iOS-scoped component transition.
    repo = init_release_repo(tmp_path)
    write_release_tree(repo, baseline_tree)
    baseline = commit_release_tree(repo, "published baseline")
    write_release_tree(repo, candidate)
    candidate_commit = commit_release_tree(repo, "invalid iOS checkpoint")

    # When: release tooling validates the iOS checkpoint.
    completed = validate_transition(
        repo,
        tag=f"ios-v{candidate.ios_version}-build.{candidate.ios_build}",
        tag_target=candidate_commit,
        default_main=candidate_commit,
        baseline=baseline,
    )

    # Then: the specific invalid transition is rejected.
    assert completed.returncode == 1
    assert expected_error in completed.stderr


def test_ios_scope_rejects_receiver_release_tag(tmp_path: Path) -> None:
    # Given: a valid iOS-only component transition.
    repo = init_release_repo(tmp_path)
    write_release_tree(repo, _baseline())
    baseline = commit_release_tree(repo, "published receiver baseline")
    write_release_tree(repo, _ios_candidate())
    candidate = commit_release_tree(repo, "iOS source checkpoint")

    # When: the checkpoint is mislabeled with the compatible receiver tag.
    completed = validate_transition(
        repo,
        tag="receiver-v1.1.1",
        tag_target=candidate,
        default_main=candidate,
        baseline=baseline,
    )

    # Then: validation requires the exact iOS component-scoped tag.
    assert completed.returncode == 1
    assert "iOS release tag must be ios-v1.1.1-build.41" in completed.stderr

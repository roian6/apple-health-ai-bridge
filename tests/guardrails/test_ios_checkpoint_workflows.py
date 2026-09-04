from __future__ import annotations

from pathlib import Path

PYTHON_WORKFLOW = Path(".github/workflows/python.yml")
IOS_WORKFLOW = Path(".github/workflows/ios.yml")
RECEIVER_RELEASE_WORKFLOW = Path(".github/workflows/release.yml")
RELEASE_CRITERIA = Path(".github/release/criteria.md")


def test_ios_checkpoint_tags_run_pinned_transition_and_source_gates() -> None:
    python = PYTHON_WORKFLOW.read_text(encoding="utf-8")
    ios = IOS_WORKFLOW.read_text(encoding="utf-8")

    for workflow in (python, ios):
        assert '      - "ios-v*"' in workflow
        assert "permissions:\n  contents: read" in workflow
        assert "contents: write" not in workflow
        assert "environment: github-release" not in workflow
        assert "actions/upload-artifact" not in workflow
        assert "gh release" not in workflow

    for marker in (
        "EVENT_TAG_OBJECT_SHA: ${{ github.event.after }}",
        'git rev-parse "refs/tags/${GITHUB_REF_NAME}^{tag}"',
        'test "$tag_ref_sha" = "$event_tag_object_sha"',
        '.verification.verified == true and .verification.reason == "valid"',
        'expected_tagger_email="23256775+roian6"@"users.noreply.github.com"',
        'test "$tagger_email" = "$expected_tagger_email"',
        'test "$target_sha" = "$default_main_sha"',
        'baseline_sha="$(git rev-parse "${target_sha}^1")"',
        "uv run python scripts/release_tools.py validate",
        '--tag "$GITHUB_REF_NAME"',
        '--tag-target-commit "$target_sha"',
        '--default-main-commit "$default_main_sha"',
        '--baseline-commit "$baseline_sha"',
    ):
        assert marker in python

    assert "fetch-depth: 0" in python
    assert 'endswith("@users.noreply.github.com")' not in python
    assert "Run Swift package tests" in ios
    assert "Build unsigned iPhone simulator app" in ios
    assert "Build unsigned generic iPhone app" in ios
    assert "Build unsigned Public Documents QA simulator app" in ios
    assert "Build unsigned Public Documents QA generic iPhone app" in ios


def test_ios_checkpoint_tags_do_not_enter_receiver_release_publication() -> None:
    receiver = RECEIVER_RELEASE_WORKFLOW.read_text(encoding="utf-8")

    assert 'tags: ["receiver-v*"]' in receiver
    assert '"ios-v*"' not in receiver
    assert (
        'expected_tagger_email="23256775+roian6"@"users.noreply.github.com"' in receiver
    )
    assert 'test "$tagger_email" = "$expected_tagger_email"' in receiver
    assert 'endswith("@users.noreply.github.com")' not in receiver


def test_ios_checkpoint_policy_requires_read_only_checks_and_tag_protection() -> None:
    criteria = RELEASE_CRITERIA.read_text(encoding="utf-8")

    for marker in (
        "Python quality and package checks",
        "Swift tests and unsigned app builds",
        "Neither workflow may publish artifacts",
        "tag ruleset targeting `refs/tags/ios-v*`",
        "restricts updates and deletions",
        "every downstream TestFlight/App Store claim on HOLD",
    ):
        assert marker in criteria

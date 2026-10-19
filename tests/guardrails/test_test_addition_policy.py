from pathlib import Path


def test_contributor_policy_connects_behavior_changes_to_boundary_tests() -> None:
    # Given
    contributing = Path("CONTRIBUTING.md").read_text()
    checklist = Path(".github/pull_request_template.md").read_text()
    # When / Then
    assert "major functionality" in contributing
    assert "behavior-changing bug fixes" in contributing
    assert "failing" in contributing
    for path in (
        "tests/queries/test_date_boundaries.py",
        "tests/receiver/test_delivery_acceptance_failures.py",
        "ios/HealthBridgeCompanion/Tests/HealthBridgeCompanionCoreTests/DeliveryProtocolV1TamperTests.swift",
    ):
        assert path in contributing
        assert Path(path).is_file()
    assert "automated regression tests" in checklist


def test_future_release_policy_requires_source_bound_swift_analysis() -> None:
    # Given / When
    criteria = Path(".github/release/criteria.md").read_text()
    guide = Path("docs/maintainer-guide.md").read_text()
    # Then
    for document in (criteria, guide):
        assert "scripts/swift-analysis.sh" in document
        assert ".github/workflows/ios.yml" in document
        assert "exact source commit" in document

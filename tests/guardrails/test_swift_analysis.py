from pathlib import Path
from subprocess import run


def test_swift_analysis_is_required_in_existing_native_gate() -> None:
    # Given
    workflow = Path(".github/workflows/ios.yml").read_text()
    # When / Then
    assert "name: Swift tests and unsigned app builds" in workflow
    assert "bash scripts/swift-analysis.sh" in workflow
    assert "working-directory: ${{ github.workspace }}" in workflow
    assert "timeout-minutes: 10" in workflow
    assert "continue-on-error" not in workflow
    assert "swift test" in workflow
    assert workflow.count("CODE_SIGNING_REQUIRED=NO") == 4


def test_swift_analysis_policy_covers_all_production_components() -> None:
    # Given
    config = Path(".github/linters/swiftlint.yml").read_text()
    script = Path("scripts/swift-analysis.sh").read_text()
    # When / Then
    for scope in (
        "ios/HealthBridgeCompanion/App",
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore",
        "macos/HealthBridgeMailboxAckPublisher",
    ):
        assert scope in config
        assert scope in script
        assert list(Path(scope).rglob("*.swift"))
    assert "only_rules:" in config
    for rule in (
        "force_cast",
        "force_try",
        "duplicate_conditions",
        "identical_operands",
    ):
        assert f"  - {rule}\n" in config
    assert "baseline" not in config
    assert "excluded:" not in config
    assert "--strict" in script
    assert "--no-cache" in script
    assert "--allow-zero-lintable-files" not in script
    assert "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0" in script
    assert "9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8" in script


def test_swift_analysis_rejects_unexpected_arguments() -> None:
    # Given / When
    completed = run(
        ["bash", "scripts/swift-analysis.sh", "--skip"],
        capture_output=True,
        text=True,
        check=False,
    )
    # Then
    assert completed.returncode == 2
    assert "Usage:" in completed.stderr

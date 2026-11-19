from pathlib import Path

FORMS = {
    "bug_report.yml": ('labels: ["bug"]', "Reproduction", "Project version"),
    "feature_request.yml": (
        'labels: ["enhancement"]',
        "Data, privacy, and network impact",
        "App Review impact",
    ),
    "setup_feedback.yml": (
        'labels: ["question"]',
        "Setup flow",
        "Visible error",
    ),
}


def test_issue_intake_uses_required_structured_forms() -> None:
    template_dir = Path(".github/ISSUE_TEMPLATE")

    for stem in ("bug_report", "feature_request", "setup_feedback"):
        assert not (template_dir / f"{stem}.md").exists()

    for filename, required_markers in FORMS.items():
        text = (template_dir / filename).read_text(encoding="utf-8")
        assert text.startswith("name:")
        assert "description:" in text
        assert "body:" in text
        assert "type: checkboxes" in text
        assert "validations:" in text
        assert "required: true" in text
        assert "real HealthKit" in text
        assert "tokens" in text
        for marker in required_markers:
            assert marker in text


def test_security_support_and_ownership_routes_are_current() -> None:
    security = Path(".github/SECURITY.md").read_text(encoding="utf-8")
    support = Path(".github/SUPPORT.md").read_text(encoding="utf-8")
    codeowners = Path(".github/CODEOWNERS").read_text(encoding="utf-8")

    assert "developer-preview" not in security
    assert "stable source release is `receiver-v1.2.0`" in security
    assert "public TestFlight" in security
    assert "security/advisories/new" in security
    assert "healthbridge@chanhyo.dev" in security

    for marker in (
        "Private security reports",
        "Setup and product support",
        "Reproducible bugs",
        "Feature proposals",
        "healthbridge.chanhyo.dev/support",
        "security/advisories/new",
    ):
        assert marker in support

    for marker in (
        "* @roian6",
        "/ios/ @roian6",
        "/src/ @roian6",
        "/docs/ @roian6",
        "/.github/ @roian6",
    ):
        assert marker in codeowners

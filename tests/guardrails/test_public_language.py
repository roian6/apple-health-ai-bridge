import re
from pathlib import Path

FORBIDDEN_PHRASES = (
    "medical advice",
    "diagnosis",
    "treatment",
    "health-risk",
    "recovery-score",
    "readiness score",
)

FILES_TO_SCAN = (
    Path("AGENTS.md"),
    Path("README.md"),
    Path("docs/reference/batch-v1.md"),
    Path("docs/reference/sqlite-v1.md"),
    Path("docs/architecture.md"),
    Path(".github/release/criteria.md"),
    Path(".github/release/app-review-notes-template.md"),
    Path("CONTRIBUTING.md"),
    Path("fixtures/health_bridge_batch_v1.synthetic.json"),
    Path("fixtures/health_bridge_batch_v1.synthetic.ndjson"),
    Path("src/health_bridge/cli.py"),
    Path("src/health_bridge/cli_mcp.py"),
    Path("src/health_bridge/cli_query.py"),
    Path("src/health_bridge/mcp/server.py"),
    Path("src/health_bridge/mcp/tools.py"),
)
MARKDOWN_PATHS = tuple(Path.cwd().glob("*.md")) + tuple(
    path for root in (Path("docs"), Path(".github")) for path in root.rglob("*.md")
)
MARKDOWN_LINK_PATTERN = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def test_public_surfaces_avoid_forbidden_claim_phrases() -> None:
    # Given / When
    matches = [
        f"{path}:{phrase}"
        for path in FILES_TO_SCAN
        for phrase in FORBIDDEN_PHRASES
        if phrase in path.read_text(encoding="utf-8").lower()
    ]

    # Then
    assert matches == []


def test_connection_check_is_reachability_only_and_does_not_enqueue_a_test_batch() -> (
    None
):
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift",
    ).read_text(encoding="utf-8")
    check_body = view_model.split(
        "private func performCheckConnection() async {",
        maxsplit=1,
    )[1].split("func performPrimaryAction() async {", maxsplit=1)[0]

    assert "await checkReceiverHealth()" in check_body
    assert "sendConnectionTestBatch" not in check_body


def test_foreground_sync_exposes_cancel_without_deleting_durable_queue() -> None:
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift",
    ).read_text(encoding="utf-8")
    content_view = Path(
        "ios/HealthBridgeCompanion/App/ContentView.swift",
    ).read_text(encoding="utf-8")

    assert "func cancelCurrentForegroundAction() async" in view_model
    assert "activeTasks.forEach { $0.cancel() }" in view_model
    assert "Any already queued uploads remain" in view_model
    assert 'title: "Cancel"' in content_view


def test_sleep_delivery_obeys_fifo_head_network_attempt_policy() -> None:
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift",
    ).read_text(encoding="utf-8")
    sleep_body = view_model.split(
        "private func deliverPendingSleepTransition(",
        maxsplit=1,
    )[1].split("func syncSupportedQuantityMetrics() async", maxsplit=1)[0]

    policy_index = sleep_body.index("shouldAttemptNetworkForQueuedPayload")
    upload_index = sleep_body.index("uploadPendingOutbox(")
    assert "pendingItems.first?.id == outboxItemID" in sleep_body
    assert policy_index < upload_index


def test_release_qa_requires_clean_install_and_real_camera_qr_pairing() -> None:
    qa_text = Path("docs/qa/public-release-qa.md").read_text(encoding="utf-8")
    checklist_text = Path(
        ".github/release/testflight-checklist.md",
    ).read_text(encoding="utf-8")
    normalized_qa_text = " ".join(qa_text.split())
    normalized_checklist_text = " ".join(checklist_text.split())

    for required_text in (
        "does not count as fresh-user QA",
        "verify that the bundle is absent",
        "scan its QR with the iPhone Camera app",
        "do not relaunch or force-quit the app",
        "container-clean, keychain freshness unproven",
        "A Mac receiver is not substitute evidence",
    ):
        assert required_text in normalized_qa_text
    assert "devicectl --payload-url` was not used" in normalized_checklist_text
    assert "without Health collection, enqueue, or per-lane upload attempts" in (
        normalized_checklist_text
    )
    assert "within eight seconds" in normalized_checklist_text
    assert "validate-fresh-device-evidence.py" in normalized_checklist_text
    assert "zero duplicate device, credential, and record identities" in (
        normalized_checklist_text
    )


def test_quickstart_does_not_expose_raw_sql_tool() -> None:
    # Given
    readme_text = Path("README.md").read_text(encoding="utf-8")
    architecture_text = Path("docs/architecture.md").read_text(encoding="utf-8")

    # When
    quickstart_text = f"{readme_text}\n{architecture_text}"

    # Then
    assert "query_health_sql" not in quickstart_text


def test_guardrail_doc_marks_forbidden_language_examples() -> None:
    # Given
    guardrail_text = Path(
        ".github/policies/privacy-and-no-medical-claims.md",
    ).read_text(encoding="utf-8")

    # When
    example_section = guardrail_text.split(
        "## Forbidden-Language Guardrail Examples",
        maxsplit=1,
    )[1]

    # Then
    for phrase in FORBIDDEN_PHRASES:
        assert f'"{phrase}"' in example_section


def test_repository_has_no_unpublished_node_wrapper_surface() -> None:
    removed_paths = (
        "package.json",
        "package-lock.json",
        "tsconfig.json",
        "src-node",
        "test-node",
    )
    for relative_path in removed_paths:
        assert not (Path.cwd() / relative_path).exists()

    public_instructions = (
        Path("README.md"),
        Path("AGENTS.md"),
        Path("docs/setup.md"),
        Path(".github/release/criteria.md"),
    )
    for path in public_instructions:
        assert "npm" not in path.read_text(encoding="utf-8").lower()


def test_public_support_privacy_and_security_routes_are_explicit() -> None:
    # Given
    readme = Path("README.md").read_text()
    security = Path("SECURITY.md").read_text()
    setup_template = Path(".github/ISSUE_TEMPLATE/setup_feedback.yml").read_text(
        encoding="utf-8"
    )
    issue_config = Path(".github/ISSUE_TEMPLATE/config.yml")

    # Then
    for url in (
        "https://healthbridge.chanhyo.dev/",
        "https://healthbridge.chanhyo.dev/privacy",
        "https://healthbridge.chanhyo.dev/support",
    ):
        assert url in readme
    assert "Apple Health AI Bridge gives you a direct, self-hosted path" in readme
    assert "not affiliated with, endorsed by, or sponsored by Apple Inc." in readme
    assert (
        "https://github.com/roian6/apple-health-ai-bridge/security/advisories/new"
        in security
    )
    assert "healthbridge@chanhyo.dev" in security
    assert 'labels: ["question"]' in setup_template
    assert issue_config.is_file()
    config_text = issue_config.read_text()
    assert "blank_issues_enabled: false" in config_text
    assert (
        "github.com/roian6/apple-health-ai-bridge/security/advisories/new"
        in config_text
    )
    assert "healthbridge.chanhyo.dev/support" in config_text
    assert "healthbridge.chanhyo.dev/privacy" in security


def test_readme_makes_testflight_primary_without_exposing_maintainer_operations() -> (
    None
):
    readme = Path("README.md").read_text()
    setup_guide = Path("docs/setup.md").read_text()
    primary_navigation = readme.split("</div>", maxsplit=1)[0]
    docs_section = readme.split("## Documentation", maxsplit=1)[1]

    assert "Install the iPhone app" in primary_navigation
    assert "Install the iPhone beta" not in primary_navigation
    assert "docs/maintainers/" not in readme
    assert "App Review" not in docs_section
    assert "Public source preview" not in readme
    assert "may lag behind the latest GitHub release" not in readme
    assert "native Windows is not currently supported" in readme
    assert "native Windows is not currently supported" in setup_guide
    assert "Numeric LAN IPs are supported" in setup_guide
    assert "scutil --get LocalHostName" in setup_guide
    assert "Local Network permission alert may fail" in setup_guide
    assert "Allow LAN access" in setup_guide


def test_contributor_and_release_docs_match_ci_release_gates() -> None:
    agents = Path("AGENTS.md").read_text()
    contributing = Path("CONTRIBUTING.md").read_text()
    release_criteria = Path(".github/release/criteria.md").read_text()

    for text in (contributing, release_criteria):
        assert "-sdk iphonesimulator" in text
        assert "-sdk iphoneos" in text
        assert "CODE_SIGNING_ALLOWED=NO" in text

    assert "uv sync --all-extras --dev --locked" in contributing
    assert "public-release-audit.py --strict" in contributing
    for command in (
        "uv run bandit -r src -q",
        "uv run pip-audit --local --skip-editable",
    ):
        assert command in contributing
        assert command in agents
    assert "git diff --cached --check" in release_criteria
    assert "one-root" in release_criteria


def test_privacy_docs_explain_manifest_and_app_store_answers_together() -> None:
    review_template = Path(".github/release/app-review-notes-template.md").read_text()

    assert "PrivacyInfo.xcprivacy" in review_template
    assert "does not declare developer-collected data" in review_template
    assert "“Data Not Collected”" in review_template


def test_product_release_identity_is_1_0_0_build_14() -> None:
    pyproject = Path("pyproject.toml").read_text()
    package_init = Path("src/health_bridge/__init__.py").read_text()
    xcode_project = Path(
        "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
    ).read_text()
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    security = Path("SECURITY.md").read_text()

    assert 'version = "1.0.0"' in pyproject
    assert '__version__: Final = "1.0.0"' in package_init
    assert xcode_project.count("MARKETING_VERSION = 1.0.0;") == 2
    assert xcode_project.count("CURRENT_PROJECT_VERSION = 15;") == 2
    assert '?? "1.0.0"' in content_view
    assert '?? "15"' in content_view
    assert "pre-1.0" not in security


def test_public_docs_explain_safe_local_purge_without_claiming_health_deletion() -> (
    None
):
    readme = Path("README.md").read_text()
    setup = Path("docs/setup.md").read_text()

    for text in (readme, setup):
        assert "health-bridge receiver purge" in text
        assert "--confirm" in text
        assert "dry-run" in text
        assert "does not delete Apple Health data" in text


def test_public_docs_do_not_publish_an_unavailable_beta_surface() -> None:
    public_docs = "\n".join(
        path.read_text(encoding="utf-8") for path in MARKDOWN_PATHS
    ).lower()

    assert "public beta is not available" not in public_docs
    assert "before the first approved beta" not in public_docs
    assert "source preview" not in public_docs
    assert not Path("docs/testflight-beta.md").exists()


def test_public_markdown_relative_links_resolve() -> None:
    broken: list[str] = []
    for source in MARKDOWN_PATHS:
        text = source.read_text(encoding="utf-8")
        for match in MARKDOWN_LINK_PATTERN.finditer(text):
            raw_target = match.group(1)
            target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
            if (
                not target
                or target.startswith("#")
                or re.match(r"^[a-z][a-z0-9+.-]*:", target, re.IGNORECASE)
            ):
                continue
            path_text = target.split("#", maxsplit=1)[0]
            resolved = (
                Path.cwd() / path_text.lstrip("/")
                if path_text.startswith("/")
                else source.parent / path_text
            )
            if not resolved.exists():
                broken.append(f"{source}:{target}")

    assert broken == []

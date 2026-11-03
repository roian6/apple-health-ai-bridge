import json
import re
import tomllib
from html import unescape
from pathlib import Path
from typing import cast

from health_bridge import __version__

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
    Path(".github/CONTRIBUTING.md"),
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


def test_quickstart_does_not_expose_raw_sql_tool() -> None:
    # Given
    readme_text = Path("README.md").read_text(encoding="utf-8")
    architecture_text = Path("docs/architecture.md").read_text(encoding="utf-8")

    # When
    quickstart_text = f"{readme_text}\n{architecture_text}"

    # Then
    assert "query_health_sql" not in quickstart_text


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
    security = Path(".github/SECURITY.md").read_text()
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
    assert "<h1>Apple Health AI Bridge</h1>" in readme
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


def test_readme_uses_official_app_store_install_artwork() -> None:
    header = (
        Path("README.md").read_text(encoding="utf-8").split("</div>", maxsplit=1)[0]
    )
    target = "https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806"
    match = re.search(
        rf'<a href="{re.escape(target)}">\s*(<img\b[^>]*>)\s*</a>',
        header,
    )

    assert match is not None
    image = match.group(1)
    official_artwork = "https://developer.apple.com/assets/elements/badges/"
    official_artwork += "download-on-the-app-store.svg"
    assert f'src="{official_artwork}"' in image
    assert 'alt="Download on the App Store"' in image
    assert 'height="40"' in image


def test_readme_links_status_badges_to_their_public_sources() -> None:
    documents = "\n".join(
        Path(document).read_text(encoding="utf-8")
        for document in ("README.md", ".github/CONTRIBUTING.md")
    )
    repository = "roian6/apple-health-ai-bridge"
    expected_links = (
        (
            f"https://github.com/{repository}/releases",
            f"https://img.shields.io/github/v/release/{repository}?filter=receiver-v%2A",
        ),
        (
            f"https://github.com/{repository}/actions/workflows/python.yml",
            f"https://img.shields.io/github/actions/workflow/status/{repository}/python.yml?branch=main",
        ),
        (
            f"https://github.com/{repository}/actions/workflows/ios.yml",
            f"https://img.shields.io/github/actions/workflow/status/{repository}/ios.yml?branch=main",
        ),
        ("LICENSE", f"https://img.shields.io/github/license/{repository}?"),
        (
            f"https://glama.ai/mcp/servers/{repository}",
            f"https://glama.ai/mcp/servers/{repository}/badges/score.svg",
        ),
        (
            f"https://scorecard.dev/viewer/?uri=github.com/{repository}",
            f"https://api.scorecard.dev/projects/github.com/{repository}/badge",
        ),
    )
    for target, endpoint in expected_links:
        match = re.search(
            rf'<a href="{re.escape(target)}">\s*(<img\b[^>]*>)\s*</a>',
            documents,
        )
        assert match is not None, target
        image = unescape(match.group(1))
        assert endpoint in image


def test_package_metadata_connects_distribution_to_public_surfaces() -> None:
    with Path("pyproject.toml").open("rb") as handle:
        pyproject = cast("dict[str, object]", tomllib.load(handle))
    project = cast("dict[str, object]", pyproject["project"])

    assert project["name"] == "apple-health-ai-bridge"
    assert project["description"] == (
        "Open-source receiver and read-only CLI/MCP package for Apple Health AI Bridge."
    )
    assert project["scripts"] == {"health-bridge": "health_bridge.cli:run"}
    assert project["keywords"] == [
        "ai-agents",
        "apple-health",
        "healthkit",
        "local-first",
        "mcp",
    ]
    assert project["urls"] == {
        "Homepage": "https://healthbridge.chanhyo.dev/",
        "Documentation": (
            "https://github.com/roian6/apple-health-ai-bridge/tree/main/docs"
        ),
        "Source": "https://github.com/roian6/apple-health-ai-bridge",
        "Issues": "https://github.com/roian6/apple-health-ai-bridge/issues",
        "Releases": "https://github.com/roian6/apple-health-ai-bridge/releases",
    }
    server = Path("src/health_bridge/mcp/server.py").read_text(encoding="utf-8")
    assert '"serverInfo": {"name": "health-bridge"' in server


def test_readme_makes_app_store_primary_without_exposing_maintainer_operations() -> (
    None
):
    readme = Path("README.md").read_text()
    setup_guide = Path("docs/setup.md").read_text()
    primary_navigation = readme.split("</div>", maxsplit=1)[0]
    docs_section = readme.split("## Documentation", maxsplit=1)[1]

    app_store_url = "https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806"
    assert "Download on the App Store" in primary_navigation
    assert app_store_url in primary_navigation
    assert "Install the iPhone beta" not in primary_navigation
    assert "official TestFlight install page" not in readme
    assert "Download [the iPhone app from the App Store]" in readme
    assert "TestFlight" in setup_guide
    assert "docs/maintainers/" not in readme
    assert "App Review" not in docs_section
    assert "Public source preview" not in readme
    assert "may lag behind the latest GitHub release" not in readme
    assert "macOS or Linux computer" in readme
    install_source = r"git\+https://github\.com/roian6/apple-health-ai-bridge\.git"
    assert re.search(
        rf'uv tool install "{install_source}@receiver-v\d+\.\d+\.\d+"',
        setup_guide,
    )
    assert "native Windows is not currently supported" in setup_guide
    assert "Numeric LAN IPs are supported" in setup_guide
    assert "scutil --get LocalHostName" in setup_guide
    assert "Local Network permission alert may fail" in setup_guide
    assert "Allow LAN access" in setup_guide


def test_primary_onboarding_requires_a_real_remote_receiver_route() -> None:
    onboarding_paths = (
        Path("README.md"),
        Path("docs/setup.md"),
        Path("docs/pairing.md"),
        Path("docs/self-build.md"),
        Path("docs/agent-assisted-setup.md"),
    )
    onboarding_copy = "\n".join(
        path.read_text(encoding="utf-8") for path in onboarding_paths
    )
    setup_guide = Path("docs/setup.md").read_text(encoding="utf-8")

    assert "your-private-host.example" not in onboarding_copy
    assert "<phone-reachable-private-host>" not in onboarding_copy
    assert "The project does not issue this URL" in setup_guide
    assert "Already use Tailscale" in setup_guide
    assert "Agent-assisted private HTTPS ingress" in setup_guide
    assert "local-network-only route" in setup_guide
    assert "Do not expose port 8765 directly to the public internet" in setup_guide
    assert "If no suitable private route exists" in setup_guide
    agent_guide = Path("docs/agent-assisted-setup.md").read_text(encoding="utf-8")
    for safety_copy in (setup_guide, agent_guide):
        assert "must not create a provider account" in safety_copy
        assert "activate a paid plan" in safety_copy
        assert "incur charges" in safety_copy
        assert "explicit approval for each" in safety_copy
    assert "## Route C: Local-network-only fallback" in setup_guide
    assert setup_guide.index("## Route C: Local-network-only fallback") < (
        setup_guide.index("## Install and run core setup")
    )
    assert "--receiver-host 0.0.0.0" in setup_guide
    assert "--receiver-port 8765" in setup_guide

    for route_handoff in (
        Path("docs/agent-assisted-setup.md"),
        Path("docs/pairing.md"),
        Path("docs/self-build.md"),
    ):
        handoff_copy = route_handoff.read_text(encoding="utf-8")
        assert "Routes A and B use HTTPS" in handoff_copy
        assert (
            "Route C deliberately uses HTTP only on the same trusted LAN"
            in handoff_copy
        )

    for path, ordered_steps in (
        (
            Path("docs/agent-assisted-setup.md"),
            (
                "run the matching setup command",
                "approved service manager",
                "printed local health URL",
                "Open that exact phone-facing `/health` URL on the physical iPhone",
                "open the private setup page",
            ),
        ),
        (
            Path("docs/pairing.md"),
            (
                "run the route-specific `health-bridge setup` command",
                "approved service manager",
                "printed local health URL",
                "Open that exact phone-facing `/health` URL on the physical iPhone",
                "open the setup-generated pairing page",
            ),
        ),
        (
            Path("docs/self-build.md"),
            (
                "run exactly one setup command",
                "approved service manager",
                "printed local health URL",
                "Open that exact phone-facing `/health` URL on the physical iPhone",
                "setup-generated HTML",
            ),
        ),
    ):
        text = path.read_text(encoding="utf-8")
        positions = [text.index(step) for step in ordered_steps]
        assert positions == sorted(positions), path

    readme = Path("README.md").read_text(encoding="utf-8")
    route_language = "\n".join(
        (
            readme,
            setup_guide,
            Path("docs/architecture.md").read_text(encoding="utf-8"),
        )
    )
    assert "agent-managed private HTTPS ingress" not in route_language
    assert "agent-managed service plan" not in route_language

    assert "(docs/setup.md)" in readme
    assert "private HTTPS route" in readme
    ordered_steps = (
        "Choose one of the following routes",
        "Install and run core setup",
        "Start and verify the receiver",
        "Pair the iPhone",
    )
    positions = [setup_guide.index(step) for step in ordered_steps]
    assert positions == sorted(positions)


def test_setup_connects_an_existing_store_before_the_first_ai_question() -> None:
    setup = Path("docs/setup.md").read_text(encoding="utf-8")
    client_setup, first_question = setup.split("## Ask your first question", maxsplit=1)
    client_setup = client_setup.split(
        "## Connect an MCP client intentionally", maxsplit=1
    )[1]
    entries: list[str] = re.findall(r"```json\n(.*?)\n```", client_setup, re.DOTALL)

    assert len(entries) == 1
    descriptor = cast("dict[str, object]", json.loads(entries[0]))
    assert str(descriptor["command"]).endswith("health-bridge")
    assert descriptor["args"] == [
        "mcp",
        "start",
        "--db",
        "/absolute/path/to/health.sqlite",
    ]
    assert "command -v health-bridge" in client_setup
    assert "already paired" in client_setup
    assert "get_bridge_status" in first_question
    assert "list_synced_metrics" in first_question


def test_current_component_identities_are_explicit() -> None:
    pyproject = Path("pyproject.toml").read_text()
    package_init = Path("src/health_bridge/__init__.py").read_text()
    xcode_project = Path(
        "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
    ).read_text()
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    server_manifest = Path("server.json").read_text()
    security = Path(".github/SECURITY.md").read_text()

    assert f'version = "{__version__}"' in pyproject
    assert f'__version__: Final = "{__version__}"' in package_init
    assert f'"version": "{__version__}"' in server_manifest
    assert xcode_project.count("MARKETING_VERSION = 1.2.0;") == 2
    assert xcode_project.count("CURRENT_PROJECT_VERSION = 51;") == 2
    assert '?? "1.2.0"' in content_view
    assert '?? "51"' in content_view
    assert "pre-1.0" not in security


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

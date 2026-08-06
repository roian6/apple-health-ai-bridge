import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import cast

IOS_ROOT = Path("ios/HealthBridgeCompanion")
PROJECT = IOS_ROOT / "HealthBridgeCompanion.xcodeproj/project.pbxproj"
PRODUCTION_INFO = IOS_ROOT / "App/Info.plist"
HIDDEN_QA_ROOT = IOS_ROOT / "MailboxQA"
PUBLIC_QA_ROOT = IOS_ROOT / "PublicDocumentsQA"
HIDDEN_TARGET = "HealthBridgeCompanionMailboxQA"
PUBLIC_TARGET = "HealthBridgeCompanionPublicDocumentsQA"
PUBLIC_BUNDLE = "com.example.HealthBridgeCompanion.publicdocuments.mailboxqa"
PUBLIC_CONTAINER = f"iCloud.{PUBLIC_BUNDLE}"
PUBLIC_CONTAINER_TOKEN = "HEALTH_BRIDGE_PUBLIC_DOCUMENTS_CONTAINER"
PUBLIC_DISPLAY_NAME = "HealthBridge Mailbox Public Documents QA"
PUBLIC_SCHEME = "HealthBridgeCompanionPublicDocumentsQA"
PUBLIC_URL_SCHEME = "healthbridgeqa-public-documents"
PUBLIC_OUTBOX_ROOT = "HealthBridgeMailboxPublicDocumentsQA"
BUILD_GUARD = Path("scripts/ios-mailbox-qa-build.sh")
INSTALL_GUARD = Path("scripts/ios-mailbox-qa-install.sh")


def _source_members(project: str, target_name: str) -> set[str]:
    target_pattern = "".join(
        (
            rf"/\* {target_name} \*/ = \{{\n\s+isa = PBXNativeTarget;",
            r"(?P<body>.*?)\n\s+\};",
        )
    )
    target = re.search(
        target_pattern,
        project,
        re.DOTALL,
    )
    assert target is not None
    build_phases = re.search(
        r"buildPhases = \((?P<body>.*?)\);",
        target.group("body"),
        re.DOTALL,
    )
    assert build_phases is not None
    source_phase_ids = cast(
        "list[str]",
        re.findall(
            r"([A-F0-9]{24}) /\* [^*]*Sources[^*]* \*/",
            build_phases.group("body"),
        ),
    )
    assert source_phase_ids
    members: set[str] = set()
    for source_phase_id in source_phase_ids:
        phase_pattern = "".join(
            (
                rf"{source_phase_id} /\* [^*]*Sources[^*]* \*/ = ",
                r"\{isa = PBXSourcesBuildPhase;.*?files = \((?P<body>.*?)\); ",
                r"runOnlyForDeploymentPostprocessing",
            )
        )
        phase = re.search(
            phase_pattern,
            project,
            re.DOTALL,
        )
        assert phase is not None
        members.update(
            re.findall(
                r"/\* ([A-Za-z0-9]+\.swift) in Sources \*/",
                phase.group("body"),
            )
        )
    return members


def test_public_documents_build_and_install_guards_use_exact_lane_tuple() -> None:
    build = BUILD_GUARD.read_text(encoding="utf-8")
    install = INSTALL_GUARD.read_text(encoding="utf-8")

    for guard in (build, install):
        for required in (
            "HEALTH_BRIDGE_QA_SCHEME_NAME",
            "HEALTH_BRIDGE_QA_TARGET_NAME",
            "HEALTH_BRIDGE_QA_URL_SCHEME",
            PUBLIC_SCHEME,
            PUBLIC_TARGET,
            PUBLIC_URL_SCHEME,
            PUBLIC_OUTBOX_ROOT,
        ):
            assert required in guard
        assert (
            '"$scheme|$target_name|$url_scheme|$HEALTH_BRIDGE_QA_OUTBOX_ROOT"' in guard
        )

    assert '"HEALTH_BRIDGE_QA_SCHEME_NAME=$scheme"' in build
    assert '"HEALTH_BRIDGE_QA_TARGET_NAME=$target_name"' in build
    assert "HEALTH_BRIDGE_QA_PROVISIONING_PROFILE_SPECIFIER" in build
    assert 'code_sign_style="${HEALTH_BRIDGE_QA_CODE_SIGN_STYLE:-Automatic}"' in build
    assert '"CODE_SIGN_STYLE=$code_sign_style"' in build
    assert '"PROVISIONING_PROFILE_SPECIFIER=$profile_specifier"' in build
    assert 'test "$code_sign_style" = "Manual"' in build
    assert 'test -n "$profile_specifier"' in build
    assert 'qa_app="$archive_path/Products/Applications/$target_name.app"' in build
    assert 'test "$embedded_scheme" = "$url_scheme"' in install
    for guard in (build, install):
        assert '--scheme-name "$scheme"' in guard
        assert '--target-name "$target_name"' in guard


def test_public_documents_target_has_exact_distinct_qa_identities() -> None:
    project = PROJECT.read_text(encoding="utf-8")

    # When: the public-documents QA sibling target is inspected.
    # Then: every app-owned identity is exact, neutral, and distinct.
    assert project.count(f"PRODUCT_BUNDLE_IDENTIFIER = {PUBLIC_BUNDLE};") == 2
    container_setting_prefix = "HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER = "
    container_setting = (
        f'{container_setting_prefix}"iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)";'
    )
    assert container_setting in project
    preprocessor_setting_prefix = "INFOPLIST_PREPROCESSOR_DEFINITIONS = "
    public_container_definition_prefix = '"HEALTH_BRIDGE_PUBLIC_DOCUMENTS_CONTAINER='
    public_container_definition_suffix = (
        '$(HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER)";'
    )
    public_container_definition = (
        f"{public_container_definition_prefix}{public_container_definition_suffix}"
    )
    preprocessor_setting = f"{preprocessor_setting_prefix}{public_container_definition}"
    assert project.count(preprocessor_setting) == 2
    assert (
        project.count(
            "HEALTH_BRIDGE_QA_OUTBOX_ROOT = HealthBridgeMailboxPublicDocumentsQA;"
        )
        == 2
    )
    assert (
        f"PRODUCT_BUNDLE_IDENTIFIER = {PUBLIC_BUNDLE};"
        not in project[: project.index(f"/* {PUBLIC_TARGET} */")]
    )
    assert PUBLIC_BUNDLE != "com.example.HealthBridgeCompanion.mailboxqa"
    assert PUBLIC_CONTAINER != "iCloud.com.example.HealthBridgeCompanion.mailboxqa"


def test_production_seal_target_guard_accepts_public_lane_and_rejects_mixed_lane() -> (
    None
):
    command = [
        sys.executable,
        "scripts/production-identity-seal.py",
        "assert-target",
        "--project",
        str(PROJECT),
        "--scheme-name",
        PUBLIC_SCHEME,
        "--target-name",
        PUBLIC_TARGET,
    ]
    public = subprocess.run(command, check=False, capture_output=True, text=True)
    assert public.returncode == 0, public.stdout + public.stderr

    mixed = subprocess.run(
        [*command[:-1], HIDDEN_TARGET],
        check=False,
        capture_output=True,
        text=True,
    )
    assert mixed.returncode != 0


def test_public_documents_info_plist_declares_public_document_scope() -> None:
    # Given: a dedicated plist for the user-visible QA container.
    info_path = PUBLIC_QA_ROOT / "Info.plist"
    info = cast("dict[str, object]", plistlib.loads(info_path.read_bytes()))
    containers = cast(
        "dict[str, object]",
        info["NSUbiquitousContainers"],
    )
    container_key = PUBLIC_CONTAINER_TOKEN
    assert set(containers) == {container_key}
    public_container = cast("dict[str, object]", containers[container_key])
    url_types = cast("list[dict[str, object]]", info["CFBundleURLTypes"])
    url_schemes = cast("list[str]", url_types[0]["CFBundleURLSchemes"])

    # When / Then: the machine-consumed public document scope is exact.
    assert public_container == {
        "NSUbiquitousContainerIsDocumentScopePublic": True,
        "NSUbiquitousContainerName": PUBLIC_DISPLAY_NAME,
        "NSUbiquitousContainerSupportedFolderLevels": "Any",
    }
    assert info["HealthBridgeQAICloudContainerIdentifier"] == (
        "$(HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER)"
    )
    assert url_schemes == ["healthbridgeqa-public-documents"]


def test_public_documents_target_reuses_only_hidden_qa_source_closure() -> None:
    # Given: both isolated targets are declared in one project.
    project = PROJECT.read_text(encoding="utf-8")

    # When: their explicit source phases are resolved.
    hidden_members = _source_members(project, "HealthBridgeCompanionMailboxQA")
    public_members = _source_members(project, PUBLIC_TARGET)

    # Then: the public lane reuses the synthetic harness without production code.
    assert public_members == hidden_members
    assert {
        "FileOutbox.swift",
        "MailboxQAHarness.swift",
        "MailboxQASyntheticPayload.swift",
        "MailboxTransport.swift",
    } <= public_members
    assert not any(
        forbidden in member
        for member in public_members
        for forbidden in ("HealthKit", "ReceiverClient", "ViewModel", "Settings")
    )
    assert "HealthBridgeCompanionApp.swift" not in public_members


def test_production_is_public_documents_while_hidden_qa_remains_non_public() -> None:
    # Given: production and the prior hidden mailbox QA lane.
    production = cast("dict[str, object]", plistlib.loads(PRODUCTION_INFO.read_bytes()))
    hidden = (HIDDEN_QA_ROOT / "Info.plist").read_text(encoding="utf-8")
    hidden_entitlements = (
        HIDDEN_QA_ROOT / "HealthBridgeCompanionMailboxQA.entitlements"
    ).read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")

    # When / Then: production alone exposes its app-owned mailbox in Files.
    containers = cast("dict[str, object]", production["NSUbiquitousContainers"])
    assert set(containers) == {"HEALTH_BRIDGE_PRODUCTION_DOCUMENTS_CONTAINER"}
    public_container = cast(
        "dict[str, object]",
        containers["HEALTH_BRIDGE_PRODUCTION_DOCUMENTS_CONTAINER"],
    )
    assert public_container == {
        "NSUbiquitousContainerIsDocumentScopePublic": True,
        "NSUbiquitousContainerName": "HealthBridge Mailbox",
        "NSUbiquitousContainerSupportedFolderLevels": "Any",
    }
    assert project.count("INFOPLIST_PREPROCESS = YES;") >= 4
    production_definition = (
        'INFOPLIST_PREPROCESSOR_DEFINITIONS = "'
        "HEALTH_BRIDGE_PRODUCTION_DOCUMENTS_CONTAINER="
        '$(HEALTH_BRIDGE_ICLOUD_CONTAINER_IDENTIFIER)";'
    )
    assert project.count(production_definition) == 2
    for content in (hidden, hidden_entitlements):
        assert "NSUbiquitousContainerIsDocumentScopePublic" not in content
        assert "NSUbiquitousContainerSupportedFolderLevels" not in content


def test_production_runtime_is_wired_without_qa_controls() -> None:
    project = PROJECT.read_text(encoding="utf-8")
    production_members = _source_members(project, "HealthBridgeCompanion")
    production_identity = (
        IOS_ROOT / "Sources/HealthBridgeCompanionCore/HealthBridgeAppIdentity.swift"
    ).read_text(encoding="utf-8")
    runtime = (
        IOS_ROOT / "Sources/HealthBridgeCompanionCore/ProductionMailboxDelivery.swift"
    ).read_text(encoding="utf-8")
    components = (
        IOS_ROOT / "Sources/HealthBridgeCompanionCore/ProductionMailboxComponents.swift"
    ).read_text(encoding="utf-8")
    production_runtime = runtime + components

    assert "ProductionMailboxDelivery.swift" in production_members
    assert "ProductionMailboxComponents.swift" in production_members
    assert "mailboxKeychainServiceName" in production_identity
    assert "MailboxLocatorV1.resolve" in production_runtime
    assert "OutboxDeliveryCoordinator" in production_runtime
    for forbidden in (
        "HEALTH_BRIDGE_MAILBOX_QA",
        "MailboxQASyntheticPayload",
        "HealthBridgeMailboxPublicDocumentsQA",
        "healthbridgeqa-public-documents",
        ".mailboxqa",
    ):
        assert forbidden not in production_runtime


def test_production_mailbox_ui_is_truthful_about_readiness_and_holds() -> None:
    view_model = (IOS_ROOT / "App/HealthBridgeCompanionViewModel.swift").read_text(
        encoding="utf-8"
    )
    content = (IOS_ROOT / "App/ContentView.swift").read_text(encoding="utf-8")

    assert "Mailbox folder is ready on this iPhone" in view_model
    assert "Receiver delivery has not been verified" in view_model
    assert "Receiver rejected" in view_model
    assert "signed ACK" not in view_model
    assert 'viewModel.usesMailboxTransport ? "Check Mailbox Folder"' in content
    assert "pending secure delivery item(s)" in content


def test_public_documents_entitlements_are_cloud_documents_only() -> None:
    # Given: the new target's dedicated entitlements.
    entitlements = (
        PUBLIC_QA_ROOT / "HealthBridgeCompanionPublicDocumentsQA.entitlements"
    ).read_text(encoding="utf-8")

    # When / Then: only the exact parameterized QA container is exposed.
    assert (
        entitlements.count(
            "<string>$(HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER)</string>"
        )
        == 2
    )
    assert "<string>CloudDocuments</string>" in entitlements
    assert "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)" in entitlements
    assert "com.apple.developer.healthkit" not in entitlements
    assert "CloudKit" not in entitlements


def test_shared_qa_configuration_has_exact_public_documents_profile() -> None:
    # Given: both QA targets compile the shared fail-closed configuration loader.
    configuration = (HIDDEN_QA_ROOT / "MailboxQAConfiguration.swift").read_text(
        encoding="utf-8"
    )

    # When / Then: the new lane's machine-consumed identity profile is exact.
    for required in (
        '".publicdocuments.mailboxqa"',
        '"HealthBridgeMailboxPublicDocumentsQA"',
        '"healthbridgeqa-public-documents"',
        '"HealthBridgeCompanionPublicDocumentsQA"',
    ):
        assert required in configuration
    assert '"HealthBridgeMailboxQA"' in configuration
    assert '"healthbridgeqa"' in configuration
    assert '"HealthBridgeCompanionMailboxQA"' in configuration


def test_shared_qa_invocation_validates_the_configured_url_scheme() -> None:
    invocation = (HIDDEN_QA_ROOT / "MailboxQAInvocation.swift").read_text(
        encoding="utf-8"
    )

    assert 'url.scheme == "healthbridgeqa"' not in invocation
    assert "url.scheme == configuration.urlScheme" in invocation

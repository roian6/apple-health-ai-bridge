import hashlib
import re
from pathlib import Path

from health_bridge.mailbox_qa.scenario_contract import SYNTHETIC_PAYLOAD_SHA256
from health_bridge.receiver.batch_acceptance import (
    BatchAcceptanceCore,
    BatchAcceptanceInput,
    PreparedBatch,
)
from health_bridge.receiver.tokens import ReceiverTokenPrincipal

IOS_ROOT = Path("ios/HealthBridgeCompanion")
PROJECT = IOS_ROOT / "HealthBridgeCompanion.xcodeproj/project.pbxproj"
QA_ROOT = IOS_ROOT / "MailboxQA"
PRODUCTION_ENTITLEMENTS = IOS_ROOT / "App/HealthBridgeCompanion.entitlements"
BUILD_GUARD = Path("scripts/ios-mailbox-qa-build.sh")
INSTALL_GUARD = Path("scripts/ios-mailbox-qa-install.sh")
ROLLBACK_GUARD = Path("scripts/ios-mailbox-qa-rollback.sh")
CURATED_CORE = {
    "DeliveryProtocolV1.swift",
    "DeliveryProtocolV1Ack.swift",
    "DeliveryProtocolV1AckAuthentication.swift",
    "DeliveryProtocolV1Canonical.swift",
    "DeliveryProtocolV1Envelope.swift",
    "DeliveryProtocolV1Models.swift",
    "DeliveryProtocolV1Outbound.swift",
    "DeliveryProtocolV1Payload.swift",
    "BatchV1.swift",
    "FileOutbox.swift",
    "HealthTypeRegistry.swift",
    "MailboxAckClassifier.swift",
    "MailboxAckDeletion.swift",
    "MailboxAckFileReader.swift",
    "MailboxAckModels.swift",
    "MailboxAckOutboxLookup.swift",
    "MailboxAckScanner.swift",
    "MailboxAckWindowReader.swift",
    "MailboxAckWindowSupport.swift",
    "MailboxAtomicPublisher.swift",
    "MailboxEnvelopeSealer.swift",
    "MailboxKeyIdentity.swift",
    "MailboxLayoutV1.swift",
    "MailboxLocatorV1.swift",
    "MailboxQADeliveryTransportTypes.swift",
    "MailboxQAHarness.swift",
    "MailboxQAHarnessDependencies.swift",
    "MailboxQAModels.swift",
    "MailboxQAReport.swift",
    "MailboxQASyntheticPayload.swift",
    "MailboxRegularFileReader.swift",
    "MailboxTransport.swift",
    "MailboxTransportModels.swift",
    "OutboxDeliveryCoordinator.swift",
    "OutboxDeliveryCoordinatorAck.swift",
    "OutboxDeliveryFinalizers.swift",
    "OutboxDeliveryModels.swift",
}
QA_APP_SOURCES = {
    "MailboxQAApp.swift",
    "MailboxQAConfiguration.swift",
    "MailboxQAInvocation.swift",
}


def test_qa_synthetic_payload_is_receiver_principal_compatible() -> None:
    # Given: the exact synthetic batch compiled into the isolated QA app.
    source = (
        IOS_ROOT / "Sources/HealthBridgeCompanionCore/MailboxQASyntheticPayload.swift"
    ).read_text(encoding="utf-8")
    match = re.search(r'"""\n\s*(\{.*\})\n\s*"""\.utf8', source)
    assert match is not None

    # When: the production receiver binds it to a paired installation principal.
    prepared = BatchAcceptanceCore.prepare(
        BatchAcceptanceInput(
            exact_bytes=match.group(1).encode(),
            principal=ReceiverTokenPrincipal(installation_id_hash="a" * 64),
        )
    )

    # Then: the QA fixture reaches ingestion instead of a terminal principal ACK.
    assert isinstance(prepared, PreparedBatch)
    assert {source.source_key for source in prepared.batch.sources} == {
        f"apple_health.phone.{('a' * 64)}"
    }
    assert {sample.source_key for sample in prepared.batch.samples} == {
        f"apple_health.phone.{('a' * 64)}"
    }


def test_qa_target_has_distinct_identity_and_no_healthkit_entitlement() -> None:
    # Given: the production app and dedicated QA app project definitions.
    project = PROJECT.read_text(encoding="utf-8")
    entitlements = (QA_ROOT / "HealthBridgeCompanionMailboxQA.entitlements").read_text(
        encoding="utf-8"
    )
    info = (QA_ROOT / "Info.plist").read_text(encoding="utf-8")

    # When: their target identities and capabilities are inspected.
    qa_target = project[project.index("/* HealthBridgeCompanionMailboxQA */") :]

    # Then: the QA app has only distinct, parameterized QA identities.
    assert (
        "PRODUCT_BUNDLE_IDENTIFIER = com.example.HealthBridgeCompanion.mailboxqa;"
        in qa_target
    )
    assert "HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" in qa_target
    assert "$(HEALTH_BRIDGE_QA_DISPLAY_IDENTITY)" in info
    assert "<string>healthbridgeqa</string>" in info
    assert "HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" in project
    assert "keychain-access-groups" in entitlements
    assert "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)" in entitlements
    assert "com.apple.developer.healthkit" not in entitlements
    assert "HealthKit" not in info
    assert "healthbridge</string>" not in info


def test_production_target_cannot_compile_or_activate_qa_harness() -> None:
    # Given: explicit source membership for both app targets.
    project = PROJECT.read_text(encoding="utf-8")
    phase_marker = (
        "B0193229F5D633567D732C36 /* Sources */ = {isa = PBXSourcesBuildPhase;"
    )
    production_phase = project[
        project.index(phase_marker) : project.index(
            "/* End PBXSourcesBuildPhase section */"
        )
    ]
    qa_source = (QA_ROOT / "MailboxQAApp.swift").read_text(encoding="utf-8")
    invocation_source = (QA_ROOT / "MailboxQAInvocation.swift").read_text(
        encoding="utf-8"
    )

    # When: QA-only symbols and the production entry point are compared.
    # Then: neither target can bootstrap the other's runtime.
    assert "MailboxQAApp.swift in Sources" not in production_phase
    assert "HealthBridgeCompanionViewModel" not in qa_source
    assert "HealthKit" not in qa_source
    assert "MailboxQAInvocation" in qa_source
    assert "first == 100 && second >= 64 && second <= 127" in invocation_source
    assert "HEALTH_BRIDGE_MAILBOX_QA" in project
    assert "HEALTH_BRIDGE_MAILBOX_QA" not in (
        IOS_ROOT / "App/HealthBridgeCompanionApp.swift"
    ).read_text(encoding="utf-8")


def test_qa_target_compiles_exact_healthkit_free_mailbox_harness_closure() -> None:
    # Given: the dedicated QA target's explicit source build phase.
    project = PROJECT.read_text(encoding="utf-8")
    marker = "A25174000000000000000001 /* Sources */ = {isa = PBXSourcesBuildPhase;"
    phase = project[
        project.index(marker) : project.index(
            "runOnlyForDeploymentPostprocessing = 0;",
            project.index(marker),
        )
    ]

    # When: source comments are resolved to the curated transitive closure.
    members: set[str] = set(
        re.findall(r"/\* ([A-Za-z0-9]+\.swift) in Sources \*/", phase)
    )

    # Then: exact-byte mailbox code is present and production/HealthKit code is absent.
    assert members == CURATED_CORE | QA_APP_SOURCES
    assert not any(
        forbidden in member
        for member in members
        for forbidden in (
            "HealthKit",
            "ReceiverClient",
            "Background",
            "Settings",
            "ViewModel",
        )
    )
    assert "HealthBridgeCompanionApp.swift" not in members


def test_qa_entitlements_and_outbox_never_fall_back_to_production() -> None:
    # Given: QA and production entitlement/configuration files.
    qa_entitlements = (
        QA_ROOT / "HealthBridgeCompanionMailboxQA.entitlements"
    ).read_text(encoding="utf-8")
    production_entitlements = PRODUCTION_ENTITLEMENTS.read_text(encoding="utf-8")
    configuration = (QA_ROOT / "MailboxQAConfiguration.swift").read_text(
        encoding="utf-8"
    )

    # When: identity inputs are missing or compared.
    # Then: every QA boundary is explicit and fail-closed.
    assert "$(HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER)" in qa_entitlements
    assert "$(HEALTH_BRIDGE_ICLOUD_CONTAINER_IDENTIFIER)" not in qa_entitlements
    assert qa_entitlements != production_entitlements
    for required in (
        "missingBundleIdentity",
        "missingContainerIdentity",
        "missingKeychainIdentity",
        "missingOutboxRoot",
        "identityMismatch",
        "productionIdentityRejected",
    ):
        assert required in configuration
    assert "HealthBridgeMailboxQA" in configuration
    assert "HealthBridgeMailbox/v1" not in configuration


def test_build_and_install_require_exact_embedded_qa_identities() -> None:
    # Given: the Mac-only QA archive and install guard scripts.
    build = BUILD_GUARD.read_text(encoding="utf-8")
    install = INSTALL_GUARD.read_text(encoding="utf-8")
    rollback = ROLLBACK_GUARD.read_text(encoding="utf-8")

    # When: identity, signing, archive, and embedded-app checks are inspected.
    # Then: every value is explicit and the archive cannot be written into Git.
    for required in (
        "HEALTH_BRIDGE_QA_DEVELOPMENT_TEAM",
        "HEALTH_BRIDGE_QA_DISPLAY_IDENTITY",
        "HEALTH_BRIDGE_QA_PROVENANCE_PATH",
        "HEALTH_BRIDGE_PRODUCTION_SEAL",
        "HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256",
        "production-identity-seal.py",
        '"iCloud.$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER"',
        '"$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER.mailboxqa"',
        '"$root_dir"/*) exit 3',
        "assert-target",
        "HEALTH_BRIDGE_QA_ALLOW_PROVISIONING_UPDATES",
        "-allowProvisioningUpdates",
        "security find-certificate",
        "PASS qa_target_validated",
        "PASS production_seal_validated",
        "HOLD external prerequisite unavailable",
        ".venv/bin/python",
        "uv sync --frozen",
        'project_file="$project/project.pbxproj"',
        '--project "$project_file"',
    ):
        assert required in build
    assert "--extract-certificates" not in build
    for required in (
        "HEALTH_BRIDGE_PRODUCTION_SEAL",
        "HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256",
        "codesign --verify --deep --strict",
        "codesign -d --entitlements",
        "device info apps",
        "HealthBridgeQASourceCommit",
        "HealthBridgeQASchemeName",
        "HealthBridgeQATargetName",
        "HealthBridgeQAICloudContainerIdentifier",
        "HealthBridgeQAKeychainService",
        "HealthBridgeQAOutboxRoot",
        "HEALTH_BRIDGE_QA_DISPLAY_IDENTITY",
        "HEALTH_BRIDGE_QA_PROVENANCE_PATH",
        "HEALTH_BRIDGE_QA_INSTALL_OBSERVATION",
        "CFBundleURLSchemes:0",
        'test "$embedded_scheme" = "$url_scheme"',
        "production-identity-seal.py",
        "security find-certificate",
        "PASS qa_embedded_identity",
        "PASS qa_signed_identity",
        "PASS qa_device_inventory",
        "PASS qa_install_preflight",
        "PASS qa_install_confirmed",
        'uv sync --frozen --directory "$root_dir"',
    ):
        assert required in install
    assert "--extract-certificates" not in install
    assert "DEVELOPMENT_TEAM = " not in build
    assert "com.example.HealthBridgeCompanion" not in build
    assert "com.example.HealthBridgeCompanion" not in install
    for required in (
        "HEALTH_BRIDGE_PRODUCTION_SEAL",
        "HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256",
        "HEALTH_BRIDGE_QA_CLEANUP_OUTPUT",
        "confirm-rollback",
        "device uninstall app",
        "device info apps",
    ):
        assert required in rollback
    assert "com.example.HealthBridgeCompanion" not in rollback


def test_build_guard_supports_disabled_provisioning_updates_on_macos_bash() -> None:
    # Given: provisioning updates are intentionally disabled for an immutable QA build.
    build = BUILD_GUARD.read_text(encoding="utf-8")

    # When / Then: the invoked command array is always non-empty under Bash 3.2 nounset.
    assert "xcodebuild_command=(xcodebuild)" in build
    assert "xcodebuild_command+=(-allowProvisioningUpdates)" in build
    assert 'if ! "${xcodebuild_command[@]}"' in build
    assert "provisioning_args" not in build


def test_qa_cloud_probe_never_blocks_the_main_actor() -> None:
    # Given: the signed QA UI probes the app-owned iCloud container on launch.
    source = (QA_ROOT / "MailboxQAApp.swift").read_text(encoding="utf-8")

    # When / Then: the potentially blocking ubiquity lookup runs off-main while
    # UI state and durable status updates remain on the main actor.
    assert "Task.detached(priority: .utility)" in source
    assert "await refreshCloudProbe()" in source
    assert "private func refreshCloudProbe() async" in source
    detached = source[source.index("Task.detached(priority: .utility)") :]
    assert "forUbiquityContainerIdentifier" in detached


def test_qa_app_observes_real_protected_data_lock_and_unlock_events() -> None:
    source = (QA_ROOT / "MailboxQAApp.swift").read_text(encoding="utf-8")
    invocation = (QA_ROOT / "MailboxQAInvocation.swift").read_text(encoding="utf-8")

    assert "UIApplication.protectedDataWillBecomeUnavailableNotification" in source
    assert "UIApplication.protectedDataDidBecomeAvailableNotification" in source
    assert "observeProtectedData(available: false)" in source
    assert "observeProtectedData(available: true)" in source
    assert "func observeProtectedData(available: Bool) async" in invocation
    assert (
        "try harness(configuration: configuration).observeProtectedData(" in invocation
    )
    assert "available: available" in invocation


def test_m3_contract_hash_matches_the_exact_swift_qa_payload() -> None:
    source = (
        IOS_ROOT / "Sources/HealthBridgeCompanionCore/MailboxQASyntheticPayload.swift"
    ).read_text(encoding="utf-8")
    match = re.search(r'"""\n(?P<body>.*?)\n\s*"""\.utf8', source, re.DOTALL)
    assert match is not None
    lines = match.group("body").splitlines()
    indentation = min(
        len(line) - len(line.lstrip(" ")) for line in lines if line.strip()
    )
    payload = "\n".join(line[indentation:] for line in lines).encode()

    assert hashlib.sha256(payload).hexdigest() == SYNTHETIC_PAYLOAD_SHA256

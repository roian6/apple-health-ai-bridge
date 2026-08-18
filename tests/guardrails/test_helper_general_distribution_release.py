from __future__ import annotations

import json
import plistlib
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import cast

ROOT = Path(__file__).parents[2]
MANIFEST_BUILDER = ROOT / "scripts/stage_helper_manifest.py"
STAGING_SCRIPT = ROOT / "scripts/stage-mailbox-helper-release.sh"
HELPER_ENTITLEMENTS = (
    ROOT
    / "macos"
    / "HealthBridgeMailboxAckPublisher"
    / "HealthBridgeMailboxAckPublisher.entitlements"
)
MACOS_VERIFIER = ROOT / "scripts/verify_helper_distribution.py"
POLICY_CHECKER = ROOT / "scripts/check_helper_distribution_policy.py"
PUBLISH_WORKFLOW = ROOT / ".github/workflows/publish-release.yml"


def _identity_value(*parts: str) -> str:
    return "".join(parts)


BUNDLE_ID = _identity_value("dev.", "chanhyo.", "healthbridge", ".mailbox.ackpublisher")
CONTAINER_ID = _identity_value("iCloud.", "dev.", "chanhyo.", "healthbridge")
COMPONENT = "HealthBridgeMailboxAckPublisher"
VERSION = "1.1.1"
TEAM_ID = _identity_value("Y3BJ", "C2J65L")
AUTHORITY = f"Developer ID Application: Chanhyo Jung ({TEAM_ID})"
WRONG_TEAM_ID = _identity_value("A1B2", "C3D4E5")


def _write_archive(path: Path) -> None:
    info = plistlib.dumps(
        {
            "CFBundleExecutable": COMPONENT,
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": VERSION,
            "CFBundleVersion": "1",
            "HealthBridgeExpectedBundleIdentifier": BUNDLE_ID,
            "HealthBridgeICloudContainerIdentifier": CONTAINER_ID,
        }
    )
    members = {
        f"{COMPONENT}.app/Contents/Info.plist": info,
        f"{COMPONENT}.app/Contents/MacOS/{COMPONENT}": b"signed",
        f"{COMPONENT}.app/Contents/_CodeSignature/CodeResources": b"signature",
    }
    with zipfile.ZipFile(path, "w") as archive:
        for name, content in members.items():
            member = zipfile.ZipInfo(name)
            member.create_system = 3
            member.external_attr = (0o100700 if "/MacOS/" in name else 0o100600) << 16
            archive.writestr(member, content)


def test_manifest_builder_emits_v2_general_distribution_identity(
    tmp_path: Path,
) -> None:
    archive = tmp_path / f"{COMPONENT}-{VERSION}.zip"
    manifest = tmp_path / f"{COMPONENT}-{VERSION}.manifest.json"
    _write_archive(archive)

    completed = subprocess.run(
        [
            sys.executable,
            str(MANIFEST_BUILDER),
            "--archive",
            str(archive),
            "--output",
            str(manifest),
            "--tag",
            f"receiver-v{VERSION}",
            "--tag-object",
            "1" * 40,
            "--commit",
            "2" * 40,
            "--tree",
            "3" * 40,
            "--source-tree",
            "4" * 40,
            "--bundle-identifier",
            BUNDLE_ID,
            "--icloud-container-identifier",
            CONTAINER_ID,
            "--version",
            VERSION,
            "--build",
            "1",
            "--signing-authority",
            AUTHORITY,
            "--team-identifier",
            TEAM_ID,
            "--notary-submission-id",
            "12345678-1234-4234-8234-123456789abc",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr
    payload = cast("dict[str, object]", json.loads(manifest.read_text()))
    distribution = cast("dict[str, object]", payload["distribution"])
    assert payload["schema_version"] == 2
    assert distribution["signing_authority"] == AUTHORITY
    assert distribution["team_identifier"] == TEAM_ID
    profile = cast("dict[str, object]", distribution["provisioning_profile"])
    assert profile["provisions_all_devices"] is True
    assert profile["icloud_container_environment"] == "Production"
    assert "provisioned_devices" not in profile
    assert distribution["secure_timestamp"] is True
    assert distribution["hardened_runtime"] is True
    assert distribution["stapled_ticket"] is True
    assert distribution["gatekeeper_assessment"] == "accepted"


def test_manifest_builder_rejects_self_consistent_wrong_publisher_policy(
    tmp_path: Path,
) -> None:
    archive = tmp_path / f"{COMPONENT}-{VERSION}.zip"
    manifest = tmp_path / f"{COMPONENT}-{VERSION}.manifest.json"
    _write_archive(archive)

    completed = subprocess.run(
        [
            sys.executable,
            str(MANIFEST_BUILDER),
            "--archive",
            str(archive),
            "--output",
            str(manifest),
            "--tag",
            f"receiver-v{VERSION}",
            "--tag-object",
            "1" * 40,
            "--commit",
            "2" * 40,
            "--tree",
            "3" * 40,
            "--source-tree",
            "4" * 40,
            "--bundle-identifier",
            "com.example.HealthBridgeMailboxAckPublisher",
            "--icloud-container-identifier",
            "iCloud.com.example.HealthBridgeMailboxAckPublisher",
            "--version",
            VERSION,
            "--build",
            "1",
            "--signing-authority",
            f"Developer ID Application: Example Health Bridge ({WRONG_TEAM_ID})",
            "--team-identifier",
            WRONG_TEAM_ID,
            "--notary-submission-id",
            "12345678-1234-4234-8234-123456789abc",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode != 0
    assert not manifest.exists()


def test_owner_staging_notarizes_and_staples_before_final_archive() -> None:
    body = STAGING_SCRIPT.read_text(encoding="utf-8")

    for marker in (
        "--notary-keychain-profile",
        "Developer ID Application:",
        "ProvisionsAllDevices",
        "ProvisionedDevices",
        "com.apple.developer.icloud-container-environment",
        "Timestamp=",
        "/usr/bin/security cms -D",
        "xcrun notarytool submit",
        "--keychain-profile",
        "--wait",
        '"Accepted"',
        "xcrun stapler staple",
        "xcrun stapler validate",
        "spctl --assess --type execute",
        "trap cleanup EXIT",
        "scripts/check_helper_distribution_policy.py",
    ):
        assert marker in body
    assert body.index("notarytool submit") < body.index("stapler staple")
    assert body.index("check_helper_distribution_policy.py") < body.index("xcodebuild")
    assert 'ARCHS="arm64 x86_64"' in body
    assert "ONLY_ACTIVE_ARCH=NO" in body
    assert "OTHER_CODE_SIGN_FLAGS=--timestamp=none" in body
    assert "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO" in body
    assert "secure_timestamp_codesign() {" in body
    assert body.count("secure_timestamp_codesign") == 2
    assert "--timestamp=http://timestamp.apple.com/ts01" in body
    assert '--entitlements "$canonical_entitlements"' in body
    assert (
        "Set :com.apple.developer.icloud-container-identifiers:0 "
        "${configured_container_id}"
    ) in body
    assert (
        "Set :com.apple.developer.ubiquity-container-identifiers:0 "
        "${configured_container_id}"
    ) in body
    assert "--preserve-metadata=identifier,requirements,entitlements" not in body
    forbidden_debug_entitlement = (
        "Print :com.apple.security.get-task-allow' "
        '"$private_build_root/entitlements.plist"'
    )
    assert forbidden_debug_entitlement in body
    assert body.index(forbidden_debug_entitlement) < body.index("notarytool submit")
    assert (
        body.index("OTHER_CODE_SIGN_FLAGS=--timestamp=none")
        < body.index('secure_timestamp_codesign "$app"')
        < body.index('codesign -d --verbose=4 "$app"')
    )
    assert "http:/$()/timestamp.apple.com/ts01" not in body
    executable = '"$app/Contents/MacOS/HealthBridgeMailboxAckPublisher"'
    architecture_check = '/usr/bin/lipo -archs "$helper_executable"'
    assert f"helper_executable={executable}" in body
    assert architecture_check in body
    assert '"$helper_architectures" != "arm64 x86_64"' in body
    assert '"$helper_architectures" != "x86_64 arm64"' in body
    assert body.index("xcodebuild") < body.index(architecture_check)
    final_archive = '--keepParent "$app" "$archive"'
    assert body.index("stapler staple") < body.index(final_archive)
    assert body.count("require_secure_timestamp") == 3
    assert body.count("require_hardened_runtime") == 3
    assert '"$profile_icloud_services" != "*"' in body
    assert "^Timestamp=.+$" not in body
    assert "grep -Eqi '^flags=.*runtime'" not in body
    assert 'echo "archive sha256:' in body
    assert 'echo "manifest sha256:' in body
    for secret_surface in (
        "--apple-id",
        "--password",
        "--issuer",
        "--key-id",
        "set -x",
    ):
        assert secret_surface not in body
    assert POLICY_CHECKER.is_file()


def test_owner_staging_accepts_real_codesign_runtime_metadata(tmp_path: Path) -> None:
    body = STAGING_SCRIPT.read_text(encoding="utf-8")
    marker = "require_hardened_runtime() {"
    assert marker in body
    start = body.index(marker)
    end = body.index("\n}\n", start) + len("\n}\n")
    function = body[start:end]
    script = f'{function}\nrequire_hardened_runtime "$1"\n'
    metadata = tmp_path / "codesign.txt"

    runtime_prefix = "CodeDirectory v=20500 size=253 flags=0x10000(runtime)"
    runtime_suffix = "hashes=2+2 location=embedded"
    _ = metadata.write_text(f"{runtime_prefix} {runtime_suffix}\n", encoding="utf-8")
    accepted = subprocess.run(
        ["bash", "-c", script, "runtime-gate", str(metadata)],
        check=False,
    )
    assert accepted.returncode == 0

    for rejected_line in (
        "CodeDirectory v=20500 flags=0x0(none) hashes=2+2\n",
        "Executable Segment flags=0x1\n",
        "Authority=Developer ID Application: Example\n",
    ):
        _ = metadata.write_text(rejected_line, encoding="utf-8")
        rejected = subprocess.run(
            ["bash", "-c", script, "runtime-gate", str(metadata)],
            check=False,
        )
        assert rejected.returncode != 0


def test_helper_entitlements_pin_production_icloud_environment() -> None:
    entitlements = cast(
        "dict[str, object]", plistlib.loads(HELPER_ENTITLEMENTS.read_bytes())
    )
    assert (
        entitlements["com.apple.developer.icloud-container-environment"] == "Production"
    )


def test_publish_requires_clean_macos_distribution_gate() -> None:
    workflow = PUBLISH_WORKFLOW.read_text(encoding="utf-8")
    verifier = MACOS_VERIFIER.read_text(encoding="utf-8")

    assert "verify_helper_on_macos:" in workflow
    assert "runs-on: macos-" in workflow
    assert "needs: verify_helper_on_macos" in workflow
    assert "Download exact bound draft helper assets" in workflow
    assert "scripts/verify_helper_distribution.py" in workflow
    assert "scripts/release_tools.py verify-helper" in workflow
    assert "helper_manifest_sha256:" in workflow
    assert (
        workflow.count(
            "EXPECTED_HELPER_MANIFEST_SHA256: ${{ inputs.helper_manifest_sha256 }}"
        )
        == 2
    )
    assert (
        workflow.count('[[ "$EXPECTED_HELPER_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]')
        == 2
    )
    assert workflow.count("--helper-manifest-sha256") == 5
    assert workflow.count('test "$actual_manifest_sha256" =') == 2
    assert "ditto -x -k" in workflow
    extracted_executable = (
        'helper_executable="$RUNNER_TEMP/helper-app/'
        "HealthBridgeMailboxAckPublisher.app/Contents/MacOS/"
        'HealthBridgeMailboxAckPublisher"'
    )
    architecture_check = '/usr/bin/lipo -archs "$helper_executable"'
    assert extracted_executable in workflow
    assert architecture_check in workflow
    assert '"$helper_architectures" != "arm64 x86_64"' in workflow
    assert '"$helper_architectures" != "x86_64 arm64"' in workflow
    assert workflow.index("ditto -x -k") < workflow.index(extracted_executable)
    assert workflow.index(extracted_executable) < workflow.index(architecture_check)
    assert workflow.index(architecture_check) < workflow.index(
        "scripts/verify_helper_distribution.py"
    )
    assert "verify_macos_release_distribution(" in verifier
    assert "gh release create" not in workflow
    assert "--clobber" not in workflow
    assert MACOS_VERIFIER.is_file()

from __future__ import annotations

import hashlib
import json
import plistlib
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import cast

ROOT = Path(__file__).parents[2]
RELEASE_TOOL = ROOT / "scripts/release_tools.py"
TAGGED_WORKFLOW = ROOT / ".github/workflows/release.yml"
CONTINUATION_WORKFLOW = ROOT / ".github/workflows/publish-release.yml"
STAGING_SCRIPT = ROOT / "scripts/stage-mailbox-helper-release.sh"


def _identity_value(*parts: str) -> str:
    return "".join(parts)


def _run_release_tool(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(RELEASE_TOOL), *args],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def _helper_verification_args(
    dist: Path,
    *,
    helper_sha256: str,
    manifest_sha256: str,
) -> tuple[str, ...]:
    return (
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
        "--helper-sha256",
        helper_sha256,
        "--helper-manifest-sha256",
        manifest_sha256,
    )


def test_helper_verification_rejects_malformed_expected_manifest_digest(
    tmp_path: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()

    completed = _run_release_tool(
        "verify-helper",
        *_helper_verification_args(
            dist,
            helper_sha256="0" * 64,
            manifest_sha256="INVALID",
        ),
    )

    assert completed.returncode != 0
    assert "expected helper manifest digest must be lowercase SHA-256" in (
        completed.stderr
    )


def test_helper_verification_rejects_manifest_digest_mismatch(
    tmp_path: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    manifest = dist / "HealthBridgeMailboxAckPublisher-1.1.1.manifest.json"
    _ = manifest.write_bytes(b"synthetic helper manifest")

    completed = _run_release_tool(
        "verify-helper",
        *_helper_verification_args(
            dist,
            helper_sha256="0" * 64,
            manifest_sha256="0" * 64,
        ),
    )

    assert completed.returncode != 0
    assert "helper manifest digest does not match continuation input" in (
        completed.stderr
    )


def test_release_metadata_binds_expected_exact_source_helper(tmp_path: Path) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    _ = (dist / "apple_health_ai_bridge-1.1.1-py3-none-any.whl").write_bytes(
        b"wheel fixture"
    )
    _ = (dist / "apple_health_ai_bridge-1.1.1.tar.gz").write_bytes(b"sdist fixture")
    output = dist / "release-metadata.json"

    completed = _run_release_tool(
        "manifest",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
        "--output",
        str(output),
    )

    assert completed.returncode == 0, completed.stderr
    payload = cast("dict[str, object]", json.loads(output.read_text()))
    helper = cast("dict[str, object]", payload["macos_mailbox_ack_helper"])
    source = cast("dict[str, object]", helper["source"])
    assert helper == {
        "archive_filename": "HealthBridgeMailboxAckPublisher-1.1.1.zip",
        "build": "1",
        "component": "HealthBridgeMailboxAckPublisher",
        "manifest_filename": ("HealthBridgeMailboxAckPublisher-1.1.1.manifest.json"),
        "source": source,
        "version": "1.1.1",
    }
    assert source["path"] == "macos/HealthBridgeMailboxAckPublisher"
    assert isinstance(source["git_tree"], str)
    assert len(source["git_tree"]) == 40


def test_final_checksums_bind_helper_digest_and_exact_asset_set(tmp_path: Path) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.1.1-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.1.1.tar.gz"
    _ = wheel.write_bytes(b"wheel fixture")
    _ = sdist.write_bytes(b"sdist fixture")
    metadata = dist / "release-metadata.json"
    created = _run_release_tool(
        "manifest",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
        "--output",
        str(metadata),
    )
    assert created.returncode == 0, created.stderr
    release_metadata = cast("dict[str, object]", json.loads(metadata.read_text()))
    helper_contract = cast(
        "dict[str, object]", release_metadata["macos_mailbox_ack_helper"]
    )
    source = cast("dict[str, str]", helper_contract["source"])
    archive = dist / "HealthBridgeMailboxAckPublisher-1.1.1.zip"
    bundle_identifier = _identity_value(
        "dev.", "chanhyo.", "healthbridge", ".mailbox.ackpublisher"
    )
    container_identifier = _identity_value(
        "iCloud.", "dev.", "chanhyo.", "healthbridge"
    )
    info = plistlib.dumps(
        {
            "CFBundleExecutable": "HealthBridgeMailboxAckPublisher",
            "CFBundleIdentifier": bundle_identifier,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.1.1",
            "CFBundleVersion": "1",
            "HealthBridgeExpectedBundleIdentifier": bundle_identifier,
            "HealthBridgeICloudContainerIdentifier": container_identifier,
        }
    )
    with zipfile.ZipFile(archive, "w") as package:
        package.writestr(
            "HealthBridgeMailboxAckPublisher.app/Contents/Info.plist", info
        )
        package.writestr(
            (
                Path("HealthBridgeMailboxAckPublisher.app/Contents/MacOS")
                / "HealthBridgeMailboxAckPublisher"
            ).as_posix(),
            b"synthetic executable",
        )
        package.writestr(
            "HealthBridgeMailboxAckPublisher.app/Contents/_CodeSignature/CodeResources",
            b"synthetic signature",
        )
    helper_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    helper_manifest = dist / ("HealthBridgeMailboxAckPublisher-1.1.1.manifest.json")
    approved_signer = _identity_value("Y3BJ", "C2J65L")
    _ = helper_manifest.write_text(
        json.dumps(
            {
                "artifact": {
                    "bytes": archive.stat().st_size,
                    "filename": archive.name,
                    "sha256": helper_digest,
                },
                "bundle": {
                    "build": "1",
                    "identifier": bundle_identifier,
                    "icloud_container_identifier": container_identifier,
                    "version": "1.1.1",
                },
                "component": "HealthBridgeMailboxAckPublisher",
                "release": {
                    "commit": "1" * 40,
                    "tag": "receiver-v1.1.1",
                    "tag_object": "3" * 40,
                    "tree": "2" * 40,
                },
                "schema_id": "health_bridge.mailbox_ack_helper.release.v2",
                "schema_version": 2,
                "distribution": {
                    "signing_authority": (
                        f"Developer ID Application: Chanhyo Jung ({approved_signer})"
                    ),
                    "team_identifier": approved_signer,
                    "provisioning_profile": {
                        "provisions_all_devices": True,
                        "application_identifier": (
                            f"{approved_signer}.{bundle_identifier}"
                        ),
                        "team_identifier": approved_signer,
                        "icloud_container_environment": "Production",
                        "icloud_container_identifiers": [container_identifier],
                        "ubiquity_container_identifiers": [container_identifier],
                    },
                    "secure_timestamp": True,
                    "hardened_runtime": True,
                    "notarization": {
                        "status": "Accepted",
                        "submission_id": ("12345678-1234-4234-8234-123456789abc"),
                    },
                    "stapled_ticket": True,
                    "gatekeeper_assessment": "accepted",
                },
                "source": {
                    "git_tree": source["git_tree"],
                    "path": "macos/HealthBridgeMailboxAckPublisher",
                },
            },
            sort_keys=True,
        ),
        encoding="utf-8",
    )
    common = _helper_verification_args(
        dist,
        helper_sha256=helper_digest,
        manifest_sha256=hashlib.sha256(helper_manifest.read_bytes()).hexdigest(),
    )

    verified = _run_release_tool("verify-helper", *common)
    finalized = _run_release_tool(
        "final-checksums",
        *common,
        "--output",
        str(dist / "SHA256SUMS"),
    )

    assert verified.returncode == 0, verified.stderr
    assert finalized.returncode == 0, finalized.stderr
    names = [
        line.split("  ", 1)[1]
        for line in (dist / "SHA256SUMS").read_text().splitlines()
    ]
    assert names == sorted(
        [
            archive.name,
            helper_manifest.name,
            wheel.name,
            sdist.name,
            metadata.name,
        ]
    )


def test_owner_staging_script_is_exact_source_and_public_safe() -> None:
    body = STAGING_SCRIPT.read_text(encoding="utf-8")
    manifest_builder = (ROOT / "scripts/stage_helper_manifest.py").read_text(
        encoding="utf-8"
    )

    for marker in (
        "git verify-tag",
        "git status --porcelain",
        "xcodebuild",
        "-xcconfig",
        "codesign --verify --strict --deep",
        "--entitlements :-",
        "runtime",
        "HealthBridgeMailboxAckPublisher-",
    ):
        assert marker in body
    for marker in (
        "health_bridge.mailbox_ack_helper.release.v2",
        '"source"',
        '"git_tree"',
    ):
        assert marker in manifest_builder
    assert "DEVELOPMENT_TEAM =" not in body
    assert "iCloud.dev." not in body
    assert "curl" not in body


def test_tagged_release_stages_attested_draft_without_publishing() -> None:
    workflow = TAGGED_WORKFLOW.read_text(encoding="utf-8")

    assert "Create and verify helper-pending draft release" in workflow
    assert "actions/attest-build-provenance@" in workflow
    assert "--draft" in workflow
    assert "--draft=false" not in workflow
    assert "HealthBridgeMailboxAckPublisher" in workflow
    assert "helper-pending" in workflow
    assert "Existing published release" in workflow


def test_manual_continuation_is_bound_and_never_replaces_published_release() -> None:
    workflow = CONTINUATION_WORKFLOW.read_text(encoding="utf-8")

    for marker in (
        "workflow_dispatch:",
        "draft_release_id:",
        "tag:",
        "helper_sha256:",
        "helper_manifest_sha256:",
        "tag_object_sha",
        "target_commit_sha",
        "tree_sha",
        "default_branch",
        "verification.verified == true",
        "draft == true",
        "published_at == null",
        "verify-helper",
        "final-checksums",
        "sha256sum --check --strict SHA256SUMS",
        "actions/attest-build-provenance@",
        "--draft=false",
        "verify-final-published",
    ):
        assert marker in workflow
    assert "gh release create" not in workflow
    assert "curl" not in workflow
    assert workflow.count("--clobber") == 0
    run_lines: list[str] = []
    in_run_block = False
    for line in workflow.splitlines():
        if line == "        run: |":
            in_run_block = True
            continue
        if in_run_block and line and not line.startswith("          "):
            in_run_block = False
        if in_run_block:
            run_lines.append(line)
    assert "${{ steps.bind.outputs." not in "\n".join(run_lines)
    for variable in (
        "PINNED_TAG_OBJECT_SHA",
        "PINNED_TARGET_COMMIT_SHA",
        "PINNED_TREE_SHA",
        "EXPECTED_HELPER_MANIFEST_SHA256",
    ):
        assert variable in workflow

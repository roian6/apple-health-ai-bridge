from __future__ import annotations

import importlib.util
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Protocol, cast
from xml.etree import ElementTree as ET

if TYPE_CHECKING:
    from collections.abc import Iterable
    from types import ModuleType

    import pytest

INFO_PLIST = Path("ios/HealthBridgeCompanion/App/Info.plist")
ENTITLEMENTS_PLIST = Path(
    "ios/HealthBridgeCompanion/App/HealthBridgeCompanion.entitlements"
)
PRIVACY_MANIFEST = Path("ios/HealthBridgeCompanion/App/PrivacyInfo.xcprivacy")
XCODE_PROJECT = Path(
    "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
)
HEALTHKIT_CATALOG = Path(
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/HealthKitReadTypeCatalog.swift"
)
IOS_SWIFT_SOURCES = tuple(Path("ios/HealthBridgeCompanion").rglob("*.swift"))
TERMINAL_TRANSITION_HELPER = (
    "private func performTerminalConnectionTransitionWhileHoldingRequestGate<Result>("
)


class PublicReleaseAuditModule(Protocol):
    LOCAL_DENYLIST_FILES: tuple[Path, ...]
    STRICT_DEFINITION_FILES: set[str]
    PUBLIC_SURFACE_FILES: set[str]

    def scan_markers(self, paths: list[Path]) -> list[str]: ...

    def scan_strict_blockers(self, paths: Iterable[Path]) -> list[str]: ...

    def git_tracked_files(self) -> list[Path]: ...


def _load_public_release_audit() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "public_release_audit_test",
        "scripts/public-release-audit.py",
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["public_release_audit_test"] = module
    spec.loader.exec_module(module)
    return module


def _parse_plist_value(element: ET.Element) -> object:
    if element.tag == "true":
        return True
    if element.tag == "false":
        return False
    if element.tag == "string":
        return element.text or ""
    if element.tag == "dict":
        return _parse_plist_dict(element)
    if element.tag == "array":
        return [_parse_plist_value(child) for child in element]
    return element.text or ""


def _parse_plist_dict(dict_element: ET.Element) -> dict[str, object]:
    children = list(dict_element)
    parsed: dict[str, object] = {}
    index = 0
    while index < len(children):
        key_element = children[index]
        value_element = children[index + 1]
        assert key_element.tag == "key"
        parsed[key_element.text or ""] = _parse_plist_value(value_element)
        index += 2
    return parsed


def _info_plist() -> dict[str, object]:
    return _parse_plist(INFO_PLIST)


def _privacy_manifest() -> dict[str, object]:
    return _parse_plist(PRIVACY_MANIFEST)


def _parse_plist(path: Path) -> dict[str, object]:
    root = ET.parse(path).getroot()  # noqa: S314 - trusted repo-local plist fixture
    dict_element = root.find("dict")
    assert dict_element is not None
    return _parse_plist_dict(dict_element)


def _string_key_dict(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    raw = cast("dict[object, object]", value)
    parsed: dict[str, object] = {}
    for key, item in raw.items():
        assert isinstance(key, str)
        parsed[key] = item
    return parsed


def _activity_basics_literal(policy: str) -> str:
    match = re.search(
        r"activityBasicsTypeCodes:\s*\[String\]\s*=\s*\[(.*?)\]",
        policy,
        flags=re.DOTALL,
    )
    assert match is not None
    return match.group(1)


def test_public_docs_do_not_claim_external_schema_clone() -> None:
    public_paths = [
        Path("README.md"),
        Path("AGENTS.md"),
        Path("CONTRIBUTING.md"),
        Path("SECURITY.md"),
        Path("CONTRIBUTING.md"),
        *Path("docs").rglob("*.md"),
    ]
    forbidden_markers = (
        "dogfood",
        "Tail" + "scale IP",
    )
    offenders = [
        f"{path}:{marker}"
        for path in public_paths
        for marker in forbidden_markers
        if marker in path.read_text()
    ]
    assert offenders == []


def test_public_release_guardrails_do_not_embed_private_literal_shapes() -> None:
    guardrail_paths = (
        Path("scripts/public-release-audit.py"),
        Path("tests/guardrails/test_ios_app_privacy.py"),
    )
    guardrail_text = "\n".join(path.read_text() for path in guardrail_paths)
    forbidden_patterns = (
        re.compile(r"\b100\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"),
        re.compile(r"\b[0-9A-F]{8}-[0-9A-F]{16}\b"),
        re.compile(r"\b\d{1,3},\d{3}\b"),
    )
    offenders = [
        pattern.pattern
        for pattern in forbidden_patterns
        if pattern.search(guardrail_text)
    ]
    assert offenders == []


def test_release_criteria_requires_pinned_all_history_gitleaks_gate() -> None:
    criteria = Path(".github/release/criteria.md").read_text()
    assert "gitleaks" in criteria.lower()
    assert "--all" in criteria
    assert "both `checks` and `build-and-test`" in criteria.lower()


def test_public_release_audit_supports_gitignored_local_denylist() -> None:
    audit_text = Path("scripts/public-release-audit.py").read_text()
    assert ".public-release-denylist.local" in audit_text


def test_public_release_audit_redacts_local_denylist_hits_in_all_tracked_files(
    tmp_path: Path,
) -> None:
    # Given
    private_literal = "PRIVATE_VALUE_FOR_LOCAL_DENYLIST_TEST"
    denylist = tmp_path / "denylist.local"
    _ = denylist.write_text(f"{private_literal}\n")
    public_doc = tmp_path / "README.md"
    _ = public_doc.write_text(f"normal text {private_literal}\n")
    definition_file = tmp_path / "scripts" / "public-release-audit.py"
    definition_file.parent.mkdir()
    _ = definition_file.write_text(f"guardrail text {private_literal}\n")
    audit = cast(
        "PublicReleaseAuditModule",
        cast("object", _load_public_release_audit()),
    )
    audit.LOCAL_DENYLIST_FILES = (denylist,)
    audit.STRICT_DEFINITION_FILES = {definition_file.as_posix()}
    audit.PUBLIC_SURFACE_FILES = {public_doc.as_posix()}

    # When
    blockers = audit.scan_strict_blockers([public_doc, definition_file])
    blocker_text = "\n".join(blockers)

    # Then
    assert len(blockers) == 2
    assert public_doc.as_posix() in blocker_text
    assert definition_file.as_posix() in blocker_text
    assert "local-denylist" in blocker_text
    assert "[REDACTED local denylist match]" in blocker_text
    assert private_literal not in blocker_text


def test_public_release_audit_scans_definition_files_for_global_credentials(
    tmp_path: Path,
) -> None:
    # Given
    definition_file = tmp_path / "scripts" / "public-release-audit.py"
    definition_file.parent.mkdir()
    credential = "hb_" + ("Z" * 40)
    _ = definition_file.write_text(f"accidental tracked value: {credential}\n")
    audit = cast(
        "PublicReleaseAuditModule",
        cast("object", _load_public_release_audit()),
    )
    audit.STRICT_DEFINITION_FILES = {definition_file.as_posix()}

    # When
    blockers = audit.scan_strict_blockers([definition_file])
    blocker_text = "\n".join(blockers)

    # Then
    assert "literal-device-credential" in blocker_text
    assert credential not in blocker_text


def test_public_release_audit_blocks_bare_account_bundle_literals(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule",
        cast("object", _load_public_release_audit()),
    )
    bundle = ".".join(("dev", "private-owner", "bridge"))  # noqa: FLY002
    fixture = tmp_path / "provenance.txt"
    _ = fixture.write_text(f"source bundle: {bundle}\n")
    canonical = tmp_path / "canonical.txt"
    _ = canonical.write_text("dev.healthbridge.companion\n")
    suffixed = tmp_path / "suffixed.txt"
    _ = suffixed.write_text("dev.healthbridge.companion" + ".private\n")

    blockers = audit.scan_strict_blockers([fixture])
    canonical_blockers = audit.scan_strict_blockers([canonical])
    suffixed_blockers = audit.scan_strict_blockers([suffixed])
    blocker_text = "\n".join(blockers)

    assert "non-neutral-bundle-literal" in blocker_text
    assert bundle not in blocker_text
    assert canonical_blockers == []
    assert any("non-neutral-bundle-literal" in item for item in suffixed_blockers)


def test_public_release_audit_limits_cgnat_detection_to_rfc6598(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule",
        cast("object", _load_public_release_audit()),
    )
    outside = tmp_path / "public.txt"
    _ = outside.write_text(
        ".".join(("100", "63", "255", "255"))  # noqa: FLY002
        + "\n"
        + ".".join(("100", "128", "0", "1"))  # noqa: FLY002
        + "\n"
    )
    inside = tmp_path / "private.txt"
    _ = inside.write_text(
        ".".join(("100", "64", "0", "1"))  # noqa: FLY002
        + "\n"
        + ".".join(("100", "127", "255", "254"))  # noqa: FLY002
        + "\n"
    )
    definition_outside = tmp_path / "scripts" / "public-release-audit.py"
    definition_outside.parent.mkdir()
    _ = definition_outside.write_text(outside.read_text())
    definition_inside = tmp_path / "tests" / "guardrails" / "audit-definition.py"
    definition_inside.parent.mkdir(parents=True)
    _ = definition_inside.write_text(inside.read_text())
    audit.STRICT_DEFINITION_FILES = {
        definition_outside.as_posix(),
        definition_inside.as_posix(),
    }

    assert audit.scan_strict_blockers([outside, definition_outside]) == []
    blockers = audit.scan_strict_blockers([inside, definition_inside])
    assert sum("private-receiver-address" in item for item in blockers) == 4


def test_public_release_audit_blocks_account_linked_identifiers_including_definitions(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule",
        cast("object", _load_public_release_audit()),
    )
    private_ip = ".".join(("192", "168", "7", "9"))  # noqa: FLY002
    user_path = (
        "/" + "/".join(("Users", "release-owner", "project")) + "/"  # noqa: FLY002
    )
    email = "@".join(("release-owner", "account.invalid"))  # noqa: FLY002
    team = "".join(("A1B2", "C3D4E5"))  # noqa: FLY002
    bundle = ".".join(("dev", "release-owner", "bridge"))  # noqa: FLY002
    definition_file = tmp_path / "scripts" / "public-release-audit.py"
    definition_file.parent.mkdir()
    _ = definition_file.write_text(
        "\n".join(
            (
                private_ip,
                user_path,
                email,
                f"DEVELOPMENT_TEAM = {team};",
                f"PRODUCT_BUNDLE_IDENTIFIER = {bundle};",
            )
        )
    )
    audit.STRICT_DEFINITION_FILES = {definition_file.as_posix()}

    blockers = audit.scan_strict_blockers([definition_file])
    blocker_text = "\n".join(blockers)

    assert "private-rfc1918-address" in blocker_text
    assert "private-user-home-path" in blocker_text
    assert "account-linked-email" in blocker_text
    assert "non-neutral-team-context" in blocker_text
    assert "non-neutral-bundle-literal" in blocker_text
    assert private_ip not in blocker_text
    assert user_path not in blocker_text
    assert email not in blocker_text


def test_public_release_audit_blocks_signing_contexts_and_pairing_credentials(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule",
        cast("object", _load_public_release_audit()),
    )
    team = "".join(("A1B2", "C3D4E5"))  # noqa: FLY002
    invitation_code = "-".join(("QWERT", "YUPAS", "DFGHK"))  # noqa: FLY002
    invitation_secret = "hbi_" + ("R" * 43)
    prefixed_live_secret = "hbi_synthetic_secret" + ("R" * 32)
    device_secret = "hb_" + ("S" * 43)
    prefixed_device_secret = "hb_test_secret" + ("S" * 32)
    content = "\n".join(
        (
            f"TEAM_ID={team}",
            f'"team_id": "{team}"',
            f'sourceTeamIdentifier: "{team}"',
            f"Apple Team ID: {team}",
            "<key>com.apple.developer.team-identifier</key>",
            f"<string> {team} </string>",
            f"invitation_code: {invitation_code}",
            f"invitation_secret: {invitation_secret}",
            f"prefixed_invitation_secret: {prefixed_live_secret}",
            f"device_secret: {device_secret}",
            f"prefixed_device_secret: {prefixed_device_secret}",
        )
    )
    ordinary = tmp_path / "private.env"
    _ = ordinary.write_text(content)
    definition = tmp_path / "scripts" / "public-release-audit.py"
    definition.parent.mkdir()
    _ = definition.write_text(content)
    audit.STRICT_DEFINITION_FILES = {definition.as_posix()}

    blockers = audit.scan_strict_blockers((ordinary, definition))
    blocker_text = "\n".join(blockers)

    assert "non-neutral-team-context" in blocker_text
    assert sum("non-neutral-team-context" in item for item in blockers) == 6
    assert "literal-pairing-code" in blocker_text
    assert "literal-invitation-secret" in blocker_text
    assert sum("literal-invitation-secret" in item for item in blockers) == 4
    assert sum("literal-device-credential" in item for item in blockers) == 4
    assert team not in blocker_text
    assert invitation_code not in blocker_text
    assert invitation_secret not in blocker_text
    assert prefixed_live_secret not in blocker_text
    assert device_secret not in blocker_text
    assert prefixed_device_secret not in blocker_text


def test_public_release_audit_reads_utf16_team_plists_without_false_positive(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule", cast("object", _load_public_release_audit())
    )
    team = "".join(("A1B2", "C3D4E5"))  # noqa: FLY002
    signing_plist = tmp_path / "signing.plist"
    signing_xml = plistlib.dumps(
        {"com.apple.developer.team-identifier": team},
        fmt=plistlib.FMT_XML,
    ).decode("utf-8")
    _ = signing_plist.write_bytes(
        signing_xml.replace('encoding="UTF-8"', 'encoding="UTF-16"').encode("utf-16")
    )
    unrelated_plist = tmp_path / "unrelated.plist"
    _ = unrelated_plist.write_bytes(
        plistlib.dumps({"BuildNumber": "ABCDEFGHIJ"}, fmt=plistlib.FMT_XML)
    )

    blockers = audit.scan_strict_blockers((signing_plist, unrelated_plist))

    assert sum("non-neutral-team-plist" in item for item in blockers) == 1
    assert all(str(unrelated_plist) not in item for item in blockers)
    assert team not in "\n".join(blockers)


def test_public_release_audit_allows_only_exact_complete_fixture_tokens(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule", cast("object", _load_public_release_audit())
    )
    allowed = "hbi_synthetic_first_mapping_rollback_secret"
    exact = tmp_path / "exact.txt"
    _ = exact.write_text(allowed)
    bypasses = tmp_path / "bypasses.txt"
    _ = bypasses.write_text(
        "\n".join(
            (
                "hb_test" + ("A" * 40),
                "HB_" + ("N" * 43),
                allowed.upper(),
                allowed[:-1] + allowed[-1].upper(),
                allowed + "A",
                allowed + "_suffix",
                allowed + "-suffix",
            )
        )
    )

    assert not any(
        "literal-invitation-secret" in item
        for item in audit.scan_strict_blockers([exact])
    )
    blockers = audit.scan_strict_blockers([bypasses])
    assert sum("literal-invitation-secret" in item for item in blockers) == 5
    assert sum("literal-device-credential" in item for item in blockers) == 2

    allowed_lowercase_code = tmp_path / "allowed-lowercase-code.txt"
    _ = allowed_lowercase_code.write_text("abcde-fghjk-mnpqr")
    unknown_lowercase_code = tmp_path / "unknown-lowercase-code.txt"
    _ = unknown_lowercase_code.write_text(
        "".join(("zzzzz", "-yyyyy", "-xxxxx"))  # noqa: FLY002
    )
    assert not any(
        "literal-pairing-code" in item
        for item in audit.scan_strict_blockers([allowed_lowercase_code])
    )
    assert (
        sum(
            "literal-pairing-code" in item
            for item in audit.scan_strict_blockers([unknown_lowercase_code])
        )
        == 1
    )


def test_public_release_audit_blocks_team_id_context_matrix_and_utf16(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule", cast("object", _load_public_release_audit())
    )
    team = "".join(("a1b2", "c3d4e5"))  # noqa: FLY002
    contexts = tmp_path / "contexts.txt"
    _ = contexts.write_text(
        "\n".join(
            (
                f"Apple Developer Team ID is {team}",
                f'developmentTeam: "{team}"',
                f'"teamIdentifier":\n"{team}"',
                f"DEVELOPMENT_TEAM[sdk=iphoneos*] = {team}",
            )
        )
    )
    little = tmp_path / "little.txt"
    _ = little.write_bytes(f"team_id={team}".encode("utf-16-le"))
    big = tmp_path / "big.txt"
    _ = big.write_bytes(f"team-id: {team}".encode("utf-16-be"))

    blockers = audit.scan_strict_blockers([contexts, little, big])
    assert sum("non-neutral-team-context" in item for item in blockers) == 6
    assert team not in "\n".join(blockers)


def test_public_release_audit_parses_binary_plists_and_fails_closed(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule", cast("object", _load_public_release_audit())
    )
    team = "".join(("A1B2", "C3D4E5"))  # noqa: FLY002
    invitation_secret = "hbi_" + ("V" * 43)
    private_address = ".".join(("192", "168", "42", "9"))  # noqa: FLY002
    account_email = "@".join(("release-owner", "account.invalid"))  # noqa: FLY002
    denylisted = "PRIVATE_BINARY_PLIST_SENTINEL"
    denylist_path = tmp_path / ".public-release-denylist.local"
    _ = denylist_path.write_text(denylisted)
    audit.LOCAL_DENYLIST_FILES = (denylist_path,)
    signing = tmp_path / "signing.plist"
    _ = signing.write_bytes(
        plistlib.dumps(
            {
                "TeamIdentifier": team,
                "application-identifier": f"{team}.com.example.Companion",
                "ApplicationIdentifierPrefix": [f"{team}."],
                "keychain-access-groups": [f"{team}.com.example.shared"],
                "invitation": invitation_secret,
                "receiver": private_address,
                "owner": account_email,
                "private-note": denylisted,
            },
            fmt=plistlib.FMT_BINARY,
        )
    )
    unrelated = tmp_path / "unrelated.plist"
    _ = unrelated.write_bytes(
        plistlib.dumps({"BuildNumber": team}, fmt=plistlib.FMT_BINARY)
    )
    malformed = tmp_path / "malformed.plist"
    _ = malformed.write_bytes(b"bplist00-not-valid")
    unsupported = tmp_path / "unsupported.txt"
    _ = unsupported.write_bytes(b"\x80\x81\x82")

    blockers = audit.scan_strict_blockers([signing, unrelated, malformed, unsupported])
    assert sum("non-neutral-team-plist" in item for item in blockers) == 1
    assert sum("non-neutral-application-identifier" in item for item in blockers) == 1
    assert sum("non-neutral-team-prefix-plist" in item for item in blockers) == 1
    assert sum("literal-invitation-secret" in item for item in blockers) == 1
    assert sum("private-rfc1918-address" in item for item in blockers) == 1
    assert sum("account-linked-email" in item for item in blockers) == 1
    assert sum("local-denylist:" in item for item in blockers) == 1
    assert sum("unparseable-plist" in item for item in blockers) == 1
    assert sum("unsupported-tracked-text-encoding" in item for item in blockers) == 1
    assert all(str(unrelated) not in item for item in blockers)


def test_public_release_audit_scans_and_redacts_tracked_filenames(
    tmp_path: Path,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule", cast("object", _load_public_release_audit())
    )
    credential = "hb_" + ("N" * 43)
    tracked = tmp_path / f"backup-{credential}.txt"
    _ = tracked.write_text("")
    uppercase_credential = "HB_" + ("P" * 43)
    uppercase_tracked = tmp_path / f"backup-{uppercase_credential}.txt"
    _ = uppercase_tracked.write_text("")

    blockers = audit.scan_strict_blockers([tracked, uppercase_tracked])
    blocker_text = "\n".join(blockers)

    assert sum("filename-literal-device-credential" in item for item in blockers) == 2
    assert credential not in blocker_text
    assert tracked.name not in blocker_text
    assert uppercase_credential not in blocker_text
    assert uppercase_tracked.name not in blocker_text
    assert "[REDACTED tracked path]" in blocker_text


def test_public_release_audit_handles_newline_in_tracked_filename(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audit = cast(
        "PublicReleaseAuditModule", cast("object", _load_public_release_audit())
    )
    _ = subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    tracked = tmp_path / "odd\nname.txt"
    _ = tracked.write_text("hb_" + ("Z" * 43))
    _ = subprocess.run(["git", "add", "--", tracked.name], cwd=tmp_path, check=True)
    monkeypatch.chdir(tmp_path)

    tracked_files = audit.git_tracked_files()
    blockers = audit.scan_strict_blockers(tracked_files)

    assert tracked_files == [Path(tracked.name)]
    assert any("literal-device-credential" in item for item in blockers)
    blocker_text = "\n".join(blockers)
    assert tracked.name not in blocker_text
    assert "odd\\nname.txt" in blocker_text


def test_public_release_audit_does_not_echo_marker_or_strict_context_values(
    tmp_path: Path,
) -> None:
    # Given
    secret_like_context = "PRIVATE_CONTEXT_VALUE_FOR_AUDIT_OUTPUT"
    private_address = ".".join(("100", "70", "1", "2"))  # noqa: FLY002
    marker_doc = tmp_path / "marker.md"
    _ = marker_doc.write_text(f"bearer_token {secret_like_context}\n")
    strict_doc = tmp_path / "strict.md"
    _ = strict_doc.write_text(
        f"private receiver {private_address} {secret_like_context}\n",
    )
    audit = cast(
        "PublicReleaseAuditModule",
        cast("object", _load_public_release_audit()),
    )

    # When
    marker_hits = audit.scan_markers([marker_doc])
    blockers = audit.scan_strict_blockers([strict_doc])
    output_text = "\n".join((*marker_hits, *blockers))

    # Then
    assert marker_hits != []
    assert blockers != []
    assert "[REDACTED" in output_text
    assert secret_like_context not in output_text
    assert private_address not in output_text


def test_public_release_audit_passes_its_real_tracked_tree() -> None:
    completed = subprocess.run(
        [sys.executable, "scripts/public-release-audit.py", "--strict"],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "strict_blockers=0" in completed.stdout
    assert "unreviewed_binaryish_tracked_files=0" in completed.stdout


def test_public_release_audit_rejects_non_neutral_xcode_signing_identity(
    tmp_path: Path,
) -> None:
    # Given
    neutral_project = tmp_path / "neutral.pbxproj"
    _ = neutral_project.write_text(
        "{}\n{}\n{}\n{}\n".format(
            'DEVELOPMENT_TEAM = "";',
            "DEVELOPMENT_TEAM = <your-apple-developer-team-id>;",
            "PRODUCT_BUNDLE_IDENTIFIER = com.example.HealthBridgeCompanion;",
            'build_settings=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")',
        ),
    )
    private_project = tmp_path / "private.pbxproj"
    team_value = "A" * 10
    bundle_value = ".".join(("dev", "owner", "HealthBridgeCompanion"))  # noqa: FLY002
    private_lines = [
        f"DEVELOPMENT_TEAM = {team_value};",
        f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_value};",
    ]
    _ = private_project.write_text("\n".join(private_lines) + "\n")
    audit = cast(
        "PublicReleaseAuditModule",
        cast("object", _load_public_release_audit()),
    )

    # When
    neutral_blockers = audit.scan_strict_blockers([neutral_project])
    private_blockers = audit.scan_strict_blockers([private_project])
    blocker_text = "\n".join(private_blockers)

    # Then
    assert neutral_blockers == []
    assert len(private_blockers) == 4
    assert "non-neutral-development-team" in blocker_text
    assert "non-neutral-bundle-identifier" in blocker_text
    assert "non-neutral-bundle-literal" in blocker_text
    assert team_value not in blocker_text
    assert bundle_value not in blocker_text


def test_ios_companion_does_not_allow_global_arbitrary_network_loads() -> None:
    # Given / When
    ats = _string_key_dict(_info_plist().get("NSAppTransportSecurity", {}))

    # Then
    assert ats.get("NSAllowsArbitraryLoads") is not True
    assert ats.get("NSAllowsLocalNetworking") is True


def test_ios_companion_declares_only_exempt_system_encryption() -> None:
    # Given / When
    plist = _info_plist()

    # Then
    assert plist.get("ITSAppUsesNonExemptEncryption") is False


def test_ios_health_usage_copy_describes_selected_read_only_sync() -> None:
    # Given / When
    plist = _info_plist()
    health_share_copy = str(plist.get("NSHealthShareUsageDescription", "")).lower()
    health_update_copy = str(plist.get("NSHealthUpdateUsageDescription", "")).lower()

    # Then
    assert "selected" in health_share_copy
    assert "read" in health_share_copy
    assert "local" in health_share_copy or "your receiver" in health_share_copy
    assert "NSHealthUpdateUsageDescription" in plist
    assert "does not write" in health_update_copy
    assert "only reads" in health_update_copy


def test_ios_companion_exposes_public_privacy_and_support_links() -> None:
    # Given / When
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()

    # Then
    assert 'Link("Privacy Policy"' in content_view
    assert 'Link("Support"' in content_view
    assert "https://healthbridge.chanhyo.dev/privacy/" in content_view
    assert "https://healthbridge.chanhyo.dev/support/" in content_view


def test_ios_healthkit_access_stays_read_only() -> None:
    # Given / When
    healthkit_catalog = HEALTHKIT_CATALOG.read_text()
    all_swift = "\n".join(path.read_text() for path in IOS_SWIFT_SOURCES)

    # Then
    assert (
        "requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes)"
        in healthkit_catalog
    )
    assert "healthStore.save" not in all_swift
    assert "HKHealthStore().save" not in all_swift
    assert "saveObject" not in all_swift
    assert "deleteObject" not in all_swift


def test_ios_companion_product_copy_has_no_stale_preview_or_future_language() -> None:
    # Given / When
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    coverage_policy = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/GenericQuantityCoveragePolicy.swift",
    ).read_text()
    ux_state = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/CompanionUXState.swift",
    ).read_text()
    readme = Path("README.md").read_text()

    # Then
    assert "Optional metrics preview" not in content_view
    assert "future read-only sync" not in coverage_policy
    assert "future explicit opt-in flow" not in coverage_policy
    assert "This preview" not in coverage_policy
    assert "scope selected in the app" not in ux_state
    assert "Request selected read-only" not in ux_state
    assert "Apple Health only asks for permissions the first time" not in content_view
    assert "Live core sync" not in readme


def test_ios_companion_diagnostics_do_not_render_token_prefixes() -> None:
    # Given / When
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()

    # Then
    assert "trimmedToken.prefix" not in view_model
    assert "String(trimmedToken" not in view_model
    assert "bundle.tokenPrefix" not in view_model
    assert "token \\" not in view_model
    assert "receiverDiagnosticsSummary" not in view_model


def test_ios_companion_exposes_structured_status_lanes() -> None:
    # Given / When
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    ux_state = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/CompanionUXState.swift",
    ).read_text()

    # Then
    assert "statusLaneSummaries" in view_model
    assert "CompanionStatusLane" in ux_state
    assert "CompanionStatusLaneBuilder" in ux_state


def test_ios_health_permissions_use_native_sheet_for_unified_scope() -> None:
    # Given / When
    policy = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/GenericQuantityCoveragePolicy.swift",
    ).read_text()
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()

    # Then
    assert "activityBasicsTypeCodes" in policy
    for type_code in [
        "basal_energy",
        "distance_walking_running",
        "energy",
        "flights_climbed",
    ]:
        assert f'"{type_code}"' in policy
    for high_sensitivity in ["oxygen_saturation", "body_mass", "vo2_max"]:
        assert f'"{high_sensitivity}"' not in _activity_basics_literal(policy)
    assert "defaultAdditionalTypeCodes" not in view_model
    assert "HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes" in view_model
    assert (
        "GenericQuantityOptInPolicy.activityBasicsTypeCodes.sorted()" not in view_model
    )
    assert "requestStatusForReadAuthorization" not in view_model
    assert all(
        invariant in view_model
        for invariant in (
            "let requestedTypeCodes = HealthKitReadTypeCatalog.availableTypeCodes(",
            "forTypeCodes: enabledHealthPermissionTypeCodes",
            "recordCompletedRequest(",
        )
    )
    assert "private var enabledBroadQuantityTypeCodes" in view_model
    assert "requestReadAuthorization(typeCodes: requestedTypeCodes)" in view_model
    assert "saveSelectedTypeCodes(optionalTypeCodes)" not in view_model
    quantity_sync_call = "typeCodes: supportedForegroundQuantityTypeCodes"
    assert quantity_sync_call in view_model
    assert "GenericQuantityOptInPresentation.optionRows" not in view_model
    assert "setOptionalQuantitySelected" not in view_model
    assert 'Toggle("Include all supported health data"' not in content_view
    assert "ForEach(viewModel.optionalQuantityRows)" not in content_view
    assert "setOptionalQuantitySelected" not in content_view
    assert "optionalQuantitySelectionStore" not in view_model
    assert "Apple Health permission request completed" in view_model
    assert 'statusMessage = "Apple Health permission failed."' in view_model
    assert "Health > profile picture > Privacy > Apps > Health Bridge" in view_model
    assert "Choose Health Data" not in content_view
    assert "Allow Health Access" in content_view
    assert "Opens Apple Health permission sheet" in content_view
    assert "healthPermissionNotice" in view_model
    assert "InlineNotice" in content_view
    assert "Review Permissions" in content_view
    assert "if !viewModel.healthPermissionsRequested" in content_view
    assert "historyWindowCard" not in content_view
    assert "openAppSettingsForHealthPermissions" not in view_model
    assert "UIApplication.openSettingsURLString" not in view_model
    assert "Core access includes Steps, Workouts, and Sleep." not in content_view
    narrow_copy = "Additional health data stays off unless you choose it here."
    assert narrow_copy not in content_view
    assert (
        "requests read-only access for every supported type currently available"
        in content_view
    )
    optional_explicit_copy = (
        "Additional optional metrics require an explicit optional sync request"
    )
    assert optional_explicit_copy not in content_view
    assert "provider-only metrics stay metadata-only" not in content_view
    runtime_permission_notice = (
        "permission request completed for \\(requestedTypeCodes.count) "
        "supported types currently available"
    )
    assert runtime_permission_notice in view_model
    assert "Select activity basics" not in content_view
    assert "Select all supported" not in content_view
    assert "Sync Additional Data Now" not in content_view
    assert "MetricGroup" not in content_view
    assert "optionalQuantitySelectionBoundaryCopy" not in content_view


def test_ios_companion_uses_button_like_ctas_and_simple_history_sync_copy() -> None:
    # Given / When
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    ux_state = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/CompanionUXState.swift"
    ).read_text()

    # Then
    assert "ProgressView()" in content_view
    assert ".buttonStyle(.borderedProminent)" in content_view
    assert ".controlSize(.large)" in content_view
    assert "Review Apple Health Permissions" not in content_view
    assert (
        "Use Sync Now to update the Apple Health data you allowed." not in content_view
    )
    assert "Some queued uploads need attention" not in content_view
    assert "Some queued uploads need attention" not in ux_state
    assert "Open Troubleshooting for queued uploads and sync status" not in content_view
    assert "Queued uploads and sync status" not in content_view
    assert "AppDetailsView" in content_view
    assert "DeveloperDiagnosticsView" not in content_view
    assert "Connection and app details" in content_view
    assert 'title: "Settings"' in content_view
    assert "Permissions and app info" not in content_view
    assert "Permissions, troubleshooting, app info" not in content_view
    assert (
        "Apple Health can ask again when supported types become newly available"
        in content_view
    )
    assert "Request Health Access Again" in content_view
    assert 'LabeledContent("Version"' in content_view
    assert "Open Source" not in content_view
    assert "Third-party libraries" not in content_view
    assert "Diagnostics" not in content_view
    assert "receiverDiagnosticsSummary" not in content_view
    assert (
        "receiverDiagnosticsSummary"
        not in Path(
            "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
        ).read_text()
    )
    assert 'Section("Automatic Sync")' in content_view
    assert "viewModel.automaticSyncCoverageDetail" in content_view
    assert "viewModel.backgroundSyncStatus" in content_view
    assert "Review Health permissions in Settings" not in ux_state
    assert "diagnosticCode(from:" in ux_state
    assert "NSURLErrorDomain -1004" in ux_state or "domain=([^|]+)" in ux_state
    assert "receiverclienterror 0" in ux_state.lower()
    assert "Connection key missing. Reconnect from setup link." in ux_state
    assert "private var statusBanner" not in content_view
    assert "accessibilityHint(subtitle)" in content_view
    assert "historicalBackfillSummary" not in content_view


def test_ios_status_card_surfaces_queued_uploads_after_disconnect() -> None:
    # Given / When
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()

    # Then
    queued_disconnected_condition = (
        "if !viewModel.canSendConnectionTest && viewModel.pendingOutboxCount > 0"
    )
    generic_disconnected_condition = "if !viewModel.canSendConnectionTest {"
    assert queued_disconnected_condition in content_view
    assert content_view.index(queued_disconnected_condition) < content_view.index(
        generic_disconnected_condition
    )
    assert "Queued Uploads Waiting" in content_view
    assert (
        "Queued uploads remain on this iPhone. Reconnect from setup link to retry them."
        in content_view
    )
    assert "or clear them" not in content_view


def test_ios_unpaired_connection_error_is_visible_and_retryable() -> None:
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()

    title_policy = content_view.split("private var statusTitle: String", maxsplit=1)[1]
    title_policy = title_policy.split("private var statusSubtitle: String", maxsplit=1)[
        0
    ]
    subtitle_policy = content_view.split(
        "private var statusSubtitle: String", maxsplit=1
    )[1]
    subtitle_policy = subtitle_policy.split(
        "private var syncErrorTitle: String", maxsplit=1
    )[0]

    error_condition = "if viewModel.statusIsError"
    disconnected_title = (
        'if !viewModel.canSendConnectionTest { return "Not Connected" }'
    )
    disconnected_subtitle = (
        'if !viewModel.canSendConnectionTest { return "Connect this iPhone before '
        'syncing." }'
    )
    assert title_policy.index(error_condition) < title_policy.index(disconnected_title)
    assert subtitle_policy.index(error_condition) < subtitle_policy.index(
        disconnected_subtitle
    )
    assert 'Button("Retry Pairing")' in content_view
    assert (
        'Button("Clear Pending Pairing and Disconnect", role: .destructive)'
        in content_view
    )
    cancel_button_start = content_view.index(
        'Button("Clear Pending Pairing and Disconnect", role: .destructive)'
    )
    cancel_button = content_view[cancel_button_start : cancel_button_start + 400]
    assert ".disabled(viewModel.isPairing)" in cancel_button
    background_uploader = Path(
        "ios/HealthBridgeCompanion/App/BackgroundURLSessionOutboxUploader.swift"
    ).read_text()
    assert "willPerformHTTPRedirection response: HTTPURLResponse" in background_uploader
    assert "ReceiverRedirectPolicy.allowsRedirect(" in background_uploader
    assert "func retryPendingPairing() async" in view_model


def test_pairing_recovery_is_visible_for_failed_connection_replacement() -> None:
    content = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text(
        encoding="utf-8"
    )

    recovery = (
        "if viewModel.hasPendingPairing {\n"
        "                        pairingRecoveryCard\n"
        "                    }"
    )
    setup_branch = "if viewModel.setupState == .unpaired {"
    assert recovery in content
    assert content.index(recovery) < content.index(setup_branch)
    assert "Clear Pending Pairing and Disconnect" in content
    assert "also removes the currently saved connection" in content


def test_different_setup_link_is_rejected_before_bootstrap_retry() -> None:
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text(encoding="utf-8")
    import_start = view_model.index("func importPairingURL(_ url: URL) async")
    import_end = view_model.index("private func performImportPairingURL", import_start)
    implementation = view_model[import_start:import_end]

    decision = "ReceiverIncomingPairingPolicy.decision"
    rejection = "case .rejectDifferentPending:"
    bootstrap = "await bootstrap()"
    assert decision in implementation
    assert rejection in implementation
    assert implementation.index(rejection) < implementation.index(bootstrap)
    assert "A different pairing is already pending" in implementation


def test_ios_companion_uses_simple_history_sync_copy() -> None:
    # Given / When
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    history_policy = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/HealthHistoryDepthPolicy.swift"
    ).read_text()
    ux_state = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/CompanionUXState.swift"
    ).read_text()

    # Then
    simple_history_copy = "First sync only."
    stale_history_first = "Sets the first-read window."
    stale_history_prefix = f"{stale_history_first} Later syncs continue from the last "
    stale_history_copy = f"{stale_history_prefix}successful upload."
    assert simple_history_copy not in content_view
    assert stale_history_copy not in content_view
    assert "First sync range. Later syncs only send changes." not in content_view
    assert 'title: "Sync Range"' in content_view
    assert "viewModel.automaticSyncScopeSummary" in content_view
    assert "iOS decides background timing" in ux_state
    assert "On when iOS allows." not in content_view
    assert "Manual only." not in content_view
    assert ".pickerStyle(.menu)" in content_view
    assert 'title: "All"' in history_policy
    assert 'return "All"' in history_policy
    assert 'title: "1 year"' in history_policy
    assert 'title: "180 days"' in history_policy
    assert 'title: "90 days"' in history_policy
    assert 'title: "30 days"' in history_policy
    assert "Best for data that changes occasionally" not in history_policy


def test_ios_companion_declares_healthkit_background_delivery_capability() -> None:
    # Given / When
    entitlements = _parse_plist(ENTITLEMENTS_PLIST)
    info = _info_plist()

    # Then
    background_modes = info["UIBackgroundModes"]
    permitted_identifiers = info["BGTaskSchedulerPermittedIdentifiers"]
    assert isinstance(background_modes, list)
    assert isinstance(permitted_identifiers, list)
    assert entitlements["com.apple.developer.healthkit"] is True
    assert entitlements["com.apple.developer.healthkit.background-delivery"] is True
    assert "fetch" in background_modes
    assert "$(PRODUCT_BUNDLE_IDENTIFIER).refresh" in permitted_identifiers


def test_ios_automatic_sync_migrates_to_unified_full_health_coverage() -> None:
    background_sync = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/BackgroundSync.swift",
    ).read_text()
    scope_policy = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/GenericQuantityCoveragePolicy.swift",
    ).read_text()
    ux_state = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/CompanionUXState.swift",
    ).read_text()
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    healthkit_read_types = Path("docs/supported-health-data.md").read_text()
    review_notes = Path(
        "docs/maintainers/app-review-notes-template.example.md"
    ).read_text()

    assert "QuantityObservationStore" in background_sync
    assert "supportedAutomaticQuantityTypeCodes" in background_sync
    assert "automaticQuantitySyncPlan" in background_sync
    assert "unifiedFullCoverageMigrationPlan" not in scope_policy
    assert "LegacyGenericQuantitySelectionStore" not in scope_policy
    assert "invalidateIfRuntimeCoverageChanged" in ux_state
    assert "completedRuntimeTypeCodes" in ux_state
    invalidation = ux_state.split("public func invalidateIfRuntimeCoverageChanged", 1)[
        1
    ].split("public func recordCompletedRequest", 1)[0]
    assert (
        "userDefaults.removeObject(forKey: Key.completedRuntimeTypeCodes)"
        in invalidation
    )
    completion = ux_state.split("public func recordCompletedRequest", 1)[1].split(
        "private static func normalizedTypeCodes", 1
    )[0]
    assert "forKey: Key.completedRuntimeTypeCodes" in completion
    assert "Key.wasRequested" not in ux_state
    assert "invalidateIfRuntimeCoverageChanged" in view_model
    assert "recordCompletedRequest" in view_model
    assert "HealthKitReadTypeCatalog.availableTypeCodes" in view_model
    assert (
        "HealthBridgeBackgroundSync.supportedAutomaticQuantityTypeCodes" in view_model
    )
    unified_type_set = "HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes"
    assert view_model.count(unified_type_set) >= 2
    assert view_model.count("forTypeCodes: enabledBroadQuantityTypeCodes") >= 2
    assert "includeAllSupportedHealthData" not in view_model
    assert "guard includeAllSupportedHealthData else { return [] }" not in view_model
    assert "if includeAllSupportedHealthData {" not in view_model
    assert "quantityObservationStore.observedTypeCodes" in view_model
    assert "quantityObservationStore.markObserved" in view_model
    assert (
        "automaticQuantityTypeCodes: availableAutomaticQuantityTypeCodes" in view_model
    )
    assert 'Toggle("Include all supported health data"' not in content_view
    assert "Core access includes Steps, Workouts, and Sleep." not in content_view
    assert (
        "requests read-only access for every supported type currently available"
        in content_view
    )
    for public_copy in (healthkit_read_types, review_notes):
        assert "every runtime-available" in public_copy
        assert "Include all supported health data" not in public_copy
        assert "off-by-default" not in public_copy
    assert "probeWeightHistoryPresence" not in view_model
    permission_block = view_model.split("func requestHealthPermissions() async", 1)[
        1
    ].split(
        "func sendConnectionTestBatch() async",
        1,
    )[0]
    assert "activateAutomaticSyncIfReady()" in permission_block
    assert "startHealthKitBackgroundDeliveryIfNeeded()" not in permission_block


def test_ios_catalog_has_no_hidden_default_health_scope() -> None:
    type_catalog = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/HealthKitTypeCatalog.swift"
    ).read_text()
    type_registry = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/HealthTypeRegistry.swift"
    ).read_text()
    read_catalog = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/HealthKitReadTypeCatalog.swift"
    ).read_text()

    public_scope_sources = type_catalog + type_registry + read_catalog
    assert "defaultEnabled" not in public_scope_sources
    assert "default_enabled" not in public_scope_sources
    assert "defaultReadCatalog" not in public_scope_sources
    assert "companionImplementedReadCatalog" not in public_scope_sources
    assert "usesDedicatedSyncLane" in type_catalog
    assert "dedicatedSyncTypeCodes" in type_catalog
    assert "dedicatedSyncTypes" in type_registry
    assert "objectTypes(for healthTypes: [HealthBridgeHealthType] =" not in read_catalog
    assert (
        "requestReadAuthorization(healthTypes: [HealthBridgeHealthType] ="
        not in read_catalog
    )


def test_ios_privacy_manifest_matches_no_developer_collection_posture() -> None:
    # Given / When
    manifest = _privacy_manifest()
    collected_data = manifest.get("NSPrivacyCollectedDataTypes")

    # Then
    assert manifest.get("NSPrivacyTracking") is False
    assert manifest.get("NSPrivacyTrackingDomains") == []
    assert collected_data == []


def test_ios_bootstrap_fails_closed_for_legacy_private_state() -> None:
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()

    assert (
        view_model.count(
            "ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(error)"
        )
        >= 2
    )
    assert view_model.count("ReceiverOutboxAdmissionPolicy.isReady(") >= 2
    assert (
        "pendingReceiverIdentities: try outbox.pendingItems().map(\\.receiverIdentity)"
        in view_model
    )
    assert "outboxIdentityMigrationReady = false" in view_model
    connection_recovery = "else if initialConnectionStateNeedsRecovery"
    outbox_recovery = "else if !outboxIdentityMigrationSucceeded"
    assert connection_recovery in view_model
    assert view_model.index(connection_recovery) < view_model.index(outbox_recovery)
    assert "must be reset and paired again before any upload" in view_model
    status_title = content_view.split("private var statusTitle: String", 1)[1].split(
        "private var statusSubtitle: String",
        1,
    )[0]
    status_subtitle = content_view.split("private var statusSubtitle: String", 1)[
        1
    ].split(
        "private var syncErrorTitle: String",
        1,
    )[0]
    assert "viewModel.hasPendingPrivateStorageRecovery" in status_title
    assert 'return "Recovery Required"' in status_title
    assert "viewModel.hasPendingPrivateStorageRecovery" in status_subtitle


def test_ios_privacy_manifest_declares_required_reason_api_usage() -> None:
    # Given / When
    manifest = _privacy_manifest()
    accessed_apis = manifest.get("NSPrivacyAccessedAPITypes")

    # Then
    assert isinstance(accessed_apis, list)
    accessed_api_items = cast("list[object]", accessed_apis)
    accessed_by_type = {
        _string_key_dict(item).get("NSPrivacyAccessedAPIType"): _string_key_dict(item)
        for item in accessed_api_items
    }
    assert accessed_by_type["NSPrivacyAccessedAPICategoryUserDefaults"].get(
        "NSPrivacyAccessedAPITypeReasons"
    ) == ["CA92.1"]
    assert accessed_by_type["NSPrivacyAccessedAPICategoryFileTimestamp"].get(
        "NSPrivacyAccessedAPITypeReasons"
    ) == ["C617.1"]


def test_ios_privacy_manifest_is_bundled_in_app_resources() -> None:
    # Given / When
    project = XCODE_PROJECT.read_text()

    # Then
    assert "PrivacyInfo.xcprivacy" in project
    assert "PrivacyInfo.xcprivacy in Resources" in project


def test_ios_companion_exposes_disconnect_receiver_control() -> None:
    # Given / When
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    receiver_client = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ReceiverClient.swift"
    ).read_text()

    # Then
    assert 'Label("Disconnect from Server"' in content_view
    assert "private var connectionStatusCard" in content_view
    assert content_view.index('Label("Disconnect from Server"') > content_view.index(
        "private var connectionStatusCard"
    )
    assert "showDisconnectConfirmation = true" in content_view
    assert "if !viewModel.receiverSettingsSaved" in content_view
    assert "isDisabled: !viewModel.canRedeemManualPairing" in content_view
    assert "isDisabled: !viewModel.canSendConnectionTest" in content_view
    assert "viewModel.disconnectReceiver()" in content_view
    assert "func disconnectReceiver() async" in view_model
    assert "performTerminalConnectionTransitionWhileHoldingRequestGate(" in view_model
    assert "clearReceiverSettings(expectedGeneration:" in receiver_client


def test_ios_companion_keeps_privacy_safety_copy_without_extra_privacy_menu() -> None:
    # Given / When
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    plist = _info_plist()
    manifest = _privacy_manifest()

    # Then
    assert "Privacy & local data" not in content_view
    assert "PrivacyLocalDataView" not in content_view
    assert (
        "Use Apple Health's permission screen to choose what this iPhone can share"
        in content_view
    )
    assert "the secret key stays on this iPhone" in content_view
    assert "Delete pending sync queue" not in content_view
    assert "Retry pending syncs" not in content_view
    assert "Activity Log" in content_view
    assert "Recent Activity" not in content_view
    assert "View All Logs" not in content_view
    assert "View Logs" in content_view
    assert (
        "activityLogMessages"
        in Path(
            "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
        ).read_text()
    )
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    quantity_sync_body = view_model.split("private func syncQuantityMetrics", 1)[
        1
    ].split("private func uploadQuantityBatchesWithOutbox", 1)[0]
    assert "requestReadAuthorization" not in quantity_sync_body
    assert "Some supported metrics were skipped:" in view_model
    assert "NSHealthShareUsageDescription" in plist
    assert manifest.get("NSPrivacyTracking") is False


def test_ios_app_review_notes_template_is_privacy_safe_and_actionable() -> None:
    # Given / When
    template = Path("docs/maintainers/app-review-notes-template.example.md")
    text = template.read_text()

    # Then
    assert "Read-only HealthKit" in text
    assert "User-owned receiver" in text
    assert "No ads, tracking, data brokers, or hidden telemetry" in text
    assert "No clinical decision support or readiness scoring" in text
    assert "Demo access" in text
    assert "Deletion and revocation" in text
    assert "<private-demo-receiver>" in text
    assert "outside Git" in text


def test_ios_companion_is_iphone_only() -> None:
    # Given / When
    plist = _info_plist()
    project = Path(
        "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
    ).read_text()

    # Then
    assert project.count("TARGETED_DEVICE_FAMILY = 1;") == 2
    assert 'TARGETED_DEVICE_FAMILY = "1,2";' not in project
    assert "UISupportedInterfaceOrientations~ipad" not in plist


def test_ios_minimum_versions_are_documented_consistently() -> None:
    # Given / When
    readme = Path("README.md").read_text()
    self_build = Path("docs/self-build.md").read_text()
    testflight = Path(".github/release/testflight-checklist.md").read_text()
    contributing = Path("CONTRIBUTING.md").read_text()

    # Then
    assert "iPhone running iOS 18 or later" in readme
    assert "Xcode 16 or later" in readme
    assert "iPhone running iOS 18 or later" in self_build
    assert "Xcode 16 or later" in self_build
    assert "iPhone running iOS 18 or later" in testflight
    assert "Xcode 16 or later" in contributing


def test_repository_has_no_password_accepting_keychain_helper() -> None:
    # Given
    removed_helpers = (
        Path("scripts/macos-fix-codesign-keychain.sh"),
        Path("scripts/macos-fix-codesign-keychain.command"),
    )
    scripts_readme = Path("scripts/README.md").read_text()

    # Then
    assert all(not helper.exists() for helper in removed_helpers)
    assert "macos-fix-codesign-keychain" not in scripts_readme
    assert "Keychain Access" in scripts_readme
    assert "Do not paste your macOS password" in scripts_readme

    script_text = "\n".join(
        path.read_text()
        for path in Path("scripts").iterdir()
        if path.suffix in {".command", ".sh"}
    )
    for forbidden_pattern in (
        "KEYCHAIN_PASSWORD",
        "read -rs",
        "security unlock-keychain -p",
        "security set-key-partition-list",
    ):
        assert forbidden_pattern not in script_text


def test_ios_pairing_v2_stages_before_redeem_and_recovers_pending_state() -> None:
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()
    app = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionApp.swift"
    ).read_text()
    receiver_client = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ReceiverClient.swift"
    ).read_text()
    settings_store = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/FileOutbox.swift"
    ).read_text()

    assert "@Published var manualPairingServer" in view_model
    assert "@Published var manualPairingCode" in view_model
    assert "@Published var isPairing" in view_model
    assert "ReceiverPairingMaterial.decode" in view_model
    assert "invitation: invitation" in view_model
    assert "manualPairing: manualPairing" in view_model
    assert view_model.count("expectedGeneration: expectedGeneration") >= 4
    assert "applyCommittedPairingCredential" in view_model
    assert "func resumePendingPairingIfNeeded() async" in view_model
    assert "func importPairingText() async" in view_model
    assert "func importPairingURL(_ url: URL) async" in view_model
    assert "func redeemManualPairing() async" in view_model

    assert 'TextField("Server address"' in content_view
    assert 'TextField("Invitation code"' in content_view
    assert "viewModel.redeemManualPairing()" in content_view
    assert 'SecureField("Secret key"' not in content_view
    assert "Task { await viewModel.importPairingText() }" in content_view

    assert ".onContinueUserActivity(NSUserActivityTypeBrowsingWeb)" in app
    assert "await viewModel.importPairingURL(url)" in app
    assert "await viewModel.bootstrap()" in app
    assert "await viewModel.resumePendingPairingIfNeeded()" not in app

    assert 'account: "pending-pairing"' in settings_store
    assert 'account: "pairing-installation-id"' in settings_store
    assert 'account: "pairing-cancellation"' in settings_store
    assert "deviceCredential: deviceCredentialGenerator()" in settings_store
    assert "client.redeem(pendingPairing: pending)" in receiver_client
    promotion = receiver_client.index("try settingsStore.save(")
    pending_clear = receiver_client.index("try stateStore.clearPending()", promotion)
    assert promotion < pending_clear


def test_receiver_error_descriptions_never_embed_response_bodies() -> None:
    receiver_client = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ReceiverClient.swift"
    ).read_text()
    error_start = receiver_client.index("public enum ReceiverClientError")
    error_end = receiver_client.index(
        "public enum ReceiverPairingRedeemError", error_start
    )
    error_body = receiver_client[error_start:error_end]

    assert "case .unsuccessfulStatusCode(let statusCode, _):" in error_body
    assert '"Receiver returned HTTP \\(statusCode)."' in error_body
    assert "bodySnippet" not in error_body

    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    describe_start = view_model.index("private func describe(_ error: Error) -> String")
    describe_body = view_model[describe_start:]
    assert "case .unsuccessfulStatusCode(let statusCode, _):" in describe_body
    assert "String(data: responseBody" not in describe_body
    assert "responseBody.trimmingCharacters" not in describe_body
    assert "lastRun.summary" not in view_model
    assert "lastRun.userVisibleSummary" in view_model


def test_ios_pairing_bootstrap_precedes_all_automatic_sync_entrypoints() -> None:
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    app = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionApp.swift"
    ).read_text()

    background_task = app.index(".backgroundTask(")
    background_bootstrap = app.index("await viewModel.bootstrap()", background_task)
    background_sync = app.index(
        "await viewModel.runBackgroundRefreshSync", background_task
    )
    assert background_bootstrap < background_sync

    init_start = view_model.index("    init(")
    init_end = view_model.index("    var canSaveReceiverSettings", init_start)
    init_body = view_model[init_start:init_end]
    assert "startHealthKitBackgroundDeliveryIfNeeded()" not in init_body
    assert "schedulePendingBackgroundOutboxUploadsIfAllowed()" not in init_body
    assert "pendingPairingMayExist = true" in init_body

    bootstrap_start = view_model.index("func bootstrap() async")
    bootstrap_end = view_model.index(
        "func resumePendingPairingIfNeeded() async", bootstrap_start
    )
    bootstrap_body = view_model[bootstrap_start:bootstrap_end]
    assert bootstrap_body.index("resumePendingPairingIfNeeded") < bootstrap_body.index(
        "bootstrapCompleted = true"
    )
    assert "guard automaticSyncReady" in view_model
    assert "automaticSyncReady," in view_model

    invitation_flow = view_model.index("case .invitation(let invitation):")
    invitation_pause = view_model.index(
        "pauseAutomaticSyncForPendingPairing()", invitation_flow
    )
    invitation_barrier = view_model.index(
        "performTerminalConnectionTransitionWhileHoldingRequestGate(", invitation_flow
    )
    invitation_redeem = view_model.index("pairingCoordinator.pair(", invitation_flow)
    assert invitation_pause < invitation_barrier < invitation_redeem

    terminal_start = view_model.index(TERMINAL_TRANSITION_HELPER)
    terminal_end = view_model.index(
        "private func cancelAndAwaitForegroundPayloadTasks()", terminal_start
    )
    terminal_body = view_model[terminal_start:terminal_end]
    assert "await self.cancelAndAwaitForegroundPayloadTasks()" in terminal_body
    assert "await self.drainBackgroundPayloadCancellation()" in terminal_body


def test_ios_pairing_cancel_and_repair_stops_inflight_sync_before_deletion() -> None:
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    content_view = Path("ios/HealthBridgeCompanion/App/ContentView.swift").read_text()

    cancel_start = view_model.index("func cancelPendingPairing() async")
    cancel_end = view_model.index("private func finishPairingAttempt", cancel_start)
    cancel_body = view_model[cancel_start:cancel_end]
    fail_closed = cancel_body.index("hasPendingPairing = true")
    barrier = cancel_body.index(
        "performTerminalConnectionTransitionWhileHoldingRequestGate("
    )
    durable_cancel = cancel_body.index("pairingCoordinator.cancelPendingPairing(")
    assert fail_closed < barrier < durable_cancel
    assert "cancelPairingOperation: true" in cancel_body
    assert "await viewModel.cancelPendingPairing()" in content_view

    receiver_client = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ReceiverClient.swift"
    ).read_text()
    coordinator_cancel_start = receiver_client.index(
        "public func cancelPendingPairing("
    )
    coordinator_cancel_end = receiver_client.index(
        "private func complete(", coordinator_cancel_start
    )
    coordinator_cancel_body = receiver_client[
        coordinator_cancel_start:coordinator_cancel_end
    ]
    marker_begin = coordinator_cancel_body.index("stateStore.beginPendingCancellation(")
    finish_call = coordinator_cancel_body.index("finishPendingCancellationIfNeeded(")
    active_clear = coordinator_cancel_body.index("settingsStore.clearReceiverSettings(")
    pending_clear = coordinator_cancel_body.rindex("stateStore.clearPending()")
    marker_clear = coordinator_cancel_body.rindex("finishPendingCancellation()")
    assert marker_begin < finish_call < active_clear < pending_clear < marker_clear

    terminal_start = view_model.index(TERMINAL_TRANSITION_HELPER)
    terminal_end = view_model.index(
        "private func requireCurrentConnectionGeneration", terminal_start
    )
    terminal_body = view_model[terminal_start:terminal_end]
    pre_cancel = terminal_body.index("await cancelPairingOperationIfNeeded()")
    barrier_call = terminal_body.index("connectionTerminalBarrier.perform(")
    foreground_join = terminal_body.index(
        "await self.cancelAndAwaitForegroundPayloadTasks()"
    )
    background_drain = terminal_body.index(
        "await self.drainBackgroundPayloadCancellation()"
    )
    assert pre_cancel < barrier_call < foreground_join < background_drain

    upload_start = view_model.index("private func uploadPayloadsWithOutbox(")
    upload_end = view_model.index("private func uploadPendingOutbox(", upload_start)
    upload_body = view_model[upload_start:upload_end]
    assert "guard !hasPendingPairing, !Task.isCancelled" in upload_body

    background_run_start = view_model.index(
        "private func performBackgroundRefreshSync(reason:"
    )
    background_run_end = view_model.index(
        "private func stopBackgroundRunIfUnavailable", background_run_start
    )
    background_run_body = view_model[background_run_start:background_run_end]
    final_guard = background_run_body.rindex(
        "guard !hasPendingPairing, !Task.isCancelled"
    )
    queued_recursion = background_run_body.rindex(
        "await performAdmittedBackgroundRefreshSync("
    )
    assert final_guard < queued_recursion

    scheduler_start = view_model.index("private func startBackgroundOutboxScheduling(")
    scheduler_end = view_model.index(
        "func noteBackgroundRefreshScheduled", scheduler_start
    )
    scheduler_body = view_model[scheduler_start:scheduler_end]
    assert scheduler_body.index("previousTask?.cancel()") < scheduler_body.index(
        "await previousTask.value"
    )
    for requirement in (
        "self.automaticSyncReady",
        "self.backgroundSyncEnabled",
        "self.settingsStore.receiverSettingsGenerationToken == expectedGeneration",
        "!Task.isCancelled",
    ):
        assert requirement in scheduler_body

    receiver_client = Path(
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/ReceiverClient.swift"
    ).read_text()
    assert "if error == .invitationInvalid" in receiver_client
    assert "(400..<500).contains" not in receiver_client
    first_cancellation = receiver_client.index("try Task.checkCancellation()")
    promotion = receiver_client.index("try settingsStore.save(")
    assert first_cancellation < promotion


def test_ios_pairing_waits_for_all_foreground_and_background_upload_paths() -> None:
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()
    background_uploader = Path(
        "ios/HealthBridgeCompanion/App/BackgroundURLSessionOutboxUploader.swift"
    ).read_text()

    resume_start = view_model.index(
        "private func performResumePendingPairingIfNeeded()"
    )
    resume_end = view_model.index("func cancelPendingPairing() async", resume_start)
    resume_body = view_model[resume_start:resume_end]
    assert resume_body.index(
        "performTerminalConnectionTransitionWhileHoldingRequestGate("
    ) < resume_body.index("pairingCoordinator.resumePendingPairing(")

    check_start = view_model.index("func checkConnection() async")
    check_end = view_model.index("func performPrimaryAction() async", check_start)
    check_body = view_model[check_start:check_end]
    assert "trackedSyncTasks[taskID] = task" in check_body
    assert "await task.value" in check_body
    assert "await checkReceiverHealth()" in check_body
    assert "sendConnectionTestBatch" not in check_body
    assert check_body.count("canSendConnectionTest") >= 1
    assert check_body.count("!Task.isCancelled") >= 1

    foreground_outbox_start = view_model.index("private func uploadPendingOutbox(")
    foreground_outbox_end = view_model.index(
        "private func refreshPendingOutboxCount", foreground_outbox_start
    )
    foreground_outbox_body = view_model[foreground_outbox_start:foreground_outbox_end]
    assert (
        foreground_outbox_body.count(
            "requireCurrentConnectionGeneration(expectedGeneration)"
        )
        >= 4
    )
    assert "catch is CancellationError" in foreground_outbox_body
    assert "bearerToken uploadBearerToken" in foreground_outbox_body

    cancel_upload_start = background_uploader.index("func cancelPendingUploads() async")
    cancel_upload_end = background_uploader.index(
        "func setBackgroundCompletionHandler", cancel_upload_start
    )
    cancel_upload_body = background_uploader[cancel_upload_start:cancel_upload_end]
    assert "if let cancellationFlight" in cancel_upload_body
    assert "return await cancellationFlight.task.value" in cancel_upload_body
    assert cancel_upload_body.index(
        "sessionTasks.forEach { $0.cancel() }"
    ) < cancel_upload_body.index("await cancellationBarrier.wait(")
    assert "eventFinalizationCoordinator.stateSnapshot()" in cancel_upload_body
    assert "waitForEventFinalizationIdle(" in cancel_upload_body
    assert "BackgroundUploadCancellationCertificationPolicy" in cancel_upload_body
    assert "timeout: Self.cancellationCompletionTimeout" in cancel_upload_body
    delegate_completion_start = background_uploader.index(
        "didCompleteWithError error: Error?"
    )
    delegate_completion_body = background_uploader[delegate_completion_start:]
    main_completion_start = delegate_completion_body.index(
        "Task { @MainActor [weak self]"
    )
    main_completion_body = delegate_completion_body[main_completion_start:]
    assert main_completion_body.index(
        "self.finishCompletedUpload("
    ) < main_completion_body.index("await completionBarrier.complete(taskID)")


def test_ios_cold_launch_pairing_url_runs_after_bootstrap_without_losing_new_link() -> (
    None
):
    view_model = Path(
        "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
    ).read_text()

    tracker_start = view_model.index("private func runTrackedPairingOperation(")
    tracker_end = view_model.index(
        "private func cancelPairingOperationIfNeeded", tracker_start
    )
    tracker_body = view_model[tracker_start:tracker_end]
    assert "let existingKind = pairingOperationKind" in tracker_body
    policy_call = "PairingOperationSequencingPolicy.shouldRunAfterWaiting("
    assert tracker_body.index("await existingTask.value") < tracker_body.index(
        policy_call
    )
    assert "existing: existingKind" in tracker_body
    assert "requested: kind" in tracker_body
    assert (
        "matchesPendingBootstrapInvitation: skipAfterBootstrapRecovery" in tracker_body
    )
    assert "pairingRequestEpoch.isCurrent(capturedPairingRequestEpoch)" in tracker_body
    assert "if let queuedUserTask = pairingTask" in tracker_body
    assert "await queuedUserTask.value" in tracker_body
    assert tracker_body.index(policy_call) < tracker_body.index(
        "let attemptID = UUID()"
    )

    import_start = view_model.index("func importPairingURL(_ url: URL) async")
    import_end = view_model.index("private func performImportPairingURL", import_start)
    import_body = view_model[import_start:import_end]
    pending_match = import_body.index(
        "pairingCoordinator.pendingPairingMatches(invitation)"
    )
    decision = import_body.index("ReceiverIncomingPairingPolicy.decision(")
    reject_different = import_body.index("case .rejectDifferentPending:")
    resume_matching = import_body.index("case .resumeMatchingPending:")
    bootstrap_wait = import_body.index("await bootstrap()", resume_matching)
    tracked_operation = import_body.index("await runTrackedPairingOperation {")
    assert (
        pending_match
        < decision
        < reject_different
        < resume_matching
        < bootstrap_wait
        < tracked_operation
    )
    assert "case .importIncoming:" in import_body
    assert (
        "skipAfterBootstrapRecovery: matchesPendingBootstrapInvitation"
        not in import_body
    )
    assert "await self?.performImportPairingURL(url)" in import_body


def test_ios_copy_does_not_expose_removed_optional_selection_contract() -> None:
    source = "\n".join(path.read_text() for path in IOS_SWIFT_SOURCES)
    stale_phrases = [
        "Selected Apple Health data only",
        "selected runtime-available quantity types",
        "No additional Apple Health data selected",
        "Additional data selected:",
        "clearing the additional data selection",
        "GenericQuantityOptIn",
        "core Apple Health data",
        "additional metrics",
        "additional health metric",
    ]

    for phrase in stale_phrases:
        assert phrase not in source

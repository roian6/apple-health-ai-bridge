#!/usr/bin/env python3
# ruff: noqa: T201,S603,TRY003,EM101
"""Privacy-oriented tracked-file audit for public OSS release prep.

This is intentionally conservative and local-only. It scans Git-tracked files for
file types and marker strings that deserve manual review before repository
visibility changes. It does not print secret values from generated/untracked
setup pages because it only reads tracked files.

Use ``--strict`` before changing repository visibility. Strict mode fails on
public-surface wording that would overfit the project to private validation data
or internal validation language. Exact private strings belong in
``.public-release-denylist.local`` instead of this tracked script.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterable

BINARYISH_SUFFIXES = {
    ".sqlite",
    ".sqlite3",
    ".db",
    ".zip",
    ".png",
    ".jpg",
    ".jpeg",
    ".heic",
    ".mov",
    ".mp4",
    ".m4v",
    ".gif",
    ".webp",
}

INTENTIONAL_BRAND_MEDIA = {
    Path("assets/brand/health-bridge-lockup.png"),
    Path("assets/brand/health-bridge-social-card.png"),
    Path("assets/brand/health-bridge-mark-1024.png"),
    Path("assets/brand/health-bridge-mark-512.png"),
    Path("assets/brand/apple-touch-icon.png"),
    Path("assets/brand/favicon-48.png"),
    Path("assets/brand/favicon-32.png"),
    Path("assets/brand/favicon-16.png"),
}

MARKERS = (
    "bearer_token",
    "pairing_url",
    "healthbridge://pair",
    "token_hash",
    "setup-page",
    "outbox payload",
    "HealthKit export",
    "receiver DB",
    "real HealthKit",
)

PUBLIC_SURFACE_ROOTS = ("docs/",)
PUBLIC_SURFACE_FILES = {
    "AGENTS.md",
    "CONTRIBUTING.md",
    "README.md",
    "SECURITY.md",
    "scripts/README.md",
}
STRICT_DEFINITION_FILES = {
    "scripts/public-release-audit.py",
    "tests/guardrails/test_ios_app_privacy.py",
}
LOCAL_DENYLIST_FILES = (Path(".public-release-denylist.local"),)

CREDENTIAL_CHARACTER_CLASS = r"A-Za-z0-9_-"
MINIMUM_UTF16_PROBE_BYTES = 4
UTF16_NUL_DENSE_RATIO = 0.3
UTF16_NUL_SPARSE_RATIO = 0.05
ALLOWED_INVITATION_SECRETS = frozenset(
    {
        "hbi_synthetic_first_mapping_rollback_secret",
        "hbi_synthetic_second_mapping_rollback_secret",
    }
)
ALLOWED_PAIRING_CODES = frozenset(
    {
        "ABCDE-FGHJK-MNPQR",
        "ABCDE-22222-22222",
        "RSTUV-WXYZ2-34567",
        "STUVW-XYZ23-45678",
    }
)
TEAM_ID_KEYS = frozenset(
    {
        "developmentteam",
        "appleteamid",
        "appledeveloperteamid",
        "teamid",
        "teamidentifier",
        "comappledeveloperteamidentifier",
    }
)
APPLICATION_IDENTIFIER_KEYS = frozenset(
    {"applicationidentifier", "comappleapplicationidentifier"}
)

INTERNAL_DOC_PATH_PATTERNS = (
    re.compile(r"^docs/plans/"),
    re.compile(r"^docs/stage[^/]*\.md$"),
    re.compile(r"^docs/project-review-.*\.md$"),
    re.compile(r"^docs/implementation-history\.md$"),
    re.compile(r"^docs/public-oss-release-checklist\.md$"),
    re.compile(r"^docs/public-release-goal-fidelity-review\.md$"),
    re.compile(r"^docs/ios/future-healthkit-sync-notes\.md$"),
)


@dataclass(frozen=True)
class StrictPattern:
    name: str
    regex: re.Pattern[str]
    reason: str
    redact_line: bool = False


CGNAT_PATTERN = (
    r"(?<!\d)100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\."
    r"(?:25[0-5]|2[0-4]\d|1?\d?\d)\."
    r"(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d)"
)
PRIVATE_RECEIVER_RE = re.compile(
    CGNAT_PATTERN + "|" + "Tail" + "scale IP",
    re.IGNORECASE,
)


STRICT_PATTERNS = (
    StrictPattern(
        name="private-dogfood-language",
        regex=re.compile(r"\bdogfood\b", re.IGNORECASE),
        reason="public docs should describe validation generically",
    ),
    StrictPattern(
        name="private-receiver-address",
        regex=PRIVATE_RECEIVER_RE,
        reason="public docs should not include a private receiver address",
    ),
)

GLOBAL_STRICT_PATTERNS = (
    StrictPattern(
        name="literal-device-credential",
        regex=re.compile(
            "".join(
                (
                    rf"(?<![{CREDENTIAL_CHARACTER_CLASS}])",
                    rf"hb_[{CREDENTIAL_CHARACTER_CLASS}]{{32,}}",
                    rf"(?![{CREDENTIAL_CHARACTER_CLASS}])",
                )
            ),
            re.IGNORECASE,
        ),
        reason="tracked files should not include a literal companion credential",
        redact_line=True,
    ),
    StrictPattern(
        name="literal-github-token",
        regex=re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
        reason="tracked files should not include a literal GitHub credential",
        redact_line=True,
    ),
    StrictPattern(
        name="literal-invitation-secret",
        regex=re.compile(
            "".join(
                (
                    rf"(?<![{CREDENTIAL_CHARACTER_CLASS}])",
                    rf"hbi_[{CREDENTIAL_CHARACTER_CLASS}]{{32,}}",
                    rf"(?![{CREDENTIAL_CHARACTER_CLASS}])",
                )
            ),
            re.IGNORECASE,
        ),
        reason="tracked files should not include a live pairing invitation secret",
        redact_line=True,
    ),
    StrictPattern(
        name="literal-pairing-code",
        regex=re.compile(
            r"(?<![A-Z0-9_-])[A-HJ-NP-Z2-9]{5}"
            r"(?:-[A-HJ-NP-Z2-9]{5}){2}(?![A-Z0-9_-])",
            re.IGNORECASE,
        ),
        reason="tracked files should not include a live manual pairing code",
        redact_line=True,
    ),
    StrictPattern(
        name="non-neutral-team-context",
        regex=re.compile(
            r"(?<![A-Z0-9_])[\"']?(?:DEVELOPMENT[ _-]?TEAM|"
            r"APPLE(?:[ _-]?DEVELOPER)?[ _-]?TEAM[ _-]?ID|"
            r"TEAM(?:[ _-]?ID|[ _-]?IDENTIFIER))(?![A-Z0-9_])[\"']?"
            r"(?:\[[^\]\r\n]+\])?"
            r"(?:"
            r"[^\S\r\n]*(?:\r?\n[^\S\r\n]*)?(?:=|:)"
            r"[^\S\r\n]*(?:\r?\n[^\S\r\n]*)?|"
            r"[^\S\r\n]+IS[^\S\r\n]*(?:\r?\n[^\S\r\n]*)?|"
            r"[^\S\r\n]+|[^\S\r\n]*\r?\n[^\S\r\n]*"
            r")"
            r"[\"']?[A-Z0-9]{10}(?![A-Z0-9])",
            re.IGNORECASE | re.VERBOSE,
        ),
        reason="tracked signing contexts should not include a real Apple team ID",
        redact_line=True,
    ),
    StrictPattern(
        name="non-neutral-development-team",
        regex=re.compile(
            r"DEVELOPMENT_TEAM(?:\[[^\]\r\n]+\])?\s*="
            r'(?!\s*""\s*;|\s*<[^;>]+>\s*;|'
            r"\s*\$(?:\([^)]+\)|\{[^}]+\})\s*;)"
            r"\s*[^;\s][^;]*;",
        ),
        reason="tracked Xcode settings should not include a real signing team",
    ),
    StrictPattern(
        name="non-neutral-bundle-identifier",
        regex=re.compile(
            r"PRODUCT_BUNDLE_IDENTIFIER\s*="
            r"(?!\s*com\.example\.[A-Za-z0-9_.-]+\s*;|"
            r"\s*\$(?:\([^)]+\)|\{[^}]+\})\s*;)\s*[^;]+;",
        ),
        reason="tracked Xcode settings should keep a public-neutral bundle ID",
    ),
    StrictPattern(
        name="non-neutral-bundle-literal",
        regex=re.compile(
            r"(?<![A-Za-z0-9.-])"
            r"(?!(?:com|org|net|io|dev|app)\.example\.)"
            r"(?!com\.apple\.)"
            r"(?!dev\.healthbridge\.companion(?![A-Za-z0-9.-]))"
            r"(?:com|org|net|io|dev|app)\."
            r"[A-Za-z0-9-]+\.[A-Za-z0-9.-]+\b",
            re.IGNORECASE,
        ),
        reason="tracked fixtures should use a public-neutral bundle namespace",
    ),
    StrictPattern(
        name="private-device-id",
        regex=re.compile(r"\b[0-9A-F]{8}-[0-9A-F]{16}\b", re.IGNORECASE),
        reason="tracked files should not include real device identifiers",
    ),
    StrictPattern(
        name="private-receiver-address",
        regex=PRIVATE_RECEIVER_RE,
        reason="tracked files should not include a private receiver address",
    ),
    StrictPattern(
        name="private-rfc1918-address",
        regex=re.compile(
            r"(?<!\d)(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|"
            r"172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?!\d)"
        ),
        reason="tracked files should not include a private LAN address",
    ),
    StrictPattern(
        name="private-user-home-path",
        regex=re.compile(r"(?:/Users|/home)/[A-Za-z0-9._-]+/"),
        reason="tracked files should not include a user-specific home path",
    ),
    StrictPattern(
        name="account-linked-email",
        regex=re.compile(
            r"\b(?!healthbridge@chanhyo\.dev\b)"
            r"[A-Za-z][A-Za-z0-9._%+-]*@"
            r"(?!(?:[A-Za-z][A-Za-z0-9-]*\.)*example\.(?:com|org|net)\b)"
            r"[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b",
            re.IGNORECASE,
        ),
        reason="tracked files should not include an unreviewed account-linked email",
        redact_line=True,
    ),
)

DEFINITION_SELF_AUDIT_PATTERNS = (
    StrictPattern(
        name="literal-private-device-id-in-guardrail",
        regex=re.compile(r"\b[0-9A-F]{8}-[0-9A-F]{16}\b", re.IGNORECASE),
        reason="guardrails should use generic detector shapes, not real device IDs",
    ),
    StrictPattern(
        name="literal-private-cgnat-ip-in-guardrail",
        regex=re.compile(
            r"(?<!\d)100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\."
            r"(?:25[0-5]|2[0-4]\d|1?\d?\d)\."
            r"(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d)"
        ),
        reason="guardrails should not embed exact private receiver addresses",
    ),
    StrictPattern(
        name="literal-private-validation-value-in-guardrail",
        regex=re.compile(r"\b\d{1,3},\d{3}\b"),
        reason="guardrails should not embed exact private validation values",
    ),
)


def is_intentional_visual_asset(path: Path) -> bool:
    """Return whether a tracked binary-ish file is an intentional brand asset.

    Public releases should still block arbitrary screenshots, downloaded reference
    images, real HealthKit screenshots, and generated media dumps. The only
    binary visual files expected in Git are the canonical synthetic brand PNGs
    and Xcode AppIcon rasters generated from the same canonical SVG source.
    """
    path_text = path.as_posix()
    return path in INTENTIONAL_BRAND_MEDIA or (
        path_text.startswith(
            "ios/HealthBridgeCompanion/App/Assets.xcassets/AppIcon.appiconset/"
        )
        and path.suffix.lower() == ".png"
    )


def git_tracked_files() -> list[Path]:
    git = shutil.which("git")
    if git is None:
        raise RuntimeError("git executable not found")
    result = subprocess.run(
        [git, "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    return [
        Path(os.fsdecode(raw_path))
        for raw_path in result.stdout.split(b"\0")
        if raw_path
    ]


class TrackedTextDecodeError(ValueError):
    pass


def render_path(path: Path) -> str:
    return json.dumps(os.fspath(path), ensure_ascii=True)


def plist_searchable_text(root: object) -> str:
    values: list[str] = []

    def walk(value: object) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                values.append(str(key))
                walk(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                walk(child)
        elif isinstance(value, str):
            values.append(value)
        elif isinstance(value, bytes):
            values.append(value.decode("latin-1"))

    walk(root)
    return "\n".join(values)


def read_tracked_text(path: Path) -> str:  # noqa: PLR0911 - explicit encoding dispatch
    data = path.read_bytes()
    if data.startswith(b"bplist00"):
        try:
            return plist_searchable_text(plistlib.loads(data))
        except Exception:  # noqa: BLE001 - scan_plist_team_ids reports the blocker.
            return ""
    if data.startswith(b"\xef\xbb\xbf"):
        return data.decode("utf-8-sig")
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16")
    if b"\x00" in data and len(data) >= MINIMUM_UTF16_PROBE_BYTES:
        even = data[0::2]
        odd = data[1::2]
        even_nul_ratio = even.count(0) / len(even)
        odd_nul_ratio = odd.count(0) / len(odd)
        if (
            odd_nul_ratio >= UTF16_NUL_DENSE_RATIO
            and even_nul_ratio <= UTF16_NUL_SPARSE_RATIO
        ):
            return data.decode("utf-16-le")
        if (
            even_nul_ratio >= UTF16_NUL_DENSE_RATIO
            and odd_nul_ratio <= UTF16_NUL_SPARSE_RATIO
        ):
            return data.decode("utf-16-be")
        raise TrackedTextDecodeError("embedded NULs are not valid UTF-16 text")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise TrackedTextDecodeError(
            "tracked text is not strict UTF-8/UTF-16"
        ) from error


def is_plist_like(path: Path, data: bytes) -> bool:
    if path.suffix.lower() in {".plist", ".entitlements", ".xcprivacy"}:
        return True
    if data.startswith(b"bplist00"):
        return True
    try:
        if data.startswith((b"\xff\xfe", b"\xfe\xff")):
            prefix = data[:512].decode("utf-16")
        elif data.startswith(b"\xef\xbb\xbf"):
            prefix = data[:512].decode("utf-8-sig")
        else:
            prefix = data[:512].decode("utf-8")
    except UnicodeError:
        return False
    stripped = prefix.lstrip()
    return stripped.startswith("<?xml") and "<plist" in stripped


def normalized_plist_key(key: object) -> str:
    return re.sub(r"[^a-z0-9]", "", str(key).casefold())


def plist_value_contains_team_id(value: object, *, requires_prefix: bool) -> bool:
    if isinstance(value, str):
        pattern = r"[A-Z0-9]{10}\." if requires_prefix else r"[A-Z0-9]{10}"
        return re.match(pattern, value, re.IGNORECASE) is not None
    if isinstance(value, (list, tuple)):
        return any(
            plist_value_contains_team_id(item, requires_prefix=requires_prefix)
            for item in value
        )
    return False


def plist_value_contains_team_prefix(value: object) -> bool:
    if isinstance(value, str):
        return re.match(r"[A-Z0-9]{10}\.", value, re.IGNORECASE) is not None
    if isinstance(value, dict):
        return any(plist_value_contains_team_prefix(child) for child in value.values())
    if isinstance(value, (list, tuple)):
        return any(plist_value_contains_team_prefix(child) for child in value)
    return False


def plist_team_prefix_blockers(path: Path, root: object) -> list[str]:
    if not plist_value_contains_team_prefix(root):
        return []
    return [
        "".join(
            (
                f"{render_path(path)}:1:non-neutral-team-prefix-plist:",
                "tracked plist values should not include an Apple team prefix: ",
                "[REDACTED plist context]",
            )
        )
    ]


def scan_plist_team_ids(path: Path, data: bytes) -> list[str]:
    if not is_plist_like(path, data):
        return []
    try:
        root = plistlib.loads(data)
    except Exception:  # noqa: BLE001 - malformed plist must fail closed.
        return [
            f"{render_path(path)}:1:unparseable-plist:"
            "tracked plist-like files must parse before public release: "
            "[REDACTED plist context]"
        ]

    blockers: list[str] = []

    def walk(value: object) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                normalized = normalized_plist_key(key)
                if normalized in TEAM_ID_KEYS and plist_value_contains_team_id(
                    child, requires_prefix=False
                ):
                    blockers.append(
                        "".join(
                            (
                                f"{render_path(path)}:1:non-neutral-team-plist:",
                                "tracked signing plists should not include a real ",
                                "Apple team ID: [REDACTED plist context]",
                            )
                        )
                    )
                if (
                    normalized in APPLICATION_IDENTIFIER_KEYS
                    and plist_value_contains_team_id(child, requires_prefix=True)
                ):
                    blockers.append(
                        "".join(
                            (
                                f"{render_path(path)}:1:non-neutral-application-identifier:",
                                "tracked application identifiers should not include ",
                                "a real ",
                                "Apple team ID: [REDACTED plist context]",
                            )
                        )
                    )
                walk(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                walk(child)

    walk(root)
    blockers.extend(plist_team_prefix_blockers(path, root))
    return blockers


def is_allowed_strict_match(pattern: StrictPattern, match: re.Match[str]) -> bool:
    if pattern.name == "literal-invitation-secret":
        return match.group(0) in ALLOWED_INVITATION_SECRETS
    if pattern.name == "literal-pairing-code":
        return match.group(0).upper() in ALLOWED_PAIRING_CODES
    return False


def scan_markers(paths: list[Path]) -> list[str]:
    hits: list[str] = []
    for path in paths:
        if is_intentional_visual_asset(path):
            continue
        try:
            text = read_tracked_text(path)
        except (OSError, TrackedTextDecodeError, UnicodeError):
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            hits.extend(
                "".join(
                    (
                        f"{render_path(path)}:{line_no}:marker:{marker}: ",
                        "[REDACTED marker context]",
                    )
                )
                for marker in MARKERS
                if marker in line
            )
    return hits


def public_surface_paths(paths: Iterable[Path]) -> list[Path]:
    public_paths: list[Path] = []
    for path in paths:
        path_text = path.as_posix()
        if path_text in PUBLIC_SURFACE_FILES:
            public_paths.append(path)
            continue
        if path_text.startswith(PUBLIC_SURFACE_ROOTS) and path.suffix == ".md":
            public_paths.append(path)
    return public_paths


def local_strict_patterns() -> list[StrictPattern]:
    patterns: list[StrictPattern] = []
    for denylist_path in LOCAL_DENYLIST_FILES:
        if not denylist_path.exists():
            continue
        for line_no, raw_line in enumerate(denylist_path.read_text().splitlines(), 1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("regex:"):
                regex = re.compile(line.removeprefix("regex:"))
            else:
                regex = re.compile(re.escape(line), re.IGNORECASE)
            patterns.append(
                StrictPattern(
                    name=f"local-denylist:{line_no}",
                    regex=regex,
                    reason=(
                        "tracked files should not include local private denylist values"
                    ),
                    redact_line=True,
                )
            )
    return patterns


def strict_blocker_line(
    path: Path,
    line_no: int,
    pattern: StrictPattern,
    line: str,  # noqa: ARG001 - raw context is intentionally never echoed.
) -> str:
    evidence = (
        "[REDACTED local denylist match]"
        if pattern.redact_line
        else "[REDACTED strict match context]"
    )
    return f"{render_path(path)}:{line_no}:{pattern.name}:{pattern.reason}: {evidence}"


def scan_filename_patterns(
    path: Path, patterns: tuple[StrictPattern, ...]
) -> list[str]:
    blockers: list[str] = []
    filename = path.as_posix()
    for pattern in patterns:
        filename_regex = pattern.regex
        if pattern.name == "literal-device-credential":
            filename_regex = re.compile(
                rf"hb_[{CREDENTIAL_CHARACTER_CLASS}]{{32,}}", re.IGNORECASE
            )
        elif pattern.name == "literal-invitation-secret":
            filename_regex = re.compile(
                rf"hbi_[{CREDENTIAL_CHARACTER_CLASS}]{{32,}}", re.IGNORECASE
            )
        for match in filename_regex.finditer(filename):
            if is_allowed_strict_match(pattern, match):
                continue
            blockers.append(
                "".join(
                    (
                        "[REDACTED tracked path]:1:filename-",
                        f"{pattern.name}:{pattern.reason}: ",
                        "[REDACTED filename match]",
                    )
                )
            )
    return blockers


def scan_patterns(
    path: Path,
    text: str,
    patterns: Iterable[StrictPattern],
) -> list[str]:
    blockers: list[str] = []
    xcode_settings_file = path.suffix.lower() in {".pbxproj", ".xcconfig"}
    for pattern in patterns:
        if (
            pattern.name
            in {
                "non-neutral-development-team",
                "non-neutral-bundle-identifier",
            }
            and not xcode_settings_file
        ):
            continue
        for match in pattern.regex.finditer(text):
            if is_allowed_strict_match(pattern, match):
                continue
            line_no = text.count("\n", 0, match.start()) + 1
            blockers.append(strict_blocker_line(path, line_no, pattern, match.group(0)))
    return blockers


def scan_strict_blockers(paths: Iterable[Path]) -> list[str]:
    paths = list(paths)
    blockers: list[str] = []
    local_patterns = tuple(local_strict_patterns())
    decoded_text: dict[Path, str] = {}
    for path in paths:
        path_text = path.as_posix()
        blockers.extend(
            scan_filename_patterns(path, (*GLOBAL_STRICT_PATTERNS, *local_patterns))
        )
        if any(pattern.search(path_text) for pattern in INTERNAL_DOC_PATH_PATTERNS):
            blockers.append(
                f"{render_path(path)}:internal-doc-path:public docs should not include "
                "internal plans, stage diaries, or private release checklists"
            )
        if is_intentional_visual_asset(path):
            continue
        if path.suffix.lower() in BINARYISH_SUFFIXES:
            continue
        try:
            data = path.read_bytes()
        except OSError:
            blockers.append(
                f"{render_path(path)}:1:unreadable-tracked-file:"
                "tracked files must be readable before public release: "
                "[REDACTED read error]"
            )
            continue
        blockers.extend(scan_plist_team_ids(path, data))
        try:
            text = read_tracked_text(path)
        except (TrackedTextDecodeError, UnicodeError):
            blockers.append(
                f"{render_path(path)}:1:unsupported-tracked-text-encoding:"
                "tracked non-media files must be strict UTF-8 or UTF-16 text: "
                "[REDACTED decode error]"
            )
            continue
        decoded_text[path] = text
        patterns: tuple[StrictPattern, ...] = (*GLOBAL_STRICT_PATTERNS, *local_patterns)
        if path_text in STRICT_DEFINITION_FILES:
            patterns = (*patterns, *DEFINITION_SELF_AUDIT_PATTERNS)
        blockers.extend(scan_patterns(path, text, patterns))

    for path in public_surface_paths(paths):
        if path in decoded_text:
            blockers.extend(scan_patterns(path, decoded_text[path], STRICT_PATTERNS))
    return blockers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--max-marker-lines",
        type=int,
        default=80,
        help="Maximum marker lines to print before truncating output.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help=(
            "Fail on public-surface personal/provider/private-validation markers "
            "and repository-wide private device or receiver identifiers that "
            "should be removed before repository visibility changes."
        ),
    )
    args = parser.parse_args()

    paths = git_tracked_files()
    binaryish = [
        path
        for path in paths
        if path.suffix.lower() in BINARYISH_SUFFIXES
        and not is_intentional_visual_asset(path)
    ]
    marker_hits = scan_markers(paths)
    strict_blockers = scan_strict_blockers(paths) if args.strict else []

    print("Public release tracked-file audit")
    print(f"tracked_files={len(paths)}")
    print(f"unreviewed_binaryish_tracked_files={len(binaryish)}")
    if binaryish:
        for path in binaryish:
            print(f"BINARYISH {render_path(path)}")

    print(f"marker_lines={len(marker_hits)}")
    for line in marker_hits[: args.max_marker_lines]:
        print(f"MARKER {line}")
    if len(marker_hits) > args.max_marker_lines:
        print(f"MARKER ... {len(marker_hits) - args.max_marker_lines} more lines")

    if args.strict:
        print(f"strict_blockers={len(strict_blockers)}")
        for blocker in strict_blockers:
            print(f"STRICT {blocker}")

    if binaryish:
        print(
            "FAIL: unreviewed tracked binary-ish files need manual review "
            "before public release."
        )
        return 2
    if strict_blockers:
        print("FAIL: strict public-surface blockers found.")
        return 3

    print(
        "PASS: no unreviewed tracked binary-ish files found. Marker lines are "
        "expected in docs/tests but still require manual review before public "
        "release."
    )
    if args.strict:
        print("PASS: no strict public-surface blockers found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

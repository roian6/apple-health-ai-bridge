from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Final

STABLE_VERSION_PATTERN: Final = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
LEGACY_RECEIVER_TAG_VERSIONS: Final = frozenset({"1.0.0", "1.0.1"})


class ReleaseError(ValueError):
    """Expected release-input failure safe to print to CI logs."""


@dataclass(frozen=True, order=True, slots=True)
class SemanticVersion:
    major: int
    minor: int
    patch: int

    def as_tuple(self) -> tuple[int, int, int]:
        return self.major, self.minor, self.patch

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


@dataclass(frozen=True, slots=True)
class ParsedReleaseTag:
    tag: str
    version: SemanticVersion

    @property
    def is_prerelease(self) -> bool:
        return self.version.major == 0


def parse_semantic_version(value: str, *, surface: str) -> SemanticVersion:
    match = STABLE_VERSION_PATTERN.fullmatch(value)
    if match is None:
        message = f"{surface} must be a stable semantic version"
        raise ReleaseError(message)
    major, minor, patch = match.groups()
    return SemanticVersion(int(major), int(minor), int(patch))


def canonical_receiver_tag(version: str) -> str:
    parsed = parse_semantic_version(version, surface="Receiver/CLI version")
    if version in LEGACY_RECEIVER_TAG_VERSIONS:
        return f"v{parsed}"
    return f"receiver-v{parsed}"


def parse_receiver_release_tag(tag: str) -> ParsedReleaseTag:
    if tag.startswith("receiver-v"):
        version_text = tag.removeprefix("receiver-v")
    elif tag.startswith("v"):
        version_text = tag.removeprefix("v")
    else:
        message = "Receiver/CLI release tag is not canonical"
        raise ReleaseError(message)
    try:
        version = parse_semantic_version(
            version_text,
            surface="Receiver/CLI release tag",
        )
    except ReleaseError as exc:
        message = "Receiver/CLI release tag is not canonical"
        raise ReleaseError(message) from exc
    if canonical_receiver_tag(str(version)) != tag:
        message = "Receiver/CLI release tag is not canonical"
        raise ReleaseError(message)
    return ParsedReleaseTag(tag=tag, version=version)

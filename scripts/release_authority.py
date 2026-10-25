#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import subprocess
from typing import TYPE_CHECKING, Annotated, ClassVar, Final, Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field, JsonValue, TypeAdapter
from release_versions import ReleaseError

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

REPOSITORY: Final = "roian6/apple-health-ai-bridge"
POLICY_PATH: Final = ".github/release/release-policy.json"
GitSha = Annotated[str, Field(pattern=r"^[0-9a-f]{40}$")]
Digest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
PAGE_SIZE: Final = 100


class Document(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, extra="forbid", strict=True
    )


class ArtifactRecord(Document):
    name: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
    size: int = Field(ge=0)
    sha256: Digest


class RetiredTag(Document):
    tag: str
    tag_object: GitSha
    commit: GitSha
    reason: str = Field(min_length=1)


class ReleasePolicy(Document):
    schema_id: Literal["health_bridge.release_policy.v1"]
    source_ref: Literal["refs/heads/release"]
    signer_login: Literal["roian6"]
    required_checks: dict[str, str]
    revoked_commits: list[GitSha]
    revoked_tag_objects: list[GitSha]
    retired_tags: list[RetiredTag]


class JsonLoader(Protocol):
    def __call__(
        self,
        raw: str,
        /,
        *,
        object_pairs_hook: Callable[
            [list[tuple[str, JsonValue]]], dict[str, JsonValue]
        ],
    ) -> JsonValue: ...


def unique_object(pairs: list[tuple[str, JsonValue]]) -> dict[str, JsonValue]:
    result: dict[str, JsonValue] = {}
    for key, value in pairs:
        if key in result:
            message = "duplicate trusted policy field"
            raise ReleaseError(message)
        result[key] = value
    return result


def parse_policy(raw: str, loader: JsonLoader = json.loads) -> ReleasePolicy:
    try:
        value = loader(raw, object_pairs_hook=unique_object)
    except json.JSONDecodeError as exc:
        message = "invalid trusted release policy JSON"
        raise ReleaseError(message) from exc
    policy = ReleasePolicy.model_validate(value)
    tags = [entry.tag for entry in policy.retired_tags]
    if len(tags) != len(set(tags)):
        message = "duplicate retired candidate identity"
        raise ReleaseError(message)
    return policy


class Baseline(Document):
    tag: str
    tag_object: GitSha
    commit: GitSha
    release_id: int | None


class SourceReceipt(Document):
    schema_id: Literal["health_bridge.source_receipt.v1"] = (
        "health_bridge.source_receipt.v1"
    )
    default_main_commit: GitSha
    baseline_commit: GitSha
    source_commit: GitSha
    source_tree: GitSha
    source_tag: str
    tag_object: GitSha
    remote_tag_verification: Literal["pending", "verified"] = "verified"
    baseline: Baseline
    compatibility_baseline: Baseline | None = None
    pull_request: int
    reviewed_head: GitSha
    check_runs: dict[str, int]


def command(
    repo: Path, executable: str, *args: str, data: bytes | None = None
) -> bytes:
    resolved = shutil.which(executable)
    if resolved is None:
        msg = f"release requires {executable}"
        raise ReleaseError(msg)
    try:
        result = subprocess.run(  # noqa: S603
            [resolved, *args],
            cwd=repo,
            input=data,
            capture_output=True,
            check=False,
            timeout=120,
        )
    except subprocess.TimeoutExpired as exc:
        msg = f"release {executable} lookup timed out"
        raise ReleaseError(msg) from exc
    if result.returncode:
        msg = f"release {executable} failed: {result.stderr.decode(errors='replace')}"
        raise ReleaseError(msg)
    return result.stdout


def git(repo: Path, *args: str) -> str:
    return command(repo, "git", "--no-replace-objects", *args).decode().strip()


def api(repo: Path, route: str) -> JsonValue:
    return TypeAdapter[JsonValue](JsonValue).validate_json(
        command(repo, "gh", "api", route)
    )


def object_value(value: JsonValue) -> dict[str, JsonValue]:
    if not isinstance(value, dict):
        msg = "expected GitHub JSON object"
        raise ReleaseError(msg)
    return value


def array_value(value: JsonValue) -> list[JsonValue]:
    if not isinstance(value, list):
        msg = "expected GitHub JSON array"
        raise ReleaseError(msg)
    return value


def repository_api(repo: Path, route: str) -> dict[str, JsonValue]:
    return object_value(api(repo, f"/repos/{REPOSITORY}{route}"))


def pages(
    repo: Path, route: str, collection: str | None = None
) -> list[dict[str, JsonValue]]:
    separator = "&" if "?" in route else "?"
    result: list[dict[str, JsonValue]] = []
    for page in range(1, 101):
        payload = api(
            repo, f"/repos/{REPOSITORY}{route}{separator}per_page=100&page={page}"
        )
        values = array_value(
            payload if collection is None else object_value(payload).get(collection)
        )
        result.extend(object_value(value) for value in values)
        if len(values) < PAGE_SIZE:
            return result
    msg = "GitHub pagination exceeds bounded release lookup"
    raise ReleaseError(msg)


def string(value: JsonValue) -> str:
    if not isinstance(value, str):
        msg = "expected GitHub string"
        raise ReleaseError(msg)
    return value


def integer(value: JsonValue) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        msg = "expected positive GitHub identity"
        raise ReleaseError(msg)
    return value


def verified(value: JsonValue) -> None:
    verification = object_value(value)
    if (
        verification.get("verified") is not True
        or verification.get("reason") != "valid"
    ):
        msg = "GitHub signature verification is not valid"
        raise ReleaseError(msg)


def trusted_policy(repo: Path) -> tuple[str, ReleasePolicy]:
    repository = repository_api(repo, "")
    if (
        repository.get("default_branch") != "main"
        or repository.get("full_name") != REPOSITORY
    ):
        msg = "release authority must be default main"
        raise ReleaseError(msg)
    branch = repository_api(repo, "/branches/main")
    if branch.get("protected") is not True or branch.get("name") != "main":
        msg = "release authority main is not protected"
        raise ReleaseError(msg)
    main = TypeAdapter[str](GitSha).validate_python(
        object_value(branch.get("commit")).get("sha")
    )
    _ = git(repo, "fetch", "--no-tags", "origin", main)
    policy = parse_policy(git(repo, "show", f"{main}:{POLICY_PATH}"))
    required = {
        "Python quality and package checks": "python.yml",
        "Swift tests and unsigned app builds": "ios.yml",
        "Analyze Python": "codeql.yml",
    }
    if policy.required_checks != required:
        msg = "required release checks must retain exact contexts and workflows"
        raise ReleaseError(msg)
    return main, policy


def public_tag(repo: Path, tag: str) -> tuple[str, str]:
    ref = object_value(repository_api(repo, f"/git/ref/tags/{tag}").get("object"))
    oid = TypeAdapter[str](GitSha).validate_python(ref.get("sha"))
    record = repository_api(repo, f"/git/tags/{oid}")
    target = object_value(record.get("object"))
    if (
        ref.get("type") != "tag"
        or record.get("sha") != oid
        or record.get("tag") != tag
        or target.get("type") != "commit"
    ):
        msg = "public tag identity is not an annotated commit tag"
        raise ReleaseError(msg)
    verified(record.get("verification"))
    tagger = object_value(record.get("tagger"))
    if (
        tagger.get("name") != "Chanhyo Jung"
        or tagger.get("email") != "23256775+roian6" + "@users.noreply.github.com"
    ):
        message = "public signed tag maintainer identity mismatch"
        raise ReleaseError(message)
    commit = TypeAdapter[str](GitSha).validate_python(target.get("sha"))
    _ = git(repo, "fetch", "--no-tags", "origin", oid)
    if git(repo, "rev-parse", f"{oid}^{{commit}}") != commit:
        msg = "public tag object target mismatch"
        raise ReleaseError(msg)
    return oid, commit


def canonical_json(document: BaseModel) -> str:
    return (
        json.dumps(
            document.model_dump(mode="json"), sort_keys=True, separators=(",", ":")
        )
        + "\n"
    )

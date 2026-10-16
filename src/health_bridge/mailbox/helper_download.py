import hashlib
import socket
import tempfile
import time
from http import HTTPStatus
from pathlib import Path
from typing import Literal, Self
from urllib.parse import urlsplit

import httpx2
from pydantic import BaseModel, Field, model_validator

from health_bridge import __version__
from health_bridge.mailbox.helper_lifecycle import (
    MAX_ARCHIVE_BYTES,
    MAX_MANIFEST_BYTES,
    HelperResult,
    HelperStatusCode,
    install_helper,
    read_helper_status,
    validate_general_distribution_helper_release,
)

REPOSITORY = "roian6/apple-health-ai-bridge"
API = f"https://api.github.com/repos/{REPOSITORY}"
SOURCE_TREE = "401d5732b9e78087db8f70d9d34d98216490410d"
TAG = f"receiver-v{__version__}"
SHA = r"^[0-9a-f]{40}$"


class Asset(BaseModel):
    name: str
    size: int = Field(gt=0, le=MAX_ARCHIVE_BYTES)
    digest: str = Field(pattern=r"^sha256:[0-9a-f]{64}$")
    browser_download_url: str


class Release(BaseModel):
    tag_name: str
    draft: Literal[False]
    prerelease: Literal[False]
    assets: list[Asset]

    @model_validator(mode="after")
    def compatible(self) -> Self:
        if self.tag_name != TAG or len({asset.name for asset in self.assets}) != len(
            self.assets
        ):
            message = "Release does not match this installed version."
            raise ValueError(message)
        return self


class GitIdentity(BaseModel):
    tag: str
    tag_object: str = Field(pattern=SHA)
    commit: str = Field(pattern=SHA)
    tree: str = Field(pattern=SHA)


class Metadata(BaseModel):
    release_version: str
    git: GitIdentity


class GitObject(BaseModel):
    sha: str = Field(pattern=SHA)
    type: Literal["commit", "tag", "tree"]


class GitReference(BaseModel):
    object: GitObject


class CommitTree(BaseModel):
    sha: str = Field(pattern=SHA)


class GitCommit(BaseModel):
    tree: CommitTree


def require_release_url(url: str) -> None:
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname
        not in {"api.github.com", "github.com", "release-assets.githubusercontent.com"}
        or parsed.username
        or parsed.password
        or parsed.port not in {None, 443}
    ):
        message = "Helper download requires the official HTTPS release route."
        raise ValueError(message)


def checked_bytes(data: bytes, digest: str) -> bytes:
    if hashlib.sha256(data).hexdigest() != digest:
        message = "Helper release digest mismatch; existing helper was not changed."
        raise ValueError(message)
    return data


def download(client: httpx2.Client, url: str, limit: int) -> bytes:
    deadline = time.monotonic() + 60
    for _ in range(4):
        require_release_url(url)
        with client.stream("GET", url, follow_redirects=False) as response:
            if response.status_code in {301, 302, 303, 307, 308}:
                url = str(response.url.join(response.headers["location"]))
                continue
            if response.status_code == HTTPStatus.NOT_FOUND:
                message = "Signed helper not available yet. Choose Tailscale or back."
                raise ValueError(message)
            _ = response.raise_for_status()
            result = bytearray()
            for chunk in response.iter_bytes(65536):
                if len(result) + len(chunk) > limit or time.monotonic() > deadline:
                    message = "Helper download exceeded its size or time limit."
                    raise ValueError(message)
                result.extend(chunk)
            return bytes(result)
    message = "Helper download exceeded its redirect limit."
    raise ValueError(message)


def asset_bytes(client: httpx2.Client, release: Release, name: str) -> bytes:
    assets = [asset for asset in release.assets if asset.name == name]
    if len(assets) != 1:
        message = "Signed assets not available yet. Choose Tailscale or back."
        raise ValueError(message)
    asset = assets[0]
    expected = f"https://github.com/{REPOSITORY}/releases/download/{TAG}/{name}"
    if asset.browser_download_url != expected:
        message = "Helper asset does not belong to the expected release."
        raise ValueError(message)
    limit = MAX_ARCHIVE_BYTES if name.endswith(".zip") else MAX_MANIFEST_BYTES
    data = checked_bytes(
        download(client, expected, limit), asset.digest.removeprefix("sha256:")
    )
    if len(data) != asset.size:
        message = "Helper asset size does not match the release."
        raise ValueError(message)
    return data


def install_published_helper() -> HelperResult:
    status = read_helper_status(expected_version=__version__)
    if status.code is HelperStatusCode.READY:
        return status
    if status.code is not HelperStatusCode.NOT_INSTALLED:
        message = "Helper kept; choose another route and inspect helper status."
        raise ValueError(message)
    transport = httpx2.HTTPTransport(
        http2=True,
        retries=3,
        socket_options=[(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)],
    )
    with httpx2.Client(
        transport=transport,
        timeout=httpx2.Timeout(connect=5, read=10, write=10, pool=10),
        limits=httpx2.Limits(
            max_connections=200, max_keepalive_connections=40, keepalive_expiry=30
        ),
        trust_env=False,
    ) as client:
        release = Release.model_validate_json(
            download(client, f"{API}/releases/tags/{TAG}", MAX_MANIFEST_BYTES)
        )
        metadata = Metadata.model_validate_json(
            asset_bytes(client, release, "release-metadata.json")
        )
        ref = GitReference.model_validate_json(
            download(client, f"{API}/git/ref/tags/{TAG}", MAX_MANIFEST_BYTES)
        )
        if ref.object.type != "tag" or ref.object.sha != metadata.git.tag_object:
            message = "Helper release tag identity mismatch."
            raise ValueError(message)
        tag = GitReference.model_validate_json(
            download(client, f"{API}/git/tags/{ref.object.sha}", MAX_MANIFEST_BYTES)
        )
        commit = GitCommit.model_validate_json(
            download(client, f"{API}/git/commits/{tag.object.sha}", MAX_MANIFEST_BYTES)
        )
        if (
            tag.object.type != "commit"
            or tag.object.sha != metadata.git.commit
            or commit.tree.sha != metadata.git.tree
            or metadata.git.tag != TAG
            or metadata.release_version != __version__
        ):
            message = "Helper release commit or version mismatch."
            raise ValueError(message)
        archive_name = f"HealthBridgeMailboxAckPublisher-{__version__}.zip"
        manifest_name = f"HealthBridgeMailboxAckPublisher-{__version__}.manifest.json"
        manifest_bytes = asset_bytes(client, release, manifest_name)
        archive_bytes = asset_bytes(client, release, archive_name)
    with tempfile.TemporaryDirectory(prefix="health-bridge-helper-") as temporary:
        root = Path(temporary)
        archive, manifest = root / archive_name, root / manifest_name
        _ = archive.write_bytes(archive_bytes)
        _ = manifest.write_bytes(manifest_bytes)
        _ = validate_general_distribution_helper_release(
            archive,
            manifest,
            expected_release=(
                TAG,
                metadata.git.tag_object,
                metadata.git.commit,
                metadata.git.tree,
            ),
            expected_source_tree=SOURCE_TREE,
            expected_version=__version__,
        )
        return install_helper(archive, manifest)

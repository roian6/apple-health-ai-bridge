#!/usr/bin/env python3
from __future__ import annotations

import base64
import binascii
import re
import shutil
import tempfile
from pathlib import Path
from typing import TYPE_CHECKING, Final

from release_authority import (
    api,
    array_value,
    command,
    git,
    object_value,
    string,
    trusted_policy,
)
from release_baseline import IOS_TAG
from release_versions import ReleaseError, parse_receiver_release_tag

if TYPE_CHECKING:
    from release_candidate_model import CandidateIdentity

MAX_TAG_INPUT: Final = 60000
SSH_KEY: Final = re.compile(
    r"(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+/=]+"
)


def decode_signed_tag(identity: CandidateIdentity, encoded: str) -> bytes:
    if identity.tag.startswith("ios-v"):
        if IOS_TAG.fullmatch(identity.tag) is None:
            message = "invalid signed iOS checkpoint tag"
            raise ReleaseError(message)
    else:
        _ = parse_receiver_release_tag(identity.tag)
    if len(encoded) > MAX_TAG_INPUT:
        message = "signed tag dispatch exceeds bounded input size"
        raise ReleaseError(message)
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as exc:
        message = "signed tag must be canonical base64"
        raise ReleaseError(message) from exc
    if base64.b64encode(raw).decode() != encoded:
        message = "signed tag base64 is not canonical"
        raise ReleaseError(message)
    header = raw.split(b"\n\n", 1)[0].decode("utf-8")
    expected = f"object {identity.commit}\ntype commit\ntag {identity.tag}\n"
    tagger = "tagger Chanhyo Jung <23256775+roian6" + "@users.noreply.github.com> "
    if (
        not header.startswith(expected + tagger)
        or b"-----BEGIN SSH SIGNATURE-----\n" not in raw
    ):
        message = "signed tag header, tagger or signature type mismatch"
        raise ReleaseError(message)
    return raw


def registered_signers(repo: Path, identity: CandidateIdentity) -> str:
    _, policy = trusted_policy(repo)
    if (
        identity.commit in policy.revoked_commits
        or identity.tag_object in policy.revoked_tag_objects
        or any(entry.tag == identity.tag for entry in policy.retired_tags)
    ):
        message = "candidate is explicitly revoked or retired"
        raise ReleaseError(message)
    keys = array_value(
        api(repo, f"/users/{policy.signer_login}/ssh_signing_keys?per_page=100")
    )
    allowed: list[str] = []
    for record in keys:
        key = string(object_value(record).get("key"))
        if SSH_KEY.fullmatch(key) is None:
            message = "registered SSH signing key has invalid encoding"
            raise ReleaseError(message)
        allowed.append(f"{policy.signer_login} {key}\n")
    if not allowed:
        message = "maintainer has no registered SSH signing key"
        raise ReleaseError(message)
    return "".join(allowed)


def owned_checkout(repo: Path, identity: CandidateIdentity) -> Path:
    common = Path(git(repo, "rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = repo / common
    if common.resolve() != (repo / ".git").resolve() or not (repo / ".git").is_dir():
        message = "tag import requires an owned independent checkout"
        raise ReleaseError(message)
    if (
        git(repo, "rev-parse", "HEAD") != identity.commit
        or git(repo, "rev-parse", "HEAD^{tree}") != identity.tree
        or git(repo, "rev-parse", "HEAD:macos/HealthBridgeMailboxAckPublisher")
        != identity.helper_tree
    ):
        message = "signed tag source differs from owned checkout"
        raise ReleaseError(message)
    return common


def import_local_tag(repo: Path, identity: CandidateIdentity, encoded: str) -> None:
    raw = decode_signed_tag(identity, encoded)
    common = owned_checkout(repo, identity)
    if (
        command(repo, "git", "hash-object", "-t", "tag", "--stdin", data=raw)
        .decode()
        .strip()
        != identity.tag_object
    ):
        message = "raw signed tag object hash mismatch"
        raise ReleaseError(message)
    allowed = registered_signers(repo, identity)
    existing = git(repo, "tag", "--list", identity.tag)
    if (
        existing
        and git(repo, "rev-parse", f"refs/tags/{identity.tag}") != identity.tag_object
    ):
        message = "existing local candidate tag differs; never replace it"
        raise ReleaseError(message)
    ssh_keygen = shutil.which("ssh-keygen")
    if ssh_keygen is None:
        message = "native SSH signature verifier is required"
        raise ReleaseError(message)
    _ = command(repo, "git", "hash-object", "-w", "-t", "tag", "--stdin", data=raw)
    with tempfile.NamedTemporaryFile(mode="w", dir=common, encoding="utf-8") as signers:
        _ = signers.write(allowed)
        signers.flush()
        _ = git(
            repo,
            "-c",
            "gpg.format=ssh",
            "-c",
            f"gpg.ssh.program={ssh_keygen}",
            "-c",
            f"gpg.ssh.allowedSignersFile={signers.name}",
            "verify-tag",
            identity.tag_object,
        )
    if git(repo, "rev-parse", f"{identity.tag_object}^{{commit}}") != identity.commit:
        message = "signed tag does not peel to candidate source"
        raise ReleaseError(message)
    if not existing:
        _ = git(
            repo,
            "update-ref",
            f"refs/tags/{identity.tag}",
            identity.tag_object,
            "0" * 40,
        )

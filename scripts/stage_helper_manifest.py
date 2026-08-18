#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Final

from health_bridge.mailbox.helper_distribution_contract import (
    HelperError,
    require_approved_helper_distribution,
)
from health_bridge.mailbox.helper_lifecycle import (
    HELPER_COMPONENT,
    HELPER_SOURCE_PATH,
    validate_helper_release,
)

_SHA_LENGTH: Final = 40
_UNAPPROVED_IDENTITY_MESSAGE: Final = "helper distribution identity is not approved"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create a public helper manifest.")
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--tag-object", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tree", required=True)
    parser.add_argument("--source-tree", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--icloud-container-identifier", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--signing-authority", required=True)
    parser.add_argument("--team-identifier", required=True)
    parser.add_argument("--notary-submission-id", required=True)
    return parser


def _lower_git_sha(value: str) -> bool:
    return len(value) == _SHA_LENGTH and all(
        character in "0123456789abcdef" for character in value
    )


def main() -> int:
    args = _parser().parse_args()
    try:
        require_approved_helper_distribution(
            signing_authority=args.signing_authority,
            team_identifier=args.team_identifier,
            bundle_identifier=args.bundle_identifier,
            icloud_container_identifier=args.icloud_container_identifier,
        )
    except HelperError as exc:
        raise SystemExit(_UNAPPROVED_IDENTITY_MESSAGE) from exc
    identities = (args.tag_object, args.commit, args.tree, args.source_tree)
    if any(not _lower_git_sha(value) for value in identities):
        message = "source identity must use lowercase Git object IDs"
        raise SystemExit(message)
    if args.tag != f"receiver-v{args.version}":
        message = "tag and helper version do not match"
        raise SystemExit(message)
    if args.archive.name != f"{HELPER_COMPONENT}-{args.version}.zip":
        message = "helper archive name is not deterministic"
        raise SystemExit(message)
    if args.output.exists():
        message = "refusing to replace a helper manifest"
        raise SystemExit(message)
    content = args.archive.read_bytes()
    payload = {
        "artifact": {
            "bytes": len(content),
            "filename": args.archive.name,
            "sha256": hashlib.sha256(content).hexdigest(),
        },
        "bundle": {
            "build": args.build,
            "identifier": args.bundle_identifier,
            "icloud_container_identifier": args.icloud_container_identifier,
            "version": args.version,
        },
        "component": HELPER_COMPONENT,
        "release": {
            "commit": args.commit,
            "tag": args.tag,
            "tag_object": args.tag_object,
            "tree": args.tree,
        },
        "schema_id": "health_bridge.mailbox_ack_helper.release.v2",
        "schema_version": 2,
        "source": {"git_tree": args.source_tree, "path": HELPER_SOURCE_PATH},
        "distribution": {
            "signing_authority": args.signing_authority,
            "team_identifier": args.team_identifier,
            "provisioning_profile": {
                "provisions_all_devices": True,
                "application_identifier": (
                    f"{args.team_identifier}.{args.bundle_identifier}"
                ),
                "team_identifier": args.team_identifier,
                "icloud_container_environment": "Production",
                "icloud_container_identifiers": [args.icloud_container_identifier],
                "ubiquity_container_identifiers": [args.icloud_container_identifier],
            },
            "secure_timestamp": True,
            "hardened_runtime": True,
            "notarization": {
                "status": "Accepted",
                "submission_id": args.notary_submission_id,
            },
            "stapled_ticket": True,
            "gatekeeper_assessment": "accepted",
        },
    }
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(args.output, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=False) as output:
            json.dump(payload, output, indent=2, sort_keys=True)
            _ = output.write("\n")
            output.flush()
            os.fsync(output.fileno())
    finally:
        os.close(descriptor)
    _ = validate_helper_release(
        args.archive,
        args.output,
        expected_release=(args.tag, args.tag_object, args.commit, args.tree),
        expected_source_tree=args.source_tree,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

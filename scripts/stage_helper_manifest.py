#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Final

from health_bridge.mailbox.helper_lifecycle import (
    HELPER_COMPONENT,
    HELPER_SOURCE_PATH,
    validate_helper_release,
)

_SHA_LENGTH: Final = 40


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
    return parser


def _lower_git_sha(value: str) -> bool:
    return len(value) == _SHA_LENGTH and all(
        character in "0123456789abcdef" for character in value
    )


def main() -> int:
    args = _parser().parse_args()
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
        "schema_id": "health_bridge.mailbox_ack_helper.release.v1",
        "schema_version": 1,
        "source": {"git_tree": args.source_tree, "path": HELPER_SOURCE_PATH},
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

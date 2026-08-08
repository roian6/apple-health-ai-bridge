#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import final

from health_bridge.mailbox_qa.m3_validator import validate_m3_v1


@final
class Arguments(argparse.Namespace):
    strict: bool = False
    commit: str = ""
    manifest: Path = Path()
    m2_manifest: Path = Path()
    anchor: Path = Path()
    production_seal: Path = Path()
    production_seal_anchor_sha256: str = ""


def main() -> int:
    parser = argparse.ArgumentParser()
    _ = parser.add_argument("--strict", action="store_true")
    _ = parser.add_argument("--commit", required=True)
    _ = parser.add_argument("--manifest", type=Path, required=True)
    _ = parser.add_argument("--m2-manifest", type=Path, required=True)
    _ = parser.add_argument("--anchor", type=Path, required=True)
    _ = parser.add_argument("--production-seal", type=Path, required=True)
    _ = parser.add_argument(
        "--production-seal-anchor-sha256",
        required=True,
    )
    args = parser.parse_args(namespace=Arguments())
    if not args.strict:
        _ = sys.stdout.write("FAIL M3 unsupported_invocation\n")
        return 1
    status, output = validate_m3_v1(
        args.manifest,
        args.m2_manifest,
        args.anchor,
        args.production_seal,
        production_seal_anchor_sha256=args.production_seal_anchor_sha256,
        expected_commit=args.commit,
    )
    _ = sys.stdout.write(output)
    return status


if __name__ == "__main__":
    raise SystemExit(main())

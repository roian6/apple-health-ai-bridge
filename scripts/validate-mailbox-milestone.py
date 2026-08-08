#!/usr/bin/env python3
# pyright: reportImplicitRelativeImport=false
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Final, final

from mailbox_m1_files import read_scoped_regular_file

from health_bridge.mailbox_m1_validator import (
    M1ValidationContext,
    validate_m1_manifest,
)

DEFAULT_MANIFEST: Final = "tests/fixtures/mailbox_m1/manifest.synthetic.json"


@final
class CliArgs(argparse.Namespace):
    def __init__(self) -> None:
        super().__init__()
        self.milestone = ""
        self.strict = False
        self.commit = ""
        self.manifest = DEFAULT_MANIFEST


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    _ = parser.add_argument("--milestone", required=True)
    _ = parser.add_argument("--strict", action="store_true")
    _ = parser.add_argument("--commit", required=True)
    _ = parser.add_argument("--manifest", default=DEFAULT_MANIFEST)
    return parser


def main() -> int:
    args = _parser().parse_args(namespace=CliArgs())
    if args.milestone == "M2":
        from health_bridge.mailbox_m2_validator import (  # noqa: PLC0415
            validate_m2_manifest,
        )

        if not args.strict:
            _ = sys.stdout.write("FAIL M2 unsupported_invocation\n")
            return 1
        status, output = validate_m2_manifest(Path(args.manifest), args.commit)
        _ = sys.stdout.write(output)
        return status
    if args.milestone != "M1" or not args.strict:
        _ = sys.stdout.write("FAIL M1 unsupported_invocation\n")
        return 1
    status, output = validate_m1_manifest(
        Path(args.manifest),
        args.commit,
        M1ValidationContext(
            repository_root=Path(__file__).resolve().parents[1],
            file_reader=read_scoped_regular_file,
        ),
    )
    _ = sys.stdout.write(output)
    return status


if __name__ == "__main__":
    sys.exit(main())

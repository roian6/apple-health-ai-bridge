#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# uv run python scripts/verify_helper_distribution.py --help

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Final

from health_bridge.mailbox.helper_distribution_contract import (
    HelperError,
    HelperErrorCode,
)
from health_bridge.mailbox.helper_distribution_verifier import (
    DistributionVerificationRequest,
)
from health_bridge.mailbox.helper_lifecycle import (
    HELPER_APP_NAME,
    validate_helper_release,
    verify_macos_release_distribution,
)

_MACOS_REQUIRED_MESSAGE: Final = "macOS is required"
_INVALID_APP_MESSAGE: Final = "helper app path is invalid"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify a staged macOS helper's general distribution trust."
    )
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    if sys.platform != "darwin":
        raise SystemExit(_MACOS_REQUIRED_MESSAGE)
    if (
        args.app.name != HELPER_APP_NAME
        or args.app.is_symlink()
        or not args.app.is_dir()
    ):
        raise SystemExit(_INVALID_APP_MESSAGE)
    try:
        _verify(args.app, args.archive, args.manifest)
    except HelperError as exc:
        raise SystemExit(str(exc)) from exc
    _ = sys.stdout.write("helper distribution verified\n")
    return 0


def _verify(app: Path, archive: Path, manifest_path: Path) -> None:
    manifest = validate_helper_release(archive, manifest_path)
    distribution = manifest.distribution_identity
    if distribution is None:
        raise HelperError(HelperErrorCode.INVALID_MANIFEST)
    verify_macos_release_distribution(
        DistributionVerificationRequest(
            app=app,
            bundle_identifier=manifest.bundle.identifier,
            icloud_container_identifier=manifest.bundle.icloud_container_identifier,
            bundle_version=manifest.bundle.version,
            bundle_build=manifest.bundle.build,
            distribution=distribution,
        )
    )


if __name__ == "__main__":
    raise SystemExit(main())

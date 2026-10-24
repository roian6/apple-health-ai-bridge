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
import tempfile
from pathlib import Path
from typing import Final

from health_bridge.mailbox.helper_distribution_contract import (
    HELPER_RELEASE_MANIFEST_ADAPTER,
    HelperError,
    HelperErrorCode,
)
from health_bridge.mailbox.helper_distribution_verifier import (
    DistributionVerificationRequest,
)
from health_bridge.mailbox.helper_lifecycle import (
    HelperPaths,
    install_helper,
    verify_macos_release_distribution,
)

_MACOS_REQUIRED_MESSAGE: Final = "macOS is required"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Install a helper ZIP privately and verify its distribution trust."
    )
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--app",
        type=Path,
        help="Deprecated and ignored; the app is installed from --archive.",
    )
    return parser


def main() -> int:
    args = _parser().parse_args()
    if sys.platform != "darwin":
        raise SystemExit(_MACOS_REQUIRED_MESSAGE)
    try:
        _verify(args.archive, args.manifest)
    except HelperError as exc:
        raise SystemExit(str(exc)) from exc
    _ = sys.stdout.write("helper distribution verified\n")
    return 0


def _verify(archive: Path, manifest_path: Path) -> None:
    with tempfile.TemporaryDirectory(
        prefix="health-bridge-helper-verify-"
    ) as temporary:
        home = Path(temporary)
        _ = install_helper(archive, manifest_path, home=home)
        paths = HelperPaths.production(home)
        manifest = HELPER_RELEASE_MANIFEST_ADAPTER.validate_json(
            paths.manifest.read_bytes()
        )
        distribution = manifest.distribution_identity
        if distribution is None:
            raise HelperError(HelperErrorCode.INVALID_MANIFEST)
        verify_macos_release_distribution(
            DistributionVerificationRequest(
                app=paths.app,
                bundle_identifier=manifest.bundle.identifier,
                icloud_container_identifier=manifest.bundle.icloud_container_identifier,
                bundle_version=manifest.bundle.version,
                bundle_build=manifest.bundle.build,
                distribution=distribution,
            )
        )


if __name__ == "__main__":
    raise SystemExit(main())

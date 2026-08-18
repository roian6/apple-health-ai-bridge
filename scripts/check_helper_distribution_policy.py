#!/usr/bin/env python3
from __future__ import annotations

import argparse

from health_bridge.mailbox.helper_distribution_contract import (
    HelperError,
    require_approved_helper_distribution,
)

_UNAPPROVED_IDENTITY_MESSAGE = "helper distribution identity is not approved"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check the public Mailbox helper publisher policy."
    )
    parser.add_argument("--signing-authority", required=True)
    parser.add_argument("--team-identifier", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--icloud-container-identifier", required=True)
    args = parser.parse_args()
    try:
        require_approved_helper_distribution(
            signing_authority=args.signing_authority,
            team_identifier=args.team_identifier,
            bundle_identifier=args.bundle_identifier,
            icloud_container_identifier=args.icloud_container_identifier,
        )
    except HelperError as exc:
        raise SystemExit(_UNAPPROVED_IDENTITY_MESSAGE) from exc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

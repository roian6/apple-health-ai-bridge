#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import assert_never

from health_bridge._mailbox_evidence_types import EvidenceHold, EvidencePass
from health_bridge.mailbox_evidence import (
    MailboxEvidenceError,
    validate_evidence_directory,
)


class Arguments(argparse.Namespace):
    evidence: Path = Path()
    phase: str = ""
    strict: bool = False
    commit: str = ""


def main() -> int:
    parser = argparse.ArgumentParser()
    _ = parser.add_argument("evidence", type=Path)
    _ = parser.add_argument("--phase", choices=("delivery",), required=True)
    _ = parser.add_argument("--strict", action="store_true", required=True)
    _ = parser.add_argument("--commit", required=True)
    arguments = parser.parse_args(namespace=Arguments())
    try:
        outcome = validate_evidence_directory(
            arguments.evidence,
            expected_commit=arguments.commit,
        )
    except MailboxEvidenceError as exc:
        _ = sys.stderr.write(f"FAIL {exc.code.value}\n")
        return 1
    except OSError:
        _ = sys.stderr.write("FAIL anchor_state_unsafe\n")
        return 1
    match outcome:
        case EvidencePass():
            _ = sys.stdout.write("PASS mailbox physical evidence\n")
            return 0
        case EvidenceHold():
            _ = sys.stdout.write("HOLD external prerequisite unavailable\n")
            return 3
    assert_never(outcome)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/ios-device-local.env" ]]; then
  source "$SCRIPT_DIR/ios-device-local.env"
fi

: "${DEVICE_ID:?Set DEVICE_ID to the target iPhone device identifier}"
: "${BUNDLE_ID:?Set BUNDLE_ID to the installed companion bundle identifier}"

args=(xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing)
if [[ -n "${PAYLOAD_URL:-}" ]]; then
  args+=(--payload-url "$PAYLOAD_URL")
fi
args+=("$BUNDLE_ID")
"${args[@]}"

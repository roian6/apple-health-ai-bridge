#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/ios-device-local.env" ]]; then
  source "$SCRIPT_DIR/ios-device-local.env"
fi

: "${DEVICE_ID:?Set DEVICE_ID to the target iPhone device identifier}"

echo "== devicectl devices =="
xcrun devicectl list devices

echo
echo "== selected device connection =="
xcrun devicectl device info details --device "$DEVICE_ID" 2>/dev/null \
  | sed -n '/deviceProperties:/,/connectionProperties:/p;/connectionProperties:/,/capabilities:/p'

echo
echo "== xctrace devices =="
xcrun xctrace list devices | sed -n '1,20p'

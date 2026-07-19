#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT_DIR/.tmp"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/ios-device-run-local.log"
{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ios-device-run-local started"
  echo "Running from local macOS Terminal session so codesign can use GUI-unlocked keychain."
  "$SCRIPT_DIR/ios-device-status.sh"
  "$SCRIPT_DIR/ios-device-build.sh"
  "$SCRIPT_DIR/ios-device-install.sh"
  "$SCRIPT_DIR/ios-device-launch.sh"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ios-device-run-local succeeded"
} 2>&1 | tee "$LOG_FILE"
printf "\nLog: %s\n" "$LOG_FILE"
printf "Press Enter to close this window..."
read -r _

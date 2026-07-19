#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
if [[ -f "$SCRIPT_DIR/ios-device-local.env" ]]; then
  source "$SCRIPT_DIR/ios-device-local.env"
fi
IOS_DIR="$ROOT_DIR/ios/HealthBridgeCompanion"
: "${DEVICE_ID:?Set DEVICE_ID to the target iPhone device identifier}"
DERIVED_DATA="${DERIVED_DATA:-$IOS_DIR/.build/DeviceDerivedData}"
case "$DERIVED_DATA" in
  /*) ;;
  *) DERIVED_DATA="$ROOT_DIR/$DERIVED_DATA" ;;
esac
APP_PATH="${APP_PATH:-$DERIVED_DATA/Build/Products/Debug-iphoneos/HealthBridgeCompanion.app}"
case "$APP_PATH" in
  /*) ;;
  *) APP_PATH="$ROOT_DIR/$APP_PATH" ;;
esac

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

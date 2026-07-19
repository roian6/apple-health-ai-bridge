#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
if [[ -f "$SCRIPT_DIR/ios-device-local.env" ]]; then
  source "$SCRIPT_DIR/ios-device-local.env"
fi
IOS_DIR="$ROOT_DIR/ios/HealthBridgeCompanion"
: "${DEVICE_ID:?Set DEVICE_ID to the target iPhone device identifier}"
: "${BUNDLE_ID:?Set BUNDLE_ID to the companion bundle identifier for this build}"
DERIVED_DATA="${DERIVED_DATA:-$IOS_DIR/.build/DeviceDerivedData}"
case "$DERIVED_DATA" in
  /*) ;;
  *) DERIVED_DATA="$ROOT_DIR/$DERIVED_DATA" ;;
esac
build_settings=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  build_settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ -n "${CODE_SIGN_STYLE:-}" ]]; then
  build_settings+=("CODE_SIGN_STYLE=$CODE_SIGN_STYLE")
fi
if [[ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]]; then
  build_settings+=("PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE_SPECIFIER")
fi
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
  build_settings+=("PROVISIONING_PROFILE=$PROVISIONING_PROFILE")
fi
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  build_settings+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
fi

xcodebuild_args=(
  -project HealthBridgeCompanion.xcodeproj
  -scheme HealthBridgeCompanion
  -configuration Debug
  -destination "platform=iOS,id=$DEVICE_ID"
  -derivedDataPath "$DERIVED_DATA"
)
if [[ "${ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
  xcodebuild_args+=(-allowProvisioningUpdates)
fi
if [[ "${ALLOW_PROVISIONING_DEVICE_REGISTRATION:-0}" == "1" ]]; then
  xcodebuild_args+=(-allowProvisioningDeviceRegistration)
fi

cd "$IOS_DIR"
xcodebuild \
  "${xcodebuild_args[@]}" \
  "${build_settings[@]}" \
  build

echo "APP_PATH=$DERIVED_DATA/Build/Products/Debug-iphoneos/HealthBridgeCompanion.app"

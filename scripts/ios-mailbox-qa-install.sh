#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scheme="${HEALTH_BRIDGE_QA_SCHEME_NAME:-HealthBridgeCompanionMailboxQA}"
target_name="${HEALTH_BRIDGE_QA_TARGET_NAME:-HealthBridgeCompanionMailboxQA}"
url_scheme="${HEALTH_BRIDGE_QA_URL_SCHEME:-healthbridgeqa}"
python_bin="$root_dir/.venv/bin/python"
if [[ ! -x "$python_bin" ]]; then
  uv sync --frozen --directory "$root_dir" >/dev/null || exit 3
fi
: "${HEALTH_BRIDGE_PRODUCTION_SEAL:?set the caller-private production seal}"
: "${HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256:?set the private seal public-key anchor}"
: "${HEALTH_BRIDGE_QA_DEVICE_IDENTIFIER:?set the explicit QA device identifier}"
: "${HEALTH_BRIDGE_QA_APP_PATH:?set the signed QA app path}"
: "${HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER:?set the signed QA bundle identifier}"
: "${HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER:?set the signed QA iCloud container}"
: "${HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE:?set the signed QA Keychain service}"
: "${HEALTH_BRIDGE_QA_KEYCHAIN_ACCESS_GROUP:?set the signed QA Keychain access group}"
: "${HEALTH_BRIDGE_QA_OUTBOX_ROOT:?set the signed QA outbox root}"
: "${HEALTH_BRIDGE_QA_DISPLAY_IDENTITY:?set the signed QA display identity}"
: "${HEALTH_BRIDGE_QA_RECEIVER_PORT:?set the isolated QA receiver port}"
: "${HEALTH_BRIDGE_QA_RUNTIME_ROOT:?set the caller-private QA runtime root}"
: "${HEALTH_BRIDGE_QA_DATABASE_NAMESPACE:?set the QA DB namespace}"
: "${HEALTH_BRIDGE_QA_EXPECTED_COMMIT:?set the exact embedded source commit}"
: "${HEALTH_BRIDGE_QA_PROVENANCE_PATH:?set the private build provenance}"
: "${HEALTH_BRIDGE_QA_INSTALL_OBSERVATION:?set the private install observation}"

case "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" in
  *".mailboxqa") ;;
  *) exit 3 ;;
esac
test "$HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" = \
  "iCloud.$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" || exit 3
test "$HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" = \
  "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER.mailboxqa" || exit 3
case "$scheme|$target_name|$url_scheme|$HEALTH_BRIDGE_QA_OUTBOX_ROOT" in
  "HealthBridgeCompanionMailboxQA|HealthBridgeCompanionMailboxQA|healthbridgeqa|HealthBridgeMailboxQA") ;;
  "HealthBridgeCompanionPublicDocumentsQA|HealthBridgeCompanionPublicDocumentsQA|healthbridgeqa-public-documents|HealthBridgeMailboxPublicDocumentsQA") ;;
  *) exit 3 ;;
esac
test -d "$HEALTH_BRIDGE_QA_APP_PATH" || exit 3

embedded_bundle="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)"
test "$embedded_bundle" = "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" || exit 3
embedded_container="$(
  /usr/libexec/PlistBuddy -c "Print :HealthBridgeQAICloudContainerIdentifier" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)"
embedded_keychain="$(
  /usr/libexec/PlistBuddy -c "Print :HealthBridgeQAKeychainService" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)"
embedded_outbox="$(
  /usr/libexec/PlistBuddy -c "Print :HealthBridgeQAOutboxRoot" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)"
embedded_display="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)"
embedded_scheme="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)"
test "$embedded_container" = \
  "$HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" || exit 3
test "$embedded_keychain" = "$HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" || exit 3
test "$embedded_outbox" = "$HEALTH_BRIDGE_QA_OUTBOX_ROOT" || exit 3
test "$embedded_display" = "$HEALTH_BRIDGE_QA_DISPLAY_IDENTITY" || exit 3
test "$embedded_scheme" = "$url_scheme" || exit 3

embedded_commit="$(
  /usr/libexec/PlistBuddy -c "Print :HealthBridgeQASourceCommit" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)"
test "$embedded_commit" = "$HEALTH_BRIDGE_QA_EXPECTED_COMMIT" || exit 3
test "$(
  /usr/libexec/PlistBuddy -c "Print :HealthBridgeQASchemeName" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)" = "$scheme" || exit 3
test "$(
  /usr/libexec/PlistBuddy -c "Print :HealthBridgeQATargetName" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)" = "$target_name" || exit 3
printf 'PASS qa_embedded_identity\n'

qa_install_tmp="$(mktemp -d)"
chmod 700 "$qa_install_tmp"
trap 'rm -rf "$qa_install_tmp"' EXIT
entitlements="$qa_install_tmp/entitlements.plist"
inventory="$qa_install_tmp/device-apps.json"
post_inventory="$qa_install_tmp/device-apps-post-install.json"
codesign --verify --deep --strict "$HEALTH_BRIDGE_QA_APP_PATH"
codesign -d --entitlements :- "$HEALTH_BRIDGE_QA_APP_PATH" \
  >"$entitlements" 2>/dev/null
codesign_authority="$(codesign -dvvv "$HEALTH_BRIDGE_QA_APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
test -n "$codesign_authority"
certificate="$qa_install_tmp/certificate.pem"
security find-certificate -p -c "$codesign_authority" "$HOME/Library/Keychains/login.keychain-db" > "$certificate"
test -s "$certificate"
qa_codesign_sha="$(openssl x509 -in "$certificate" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')"
[[ "$qa_codesign_sha" =~ ^[0-9a-f]{64}$ ]]
executable="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
    "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist"
)"
qa_executable_sha="$(
  shasum -a 256 "$HEALTH_BRIDGE_QA_APP_PATH/$executable" | awk '{print $1}'
)"
printf 'PASS qa_signed_identity\n'
xcrun devicectl device info apps \
  --device "$HEALTH_BRIDGE_QA_DEVICE_IDENTIFIER" \
  --json-output "$inventory" >/dev/null
printf 'PASS qa_device_inventory\n'
"$python_bin" "$root_dir/scripts/production-identity-seal.py" inspect-install \
  --seal "$HEALTH_BRIDGE_PRODUCTION_SEAL" \
  --anchor-sha256 "$HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256" \
  --scheme-name "$scheme" \
  --target-name "$target_name" \
  --bundle-identifier "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" \
  --container-identifier "$HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" \
  --url-scheme "$url_scheme" \
  --keychain-service "$HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" \
  --keychain-access-group "$HEALTH_BRIDGE_QA_KEYCHAIN_ACCESS_GROUP" \
  --outbox-root "$HEALTH_BRIDGE_QA_OUTBOX_ROOT" \
  --display-identity "$HEALTH_BRIDGE_QA_DISPLAY_IDENTITY" \
  --receiver-port "$HEALTH_BRIDGE_QA_RECEIVER_PORT" \
  --runtime-root "$HEALTH_BRIDGE_QA_RUNTIME_ROOT" \
  --database-namespace "$HEALTH_BRIDGE_QA_DATABASE_NAMESPACE" \
  --app-path "$HEALTH_BRIDGE_QA_APP_PATH" \
  --info-plist "$HEALTH_BRIDGE_QA_APP_PATH/Info.plist" \
  --entitlements-plist "$entitlements" \
  --inventory "$inventory" \
  --expected-commit "$HEALTH_BRIDGE_QA_EXPECTED_COMMIT" \
  --qa-executable-sha256 "$qa_executable_sha" \
  --qa-codesign-identity-sha256 "$qa_codesign_sha" \
  --provenance "$HEALTH_BRIDGE_QA_PROVENANCE_PATH" \
  --inspection-observation "$HEALTH_BRIDGE_QA_INSTALL_OBSERVATION" >/dev/null
printf 'PASS qa_install_preflight\n'

if ! xcrun devicectl device install app \
  --device "$HEALTH_BRIDGE_QA_DEVICE_IDENTIFIER" \
  "$HEALTH_BRIDGE_QA_APP_PATH"; then
  printf 'HOLD external prerequisite unavailable\n'
  exit 3
fi
xcrun devicectl device info apps \
  --device "$HEALTH_BRIDGE_QA_DEVICE_IDENTIFIER" \
  --json-output "$post_inventory" >/dev/null
"$python_bin" "$root_dir/scripts/production-identity-seal.py" confirm-install \
  --seal "$HEALTH_BRIDGE_PRODUCTION_SEAL" \
  --anchor-sha256 "$HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256" \
  --scheme-name "$scheme" \
  --target-name "$target_name" \
  --bundle-identifier "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" \
  --container-identifier "$HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" \
  --url-scheme "$url_scheme" \
  --keychain-service "$HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" \
  --keychain-access-group "$HEALTH_BRIDGE_QA_KEYCHAIN_ACCESS_GROUP" \
  --outbox-root "$HEALTH_BRIDGE_QA_OUTBOX_ROOT" \
  --display-identity "$HEALTH_BRIDGE_QA_DISPLAY_IDENTITY" \
  --receiver-port "$HEALTH_BRIDGE_QA_RECEIVER_PORT" \
  --runtime-root "$HEALTH_BRIDGE_QA_RUNTIME_ROOT" \
  --database-namespace "$HEALTH_BRIDGE_QA_DATABASE_NAMESPACE" \
  --app-path "$HEALTH_BRIDGE_QA_APP_PATH" \
  --inventory "$post_inventory" >/dev/null
printf 'PASS qa_install_confirmed\n'

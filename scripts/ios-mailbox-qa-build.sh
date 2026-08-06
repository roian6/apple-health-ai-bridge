#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root_dir/ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj"
project_file="$project/project.pbxproj"
scheme="${HEALTH_BRIDGE_QA_SCHEME_NAME:-HealthBridgeCompanionMailboxQA}"
target_name="${HEALTH_BRIDGE_QA_TARGET_NAME:-HealthBridgeCompanionMailboxQA}"
url_scheme="${HEALTH_BRIDGE_QA_URL_SCHEME:-healthbridgeqa}"
code_sign_style="${HEALTH_BRIDGE_QA_CODE_SIGN_STYLE:-Automatic}"
profile_specifier="${HEALTH_BRIDGE_QA_PROVISIONING_PROFILE_SPECIFIER:-}"

: "${HEALTH_BRIDGE_PRODUCTION_SEAL:?set the caller-private production seal}"
: "${HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256:?set the private seal public-key anchor}"
: "${HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER:?set a QA bundle identifier}"
: "${HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER:?set a QA iCloud container}"
: "${HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE:?set a QA Keychain service}"
: "${HEALTH_BRIDGE_QA_KEYCHAIN_ACCESS_GROUP:?set a QA Keychain access group}"
: "${HEALTH_BRIDGE_QA_OUTBOX_ROOT:?set a QA outbox root}"
: "${HEALTH_BRIDGE_QA_DISPLAY_IDENTITY:?set the QA app display identity}"
: "${HEALTH_BRIDGE_QA_RECEIVER_PORT:?set the isolated QA receiver port}"
: "${HEALTH_BRIDGE_QA_RUNTIME_ROOT:?set the caller-private QA runtime root}"
: "${HEALTH_BRIDGE_QA_DATABASE_NAMESPACE:?set the QA DB namespace}"
: "${HEALTH_BRIDGE_QA_DEVELOPMENT_TEAM:?set the QA signing team at invocation time}"
: "${HEALTH_BRIDGE_QA_ARCHIVE_PATH:?set a caller-private archive path outside Git}"
: "${HEALTH_BRIDGE_QA_PROVENANCE_PATH:?set a caller-private provenance path}"

xcodebuild_command=(xcodebuild)
case "${HEALTH_BRIDGE_QA_ALLOW_PROVISIONING_UPDATES:-0}" in
  0) ;;
  1) xcodebuild_command+=(-allowProvisioningUpdates) ;;
  *) exit 3 ;;
esac

case "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" in
  *".mailboxqa") ;;
  *) exit 3 ;;
esac
test "$HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" = \
  "iCloud.$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" || exit 3
test "$HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" = \
  "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER.mailboxqa" || exit 3
case "$scheme|$target_name|$url_scheme|$HEALTH_BRIDGE_QA_OUTBOX_ROOT" in
  "HealthBridgeCompanionMailboxQA|HealthBridgeCompanionMailboxQA|healthbridgeqa|HealthBridgeMailboxQA")
    test "$code_sign_style" = "Automatic" || exit 3
    test -z "$profile_specifier" || exit 3
    ;;
  "HealthBridgeCompanionPublicDocumentsQA|HealthBridgeCompanionPublicDocumentsQA|healthbridgeqa-public-documents|HealthBridgeMailboxPublicDocumentsQA")
    test "$code_sign_style" = "Manual" || exit 3
    test -n "$profile_specifier" || exit 3
    ;;
  *) exit 3 ;;
esac

archive_parent="$(
  cd "$(dirname "$HEALTH_BRIDGE_QA_ARCHIVE_PATH")" && pwd -P
)" || exit 3
archive_path="$archive_parent/$(basename "$HEALTH_BRIDGE_QA_ARCHIVE_PATH")"
case "$archive_path" in
  "$root_dir"|"$root_dir"/*) exit 3 ;;
esac
provenance_parent="$(
  cd "$(dirname "$HEALTH_BRIDGE_QA_PROVENANCE_PATH")" && pwd -P
)" || exit 3
provenance_path="$provenance_parent/$(basename "$HEALTH_BRIDGE_QA_PROVENANCE_PATH")"
case "$provenance_path" in
  "$root_dir"|"$root_dir"/*) exit 3 ;;
esac

python_bin="$root_dir/.venv/bin/python"
if [[ ! -x "$python_bin" ]]; then
  if ! uv sync --frozen --directory "$root_dir" >/dev/null; then
    printf 'HOLD external prerequisite unavailable\n'
    exit 3
  fi
fi

if ! "$python_bin" "$root_dir/scripts/production-identity-seal.py" assert-target \
  --project "$project_file" \
  --scheme-name "$scheme" \
  --target-name "$target_name" >/dev/null; then
  printf 'FAIL qa_target_invalid\n'
  exit 1
fi
printf 'PASS qa_target_validated\n'
if ! "$python_bin" "$root_dir/scripts/production-identity-seal.py" validate \
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
  --app-path "$archive_path" >/dev/null; then
  printf 'FAIL production_seal_invalid\n'
  exit 1
fi
printf 'PASS production_seal_validated\n'

source_commit="$(git -C "$root_dir" rev-parse --verify HEAD)"
if ! "${xcodebuild_command[@]}" \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$archive_path" \
  archive \
  "DEVELOPMENT_TEAM=$HEALTH_BRIDGE_QA_DEVELOPMENT_TEAM" \
  "PRODUCT_BUNDLE_IDENTIFIER=$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" \
  "HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER=$HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" \
  "HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE=$HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" \
  "HEALTH_BRIDGE_QA_OUTBOX_ROOT=$HEALTH_BRIDGE_QA_OUTBOX_ROOT" \
  "HEALTH_BRIDGE_QA_DISPLAY_IDENTITY=$HEALTH_BRIDGE_QA_DISPLAY_IDENTITY" \
  "HEALTH_BRIDGE_SOURCE_COMMIT=$source_commit" \
  "HEALTH_BRIDGE_QA_SCHEME_NAME=$scheme" \
  "HEALTH_BRIDGE_QA_TARGET_NAME=$target_name" \
  "CODE_SIGN_STYLE=$code_sign_style" \
  "PROVISIONING_PROFILE_SPECIFIER=$profile_specifier"; then
  printf 'HOLD external prerequisite unavailable\n'
  exit 3
fi
printf 'PASS signed_archive_created\n'

qa_app="$archive_path/Products/Applications/$target_name.app"
test -d "$qa_app" || exit 3
qa_build_tmp="$(mktemp -d)"
chmod 700 "$qa_build_tmp"
trap 'rm -rf "$qa_build_tmp"' EXIT
codesign --verify --deep --strict "$qa_app"
codesign_authority="$(codesign -dvvv "$qa_app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
test -n "$codesign_authority"
certificate="$qa_build_tmp/certificate.pem"
security find-certificate -p -c "$codesign_authority" "$HOME/Library/Keychains/login.keychain-db" > "$certificate"
test -s "$certificate"
qa_codesign_sha="$(openssl x509 -in "$certificate" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')"
[[ "$qa_codesign_sha" =~ ^[0-9a-f]{64}$ ]]
executable="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$qa_app/Info.plist"
)"
qa_executable_sha="$(
  shasum -a 256 "$qa_app/$executable" | awk '{print $1}'
)"
"$python_bin" "$root_dir/scripts/production-identity-seal.py" write-provenance \
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
  --app-path "$qa_app" \
  --expected-commit "$source_commit" \
  --qa-executable-sha256 "$qa_executable_sha" \
  --qa-codesign-identity-sha256 "$qa_codesign_sha" \
  --provenance "$provenance_path" >/dev/null

#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: stage-mailbox-helper-release.sh --tag receiver-vX.Y.Z --xcconfig PRIVATE_XCCONFIG --notary-keychain-profile PROFILE --output-dir PRIVATE_DIR" >&2
  exit 2
}

require_secure_timestamp() {
  local metadata_path="$1"
  local timestamp
  local normalized_timestamp
  timestamp="$(awk '/^Timestamp=/{value=substr($0,index($0,"=")+1); sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); print value; exit}' "$metadata_path")"
  normalized_timestamp="$(printf '%s' "$timestamp" | tr '[:upper:]' '[:lower:]')"
  test -n "$timestamp" && test "$normalized_timestamp" != "none"
}

require_hardened_runtime() {
  local metadata_path="$1"
  grep -Eqi '^.*flags=.*[(,[:space:]]runtime[),[:space:]]' "$metadata_path"
}

secure_timestamp_codesign() {
  local target="$1"
  local attempt
  for attempt in 1 2 3; do
    if /usr/bin/codesign \
      --force \
      --sign "$expected_authority" \
      --options runtime \
      --timestamp=http://timestamp.apple.com/ts01 \
      --entitlements "$canonical_entitlements" \
      --preserve-metadata=identifier,requirements \
      --generate-entitlement-der \
      "$target" >>"$private_build_root/codesign-resign.log" 2>&1; then
      return 0
    fi
    sleep "$attempt"
  done
  return 1
}

tag=""
xcconfig=""
output_dir=""
notary_profile=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:-}"; shift 2 ;;
    --xcconfig) xcconfig="${2:-}"; shift 2 ;;
    --notary-keychain-profile) notary_profile="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$tag" && -n "$xcconfig" && -n "$notary_profile" && -n "$output_dir" ]] || usage
[[ "$notary_profile" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]{0,127}$ ]] || usage
[[ "$(uname -s)" = "Darwin" ]] || { echo "macOS is required" >&2; exit 1; }

repo="$(git rev-parse --show-toplevel)"
cd "$repo"
xcconfig="$(cd "$(dirname "$xcconfig")" && pwd -P)/$(basename "$xcconfig")"
output_dir="$(mkdir -p "$output_dir" && cd "$output_dir" && pwd -P)"
chmod 700 "$output_dir"
case "$xcconfig" in "$repo"/*) echo "signing xcconfig must stay outside Git" >&2; exit 1 ;; esac
case "$output_dir" in "$repo"/*) echo "release output must stay outside Git" >&2; exit 1 ;; esac
[[ -f "$xcconfig" ]] || { echo "signing xcconfig is unavailable" >&2; exit 1; }
test "$(stat -f '%Su' "$xcconfig")" = "$(id -un)"
xcconfig_mode="$(stat -f '%Lp' "$xcconfig")"
test "$((8#$xcconfig_mode & 8#77))" -eq 0
grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' "$xcconfig"
grep -Eq '^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=[[:space:]]*Developer ID Application:' "$xcconfig"
grep -Eq '^[[:space:]]*PROVISIONING_PROFILE_SPECIFIER[[:space:]]*=' "$xcconfig"
grep -Eq '^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=' "$xcconfig"
grep -Eq '^[[:space:]]*HEALTH_BRIDGE_EXPECTED_BUNDLE_IDENTIFIER[[:space:]]*=' "$xcconfig"
grep -Eq '^[[:space:]]*HEALTH_BRIDGE_ICLOUD_CONTAINER_IDENTIFIER[[:space:]]*=' "$xcconfig"

git verify-tag "$tag" >/dev/null 2>&1
test "$(git rev-parse HEAD)" = "$(git rev-parse "${tag}^{commit}")"
test -z "$(git status --porcelain -- macos/HealthBridgeMailboxAckPublisher)"
version="${tag#receiver-v}"
test "$tag" = "receiver-v${version}"
project_version="$(python3 -c 'import tomllib; print(tomllib.load(open("pyproject.toml", "rb"))["project"]["version"])')"
test "$version" = "$project_version"

private_build_root="$(mktemp -d "${TMPDIR:-/tmp}/health-bridge-helper.XXXXXX")"
chmod 700 "$private_build_root"
cleanup() { rm -rf -- "$private_build_root"; }
trap cleanup EXIT

expected_team="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([^[:space:];]+).*$/\1/p' "$xcconfig" | tail -n 1)"
expected_authority="$(sed -nE 's/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=[[:space:]]*(Developer ID Application:.*[^[:space:]])[[:space:]]*$/\1/p' "$xcconfig" | tail -n 1)"
configured_bundle_id="$(sed -nE 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*([A-Za-z0-9.-]+)[[:space:]]*;?[[:space:]]*$/\1/p' "$xcconfig" | tail -n 1)"
configured_expected_bundle_id="$(sed -nE 's/^[[:space:]]*HEALTH_BRIDGE_EXPECTED_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*([A-Za-z0-9.-]+)[[:space:]]*;?[[:space:]]*$/\1/p' "$xcconfig" | tail -n 1)"
configured_container_id="$(sed -nE 's/^[[:space:]]*HEALTH_BRIDGE_ICLOUD_CONTAINER_IDENTIFIER[[:space:]]*=[[:space:]]*([A-Za-z0-9.-]+)[[:space:]]*;?[[:space:]]*$/\1/p' "$xcconfig" | tail -n 1)"
[[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]]
[[ "$expected_authority" == "Developer ID Application:"*"(${expected_team})" ]]
test -n "$configured_bundle_id"
test "$configured_bundle_id" = "$configured_expected_bundle_id"
[[ "$configured_container_id" == iCloud.* ]]
application_id="${expected_team}.${configured_bundle_id}"
uv run python scripts/check_helper_distribution_policy.py \
  --signing-authority "$expected_authority" \
  --team-identifier "$expected_team" \
  --bundle-identifier "$configured_bundle_id" \
  --icloud-container-identifier "$configured_container_id"

if ! xcodebuild \
  -project macos/HealthBridgeMailboxAckPublisher/HealthBridgeMailboxAckPublisher.xcodeproj \
  -target HealthBridgeMailboxAckPublisher \
  -configuration Release \
  -xcconfig "$xcconfig" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CONFIGURATION_BUILD_DIR="$private_build_root/build" \
  clean build >"$private_build_root/xcodebuild.log" 2>&1; then
  echo "signed helper build failed; private build log was not published" >&2
  exit 1
fi

app="$private_build_root/build/HealthBridgeMailboxAckPublisher.app"
test -d "$app"
helper_executable="$app/Contents/MacOS/HealthBridgeMailboxAckPublisher"
test -f "$helper_executable"
canonical_entitlements="$private_build_root/canonical-entitlements.plist"
/bin/cp \
  macos/HealthBridgeMailboxAckPublisher/HealthBridgeMailboxAckPublisher.entitlements \
  "$canonical_entitlements"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.developer.icloud-container-identifiers:0 ${configured_container_id}" \
  "$canonical_entitlements"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.developer.ubiquity-container-identifiers:0 ${configured_container_id}" \
  "$canonical_entitlements"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.application-identifier string ${application_id}" \
  "$canonical_entitlements"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.developer.team-identifier string ${expected_team}" \
  "$canonical_entitlements"
if /usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.get-task-allow' \
  "$canonical_entitlements" >/dev/null 2>&1; then
  echo "canonical helper entitlements contain get-task-allow" >&2
  exit 1
fi
helper_architectures="$(/usr/bin/lipo -archs "$helper_executable")"
if [[ "$helper_architectures" != "arm64 x86_64" && "$helper_architectures" != "x86_64 arm64" ]]; then
  echo "helper executable is not universal2" >&2
  exit 1
fi
secure_timestamp_codesign "$app"
codesign --verify --strict --deep "$app" >/dev/null 2>&1
codesign -d --entitlements :- "$app" >"$private_build_root/entitlements.plist" 2>/dev/null
codesign -d --verbose=4 "$app" >"$private_build_root/codesign.txt" 2>&1
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$private_build_root/entitlements.plist" >/dev/null 2>&1; then
  echo "signed helper requests get-task-allow" >&2
  exit 1
fi
python3 -c 'import plistlib, sys; expected = plistlib.load(open(sys.argv[1], "rb")); actual = plistlib.load(open(sys.argv[2], "rb")); raise SystemExit(0 if actual == expected else 1)' \
  "$canonical_entitlements" \
  "$private_build_root/entitlements.plist"
grep -Fqx "Authority=${expected_authority}" "$private_build_root/codesign.txt"
grep -Fqx "TeamIdentifier=${expected_team}" "$private_build_root/codesign.txt"
require_secure_timestamp "$private_build_root/codesign.txt"
require_hardened_runtime "$private_build_root/codesign.txt"

info="$app/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
expected_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :HealthBridgeExpectedBundleIdentifier' "$info")"
container_id="$(/usr/libexec/PlistBuddy -c 'Print :HealthBridgeICloudContainerIdentifier' "$info")"
test "$bundle_id" = "$expected_bundle_id"
test "$bundle_id" = "$configured_bundle_id"
test "$container_id" = "$configured_container_id"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" = "1"
test "$application_id" = "${expected_team}.${bundle_id}"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$private_build_root/entitlements.plist")" = "$application_id"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$private_build_root/entitlements.plist")" = "$expected_team"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$private_build_root/entitlements.plist")" = "Production"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$private_build_root/entitlements.plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$private_build_root/entitlements.plist")" = "$container_id"
! /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:1' "$private_build_root/entitlements.plist" >/dev/null 2>&1
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.ubiquity-container-identifiers:0' "$private_build_root/entitlements.plist")" = "$container_id"
! /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.ubiquity-container-identifiers:1' "$private_build_root/entitlements.plist" >/dev/null 2>&1
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services:0' "$private_build_root/entitlements.plist")" = "CloudDocuments"
! /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services:1' "$private_build_root/entitlements.plist" >/dev/null 2>&1

profile="$app/Contents/embedded.provisionprofile"
test -f "$profile"
if ! /usr/bin/security cms -D -i "$profile" >"$private_build_root/profile.plist" 2>"$private_build_root/profile.log"; then
  echo "helper distribution profile is invalid" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$private_build_root/profile.plist" >/dev/null 2>&1; then
  echo "device-limited helper profiles are not distributable" >&2
  exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$private_build_root/profile.plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$private_build_root/profile.plist")" = "$expected_team"
! /usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:1' "$private_build_root/profile.plist" >/dev/null 2>&1
test "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$private_build_root/profile.plist")" = "$application_id"
test "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$private_build_root/profile.plist")" = "$expected_team"
test "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "$private_build_root/profile.plist")" = "Production"
test "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers:0' "$private_build_root/profile.plist")" = "$container_id"
! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers:1' "$private_build_root/profile.plist" >/dev/null 2>&1
test "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.ubiquity-container-identifiers:0' "$private_build_root/profile.plist")" = "$container_id"
! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.ubiquity-container-identifiers:1' "$private_build_root/profile.plist" >/dev/null 2>&1
profile_icloud_services="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-services' "$private_build_root/profile.plist")"
if [[ "$profile_icloud_services" != "*" && "$profile_icloud_services" != "CloudDocuments" ]]; then
  echo "helper distribution profile does not authorize CloudDocuments" >&2
  exit 1
fi
! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-services:1' "$private_build_root/profile.plist" >/dev/null 2>&1

submission_archive="$private_build_root/notary-upload.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$submission_archive"
if ! xcrun notarytool submit "$submission_archive" \
  --keychain-profile "$notary_profile" \
  --wait \
  --output-format json \
  >"$private_build_root/notary-result.json" \
  2>"$private_build_root/notary.log"; then
  echo "helper notarization failed; private notary log was not published" >&2
  exit 1
fi
notary_status="$(/usr/bin/plutil -extract status raw -o - "$private_build_root/notary-result.json")"
notary_id="$(/usr/bin/plutil -extract id raw -o - "$private_build_root/notary-result.json")"
test "$notary_status" = "Accepted"
[[ "$notary_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
notary_id="$(printf '%s' "$notary_id" | tr '[:upper:]' '[:lower:]')"
if ! xcrun stapler staple "$app" >"$private_build_root/staple.log" 2>&1; then
  echo "helper notarization ticket could not be stapled" >&2
  exit 1
fi
if ! xcrun stapler validate "$app" >"$private_build_root/staple-validate.log" 2>&1; then
  echo "helper notarization ticket is invalid" >&2
  exit 1
fi
if ! /usr/sbin/spctl --assess --type execute --verbose=4 "$app" >"$private_build_root/gatekeeper.log" 2>&1; then
  echo "Gatekeeper rejected the helper" >&2
  exit 1
fi
codesign --verify --strict --deep "$app" >/dev/null 2>&1
codesign -d --verbose=4 "$app" >"$private_build_root/codesign-after-staple.txt" 2>&1
grep -Fqx "Authority=${expected_authority}" "$private_build_root/codesign-after-staple.txt"
grep -Fqx "TeamIdentifier=${expected_team}" "$private_build_root/codesign-after-staple.txt"
require_secure_timestamp "$private_build_root/codesign-after-staple.txt"
require_hardened_runtime "$private_build_root/codesign-after-staple.txt"

archive="$output_dir/HealthBridgeMailboxAckPublisher-${version}.zip"
manifest="$output_dir/HealthBridgeMailboxAckPublisher-${version}.manifest.json"
test ! -e "$archive"
test ! -e "$manifest"
/usr/bin/ditto -c -k --keepParent "$app" "$archive"
chmod 600 "$archive"

tag_object="$(git rev-parse "${tag}^{tag}")"
commit="$(git rev-parse "${tag}^{commit}")"
tree="$(git rev-parse "${commit}^{tree}")"
source_tree="$(git rev-parse "${commit}:macos/HealthBridgeMailboxAckPublisher")"
uv run python scripts/stage_helper_manifest.py \
  --archive "$archive" \
  --output "$manifest" \
  --tag "$tag" \
  --tag-object "$tag_object" \
  --commit "$commit" \
  --tree "$tree" \
  --source-tree "$source_tree" \
  --bundle-identifier "$bundle_id" \
  --icloud-container-identifier "$container_id" \
  --version "$version" \
  --build "1" \
  --signing-authority "$expected_authority" \
  --team-identifier "$expected_team" \
  --notary-submission-id "$notary_id"
chmod 600 "$manifest"
uv run python scripts/verify_helper_distribution.py \
  --archive "$archive" \
  --manifest "$manifest" \
  --app "$app" \
  >"$private_build_root/distribution-verification.log" 2>&1

echo "staged: $(basename "$archive")"
echo "manifest: $(basename "$manifest")"
echo "archive sha256: $(shasum -a 256 "$archive" | awk '{print $1}')"
echo "manifest sha256: $(shasum -a 256 "$manifest" | awk '{print $1}')"

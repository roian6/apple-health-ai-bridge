#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 --tag receiver-vX.Y.Z --xcconfig /private/path/signing.xcconfig --output-dir /private/path" >&2
  exit 2
}

tag=""
xcconfig=""
output_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:-}"; shift 2 ;;
    --xcconfig) xcconfig="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$tag" && -n "$xcconfig" && -n "$output_dir" ]] || usage
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
cleanup() { rm -rf "$private_build_root"; }
trap cleanup EXIT

if ! xcodebuild \
  -project macos/HealthBridgeMailboxAckPublisher/HealthBridgeMailboxAckPublisher.xcodeproj \
  -target HealthBridgeMailboxAckPublisher \
  -configuration Release \
  -xcconfig "$xcconfig" \
  CONFIGURATION_BUILD_DIR="$private_build_root/build" \
  clean build >"$private_build_root/xcodebuild.log" 2>&1; then
  echo "signed helper build failed; private build log was not published" >&2
  exit 1
fi

app="$private_build_root/build/HealthBridgeMailboxAckPublisher.app"
test -d "$app"
codesign --verify --strict --deep "$app" >/dev/null 2>&1
codesign -d --entitlements :- "$app" >"$private_build_root/entitlements.plist" 2>/dev/null
codesign -d --verbose=4 "$app" >"$private_build_root/codesign.txt" 2>&1
grep -qi 'runtime' "$private_build_root/codesign.txt"

info="$app/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
expected_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :HealthBridgeExpectedBundleIdentifier' "$info")"
container_id="$(/usr/libexec/PlistBuddy -c 'Print :HealthBridgeICloudContainerIdentifier' "$info")"
test "$bundle_id" = "$expected_bundle_id"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" = "1"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$private_build_root/entitlements.plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$private_build_root/entitlements.plist")" = "$container_id"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.ubiquity-container-identifiers:0' "$private_build_root/entitlements.plist")" = "$container_id"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services:0' "$private_build_root/entitlements.plist")" = "CloudDocuments"

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
  --build "1"
chmod 600 "$manifest"

echo "staged: $(basename "$archive")"
echo "manifest: $(basename "$manifest")"
echo "sha256: $(shasum -a 256 "$archive" | awk '{print $1}')"

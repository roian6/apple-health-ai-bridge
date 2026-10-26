#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0

if [[ $# -ne 0 ]]; then
  printf 'Usage: bash scripts/swift-analysis.sh\n' >&2
  exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
version=0.65.1
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64|Darwin/x86_64)
    asset=portable_swiftlint.zip
    digest=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
    ;;
  Linux/aarch64)
    asset=swiftlint_linux_arm64.zip
    digest=9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8
    ;;
  *) printf 'Unsupported SwiftLint host; use the macOS CI gate.\n' >&2; exit 1 ;;
esac

temporary_root=${RUNNER_TEMP:-$(git rev-parse --git-path swift-analysis)}
mkdir -p -m 700 "$temporary_root"
scratch=$(mktemp -d "$temporary_root/health-bridge-swiftlint.XXXXXXXX")
scratch=$(cd "$scratch" && pwd)
trap 'rm -rf "$scratch"' EXIT
curl --fail --location --retry 2 --max-time 120 \
  "https://github.com/realm/SwiftLint/releases/download/$version/$asset" \
  --output "$scratch/$asset"
actual=$(shasum -a 256 "$scratch/$asset")
[[ "${actual%% *}" == "$digest" ]] || { printf 'SwiftLint checksum mismatch.\n' >&2; exit 1; }
printf 'SwiftLint archive: %s SHA256: %s\n' "$asset" "$digest"
unzip -q "$scratch/$asset" -d "$scratch/tool"
lint="$scratch/tool/swiftlint"
[[ "$($lint version)" == "$version" ]]
printf 'SwiftLint version: %s\n' "$version"

scopes=(
  ios/HealthBridgeCompanion/App
  ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore
  macos/HealthBridgeMailboxAckPublisher
)
files=()
for scope in "${scopes[@]}"; do
  count=0
  find "$scope" -type f -name '*.swift' > "$scratch/scope-files"
  LC_ALL=C sort "$scratch/scope-files" > "$scratch/sorted-files"
  while IFS= read -r file; do
    files+=("$file")
    count=$((count + 1))
    printf 'Analyzing: %s\n' "$file"
  done < "$scratch/sorted-files"
  [[ $count -gt 0 ]] || { printf 'No Swift files in %s\n' "$scope" >&2; exit 1; }
  printf 'Scope: %s Files: %s\n' "$scope" "$count"
done
printf 'Total production Swift files: %s\n' "${#files[@]}"

printf 'let control = 1\n' | "$lint" lint --config "$root/.github/linters/swiftlint.yml" \
  --strict --no-cache --use-stdin
printf 'Positive control: accepted\n'
set +e
printf 'let control = (1 as Any) as! String\n' | "$lint" lint \
  --config "$root/.github/linters/swiftlint.yml" --strict --no-cache --use-stdin \
  > "$scratch/negative.log" 2>&1
negative_status=$?
set -e
cat "$scratch/negative.log"
[[ $negative_status -eq 2 ]] && grep -q 'force_cast' "$scratch/negative.log" || {
  printf 'Negative control did not report the expected force_cast violation.\n' >&2
  exit 1
}
printf 'Negative control: rejected with force_cast (exit %s)\n' "$negative_status"
"$lint" lint --config "$root/.github/linters/swiftlint.yml" --strict --no-cache "${files[@]}"

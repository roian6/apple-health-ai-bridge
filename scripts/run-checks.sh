#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

usage() {
  printf '%s\n' \
    'Usage: run-checks.sh local [BASE_REF]' \
    '       run-checks.sh full' \
    '       run-checks.sh python|native|native-builds|tests maintenance|python|native|full' >&2
  exit 2
}

case "${1:-}" in
  local)
    [[ "$#" -le 2 ]] || usage
    mode="$(bash scripts/ci-scope.sh local "${2:-origin/main}")"
    ;;
  full)
    [[ "$#" -eq 1 ]] || usage
    mode=full
    ;;
  python|native|native-builds|tests)
    [[ "$#" -eq 2 ]] || usage
    mode="$2"
    ;;
  *) usage ;;
esac
case "$mode" in maintenance|python|native|full) ;; *) usage ;; esac

output="${CHECKS_OUTPUT_DIR:-$root/.tmp/checks}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
export COVERAGE_FILE="${COVERAGE_FILE:-$output/.coverage}"
printf 'Selected check profile: %s\n' "$mode"

run_tests() {
  test_args=(tests)
  case "$mode" in
    python|maintenance|native)
      test_args=()
      git ls-files -z -- tests > "$output/test-files"
      while IFS= read -r -d '' path; do
        case "$path" in
          tests/guardrails/test_release_*.py) continue ;;
        esac
        if [[ "$mode" != python && "$path" != tests/guardrails/* ]]; then
          continue
        fi
        case "${path##*/}" in test_*.py|*_test.py) test_args+=("$path") ;; esac
      done < "$output/test-files"
      [[ "${#test_args[@]}" -gt 0 ]] || { printf 'No selected tests found\n' >&2; exit 1; }
      if [[ "$mode" != python ]]; then
        test_args+=(tests/mcp/test_reference_examples.py)
      fi
      if [[ "$mode" == native ]]; then
        test_args+=(tests/contract tests/scripts/test_production_identity_seal.py)
      fi
      ;;
  esac
  if [[ "$mode" != full ]]; then
    for name in \
      test_public_docs_name_each_version_surface_and_transition \
      test_release_and_self_build_docs_reference_current_guidance \
      test_brand_readme_local_links_resolve_inside_repository \
      test_install_commands_are_pinned_to_their_receiver_release \
      test_roadmap_links_to_readme_default_receiver_release \
      test_versioned_setup_links_to_matching_mailbox_release_assets; do
      test_args+=("tests/guardrails/test_release_management.py::$name")
    done
  fi
  if [[ "$mode" == full || "$mode" == python ]]; then
    uv run pytest -q "${test_args[@]}" \
      --cov --cov-config=pyproject.toml --cov-report=term \
      "--cov-report=xml:$output/coverage.xml" \
      "--cov-report=json:$output/coverage.json" \
      --durations=30 --durations-min=1.0 "--junitxml=$output/pytest-$mode.xml"
  else
    uv run pytest -q "${test_args[@]}" \
      --durations=30 --durations-min=1.0 "--junitxml=$output/pytest-$mode.xml"
  fi
}

run_python() {
  uv run python scripts/public-release-audit.py --strict
  uv run ruff format --check .
  uv run ruff check .
  uv run basedpyright
  uv run bandit -r src -q
  uv run pip-audit --local --skip-editable
  uv run check-jsonschema --builtin-schema vendor.github-workflows .github/workflows/*.yml
  run_tests
  rm -rf -- "$output/dist"
  uv build --build-constraints .github/release/build-constraints.txt \
    --require-hashes --out-dir "$output/dist"
  uv run python scripts/package-smoke.py --dist-dir "$output/dist"
  git diff --check
  git diff --cached --check
}

helper_command() {
  local log="$1" status
  shift
  { printf 'argv:'; printf ' %q' "$@"; printf '\n'; } >> "$output/helper/commands.log"
  if "$@" 2>&1 | tee "$output/helper/$log"; then
    status=0
  else
    status=$?
  fi
  printf 'exit: %s\n' "$status" >> "$output/helper/commands.log"
  return "$status"
}

run_helper() {
  helper="$output/helper"
  # This lane is runner-owned. Never accept a stale executable or build product.
  rm -rf -- "$helper"
  mkdir -p "$helper"
  helper_sources=(
    macos/HealthBridgeMailboxAckPublisher/main.swift
    macos/HealthBridgeMailboxAckPublisher/Tests/NativePairingLocalFakeTests.swift
    macos/HealthBridgeMailboxAckPublisher/Info.plist
    macos/HealthBridgeMailboxAckPublisher/HealthBridgeMailboxAckPublisher.entitlements
    macos/HealthBridgeMailboxAckPublisher/HealthBridgeMailboxAckPublisher.xcodeproj/project.pbxproj
    scripts/run-checks.sh
  )
  shasum -a 256 "${helper_sources[@]}" > "$helper/sources-before.sha256"
  helper_command compiler-version.log xcrun swiftc --version
  helper_command xcode-version.log xcodebuild -version
  helper_command sdk-version.log xcrun --sdk macosx --show-sdk-version
  helper_command compile.log xcrun swiftc -D HEALTH_BRIDGE_ISOLATED_HELPER_TEST_HOST \
    -module-cache-path "$helper/swift" \
    macos/HealthBridgeMailboxAckPublisher/main.swift \
    macos/HealthBridgeMailboxAckPublisher/Tests/NativePairingLocalFakeTests.swift \
    -o "$helper/native-tests"
  [[ -f "$helper/native-tests" && -x "$helper/native-tests" ]] || {
    printf 'Missing executable native test host\n' >&2; exit 1;
  }
  xcrun lipo -archs "$helper/native-tests" > "$helper/architectures.log"
  shasum -a 256 "$helper/native-tests" > "$helper/native-tests-before.sha256"
  # Capture identity even when the host exits nonzero.
  local test_status=0
  helper_command test.log "$helper/native-tests" || test_status=$?
  shasum -a 256 "$helper/native-tests" > "$helper/native-tests-after.sha256"
  [[ "$test_status" -eq 0 ]] || return "$test_status"
  cmp "$helper/native-tests-before.sha256" "$helper/native-tests-after.sha256"
  awk '
    /^CASES=[0-9]+ PASSED=[0-9]+ FAILED=[0-9]+ SKIPPED=[0-9]+$/ {
      summaries++
      split($1, cases, "="); split($2, passed, "=")
      split($3, failed, "="); split($4, skipped, "=")
      valid = cases[2] > 0 && passed[2] == cases[2] && failed[2] == 0 && skipped[2] == 0
    }
    END { exit !(summaries == 1 && valid) }
  ' "$helper/test.log"
  helper_command build.log xcodebuild \
    -project macos/HealthBridgeMailboxAckPublisher/HealthBridgeMailboxAckPublisher.xcodeproj \
    -target HealthBridgeMailboxAckPublisher -sdk macosx -configuration Release \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES \
    "CONFIGURATION_BUILD_DIR=$helper/build" \
    "OBJROOT=$helper/objects" "SYMROOT=$helper/products" \
    "SHARED_PRECOMPS_DIR=$helper/precompiled" \
    "CLANG_MODULE_CACHE_PATH=$helper/clang" "SWIFT_MODULE_CACHE_PATH=$helper/swift" build
  local app="$helper/build/HealthBridgeMailboxAckPublisher.app/Contents/MacOS/HealthBridgeMailboxAckPublisher"
  [[ -f "$app" && -x "$app" ]] || {
    printf 'Missing unsigned helper executable\n' >&2; exit 1;
  }
  shasum -a 256 "$app" > "$helper/app.sha256"
  xcrun lipo -archs "$app" >> "$helper/architectures.log"
  printf '%s\n' \
    'isolated production logic: executed; see test.log' \
    'unsigned production target: compiled only; see build.log' \
    'signed-distribution qualification: NOT RUN' > "$helper/qualification.txt"
}

run_native() {
  case "$mode" in maintenance|python) return 0 ;; esac
  if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Selected native checks require macOS with Xcode\n' >&2
    exit 1
  fi
  if [[ "${1:-all}" == all ]]; then
    bash scripts/swift-analysis.sh
  fi
  run_helper
  (
    cd ios/HealthBridgeCompanion
    build_paths=(
      "SYMROOT=$output/xcode"
      "OBJROOT=$output/xcode-objects"
      "CLANG_MODULE_CACHE_PATH=$output/module-cache"
    )
    swift test --scratch-path "$output/swift" --cache-path "$output/swift-cache"
    xcodebuild -project HealthBridgeCompanion.xcodeproj \
      -target HealthBridgeCompanion -sdk iphonesimulator -configuration Debug \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "${build_paths[@]}" build
    xcodebuild -project HealthBridgeCompanion.xcodeproj \
      -target HealthBridgeCompanion -sdk iphoneos -configuration Debug \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "${build_paths[@]}" build
    xcodebuild -project HealthBridgeCompanion.xcodeproj \
      -target HealthBridgeCompanionPublicDocumentsQA -sdk iphonesimulator -configuration Debug \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "${build_paths[@]}" build
    xcodebuild -project HealthBridgeCompanion.xcodeproj \
      -target HealthBridgeCompanionPublicDocumentsQA -sdk iphoneos -configuration Debug \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "${build_paths[@]}" build
  )
  shasum -a 256 "${helper_sources[@]}" > "$helper/sources-after.sha256"
  cmp "$helper/sources-before.sha256" "$helper/sources-after.sha256"
}

case "$1" in
  local|full)
    uv sync --all-extras --dev --locked
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/health-bridge-checks.XXXXXX")"
    scratch="$(cd "$scratch" && pwd -P)"
    trap 'rm -rf "$scratch"' EXIT
    case "$scratch/" in
      "$root/"*) printf 'Temporary directory must be outside checkout\n' >&2; exit 1 ;;
    esac
    mkdir -p "$scratch/home" "$scratch/tmp" "$scratch/cache"
    export TMPDIR="$scratch/tmp" XDG_CACHE_HOME="$scratch/cache"
    (
      export HOME="$scratch/home"
      run_python
    )
    run_native
    printf 'Selected local checks passed; hosted CodeQL and native fuzzing remain CI checks.\n'
    ;;
  python) run_python ;;
  native) run_native ;;
  native-builds) run_native builds ;;
  tests) run_tests ;;
esac

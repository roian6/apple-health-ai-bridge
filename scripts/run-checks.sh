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

run_native() {
  case "$mode" in maintenance|python) return 0 ;; esac
  if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Selected native checks require macOS with Xcode\n' >&2
    exit 1
  fi
  if [[ "${1:-all}" == all ]]; then
    bash scripts/swift-analysis.sh
  fi
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

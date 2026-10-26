#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: ci-scope.sh classify EVENT BASE_SHA HEAD_SHA' \
    '       ci-scope.sh local BASE_REF' \
    '       ci-scope.sh check python|native SCOPE_RESULT MODE WORKER_RESULT' >&2
  exit 2
}

classify_changes() {
  count=0
  python_changed=0
  native_changed=0
  while IFS= read -r -d '' entry; do
    if ! IFS= read -r -d '' path; then
      printf 'Incomplete Git change record\n' >&2
      exit 1
    fi
    if [[ ! "$entry" =~ ^:100644\ 100644\ [0-9a-f]{40}\ [0-9a-f]{40}\ M$ ]]; then
      printf 'full\n'
      return
    fi
    case "$path" in
      README.md|.github/CONTRIBUTING.md|.github/SECURITY.md|.github/SUPPORT.md|\
      .github/pull_request_template.md|.github/ISSUE_TEMPLATE/bug_report.yml|\
      .github/ISSUE_TEMPLATE/feature_request.yml|.github/ISSUE_TEMPLATE/setup_feedback.yml|\
      .github/ISSUE_TEMPLATE/config.yml|.github/labeler.yml|.coderabbit.yaml|\
      .github/workflows/labels.yml|assets/brand/*.svg|assets/brand/*.png|\
      assets/brand/*.html|assets/brand/README.md|assets/clients/*.svg|\
      assets/clients/*.md|assets/clients/LICENSE*|\
      docs/brand.md|docs/setup.md|docs/pairing.md|docs/self-build.md|\
      docs/agent-assisted-setup.md|docs/architecture.md|docs/supported-health-data.md|\
      docs/roadmap.md|docs/contribution-ideas.md|docs/maintainer-guide.md|\
      docs/examples/*.md|docs/clients/*.md|docs/reference/cli.md|docs/reference/mcp.md|\
      tests/guardrails/test_public_language.py|tests/guardrails/test_governance_surfaces.py|\
      tests/guardrails/test_issue_forms.py|tests/guardrails/test_brand_assets.py|\
      tests/guardrails/test_repository_automation.py)
        ;;
      src/health_bridge/mcp/types.py|\
      ios/*Delivery*|ios/*Transport*|ios/*Pairing*|ios/*Mailbox*|ios/*Outbox*|\
      ios/*Identity*|ios/*Locator*|ios/*Capabilities*|ios/*Envelope*|ios/*Batch*|\
      ios/*.xcodeproj/*|ios/*Info.plist|ios/*PrivacyInfo.xcprivacy|\
      ios/*.entitlements|ios/*Package.swift|ios/*Package.resolved|\
      tests/guardrails/test_ios_checkpoint_workflows.py|\
      tests/guardrails/test_ios_release_scope_validation.py)
        printf 'full\n'
        return
        ;;
      src/health_bridge/queries/*|src/health_bridge/mcp/*|\
      src/health_bridge/cli_query.py|src/health_bridge/cli_mcp.py|\
      src/health_bridge/ingest.py|src/health_bridge/timeseries_catalog.py|\
      src/health_bridge/timeseries_alias_compat.py|\
      tests/queries/*|tests/mcp/*|tests/ingest/*|\
      tests/cli/test_query_cli.py|tests/cli/test_committed_query_cli.py|\
      tests/test_timeseries_catalog.py|tests/test_timeseries_alias_compat.py)
        python_changed=1
        ;;
      ios/*|scripts/generate_brand_assets.py|scripts/swift-analysis.sh|\
      .github/linters/swiftlint.yml|tests/guardrails/test_ios_*.py|\
      tests/guardrails/test_swift_analysis.py)
        native_changed=1
        ;;
      *)
        printf 'full\n'
        return
        ;;
    esac
    count=$((count + 1))
  done < "$changes"
  if [[ -n "$entry" ]]; then
    printf 'Incomplete Git change record\n' >&2
    exit 1
  fi
  if [[ "$count" -eq 0 || "$python_changed:$native_changed" == 1:1 ]]; then
    printf 'full\n'
  elif [[ "$python_changed" -eq 1 ]]; then
    printf 'python\n'
  elif [[ "$native_changed" -eq 1 ]]; then
    printf 'native\n'
  else
    printf 'maintenance\n'
  fi
}

case "${1:-}" in
  classify)
    [[ "$#" -eq 4 ]] || usage
    if [[ "$2" != pull_request ]]; then
      printf 'full\n'
      exit 0
    fi
    [[ "$3" =~ ^[0-9a-f]{40}$ && "$4" =~ ^[0-9a-f]{40}$ ]] || usage
    changes="$(mktemp "${TMPDIR:-/tmp}/health-bridge-ci-scope.XXXXXX")"
    trap 'rm -f "$changes"' EXIT
    git diff --raw -z --no-abbrev --no-renames --no-ext-diff --no-textconv \
      "$3...$4" -- > "$changes"
    classify_changes
    ;;
  local)
    [[ "$#" -eq 2 ]] || usage
    base="$(git rev-parse --verify --end-of-options "$2^{commit}")"
    base="$(git merge-base "$base" HEAD)"
    changes="$(mktemp "${TMPDIR:-/tmp}/health-bridge-ci-scope.XXXXXX")"
    trap 'rm -f "$changes" "$changes.untracked"' EXIT
    git ls-files --others --exclude-standard -z > "$changes.untracked"
    if [[ -s "$changes.untracked" ]]; then
      printf 'full\n'
      exit 0
    fi
    git diff --raw -z --no-abbrev --no-renames --no-ext-diff --no-textconv \
      "$base" -- > "$changes"
    classify_changes
    ;;
  check)
    [[ "$#" -eq 5 ]] || usage
    case "$2:$4" in
      python:full|python:maintenance|python:python|python:native|\
      native:full|native:native) expected=success ;;
      native:maintenance|native:python) expected=skipped ;;
      *) usage ;;
    esac
    printf '%s gate: classification=%s mode=%s worker=%s\n' "$2" "$3" "$4" "$5"
    [[ "$3" == success && "$5" == "$expected" ]]
    ;;
  *) usage ;;
esac

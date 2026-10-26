#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: ci-scope.sh classify EVENT BASE_SHA HEAD_SHA' \
    '       ci-scope.sh check python|native SCOPE_RESULT MODE WORKER_RESULT' >&2
  exit 2
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

    count=0
    while IFS= read -r -d '' entry; do
      if ! IFS= read -r -d '' path; then
        printf 'Incomplete Git change record\n' >&2
        exit 1
      fi
      if [[ ! "$entry" =~ ^:100644\ 100644\ [0-9a-f]{40}\ [0-9a-f]{40}\ M$ ]]; then
        printf 'full\n'
        exit 0
      fi
      case "$path" in
        .github/ISSUE_TEMPLATE/bug_report.yml|\
        .github/ISSUE_TEMPLATE/feature_request.yml|\
        .github/ISSUE_TEMPLATE/setup_feedback.yml|\
        .github/ISSUE_TEMPLATE/config.yml|\
        .github/pull_request_template.md)
          count=$((count + 1))
          ;;
        *)
          printf 'full\n'
          exit 0
          ;;
      esac
    done < "$changes"
    if [[ -n "$entry" ]]; then
      printf 'Incomplete Git change record\n' >&2
      exit 1
    fi
    if [[ "$count" -gt 0 ]]; then
      printf 'metadata\n'
    else
      printf 'full\n'
    fi
    ;;
  check)
    [[ "$#" -eq 5 ]] || usage
    case "$2:$4" in
      python:full|python:metadata|native:full) expected=success ;;
      native:metadata) expected=skipped ;;
      *) usage ;;
    esac
    printf '%s gate: classification=%s mode=%s worker=%s\n' "$2" "$3" "$4" "$5"
    [[ "$3" == success && "$5" == "$expected" ]]
    ;;
  *) usage ;;
esac

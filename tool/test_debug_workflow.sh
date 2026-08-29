#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
workflow="$ROOT_DIR/.github/workflows/debug.yml"
readonly workflow

require_line() {
  local expected="$1"
  local description="$2"
  if ! grep -F -- "$expected" "$workflow" >/dev/null; then
    printf 'Debug workflow is missing %s\n' "$description" >&2
    exit 1
  fi
}

require_line '  push:' 'push trigger'
require_line "      - 'app/**'" 'application path filter'
require_line '  pull_request:' 'pull request trigger'
require_line '  workflow_dispatch:' 'manual trigger'
require_line '      api_base_url:' 'manual API URL input'
require_line "format('debug-apk-pr-{0}', github.event.pull_request.number)" 'per-PR concurrency'
require_line "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" 'stale PR cancellation'
require_line "github.event.pull_request.head.repo.full_name == github.repository" 'fork secret guard'
require_line 'uses: actions/upload-artifact@v7' 'PR artifact upload'
require_line 'retention-days: 14' 'PR artifact retention'
require_line '<!-- gamebox-pr-debug-apk -->' 'stable PR comment marker'
require_line "if: github.event_name != 'pull_request'" 'PR release publication guard'
require_line 'Keep the tag as the stable release identity' 'stable rolling release behavior'
if grep -F '      - main' "$workflow" >/dev/null; then
  printf 'Debug workflow still restricts push triggers to main\n' >&2
  exit 1
fi
if grep -F "if: github.ref == 'refs/heads/main'" "$workflow" >/dev/null; then
  printf 'Debug workflow still restricts the publish job to main\n' >&2
  exit 1
fi
if grep -F 'update_debug_tag' "$workflow" >/dev/null; then
  printf 'Debug workflow still requires moving the rolling tag per branch\n' >&2
  exit 1
fi

printf 'PASS debug workflow publishes PR artifacts and retains push/manual release builds\n'

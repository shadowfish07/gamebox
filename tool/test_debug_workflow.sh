#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
workflow="$ROOT_DIR/.github/workflows/debug.yml"
readonly workflow

grep -F '  push:' "$workflow" >/dev/null
grep -F "      - 'app/**'" "$workflow" >/dev/null
grep -F '  workflow_dispatch:' "$workflow" >/dev/null
grep -F '  group: debug-apk-publish' "$workflow" >/dev/null
grep -F '  cancel-in-progress: false' "$workflow" >/dev/null
if grep -F '      - main' "$workflow" >/dev/null; then
  printf 'Debug workflow still restricts push triggers to main\n' >&2
  exit 1
fi
if grep -F "if: github.ref == 'refs/heads/main'" "$workflow" >/dev/null; then
  printf 'Debug workflow still restricts the publish job to main\n' >&2
  exit 1
fi

printf 'PASS debug workflow accepts all branches and serializes rolling publish\n'

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
release_script="$ROOT_DIR/tool/release.sh"
source "$ROOT_DIR/tool/lib/check_output.sh"
gamebox_test_output_init
trap gamebox_test_output_cleanup EXIT

bash -n "$release_script"
help_output="$(bash "$release_script" 2>&1 || true)"
grep -F 'Usage: bash tool/release.sh major|minor|patch [--dry-run]' <<<"$help_output" >/dev/null
invalid_output="$(bash "$release_script" invalid 2>&1 || true)"
grep -F 'bump must be major, minor, or patch' <<<"$invalid_output" >/dev/null
gamebox_run_step "release wait and deployment fixtures" \
  env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT_DIR/tool/test_release_finish.py"
gamebox_test_output_finish release

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
cd "$ROOT_DIR"
# shellcheck source=tool/lib/check_output.sh
source "$ROOT_DIR/tool/lib/check_output.sh"

# Android unit tests, the APK builds, and APK packaging assertions left this
# gate: they run in the tag-triggered release workflow (and the debug build
# workflow) through tool/verify_android_apk.sh. The packaging predicates stay
# covered on every push by that script's offline fixture suites below.

# setup-godot exposes the executable on PATH in CI, while the local bootstrap
# retains its macOS application-bundle default.
if [[ -z "${GODOT_BIN:-}" ]] && command -v godot >/dev/null 2>&1; then
  export GODOT_BIN
  GODOT_BIN="$(command -v godot)"
fi

if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  export JAVA_HOME
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi

if [[ "${1:-}" == "--self-test" ]]; then
  [[ $# -eq 1 ]] || {
    printf 'usage: %s [--self-test]\n' "$0" >&2
    exit 2
  }
  gamebox_test_output_init
  trap gamebox_test_output_cleanup EXIT
  env GAMEBOX_TEST_NESTED=1 bash tool/verify_android_apk.sh --self-test
  gamebox_test_output_finish verify-self-test
  exit 0
fi
[[ $# -eq 0 ]] || {
  printf 'usage: %s [--self-test]\n' "$0" >&2
  exit 2
}
gamebox_test_output_init
trap gamebox_test_output_cleanup EXIT
gamebox_run_step "APK packaging gate fixtures" \
  env GAMEBOX_TEST_NESTED=1 bash tool/verify_android_apk.sh --self-test
gamebox_run_step "toolchain bootstrap" bash tool/bootstrap.sh --build-only
gamebox_run_step "fast verification" env GAMEBOX_TEST_NESTED=1 bash tool/verify_fast.sh
gamebox_test_output_finish verify

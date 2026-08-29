#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
fixture_root="$(mktemp -d -t gamebox-godot-status.XXXXXX)"
readonly fixture_root

cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

fake_godot="$fixture_root/fake-godot"
cat >"$fake_godot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

phase="tests"
for argument in "$@"; do
  if [[ "$argument" == "--import" ]]; then
    phase="import"
    break
  fi
done

if [[ "$phase" == "import" ]]; then
  printf '%b' "${FAKE_GODOT_IMPORT_OUTPUT:-}"
  exit "${FAKE_GODOT_IMPORT_STATUS:-0}"
fi

printf '%b' "${FAKE_GODOT_TEST_OUTPUT:-GAMEBOX_GODOT_TESTS_PASSED\n}"
exit "${FAKE_GODOT_TEST_STATUS:-0}"
EOF
chmod +x "$fake_godot"

run_fixture() {
  # Keep the fixture bounded without racing process startup on a busy CI host.
  env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
    GODOT_BIN="$fake_godot" \
    GODOT_TEST_WATCHDOG_SECONDS=5 \
    "$@" bash "$ROOT_DIR/tool/verify_godot_tests.sh" 2>&1
}

assert_contains() {
  local output="$1"
  local expected="$2"
  grep -F "$expected" <<<"$output" >/dev/null || {
    printf 'Expected output to contain %q:\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

runner_status=0
runner_output="$(
  run_fixture \
    GAMEBOX_TEST_OUTPUT=compact \
    FAKE_GODOT_IMPORT_OUTPUT='fixture import failure\n' \
    FAKE_GODOT_IMPORT_STATUS=3
)" || runner_status=$?
[[ "$runner_status" -eq 3 ]] || {
  printf 'Godot import verifier changed child status 3 to %s:\n%s\n' \
    "$runner_status" "$runner_output" >&2
  exit 1
}
assert_contains "$runner_output" "FAIL Godot resource import (exit 3)"
assert_contains "$runner_output" "fixture import failure"

runner_status=0
runner_output="$(
  run_fixture \
    GAMEBOX_TEST_OUTPUT=compact \
    FAKE_GODOT_TEST_OUTPUT='fixture Godot test failure\n' \
    FAKE_GODOT_TEST_STATUS=2
)" || runner_status=$?
[[ "$runner_status" -eq 2 ]] || {
  printf 'Godot test verifier changed child status 2 to %s:\n%s\n' \
    "$runner_status" "$runner_output" >&2
  exit 1
}
assert_contains "$runner_output" "FAIL Godot tests (exit 2)"
assert_contains "$runner_output" "fixture Godot test failure"

runner_output="$(
  run_fixture \
    GAMEBOX_TEST_OUTPUT=compact \
    FAKE_GODOT_IMPORT_OUTPUT='hidden import success\n' \
    FAKE_GODOT_TEST_OUTPUT='hidden test success\nGAMEBOX_GODOT_TESTS_PASSED\n'
)"
[[ "$runner_output" == "PASS godot-tests (2 checks)" ]] || {
  printf 'Godot verifier compact success was noisy:\n%s\n' "$runner_output" >&2
  exit 1
}

runner_output="$(
  run_fixture \
    GAMEBOX_TEST_OUTPUT=verbose \
    FAKE_GODOT_IMPORT_OUTPUT='verbose import success\n' \
    FAKE_GODOT_TEST_OUTPUT='verbose test success\nGAMEBOX_GODOT_TESTS_PASSED\n'
)"
assert_contains "$runner_output" "verbose import success"
assert_contains "$runner_output" "verbose test success"
assert_contains "$runner_output" "PASS godot-tests (2 checks)"

runner_output="$(
  run_fixture \
    GAMEBOX_TEST_OUTPUT=compact \
    FAKE_GODOT_IMPORT_OUTPUT='WARNING: import fixture\n' \
    FAKE_GODOT_TEST_OUTPUT='WARNING: test fixture\nGAMEBOX_GODOT_TESTS_PASSED\n'
)"
[[ "$runner_output" == "PASS godot-tests (2 checks, 2 warnings)" ]] || {
  printf 'Godot verifier did not aggregate warnings:\n%s\n' "$runner_output" >&2
  exit 1
}

printf 'Godot verifier fixtures passed.\n'

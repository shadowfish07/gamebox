#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
readonly OUTPUT_LIBRARY="$ROOT_DIR/tool/lib/check_output.sh"

fail() {
  printf 'Check output fixture failed: %s\n' "$1" >&2
  exit 1
}

compact_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=compact bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
  gamebox_run_step "quiet one" bash -c "printf noisy-success"
  gamebox_run_step "quiet two" bash -c "printf \"warning: fixture warning\\n\" >&2"
  gamebox_test_output_finish fixture
' _ "$OUTPUT_LIBRARY")"
[[ "$compact_output" == 'PASS fixture (2 checks, 1 warning)' ]] \
  || fail "compact success was not reduced to one summary: $compact_output"

failure_status=0
failure_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=compact bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
  gamebox_run_step "passing first" bash -c "printf prior-success-noise"
  gamebox_run_step "broken step" bash -c "printf relevant-failure-detail >&2; exit 7"
' _ "$OUTPUT_LIBRARY" 2>&1)" || failure_status=$?
[[ "$failure_status" -eq 7 ]] \
  || fail "failure status was $failure_status instead of 7"
grep -F 'FAIL broken step (exit 7)' <<<"$failure_output" >/dev/null \
  || fail "failure headline was missing: $failure_output"
grep -F 'relevant-failure-detail' <<<"$failure_output" >/dev/null \
  || fail "failure detail was missing: $failure_output"
if grep -F 'prior-success-noise' <<<"$failure_output" >/dev/null; then
  fail "a successful prior step leaked into failure output: $failure_output"
fi

verbose_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=verbose bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
  gamebox_run_step "visible step" bash -c "printf visible-success-noise"
  gamebox_test_output_finish verbose-fixture
' _ "$OUTPUT_LIBRARY")"
grep -F 'visible-success-noise' <<<"$verbose_output" >/dev/null \
  || fail "verbose mode did not stream successful output: $verbose_output"
grep -F 'PASS verbose-fixture (1 check)' <<<"$verbose_output" >/dev/null \
  || fail "verbose mode omitted the final summary: $verbose_output"

verbose_failure_status=0
verbose_failure_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=verbose bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
  gamebox_run_step "verbose broken" bash -c "printf verbose-failure-detail >&2; exit 2"
' _ "$OUTPUT_LIBRARY" 2>&1)" || verbose_failure_status=$?
[[ "$verbose_failure_status" -eq 2 ]] \
  || fail "verbose failure status was $verbose_failure_status instead of 2"
[[ "$(grep -Fo 'verbose-failure-detail' <<<"$verbose_failure_output" | wc -l | tr -d ' ')" -eq 1 ]] \
  || fail "verbose failure detail was not emitted exactly once: $verbose_failure_output"

nested_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=compact bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
  gamebox_run_step nested env GAMEBOX_TEST_NESTED=1 bash -c '\''
    set -euo pipefail
    source "$1"
    gamebox_test_output_init
    gamebox_run_step child bash -c "printf \"WARNING: nested warning\\n\" >&2"
    gamebox_test_output_finish child-suite
  '\'' _ "$1"
  gamebox_test_output_finish parent-suite
' _ "$OUTPUT_LIBRARY")"
[[ "$nested_output" == 'PASS parent-suite (1 check, 1 warning)' ]] \
  || fail "nested warnings were not included in the parent summary: $nested_output"

nested_verbose_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=verbose bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
  gamebox_run_step nested env GAMEBOX_TEST_NESTED=1 bash -c '\''
    set -euo pipefail
    source "$1"
    gamebox_test_output_init
    gamebox_run_step child bash -c "printf \"Warning: nested verbose warning\\n\" >&2"
    gamebox_test_output_finish child-suite
  '\'' _ "$1"
  gamebox_test_output_finish parent-suite
' _ "$OUTPUT_LIBRARY")"
grep -F 'PASS parent-suite (1 check, 1 warning)' <<<"$nested_verbose_output" >/dev/null \
  || fail "nested verbose warning was not counted exactly once: $nested_verbose_output"

mixed_warning_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=verbose bash -c '
  set -euo pipefail
  source "$1"
  output_library="$1"
  gamebox_test_output_init
  mixed_step() {
    env GAMEBOX_TEST_NESTED=1 bash -c '\''
      set -euo pipefail
      source "$1"
      gamebox_test_output_init
      gamebox_run_step child bash -c "printf \"warning: nested mixed warning\\n\" >&2"
      gamebox_test_output_finish child-suite
    '\'' _ "$output_library"
    printf "warning: parent mixed warning\n" >&2
  }
  gamebox_run_step mixed mixed_step
  gamebox_test_output_finish parent-suite
' _ "$OUTPUT_LIBRARY")"
grep -F 'PASS parent-suite (1 check, 2 warnings)' <<<"$mixed_warning_output" >/dev/null \
  || fail "mixed parent and nested warnings were not both counted: $mixed_warning_output"

identical_compact_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=compact bash -c '
  set -euo pipefail
  source "$1"
  output_library="$1"
  gamebox_test_output_init
  identical_step() {
    env GAMEBOX_TEST_NESTED=1 bash -c '\''
      set -euo pipefail
      source "$1"
      gamebox_test_output_init
      gamebox_run_step child bash -c "printf \"warning: identical warning\\n\" >&2"
      gamebox_test_output_finish child-suite
    '\'' _ "$output_library"
    printf "warning: identical warning\n" >&2
  }
  gamebox_run_step identical identical_step
  gamebox_test_output_finish parent-suite
' _ "$OUTPUT_LIBRARY")"
[[ "$identical_compact_output" == 'PASS parent-suite (1 check, 2 warnings)' ]] \
  || fail "identical compact parent and nested warnings were conflated: $identical_compact_output"

signal_status=0
signal_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=compact bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
  gamebox_run_step terminated bash -c '\''kill -TERM "$$"'\''
' _ "$OUTPUT_LIBRARY" 2>&1)" || signal_status=$?
[[ "$signal_status" -eq 143 ]] \
  || fail "TERM-derived status was $signal_status instead of 143: $signal_output"
grep -F 'FAIL terminated (exit 143)' <<<"$signal_output" >/dev/null \
  || fail "TERM-derived failure headline was missing: $signal_output"

interrupt_status=0
interrupt_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=compact bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
  gamebox_run_step interrupted bash -c '\''kill -INT "$$"'\''
' _ "$OUTPUT_LIBRARY" 2>&1)" || interrupt_status=$?
[[ "$interrupt_status" -eq 130 ]] \
  || fail "INT-derived status was $interrupt_status instead of 130: $interrupt_output"
grep -F 'FAIL interrupted (exit 130)' <<<"$interrupt_output" >/dev/null \
  || fail "INT-derived failure headline was missing: $interrupt_output"

invalid_status=0
invalid_output="$(env -u GAMEBOX_TEST_WARNING_FILE -u GAMEBOX_TEST_NESTED \
  GAMEBOX_TEST_OUTPUT=invalid bash -c '
  set -euo pipefail
  source "$1"
  gamebox_test_output_init
' _ "$OUTPUT_LIBRARY" 2>&1)" || invalid_status=$?
[[ "$invalid_status" -eq 2 ]] \
  || fail "invalid output mode exited $invalid_status instead of 2"
grep -F 'GAMEBOX_TEST_OUTPUT must be compact or verbose.' <<<"$invalid_output" >/dev/null \
  || fail "invalid output mode diagnostic was missing: $invalid_output"

printf 'Check output fixtures passed.\n'

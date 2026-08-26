#!/usr/bin/env bash

if [[ -n "${GAMEBOX_CHECK_OUTPUT_LOADED:-}" ]]; then
  return 0
fi
readonly GAMEBOX_CHECK_OUTPUT_LOADED=1

GAMEBOX_TEST_CHECK_COUNT=0
GAMEBOX_TEST_WARNING_FILE_OWNED=0

gamebox_test_output_cleanup() {
  if ((GAMEBOX_TEST_WARNING_FILE_OWNED)) && [[ -n "${GAMEBOX_TEST_WARNING_FILE:-}" ]]; then
    rm -f -- "$GAMEBOX_TEST_WARNING_FILE"
    unset GAMEBOX_TEST_WARNING_FILE
    GAMEBOX_TEST_WARNING_FILE_OWNED=0
  fi
}

gamebox_test_output_init() {
  case "${GAMEBOX_TEST_OUTPUT:-compact}" in
    compact | verbose) ;;
    *)
      printf 'GAMEBOX_TEST_OUTPUT must be compact or verbose.\n' >&2
      return 2
      ;;
  esac

  GAMEBOX_TEST_CHECK_COUNT=0
  if [[ -z "${GAMEBOX_TEST_WARNING_FILE:-}" ]]; then
    GAMEBOX_TEST_WARNING_FILE="$(mktemp -t gamebox-test-warnings.XXXXXX)"
    export GAMEBOX_TEST_WARNING_FILE
    GAMEBOX_TEST_WARNING_FILE_OWNED=1
  else
    touch "$GAMEBOX_TEST_WARNING_FILE"
  fi
}

gamebox_collect_step_warnings() {
  local log_file="$1"
  local warning_count_before="$2"
  local subtract_nested_replay="${3:-0}"
  local captured_warnings nested_warnings warning_count_after
  captured_warnings="$(mktemp -t gamebox-step-warnings.XXXXXX)"
  nested_warnings="$(mktemp -t gamebox-nested-warnings.XXXXXX)"
  LC_ALL=C grep -Ei '^(w:|warning([[:space:]]*[:=-])|Deprecated Gradle features|Future versions of Flutter)' \
    "$log_file" >"$captured_warnings" || true

  warning_count_after="$(gamebox_test_output_warning_count)"
  if ((subtract_nested_replay && warning_count_after > warning_count_before)); then
    tail -n "+$((warning_count_before + 1))" "$GAMEBOX_TEST_WARNING_FILE" >"$nested_warnings"
    awk '
      NR == FNR { nested[$0]++; next }
      nested[$0] > 0 { nested[$0]--; next }
      { print }
    ' "$nested_warnings" "$captured_warnings" >>"$GAMEBOX_TEST_WARNING_FILE"
  else
    sed -n 'p' "$captured_warnings" >>"$GAMEBOX_TEST_WARNING_FILE"
  fi
  rm -f -- "$captured_warnings" "$nested_warnings"
}

gamebox_run_step() {
  local label="$1"
  shift

  local log_file
  log_file="$(mktemp -t gamebox-test-step.XXXXXX)"
  local command_status=0
  local warning_count_before
  warning_count_before="$(gamebox_test_output_warning_count)"

  if [[ "${GAMEBOX_TEST_OUTPUT:-compact}" == verbose ]]; then
    local -a pipeline_statuses
    if "$@" 2>&1 | tee "$log_file"; then
      pipeline_statuses=("${PIPESTATUS[@]}")
    else
      pipeline_statuses=("${PIPESTATUS[@]}")
    fi
    command_status="${pipeline_statuses[0]}"
  elif "$@" >"$log_file" 2>&1; then
    command_status=0
  else
    command_status=$?
  fi

  local subtract_nested_replay=0
  if [[ "${GAMEBOX_TEST_OUTPUT:-compact}" == verbose ]] || ((command_status != 0)); then
    subtract_nested_replay=1
  fi
  gamebox_collect_step_warnings \
    "$log_file" "$warning_count_before" "$subtract_nested_replay"
  if ((command_status == 0)); then
    GAMEBOX_TEST_CHECK_COUNT=$((GAMEBOX_TEST_CHECK_COUNT + 1))
    rm -f -- "$log_file"
    return 0
  fi

  printf 'FAIL %s (exit %s)\n' "$label" "$command_status" >&2
  if [[ "${GAMEBOX_TEST_OUTPUT:-compact}" != verbose ]]; then
    cat "$log_file" >&2
  fi
  rm -f -- "$log_file"
  gamebox_test_output_cleanup
  return "$command_status"
}

gamebox_test_output_warning_count() {
  if [[ -n "${GAMEBOX_TEST_WARNING_FILE:-}" && -f "$GAMEBOX_TEST_WARNING_FILE" ]]; then
    wc -l <"$GAMEBOX_TEST_WARNING_FILE" | tr -d ' '
  else
    printf '0\n'
  fi
}

gamebox_test_progress() {
  if [[ "${GAMEBOX_TEST_OUTPUT:-compact}" == compact ]]; then
    printf '%s\n' "$*"
  fi
}

gamebox_test_output_finish() {
  local suite="$1"
  local warning_count
  warning_count="$(gamebox_test_output_warning_count)"

  if [[ "${GAMEBOX_TEST_NESTED:-0}" != 1 ]]; then
    local check_word=checks
    local warning_word=warnings
    [[ "$GAMEBOX_TEST_CHECK_COUNT" -eq 1 ]] && check_word=check
    [[ "$warning_count" -eq 1 ]] && warning_word=warning
    if ((warning_count > 0)); then
      printf 'PASS %s (%s %s, %s %s)\n' \
        "$suite" "$GAMEBOX_TEST_CHECK_COUNT" "$check_word" "$warning_count" "$warning_word"
    else
      printf 'PASS %s (%s %s)\n' "$suite" "$GAMEBOX_TEST_CHECK_COUNT" "$check_word"
    fi
  fi
  gamebox_test_output_cleanup
}

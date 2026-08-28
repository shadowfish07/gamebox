#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
runner="$root_dir/tool/e2e/run.sh"

fail() {
  printf 'E2E CLI fixture failed: %s\n' "$1" >&2
  exit 1
}

scenario_output="$(bash "$runner" --list-scenarios)"
grep -F 'full' <<<"$scenario_output" >/dev/null \
  || fail 'full scenario is missing from the registry'
for scenario in flutter-host gomoku-network rps-network; do
  grep -F "$scenario" <<<"$scenario_output" >/dev/null \
    || fail "$scenario is missing from the registry"
done

help_output="$(bash "$runner" --help)"
grep -F -- '--scenario NAME' <<<"$help_output" >/dev/null \
  || fail 'scenario option is missing from help'

invalid_status=0
invalid_output="$(bash "$runner" --scenario missing 2>&1)" || invalid_status=$?
[[ "$invalid_status" == 2 ]] \
  || fail "unknown scenario exited $invalid_status instead of 2"
grep -F 'unknown E2E scenario: missing' <<<"$invalid_output" >/dev/null \
  || fail 'unknown scenario diagnostic is missing'

plan_output="$(bash "$runner" --scenario gomoku-network --scenario rps-network --plan)"
[[ "$plan_output" == 'Selected E2E scenarios: gomoku-network rps-network' ]] \
  || fail "focused scenario plan was unexpected: $plan_output"

combined_full_status=0
combined_full_output="$(bash "$runner" --scenario full --scenario rps-network --plan 2>&1)" \
  || combined_full_status=$?
[[ "$combined_full_status" == 2 ]] \
  || fail "combined full scenario exited $combined_full_status instead of 2"
grep -F 'the full scenario cannot be combined with another scenario' \
  <<<"$combined_full_output" >/dev/null \
  || fail 'combined full scenario diagnostic is missing'

printf 'E2E CLI fixtures passed.\n'

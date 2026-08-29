#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly root_dir
# shellcheck source=tool/e2e/lib/options.sh
source "$root_dir/tool/e2e/lib/options.sh"
# shellcheck source=tool/lib/check_output.sh
source "$root_dir/tool/lib/check_output.sh"

gamebox_e2e_parse_options "$@" || {
  gamebox_e2e_usage >&2
  exit 2
}

if ((GAMEBOX_E2E_HELP)); then
  gamebox_e2e_usage
  exit 0
fi
if ((GAMEBOX_E2E_LIST_ONLY)); then
  gamebox_e2e_list_scenarios
  exit 0
fi
if ((GAMEBOX_E2E_PLAN_ONLY)); then
  printf 'Selected E2E scenarios:'
  printf ' %s' "${GAMEBOX_E2E_SCENARIOS[@]}"
  printf '\n'
  exit 0
fi
if ((GAMEBOX_E2E_VERBOSE)); then
  export GAMEBOX_TEST_OUTPUT=verbose
fi

if ((GAMEBOX_E2E_SELF_TEST)); then
  gamebox_test_output_init
  trap gamebox_test_output_cleanup EXIT
  gamebox_run_step "E2E CLI fixtures" bash "$root_dir/tool/e2e/test_cli.sh"
  gamebox_run_step "E2E harness fixtures" \
    env GAMEBOX_TEST_NESTED=1 bash "$root_dir/tool/e2e/harness.sh" --self-test
  gamebox_test_output_finish e2e-self-test
  trap - EXIT
  exit 0
fi

scenario_csv="$(IFS=,; printf '%s' "${GAMEBOX_E2E_SCENARIOS[*]}")"
exec env GAMEBOX_E2E_SCENARIOS="$scenario_csv" \
  bash "$root_dir/tool/e2e/harness.sh"

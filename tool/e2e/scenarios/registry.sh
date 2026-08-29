#!/usr/bin/env bash

gamebox_e2e_scenario_enabled() {
  local wanted="$1"
  local selected=",${GAMEBOX_E2E_SCENARIOS:-full},"
  [[ "$selected" == *,full,* || "$selected" == *",$wanted,"* ]]
}

gamebox_e2e_record_scenario_result() {
  local scenario="$1"
  local result_json="$2"
  local result_file="$TEMP_DIR/scenario-$scenario.json"
  jq -c --arg scenario "$scenario" '. + {scenario:$scenario}' \
    <<<"$result_json" >"$result_file"
  SCENARIO_RESULT_FILES+=("$result_file")
}

gamebox_e2e_enter_phase() {
  E2E_PHASE="$1"
}

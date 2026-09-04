#!/usr/bin/env bash

gamebox_e2e_usage() {
  cat <<'EOF'
Usage: bash tool/e2e_android.sh [options]

Options:
  --scenario NAME   Run one focused scenario. Repeat to run several.
  --list-scenarios  List supported scenario names and exit.
  --plan            Print the selected scenarios without changing runtime state.
  --self-test       Run runner and harness fixtures without Android devices.
  --verbose         Stream successful subprocess output.
  -h, --help        Show this help.

With no --scenario, the release-level full suite runs.
EOF
}

gamebox_e2e_list_scenarios() {
  cat <<'EOF'
full                 All cross-runtime scenarios (release-level gate)
flutter-host         Flutter registration/update integration on the packaged app
chinese-checkers-network Chinese Checkers direct paths, authority, and recovery
flight-chess-network Flight Chess dice, plane authority, and recovery
gomoku-network       Gomoku bridge, authority, lifecycle, and recovery
rps-network          RPS sealed-choice, reconnect, authority, and completion
EOF
}

gamebox_e2e_parse_options() {
  GAMEBOX_E2E_SELF_TEST=0
  GAMEBOX_E2E_LIST_ONLY=0
  GAMEBOX_E2E_VERBOSE=0
  GAMEBOX_E2E_HELP=0
  GAMEBOX_E2E_PLAN_ONLY=0
  GAMEBOX_E2E_SCENARIOS=()

  while (($# > 0)); do
    case "$1" in
      --scenario)
        (($# >= 2)) || { printf '%s\n' '--scenario requires a name' >&2; return 2; }
        GAMEBOX_E2E_SCENARIOS+=("$2")
        shift 2
        ;;
      --scenario=*)
        GAMEBOX_E2E_SCENARIOS+=("${1#--scenario=}")
        shift
        ;;
      --list-scenarios)
        GAMEBOX_E2E_LIST_ONLY=1
        shift
        ;;
      --self-test)
        GAMEBOX_E2E_SELF_TEST=1
        shift
        ;;
      --plan)
        GAMEBOX_E2E_PLAN_ONLY=1
        shift
        ;;
      --verbose)
        GAMEBOX_E2E_VERBOSE=1
        shift
        ;;
      -h|--help)
        GAMEBOX_E2E_HELP=1
        shift
        ;;
      *)
        printf 'unknown E2E option: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  if ((${#GAMEBOX_E2E_SCENARIOS[@]} == 0)); then
    GAMEBOX_E2E_SCENARIOS=(full)
  fi

  local scenario
  for scenario in "${GAMEBOX_E2E_SCENARIOS[@]}"; do
    case "$scenario" in
      full|flutter-host|chinese-checkers-network|flight-chess-network|gomoku-network|rps-network) ;;
      '') printf '%s\n' 'scenario name must not be empty' >&2; return 2 ;;
      *) printf 'unknown E2E scenario: %s\n' "$scenario" >&2; return 2 ;;
    esac
  done

  if ((${#GAMEBOX_E2E_SCENARIOS[@]} > 1)); then
    for scenario in "${GAMEBOX_E2E_SCENARIOS[@]}"; do
      if [[ "$scenario" == full ]]; then
        printf '%s\n' 'the full scenario cannot be combined with another scenario' >&2
        return 2
      fi
    done
  fi
}

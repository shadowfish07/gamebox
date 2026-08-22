#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="me.zqydev.gamebox"
readonly MAIN_ACTIVITY="$PACKAGE/.MainActivity"
readonly TEST_PACKAGE="$PACKAGE.test"
readonly TEST_RUNNER="$TEST_PACKAGE/me.zqydev.gamebox.HostSmokeTestRunner"
readonly SET_TEXT_TEST="me.zqydev.gamebox.E2eSetTextTest#setApprovedFieldFromPrivateInputWithoutEchoingValue"
readonly CLEAR_CLIPBOARD_TEST="me.zqydev.gamebox.E2eSetTextTest#clearClipboardWithoutReadingIt"
readonly MANAGED_AVD_A="Gamebox_A_API_36"
readonly MANAGED_AVD_B="Gamebox_B_API_36"
readonly MANAGED_PORT_A=5560
readonly MANAGED_PORT_B=5562
readonly WAIT_SECONDS=30
readonly DESIGN_WIDTH=1080
readonly DESIGN_HEIGHT=1920
readonly BOARD_LEFT=60
readonly BOARD_TOP=360
readonly BOARD_SIDE=960
readonly BOARD_GRID_LEFT=96
readonly BOARD_GRID_TOP=396
readonly BOARD_GRID_SIDE=888
readonly GAMEBOX_READY_MARKER="GAMEBOX_GODOT_READY"
readonly GAMEBOX_STATE_MARKER="GAMEBOX_GODOT_STATE"
readonly GAMEBOX_RESULT_MARKER="GAMEBOX_MATCH_RESULT"

ADB_BIN="${GAMEBOX_E2E_ADB_BIN:-adb}"
ADB_TIMEOUT_SECONDS="${GAMEBOX_E2E_ADB_TIMEOUT_SECONDS:-30}"
INPUT_TIMEOUT_SECONDS="${GAMEBOX_E2E_INPUT_TIMEOUT_SECONDS:-20}"
BUILD_TIMEOUT_SECONDS="${GAMEBOX_E2E_BUILD_TIMEOUT_SECONDS:-600}"
SEMANTICS_TIMEOUT_SECONDS="${GAMEBOX_E2E_SEMANTICS_TIMEOUT_SECONDS:-300}"
AVD_SETUP_TIMEOUT_SECONDS="${GAMEBOX_E2E_AVD_SETUP_TIMEOUT_SECONDS:-120}"
TIMEOUT_KILL_GRACE_SECONDS="${GAMEBOX_E2E_TIMEOUT_KILL_GRACE_SECONDS:-2}"
BOUND_CHILD_REGISTRY=""
BOUND_SESSION_STATE_DIR=""
readonly HARNESS_PID=$$

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# shellcheck source=tool/lib/android_lease.sh
source "$ROOT_DIR/tool/lib/android_lease.sh"
HARNESS_PGID="$(ps -p "$HARNESS_PID" -o pgid= | tr -d ' ')"
readonly HARNESS_PGID
[[ "$HARNESS_PGID" =~ ^[1-9][0-9]*$ ]] || {
  printf 'Gamebox E2E failed: could not establish the harness process group\n' >&2
  exit 2
}

if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  export JAVA_HOME
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi

if [[ "${1:-}" == "--self-test" ]]; then
  SELF_TEST_ONLY=1
  shift
else
  SELF_TEST_ONLY=0
fi
[[ $# -eq 0 ]] || {
  printf 'usage: %s [--self-test]\n' "$0" >&2
  exit 2
}

terminate_exact_child() {
  local pid="$1"
  local grace_seconds="$2"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  local deadline=$((SECONDS + grace_seconds))
  while ((SECONDS < deadline)) && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
}

process_session_id() {
  local pid="$1"
  ruby "$ROOT_DIR/tool/run_in_session.rb" --session-id "$pid" 2>/dev/null
}

session_group_state() {
  local process_group="$1"
  local expected_session="$2"
  [[ "$process_group" =~ ^[1-9][0-9]*$ && "$expected_session" =~ ^[1-9][0-9]*$ ]] || return 2
  local status
  if ruby "$ROOT_DIR/tool/run_in_session.rb" --validate-session \
    "$process_group" "$expected_session" >/dev/null 2>&1; then
    return 0
  else
    status=$?
    [[ "$status" == "1" ]] && return 1
    return 2
  fi
}

session_numbers_are_safe() {
  local leader_pid="$1"
  local process_group="$2"
  local session_id="$3"
  [[ "$leader_pid" =~ ^[1-9][0-9]*$ \
    && "$leader_pid" == "$process_group" \
    && "$leader_pid" == "$session_id" \
    && "$leader_pid" != "$HARNESS_PID" \
    && "$process_group" != "$HARNESS_PGID" ]]
}

session_identity_is_safe() {
  local leader_pid="$1"
  local process_group="$2"
  local session_id="$3"
  session_numbers_are_safe "$leader_pid" "$process_group" "$session_id" || return 1

  local actual_group actual_session
  actual_group="$(ps -p "$leader_pid" -o pgid= 2>/dev/null | tr -d ' ')"
  actual_session="$(process_session_id "$leader_pid")" || return 1
  [[ "$actual_group" == "$process_group" && "$actual_session" == "$session_id" ]]
}

terminate_owned_session_group() {
  local leader_pid="$1"
  local process_group="$2"
  local session_id="$3"
  local grace_seconds="$4"
  session_numbers_are_safe "$leader_pid" "$process_group" "$session_id" || return 1

  local state
  if session_group_state "$process_group" "$session_id"; then
    state=0
  else
    state=$?
    [[ "$state" == "1" ]] && return 0
    return 1
  fi

  kill -TERM -- "-$process_group" 2>/dev/null || true
  local deadline=$((SECONDS + grace_seconds))
  while ((SECONDS < deadline)); do
    if session_group_state "$process_group" "$session_id"; then
      sleep 0.1
    else
      state=$?
      [[ "$state" == "1" ]] && return 0
      return 1
    fi
  done

  if session_group_state "$process_group" "$session_id"; then
    state=0
  else
    state=$?
    [[ "$state" == "1" ]] && return 0
    return 1
  fi
  kill -KILL -- "-$process_group" 2>/dev/null || true
  deadline=$((SECONDS + grace_seconds))
  while ((SECONDS < deadline)); do
    if session_group_state "$process_group" "$session_id"; then
      sleep 0.1
    else
      state=$?
      [[ "$state" == "1" ]] && return 0
      return 1
    fi
  done
  if session_group_state "$process_group" "$session_id" >/dev/null 2>&1; then
    return 1
  else
    state=$?
    [[ "$state" == "1" ]]
  fi
}

valid_session_ready_path() {
  local ready_path="$1"
  [[ -n "$BOUND_SESSION_STATE_DIR" \
    && "$ready_path" == "$BOUND_SESSION_STATE_DIR"/session-*.ready \
    && "${ready_path##*/}" =~ ^session-[0-9]+-[0-9]+\.ready$ ]]
}

cleanup_bounded_session() {
  local leader_pid="$1"
  local process_group="$2"
  local session_id="$3"
  local marker="$4"
  local ready_path="$5"
  if [[ -n "$process_group" ]]; then
    terminate_owned_session_group "$leader_pid" "$process_group" "$session_id" \
      "$TIMEOUT_KILL_GRACE_SECONDS" || true
  else
    terminate_exact_child "$leader_pid" "$TIMEOUT_KILL_GRACE_SECONDS"
  fi
  wait "$leader_pid" 2>/dev/null || true
  [[ -z "$marker" ]] || rm -f -- "$marker"
  valid_session_ready_path "$ready_path" && rm -f -- "$ready_path"
}

run_with_timeout() (
  local timeout_seconds="$1"
  shift
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] && ((timeout_seconds > 0)) || return 2
  (($# > 0)) || return 2
  [[ -x "$ROOT_DIR/tool/run_in_session.rb" \
    && -n "$BOUND_SESSION_STATE_DIR" && -d "$BOUND_SESSION_STATE_DIR" ]] || return 125

  local ready_path="$BOUND_SESSION_STATE_DIR/session-${BASHPID:-$$}-$RANDOM.ready"
  ruby "$ROOT_DIR/tool/run_in_session.rb" "$ready_path" -- "$@" <&0 &
  local child_pid=$!
  local child_marker=""
  if [[ -n "$BOUND_CHILD_REGISTRY" ]]; then
    child_marker="$BOUND_CHILD_REGISTRY/$child_pid"
    printf 'pending %s\n' "$ready_path" >"$child_marker"
  fi
  local process_group=""
  local session_id=""
  trap 'cleanup_bounded_session "$child_pid" "$process_group" "$session_id" "$child_marker" "$ready_path"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local handshake_deadline=$((SECONDS + 2))
  while [[ ! -s "$ready_path" ]] && kill -0 "$child_pid" 2>/dev/null; do
    ((SECONDS < handshake_deadline)) || break
    sleep 0.05
  done
  local handshake_pid extra=""
  if [[ ! -s "$ready_path" ]] \
    || ! read -r handshake_pid process_group session_id extra <"$ready_path" \
    || [[ -n "$extra" || "$handshake_pid" != "$child_pid" ]] \
    || ! session_numbers_are_safe "$child_pid" "$process_group" "$session_id"; then
    cleanup_bounded_session "$child_pid" "" "" "$child_marker" "$ready_path"
    child_pid=""
    child_marker=""
    ready_path=""
    trap - EXIT INT TERM
    return 125
  fi
  local handshake_state=0
  if session_identity_is_safe "$child_pid" "$process_group" "$session_id"; then
    handshake_state=0
  elif session_group_state "$process_group" "$session_id"; then
    handshake_state=0
  else
    handshake_state=$?
    if [[ "$handshake_state" == "1" ]]; then
      local fast_status
      if wait "$child_pid"; then
        fast_status=0
      else
        fast_status=$?
      fi
      child_pid=""
      [[ -z "$child_marker" ]] || rm -f -- "$child_marker"
      child_marker=""
      valid_session_ready_path "$ready_path" && rm -f -- "$ready_path"
      ready_path=""
      trap - EXIT INT TERM
      return "$fast_status"
    fi
    cleanup_bounded_session "$child_pid" "" "" "$child_marker" "$ready_path"
    child_pid=""
    child_marker=""
    ready_path=""
    trap - EXIT INT TERM
    return 125
  fi
  [[ -z "$child_marker" ]] \
    || printf 'session %s %s %s %s\n' "$child_pid" "$process_group" "$session_id" "$ready_path" >"$child_marker"

  local deadline=$((SECONDS + timeout_seconds))
  local state
  while true; do
    if session_group_state "$process_group" "$session_id"; then
      state=0
    else
      state=$?
      [[ "$state" == "1" ]] && break
      cleanup_bounded_session "$child_pid" "$process_group" "$session_id" "$child_marker" "$ready_path"
      child_pid=""
      child_marker=""
      ready_path=""
      trap - EXIT INT TERM
      return 125
    fi
    if ((SECONDS >= deadline)); then
      terminate_owned_session_group "$child_pid" "$process_group" "$session_id" \
        "$TIMEOUT_KILL_GRACE_SECONDS" || return 125
      wait "$child_pid" 2>/dev/null || true
      child_pid=""
      [[ -z "$child_marker" ]] || rm -f -- "$child_marker"
      child_marker=""
      valid_session_ready_path "$ready_path" && rm -f -- "$ready_path"
      ready_path=""
      trap - EXIT INT TERM
      return 124
    fi
    sleep 0.1
  done

  local status
  if wait "$child_pid"; then
    status=0
  else
    status=$?
  fi
  child_pid=""
  [[ -z "$child_marker" ]] || rm -f -- "$child_marker"
  child_marker=""
  valid_session_ready_path "$ready_path" && rm -f -- "$ready_path"
  ready_path=""
  trap - EXIT INT TERM
  return "$status"
)

pid_descends_from_harness() {
  local current="$1"
  local _
  [[ "$current" =~ ^[0-9]+$ ]] || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [[ "$current" == "$HARNESS_PID" ]] && return 0
    current="$(ps -p "$current" -o ppid= 2>/dev/null | tr -d ' ')"
    [[ "$current" =~ ^[0-9]+$ && "$current" != "0" ]] || return 1
  done
  return 1
}

terminate_registered_bounded_children() {
  local marker pid kind marker_pid process_group session_id ready_path extra
  [[ -d "$BOUND_CHILD_REGISTRY" ]] || return 0
  for marker in "$BOUND_CHILD_REGISTRY"/*; do
    [[ -f "$marker" ]] || continue
    pid="${marker##*/}"
    kind=""
    marker_pid=""
    process_group=""
    session_id=""
    ready_path=""
    extra=""
    read -r kind marker_pid process_group session_id ready_path extra <"$marker" || true
    if [[ "$kind" == "session" && -z "$extra" && "$marker_pid" == "$pid" \
      && -n "$ready_path" ]] \
      && valid_session_ready_path "$ready_path" \
      && session_numbers_are_safe "$pid" "$process_group" "$session_id"; then
      terminate_owned_session_group "$pid" "$process_group" "$session_id" \
        "$TIMEOUT_KILL_GRACE_SECONDS" || true
    elif [[ "$kind" == "pending" ]]; then
      ready_path="$marker_pid"
      if valid_session_ready_path "$ready_path" && [[ -s "$ready_path" ]] \
        && read -r marker_pid process_group session_id extra <"$ready_path" \
        && [[ -z "$extra" && "$marker_pid" == "$pid" ]] \
        && session_numbers_are_safe "$pid" "$process_group" "$session_id"; then
        terminate_owned_session_group "$pid" "$process_group" "$session_id" \
          "$TIMEOUT_KILL_GRACE_SECONDS" || true
      elif pid_descends_from_harness "$pid"; then
        terminate_exact_child "$pid" "$TIMEOUT_KILL_GRACE_SECONDS"
      fi
    elif pid_descends_from_harness "$pid"; then
      terminate_exact_child "$pid" "$TIMEOUT_KILL_GRACE_SECONDS"
    fi
    valid_session_ready_path "$ready_path" && rm -f -- "$ready_path"
    rm -f -- "$marker"
  done
}

adb_for_timeout() {
  local timeout_seconds="$1"
  local serial="$2"
  shift 2
  run_with_timeout "$timeout_seconds" "$ADB_BIN" -s "$serial" "$@"
}

adb_for() {
  local serial="$1"
  shift
  adb_for_timeout "$ADB_TIMEOUT_SECONDS" "$serial" "$@"
}

refresh_game_log_boundaries() {
  local suffix="$1"
  [[ "$suffix" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || return 2
  local boundary_a="GAMEBOX_E2E_A_${suffix}_$RUN_ID"
  local boundary_b="GAMEBOX_E2E_B_${suffix}_$RUN_ID"
  adb_for "$SERIAL_A" shell log -p i -t GameboxE2E "$boundary_a" >/dev/null || return 1
  adb_for "$SERIAL_B" shell log -p i -t GameboxE2E "$boundary_b" >/dev/null || return 1
  LOG_BOUNDARY_A="$boundary_a"
  LOG_BOUNDARY_B="$boundary_b"
}

capture_adb_devices() {
  local output_variable="$1"
  local captured_listing
  if ! captured_listing="$(run_with_timeout "$ADB_TIMEOUT_SECONDS" "$ADB_BIN" devices 2>&1)"; then
    return 2
  fi
  local saw_header=0 line
  while IFS= read -r line; do
    [[ "$line" == "List of devices attached" ]] && saw_header=1
  done <<<"$captured_listing"
  ((saw_header == 1)) || return 2
  printf -v "$output_variable" '%s' "$captured_listing"
}

find_managed_avd_serial() {
  local avd_name="$1"
  local devices_result="$2"
  local serial state _ running_name found=""
  while read -r serial state _; do
    [[ "$serial" == emulator-* && "$state" == "device" ]] || continue
    if ! running_name="$(adb_for "$serial" shell getprop ro.boot.qemu.avd_name 2>/dev/null | tr -d '\r')"; then
      return 2
    fi
    if [[ "$running_name" == "$avd_name" ]]; then
      [[ -z "$found" ]] || return 2
      found="$serial"
    fi
  done <<<"$devices_result"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

managed_avd_start_preflight() {
  local avd_name="$1"
  local devices_listing existing_serial status
  capture_adb_devices devices_listing || return 2
  if existing_serial="$(find_managed_avd_serial "$avd_name" "$devices_listing")"; then
    return 1
  else
    status=$?
    [[ "$status" == "1" ]] || return 2
  fi
  return 0
}

provenance_contract() {
  local start_head="$1"
  local start_status="$2"
  local end_head="$3"
  local end_status="$4"
  [[ "$start_head" =~ ^[0-9a-f]{40}$ \
    && -z "$start_status" \
    && "$end_head" == "$start_head" \
    && -z "$end_status" ]]
}

# This parser is deliberately resource-id only. Human-readable labels and
# content descriptions are diagnostics, never automation selectors.
xml_query() {
  local mode="$1"
  local xml_path="$2"
  local expected="${3:-}"
  ruby -r rexml/document -e '
    mode, path, expected = ARGV
    document = REXML::Document.new(File.binread(path))
    nodes = []
    document.elements.each("//node") { |node| nodes << node }
    enabled = ->(node) { node.attributes["enabled"] == "true" && node.attributes["visible-to-user"] != "false" }
    bounds = ->(node) do
      match = /\A\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]\z/.match(node.attributes["bounds"].to_s)
      next nil unless match
      values = match.captures.map(&:to_i)
      next nil unless values[2] > values[0] && values[3] > values[1]
      [((values[0] + values[2]) / 2), ((values[1] + values[3]) / 2)]
    end
    case mode
    when "bounds"
      matches = nodes.select { |node| node.attributes["resource-id"] == expected && enabled.call(node) && bounds.call(node) }
      exit 3 unless matches.length == 1
      puts bounds.call(matches.first).join(" ")
    when "opponent"
      pattern = /\Aopponent-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      matches = nodes.select { |node| pattern.match?(node.attributes["resource-id"].to_s) && enabled.call(node) && bounds.call(node) }
      exit 3 unless matches.length == 1
      puts matches.first.attributes["resource-id"]
    when "field-text"
      matches = nodes.select { |node| node.attributes["resource-id"] == expected }
      exit 3 unless matches.length == 1
      values = []
      own_value = matches.first.attributes["text"].to_s
      values << own_value unless own_value.empty?
      matches.first.each_element(".//node") do |node|
        value = node.attributes["text"].to_s
        values << value unless value.empty?
      end
      values.uniq!
      exit 3 unless values.length == 1
      puts values.first
    when "field-empty"
      matches = nodes.select { |node| node.attributes["resource-id"] == expected }
      exit 3 unless matches.length == 1
      values = [matches.first.attributes["text"].to_s]
      matches.first.each_element(".//node") { |node| values << node.attributes["text"].to_s }
      exit 3 unless values.all?(&:empty?)
    when "diagnostics"
      nodes.each do |node|
        identifier = node.attributes["resource-id"].to_s
        text = node.attributes["text"].to_s
        description = node.attributes["content-desc"].to_s
        next if identifier.empty? && text.empty? && description.empty?
        puts "id=#{identifier.empty? ? "-" : identifier} text=#{text.empty? ? "-" : text} desc=#{description.empty? ? "-" : description}"
      end
    else
      exit 2
    end
  ' "$mode" "$xml_path" "$expected"
}

sanitize_stream() {
  sed -E \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1[REDACTED]/g' \
    -e 's/("(accessToken|refreshToken|launchTicket|inviteCode|invites)"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"[REDACTED]"/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[REDACTED_JWT]/g' \
    -e 's/[A-Za-z0-9_-]{40,}/[REDACTED_HIGH_ENTROPY]/g'
}

device_summary_json() {
  local serial_a="$1"
  local serial_b="$2"
  local api_level_a="$3"
  local api_level_b="$4"
  local api_base_url="$5"
  jq -cn \
    --arg serialA "$serial_a" \
    --arg serialB "$serial_b" \
    --arg apiLevelA "$api_level_a" \
    --arg apiLevelB "$api_level_b" \
    --arg apiBaseUrl "$api_base_url" \
    '{
      serialA:$serialA,
      serialB:$serialB,
      apiLevelA:($apiLevelA | tonumber),
      apiLevelB:($apiLevelB | tonumber),
      apiBaseUrl:$apiBaseUrl
    }'
}

failure_media_safe() {
  local secret_active="$1"
  local clear_verified="$2"
  [[ "$secret_active" == "0" || ("$secret_active" == "1" && "$clear_verified" == "1") ]]
}

fixed_value_absent() {
  local file="$1"
  local value="$2"
  local status
  if printf '%s\n' "$value" \
    | rg --text --fixed-strings --file - -- "$file" >/dev/null 2>&1; then
    return 1
  else
    status=$?
    [[ "$status" == "1" ]]
  fi
}

protect_artifact_directory() {
  local directory="$1"
  local scratch="$2"
  shift 2
  local unsafe=0
  local scanner_failed=0
  local value status file
  : >"$scratch"

  for value in "$@"; do
    [[ -n "$value" ]] || continue
    if printf '%s\n' "$value" \
      | rg --text --files-with-matches --fixed-strings --file - -- "$directory" >"$scratch" 2>/dev/null; then
      while IFS= read -r file; do
        case "$file" in
          "$directory"/*)
            [[ -f "$file" || -L "$file" ]] && rm -f -- "$file"
            ;;
          *) scanner_failed=1 ;;
        esac
      done <"$scratch"
      unsafe=1
    else
      status=$?
      ((status == 1)) || scanner_failed=1
    fi
  done

  local credential_pattern='eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|Authorization[[:space:]]*:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{8,}|"(accessToken|refreshToken|launchTicket|inviteCode)"[[:space:]]*:[[:space:]]*"[A-Za-z0-9._-]{8,}'
  if rg --text --files-with-matches "$credential_pattern" "$directory" >"$scratch" 2>/dev/null; then
    while IFS= read -r file; do
      case "$file" in
        "$directory"/*)
          [[ -f "$file" || -L "$file" ]] && rm -f -- "$file"
          ;;
        *) scanner_failed=1 ;;
      esac
    done <"$scratch"
    unsafe=1
  else
    status=$?
    ((status == 1)) || scanner_failed=1
  fi

  if ((scanner_failed)); then
    for file in "$directory"/*; do
      [[ -e "$file" || -L "$file" ]] || continue
      [[ -f "$file" || -L "$file" ]] && rm -f -- "$file"
    done
    return 1
  fi

  for value in "$@"; do
    [[ -n "$value" ]] || continue
    if printf '%s\n' "$value" \
      | rg --text --fixed-strings --file - -- "$directory" >/dev/null 2>&1; then
      for file in "$directory"/*; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ -f "$file" || -L "$file" ]] && rm -f -- "$file"
      done
      return 1
    else
      status=$?
      if ((status != 1)); then
        for file in "$directory"/*; do
          [[ -e "$file" || -L "$file" ]] || continue
          [[ -f "$file" || -L "$file" ]] && rm -f -- "$file"
        done
        return 1
      fi
    fi
  done
  if rg --text "$credential_pattern" "$directory" >/dev/null 2>&1; then
    for file in "$directory"/*; do
      [[ -e "$file" || -L "$file" ]] || continue
      [[ -f "$file" || -L "$file" ]] && rm -f -- "$file"
    done
    return 1
  else
    status=$?
    if ((status != 1)); then
      for file in "$directory"/*; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ -f "$file" || -L "$file" ]] && rm -f -- "$file"
      done
      return 1
    fi
  fi
  ((unsafe == 0))
}

valid_private_input_name() {
  [[ "$1" =~ ^gamebox-e2e-input-[A-Za-z0-9_.-]{8,96}$ ]]
}

stage_private_input() {
  local serial="$1"
  local input_name="$2"
  valid_private_input_name "$input_name" || return 2
  local private_path="/data/user/0/$TEST_PACKAGE/$input_name"
  local remote_command="run-as $TEST_PACKAGE sh -c 'umask 077; cat > $private_path && chmod 600 $private_path'"
  adb_for_timeout "$INPUT_TIMEOUT_SECONDS" "$serial" \
    shell "$remote_command"
}

remove_private_input() {
  local serial="$1"
  local input_name="$2"
  valid_private_input_name "$input_name" || return 2
  local private_path="/data/user/0/$TEST_PACKAGE/$input_name"
  local remote_command="run-as $TEST_PACKAGE sh -c 'rm -f -- $private_path'"
  adb_for_timeout "$INPUT_TIMEOUT_SECONDS" "$serial" \
    shell "$remote_command" >/dev/null 2>&1
}

private_input_absent() {
  local serial="$1"
  local input_name="$2"
  valid_private_input_name "$input_name" || return 2
  local private_path="/data/user/0/$TEST_PACKAGE/$input_name"
  local remote_command="run-as $TEST_PACKAGE sh -c 'test ! -e $private_path'"
  adb_for_timeout "$INPUT_TIMEOUT_SECONDS" "$serial" \
    shell "$remote_command" >/dev/null 2>&1
}

run_helper_instrumentation() {
  local serial="$1"
  local test_name="$2"
  local output_variable="$3"
  shift 3
  local output status
  if output="$(
    adb_for_timeout "$INPUT_TIMEOUT_SECONDS" "$serial" shell am instrument -w -r \
      -e class "$test_name" "$@" "$TEST_RUNNER" 2>&1
  )"; then
    status=0
  else
    status=$?
  fi
  printf -v "$output_variable" '%s' "$output"
  ((status == 0)) \
    && grep -F 'OK (1 test)' <<<"$output" >/dev/null \
    && ! grep -E 'FAILURES!!!|Process crashed|INSTRUMENTATION_FAILED' <<<"$output" >/dev/null
}

clear_helper_clipboard() {
  local serial="$1"
  adb_for_timeout "$INPUT_TIMEOUT_SECONDS" "$serial" \
    shell am force-stop "$TEST_PACKAGE" >/dev/null 2>&1 || return 1
  local output
  run_helper_instrumentation "$serial" "$CLEAR_CLIPBOARD_TEST" output
}

set_text_from_private_input() {
  local serial="$1"
  local target="$2"
  local input_name="$3"
  valid_private_input_name "$input_name" || return 2
  local output
  if ! run_helper_instrumentation \
    "$serial" "$SET_TEXT_TEST" output \
    -e gameboxTextTarget "$target" \
    -e gameboxTextInputName "$input_name"; then
    remove_private_input "$serial" "$input_name" || true
    clear_helper_clipboard "$serial" || true
    return 1
  fi
  if ! private_input_absent "$serial" "$input_name"; then
    remove_private_input "$serial" "$input_name" || true
    clear_helper_clipboard "$serial" || true
    return 1
  fi
  clear_helper_clipboard "$serial"
}

valid_remote_ui_path() {
  [[ "$1" =~ ^/data/local/tmp/gamebox-e2e-[A-Za-z0-9_.-]{8,96}\.xml$ ]]
}

valid_installed_apk_path() {
  [[ "$1" =~ ^/data/app/[A-Za-z0-9._~+=-]+/[A-Za-z0-9._~+=-]+/base\.apk$ ]]
}

cleanup_remote_ui_dump() {
  local serial="$1"
  local remote="$2"
  valid_remote_ui_path "$remote" || return 2
  adb_for "$serial" shell rm -f -- "$remote" >/dev/null 2>&1
}

dump_ui_remote() {
  local serial="$1"
  local local_path="$2"
  local remote="$3"
  valid_remote_ui_path "$remote" || return 2
  local status=1
  if adb_for "$serial" shell uiautomator dump --compressed "$remote" >/dev/null 2>&1 \
    && adb_for "$serial" pull "$remote" "$local_path" >/dev/null 2>&1 \
    && [[ -s "$local_path" ]]; then
    status=0
  fi
  cleanup_remote_ui_dump "$serial" "$remote" || status=1
  return "$status"
}

self_test() {
  local fixture_dir
  fixture_dir="$(mktemp -d)"
  BOUND_CHILD_REGISTRY="$fixture_dir/bounded-children"
  BOUND_SESSION_STATE_DIR="$fixture_dir/bounded-sessions"
  mkdir "$BOUND_CHILD_REGISTRY" "$BOUND_SESSION_STATE_DIR"
  local session_fixture_direct_pid=""
  local session_fixture_grandchild_pid=""
  local session_fixture_unrelated_pid=""
  local session_fixture_wrapper_pid=""
  trap 'terminate_exact_child "$session_fixture_wrapper_pid" 1; terminate_exact_child "$session_fixture_direct_pid" 1; terminate_exact_child "$session_fixture_grandchild_pid" 1; terminate_exact_child "$session_fixture_unrelated_pid" 1; rm -rf "$fixture_dir"' RETURN
  local fixture="$fixture_dir/ui.xml"
  local opponent_id="opponent-22222222-2222-4222-8222-222222222222"
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>' \
    '<hierarchy rotation="0">' \
    '  <node resource-id="invite-code" text="" content-desc="not-a-selector" enabled="true" visible-to-user="true" bounds="[10,20][110,220]"><node resource-id="" text="fixture-secret" enabled="true" bounds="[10,20][110,220]" /></node>' \
    '  <node resource-id="nickname" text="fixture-nickname" content-desc="" enabled="true" visible-to-user="true" bounds="[120,20][220,220]"><node resource-id="" text="fixture-nickname" enabled="true" bounds="[120,20][220,220]" /></node>' \
    '  <node resource-id="disabled" text="" content-desc="invite-code" enabled="false" visible-to-user="true" bounds="[0,0][50,50]" />' \
    "  <node resource-id=\"$opponent_id\" text=\"Bob\" content-desc=\"Bob\" enabled=\"true\" visible-to-user=\"true\" bounds=\"[100,300][500,500]\" />" \
    '</hierarchy>' >"$fixture"

  [[ "$(xml_query bounds "$fixture" invite-code)" == "60 120" ]] \
    || { printf 'bounds fixture failed\n' >&2; return 1; }
  [[ "$(xml_query field-text "$fixture" invite-code)" == "fixture-secret" ]] \
    || { printf 'field text fixture failed\n' >&2; return 1; }
  [[ "$(xml_query field-text "$fixture" nickname)" == "fixture-nickname" ]] \
    || { printf 'direct field text fixture failed\n' >&2; return 1; }
  if xml_query field-empty "$fixture" invite-code >/dev/null 2>&1; then
    printf 'nonempty field was accepted as cleared\n' >&2
    return 1
  fi
  if xml_query bounds "$fixture" disabled >/dev/null 2>&1; then
    printf 'disabled resource-id fixture was accepted\n' >&2
    return 1
  fi
  if xml_query bounds "$fixture" not-a-selector >/dev/null 2>&1; then
    printf 'content-desc was incorrectly used as a selector\n' >&2
    return 1
  fi
  [[ "$(xml_query opponent "$fixture")" == "$opponent_id" ]] \
    || { printf 'opponent fixture failed\n' >&2; return 1; }

  local duplicate="$fixture_dir/duplicate.xml"
  printf '<hierarchy><node resource-id="register" enabled="true" bounds="[0,0][10,10]"/><node resource-id="register" enabled="true" bounds="[10,10][20,20]"/></hierarchy>\n' >"$duplicate"
  if xml_query bounds "$duplicate" register >/dev/null 2>&1; then
    printf 'duplicate resource-id fixture was accepted\n' >&2
    return 1
  fi
  local malformed="$fixture_dir/malformed.xml"
  printf '<not-xml' >"$malformed"
  if xml_query bounds "$malformed" register >/dev/null 2>&1; then
    printf 'malformed XML fixture was accepted\n' >&2
    return 1
  fi

  local empty_field="$fixture_dir/empty-field.xml"
  printf '<hierarchy><node resource-id="invite-code" text=""><node resource-id="" text=""/></node></hierarchy>\n' >"$empty_field"
  xml_query field-empty "$empty_field" invite-code >/dev/null \
    || { printf 'empty field fixture failed\n' >&2; return 1; }

  local marker='known-secret-value-abcdefghijklmnopqrstuvwxyz0123456789'
  local sanitized
  sanitized="$(printf 'Authorization: Bearer abc.def.ghi %s\n' "$marker" | sanitize_stream)"
  [[ "$sanitized" != *"$marker"* && "$sanitized" != *"abc.def.ghi"* ]] \
    || { printf 'sanitizer fixture failed\n' >&2; return 1; }

  local devices
  devices="$(device_summary_json fixture-A fixture-B 36 35 http://fixture.invalid:18080)"
  jq -e '
    . == {
      serialA:"fixture-A", serialB:"fixture-B",
      apiLevelA:36, apiLevelB:35,
      apiBaseUrl:"http://fixture.invalid:18080"
    } and (has("api") | not)
  ' <<<"$devices" >/dev/null \
    || { printf 'device summary fixture failed\n' >&2; return 1; }

  failure_media_safe 0 0 \
    || { printf 'inactive secret media gate fixture failed\n' >&2; return 1; }
  failure_media_safe 1 1 \
    || { printf 'verified clear media gate fixture failed\n' >&2; return 1; }
  if failure_media_safe 1 0; then
    printf 'uncleared secret media gate fixture was accepted\n' >&2
    return 1
  fi

  local artifact_fixture="$fixture_dir/artifact"
  mkdir "$artifact_fixture"
  printf 'safe diagnostic\n' >"$artifact_fixture/safe.txt"
  printf '%s\n' "$marker" >"$artifact_fixture/known-secret.txt"
  printf 'Authorization: Bearer fixture-token-1234567890\n' >"$artifact_fixture/token.txt"
  if protect_artifact_directory "$artifact_fixture" "$fixture_dir/scan.txt" "$marker"; then
    printf 'contaminated artifact fixture was accepted\n' >&2
    return 1
  fi
  [[ -f "$artifact_fixture/safe.txt" && ! -e "$artifact_fixture/known-secret.txt" && ! -e "$artifact_fixture/token.txt" ]] \
    || { printf 'artifact protection fixture failed\n' >&2; return 1; }
  protect_artifact_directory "$artifact_fixture" "$fixture_dir/scan-clean.txt" "$marker" \
    || { printf 'clean artifact fixture was rejected\n' >&2; return 1; }

  local fixture_head='1111111111111111111111111111111111111111'
  provenance_contract "$fixture_head" "" "$fixture_head" "" \
    || { printf 'clean provenance fixture failed\n' >&2; return 1; }
  if provenance_contract "$fixture_head" ' M tracked-file' "$fixture_head" ""; then
    printf 'dirty start provenance fixture was accepted\n' >&2
    return 1
  fi
  if provenance_contract "$fixture_head" "" '2222222222222222222222222222222222222222' ""; then
    printf 'changed HEAD provenance fixture was accepted\n' >&2
    return 1
  fi
  if provenance_contract "$fixture_head" "" "$fixture_head" '?? generated-file'; then
    printf 'dirty end provenance fixture was accepted\n' >&2
    return 1
  fi
  valid_installed_apk_path '/data/app/~~Ab_C-123==/me.zqydev.gamebox-Xy_Z+987==/base.apk' \
    || { printf 'installed APK path fixture failed\n' >&2; return 1; }
  if valid_installed_apk_path '/data/app/../../data/local/tmp/unsafe.apk'; then
    printf 'unsafe installed APK path fixture was accepted\n' >&2
    return 1
  fi

  local fake_adb="$ROOT_DIR/tool/fixtures/e2e_fake_adb.sh"
  local fake_log="$fixture_dir/fake-adb.log"
  local fake_device_root="$fixture_dir/fake-device"
  local fake_pid_file="$fixture_dir/fake-adb.pid"
  mkdir "$fake_device_root"
  : >"$fake_log"
  export FAKE_ADB_LOG="$fake_log"
  export FAKE_DEVICE_ROOT="$fake_device_root"
  export FAKE_ADB_PID_FILE="$fake_pid_file"
  ADB_BIN="$fake_adb"
  ADB_TIMEOUT_SECONDS=1
  INPUT_TIMEOUT_SECONDS=1
  TIMEOUT_KILL_GRACE_SECONDS=1

  local session_tree="$ROOT_DIR/tool/fixtures/e2e_session_tree.sh"
  local tree_pid_file="$fixture_dir/session-tree.pid"
  local timeout_status=0
  export GAMEBOX_E2E_TREE_PID_FILE="$tree_pid_file"
  export GAMEBOX_E2E_TREE_MODE=ignore-term
  local timeout_output
  local timeout_started=$SECONDS
  if timeout_output="$(run_with_timeout 1 "$session_tree" 2>/dev/null)"; then
    printf 'descendant watchdog fixture unexpectedly succeeded\n' >&2
    return 1
  else
    timeout_status=$?
  fi
  [[ "$timeout_status" == "124" && -s "$tree_pid_file" ]] \
    || { printf 'descendant watchdog fixture did not time out deterministically\n' >&2; return 1; }
  [[ -z "$timeout_output" ]] \
    || { printf 'descendant watchdog fixture emitted unexpected output\n' >&2; return 1; }
  ((SECONDS - timeout_started <= 5)) \
    || { printf 'descendant watchdog held command-substitution stdout open\n' >&2; return 1; }
  read -r session_fixture_direct_pid session_fixture_grandchild_pid <"$tree_pid_file"
  if kill -0 "$session_fixture_direct_pid" 2>/dev/null \
    || kill -0 "$session_fixture_grandchild_pid" 2>/dev/null; then
    printf 'descendant survived process watchdog\n' >&2
    return 1
  fi
  session_fixture_direct_pid=""
  session_fixture_grandchild_pid=""

  ruby -e 'Signal.trap("TERM") { exit 0 }; loop { sleep 3600 }' >/dev/null 2>&1 &
  session_fixture_unrelated_pid=$!
  local descendant_fixture_count="${GAMEBOX_E2E_DESCENDANT_FIXTURE_COUNT:-3}"
  [[ "$descendant_fixture_count" =~ ^[1-9][0-9]*$ && "$descendant_fixture_count" -le 50 ]] \
    || { printf 'descendant watchdog count fixture is invalid\n' >&2; return 1; }
  local descendant_index
  for ((descendant_index = 1; descendant_index <= descendant_fixture_count; descendant_index++)); do
    tree_pid_file="$fixture_dir/session-tree-$descendant_index.pid"
    export GAMEBOX_E2E_TREE_PID_FILE="$tree_pid_file"
    if ((descendant_index % 2 == 0)); then
      export GAMEBOX_E2E_TREE_MODE=ignore-term
    else
      export GAMEBOX_E2E_TREE_MODE=normal
    fi
    timeout_status=0
    if timeout_output="$(run_with_timeout 1 "$session_tree" 2>/dev/null)"; then
      printf 'high-count descendant watchdog unexpectedly succeeded\n' >&2
      return 1
    else
      timeout_status=$?
    fi
    [[ "$timeout_status" == "124" && -s "$tree_pid_file" ]] \
      || { printf 'high-count descendant watchdog was not deterministic\n' >&2; return 1; }
    read -r session_fixture_direct_pid session_fixture_grandchild_pid <"$tree_pid_file"
    if kill -0 "$session_fixture_direct_pid" 2>/dev/null \
      || kill -0 "$session_fixture_grandchild_pid" 2>/dev/null; then
      printf 'high-count descendant survived process watchdog\n' >&2
      return 1
    fi
    session_fixture_direct_pid=""
    session_fixture_grandchild_pid=""
  done
  kill -0 "$session_fixture_unrelated_pid" 2>/dev/null \
    || { printf 'watchdog killed an unrelated process\n' >&2; return 1; }

  tree_pid_file="$fixture_dir/session-tree-exit-cleanup.pid"
  export GAMEBOX_E2E_TREE_PID_FILE="$tree_pid_file"
  export GAMEBOX_E2E_TREE_MODE=ignore-term
  run_with_timeout 30 "$session_tree" >/dev/null 2>&1 &
  session_fixture_wrapper_pid=$!
  local fixture_ready=0 fixture_wait_index
  for fixture_wait_index in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -s "$tree_pid_file" ]]; then
      fixture_ready=1
      break
    fi
    sleep 0.05
  done
  ((fixture_ready == 1)) \
    || { printf 'EXIT cleanup descendant fixture did not start\n' >&2; return 1; }
  read -r session_fixture_direct_pid session_fixture_grandchild_pid <"$tree_pid_file"
  timeout_started=$SECONDS
  kill -TERM "$session_fixture_wrapper_pid"
  wait "$session_fixture_wrapper_pid" 2>/dev/null || true
  session_fixture_wrapper_pid=""
  terminate_registered_bounded_children
  for ((fixture_wait_index = 1; fixture_wait_index <= 50; fixture_wait_index++)); do
    if ! kill -0 "$session_fixture_direct_pid" 2>/dev/null \
      && ! kill -0 "$session_fixture_grandchild_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  ((SECONDS - timeout_started <= 5)) \
    || { printf 'EXIT cleanup exceeded its bounded grace\n' >&2; return 1; }
  if kill -0 "$session_fixture_direct_pid" 2>/dev/null \
    || kill -0 "$session_fixture_grandchild_pid" 2>/dev/null; then
    printf 'EXIT cleanup left a session descendant alive\n' >&2
    return 1
  fi
  session_fixture_direct_pid=""
  session_fixture_grandchild_pid=""

  terminate_exact_child "$session_fixture_unrelated_pid" 1
  wait "$session_fixture_unrelated_pid" 2>/dev/null || true
  session_fixture_unrelated_pid=""
  unset GAMEBOX_E2E_TREE_PID_FILE GAMEBOX_E2E_TREE_MODE

  local captured_devices=""
  export FAKE_ADB_MODE=devices-fail
  if managed_avd_start_preflight "$MANAGED_AVD_B"; then
    printf 'nonzero adb devices fixture allowed an AVD start\n' >&2
    return 1
  fi
  export FAKE_ADB_MODE=devices-hang
  timeout_started=$SECONDS
  if managed_avd_start_preflight "$MANAGED_AVD_B"; then
    printf 'blocking adb devices fixture allowed an AVD start\n' >&2
    return 1
  fi
  ((SECONDS - timeout_started <= 5)) \
    || { printf 'adb devices watchdog exceeded its injected bound\n' >&2; return 1; }
  if [[ -s "$fake_pid_file" ]] && kill -0 "$(<"$fake_pid_file")" 2>/dev/null; then
    printf 'blocking adb devices process survived watchdog\n' >&2
    return 1
  fi
  unset FAKE_ADB_MODE
  capture_adb_devices captured_devices \
    || { printf 'normal adb devices fixture was rejected\n' >&2; return 1; }
  [[ "$(find_managed_avd_serial "$MANAGED_AVD_A" "$captured_devices")" == "emulator-5560" ]] \
    || { printf 'owned AVD serial fixture was not recognized\n' >&2; return 1; }
  if managed_avd_start_preflight "$MANAGED_AVD_A"; then
    printf 'already-running owned AVD fixture allowed a second start\n' >&2
    return 1
  fi
  managed_avd_start_preflight "$MANAGED_AVD_B" \
    || { printf 'absent managed AVD fixture was not startable\n' >&2; return 1; }

  SERIAL_A="fixture-A"
  SERIAL_B="fixture-B"
  RUN_ID="fixture-run"
  LOG_BOUNDARY_A="old-A"
  LOG_BOUNDARY_B="old-B"
  refresh_game_log_boundaries revision-8 \
    || { printf 'dual-device log boundary fixture failed\n' >&2; return 1; }
  [[ "$LOG_BOUNDARY_A" == "GAMEBOX_E2E_A_revision-8_fixture-run" \
    && "$LOG_BOUNDARY_B" == "GAMEBOX_E2E_B_revision-8_fixture-run" ]] \
    || { printf 'dual-device log boundary fixture was not committed atomically\n' >&2; return 1; }
  LOG_BOUNDARY_A="old-A"
  LOG_BOUNDARY_B="old-B"
  export FAKE_ADB_MODE=log-b-fail
  if refresh_game_log_boundaries revision-9; then
    printf 'partial dual-device log boundary fixture was accepted\n' >&2
    return 1
  fi
  unset FAKE_ADB_MODE
  [[ "$LOG_BOUNDARY_A" == "old-A" && "$LOG_BOUNDARY_B" == "old-B" ]] \
    || { printf 'failed dual-device log boundary was partially committed\n' >&2; return 1; }

  local private_secret='FixtureInvite_1234567890'
  local private_secret_base64
  private_secret_base64="$(printf '%s' "$private_secret" | openssl base64 -A)"
  local private_name='gamebox-e2e-input-fixture-normal-0001'
  printf '%s' "$private_secret" | stage_private_input fixture-serial "$private_name" \
    || { printf 'private input staging fixture failed\n' >&2; return 1; }
  [[ "$(stat -f '%Lp' "$fake_device_root/$private_name")" == "600" \
    && "$(<"$fake_device_root/$private_name")" == "$private_secret" ]] \
    || { printf 'private input permissions fixture failed\n' >&2; return 1; }
  set_text_from_private_input fixture-serial invite-code "$private_name" \
    || { printf 'private input consumption fixture failed\n' >&2; return 1; }
  [[ ! -e "$fake_device_root/$private_name" ]] \
    || { printf 'consumed private input fixture remained\n' >&2; return 1; }
  fixed_value_absent "$fake_log" "$private_secret" \
    || { printf 'raw private input appeared in adb argv fixture\n' >&2; return 1; }
  fixed_value_absent "$fake_log" "$private_secret_base64" \
    || { printf 'base64 private input appeared in adb argv fixture\n' >&2; return 1; }

  local hanging_name='gamebox-e2e-input-fixture-hanging-0002'
  printf '%s' "$private_secret" | stage_private_input fixture-serial "$hanging_name" \
    || { printf 'hanging private input staging fixture failed\n' >&2; return 1; }
  export FAKE_ADB_MODE=hang-instrument
  local timeout_start=$SECONDS
  if set_text_from_private_input fixture-serial invite-code "$hanging_name"; then
    printf 'permanently blocking fake adb was accepted\n' >&2
    return 1
  fi
  unset FAKE_ADB_MODE
  ((SECONDS - timeout_start <= 5)) \
    || { printf 'fake adb watchdog exceeded its injected bound\n' >&2; return 1; }
  [[ ! -e "$fake_device_root/$hanging_name" ]] \
    || { printf 'killed helper private input was not externally removed\n' >&2; return 1; }
  grep -F 'private-input-cleanup=gamebox-e2e-input-fixture-hanging-0002' "$fake_log" >/dev/null \
    || { printf 'killed helper cleanup invocation fixture failed\n' >&2; return 1; }
  grep -F 'clipboard-clear' "$fake_log" >/dev/null \
    || { printf 'killed helper clipboard recovery fixture failed\n' >&2; return 1; }
  if [[ -s "$fake_pid_file" ]] && kill -0 "$(<"$fake_pid_file")" 2>/dev/null; then
    printf 'fake adb process survived watchdog\n' >&2
    return 1
  fi

  local remote_fixture='/data/local/tmp/gamebox-e2e-fixture-pull-failure.xml'
  export FAKE_ADB_MODE=pull-fail
  if dump_ui_remote fixture-serial "$fixture_dir/pull-failure.xml" "$remote_fixture"; then
    printf 'fake adb pull failure was accepted\n' >&2
    return 1
  fi
  unset FAKE_ADB_MODE
  [[ ! -e "$fake_device_root/remote-ui.xml" ]] \
    || { printf 'remote UI XML survived pull failure cleanup\n' >&2; return 1; }
  grep -F 'remote-cleanup' "$fake_log" >/dev/null \
    || { printf 'remote UI XML cleanup invocation fixture failed\n' >&2; return 1; }

  local helper_source="$ROOT_DIR/app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/E2eSetTextTest.kt"
  if rg -n 'Base64|gameboxTextValueBase64' "$helper_source" >/dev/null; then
    printf 'Android helper still accepts reversible secret argv\n' >&2
    return 1
  fi

  local runtime_source
  runtime_source="$(sed -n '/^for required_command in /,$p' "${BASH_SOURCE[0]}")"
  grep -F 'failure_media_safe' <<<"$runtime_source" >/dev/null \
    || { printf 'failure screenshot safety gate is missing\n' >&2; return 1; }
  grep -F 'failure-artifact-scan.txt' <<<"$runtime_source" >/dev/null \
    || { printf 'failure artifact scanner is missing\n' >&2; return 1; }
  if grep -E 'screencap.*ARTIFACT_DIR' <<<"$runtime_source" >/dev/null; then
    printf 'raw failure screenshot is written directly to artifacts\n' >&2
    return 1
  fi
  grep -F "flutter test -d \"\$SERIAL_A\" integration_test/semantics_test.dart" <<<"$runtime_source" >/dev/null \
    || { printf 'selected-device semantics command is missing\n' >&2; return 1; }
  if grep -F 'SECONDS + 10' <<<"$runtime_source" >/dev/null; then
    printf 'render revision wait still uses a hard-coded 10 second deadline\n' >&2
    return 1
  fi
  if grep -F 'gameboxTextValueBase64' <<<"$runtime_source" >/dev/null; then
    printf 'secret text still crosses an instrumentation argv as base64\n' >&2
    return 1
  fi
  grep -F 'run_with_timeout' <<<"$runtime_source" >/dev/null \
    || { printf 'process-level command watchdog is missing\n' >&2; return 1; }
  grep -F 'refresh_game_log_boundaries' <<<"$runtime_source" >/dev/null \
    || { printf 'per-revision dual-device log boundary is missing\n' >&2; return 1; }
  if grep -F 'done < <(run_with_timeout' <<<"$runtime_source" >/dev/null; then
    printf 'adb devices status is still swallowed by process substitution\n' >&2
    return 1
  fi
  grep -F 'cleanup_remote_ui_dump' <<<"$runtime_source" >/dev/null \
    || { printf 'remote UI dump cleanup contract is missing\n' >&2; return 1; }
  grep -F 'apkSha256' <<<"$runtime_source" >/dev/null \
    || { printf 'APK build provenance is missing\n' >&2; return 1; }
  grep -F 'uninstall "$installed_package"' <<<"$runtime_source" >/dev/null \
    || { printf 'preinstall package cleanup is missing\n' >&2; return 1; }
  printf 'Gamebox E2E parser fixtures passed.\n'
}

if ((SELF_TEST_ONLY)); then
  self_test
  exit 0
fi

for required_command in curl ffmpeg git go jq lsof openssl rg ruby sed shasum unzip; do
  command -v "$required_command" >/dev/null 2>&1 \
    || { printf 'Gamebox E2E failed: missing required command %s\n' "$required_command" >&2; exit 2; }
done
command -v "$ADB_BIN" >/dev/null 2>&1 \
  || { printf 'Gamebox E2E failed: configured adb is not available\n' >&2; exit 2; }
command -v flutter >/dev/null 2>&1 \
  || { printf 'Gamebox E2E failed: flutter is not available on PATH\n' >&2; exit 2; }
for timeout_value in \
  "$ADB_TIMEOUT_SECONDS" "$INPUT_TIMEOUT_SECONDS" "$BUILD_TIMEOUT_SECONDS" \
  "$SEMANTICS_TIMEOUT_SECONDS" "$AVD_SETUP_TIMEOUT_SECONDS" "$TIMEOUT_KILL_GRACE_SECONDS"; do
  if [[ ! "$timeout_value" =~ ^[0-9]+$ ]] || ((timeout_value <= 0)); then
    printf 'Gamebox E2E failed: every watchdog timeout must be a positive integer\n' >&2
    exit 2
  fi
done

SOURCE_REVISION_START="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_STATUS_START="$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=normal)"
if ! provenance_contract "$SOURCE_REVISION_START" "$SOURCE_STATUS_START" "$SOURCE_REVISION_START" ""; then
  printf 'Gamebox E2E failed: build provenance requires a clean worktree at start\n' >&2
  exit 2
fi
readonly SOURCE_REVISION_START SOURCE_STATUS_START

umask 077
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly RUN_ID
TEMP_DIR="$(mktemp -d)"
readonly TEMP_DIR
BOUND_CHILD_REGISTRY="$TEMP_DIR/bounded-children"
BOUND_SESSION_STATE_DIR="$TEMP_DIR/bounded-sessions"
mkdir "$BOUND_CHILD_REGISTRY" "$BOUND_SESSION_STATE_DIR"
readonly BOUND_CHILD_REGISTRY
readonly BOUND_SESSION_STATE_DIR
ARTIFACT_DIR="$ROOT_DIR/artifacts/e2e/$RUN_ID"
mkdir -p "$ARTIFACT_DIR"
readonly ARTIFACT_DIR
DB_PATH="$TEMP_DIR/gamebox.sqlite"
SERVER_LOG="$TEMP_DIR/server.log"
SERVER_BIN="$TEMP_DIR/gameboxd"
CTL_BIN="$TEMP_DIR/gameboxctl"
readonly DB_PATH SERVER_LOG SERVER_BIN CTL_BIN

SERVER_PID=""
EMULATOR_PID_A=""
EMULATOR_PID_B=""
SERIAL_A=""
SERIAL_B=""
STARTED_A=0
STARTED_B=0
SECRETS_ON_UI_A=0
SECRETS_ON_UI_B=0
FAILURE_CAPTURED=0
JWT_SECRET=""
TOKEN_PEPPER=""
INVITE_A=""
INVITE_B=""
LOG_BOUNDARY_A=""
LOG_BOUNDARY_B=""
MATCH_ID=""
SECOND_MATCH_ID=""
RECOVERY_SERIAL=""
PREVIOUS_BOARD_HASH=""
VISUAL_METRICS="$TEMP_DIR/visual-metrics.tsv"
REMOTE_UI_PATH="/data/local/tmp/gamebox-e2e-$RUN_ID.xml"
SECRET_INPUT_COUNTER=0
SECRET_INPUT_FILES_A=()
SECRET_INPUT_FILES_B=()
readonly REMOTE_UI_PATH
WORKTREE_ANDROID_RUNTIME_DIR="${GAMEBOX_WORKTREE_ANDROID_RUNTIME_DIR:-}"
if [[ -n "$WORKTREE_ANDROID_RUNTIME_DIR" \
  && "$WORKTREE_ANDROID_RUNTIME_DIR" != "$ROOT_DIR/.gamebox-worktree/android-runtime" ]]; then
  printf 'Gamebox E2E failed: worktree Android runtime path is outside the approved local state directory\n' >&2
  exit 2
fi
readonly WORKTREE_ANDROID_RUNTIME_DIR

write_android_runtime_value() {
  local name="$1"
  local value="$2"
  local staged
  [[ -n "$WORKTREE_ANDROID_RUNTIME_DIR" ]] || return 0
  mkdir -p "$WORKTREE_ANDROID_RUNTIME_DIR"
  chmod 700 "$WORKTREE_ANDROID_RUNTIME_DIR"
  staged="$(mktemp "$WORKTREE_ANDROID_RUNTIME_DIR/.runtime.XXXXXX")"
  printf '%s\n' "$value" >"$staged"
  chmod 600 "$staged"
  mv "$staged" "$WORKTREE_ANDROID_RUNTIME_DIR/$name"
}

record_android_runtime() {
  [[ -n "$WORKTREE_ANDROID_RUNTIME_DIR" ]] || return 0
  write_android_runtime_value token "$GAMEBOX_ANDROID_LEASE_TOKEN"
  write_android_runtime_value started-a "$STARTED_A"
  write_android_runtime_value started-b "$STARTED_B"
  write_android_runtime_value pid-a "$EMULATOR_PID_A"
  write_android_runtime_value pid-b "$EMULATOR_PID_B"
  write_android_runtime_value avd-a "$MANAGED_AVD_A"
  write_android_runtime_value avd-b "$MANAGED_AVD_B"
  write_android_runtime_value serial-a "$SERIAL_A"
  write_android_runtime_value serial-b "$SERIAL_B"
}

clear_android_runtime() {
  local name
  [[ -n "$WORKTREE_ANDROID_RUNTIME_DIR" && -d "$WORKTREE_ANDROID_RUNTIME_DIR" ]] || return 0
  for name in token started-a started-b pid-a pid-b avd-a avd-b serial-a serial-b; do
    [[ -e "$WORKTREE_ANDROID_RUNTIME_DIR/$name" ]] && rm -f "$WORKTREE_ANDROID_RUNTIME_DIR/$name"
  done
  find "$WORKTREE_ANDROID_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type f -name '.runtime.*' -delete
  rmdir "$WORKTREE_ANDROID_RUNTIME_DIR" 2>/dev/null || true
}

owned_process_matches() {
  local pid="$1"
  local needle="$2"
  [[ -n "$pid" ]] || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -F -- "$needle" >/dev/null
}

stop_owned_process() {
  local pid="$1"
  local needle="$2"
  local grace="$3"
  [[ -n "$pid" ]] || return 0
  owned_process_matches "$pid" "$needle" || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  local deadline=$((SECONDS + grace))
  while ((SECONDS < deadline)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  owned_process_matches "$pid" "$needle" && kill -KILL "$pid" 2>/dev/null || true
}

bounded_helper_uninstall() {
  local serial="$1"
  adb_for_timeout "$INPUT_TIMEOUT_SECONDS" "$serial" uninstall "$TEST_PACKAGE" >/dev/null 2>&1 || true
}

helper_package_installed() {
  local serial="$1"
  adb_for "$serial" shell pm path "$TEST_PACKAGE" 2>/dev/null | grep -q '^package:'
}

cleanup_serial_private_state() {
  local serial="$1"
  local label="$2"
  [[ -n "$serial" ]] || return 0
  cleanup_remote_ui_dump "$serial" "$REMOTE_UI_PATH" || true
  local input_name
  if [[ "$label" == "A" ]]; then
    for input_name in "${SECRET_INPUT_FILES_A[@]-}"; do
      [[ -n "$input_name" ]] || continue
      remove_private_input "$serial" "$input_name" || true
    done
  else
    for input_name in "${SECRET_INPUT_FILES_B[@]-}"; do
      [[ -n "$input_name" ]] || continue
      remove_private_input "$serial" "$input_name" || true
    done
  fi
  if helper_package_installed "$serial"; then
    clear_helper_clipboard "$serial" || true
  fi
}

cleanup() {
  local exit_code=$?
  local cleanup_ok=1
  trap - EXIT INT TERM ERR
  set +e
  terminate_registered_bounded_children
  if [[ -n "$SERIAL_A" ]]; then
    cleanup_serial_private_state "$SERIAL_A" A
    bounded_helper_uninstall "$SERIAL_A"
  fi
  if [[ -n "$SERIAL_B" ]]; then
    cleanup_serial_private_state "$SERIAL_B" B
    bounded_helper_uninstall "$SERIAL_B"
  fi
  stop_owned_process "$SERVER_PID" "$SERVER_BIN" 10
  ((STARTED_B)) && stop_owned_process "$EMULATOR_PID_B" "-avd $MANAGED_AVD_B" 20
  ((STARTED_A)) && stop_owned_process "$EMULATOR_PID_A" "-avd $MANAGED_AVD_A" 20
  if ((STARTED_B)) && owned_process_matches "$EMULATOR_PID_B" "-avd $MANAGED_AVD_B"; then
    cleanup_ok=0
  fi
  if ((STARTED_A)) && owned_process_matches "$EMULATOR_PID_A" "-avd $MANAGED_AVD_A"; then
    cleanup_ok=0
  fi
  if ((cleanup_ok)) && ((GAMEBOX_ANDROID_LEASE_OWNED == 1 || GAMEBOX_ANDROID_LEASE_INHERITED == 1)); then
    clear_android_runtime
    gamebox_android_lease_release || cleanup_ok=0
  fi
  if ((cleanup_ok == 0)); then
    printf 'Gamebox E2E cleanup was incomplete; owned runtime and lease metadata were preserved for tool/worktree.sh down.\n' >&2
  fi
  rm -rf "$TEMP_DIR"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

clear_secret_field_for_failure() {
  local serial="$1"
  local enabled="$2"
  local secret="$3"
  ((enabled)) || return 0
  [[ -n "$secret" ]] || return 1
  local xml="$TEMP_DIR/failure-clear-${serial//[^A-Za-z0-9_.-]/_}.xml"
  local verification_xml="$TEMP_DIR/failure-clear-verified-${serial//[^A-Za-z0-9_.-]/_}.xml"
  declare -F dump_ui >/dev/null 2>&1 || return 1
  local center
  dump_ui "$serial" "$xml" || return 1
  center="$(xml_query bounds "$xml" invite-code 2>/dev/null)" || return 1
  local x y
  read -r x y <<<"$center"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null 2>&1 || return 1
  adb_for "$serial" shell input keyevent KEYCODE_MOVE_END >/dev/null 2>&1 || return 1
  local index
  for ((index = 0; index < 96; index++)); do
    adb_for "$serial" shell input keyevent KEYCODE_DEL >/dev/null 2>&1 || return 1
  done

  local _
  for _ in 1 2 3; do
    if dump_ui "$serial" "$verification_xml" \
      && xml_query field-empty "$verification_xml" invite-code >/dev/null 2>&1 \
      && fixed_value_absent "$verification_xml" "$secret"; then
      sleep 1
      dump_ui "$serial" "$verification_xml" || return 1
      xml_query field-empty "$verification_xml" invite-code >/dev/null 2>&1 || return 1
      fixed_value_absent "$verification_xml" "$secret" || return 1
      return 0
    fi
    sleep 1
  done
  return 1
}

capture_failure() {
  local message="$1"
  ((FAILURE_CAPTURED)) && return 0
  FAILURE_CAPTURED=1
  local serial label xml secret_active secret clear_verified screenshot
  for label in A B; do
    if [[ "$label" == "A" ]]; then
      serial="$SERIAL_A"
      secret_active="$SECRETS_ON_UI_A"
      secret="$INVITE_A"
    else
      serial="$SERIAL_B"
      secret_active="$SECRETS_ON_UI_B"
      secret="$INVITE_B"
    fi
    [[ -n "$serial" ]] || continue
    clear_verified=0
    if clear_secret_field_for_failure "$serial" "$secret_active" "$secret"; then
      clear_verified=1
    fi
    if failure_media_safe "$secret_active" "$clear_verified"; then
      screenshot="$TEMP_DIR/failure-$label.png"
      rm -f -- "$screenshot"
      if adb_for "$serial" exec-out screencap -p >"$screenshot" 2>/dev/null && [[ -s "$screenshot" ]]; then
        cp "$screenshot" "$ARTIFACT_DIR/failure-$label.png" 2>/dev/null || true
      fi
      rm -f -- "$screenshot"
      xml="$TEMP_DIR/failure-$label.xml"
      if declare -F dump_ui >/dev/null 2>&1 && dump_ui "$serial" "$xml"; then
        xml_query diagnostics "$xml" 2>/dev/null | sanitize_stream >"$ARTIFACT_DIR/failure-$label-ui.txt" || true
      fi
    else
      printf 'Failure screenshot and UI dump omitted because secret-field clearing could not be verified.\n' \
        >"$ARTIFACT_DIR/failure-$label-media-omitted.txt" || true
    fi
    if declare -F game_logs_after_boundary >/dev/null 2>&1 && declare -F boundary_for_serial >/dev/null 2>&1; then
      game_logs_after_boundary "$serial" "$(boundary_for_serial "$serial")" \
        | sanitize_stream >"$ARTIFACT_DIR/failure-$label-logcat.txt" || true
    fi
  done
  if [[ -n "$MATCH_ID" && -n "$SERVER_PID" ]] \
    && declare -F match_show >/dev/null 2>&1 \
    && owned_process_matches "$SERVER_PID" "$SERVER_BIN"; then
    stop_owned_process "$SERVER_PID" "$SERVER_BIN" 10
    SERVER_PID=""
    local after_stop_snapshot
    after_stop_snapshot="$(match_show "$MATCH_ID" 2>/dev/null || true)"
    if [[ "$(jq -r '.id // ""' <<<"$after_stop_snapshot" 2>/dev/null)" == "$MATCH_ID" ]]; then
      printf '%s\n' "$after_stop_snapshot" | jq -S . \
        | sanitize_stream >"$ARTIFACT_DIR/failure-match-after-server-stop.json" || true
    fi
  fi
  [[ -f "$SERVER_LOG" ]] && sanitize_stream <"$SERVER_LOG" >"$ARTIFACT_DIR/server-sanitized.log" || true
  jq -n --arg status failure --arg message "$message" --arg serialA "$SERIAL_A" --arg serialB "$SERIAL_B" \
    '{status:$status,message:$message,serials:[$serialA,$serialB]}' >"$ARTIFACT_DIR/summary.json" || true
  if ! protect_artifact_directory \
    "$ARTIFACT_DIR" "$TEMP_DIR/failure-artifact-scan.txt" \
    "$INVITE_A" "$INVITE_B" "$JWT_SECRET" "$TOKEN_PEPPER"; then
    printf 'Unsafe or unverifiable failure artifacts were removed.\n' \
      >"$ARTIFACT_DIR/artifact-safety.txt" || true
  fi
}

fail() {
  local message="$1"
  printf 'Gamebox E2E failed: %s\nArtifacts: %s\n' "$message" "$ARTIFACT_DIR" >&2
  capture_failure "$message"
  exit 1
}

unexpected_error() {
  local exit_code="$1"
  local line="$2"
  trap - ERR
  fail "unexpected harness command failure at line $line (exit $exit_code)"
}
trap 'unexpected_error "$?" "$LINENO"' ERR

gamebox_android_lease_acquire \
  "$ROOT_DIR" "$MANAGED_AVD_A,$MANAGED_AVD_B" "${GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS:-900}" \
  || fail "could not acquire the shared Android lease"
record_android_runtime

validate_serial_text() {
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

port_is_free() {
  ! lsof -nP -iTCP:"$1" 2>/dev/null | grep -q .
}

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
emulator_bin="$sdk_root/emulator/emulator"
[[ -x "$emulator_bin" ]] || emulator_bin="$sdk_root/tools/emulator"
readonly sdk_root emulator_bin

wait_for_boot() {
  local serial="$1"
  local _
  for _ in 1 2 3; do
    local deadline=$((SECONDS + WAIT_SECONDS))
    while ((SECONDS < deadline)); do
      local state boot
      state="$(adb_for "$serial" get-state 2>/dev/null || true)"
      boot="$(adb_for "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
      if [[ "$state" == "device" && "$boot" == "1" ]] \
        && adb_for "$serial" shell cmd package list packages >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
  done
  return 1
}

assert_managed_avd_not_running() {
  local avd_name="$1"
  local devices_listing existing_serial status
  capture_adb_devices devices_listing \
    || fail "adb devices failed or exceeded its ${ADB_TIMEOUT_SECONDS}s bound; refusing to start $avd_name"
  if existing_serial="$(find_managed_avd_serial "$avd_name" "$devices_listing")"; then
    fail "$avd_name is already running as $existing_serial; refusing to reuse or stop it"
  else
    status=$?
    [[ "$status" == "1" ]] \
      || fail "managed AVD inspection failed; refusing to start $avd_name"
  fi
}

start_managed_emulator() {
  local label="$1"
  local avd_name="$2"
  local port="$3"
  local pid_var="$4"
  local serial_var="$5"
  port_is_free "$port" || fail "managed emulator port $port is occupied; no process was stopped"
  assert_managed_avd_not_running "$avd_name"
  local log="$TEMP_DIR/emulator-$label.log"
  "$emulator_bin" -avd "$avd_name" -port "$port" \
    -no-snapshot-save -no-boot-anim -no-window -no-audio \
    -camera-back none -camera-front none >"$log" 2>&1 &
  local pid=$!
  local serial="emulator-$port"
  printf -v "$pid_var" '%s' "$pid"
  printf -v "$serial_var" '%s' "$serial"
  record_android_runtime
  wait_for_boot "$serial" || fail "$avd_name did not become healthy within three bounded boot phases"
  owned_process_matches "$pid" "-avd $avd_name" || fail "$avd_name process exited during boot"
}

provided_a="${GAMEBOX_E2E_SERIAL_A:-}"
provided_b="${GAMEBOX_E2E_SERIAL_B:-}"
if [[ -n "$provided_a" || -n "$provided_b" ]]; then
  [[ -n "$provided_a" && -n "$provided_b" ]] || fail "provide both GAMEBOX_E2E_SERIAL_A and GAMEBOX_E2E_SERIAL_B"
  if ! validate_serial_text "$provided_a" || ! validate_serial_text "$provided_b"; then
    fail "a provided Android serial contains unsupported characters"
  fi
  [[ "$provided_a" != "$provided_b" ]] || fail "the two provided serials must be different"
  SERIAL_A="$provided_a"
  SERIAL_B="$provided_b"
else
  run_with_timeout "$AVD_SETUP_TIMEOUT_SECONDS" bash "$ROOT_DIR/tool/ensure_test_avds.sh" \
    || fail "managed AVD validation exceeded its ${AVD_SETUP_TIMEOUT_SECONDS}s bound or failed"
  STARTED_A=1
  start_managed_emulator A "$MANAGED_AVD_A" "$MANAGED_PORT_A" EMULATOR_PID_A SERIAL_A
  STARTED_B=1
  start_managed_emulator B "$MANAGED_AVD_B" "$MANAGED_PORT_B" EMULATOR_PID_B SERIAL_B
fi
record_android_runtime
readonly SERIAL_A SERIAL_B

validate_device() {
  local serial="$1"
  local api_variable="$2"
  [[ "$(adb_for "$serial" get-state 2>/dev/null || true)" == "device" ]] \
    || fail "$serial is not a ready Android device"
  local api abi
  api="$(adb_for "$serial" shell getprop ro.build.version.sdk | tr -d '\r')"
  abi="$(adb_for "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')"
  [[ "$api" == "36" ]] || fail "$serial runs API $api, expected API 36"
  [[ "$abi" == "arm64-v8a" ]] || fail "$serial ABI is $abi, expected arm64-v8a"
  adb_for "$serial" shell wm size | grep -Eq '[0-9]+x[0-9]+' \
    || fail "$serial did not report a usable display size"
  printf -v "$api_variable" '%s' "$api"
}
API_LEVEL_A=""
API_LEVEL_B=""
validate_device "$SERIAL_A" API_LEVEL_A
validate_device "$SERIAL_B" API_LEVEL_B
readonly API_LEVEL_A API_LEVEL_B

SEMANTICS_LOG="$TEMP_DIR/semantics-test.log"
readonly SEMANTICS_LOG
printf 'Running semantics integration test on selected device %s...\n' "$SERIAL_A"
if ! (
  cd "$ROOT_DIR/app"
  run_with_timeout "$SEMANTICS_TIMEOUT_SECONDS" \
    flutter test -d "$SERIAL_A" integration_test/semantics_test.dart
) >"$SEMANTICS_LOG" 2>&1; then
  sanitize_stream <"$SEMANTICS_LOG" >"$ARTIFACT_DIR/semantics-test.log" || true
  fail "selected-device semantics integration test failed on $SERIAL_A"
fi

server_port="${GAMEBOX_E2E_API_PORT:-$((18080 + ($$ % 1000)))}"
[[ "$server_port" =~ ^[0-9]+$ ]] \
  || fail "GAMEBOX_E2E_API_PORT must be an integer from 1024 to 65535"
server_port_number=$((10#$server_port))
((server_port_number >= 1024 && server_port_number <= 65535)) \
  || fail "GAMEBOX_E2E_API_PORT must be an integer from 1024 to 65535"
port_is_free "$server_port" || fail "server port $server_port is occupied; no process was stopped"
readonly server_port
api_base="http://10.0.2.2:$server_port"
host_base="http://127.0.0.1:$server_port"
readonly api_base host_base

printf 'Building single-ABI debug APK and server tools...\n'
# Build the repository-owned UI Automator helper first. Gradle also assembles a
# default app APK for androidTest; the Flutter build below must run last so the
# installed app retains this run's isolated API base URL.
(
  cd "$ROOT_DIR/app/android"
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" env \
    ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a \
    ./gradlew :app:assembleDebugAndroidTest
)
TEST_APK="$ROOT_DIR/app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
readonly TEST_APK
[[ -f "$TEST_APK" ]] || fail "E2E-owned UI Automator helper APK was not produced"
(
  cd "$ROOT_DIR/app"
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" env \
    ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a \
    flutter build apk \
      --debug --target-platform=android-arm64 \
      --dart-define="GAMEBOX_API_BASE_URL=$api_base"
)
APK="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-debug.apk"
readonly APK
[[ -f "$APK" ]] || fail "debug APK was not produced"
packaged_abis="$(unzip -Z1 "$APK" | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u | paste -sd ' ' -)"
[[ "$packaged_abis" == "arm64-v8a" ]] || fail "APK ABI set is '${packaged_abis:-empty}', expected arm64-v8a only"
for required_asset in assets/games/gomoku/gomoku_scene.tscn assets/games/gomoku/gomoku_board.gd; do
  unzip -Z1 "$APK" | grep -Fx "$required_asset" >/dev/null || fail "APK is missing $required_asset"
done
APK_SHA256="$(shasum -a 256 "$APK" | awk '{print $1}')"
TEST_APK_SHA256="$(shasum -a 256 "$TEST_APK" | awk '{print $1}')"
[[ "$APK_SHA256" =~ ^[0-9a-f]{64}$ && "$TEST_APK_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "built APK SHA-256 provenance was invalid"
readonly APK_SHA256 TEST_APK_SHA256
(
  cd "$ROOT_DIR/server"
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" go build -o "$SERVER_BIN" ./cmd/gameboxd
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" go build -o "$CTL_BIN" ./cmd/gameboxctl
)

install_app() {
  local serial="$1"
  local installed_package
  for installed_package in "$TEST_PACKAGE" "$PACKAGE"; do
    if adb_for "$serial" shell pm path "$installed_package" 2>/dev/null | grep -q '^package:'; then
      adb_for "$serial" uninstall "$installed_package" >/dev/null \
        || fail "could not remove the previous $installed_package installation on $serial"
    fi
  done
  adb_for "$serial" install --streaming "$APK" >/dev/null \
    || fail "APK installation failed on $serial"
  adb_for "$serial" install --streaming -t "$TEST_APK" >/dev/null \
    || fail "E2E-owned UI Automator helper installation failed on $serial"
  adb_for "$serial" shell pm clear "$PACKAGE" >/dev/null \
    || fail "could not clear only $PACKAGE on $serial after install"
}
install_app "$SERIAL_A"
install_app "$SERIAL_B"

installed_package_sha256() {
  local serial="$1"
  local package_name="$2"
  local paths remote
  paths="$(adb_for "$serial" shell pm path "$package_name" | tr -d '\r')" || return 1
  [[ "$(wc -l <<<"$paths" | tr -d ' ')" == "1" && "$paths" == package:* ]] || return 1
  remote="${paths#package:}"
  valid_installed_apk_path "$remote" || return 1
  adb_for "$serial" exec-out cat "$remote" \
    | shasum -a 256 \
    | awk '{print $1}'
}

INSTALLED_APK_SHA_A="$(installed_package_sha256 "$SERIAL_A" "$PACKAGE")" \
  || fail "could not hash the installed main APK on $SERIAL_A"
INSTALLED_APK_SHA_B="$(installed_package_sha256 "$SERIAL_B" "$PACKAGE")" \
  || fail "could not hash the installed main APK on $SERIAL_B"
INSTALLED_TEST_APK_SHA_A="$(installed_package_sha256 "$SERIAL_A" "$TEST_PACKAGE")" \
  || fail "could not hash the installed helper APK on $SERIAL_A"
INSTALLED_TEST_APK_SHA_B="$(installed_package_sha256 "$SERIAL_B" "$TEST_PACKAGE")" \
  || fail "could not hash the installed helper APK on $SERIAL_B"
[[ "$INSTALLED_APK_SHA_A" == "$APK_SHA256" && "$INSTALLED_APK_SHA_B" == "$APK_SHA256" ]] \
  || fail "installed main APK bytes did not match the built APK SHA-256"
[[ "$INSTALLED_TEST_APK_SHA_A" == "$TEST_APK_SHA256" \
  && "$INSTALLED_TEST_APK_SHA_B" == "$TEST_APK_SHA256" ]] \
  || fail "installed helper APK bytes did not match the built APK SHA-256"
readonly INSTALLED_APK_SHA_A INSTALLED_APK_SHA_B INSTALLED_TEST_APK_SHA_A INSTALLED_TEST_APK_SHA_B

LOG_BOUNDARY_A="GAMEBOX_E2E_A_$RUN_ID"
LOG_BOUNDARY_B="GAMEBOX_E2E_B_$RUN_ID"
adb_for "$SERIAL_A" shell log -p i -t GameboxE2E "$LOG_BOUNDARY_A" >/dev/null
adb_for "$SERIAL_B" shell log -p i -t GameboxE2E "$LOG_BOUNDARY_B" >/dev/null

boundary_for_serial() {
  [[ "$1" == "$SERIAL_A" ]] && printf '%s\n' "$LOG_BOUNDARY_A" || printf '%s\n' "$LOG_BOUNDARY_B"
}

logs_after_boundary() {
  local serial="$1"
  local boundary="$2"
  adb_for "$serial" logcat -b all -d -v threadtime 2>/dev/null | awk -v marker="$boundary" '
    index($0, marker) { found=1; next }
    found { print }
  '
}

game_logs_after_boundary() {
  logs_after_boundary "$1" "$2" \
    | grep -E '[[:space:]]I[[:space:]]+godot[[:space:]]+:' || true
}

dump_ui() {
  local serial="$1"
  local local_path="$2"
  dump_ui_remote "$serial" "$local_path" "$REMOTE_UI_PATH"
}

wait_for_identifier() {
  local serial="$1"
  local identifier="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))
  local xml="$TEMP_DIR/ui-${serial//[^A-Za-z0-9_.-]/_}.xml"
  while ((SECONDS < deadline)); do
    if dump_ui "$serial" "$xml"; then
      local center
      center="$(xml_query bounds "$xml" "$identifier" 2>/dev/null)" && {
        printf '%s\n' "$center"
        return 0
      }
    fi
    sleep 1
  done
  return 1
}

tap_identifier() {
  local serial="$1"
  local identifier="$2"
  local center x y
  center="$(wait_for_identifier "$serial" "$identifier")" \
    || fail "$identifier did not become uniquely enabled on $serial within ${WAIT_SECONDS}s"
  read -r x y <<<"$center"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null \
    || fail "could not tap resource-id $identifier on $serial"
}

wait_for_opponent_identifier() {
  local serial="$1"
  local deadline=$((SECONDS + WAIT_SECONDS))
  local xml="$TEMP_DIR/ui-opponent-${serial//[^A-Za-z0-9_.-]/_}.xml"
  while ((SECONDS < deadline)); do
    if dump_ui "$serial" "$xml"; then
      local identifier
      identifier="$(xml_query opponent "$xml" 2>/dev/null)" && {
        printf '%s\n' "$identifier"
        return 0
      }
    fi
    sleep 1
  done
  return 1
}

input_text_by_identifier() {
  local serial="$1"
  local identifier="$2"
  local value="$3"
  SECRET_INPUT_COUNTER=$((SECRET_INPUT_COUNTER + 1))
  local input_name
  input_name="gamebox-e2e-input-$RUN_ID-$(printf '%04d' "$SECRET_INPUT_COUNTER")"
  if [[ "$serial" == "$SERIAL_A" ]]; then
    SECRET_INPUT_FILES_A+=("$input_name")
  elif [[ "$serial" == "$SERIAL_B" ]]; then
    SECRET_INPUT_FILES_B+=("$input_name")
  else
    fail "private input target was not one of the selected devices"
  fi

  if ! printf '%s' "$value" | stage_private_input "$serial" "$input_name"; then
    remove_private_input "$serial" "$input_name" || true
    fail "could not stage a private UI input on $serial"
  fi
  if ! set_text_from_private_input "$serial" "$identifier" "$input_name"; then
    fail "UI Automator helper could not consume private input for resource-id $identifier on $serial"
  fi
}

assert_field_text() {
  local serial="$1"
  local identifier="$2"
  local expected="$3"
  local xml="$TEMP_DIR/field-${serial//[^A-Za-z0-9_.-]/_}-${identifier}.xml"
  dump_ui "$serial" "$xml" || fail "could not inspect resource-id $identifier after text entry on $serial"
  local actual
  actual="$(xml_query field-text "$xml" "$identifier" 2>/dev/null)" \
    || fail "resource-id $identifier did not expose exactly one entered value on $serial"
  [[ "$actual" == "$expected" ]] \
    || fail "resource-id $identifier input did not round-trip exactly on $serial"
}

start_flutter() {
  local serial="$1"
  adb_for "$serial" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null \
    || fail "could not start $MAIN_ACTIVITY on $serial"
}

wait_for_log_marker() {
  local serial="$1"
  local marker="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while ((SECONDS < deadline)); do
    if game_logs_after_boundary "$serial" "$(boundary_for_serial "$serial")" | grep -F "$marker" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_new_ready_match_id() {
  local serial="$1"
  local excluded_id="${2:-}"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while ((SECONDS < deadline)); do
    local candidates candidate_count
    candidates="$(
      game_logs_after_boundary "$serial" "$(boundary_for_serial "$serial")" \
        | sed -E -n 's/.*GAMEBOX_GODOT_READY game=gomoku match=([0-9a-f-]{36}).*/\1/p' \
        | awk -v excluded="$excluded_id" '$0 != excluded' \
        | sort -u
    )"
    candidate_count="$(printf '%s\n' "$candidates" | awk 'NF { count++ } END { print count + 0 }')"
    if [[ "$candidate_count" == "1" ]]; then
      printf '%s\n' "$candidates"
      return 0
    fi
    sleep 1
  done
  return 1
}

JWT_SECRET="$(openssl rand -hex 32)"
TOKEN_PEPPER="$(openssl rand -hex 32)"
GAMEBOX_ADDR="0.0.0.0:$server_port" \
GAMEBOX_DB_PATH="$DB_PATH" \
GAMEBOX_JWT_SECRET="$JWT_SECRET" \
GAMEBOX_TOKEN_PEPPER="$TOKEN_PEPPER" \
  "$SERVER_BIN" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

health_deadline=$((SECONDS + WAIT_SECONDS))
while ((SECONDS < health_deadline)); do
  if curl --fail --silent --max-time 2 "$host_base/healthz" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    break
  fi
  owned_process_matches "$SERVER_PID" "$SERVER_BIN" || fail "gameboxd exited before healthz became ready"
  sleep 1
done
curl --fail --silent --max-time 2 "$host_base/healthz" | jq -e '.status == "ok"' >/dev/null \
  || fail "healthz did not become ready within ${WAIT_SECONDS}s"

# Exercise the production order: the daemon remains the long-lived writer
# while the invite CLI opens, writes, and closes the same private WAL database.
invite_json="$(GAMEBOX_TOKEN_PEPPER="$TOKEN_PEPPER" "$CTL_BIN" invite create --count 2 --db "$DB_PATH" --json)" \
  || fail "invite creation failed"
[[ "$(jq -r '.invites | length' <<<"$invite_json")" == "2" ]] || fail "invite CLI did not return exactly two invites"
INVITE_A="$(jq -er '.invites[0] | select(type == "string" and length > 0)' <<<"$invite_json")"
INVITE_B="$(jq -er '.invites[1] | select(type == "string" and length > 0)' <<<"$invite_json")"
[[ "$INVITE_A" != "$INVITE_B" ]] || fail "invite CLI returned a duplicate"
invite_json=""

nonce="$(date -u +%H%M%S)"
NICKNAME_A="A$nonce"
NICKNAME_B="B$nonce"
readonly NICKNAME_A NICKNAME_B

register_user() {
  local serial="$1"
  local invite="$2"
  local nickname="$3"
  local secret_flag="$4"
  start_flutter "$serial"
  wait_for_identifier "$serial" invite-code >/dev/null \
    || fail "registration page did not expose invite-code on $serial"
  printf -v "$secret_flag" '%s' 1
  input_text_by_identifier "$serial" invite-code "$invite"
  assert_field_text "$serial" invite-code "$invite"
  input_text_by_identifier "$serial" nickname "$nickname"
  assert_field_text "$serial" nickname "$nickname"
  tap_identifier "$serial" register
  wait_for_identifier "$serial" game-gomoku >/dev/null \
    || fail "registration did not reach the catalog on $serial"
  printf -v "$secret_flag" '%s' 0
}
register_user "$SERIAL_A" "$INVITE_A" "$NICKNAME_A" SECRETS_ON_UI_A
register_user "$SERIAL_B" "$INVITE_B" "$NICKNAME_B" SECRETS_ON_UI_B

uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

tap_identifier "$SERIAL_A" choose-opponent
opponent_identifier="$(wait_for_opponent_identifier "$SERIAL_A")" \
  || fail "A did not expose exactly one enabled opponent resource-id"
USER_ID_B="${opponent_identifier#opponent-}"
[[ "$USER_ID_B" =~ $uuid_pattern && "$opponent_identifier" == "opponent-$USER_ID_B" ]] \
  || fail "A opponent resource-id did not contain B's canonical user ID"
readonly USER_ID_B
tap_identifier "$SERIAL_A" "$opponent_identifier"

MATCH_ID="$(wait_for_new_ready_match_id "$SERIAL_A")" \
  || fail "A did not emit exactly one first-match ready ID within ${WAIT_SECONDS}s"
[[ "$MATCH_ID" =~ $uuid_pattern ]] || fail "first Godot ready marker did not contain a canonical match ID"

match_show() {
  "$CTL_BIN" match show --id "$1" --db "$DB_PATH" --json
}

wait_for_server_match_lifecycle() {
  local match_id="$1"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while ((SECONDS < deadline)); do
    if grep -F "\"match_id\":\"$match_id\"" "$SERVER_LOG" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_match_snapshot() {
  local match_id="$1"
  local deadline=$((SECONDS + WAIT_SECONDS))
  local snapshot=""
  while ((SECONDS < deadline)); do
    snapshot="$(match_show "$match_id" 2>/dev/null || true)"
    if [[ "$(jq -r '.id // ""' <<<"$snapshot" 2>/dev/null)" == "$match_id" ]]; then
      printf '%s\n' "$snapshot"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_server_match_lifecycle "$MATCH_ID" \
  || fail "server lifecycle did not confirm the first match ID"
match_json="$(wait_for_match_snapshot "$MATCH_ID")" \
  || fail "first match was not readable through gameboxctl within ${WAIT_SECONDS}s"
BLACK_USER_ID="$(jq -er '.players[] | select(.color == "black") | .userId' <<<"$match_json")"
WHITE_USER_ID="$(jq -er '.players[] | select(.color == "white") | .userId' <<<"$match_json")"
USER_ID_A="$(jq -er --arg userB "$USER_ID_B" '.players[] | select(.userId != $userB) | .userId' <<<"$match_json")"
[[ "$USER_ID_A" =~ $uuid_pattern && "$USER_ID_A" != "$USER_ID_B" ]] \
  || fail "gameboxctl snapshot did not map A and B to distinct users"
readonly USER_ID_A
if [[ "$BLACK_USER_ID" == "$USER_ID_A" && "$WHITE_USER_ID" == "$USER_ID_B" ]]; then
  BLACK_SERIAL="$SERIAL_A"
  WHITE_SERIAL="$SERIAL_B"
elif [[ "$BLACK_USER_ID" == "$USER_ID_B" && "$WHITE_USER_ID" == "$USER_ID_A" ]]; then
  BLACK_SERIAL="$SERIAL_B"
  WHITE_SERIAL="$SERIAL_A"
else
  fail "match colors did not map to the registered users"
fi
readonly BLACK_USER_ID WHITE_USER_ID BLACK_SERIAL WHITE_SERIAL

wait_for_log_marker "$SERIAL_A" "$GAMEBOX_READY_MARKER game=gomoku match=$MATCH_ID" \
  || fail "A Godot did not report ready for the first match"
tap_identifier "$SERIAL_B" continue-match
wait_for_log_marker "$SERIAL_B" "$GAMEBOX_READY_MARKER game=gomoku match=$MATCH_ID" \
  || fail "B Godot did not report ready for the first match"
presence_marker="$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=0 status=active connection=connected opponent_presence=online"
wait_for_log_marker "$SERIAL_A" "$presence_marker" \
  || fail "A did not render B as online in the first match"
wait_for_log_marker "$SERIAL_B" "$presence_marker" \
  || fail "B did not render A as online in the first match"

display_size() {
  adb_for "$1" shell wm size | sed -n 's/.*: \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' | tail -n 1
}

design_point_for_serial() {
  local serial="$1"
  local design_x="$2"
  local design_y="$3"
  local width height
  read -r width height <<<"$(display_size "$serial")"
  ruby -e '
    width, height, design_width, design_height, x, y = ARGV.map(&:to_f)
    scale = [width / design_width, height / design_height].min
    offset_x = (width - design_width * scale) / 2.0
    offset_y = (height - design_height * scale) / 2.0
    puts "#{(offset_x + x * scale).round} #{(offset_y + y * scale).round}"
  ' "$width" "$height" "$DESIGN_WIDTH" "$DESIGN_HEIGHT" "$design_x" "$design_y"
}

tap_board_cell() {
  local serial="$1"
  local x="$2"
  local y="$3"
  local design_x design_y point pixel_x pixel_y
  design_x="$(ruby -e 'puts (ARGV[0].to_f + ARGV[1].to_i * ARGV[2].to_f / 14.0)' "$BOARD_GRID_LEFT" "$x" "$BOARD_GRID_SIDE")"
  design_y="$(ruby -e 'puts (ARGV[0].to_f + ARGV[1].to_i * ARGV[2].to_f / 14.0)' "$BOARD_GRID_TOP" "$y" "$BOARD_GRID_SIDE")"
  point="$(design_point_for_serial "$serial" "$design_x" "$design_y")"
  read -r pixel_x pixel_y <<<"$point"
  adb_for "$serial" shell input tap "$pixel_x" "$pixel_y" >/dev/null \
    || fail "could not tap board cell ($x,$y) on $serial"
}

wait_match_revision() {
  local expected="$1"
  local x="$2"
  local y="$3"
  local color="$4"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while ((SECONDS < deadline)); do
    local snapshot revision cell
    snapshot="$(match_show "$MATCH_ID" 2>/dev/null || true)"
    revision="$(jq -r '.revision // -1' <<<"$snapshot" 2>/dev/null || printf '%s' -1)"
    cell="$(jq -r --argjson index "$((y * 15 + x))" '.board[$index] // -1' <<<"$snapshot" 2>/dev/null || printf '%s' -1)"
    if [[ "$revision" == "$expected" && "$cell" == "$color" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

capture_board_crop() {
  local serial="$1"
  local output="$2"
  local screenshot="$output.full.png"
  adb_for "$serial" exec-out screencap -p >"$screenshot" || return 1
  [[ -s "$screenshot" ]] || return 1
  local top_left bottom_right left top right bottom width height
  top_left="$(design_point_for_serial "$serial" "$BOARD_LEFT" "$BOARD_TOP")"
  bottom_right="$(design_point_for_serial "$serial" "$((BOARD_LEFT + BOARD_SIDE))" "$((BOARD_TOP + BOARD_SIDE))")"
  read -r left top <<<"$top_left"
  read -r right bottom <<<"$bottom_right"
  width=$((right - left))
  height=$((bottom - top))
  ((width > 0 && height > 0)) || return 1
  ffmpeg -v error -y -i "$screenshot" -vf "crop=$width:$height:$left:$top" "$output" >/dev/null 2>&1 \
    || return 1
  [[ -s "$output" ]]
}

crop_matches_board() {
  local crop="$1"
  local board_json="$2"
  ffmpeg -v error -i "$crop" -f rawvideo -pix_fmt rgb24 - \
    | ruby -r json -e '
      path, encoded_board = ARGV
      header = File.binread(path, 24)
      exit 2 unless header.start_with?("\x89PNG".b)
      width, height = header.byteslice(16, 8).unpack("N2")
      exit 2 unless width == height && width.positive?
      pixels = STDIN.read
      exit 2 unless pixels.bytesize == width * height * 3
      board = JSON.parse(encoded_board)
      exit 2 unless board.length == 225 && board.all? { |cell| [0, 1, 2].include?(cell) }
      colors = [[216, 168, 95], [21, 26, 36], [248, 250, 252]]
      sample_offset = [(width * 0.006).round, 2].max
      board.each_with_index do |expected, index|
        offset = expected.zero? ? sample_offset : 0
        x = (((36.0 + (index % 15) * 888.0 / 14.0) / 960.0) * width).round + offset
        y = (((36.0 + (index / 15) * 888.0 / 14.0) / 960.0) * height).round + offset
        actual = pixels.byteslice((y * width + x) * 3, 3).bytes
        target = colors.fetch(expected)
        distance = Math.sqrt(actual.zip(target).sum { |left, right| (left - right)**2 })
        exit 3 if distance > 20.0
      end
    ' "$crop" "$board_json"
}

crop_grid_score() {
  ffmpeg -v error -i "$1" \
    -vf 'edgedetect=low=0.05:high=0.2,signalstats,metadata=print:file=-' \
    -frames:v 1 -f null - 2>&1 \
    | sed -n 's/^lavfi\.signalstats\.YAVG=//p' \
    | tail -n 1
}

crop_ssim() {
  ffmpeg -v info -i "$1" -i "$2" -lavfi ssim -f null - 2>&1 \
    | sed -E -n 's/.* All:([0-9.]+).*/\1/p' \
    | tail -n 1
}

assert_both_render_revision() {
  local revision="$1"
  local evidence_name="$2"
  local state_fragment="$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=$revision"
  wait_for_log_marker "$SERIAL_A" "$state_fragment" || fail "A did not render revision $revision marker"
  wait_for_log_marker "$SERIAL_B" "$state_fragment" || fail "B did not render revision $revision marker"
  local deadline=$((SECONDS + WAIT_SECONDS))
  local crop_a="$TEMP_DIR/board-A.png"
  local crop_b="$TEMP_DIR/board-B.png"
  local snapshot board_json
  snapshot="$(match_show "$MATCH_ID")" || fail "could not read authoritative board at revision $revision"
  [[ "$(jq -r '.revision' <<<"$snapshot")" == "$revision" ]] \
    || fail "authoritative board revision changed before visual assertion $revision"
  board_json="$(jq -ce '.board | select(length == 225)' <<<"$snapshot")" \
    || fail "authoritative board was malformed at revision $revision"
  local hash_a="" hash_b="" similarity="" grid_a="" grid_b=""
  while ((SECONDS < deadline)); do
    if capture_board_crop "$SERIAL_A" "$crop_a" && capture_board_crop "$SERIAL_B" "$crop_b"; then
      hash_a="$(shasum -a 256 "$crop_a" | awk '{print $1}')"
      hash_b="$(shasum -a 256 "$crop_b" | awk '{print $1}')"
      similarity="$(crop_ssim "$crop_a" "$crop_b")"
      grid_a="$(crop_grid_score "$crop_a")"
      grid_b="$(crop_grid_score "$crop_b")"
      if crop_matches_board "$crop_a" "$board_json" \
        && crop_matches_board "$crop_b" "$board_json" \
        && ruby -e 'exit(Float(ARGV[0]) >= 0.995 && Float(ARGV[1]) >= 5.0 && Float(ARGV[2]) >= 5.0 ? 0 : 1)' \
          "$similarity" "$grid_a" "$grid_b"; then
        break
      fi
    fi
    sleep 1
  done
  if [[ -z "$similarity" ]] \
    || ! crop_matches_board "$crop_a" "$board_json" \
    || ! crop_matches_board "$crop_b" "$board_json" \
    || ! ruby -e 'exit(Float(ARGV[0]) >= 0.995 && Float(ARGV[1]) >= 5.0 && Float(ARGV[2]) >= 5.0 ? 0 : 1)' \
      "$similarity" "$grid_a" "$grid_b"; then
    fail "rendered crops did not match the authoritative board at revision $revision"
  fi
  if [[ -n "$PREVIOUS_BOARD_HASH" && "$hash_a" == "$PREVIOUS_BOARD_HASH" ]]; then
    fail "rendered board hash did not change at accepted revision $revision"
  fi
  PREVIOUS_BOARD_HASH="$hash_a"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$revision" "$similarity" "$grid_a" "$grid_b" "$hash_a" "$hash_b" >>"$VISUAL_METRICS"
  if [[ -n "$evidence_name" ]]; then
    cp "$crop_a.full.png" "$ARTIFACT_DIR/$evidence_name-A.png"
    cp "$crop_b.full.png" "$ARTIFACT_DIR/$evidence_name-B.png"
  fi
}

assert_both_render_revision 0 initial

perform_move() {
  local serial="$1"
  local x="$2"
  local y="$3"
  local revision="$4"
  local color="$5"
  local evidence="$6"
  refresh_game_log_boundaries "revision-$revision" \
    || fail "could not establish dual-device log boundary for revision $revision"
  tap_board_cell "$serial" "$x" "$y"
  wait_match_revision "$revision" "$x" "$y" "$color" \
    || fail "move ($x,$y) did not commit as revision $revision"
  assert_both_render_revision "$revision" "$evidence"
}

perform_move "$BLACK_SERIAL" 3 3 1 1 ""
perform_move "$WHITE_SERIAL" 3 5 2 2 ""
perform_move "$BLACK_SERIAL" 4 3 3 1 pre-recovery

RECOVERY_SERIAL="$WHITE_SERIAL"
adb_for "$RECOVERY_SERIAL" shell am force-stop "$PACKAGE" >/dev/null \
  || fail "could not force-stop only $PACKAGE on the recovery device"
sleep 1
recovery_snapshot="$(match_show "$MATCH_ID")" || fail "match became unreadable after force-stop"
[[ "$(jq -r '.revision' <<<"$recovery_snapshot")" == "3" ]] \
  || fail "server revision changed while one client was force-stopped"
for check in '3,3,1' '3,5,2' '4,3,1'; do
  IFS=, read -r check_x check_y check_color <<<"$check"
  [[ "$(jq -r --argjson index "$((check_y * 15 + check_x))" '.board[$index]' <<<"$recovery_snapshot")" == "$check_color" ]] \
    || fail "accepted event ($check_x,$check_y) was lost during force-stop"
done

recovery_boundary="GAMEBOX_E2E_RECOVERY_$RUN_ID"
adb_for "$RECOVERY_SERIAL" shell log -p i -t GameboxE2E "$recovery_boundary" >/dev/null
if [[ "$RECOVERY_SERIAL" == "$SERIAL_A" ]]; then
  LOG_BOUNDARY_A="$recovery_boundary"
else
  LOG_BOUNDARY_B="$recovery_boundary"
fi
start_flutter "$RECOVERY_SERIAL"
tap_identifier "$RECOVERY_SERIAL" continue-match
wait_for_log_marker "$RECOVERY_SERIAL" "$GAMEBOX_READY_MARKER game=gomoku match=$MATCH_ID" \
  || fail "force-stopped client did not relaunch Godot"
wait_for_log_marker "$RECOVERY_SERIAL" "$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=3" \
  || fail "force-stopped client did not resume at authoritative revision 3"
PREVIOUS_BOARD_HASH=""
assert_both_render_revision 3 recovered

perform_move "$WHITE_SERIAL" 4 5 4 2 ""
perform_move "$BLACK_SERIAL" 5 3 5 1 ""
perform_move "$WHITE_SERIAL" 5 5 6 2 ""
perform_move "$BLACK_SERIAL" 6 3 7 1 ""
perform_move "$WHITE_SERIAL" 6 5 8 2 ""
perform_move "$BLACK_SERIAL" 7 3 9 1 terminal

final_snapshot="$(match_show "$MATCH_ID")" || fail "finished match was not readable"
[[ "$(jq -r '.status' <<<"$final_snapshot")" == "finished" \
  && "$(jq -r '.result' <<<"$final_snapshot")" == "five" \
  && "$(jq -r '.winnerUserId' <<<"$final_snapshot")" == "$BLACK_USER_ID" ]] \
  || fail "first match did not finish as a five for black"
for serial in "$SERIAL_A" "$SERIAL_B"; do
  wait_for_log_marker "$serial" "$GAMEBOX_RESULT_MARKER match=$MATCH_ID result=five" \
    || fail "$serial did not report the shared five result"
done

tap_design_back() {
  local serial="$1"
  local point x y
  point="$(design_point_for_serial "$serial" 144 120)"
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null || return 1
}
tap_design_back "$SERIAL_A" || fail "could not return A to the lobby"
tap_design_back "$SERIAL_B" || fail "could not return B to the lobby"
wait_for_identifier "$SERIAL_A" choose-opponent >/dev/null || fail "A lobby did not return to idle"
wait_for_identifier "$SERIAL_B" choose-opponent >/dev/null || fail "B lobby did not return to idle"

tap_identifier "$SERIAL_A" choose-opponent
second_opponent_identifier="$(wait_for_opponent_identifier "$SERIAL_A")" \
  || fail "A could not select B for the second match"
[[ "$second_opponent_identifier" == "opponent-$USER_ID_B" ]] \
  || fail "second opponent resource-id did not identify B"
tap_identifier "$SERIAL_A" "$second_opponent_identifier"
SECOND_MATCH_ID="$(wait_for_new_ready_match_id "$SERIAL_A" "$MATCH_ID")" \
  || fail "A did not emit exactly one second-match ready ID within ${WAIT_SECONDS}s"
[[ "$SECOND_MATCH_ID" =~ $uuid_pattern ]] || fail "second Godot ready marker did not contain a canonical match ID"
tap_identifier "$SERIAL_B" cancel-match
cancel_deadline=$((SECONDS + WAIT_SECONDS))
while ((SECONDS < cancel_deadline)); do
  second_snapshot="$(match_show "$SECOND_MATCH_ID" 2>/dev/null || true)"
  if [[ "$(jq -r '.status // ""' <<<"$second_snapshot" 2>/dev/null)" == "cancelled" \
    && "$(jq -r '.revision // -1' <<<"$second_snapshot" 2>/dev/null)" == "1" ]]; then
    break
  fi
  sleep 1
done
if [[ -z "${second_snapshot:-}" ]] \
  || ! jq -e '.status == "cancelled" and .revision == 1' <<<"$second_snapshot" >/dev/null; then
  fail "second zero-step match did not cancel"
fi
wait_for_log_marker "$SERIAL_A" "$GAMEBOX_RESULT_MARKER match=$SECOND_MATCH_ID result=cancelled" \
  || fail "A did not observe the second cancellation"
tap_design_back "$SERIAL_A" || fail "could not leave the cancelled second match"
wait_for_identifier "$SERIAL_A" choose-opponent >/dev/null || fail "A was not idle after second cancellation"
wait_for_identifier "$SERIAL_B" choose-opponent >/dev/null || fail "B was not idle after second cancellation"

SOURCE_REVISION_END="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_STATUS_END="$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=normal)"
provenance_contract \
  "$SOURCE_REVISION_START" "$SOURCE_STATUS_START" "$SOURCE_REVISION_END" "$SOURCE_STATUS_END" \
  || fail "source HEAD or worktree cleanliness changed after build"

printf '%s\n' "$final_snapshot" | jq -S . >"$ARTIFACT_DIR/final-match.json"
cp "$VISUAL_METRICS" "$ARTIFACT_DIR/visual-metrics.tsv"
sanitize_stream <"$SERVER_LOG" >"$ARTIFACT_DIR/server-sanitized.log"
sanitize_stream <"$SEMANTICS_LOG" >"$ARTIFACT_DIR/semantics-test.log"
devices_json="$(device_summary_json "$SERIAL_A" "$SERIAL_B" "$API_LEVEL_A" "$API_LEVEL_B" "$api_base")"
jq -n \
  --arg status passed \
  --arg sourceRevision "$SOURCE_REVISION_START" \
  --arg apkSha256 "$APK_SHA256" \
  --arg testApkSha256 "$TEST_APK_SHA256" \
  --arg installedApkSha256A "$INSTALLED_APK_SHA_A" \
  --arg installedApkSha256B "$INSTALLED_APK_SHA_B" \
  --arg installedTestApkSha256A "$INSTALLED_TEST_APK_SHA_A" \
  --arg installedTestApkSha256B "$INSTALLED_TEST_APK_SHA_B" \
  --argjson devices "$devices_json" \
  --arg matchId "$MATCH_ID" \
  --arg secondMatchId "$SECOND_MATCH_ID" \
  --arg recoverySerial "$RECOVERY_SERIAL" \
  --argjson recoveryBefore 3 \
  --argjson recoveryAfter 3 \
  '{
    status:$status,
    sourceRevision:$sourceRevision,
    apkSha256:$apkSha256,
    testApkSha256:$testApkSha256,
    installedApkSha256:{serialA:$installedApkSha256A,serialB:$installedApkSha256B},
    installedTestApkSha256:{serialA:$installedTestApkSha256A,serialB:$installedTestApkSha256B},
    devices:$devices,
    firstMatch:{id:$matchId,revisions:[0,1,2,3,4,5,6,7,8,9],status:"finished",result:"five"},
    recovery:{serial:$recoverySerial,beforeRevision:$recoveryBefore,afterRevision:$recoveryAfter,eventLoss:false},
    secondMatch:{id:$secondMatchId,revision:1,status:"cancelled",slotsReleased:true},
    assertions:[
      "resource-id-only-ui-driving","two-registered-users","random-color-mapping",
      "revision-and-board-after-each-move","two-authoritative-board-crops-with-ssim",
      "force-stop-auto-login-resume","shared-five-result","lobby-idle",
      "second-match-created","zero-step-cancelled","slots-released",
      "selected-device-semantics-integration","clean-build-provenance",
      "installed-apk-sha256-equality"
    ]
  }' >"$ARTIFACT_DIR/summary.json"

if ! protect_artifact_directory \
  "$ARTIFACT_DIR" "$TEMP_DIR/success-artifact-scan.txt" \
  "$INVITE_A" "$INVITE_B" "$JWT_SECRET" "$TOKEN_PEPPER"; then
  fail "artifact secret scanner removed unsafe or unverifiable output"
fi

printf 'Gamebox two-emulator E2E passed. Artifacts: %s\n' "$ARTIFACT_DIR"

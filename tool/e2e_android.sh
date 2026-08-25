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
readonly BOARD_GRID_LEFT=96
readonly BOARD_GRID_TOP=396
readonly BOARD_GRID_SIDE=888
readonly GAMEBOX_READY_MARKER="GAMEBOX_GODOT_READY"
readonly GAMEBOX_STATE_MARKER="GAMEBOX_GODOT_STATE"
readonly GAMEBOX_RESULT_MARKER="GAMEBOX_MATCH_RESULT"
readonly MANAGED_LARGE_DISPLAY="1080x2400"
readonly MANAGED_NARROW_DISPLAY="720x1600"
readonly MANAGED_LARGE_DENSITY=420
readonly MANAGED_NARROW_DENSITY=320

ADB_BIN="${GAMEBOX_E2E_ADB_BIN:-adb}"
ADB_TIMEOUT_SECONDS="${GAMEBOX_E2E_ADB_TIMEOUT_SECONDS:-30}"
INPUT_TIMEOUT_SECONDS="${GAMEBOX_E2E_INPUT_TIMEOUT_SECONDS:-20}"
BUILD_TIMEOUT_SECONDS="${GAMEBOX_E2E_BUILD_TIMEOUT_SECONDS:-600}"
SEMANTICS_TIMEOUT_SECONDS="${GAMEBOX_E2E_SEMANTICS_TIMEOUT_SECONDS:-300}"
AVD_SETUP_TIMEOUT_SECONDS="${GAMEBOX_E2E_AVD_SETUP_TIMEOUT_SECONDS:-120}"
CONNECTION_STATE_TIMEOUT_SECONDS="${GAMEBOX_E2E_CONNECTION_STATE_TIMEOUT_SECONDS:-150}"
TIMEOUT_KILL_GRACE_SECONDS="${GAMEBOX_E2E_TIMEOUT_KILL_GRACE_SECONDS:-2}"
BOUND_CHILD_REGISTRY=""
BOUND_SESSION_STATE_DIR=""
readonly HARNESS_PID=$$

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# shellcheck source=tool/lib/android_lease.sh
source "$ROOT_DIR/tool/lib/android_lease.sh"
# shellcheck source=tool/lib/check_output.sh
source "$ROOT_DIR/tool/lib/check_output.sh"
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

refresh_game_log_boundary() {
  local serial="$1"
  local suffix="$2"
  [[ "$suffix" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || return 2
  [[ "$serial" == "$SERIAL_A" || "$serial" == "$SERIAL_B" ]] || return 2
  local device_label boundary
  if [[ "$serial" == "$SERIAL_A" ]]; then
    device_label=A
  else
    device_label=B
  fi
  boundary="GAMEBOX_E2E_${device_label}_${suffix}_$RUN_ID"
  adb_for "$serial" shell log -p i -t GameboxE2E "$boundary" >/dev/null || return 1
  if [[ "$device_label" == A ]]; then
    LOG_BOUNDARY_A="$boundary"
  else
    LOG_BOUNDARY_B="$boundary"
  fi
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
    when "identifier-count"
      puts nodes.count { |node| node.attributes["resource-id"] == expected }
    when "visible-text", "visible-text-count"
      matches = nodes.select do |node|
        (node.attributes["text"].to_s == expected || node.attributes["content-desc"].to_s == expected) \
          && enabled.call(node) && bounds.call(node)
      end
      if mode == "visible-text-count"
        puts matches.length
      else
        exit 3 unless matches.length == 1
      end
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

failure_ui_dump_safe() {
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
  local instrumentation_output status
  if instrumentation_output="$(
    adb_for_timeout "$INPUT_TIMEOUT_SECONDS" "$serial" shell am instrument -w -r \
      -e class "$test_name" "$@" "$TEST_RUNNER" 2>&1
  )"; then
    status=0
  else
    status=$?
  fi
  printf -v "$output_variable" '%s' "$instrumentation_output"
  ((status == 0)) \
    && grep -F 'OK (1 test)' <<<"$instrumentation_output" >/dev/null \
    && ! grep -E 'FAILURES!!!|Process crashed|INSTRUMENTATION_FAILED' <<<"$instrumentation_output" >/dev/null
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
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
      printf '%s\n' "${output-}" | sanitize_stream \
        >"$ARTIFACT_DIR/helper-${serial//[^A-Za-z0-9_.-]/_}-$target.log" || true
    fi
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

assert_ui_state_safe() {
  local serial="$1"
  local secret_flag="$2"
  [[ "$secret_flag" == "0" ]] || return 1
  local safe_serial="${serial//[^A-Za-z0-9_.-]/_}"
  local local_path="$TEMP_DIR/ui-state-$safe_serial.xml"
  local remote_path="/data/local/tmp/gamebox-e2e-ui-state-${RUN_ID:-fixture-run}-$safe_serial.xml"
  local status=0 identifier_count value
  valid_remote_ui_path "$remote_path" || return 1
  rm -f -- "$local_path"
  if ! dump_ui_remote "$serial" "$local_path" "$remote_path"; then
    return 1
  fi
  identifier_count="$(xml_query identifier-count "$local_path" invite-code 2>/dev/null)" || status=1
  if ((status == 0)) && [[ "$identifier_count" != "0" ]]; then
    [[ "$identifier_count" == "1" ]] && xml_query field-empty "$local_path" invite-code >/dev/null 2>&1 \
      || status=1
  fi
  for value in "${INVITE_A:-}" "${INVITE_B:-}" "${JWT_SECRET:-}" "${TOKEN_PEPPER:-}"; do
    [[ -z "$value" ]] || fixed_value_absent "$local_path" "$value" || status=1
  done
  rm -f -- "$local_path"
  ((status == 0))
}

device_ui_mode() {
  local serial="$1"
  adb_for "$serial" shell cmd uimode night 2>/dev/null \
    | sed -n 's/^[[:space:]]*Night mode:[[:space:]]*\([a-z_][a-z_]*\).*$/\1/p' \
    | tail -n 1
}

device_display_override() {
  local serial="$1"
  adb_for "$serial" shell wm size 2>/dev/null \
    | sed -n 's/^[[:space:]]*Override size:[[:space:]]*\([0-9][0-9]*x[0-9][0-9]*\).*$/\1/p' \
    | tail -n 1
}

device_density_override() {
  local serial="$1"
  adb_for "$serial" shell wm density 2>/dev/null \
    | sed -n 's/^[[:space:]]*Override density:[[:space:]]*\([0-9][0-9]*\).*$/\1/p' \
    | tail -n 1
}

device_effective_density() {
  local serial="$1"
  adb_for "$serial" shell wm density 2>/dev/null \
    | sed -n 's/.*density:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    | tail -n 1
}

device_effective_size() {
  local serial="$1"
  adb_for "$serial" shell wm size 2>/dev/null \
    | sed -n 's/.*size:[[:space:]]*\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' \
    | tail -n 1
}

restore_one_device_visuals() {
  local serial="$1"
  local original_ui_mode="$2"
  local original_display_override="$3"
  local ui_flag_variable="$4"
  local display_flag_variable="$5"
  local original_density_override="$6"
  local density_flag_variable="$7"
  local status=0 actual
  if [[ "${!ui_flag_variable:-0}" == "1" ]]; then
    adb_for "$serial" shell cmd uimode night "$original_ui_mode" >/dev/null 2>&1 || status=1
    if ((status == 0)) && [[ "${VERIFY_VISUAL_RESTORE:-1}" == "1" ]]; then
      actual="$(device_ui_mode "$serial")" || status=1
      [[ "$actual" == "$original_ui_mode" ]] || status=1
    fi
    ((status == 0)) && printf -v "$ui_flag_variable" '%s' 0
  fi
  if [[ "${!display_flag_variable:-0}" == "1" ]]; then
    if [[ -n "$original_display_override" ]]; then
      adb_for "$serial" shell wm size "$original_display_override" >/dev/null 2>&1 || status=1
    else
      adb_for "$serial" shell wm size reset >/dev/null 2>&1 || status=1
    fi
    if ((status == 0)) && [[ "${VERIFY_VISUAL_RESTORE:-1}" == "1" ]]; then
      actual="$(device_display_override "$serial")" || status=1
      [[ "$actual" == "$original_display_override" ]] || status=1
    fi
    ((status == 0)) && printf -v "$display_flag_variable" '%s' 0
  fi
  if [[ "${!density_flag_variable:-0}" == "1" ]]; then
    if [[ -n "$original_density_override" ]]; then
      adb_for "$serial" shell wm density "$original_density_override" >/dev/null 2>&1 || status=1
    else
      adb_for "$serial" shell wm density reset >/dev/null 2>&1 || status=1
    fi
    if ((status == 0)) && [[ "${VERIFY_VISUAL_RESTORE:-1}" == "1" ]]; then
      actual="$(device_density_override "$serial")" || status=1
      [[ "$actual" == "$original_density_override" ]] || status=1
    fi
    ((status == 0)) && printf -v "$density_flag_variable" '%s' 0
  fi
  ((status == 0))
}

restore_selected_device_visuals() {
  local status=0
  if [[ -n "${SERIAL_A:-}" ]]; then
    restore_one_device_visuals \
      "$SERIAL_A" "${ORIGINAL_UI_MODE_A:-}" "${ORIGINAL_DISPLAY_OVERRIDE_A:-}" \
      UI_MODE_MUTATED_A DISPLAY_MUTATED_A "${ORIGINAL_DENSITY_OVERRIDE_A:-}" \
      DENSITY_MUTATED_A || status=1
  fi
  if [[ -n "${SERIAL_B:-}" ]]; then
    restore_one_device_visuals \
      "$SERIAL_B" "${ORIGINAL_UI_MODE_B:-}" "${ORIGINAL_DISPLAY_OVERRIDE_B:-}" \
      UI_MODE_MUTATED_B DISPLAY_MUTATED_B "${ORIGINAL_DENSITY_OVERRIDE_B:-}" \
      DENSITY_MUTATED_B || status=1
  fi
  ((status == 0))
}

configure_device_visuals() {
  local label="$1"
  local serial="$2"
  local target_ui_mode="$3"
  local target_display="$4"
  local target_density="$5"
  local mutate_display="$6"
  local original_ui_mode original_display_override original_density_override actual
  original_ui_mode="$(device_ui_mode "$serial")" \
    || fail "$serial did not report its original ui mode"
  case "$original_ui_mode" in
    auto|no|yes|custom) ;;
    *) fail "$serial reported an unsupported original ui mode" ;;
  esac
  original_display_override="$(device_display_override "$serial")" \
    || fail "$serial did not report its original display override"
  original_density_override="$(device_density_override "$serial")" \
    || fail "$serial did not report its original density override"

  printf -v "ORIGINAL_UI_MODE_$label" '%s' "$original_ui_mode"
  printf -v "ORIGINAL_DISPLAY_OVERRIDE_$label" '%s' "$original_display_override"
  printf -v "ORIGINAL_DENSITY_OVERRIDE_$label" '%s' "$original_density_override"
  printf -v "UI_MODE_MUTATED_$label" '%s' 1
  adb_for "$serial" shell cmd uimode night "$target_ui_mode" >/dev/null \
    || fail "could not set $serial to $target_ui_mode ui mode"
  actual="$(device_ui_mode "$serial")" || fail "$serial ui mode could not be verified"
  [[ "$actual" == "$target_ui_mode" ]] \
    || fail "$serial did not enter $target_ui_mode ui mode"

  if [[ "$mutate_display" == "1" ]]; then
    printf -v "DISPLAY_MUTATED_$label" '%s' 1
    adb_for "$serial" shell wm size "$target_display" >/dev/null \
      || fail "could not set the managed $serial display to $target_display"
    actual="$(device_display_override "$serial")" \
      || fail "$serial display override could not be verified"
    [[ "$actual" == "$target_display" ]] \
      || fail "$serial did not enter the required $target_display display override"
    printf -v "DENSITY_MUTATED_$label" '%s' 1
    adb_for "$serial" shell wm density "$target_density" >/dev/null \
      || fail "could not set the managed $serial density to $target_density"
    actual="$(device_density_override "$serial")" \
      || fail "$serial density override could not be verified"
    [[ "$actual" == "$target_density" ]] \
      || fail "$serial did not enter the required $target_density density override"
  fi
}

logical_viewport() {
  local width="$1"
  local height="$2"
  local density="$3"
  ruby -e '
    width, height, density = ARGV.map(&:to_f)
    puts "#{(width * 160.0 / density).floor} #{(height * 160.0 / density).floor}"
  ' "$width" "$height" "$density"
}

assert_selected_viewport_matrix() {
  local width_a height_a width_b height_b density_a density_b
  local logical_width_a logical_height_a logical_width_b logical_height_b
  read -r width_a height_a <<<"$(device_effective_size "$SERIAL_A")"
  read -r width_b height_b <<<"$(device_effective_size "$SERIAL_B")"
  [[ "$width_a" =~ ^[0-9]+$ && "$height_a" =~ ^[0-9]+$ \
    && "$width_b" =~ ^[0-9]+$ && "$height_b" =~ ^[0-9]+$ ]] \
    || fail "selected Android devices did not report usable effective viewports"
  ((height_a > width_a && height_b > width_b)) \
    || fail "selected Android devices must both use portrait phone viewports"
  density_a="$(device_effective_density "$SERIAL_A")"
  density_b="$(device_effective_density "$SERIAL_B")"
  [[ "$density_a" =~ ^[1-9][0-9]*$ && "$density_b" =~ ^[1-9][0-9]*$ ]] \
    || fail "selected Android devices did not report usable effective densities"
  read -r logical_width_a logical_height_a <<<"$(logical_viewport "$width_a" "$height_a" "$density_a")"
  read -r logical_width_b logical_height_b <<<"$(logical_viewport "$width_b" "$height_b" "$density_b")"
  ((logical_width_a >= 410 && logical_width_a <= 414 \
    && logical_height_a >= 912 && logical_height_a <= 918)) \
    || fail "serial A must provide the 412x915dp large phone viewport"
  ((logical_width_b >= 358 && logical_width_b <= 362 \
    && logical_height_b >= 798 && logical_height_b <= 802)) \
    || fail "serial B must provide the 360x800dp narrow phone viewport"
  VIEWPORT_A="${logical_width_a}x${logical_height_a}dp (${width_a}x${height_a}px@$density_a)"
  VIEWPORT_B="${logical_width_b}x${logical_height_b}dp (${width_b}x${height_b}px@$density_b)"
}

finalize_cleanup_outcome() {
  local original_exit_code="$1"
  local cleanup_ok="$2"
  local summary_path="$3"
  [[ "$original_exit_code" =~ ^[0-9]+$ \
    && ("$cleanup_ok" == "0" || "$cleanup_ok" == "1") \
    && -n "$summary_path" ]] || return 2

  local final_exit_code="$original_exit_code"
  if [[ "$cleanup_ok" == "0" ]]; then
    if [[ -f "$summary_path" ]] \
      && jq -e '.status == "passed"' "$summary_path" >/dev/null 2>&1; then
      local replacement="${summary_path}.cleanup-$HARNESS_PID"
      if jq -n \
        --arg status failure \
        --arg phase cleanup \
        --arg message 'E2E assertions passed, but owned runtime cleanup was incomplete.' \
        '{status:$status,phase:$phase,message:$message}' >"$replacement" \
        && mv "$replacement" "$summary_path"; then
        :
      else
        rm -f -- "$replacement" "$summary_path"
      fi
    fi
    [[ "$original_exit_code" == "0" ]] && final_exit_code=1
  fi
  printf '%s\n' "$final_exit_code"
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

e2e_server_identity_is_safe() {
  [[ -n "${SERVER_PID:-}" \
    && "$SERVER_PID" =~ ^[1-9][0-9]*$ \
    && "$SERVER_PID" != "$HARNESS_PID" ]] \
    && pid_descends_from_harness "$SERVER_PID" \
    && owned_process_matches "$SERVER_PID" "$SERVER_BIN"
}

pause_e2e_server() {
  ((SERVER_PAUSED == 0)) || return 0
  e2e_server_identity_is_safe || return 1
  kill -STOP "$SERVER_PID" 2>/dev/null || return 1
  local process_state
  process_state="$(ps -p "$SERVER_PID" -o stat= 2>/dev/null | tr -d ' ')"
  [[ "$process_state" == *T* ]] || return 1
  SERVER_PAUSED=1
}

resume_e2e_server() {
  ((SERVER_PAUSED == 1)) || return 0
  e2e_server_identity_is_safe || return 1
  kill -CONT "$SERVER_PID" 2>/dev/null || return 1
  local deadline=$((SECONDS + TIMEOUT_KILL_GRACE_SECONDS)) process_state
  while ((SECONDS < deadline)); do
    process_state="$(ps -p "$SERVER_PID" -o stat= 2>/dev/null | tr -d ' ')"
    [[ "$process_state" != *T* ]] && {
      SERVER_PAUSED=0
      return 0
    }
    sleep 0.1
  done
  return 1
}

stop_e2e_server() {
  [[ -n "${SERVER_PID:-}" ]] || {
    SERVER_PAUSED=0
    return 0
  }
  e2e_server_identity_is_safe || return 1
  resume_e2e_server || return 1
  local stopped_pid="$SERVER_PID"
  stop_owned_process "$stopped_pid" "$SERVER_BIN" 10
  wait "$stopped_pid" 2>/dev/null || true
  if kill -0 "$stopped_pid" 2>/dev/null; then
    return 1
  fi
  SERVER_PID=""
  SERVER_PAUSED=0
}

start_e2e_server() {
  [[ -z "${SERVER_PID:-}" && "$SERVER_PAUSED" == "0" ]] || return 1
  port_is_free "$server_port" || return 1
  GAMEBOX_ADDR="0.0.0.0:$server_port" \
  GAMEBOX_DB_PATH="$DB_PATH" \
  GAMEBOX_JWT_SECRET="$JWT_SECRET" \
  GAMEBOX_TOKEN_PEPPER="$TOKEN_PEPPER" \
    "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  if ! e2e_server_identity_is_safe; then
    terminate_exact_child "$SERVER_PID" "$TIMEOUT_KILL_GRACE_SECONDS"
    SERVER_PID=""
    return 1
  fi
}

wait_for_e2e_server_health() {
  local deadline=$((SECONDS + WAIT_SECONDS))
  while ((SECONDS < deadline)); do
    if curl --fail --silent --max-time 2 "$host_base/healthz" \
      | jq -e '.status == "ok"' >/dev/null 2>&1; then
      return 0
    fi
    e2e_server_identity_is_safe || return 1
    sleep 1
  done
  return 1
}

boundary_for_serial() {
  [[ "$1" == "$SERIAL_A" ]] && printf '%s\n' "$LOG_BOUNDARY_A" || printf '%s\n' "$LOG_BOUNDARY_B"
}

start_first_connect_loading_watch() {
  local serial="$1"
  local boundary_suffix="${2:-}"
  local boundary watcher_pid watcher_group watcher_session extra=""
  [[ -z "${LOADING_WATCH_PID:-}" ]] || return 2
  if [[ -n "$boundary_suffix" ]]; then
    [[ "$boundary_suffix" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || return 2
    if [[ "$serial" == "$SERIAL_A" ]]; then
      boundary="GAMEBOX_E2E_A_${boundary_suffix}_$RUN_ID"
    elif [[ "$serial" == "$SERIAL_B" ]]; then
      boundary="GAMEBOX_E2E_B_${boundary_suffix}_$RUN_ID"
    else
      return 2
    fi
  else
    boundary="$(boundary_for_serial "$serial")"
  fi
  [[ -x "$ROOT_DIR/tool/run_in_session.rb" ]] || return 1
  LOADING_WATCH_FILE="$TEMP_DIR/first-connect-loading-match-id"
  LOADING_WATCH_READY_FILE="$TEMP_DIR/first-connect-loading-session"
  LOADING_WATCH_STREAM_READY_FILE="$TEMP_DIR/first-connect-loading-stream"
  rm -f -- "$LOADING_WATCH_FILE"
  rm -f -- "$LOADING_WATCH_READY_FILE"
  rm -f -- "$LOADING_WATCH_STREAM_READY_FILE"
  {
    ruby "$ROOT_DIR/tool/run_in_session.rb" "$LOADING_WATCH_READY_FILE" -- \
      "$ADB_BIN" -s "$serial" logcat -b all -v threadtime -T 100 2>/dev/null \
      | awk -v marker="$boundary" -v stream_ready_file="$LOADING_WATCH_STREAM_READY_FILE" '
          {
            if (!stream_ready) {
              print "ready" > stream_ready_file
              close(stream_ready_file)
              stream_ready = 1
            }
          }
          index($0, marker) {
            found = 1
            next
          }
          found && $0 ~ /GAMEBOX_GODOT_STATE match=[0-9a-f-]+ revision=-1 status=loading connection=/ {
            line = $0
            sub(/^.*GAMEBOX_GODOT_STATE match=/, "", line)
            sub(/ revision=-1.*$/, "", line)
            print line
            fflush()
            exit
          }
        '
  } >"$LOADING_WATCH_FILE" 2>/dev/null &
  LOADING_WATCH_PID=$!
  local handshake_deadline=$((SECONDS + 2))
  while [[ ! -s "$LOADING_WATCH_READY_FILE" ]] \
    && kill -0 "$LOADING_WATCH_PID" 2>/dev/null; do
    ((SECONDS < handshake_deadline)) || break
    sleep 0.05
  done
  if [[ ! -s "$LOADING_WATCH_READY_FILE" ]] \
    || ! read -r watcher_pid watcher_group watcher_session extra <"$LOADING_WATCH_READY_FILE" \
    || [[ -n "$extra" ]] \
    || ! session_numbers_are_safe "$watcher_pid" "$watcher_group" "$watcher_session"; then
    stop_first_connect_loading_watch
    return 1
  fi
  LOADING_WATCH_LEADER_PID="$watcher_pid"
  LOADING_WATCH_PROCESS_GROUP="$watcher_group"
  LOADING_WATCH_SESSION="$watcher_session"
  if ! session_identity_is_safe \
    "$LOADING_WATCH_LEADER_PID" "$LOADING_WATCH_PROCESS_GROUP" "$LOADING_WATCH_SESSION"; then
    stop_first_connect_loading_watch
    return 1
  fi
  local stream_deadline=$((SECONDS + 2))
  while [[ ! -s "$LOADING_WATCH_STREAM_READY_FILE" ]] \
    && kill -0 "$LOADING_WATCH_PID" 2>/dev/null; do
    ((SECONDS < stream_deadline)) || break
    sleep 0.05
  done
  if [[ ! -s "$LOADING_WATCH_STREAM_READY_FILE" ]]; then
    stop_first_connect_loading_watch
    return 1
  fi
}

stop_first_connect_loading_watch() {
  local cleanup_status=0
  local watcher_recheck=0
  local watcher_process_group=""
  local watcher_session=""
  if [[ -n "${LOADING_WATCH_LEADER_PID:-}" \
    && -n "${LOADING_WATCH_PROCESS_GROUP:-}" \
    && -n "${LOADING_WATCH_SESSION:-}" ]]; then
    watcher_process_group="$LOADING_WATCH_PROCESS_GROUP"
    watcher_session="$LOADING_WATCH_SESSION"
    if session_numbers_are_safe \
      "$LOADING_WATCH_LEADER_PID" "$watcher_process_group" "$watcher_session"; then
      if ! terminate_owned_session_group \
        "$LOADING_WATCH_LEADER_PID" "$watcher_process_group" "$watcher_session" \
        "$TIMEOUT_KILL_GRACE_SECONDS"; then
        cleanup_status=1
        watcher_recheck=1
      fi
    else
      cleanup_status=1
    fi
  fi
  if [[ -n "${LOADING_WATCH_PID:-}" ]]; then
    kill "$LOADING_WATCH_PID" 2>/dev/null || true
    wait "$LOADING_WATCH_PID" 2>/dev/null || true
  fi
  if ((watcher_recheck)); then
    if session_group_state "$watcher_process_group" "$watcher_session"; then
      cleanup_status=1
    else
      if [[ "$?" == "1" ]]; then
        cleanup_status=0
      else
        cleanup_status=1
      fi
    fi
  fi
  [[ -z "${LOADING_WATCH_READY_FILE:-}" ]] \
    || rm -f -- "$LOADING_WATCH_READY_FILE"
  [[ -z "${LOADING_WATCH_STREAM_READY_FILE:-}" ]] \
    || rm -f -- "$LOADING_WATCH_STREAM_READY_FILE"
  LOADING_WATCH_PID=""
  LOADING_WATCH_LEADER_PID=""
  LOADING_WATCH_PROCESS_GROUP=""
  LOADING_WATCH_SESSION=""
  LOADING_WATCH_READY_FILE=""
  LOADING_WATCH_STREAM_READY_FILE=""
  return "$cleanup_status"
}

wait_for_first_connect_loading() {
  local serial="$1"
  local deadline=$((SECONDS + WAIT_SECONDS)) candidate=""
  while ((SECONDS < deadline)); do
    if [[ -s "$LOADING_WATCH_FILE" ]]; then
      candidate="$(tail -n 1 "$LOADING_WATCH_FILE")"
    fi
    if [[ "$candidate" =~ ^[0-9a-f-]{36}$ ]]; then
      LOADING_MATCH_ID="$candidate"
      stop_first_connect_loading_watch
      return $?
    fi
    sleep 0.01
  done
  stop_first_connect_loading_watch
  return 1
}

presence_state_fragment() {
  local match_id="$1"
  local revision="$2"
  local presence="$3"
  [[ "$match_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ \
    && "$revision" =~ ^-?[0-9]+$ \
    && ("$presence" == "online" || "$presence" == "offline" || "$presence" == "unknown") ]] \
    || return 2
  printf '%s match=%s revision=%s status=%s connection=%s opponent_presence=%s\n' \
    "$GAMEBOX_STATE_MARKER" "$match_id" "$revision" \
    "$( [[ "$revision" == "-1" ]] && printf loading || printf active )" \
    "$( [[ "$revision" == "-1" ]] && printf connecting || printf connected )" \
    "$presence"
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
  trap 'stop_e2e_server || true; terminate_exact_child "$session_fixture_wrapper_pid" 1; terminate_exact_child "$session_fixture_direct_pid" 1; terminate_exact_child "$session_fixture_grandchild_pid" 1; terminate_exact_child "$session_fixture_unrelated_pid" 1; rm -rf "$fixture_dir"' RETURN
  local fixture="$fixture_dir/ui.xml"
  local opponent_id="opponent-22222222-2222-4222-8222-222222222222"
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>' \
    '<hierarchy rotation="0">' \
    '  <node resource-id="invite-code" text="" content-desc="not-a-selector" enabled="true" visible-to-user="true" bounds="[10,20][110,220]"><node resource-id="" text="fixture-secret" enabled="true" bounds="[10,20][110,220]" /></node>' \
    '  <node resource-id="nickname" text="fixture-nickname" content-desc="" enabled="true" visible-to-user="true" bounds="[120,20][220,220]"><node resource-id="" text="fixture-nickname" enabled="true" bounds="[120,20][220,220]" /></node>' \
    '  <node resource-id="disabled" text="" content-desc="invite-code" enabled="false" visible-to-user="true" bounds="[0,0][50,50]" />' \
    '  <node resource-id="" text="" content-desc="当前已是最新版本" enabled="true" visible-to-user="true" bounds="[20,520][400,600]" />' \
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
  xml_query visible-text "$fixture" '当前已是最新版本' >/dev/null \
    || { printf 'visible Snackbar text fixture failed\n' >&2; return 1; }
  [[ "$(xml_query visible-text-count "$fixture" '当前已是最新版本')" == "1" ]] \
    || { printf 'single visible text count fixture failed\n' >&2; return 1; }
  [[ "$(xml_query visible-text-count "$fixture" '不存在的提示')" == "0" ]] \
    || { printf 'missing visible text count fixture failed\n' >&2; return 1; }
  if xml_query visible-text "$fixture" '不存在的提示' >/dev/null 2>&1; then
    printf 'missing visible text fixture was accepted\n' >&2
    return 1
  fi

  local duplicate_visible_text="$fixture_dir/duplicate-visible-text.xml"
  printf '%s\n' \
    '<hierarchy>' \
    '  <node text="应用更新" enabled="true" visible-to-user="true" bounds="[0,0][10,10]" />' \
    '  <node content-desc="应用更新" enabled="true" visible-to-user="true" bounds="[10,10][20,20]" />' \
    '</hierarchy>' >"$duplicate_visible_text"
  [[ "$(xml_query visible-text-count "$duplicate_visible_text" '应用更新')" == "2" ]] \
    || { printf 'duplicate visible text count fixture failed\n' >&2; return 1; }

  local fixture_match_id='11111111-1111-4111-8111-111111111111'
  [[ "$(presence_state_fragment "$fixture_match_id" 3 offline)" \
    == 'GAMEBOX_GODOT_STATE match=11111111-1111-4111-8111-111111111111 revision=3 status=active connection=connected opponent_presence=offline' ]] \
    || { printf 'offline presence marker fixture failed\n' >&2; return 1; }

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

  local cleanup_summary="$fixture_dir/cleanup-summary.json"
  local cleanup_result
  printf '{"status":"passed","mode":"fixture"}\n' >"$cleanup_summary"
  cleanup_result="$(finalize_cleanup_outcome 0 0 "$cleanup_summary")" \
    || { printf 'success-path cleanup failure outcome fixture errored\n' >&2; return 1; }
  [[ "$cleanup_result" == "1" ]] \
    || { printf 'success-path cleanup failure remained successful\n' >&2; return 1; }
  if [[ -f "$cleanup_summary" ]] \
    && jq -e '.status == "passed"' "$cleanup_summary" >/dev/null 2>&1; then
    printf 'cleanup failure retained a passed summary\n' >&2
    return 1
  fi

  printf '{"status":"passed","mode":"fixture"}\n' >"$cleanup_summary"
  cleanup_result="$(finalize_cleanup_outcome 23 0 "$cleanup_summary")" \
    || { printf 'nonzero cleanup failure outcome fixture errored\n' >&2; return 1; }
  [[ "$cleanup_result" == "23" ]] \
    || { printf 'cleanup failure replaced the original nonzero exit code\n' >&2; return 1; }

  printf '{"status":"passed","mode":"fixture"}\n' >"$cleanup_summary"
  cleanup_result="$(finalize_cleanup_outcome 0 1 "$cleanup_summary")" \
    || { printf 'successful cleanup outcome fixture errored\n' >&2; return 1; }
  [[ "$cleanup_result" == "0" ]] \
    && jq -e '.status == "passed"' "$cleanup_summary" >/dev/null \
    || { printf 'successful cleanup altered its exit code or summary\n' >&2; return 1; }

  local server_fixture="$fixture_dir/gameboxd-fixture"
  local server_environment_log="$fixture_dir/server-environment.log"
  : >"$server_environment_log"
  printf '%s\n' \
    '#!/bin/sh' \
    "trap 'exit 0' TERM INT" \
    'printf "%s|%s|%s|%s\n" "$GAMEBOX_ADDR" "$GAMEBOX_DB_PATH" "$GAMEBOX_JWT_SECRET" "$GAMEBOX_TOKEN_PEPPER" >>"$GAMEBOX_E2E_SERVER_ENV_LOG"' \
    'while :; do sleep 1; done' >"$server_fixture"
  chmod 700 "$server_fixture"
  export GAMEBOX_E2E_SERVER_ENV_LOG="$server_environment_log"
  SERVER_BIN="$server_fixture"
  SERVER_LOG="$fixture_dir/server.log"
  DB_PATH="$fixture_dir/server.sqlite"
  JWT_SECRET='fixture-jwt'
  TOKEN_PEPPER='fixture-pepper'
  server_port=23456
  SERVER_PID=""
  SERVER_PAUSED=0
  port_is_free() { return 0; }

  start_e2e_server \
    || { printf 'owned server fixture did not start\n' >&2; return 1; }
  local first_server_pid="$SERVER_PID"
  local fixture_wait_index fixture_launch_count
  for fixture_wait_index in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    fixture_launch_count="$(wc -l <"$server_environment_log" | tr -d '[:space:]')"
    [[ "$fixture_launch_count" == "1" ]] && break
    sleep 0.05
  done
  [[ "${fixture_launch_count:-0}" == "1" ]] \
    || { printf 'owned server fixture did not record its first launch\n' >&2; return 1; }
  pause_e2e_server \
    || { printf 'owned server fixture did not pause\n' >&2; return 1; }
  [[ "$SERVER_PAUSED" == "1" ]] \
    || { printf 'owned server pause state was not tracked\n' >&2; return 1; }
  resume_e2e_server \
    || { printf 'owned server fixture did not resume\n' >&2; return 1; }
  [[ "$SERVER_PAUSED" == "0" ]] \
    || { printf 'owned server resume state was not cleared\n' >&2; return 1; }
  pause_e2e_server \
    || { printf 'owned server fixture did not pause before stop\n' >&2; return 1; }
  stop_e2e_server \
    || { printf 'exact paused owned server fixture did not stop\n' >&2; return 1; }
  [[ -z "$SERVER_PID" && "$SERVER_PAUSED" == "0" ]] \
    || { printf 'owned server stop did not clear tracked identity\n' >&2; return 1; }
  start_e2e_server \
    || { printf 'owned server fixture did not restart\n' >&2; return 1; }
  [[ "$SERVER_PID" != "$first_server_pid" ]] \
    || { printf 'owned server restart reused the stopped process identity\n' >&2; return 1; }
  for fixture_wait_index in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    fixture_launch_count="$(wc -l <"$server_environment_log" | tr -d '[:space:]')"
    [[ "$fixture_launch_count" == "2" ]] && break
    sleep 0.05
  done
  [[ "${fixture_launch_count:-0}" == "2" ]] \
    || { printf 'owned server fixture did not record its restart\n' >&2; return 1; }
  stop_e2e_server \
    || { printf 'restarted owned server fixture did not stop\n' >&2; return 1; }
  [[ "$(wc -l <"$server_environment_log" | tr -d '[:space:]')" == "2" ]] \
    || { printf 'owned server restart did not preserve two launches\n' >&2; return 1; }
  [[ "$(sort -u "$server_environment_log" | wc -l | tr -d '[:space:]')" == "1" ]] \
    || { printf 'owned server restart changed its database, port, or secrets\n' >&2; return 1; }

  ruby -e 'Signal.trap("TERM") { exit 0 }; loop { sleep 3600 }' >/dev/null 2>&1 &
  session_fixture_unrelated_pid=$!
  sleep 0.1
  SERVER_PID="$session_fixture_unrelated_pid"
  SERVER_PAUSED=0
  if pause_e2e_server || stop_e2e_server; then
    printf 'server lifecycle fixture accepted an unrelated child process\n' >&2
    return 1
  fi
  kill -0 "$session_fixture_unrelated_pid" 2>/dev/null \
    || { printf 'server lifecycle fixture killed an unrelated process\n' >&2; return 1; }
  SERVER_PID=""
  SERVER_PAUSED=0
  terminate_exact_child "$session_fixture_unrelated_pid" 1
  wait "$session_fixture_unrelated_pid" 2>/dev/null || true
  session_fixture_unrelated_pid=""
  unset GAMEBOX_E2E_SERVER_ENV_LOG

  failure_ui_dump_safe 0 0 \
    || { printf 'inactive secret UI dump gate fixture failed\n' >&2; return 1; }
  failure_ui_dump_safe 1 1 \
    || { printf 'verified clear UI dump gate fixture failed\n' >&2; return 1; }
  if failure_ui_dump_safe 1 0; then
    printf 'uncleared secret UI dump gate fixture was accepted\n' >&2
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
  local loading_watch_pid_file="$fixture_dir/loading-watch.pid"
  : >"$loading_watch_pid_file"
  export FAKE_ADB_PID_FILE="$loading_watch_pid_file"
  export FAKE_ADB_LOG_BOUNDARY='watch-boundary'
  local loading_match_id='11111111-1111-4111-8111-111111111111'
  export FAKE_ADB_LOADING_MATCH_ID="$loading_match_id"
  export FAKE_ADB_MODE=loading-watch
  TEMP_DIR="$fixture_dir"
  SERIAL_A='fixture-A'
  LOG_BOUNDARY_A='watch-boundary'
  LOADING_WATCH_PID=""
  LOADING_WATCH_FILE=""
  LOADING_WATCH_LEADER_PID=""
  LOADING_WATCH_PROCESS_GROUP=""
  LOADING_WATCH_SESSION=""
  LOADING_WATCH_READY_FILE=""
  local loading_watch_wait_index loading_watch_adb_pid
  start_first_connect_loading_watch fixture-A \
    || { printf 'loading watcher could not start in fixture\n' >&2; return 1; }
  for loading_watch_wait_index in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$loading_watch_pid_file" ]] && break
    sleep 0.05
  done
  [[ -s "$loading_watch_pid_file" ]] \
    || { printf 'loading watcher fixture did not start adb logcat\n' >&2; return 1; }
  loading_watch_adb_pid="$(<"$loading_watch_pid_file")"
  wait_for_first_connect_loading fixture-A \
    || { printf 'loading watcher fixture did not observe its marker\n' >&2; return 1; }
  [[ "$LOADING_MATCH_ID" == "$loading_match_id" ]] \
    || { printf 'loading watcher fixture returned the wrong match ID\n' >&2; return 1; }
  if kill -0 "$loading_watch_adb_pid" 2>/dev/null; then
    kill -KILL "$loading_watch_adb_pid" 2>/dev/null || true
    printf 'loading watcher left adb logcat alive\n' >&2
    return 1
  fi
  export FAKE_ADB_PID_FILE="$fake_pid_file"
  [[ "$FAKE_ADB_PID_FILE" == "$fake_pid_file" ]] \
    || { printf 'loading watcher fixture did not restore the fake adb pid file\n' >&2; return 1; }
  unset FAKE_ADB_MODE FAKE_ADB_LOG_BOUNDARY FAKE_ADB_LOADING_MATCH_ID
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
  refresh_game_log_boundary fixture-A revision-8-single \
    || { printf 'single-device log boundary fixture failed\n' >&2; return 1; }
  [[ "$LOG_BOUNDARY_A" == "GAMEBOX_E2E_A_revision-8-single_fixture-run" \
    && "$LOG_BOUNDARY_B" == "old-B" ]] \
    || { printf 'single-device log boundary changed the unrelated device\n' >&2; return 1; }

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

  : >"$fake_log"
  assert_ui_state_safe fixture-serial 0 \
    || { printf 'logic-only UI state assertion fixture failed\n' >&2; return 1; }
  if grep -F 'screencap' "$fake_log" >/dev/null; then
    printf 'logic-only UI state assertion invoked screenshot capture\n' >&2
    return 1
  fi

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
  dump_ui_remote fixture-serial "$fixture_dir/pull-success.xml" \
    '/data/local/tmp/gamebox-e2e-fixture-pull-success.xml' \
    || { printf 'successful remote UI dump fixture failed\n' >&2; return 1; }
  [[ -s "$fixture_dir/pull-success.xml" && ! -e "$fake_device_root/remote-ui.xml" ]] \
    || { printf 'remote UI XML survived successful pull cleanup\n' >&2; return 1; }

  : >"$fake_log"
  TEMP_DIR="$fixture_dir"
  INVITE_A="$marker"
  INVITE_B='second-fixture-secret-abcdefghijklmnopqrstuvwxyz0123456789'
  JWT_SECRET='fixture-jwt-secret-abcdefghijklmnopqrstuvwxyz0123456789'
  TOKEN_PEPPER='fixture-token-pepper-abcdefghijklmnopqrstuvwxyz0123456789'
  if assert_ui_state_safe fixture-serial 1; then
    printf 'secret-active UI state assertion was accepted\n' >&2
    return 1
  fi
  [[ ! -s "$fake_log" ]] \
    || { printf 'secret-active UI state assertion reached adb\n' >&2; return 1; }
  assert_ui_state_safe fixture-serial 0 \
    || { printf 'safe logic-only UI state assertion fixture failed\n' >&2; return 1; }
  if grep -F 'screencap' "$fake_log" >/dev/null; then
    printf 'logic-only UI state assertion invoked screenshot capture\n' >&2
    return 1
  fi
  [[ ! -e "$fake_device_root/remote-ui.xml" ]] \
    || { printf 'logic-only UI state assertion left a remote UI dump\n' >&2; return 1; }

  [[ "$(logical_viewport 1080 2400 420)" == "411 914" \
    && "$(logical_viewport 720 1600 320)" == "360 800" ]] \
    || { printf 'logical Android viewport conversion fixture failed\n' >&2; return 1; }
  grep -F '410-414x912-918dp' "$ROOT_DIR/README.md" >/dev/null \
    && grep -F '358-362x798-802dp' "$ROOT_DIR/README.md" >/dev/null \
    || { printf 'documented supplied-device viewport contract is inconsistent with the harness\n' >&2; return 1; }

  SERIAL_A='fixture-A'
  SERIAL_B='fixture-B'
  ORIGINAL_UI_MODE_A='auto'
  ORIGINAL_UI_MODE_B='no'
  ORIGINAL_DISPLAY_OVERRIDE_A='800x1800'
  ORIGINAL_DISPLAY_OVERRIDE_B=''
  ORIGINAL_DENSITY_OVERRIDE_A='420'
  ORIGINAL_DENSITY_OVERRIDE_B=''
  UI_MODE_MUTATED_A=1
  UI_MODE_MUTATED_B=1
  DISPLAY_MUTATED_A=1
  DISPLAY_MUTATED_B=1
  DENSITY_MUTATED_A=1
  DENSITY_MUTATED_B=1
  VERIFY_VISUAL_RESTORE=0
  : >"$fake_log"
  restore_selected_device_visuals \
    || { printf 'dual-device visual restoration fixture failed\n' >&2; return 1; }
  grep -F 'arg=auto' "$fake_log" >/dev/null \
    || { printf 'A original ui mode was not restored\n' >&2; return 1; }
  grep -F 'arg=no' "$fake_log" >/dev/null \
    || { printf 'B original ui mode was not restored\n' >&2; return 1; }
  grep -F 'arg=800x1800' "$fake_log" >/dev/null \
    || { printf 'A original display override was not restored\n' >&2; return 1; }
  grep -F 'arg=reset' "$fake_log" >/dev/null \
    || { printf 'B absent display override was not restored\n' >&2; return 1; }
  grep -F 'arg=420' "$fake_log" >/dev/null \
    || { printf 'A original density override was not restored\n' >&2; return 1; }
  [[ "$UI_MODE_MUTATED_A" == "0" && "$UI_MODE_MUTATED_B" == "0" \
    && "$DISPLAY_MUTATED_A" == "0" && "$DISPLAY_MUTATED_B" == "0" \
    && "$DENSITY_MUTATED_A" == "0" && "$DENSITY_MUTATED_B" == "0" ]] \
    || { printf 'visual restoration fixture did not clear mutation flags\n' >&2; return 1; }

  local helper_source="$ROOT_DIR/app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/E2eSetTextTest.kt"
  if rg -n 'Base64|gameboxTextValueBase64' "$helper_source" >/dev/null; then
    printf 'Android helper still accepts reversible secret argv\n' >&2
    return 1
  fi

  local runtime_source
  runtime_source="$(sed -n '/^for required_command in /,$p' "${BASH_SOURCE[0]}")"
  local cleanup_source
  cleanup_source="$(sed -n '/^cleanup() {/,/^}/p' "${BASH_SOURCE[0]}")"
  grep -F 'restore_selected_device_visuals' <<<"$cleanup_source" >/dev/null \
    || { printf 'EXIT cleanup no longer restores selected device visuals\n' >&2; return 1; }
  grep -F 'stop_e2e_server' <<<"$cleanup_source" >/dev/null \
    || { printf 'EXIT cleanup no longer stops the exact owned server\n' >&2; return 1; }
  grep -F 'declare -F stop_first_connect_loading_watch' <<<"$cleanup_source" >/dev/null \
    || { printf 'early EXIT cleanup calls an unavailable loading watcher\n' >&2; return 1; }
  local watcher_cleanup_source watcher_wait_line watcher_recheck_line
  watcher_cleanup_source="$(sed -n '/^stop_first_connect_loading_watch() {/,/^self_test() {/p' "${BASH_SOURCE[0]}")"
  watcher_wait_line="$(grep -n 'wait \"\$LOADING_WATCH_PID\"' <<<"$watcher_cleanup_source" | head -n 1 | cut -d: -f1)"
  watcher_recheck_line="$(grep -n 'session_group_state \"\$watcher_process_group\" \"\$watcher_session\"' <<<"$watcher_cleanup_source" | head -n 1 | cut -d: -f1)"
  [[ "$watcher_wait_line" =~ ^[1-9][0-9]*$ && "$watcher_recheck_line" =~ ^[1-9][0-9]*$ \
    && "$watcher_recheck_line" -gt "$watcher_wait_line" ]] \
    || { printf 'loading watcher teardown validates its session before reaping the pipeline\n' >&2; return 1; }
  local loading_pause_source loading_pause_line loading_stop_line
  loading_pause_source="$(sed -n '/^wait_for_first_connect_loading_and_pause() {/,/^}/p' "${BASH_SOURCE[0]}")"
  loading_pause_line="$(grep -n 'pause_e2e_server || return 1' <<<"$loading_pause_source" | head -n 1 | cut -d: -f1)"
  loading_stop_line="$(grep -n 'stop_first_connect_loading_watch' <<<"$loading_pause_source" | head -n 1 | cut -d: -f1)"
  [[ "$loading_pause_line" =~ ^[1-9][0-9]*$ && "$loading_stop_line" =~ ^[1-9][0-9]*$ \
    && "$loading_pause_line" -lt "$loading_stop_line" ]] \
    || { printf 'first-connect server pause does not precede watcher teardown\n' >&2; return 1; }
  local visual_configuration_source
  visual_configuration_source="$(
    sed -n '/^configure_device_visuals() {/,/^}/p' "${BASH_SOURCE[0]}"
  )"
  if grep -E 'font_scale|accessibility(_enabled|_services)?' \
    <<<"$visual_configuration_source" >/dev/null; then
    printf 'device visual configuration reads or mutates excluded accessibility state\n' >&2
    return 1
  fi
  grep -F 'failure_ui_dump_safe' <<<"$runtime_source" >/dev/null \
    || { printf 'failure UI dump safety gate is missing\n' >&2; return 1; }
  grep -F 'failure-artifact-scan.txt' <<<"$runtime_source" >/dev/null \
    || { printf 'failure artifact scanner is missing\n' >&2; return 1; }
  grep -F 'start_first_connect_loading_watch "$SERIAL_A" first-gomoku-loading' \
    <<<"$runtime_source" >/dev/null \
    || { printf 'first-connect loading watcher is not started with a post-attach boundary\n' >&2; return 1; }
  grep -F 'tap_identifier_after_scroll "$SERIAL_B" continue-match' \
    <<<"$runtime_source" >/dev/null \
    || { printf 'narrow active-match action is not atomically scroll-aware\n' >&2; return 1; }
  if grep -E 'tap_identifier "\$[A-Za-z_][A-Za-z0-9_]*" continue-match' \
    <<<"$runtime_source" >/dev/null; then
    printf 'a continue-match action still uses the non-scroll-aware tap helper\n' >&2
    return 1
  fi
  grep -F 'wait_for_first_connect_loading_and_pause "$SERIAL_A"' \
    <<<"$runtime_source" >/dev/null \
    || { printf 'first-connect loading flow does not pause before inspecting UI\n' >&2; return 1; }
  local first_connect_flow_source
  first_connect_flow_source="$(sed -n '/^wait_for_first_connect_loading_and_pause "\$SERIAL_A"/,/^resume_e2e_server/p' "${BASH_SOURCE[0]}")"
  grep -F 'assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A"' \
    <<<"$first_connect_flow_source" >/dev/null \
    || { printf 'first-connect loading flow does not capture its safe UI snapshot\n' >&2; return 1; }
  grep -F 'assert_first_connect_loading_held "$SERIAL_A" "$LOADING_MATCH_ID"' \
    <<<"$first_connect_flow_source" >/dev/null \
    || { printf 'first-connect loading flow does not recheck the held state after its UI snapshot\n' >&2; return 1; }
  local first_connect_safe_line first_connect_held_line
  first_connect_safe_line="$(grep -n 'assert_ui_state_safe' <<<"$first_connect_flow_source" | head -n 1 | cut -d: -f1)"
  first_connect_held_line="$(grep -n 'assert_first_connect_loading_held' <<<"$first_connect_flow_source" | head -n 1 | cut -d: -f1)"
  [[ "$first_connect_safe_line" =~ ^[1-9][0-9]*$ \
    && "$first_connect_held_line" =~ ^[1-9][0-9]*$ \
    && "$first_connect_held_line" -gt "$first_connect_safe_line" ]] \
    || { printf 'first-connect held-state recheck does not follow its UI snapshot\n' >&2; return 1; }
  grep -F 'resume_e2e_server' \
    <<<"$runtime_source" >/dev/null \
    || { printf 'first-connect loading flow does not resume the paused server\n' >&2; return 1; }
  grep -F 'exercise_optional_move_confirmation "$BLACK_SERIAL" 3 3 1 1' \
    <<<"$runtime_source" >/dev/null \
    || { printf 'optional move confirmation lifecycle is not exercised\n' >&2; return 1; }
  grep -F 'optional-move-confirmation-enable-cancel-confirm-disable' \
    <<<"$runtime_source" >/dev/null \
    || { printf 'optional move confirmation result assertion is missing\n' >&2; return 1; }
  local update_flow_source
  update_flow_source="$(sed -n '/^tap_identifier "\$SERIAL_B" app-update/,/^uuid_pattern=/p' "${BASH_SOURCE[0]}")"
  grep -F 'wait_for_identifier "$SERIAL_B" update-feedback' \
    <<<"$update_flow_source" >/dev/null \
    || { printf 'update flow does not wait for terminal update feedback\n' >&2; return 1; }
  if grep -F 'settle_update_action "$SERIAL_B"' <<<"$update_flow_source" >/dev/null; then
    printf 'update flow still uses the premature toolbar settlement gate\n' >&2
    return 1
  fi
  if grep -F 'KEYCODE_BACK' <<<"$update_flow_source" >/dev/null; then
    printf 'update flow can still exit the app when no dialog opens\n' >&2
    return 1
  fi
  if grep -E 'screencap|capture_ui_evidence|ui_evidence|screenshots/|\.png' \
    <<<"$runtime_source" >/dev/null; then
    printf 'fixed E2E runtime still contains screenshot capture or evidence paths\n' >&2
    return 1
  fi
  grep -F 'point="$(design_point_for_serial "$serial" 640 1230)"' <<<"$runtime_source" >/dev/null \
    || { printf 'large portrait resign confirmation tap point is stale\n' >&2; return 1; }
  grep -F 'point="$(design_point_from_bottom_for_serial "$serial" 540 240)"' <<<"$runtime_source" >/dev/null \
    || { printf 'large portrait settings Done tap point is stale\n' >&2; return 1; }
  grep -F "flutter test -d \"\$SERIAL_A\" integration_test/semantics_test.dart" <<<"$runtime_source" >/dev/null \
    || { printf 'selected-device semantics command is missing\n' >&2; return 1; }
  if grep -F 'SECONDS + 10' <<<"$runtime_source" >/dev/null; then
    printf 'state revision wait still uses a hard-coded 10 second deadline\n' >&2
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

for required_command in curl git go jq lsof openssl rg ruby sed shasum unzip; do
  command -v "$required_command" >/dev/null 2>&1 \
    || { printf 'Gamebox E2E failed: missing required command %s\n' "$required_command" >&2; exit 2; }
done
command -v "$ADB_BIN" >/dev/null 2>&1 \
  || { printf 'Gamebox E2E failed: configured adb is not available\n' >&2; exit 2; }
command -v flutter >/dev/null 2>&1 \
  || { printf 'Gamebox E2E failed: flutter is not available on PATH\n' >&2; exit 2; }
for timeout_value in \
  "$ADB_TIMEOUT_SECONDS" "$INPUT_TIMEOUT_SECONDS" "$BUILD_TIMEOUT_SECONDS" \
  "$SEMANTICS_TIMEOUT_SECONDS" "$AVD_SETUP_TIMEOUT_SECONDS" \
  "$CONNECTION_STATE_TIMEOUT_SECONDS" "$TIMEOUT_KILL_GRACE_SECONDS"; do
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
SERVER_PAUSED=0
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
THIRD_MATCH_ID=""
LOADING_MATCH_ID=""
LOADING_WATCH_PID=""
LOADING_WATCH_FILE=""
LOADING_WATCH_LEADER_PID=""
LOADING_WATCH_PROCESS_GROUP=""
LOADING_WATCH_SESSION=""
LOADING_WATCH_READY_FILE=""
RECOVERY_SERIAL=""
REMOTE_UI_PATH="/data/local/tmp/gamebox-e2e-$RUN_ID.xml"
SECRET_INPUT_COUNTER=0
SECRET_INPUT_FILES_A=()
SECRET_INPUT_FILES_B=()
ORIGINAL_UI_MODE_A=""
ORIGINAL_UI_MODE_B=""
ORIGINAL_DISPLAY_OVERRIDE_A=""
ORIGINAL_DISPLAY_OVERRIDE_B=""
ORIGINAL_DENSITY_OVERRIDE_A=""
ORIGINAL_DENSITY_OVERRIDE_B=""
UI_MODE_MUTATED_A=0
UI_MODE_MUTATED_B=0
DISPLAY_MUTATED_A=0
DISPLAY_MUTATED_B=0
DENSITY_MUTATED_A=0
DENSITY_MUTATED_B=0
VERIFY_VISUAL_RESTORE=1
VIEWPORT_A=""
VIEWPORT_B=""
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
  local finalized_exit_code
  trap - EXIT INT TERM ERR
  set +e
  if declare -F stop_first_connect_loading_watch >/dev/null; then
    stop_first_connect_loading_watch || cleanup_ok=0
  fi
  terminate_registered_bounded_children
  if [[ -n "$SERIAL_A" ]]; then
    cleanup_serial_private_state "$SERIAL_A" A
    bounded_helper_uninstall "$SERIAL_A"
  fi
  if [[ -n "$SERIAL_B" ]]; then
    cleanup_serial_private_state "$SERIAL_B" B
    bounded_helper_uninstall "$SERIAL_B"
  fi
  restore_selected_device_visuals || cleanup_ok=0
  stop_e2e_server || cleanup_ok=0
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
  if finalized_exit_code="$(
    finalize_cleanup_outcome "$exit_code" "$cleanup_ok" "$ARTIFACT_DIR/summary.json"
  )"; then
    exit_code="$finalized_exit_code"
  else
    rm -f -- "$ARTIFACT_DIR/summary.json"
    ((exit_code == 0)) && exit_code=1
  fi
  gamebox_test_output_cleanup
  rm -rf "$TEMP_DIR"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
gamebox_test_output_init

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
  local serial label xml secret_active secret clear_verified
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
    if failure_ui_dump_safe "$secret_active" "$clear_verified"; then
      xml="$TEMP_DIR/failure-$label.xml"
      if declare -F dump_ui >/dev/null 2>&1 && dump_ui "$serial" "$xml"; then
        xml_query diagnostics "$xml" 2>/dev/null | sanitize_stream >"$ARTIFACT_DIR/failure-$label-ui.txt" || true
      fi
    else
      printf 'Failure UI dump omitted because secret-field clearing could not be verified.\n' \
        >"$ARTIFACT_DIR/failure-$label-media-omitted.txt" || true
    fi
    if declare -F game_logs_after_boundary >/dev/null 2>&1 && declare -F boundary_for_serial >/dev/null 2>&1; then
      game_logs_after_boundary "$serial" "$(boundary_for_serial "$serial")" \
        | sanitize_stream >"$ARTIFACT_DIR/failure-$label-logcat.txt" || true
    fi
  done
  if [[ -n "$MATCH_ID" && -n "$SERVER_PID" ]] \
    && declare -F match_show >/dev/null 2>&1 \
    && e2e_server_identity_is_safe; then
    stop_e2e_server || true
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
  USING_PROVIDED_DEVICES=1
  [[ -n "$provided_a" && -n "$provided_b" ]] || fail "provide both GAMEBOX_E2E_SERIAL_A and GAMEBOX_E2E_SERIAL_B"
  if ! validate_serial_text "$provided_a" || ! validate_serial_text "$provided_b"; then
    fail "a provided Android serial contains unsupported characters"
  fi
  [[ "$provided_a" != "$provided_b" ]] || fail "the two provided serials must be different"
  SERIAL_A="$provided_a"
  SERIAL_B="$provided_b"
else
  USING_PROVIDED_DEVICES=0
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

configure_device_visuals A "$SERIAL_A" no "$MANAGED_LARGE_DISPLAY" "$MANAGED_LARGE_DENSITY" "$((1 - USING_PROVIDED_DEVICES))"
configure_device_visuals B "$SERIAL_B" yes "$MANAGED_NARROW_DISPLAY" "$MANAGED_NARROW_DENSITY" "$((1 - USING_PROVIDED_DEVICES))"
assert_selected_viewport_matrix
readonly VIEWPORT_A VIEWPORT_B
printf 'E2E viewports: A=%s (light/large), B=%s (dark/narrow)\n' \
  "$VIEWPORT_A" "$VIEWPORT_B"

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
build_android_test_apk() {
  (
  cd "$ROOT_DIR/app/android"
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" env \
    ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a \
    ./gradlew :app:assembleDebugAndroidTest
  )
}
gamebox_run_step "E2E Android test APK build" build_android_test_apk
TEST_APK="$ROOT_DIR/app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
readonly TEST_APK
[[ -f "$TEST_APK" ]] || fail "E2E-owned UI Automator helper APK was not produced"
build_flutter_debug_apk() {
  (
  cd "$ROOT_DIR/app"
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" env \
    ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a \
    flutter build apk \
      --debug --target-platform=android-arm64 \
      --dart-define="GAMEBOX_API_BASE_URL=$api_base"
  )
}
gamebox_run_step "E2E Flutter debug APK build" build_flutter_debug_apk
APK="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-debug.apk"
readonly APK
[[ -f "$APK" ]] || fail "debug APK was not produced"
packaged_abis="$(unzip -Z1 "$APK" | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u | paste -sd ' ' -)"
[[ "$packaged_abis" == "arm64-v8a" ]] || fail "APK ABI set is '${packaged_abis:-empty}', expected arm64-v8a only"
for required_asset in \
  assets/games/gomoku/gomoku_scene.tscn \
  assets/games/gomoku/gomoku_board.gd \
  assets/games/gomoku/gomoku_preferences.gd \
  assets/design_system/components/gamebox_back_button.tscn \
  assets/design_system/gamebox_theme.gd; do
  unzip -Z1 "$APK" | grep -Fx "$required_asset" >/dev/null || fail "APK is missing $required_asset"
done
APK_SHA256="$(shasum -a 256 "$APK" | awk '{print $1}')"
TEST_APK_SHA256="$(shasum -a 256 "$TEST_APK" | awk '{print $1}')"
[[ "$APK_SHA256" =~ ^[0-9a-f]{64}$ && "$TEST_APK_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "built APK SHA-256 provenance was invalid"
readonly APK_SHA256 TEST_APK_SHA256
build_server_tools() {
  (
  cd "$ROOT_DIR/server"
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" go build -o "$SERVER_BIN" ./cmd/gameboxd
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" go build -o "$CTL_BIN" ./cmd/gameboxctl
  )
}
gamebox_run_step "E2E server tools build" build_server_tools

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

wait_for_identifier_after_scroll() {
  local serial="$1"
  local identifier="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))
  local xml="$TEMP_DIR/ui-scroll-${serial//[^A-Za-z0-9_.-]/_}.xml"
  local width height center
  read -r width height <<<"$(device_effective_size "$serial")"
  [[ "$width" =~ ^[1-9][0-9]*$ && "$height" =~ ^[1-9][0-9]*$ ]] || return 1
  while ((SECONDS < deadline)); do
    if dump_ui "$serial" "$xml"; then
      center="$(xml_query bounds "$xml" "$identifier" 2>/dev/null)" && {
        printf '%s\n' "$center"
        return 0
      }
    fi
    adb_for "$serial" shell input swipe \
      "$((width / 2))" "$((height * 3 / 4))" \
      "$((width / 2))" "$((height * 2 / 5))" 250 >/dev/null || return 1
    sleep 0.5
  done
  return 1
}

wait_for_visible_text() {
  local serial="$1"
  local expected="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))
  local xml="$TEMP_DIR/ui-visible-text-${serial//[^A-Za-z0-9_.-]/_}.xml"
  while ((SECONDS < deadline)); do
    if dump_ui "$serial" "$xml" \
      && xml_query visible-text "$xml" "$expected" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

tap_identifier_after_scroll() {
  local serial="$1"
  local identifier="$2"
  local center x y
  center="$(wait_for_identifier_after_scroll "$serial" "$identifier")" || return 1
  read -r x y <<<"$center"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
}

assert_visible_text_absent() {
  local serial="$1"
  local unexpected="$2"
  local xml="$TEMP_DIR/ui-absent-text-${serial//[^A-Za-z0-9_.-]/_}.xml"
  dump_ui "$serial" "$xml" || return 1
  [[ "$(xml_query visible-text-count "$xml" "$unexpected")" == "0" ]]
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

wait_for_log_marker_with_timeout() {
  local serial="$1"
  local marker="$2"
  local timeout_seconds="$3"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if game_logs_after_boundary "$serial" "$(boundary_for_serial "$serial")" | grep -F "$marker" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_log_marker() {
  wait_for_log_marker_with_timeout "$1" "$2" "$WAIT_SECONDS"
}

wait_for_presence_state() {
  local serial="$1"
  local match_id="$2"
  local revision="$3"
  local presence="$4"
  local fragment
  fragment="$(presence_state_fragment "$match_id" "$revision" "$presence")" || return $?
  wait_for_log_marker "$serial" "$fragment"
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

wait_for_first_connect_loading_and_pause() {
  local serial="$1"
  local deadline=$((SECONDS + WAIT_SECONDS)) candidate=""
  while ((SECONDS < deadline)); do
    if [[ -s "$LOADING_WATCH_FILE" ]]; then
      candidate="$(tail -n 1 "$LOADING_WATCH_FILE")"
    fi
    if [[ "$candidate" =~ ^[0-9a-f-]{36}$ ]]; then
      LOADING_MATCH_ID="$candidate"
      pause_e2e_server || return 1
      if ! stop_first_connect_loading_watch; then
        resume_e2e_server || true
        return 1
      fi
      sleep 0.2
      if game_logs_after_boundary "$serial" "$(boundary_for_serial "$serial")" \
        | grep -F "$GAMEBOX_STATE_MARKER match=$candidate revision=0" >/dev/null; then
        resume_e2e_server || true
        return 1
      fi
      return 0
    fi
    sleep 0.01
  done
  stop_first_connect_loading_watch
  return 1
}

assert_first_connect_loading_held() {
  local serial="$1"
  local match_id="$2"
  [[ "$match_id" =~ ^[0-9a-f-]{36}$ ]] || return 2
  if game_logs_after_boundary "$serial" "$(boundary_for_serial "$serial")" \
    | grep -F "$GAMEBOX_STATE_MARKER match=$match_id revision=0" >/dev/null; then
    return 1
  fi
}

JWT_SECRET="$(openssl rand -hex 32)"
TOKEN_PEPPER="$(openssl rand -hex 32)"
: >"$SERVER_LOG"
start_e2e_server || fail "could not start the exact E2E-owned gameboxd process"
wait_for_e2e_server_health \
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
  assert_ui_state_safe "$serial" "${!secret_flag}" \
    || fail "could not verify registration UI state before private invite input"
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
gamebox_test_progress 'Gamebox E2E: registering both users and creating the first match...'
register_user "$SERIAL_A" "$INVITE_A" "$NICKNAME_A" SECRETS_ON_UI_A
assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A" \
  || fail "could not verify the light idle lobby UI state"
register_user "$SERIAL_B" "$INVITE_B" "$NICKNAME_B" SECRETS_ON_UI_B

wait_for_visible_text "$SERIAL_B" '检查更新' \
  || fail "B update action did not become ready after its automatic check"
tap_identifier "$SERIAL_B" app-update
wait_for_identifier "$SERIAL_B" update-feedback >/dev/null \
  || fail "B did not show terminal non-modal update feedback"
assert_visible_text_absent "$SERIAL_B" '应用更新' \
  || fail "B showed a modal update dialog for terminal update feedback"
assert_ui_state_safe "$SERIAL_B" "$SECRETS_ON_UI_B" \
  || fail "could not verify the dark routine-update feedback state"
wait_for_identifier "$SERIAL_B" game-gomoku >/dev/null \
  || fail "B left the lobby after routine update feedback"

uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

tap_identifier "$SERIAL_A" choose-opponent
opponent_identifier="$(wait_for_opponent_identifier "$SERIAL_A")" \
  || fail "A did not expose exactly one enabled opponent resource-id"
assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A" \
  || fail "could not verify the light opponent list UI state"
USER_ID_B="${opponent_identifier#opponent-}"
[[ "$USER_ID_B" =~ $uuid_pattern && "$opponent_identifier" == "opponent-$USER_ID_B" ]] \
  || fail "A opponent resource-id did not contain B's canonical user ID"
readonly USER_ID_B
start_first_connect_loading_watch "$SERIAL_A" first-gomoku-loading \
  || fail "could not start the first-connect loading event watcher"
refresh_game_log_boundary "$SERIAL_A" first-gomoku-loading \
  || fail "could not establish first-connect loading log boundary after watcher attach"
tap_identifier "$SERIAL_A" "$opponent_identifier"

wait_for_first_connect_loading_and_pause "$SERIAL_A" \
  || fail "could not hold the real first-connect loading state before its initial snapshot"
assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A" \
  || fail "could not verify the real first-connect loading UI state"
assert_first_connect_loading_held "$SERIAL_A" "$LOADING_MATCH_ID" \
  || fail "first-connect snapshot arrived while the held loading UI was inspected"
resume_e2e_server \
  || fail "could not resume the E2E server after first-connect loading assertion"

MATCH_ID="$(wait_for_new_ready_match_id "$SERIAL_A")" \
  || fail "A did not emit exactly one first-match ready ID within ${WAIT_SECONDS}s"
[[ "$MATCH_ID" =~ $uuid_pattern ]] || fail "first Godot ready marker did not contain a canonical match ID"
[[ "$MATCH_ID" == "$LOADING_MATCH_ID" ]] \
  || fail "first-connect loading assertion did not belong to the ready match"

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
wait_for_identifier_after_scroll "$SERIAL_B" continue-match >/dev/null \
  || fail "B did not expose the active-match automation identifier"
assert_ui_state_safe "$SERIAL_B" "$SECRETS_ON_UI_B" \
  || fail "could not verify the dark narrow active lobby UI state"
tap_identifier_after_scroll "$SERIAL_B" continue-match \
  || fail "B could not activate the narrow active-match action"
wait_for_log_marker "$SERIAL_B" "$GAMEBOX_READY_MARKER game=gomoku match=$MATCH_ID" \
  || fail "B Godot did not report ready for the first match"
wait_for_presence_state "$SERIAL_A" "$MATCH_ID" 0 online \
  || fail "A did not render B as online in the first match"
wait_for_presence_state "$SERIAL_B" "$MATCH_ID" 0 online \
  || fail "B did not render A as online in the first match"

display_size() {
  device_effective_size "$1"
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
    puts "#{(x * scale).round} #{(y * scale).round}"
  ' "$width" "$height" "$DESIGN_WIDTH" "$DESIGN_HEIGHT" "$design_x" "$design_y"
}

design_point_from_bottom_for_serial() {
  local serial="$1"
  local design_x="$2"
  local bottom_offset="$3"
  local width height
  read -r width height <<<"$(display_size "$serial")"
  ruby -e '
    width, height, design_width, design_height, x, bottom_offset = ARGV.map(&:to_f)
    scale = [width / design_width, height / design_height].min
    puts "#{(x * scale).round} #{(height - bottom_offset * scale).round}"
  ' "$width" "$height" "$DESIGN_WIDTH" "$DESIGN_HEIGHT" "$design_x" "$bottom_offset"
}

tap_godot_settings() {
  local serial="$1" point x y
  point="$(design_point_for_serial "$serial" 936 120)"
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
}

tap_godot_move_confirmation_toggle() {
  local serial="$1" point x y
  point="$(design_point_from_bottom_for_serial "$serial" 540 434)"
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
}

tap_godot_settings_done() {
  local serial="$1" point x y
  point="$(design_point_from_bottom_for_serial "$serial" 540 240)"
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
}

tap_godot_move_cancel() {
  local serial="$1" point x y
  point="$(design_point_for_serial "$serial" 314 1604)"
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
}

tap_godot_move_confirm() {
  local serial="$1" point x y
  point="$(design_point_for_serial "$serial" 766 1604)"
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
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

assert_both_state_revision() {
  local revision="$1"
  local state_fragment="$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=$revision"
  wait_for_log_marker "$SERIAL_A" "$state_fragment" || fail "A did not report revision $revision state"
  wait_for_log_marker "$SERIAL_B" "$state_fragment" || fail "B did not report revision $revision state"
  local snapshot
  snapshot="$(match_show "$MATCH_ID")" || fail "could not read authoritative board at revision $revision"
  [[ "$(jq -r '.revision' <<<"$snapshot")" == "$revision" ]] \
    || fail "authoritative board revision changed before logic assertion $revision"
  jq -e '.board | length == 225 and all(. == 0 or . == 1 or . == 2)' <<<"$snapshot" >/dev/null \
    || fail "authoritative board was malformed at revision $revision"
}

assert_both_state_revision 0

assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A" \
  || fail "could not verify the light initial Gomoku UI state"

perform_move() {
  local serial="$1"
  local x="$2"
  local y="$3"
  local revision="$4"
  local color="$5"
  refresh_game_log_boundaries "revision-$revision" \
    || fail "could not establish dual-device log boundary for revision $revision"
  tap_board_cell "$serial" "$x" "$y"
  wait_match_revision "$revision" "$x" "$y" "$color" \
    || fail "move ($x,$y) did not commit as revision $revision"
  assert_both_state_revision "$revision"
}

perform_pending_logic_move() {
  local serial="$1"
  local x="$2"
  local y="$3"
  local revision="$4"
  local color="$5"
  refresh_game_log_boundaries "pending-revision-$revision" \
    || fail "could not establish the pending logic log boundary"
  pause_e2e_server \
    || fail "could not pause the exact E2E-owned server for pending logic"
  tap_board_cell "$serial" "$x" "$y"
  wait_for_log_marker_with_timeout \
    "$serial" \
    "GAMEBOX_BOARD_CANMOVE can=false conn=connected await=false status=active pend_empty=false" \
    "$WAIT_SECONDS" \
    || fail "the local pending logic state did not appear before acknowledgement"
  resume_e2e_server \
    || fail "could not resume the exact E2E-owned server after pending logic"
  wait_match_revision "$revision" "$x" "$y" "$color" \
    || fail "pending logic move ($x,$y) did not commit as revision $revision after resume"
  assert_both_state_revision "$revision"
}

exercise_optional_move_confirmation() {
  local serial="$1"
  local x="$2"
  local y="$3"
  local revision="$4"
  local color="$5"
  local snapshot cell_index
  cell_index=$((y * 15 + x))

  refresh_game_log_boundaries optional-confirmation-enable \
    || fail "could not establish optional confirmation log boundaries"
  tap_godot_settings "$serial" || fail "could not open Gomoku settings"
  wait_for_log_marker "$serial" 'GAMEBOX_SETTINGS_SHEET visible=true' \
    || fail "Gomoku settings sheet did not open"
  tap_godot_move_confirmation_toggle "$serial" || fail "could not enable move confirmation"
  wait_for_log_marker "$serial" 'GAMEBOX_MOVE_CONFIRMATION enabled=true' \
    || fail "move confirmation did not enable"
  tap_godot_settings_done "$serial" || fail "could not close Gomoku settings"
  wait_for_log_marker "$serial" 'GAMEBOX_SETTINGS_SHEET visible=false' \
    || fail "Gomoku settings sheet did not close"

  tap_board_cell "$serial" "$x" "$y"
  wait_for_log_marker "$serial" "GAMEBOX_MOVE_SELECTION state=selected x=$x y=$y" \
    || fail "the first board tap did not remain a local selection"
  sleep 2
  snapshot="$(match_show "$MATCH_ID")" || fail "could not inspect the match after local selection"
  [[ "$(jq -r '.revision' <<<"$snapshot")" == "$((revision - 1))" \
    && "$(jq -r --argjson index "$cell_index" '.board[$index]' <<<"$snapshot")" == "0" ]] \
    || fail "local move selection changed the authoritative match before confirmation"
  tap_godot_move_cancel "$serial" || fail "could not cancel the local move selection"
  wait_for_log_marker "$serial" "GAMEBOX_MOVE_SELECTION state=cancelled x=$x y=$y" \
    || fail "local move selection did not cancel"
  snapshot="$(match_show "$MATCH_ID")" || fail "could not inspect the match after cancellation"
  [[ "$(jq -r '.revision' <<<"$snapshot")" == "$((revision - 1))" \
    && "$(jq -r --argjson index "$cell_index" '.board[$index]' <<<"$snapshot")" == "0" ]] \
    || fail "cancelling a local move selection changed the authoritative match"

  refresh_game_log_boundaries optional-confirmation-submit \
    || fail "could not establish optional confirmation submit boundaries"
  tap_board_cell "$serial" "$x" "$y"
  wait_for_log_marker "$serial" "GAMEBOX_MOVE_SELECTION state=selected x=$x y=$y" \
    || fail "the second board tap did not create a local selection"
  pause_e2e_server \
    || fail "could not pause the E2E server before confirming the selected move"
  tap_godot_move_confirm "$serial" || fail "could not confirm the selected move"
  wait_for_log_marker_with_timeout \
    "$serial" \
    "GAMEBOX_BOARD_CANMOVE can=false conn=connected await=false status=active pend_empty=false" \
    "$WAIT_SECONDS" \
    || fail "confirmed selection did not become pending before acknowledgement"
  resume_e2e_server \
    || fail "could not resume the E2E server after confirming the selected move"
  wait_match_revision "$revision" "$x" "$y" "$color" \
    || fail "confirmed move ($x,$y) did not commit as revision $revision"
  assert_both_state_revision "$revision"

  refresh_game_log_boundaries optional-confirmation-disable \
    || fail "could not establish optional confirmation disable boundaries"
  tap_godot_settings "$serial" || fail "could not reopen Gomoku settings"
  wait_for_log_marker "$serial" 'GAMEBOX_SETTINGS_SHEET visible=true' \
    || fail "Gomoku settings sheet did not reopen"
  tap_godot_move_confirmation_toggle "$serial" || fail "could not disable move confirmation"
  wait_for_log_marker "$serial" 'GAMEBOX_MOVE_CONFIRMATION enabled=false' \
    || fail "move confirmation did not disable"
  tap_godot_settings_done "$serial" || fail "could not finish Gomoku settings"
  wait_for_log_marker "$serial" 'GAMEBOX_SETTINGS_SHEET visible=false' \
    || fail "Gomoku settings sheet did not close after disabling confirmation"
}

tap_godot_resign() {
  local serial="$1"
  local point x y
  point="$(design_point_for_serial "$serial" 540 1640)"
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
}

tap_godot_confirm_resign() {
  local serial="$1"
  local point x y
  point="$(design_point_for_serial "$serial" 640 1230)"
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
}

capture_resign_confirmation() {
  local serial="$1"
  local before after expected_revision
  before="$(match_show "$MATCH_ID")" || fail "could not read the match before resign confirmation"
  expected_revision="$(jq -er '.revision' <<<"$before")"
  tap_godot_resign "$serial" || fail "could not open the Gomoku resign confirmation"
  sleep 1
  assert_ui_state_safe "$serial" "$SECRETS_ON_UI_A" \
    || fail "could not verify the light resign confirmation UI state"
  adb_for "$serial" shell input keyevent KEYCODE_BACK >/dev/null \
    || fail "Android Back did not close the resign confirmation"
  sleep 1
  after="$(match_show "$MATCH_ID")" || fail "could not read the match after cancelling resign"
  [[ "$(jq -r '.revision' <<<"$after")" == "$expected_revision" \
    && "$(jq -r '.status' <<<"$after")" == "active" ]] \
    || fail "cancelling resign changed the authoritative match"
}

exercise_active_system_back() {
  local serial="$1"
  local expected_revision="$2"
  local before after
  before="$(match_show "$MATCH_ID")" || fail "could not read the active match before Android Back"
  refresh_game_log_boundary "$serial" active-system-back \
    || fail "could not establish active Android Back log boundaries"
  adb_for "$serial" shell input keyevent KEYCODE_BACK >/dev/null \
    || fail "could not send Android Back during the active match"
  wait_for_identifier_after_scroll "$serial" continue-match >/dev/null \
    || fail "active Android Back did not return to a resumable lobby"
  assert_ui_state_safe "$serial" "$SECRETS_ON_UI_A" \
    || fail "could not verify the resumable lobby after Android Back"
  after="$(match_show "$MATCH_ID")" || fail "could not read the active match after Android Back"
  [[ "$(jq -r '.revision' <<<"$after")" == "$expected_revision" \
    && "$(jq -r '.status' <<<"$after")" == "active" \
    && "$(jq -S '.board' <<<"$after")" == "$(jq -S '.board' <<<"$before")" ]] \
    || fail "Android Back changed or discarded the authoritative active match"
  tap_identifier_after_scroll "$serial" continue-match \
    || fail "active match could not be relaunched after Android Back"
  wait_for_log_marker "$serial" "$GAMEBOX_READY_MARKER game=gomoku match=$MATCH_ID" \
    || fail "active match did not relaunch after Android Back"
  wait_for_log_marker "$serial" "$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=$expected_revision status=active connection=connected" \
    || fail "active match did not resynchronize after Android Back"
  assert_both_state_revision "$expected_revision"
}

recover_both_clients_after_server_restart() {
  local expected_revision="$1" serial
  refresh_game_log_boundaries post-server-restart \
    || fail "could not establish post-restart log boundaries"
  for serial in "$SERIAL_A" "$SERIAL_B"; do
    adb_for "$serial" shell am force-stop "$PACKAGE" >/dev/null \
      || fail "could not force-stop only $PACKAGE on $serial after server restart"
    start_flutter "$serial"
    wait_for_identifier_after_scroll "$serial" continue-match >/dev/null \
      || fail "$serial did not expose continue-match after server restart"
    tap_identifier_after_scroll "$serial" continue-match \
      || fail "$serial could not activate continue-match after server restart"
  done
  for serial in "$SERIAL_A" "$SERIAL_B"; do
    wait_for_log_marker "$serial" "$GAMEBOX_READY_MARKER game=gomoku match=$MATCH_ID" \
      || fail "$serial did not relaunch Gomoku after server restart"
    wait_for_log_marker "$serial" "$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=$expected_revision status=active connection=connected" \
      || fail "$serial did not resynchronize revision $expected_revision after server restart"
  done
  assert_both_state_revision "$expected_revision"
}

capture_connection_recovery_states() {
  local expected_revision="$1"
  refresh_game_log_boundaries connection-logic \
    || fail "could not establish connection logic log boundaries"
  pause_e2e_server \
    || fail "could not pause the exact E2E-owned server for reconnect logic"
  wait_for_log_marker_with_timeout \
    "$SERIAL_A" "$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=$expected_revision status=active connection=reconnecting" \
    "$CONNECTION_STATE_TIMEOUT_SECONDS" \
    || fail "A did not enter the real reconnecting state while the E2E server was paused"
  assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A" \
    || fail "could not verify the reconnecting Gomoku UI state"
  stop_e2e_server \
    || fail "could not terminate the exact paused E2E-owned server"
  wait_for_log_marker_with_timeout \
    "$SERIAL_A" "$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=$expected_revision status=active connection=failed" \
    "$CONNECTION_STATE_TIMEOUT_SECONDS" \
    || fail "A did not enter the real connection-failed state"
  assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A" \
    || fail "could not verify the failed Gomoku UI state"
  start_e2e_server \
    || fail "could not restart the E2E-owned server with the same database and secrets"
  wait_for_e2e_server_health \
    || fail "restarted E2E server did not become healthy within ${WAIT_SECONDS}s"
  recover_both_clients_after_server_restart "$expected_revision"
}

exercise_optional_move_confirmation "$BLACK_SERIAL" 3 3 1 1
capture_resign_confirmation "$SERIAL_A"
if [[ "$WHITE_SERIAL" == "$SERIAL_A" ]]; then
  perform_pending_logic_move "$WHITE_SERIAL" 3 5 2 2
else
  perform_move "$WHITE_SERIAL" 3 5 2 2
fi
capture_connection_recovery_states 2
exercise_active_system_back "$SERIAL_A" 2
perform_move "$BLACK_SERIAL" 4 3 3 1
gamebox_test_progress 'Gamebox E2E: validating process recovery and resumed state...'

RECOVERY_SERIAL="$WHITE_SERIAL"
if [[ "$RECOVERY_SERIAL" == "$SERIAL_A" ]]; then
  SURVIVING_SERIAL="$SERIAL_B"
else
  SURVIVING_SERIAL="$SERIAL_A"
fi
refresh_game_log_boundaries presence-recovery \
  || fail "could not establish presence recovery log boundaries"
adb_for "$RECOVERY_SERIAL" shell am force-stop "$PACKAGE" >/dev/null \
  || fail "could not force-stop only $PACKAGE on the recovery device"
wait_for_presence_state "$SURVIVING_SERIAL" "$MATCH_ID" 3 offline \
  || fail "surviving client did not render the force-stopped opponent as offline"
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
tap_identifier_after_scroll "$RECOVERY_SERIAL" continue-match \
  || fail "force-stopped client could not activate the resumable match"
 wait_for_presence_state "$RECOVERY_SERIAL" "$MATCH_ID" -1 unknown \
   || fail "relaunching client did not report unknown presence before its snapshot"
wait_for_log_marker "$RECOVERY_SERIAL" "$GAMEBOX_READY_MARKER game=gomoku match=$MATCH_ID" \
  || fail "force-stopped client did not relaunch Godot"
wait_for_log_marker "$RECOVERY_SERIAL" "$GAMEBOX_STATE_MARKER match=$MATCH_ID revision=3" \
  || fail "force-stopped client did not resume at authoritative revision 3"
wait_for_presence_state "$RECOVERY_SERIAL" "$MATCH_ID" 3 online \
  || fail "relaunching client did not restore the opponent to online"
wait_for_presence_state "$SURVIVING_SERIAL" "$MATCH_ID" 3 online \
  || fail "surviving client did not restore the relaunched opponent to online"
assert_both_state_revision 3

perform_move "$WHITE_SERIAL" 4 5 4 2
perform_move "$BLACK_SERIAL" 5 3 5 1
perform_move "$WHITE_SERIAL" 5 5 6 2
perform_move "$BLACK_SERIAL" 6 3 7 1
perform_move "$WHITE_SERIAL" 6 5 8 2
perform_move "$BLACK_SERIAL" 7 3 9 1

final_snapshot="$(match_show "$MATCH_ID")" || fail "finished match was not readable"
[[ "$(jq -r '.status' <<<"$final_snapshot")" == "finished" \
  && "$(jq -r '.result' <<<"$final_snapshot")" == "five" \
  && "$(jq -r '.winnerUserId' <<<"$final_snapshot")" == "$BLACK_USER_ID" ]] \
  || fail "first match did not finish as a five for black"
for serial in "$SERIAL_A" "$SERIAL_B"; do
  wait_for_log_marker "$serial" "$GAMEBOX_RESULT_MARKER match=$MATCH_ID result=five" \
    || fail "$serial did not report the shared five result"
done
assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A" \
  || fail "could not verify the light terminal Gomoku UI state"

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
gamebox_test_progress 'Gamebox E2E: validating zero-step cancellation and slot release...'
SECOND_MATCH_ID="$(wait_for_new_ready_match_id "$SERIAL_A" "$MATCH_ID")" \
  || fail "A did not emit exactly one second-match ready ID within ${WAIT_SECONDS}s"
[[ "$SECOND_MATCH_ID" =~ $uuid_pattern ]] || fail "second Godot ready marker did not contain a canonical match ID"
tap_identifier "$SERIAL_B" cancel-match
wait_for_identifier "$SERIAL_B" confirm-cancel-match >/dev/null \
  || fail "the second-match cancellation confirmation did not expose its stable identifier"
assert_ui_state_safe "$SERIAL_B" "$SECRETS_ON_UI_B" \
  || fail "could not verify the dark narrow cancellation confirmation UI state"
tap_identifier "$SERIAL_B" confirm-cancel-match
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

refresh_game_log_boundaries third-match \
  || fail "could not establish third-match log boundaries"
tap_identifier "$SERIAL_A" choose-opponent
third_opponent_identifier="$(wait_for_opponent_identifier "$SERIAL_A")" \
  || fail "A could not select B for the resignation match"
[[ "$third_opponent_identifier" == "opponent-$USER_ID_B" ]] \
  || fail "third opponent resource-id did not identify B"
tap_identifier "$SERIAL_A" "$third_opponent_identifier"
THIRD_MATCH_ID="$(wait_for_new_ready_match_id "$SERIAL_A")" \
  || fail "A did not emit exactly one resignation-match ready ID within ${WAIT_SECONDS}s"
[[ "$THIRD_MATCH_ID" =~ $uuid_pattern ]] \
  || fail "resignation-match ready marker did not contain a canonical match ID"
wait_for_identifier_after_scroll "$SERIAL_B" continue-match >/dev/null \
  || fail "B did not expose the resignation match"
tap_identifier_after_scroll "$SERIAL_B" continue-match \
  || fail "B could not activate the narrow resignation match"
wait_for_log_marker "$SERIAL_B" "$GAMEBOX_READY_MARKER game=gomoku match=$THIRD_MATCH_ID" \
  || fail "B did not launch the resignation match"

third_match_json="$(wait_for_match_snapshot "$THIRD_MATCH_ID")" \
  || fail "resignation match was not readable"
third_black_user_id="$(jq -er '.players[] | select(.color == "black") | .userId' <<<"$third_match_json")"
if [[ "$third_black_user_id" == "$USER_ID_A" ]]; then
  THIRD_BLACK_SERIAL="$SERIAL_A"
elif [[ "$third_black_user_id" == "$USER_ID_B" ]]; then
  THIRD_BLACK_SERIAL="$SERIAL_B"
else
  fail "resignation match black player did not map to a registered user"
fi

FIRST_MATCH_ID="$MATCH_ID"
MATCH_ID="$THIRD_MATCH_ID"
assert_both_state_revision 0
perform_move "$THIRD_BLACK_SERIAL" 7 7 1 1
tap_godot_resign "$SERIAL_A" || fail "A could not open resignation confirmation in the resignation match"
sleep 1
tap_godot_confirm_resign "$SERIAL_A" || fail "A could not confirm resignation"
resign_deadline=$((SECONDS + WAIT_SECONDS))
while ((SECONDS < resign_deadline)); do
  resigned_snapshot="$(match_show "$THIRD_MATCH_ID" 2>/dev/null || true)"
  if [[ "$(jq -r '.status // ""' <<<"$resigned_snapshot" 2>/dev/null)" == "finished" \
    && "$(jq -r '.result // ""' <<<"$resigned_snapshot" 2>/dev/null)" == "resignation" \
    && "$(jq -r '.revision // -1' <<<"$resigned_snapshot" 2>/dev/null)" == "2" ]]; then
    break
  fi
  sleep 1
done
if [[ -z "${resigned_snapshot:-}" ]] \
  || ! jq -e --arg resigner "$USER_ID_A" \
    '.status == "finished" and .result == "resignation" and .revision == 2 and .winnerUserId != $resigner' \
    <<<"$resigned_snapshot" >/dev/null; then
  fail "confirmed resignation did not produce exactly one authoritative resignation result"
fi
for serial in "$SERIAL_A" "$SERIAL_B"; do
  wait_for_log_marker "$serial" "$GAMEBOX_RESULT_MARKER match=$THIRD_MATCH_ID result=resignation" \
    || fail "$serial did not observe the authoritative resignation result"
done
assert_ui_state_safe "$SERIAL_A" "$SECRETS_ON_UI_A" \
  || fail "could not verify the authoritative resignation result UI state"
tap_design_back "$SERIAL_A" || fail "A could not leave the resignation result"
tap_design_back "$SERIAL_B" || fail "B could not leave the resignation result"
wait_for_identifier "$SERIAL_A" choose-opponent >/dev/null || fail "A was not idle after resignation"
wait_for_identifier "$SERIAL_B" choose-opponent >/dev/null || fail "B was not idle after resignation"

tap_identifier "$SERIAL_A" open-match-history
wait_for_identifier "$SERIAL_A" match-history-statistics >/dev/null \
  || fail "A history statistics did not load"
wait_for_identifier "$SERIAL_A" "match-history-entry-$THIRD_MATCH_ID" >/dev/null \
  || fail "A history did not include the authoritative resignation match"
tap_identifier "$SERIAL_A" match-history-back
wait_for_identifier "$SERIAL_A" choose-opponent >/dev/null \
  || fail "visible history Back did not return A to the idle lobby"

tap_identifier "$SERIAL_A" open-match-history
wait_for_identifier "$SERIAL_A" match-history-page >/dev/null \
  || fail "A history page did not reopen"
adb_for "$SERIAL_A" shell input keyevent KEYCODE_BACK >/dev/null \
  || fail "could not send Android Back from history"
wait_for_identifier "$SERIAL_A" choose-opponent >/dev/null \
  || fail "Android Back did not return A to the idle lobby"
MATCH_ID="$FIRST_MATCH_ID"

restore_selected_device_visuals \
  || fail "could not restore both selected devices to their original ui mode and display override"
[[ "$UI_MODE_MUTATED_A" == "0" && "$UI_MODE_MUTATED_B" == "0" \
  && "$DISPLAY_MUTATED_A" == "0" && "$DISPLAY_MUTATED_B" == "0" \
  && "$DENSITY_MUTATED_A" == "0" && "$DENSITY_MUTATED_B" == "0" ]] \
  || fail "device visual restoration left a tracked mutation active"

SOURCE_REVISION_END="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_STATUS_END="$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=normal)"
provenance_contract \
  "$SOURCE_REVISION_START" "$SOURCE_STATUS_START" "$SOURCE_REVISION_END" "$SOURCE_STATUS_END" \
  || fail "source HEAD or worktree cleanliness changed after build"

printf '%s\n' "$final_snapshot" | jq -S . >"$ARTIFACT_DIR/final-match.json"
sanitize_stream <"$SERVER_LOG" >"$ARTIFACT_DIR/server-sanitized.log"
sanitize_stream <"$SEMANTICS_LOG" >"$ARTIFACT_DIR/semantics-test.log"
if ! protect_artifact_directory \
  "$ARTIFACT_DIR" "$TEMP_DIR/success-artifact-scan.txt" \
  "$INVITE_A" "$INVITE_B" "$JWT_SECRET" "$TOKEN_PEPPER"; then
  fail "artifact secret scanner removed unsafe or unverifiable output"
fi
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
  --arg thirdMatchId "$THIRD_MATCH_ID" \
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
    thirdMatch:{id:$thirdMatchId,revision:2,status:"finished",result:"resignation",slotsReleased:true},
    assertions:[
      "resource-id-only-ui-driving","two-registered-users","random-color-mapping",
      "revision-and-board-after-each-move","dual-device-state-markers",
      "force-stop-auto-login-resume","shared-five-result","lobby-idle",
      "second-match-created","cancel-confirmed-once","zero-step-cancelled","slots-released",
      "active-system-back-resumable","confirmed-resignation-once","authoritative-resignation-result",
      "pending-before-authoritative-ack","real-reconnecting-and-failed-states",
      "optional-move-confirmation-enable-cancel-confirm-disable",
      "presence-online-offline-unknown-restored-online",
      "exact-owned-server-pause-stop-restart","ui-mode-and-display-restored",
      "selected-device-semantics-integration","clean-build-provenance",
      "installed-apk-sha256-equality"
    ]
  }' >"$ARTIFACT_DIR/summary.json"

if ! protect_artifact_directory \
  "$ARTIFACT_DIR" "$TEMP_DIR/final-success-artifact-scan.txt" \
  "$INVITE_A" "$INVITE_B" "$JWT_SECRET" "$TOKEN_PEPPER"; then
  fail "artifact secret scanner removed unsafe or unverifiable output"
fi

warning_count="$(gamebox_test_output_warning_count)"
if ((warning_count > 0)); then
  printf 'Gamebox two-emulator E2E passed (%s warning lines). Artifacts: %s\n' \
    "$warning_count" "$ARTIFACT_DIR"
else
  printf 'Gamebox two-emulator E2E passed. Artifacts: %s\n' "$ARTIFACT_DIR"
fi

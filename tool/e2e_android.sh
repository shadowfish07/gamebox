#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="me.zqydev.gamebox"
readonly MAIN_ACTIVITY="$PACKAGE/.MainActivity"
readonly TEST_PACKAGE="$PACKAGE.test"
readonly TEST_RUNNER="$TEST_PACKAGE/me.zqydev.gamebox.HostSmokeTestRunner"
readonly SET_TEXT_TEST="me.zqydev.gamebox.E2eSetTextTest#setApprovedFieldFromBase64WithoutEchoingValue"
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR

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
  if rg --text --fixed-strings -- "$value" "$file" >/dev/null 2>&1; then
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
    if rg --text --files-with-matches --fixed-strings -- "$value" "$directory" >"$scratch" 2>/dev/null; then
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
    if rg --text --fixed-strings -- "$value" "$directory" >/dev/null 2>&1; then
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

self_test() {
  local fixture_dir
  fixture_dir="$(mktemp -d)"
  trap 'rm -rf "$fixture_dir"' RETURN
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
  printf 'Gamebox E2E parser fixtures passed.\n'
}

if ((SELF_TEST_ONLY)); then
  self_test
  exit 0
fi

for required_command in adb curl ffmpeg git go jq lsof openssl rg ruby sed shasum unzip; do
  command -v "$required_command" >/dev/null 2>&1 \
    || { printf 'Gamebox E2E failed: missing required command %s\n' "$required_command" >&2; exit 2; }
done
command -v flutter >/dev/null 2>&1 \
  || { printf 'Gamebox E2E failed: flutter is not available on PATH\n' >&2; exit 2; }

umask 077
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly RUN_ID
TEMP_DIR="$(mktemp -d)"
readonly TEMP_DIR
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
LEASE_OWNED=0
LEASE_DIR=""
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

adb_for() {
  local serial="$1"
  shift
  adb -s "$serial" "$@"
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
  local pid deadline
  adb -s "$serial" uninstall "$TEST_PACKAGE" >/dev/null 2>&1 &
  pid=$!
  deadline=$((SECONDS + 5))
  while ((SECONDS < deadline)) && kill -0 "$pid" 2>/dev/null; do
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null \
    && owned_process_matches "$pid" "adb -s $serial uninstall $TEST_PACKAGE"; then
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$((SECONDS + 3))
    while ((SECONDS < deadline)) && kill -0 "$pid" 2>/dev/null; do
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null \
      && owned_process_matches "$pid" "adb -s $serial uninstall $TEST_PACKAGE"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM ERR
  set +e
  if [[ -n "$SERIAL_A" ]]; then
    bounded_helper_uninstall "$SERIAL_A"
  fi
  if [[ -n "$SERIAL_B" ]]; then
    bounded_helper_uninstall "$SERIAL_B"
  fi
  stop_owned_process "$SERVER_PID" "$SERVER_BIN" 10
  ((STARTED_B)) && stop_owned_process "$EMULATOR_PID_B" "-avd $MANAGED_AVD_B" 20
  ((STARTED_A)) && stop_owned_process "$EMULATOR_PID_A" "-avd $MANAGED_AVD_A" 20
  if ((LEASE_OWNED)) && [[ -f "$LEASE_DIR/owner" ]] \
    && grep -Fx "$RUN_ID" "$LEASE_DIR/owner" >/dev/null 2>&1; then
    rm -f "$LEASE_DIR/owner"
    rmdir "$LEASE_DIR" 2>/dev/null || true
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

common_dir="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
  || git -C "$ROOT_DIR" rev-parse --git-common-dir)"
if [[ "$common_dir" != /* ]]; then
  common_dir="$(cd "$ROOT_DIR" && cd "$common_dir" && pwd)"
fi
LEASE_DIR="$common_dir/gamebox-android-e2e.lease"
if ! mkdir "$LEASE_DIR" 2>/dev/null; then
  fail "the shared Android E2E lease is held at $LEASE_DIR"
fi
printf '%s\n' "$RUN_ID" >"$LEASE_DIR/owner"
LEASE_OWNED=1

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
  local serial
  while read -r serial _; do
    [[ "$serial" == emulator-* ]] || continue
    if [[ "$(adb_for "$serial" shell getprop ro.boot.qemu.avd_name 2>/dev/null | tr -d '\r')" == "$avd_name" ]]; then
      fail "$avd_name is already running as $serial; refusing to reuse or stop it"
    fi
  done < <(adb devices | tail -n +2)
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
  bash "$ROOT_DIR/tool/ensure_test_avds.sh"
  STARTED_A=1
  start_managed_emulator A "$MANAGED_AVD_A" "$MANAGED_PORT_A" EMULATOR_PID_A SERIAL_A
  STARTED_B=1
  start_managed_emulator B "$MANAGED_AVD_B" "$MANAGED_PORT_B" EMULATOR_PID_B SERIAL_B
fi
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
  ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a ./gradlew :app:assembleDebugAndroidTest
)
TEST_APK="$ROOT_DIR/app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
readonly TEST_APK
[[ -f "$TEST_APK" ]] || fail "E2E-owned UI Automator helper APK was not produced"
(
  cd "$ROOT_DIR/app"
  ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a flutter build apk \
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
(
  cd "$ROOT_DIR/server"
  go build -o "$SERVER_BIN" ./cmd/gameboxd
  go build -o "$CTL_BIN" ./cmd/gameboxctl
)

install_app() {
  local serial="$1"
  if adb_for "$serial" shell pm path "$PACKAGE" 2>/dev/null | grep -q '^package:'; then
    adb_for "$serial" shell pm clear "$PACKAGE" >/dev/null \
      || fail "could not clear only $PACKAGE on $serial before install"
  fi
  adb_for "$serial" install --streaming -r "$APK" >/dev/null \
    || fail "APK installation failed on $serial"
  adb_for "$serial" install --streaming -r -t "$TEST_APK" >/dev/null \
    || fail "E2E-owned UI Automator helper installation failed on $serial"
  adb_for "$serial" shell pm clear "$PACKAGE" >/dev/null \
    || fail "could not clear only $PACKAGE on $serial after install"
}
install_app "$SERIAL_A"
install_app "$SERIAL_B"

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
  local remote="/data/local/tmp/gamebox-e2e-$RUN_ID.xml"
  adb_for "$serial" shell uiautomator dump --compressed "$remote" >/dev/null 2>&1 || return 1
  adb_for "$serial" pull "$remote" "$local_path" >/dev/null 2>&1 || return 1
  adb_for "$serial" shell rm -f "$remote" >/dev/null 2>&1 || true
  [[ -s "$local_path" ]]
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
  local encoded output
  encoded="$(printf '%s' "$value" | openssl base64 -A)"
  output="$(
    adb_for "$serial" shell am instrument -w -r \
      -e class "$SET_TEXT_TEST" \
      -e gameboxTextTarget "$identifier" \
      -e gameboxTextValueBase64 "$encoded" \
      "$TEST_RUNNER" 2>&1
  )" || {
    printf '%s\n' "$output" | sanitize_stream >&2
    fail "UI Automator helper could not set resource-id $identifier on $serial"
  }
  if ! grep -F 'OK (1 test)' <<<"$output" >/dev/null \
    || grep -E 'FAILURES!!!|Process crashed|INSTRUMENTATION_FAILED' <<<"$output" >/dev/null; then
    printf '%s\n' "$output" | sanitize_stream >&2
    fail "UI Automator helper did not confirm resource-id $identifier on $serial"
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

printf '%s\n' "$final_snapshot" | jq -S . >"$ARTIFACT_DIR/final-match.json"
cp "$VISUAL_METRICS" "$ARTIFACT_DIR/visual-metrics.tsv"
sanitize_stream <"$SERVER_LOG" >"$ARTIFACT_DIR/server-sanitized.log"
sanitize_stream <"$SEMANTICS_LOG" >"$ARTIFACT_DIR/semantics-test.log"
source_revision="$(git -C "$ROOT_DIR" rev-parse HEAD)"
devices_json="$(device_summary_json "$SERIAL_A" "$SERIAL_B" "$API_LEVEL_A" "$API_LEVEL_B" "$api_base")"
jq -n \
  --arg status passed \
  --arg sourceRevision "$source_revision" \
  --argjson devices "$devices_json" \
  --arg matchId "$MATCH_ID" \
  --arg secondMatchId "$SECOND_MATCH_ID" \
  --arg recoverySerial "$RECOVERY_SERIAL" \
  --argjson recoveryBefore 3 \
  --argjson recoveryAfter 3 \
  '{
    status:$status,
    sourceRevision:$sourceRevision,
    devices:$devices,
    firstMatch:{id:$matchId,revisions:[0,1,2,3,4,5,6,7,8,9],status:"finished",result:"five"},
    recovery:{serial:$recoverySerial,beforeRevision:$recoveryBefore,afterRevision:$recoveryAfter,eventLoss:false},
    secondMatch:{id:$secondMatchId,revision:1,status:"cancelled",slotsReleased:true},
    assertions:[
      "resource-id-only-ui-driving","two-registered-users","random-color-mapping",
      "revision-and-board-after-each-move","two-authoritative-board-crops-with-ssim",
      "force-stop-auto-login-resume","shared-five-result","lobby-idle",
      "second-match-created","zero-step-cancelled","slots-released",
      "selected-device-semantics-integration"
    ]
  }' >"$ARTIFACT_DIR/summary.json"

if ! protect_artifact_directory \
  "$ARTIFACT_DIR" "$TEMP_DIR/success-artifact-scan.txt" \
  "$INVITE_A" "$INVITE_B" "$JWT_SECRET" "$TOKEN_PEPPER"; then
  fail "artifact secret scanner removed unsafe or unverifiable output"
fi

printf 'Gamebox two-emulator E2E passed. Artifacts: %s\n' "$ARTIFACT_DIR"

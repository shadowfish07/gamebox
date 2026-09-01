#!/usr/bin/env bash
set -Eeuo pipefail

readonly PACKAGE=me.zqydev.gamebox
readonly TEST_PACKAGE=me.zqydev.gamebox.test
readonly MAIN_ACTIVITY="$PACKAGE/.MainActivity"
readonly APP_TEST_RUNNER="$TEST_PACKAGE/androidx.test.runner.AndroidJUnitRunner"
readonly HELPER_TEST_RUNNER="$TEST_PACKAGE/me.zqydev.gamebox.HostSmokeTestRunner"
readonly AVD_A=Gamebox_A_API_36
readonly AVD_B=Gamebox_B_API_36
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly RUN_ID
readonly ARTIFACT_DIR="$ROOT_DIR/artifacts/e2e-lan-android/$RUN_ID"
TEMP_DIR="$(mktemp -d -t gamebox-lan-e2e.XXXXXX)"
readonly TEMP_DIR
ADB_BIN="${GAMEBOX_E2E_ADB_BIN:-adb}"
VERBOSE=0
SELF_TEST=0
SERIAL_A="${GAMEBOX_E2E_SERIAL_A:-}"
SERIAL_B="${GAMEBOX_E2E_SERIAL_B:-}"
EMULATOR_PID_A=""
EMULATOR_PID_B=""
FORWARDED_PORT=""
ROOM_ID=""
SENSITIVE_UI=0
WARNING_COUNT=0

# shellcheck source=tool/lib/android_lease.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/tool/lib/android_lease.sh"

while (($#)); do
  case "$1" in
    --self-test) SELF_TEST=1 ;;
    --verbose) VERBOSE=1 ;;
    *) printf 'usage: %s [--self-test] [--verbose]\n' "$0" >&2; exit 2 ;;
  esac
  shift
done

log() { ((VERBOSE == 1)) && printf '[lan-e2e] %s\n' "$*" || true; }
sanitize_log() {
  sed -E \
    -e 's/(roomKey|launchTicket|resumeToken|accessToken|refreshToken)([=:])[[:space:]]*[^[:space:],}"&]+/\1\2[REDACTED]/g' \
    -e 's/[A-Za-z0-9_-]{43}/[REDACTED_CREDENTIAL]/g'
}
capture_phase() {
  local log_file="$1"
  shift
  local status warning_count
  set +e
  if ((VERBOSE == 1)); then
    "$@" 2>&1 | tee "$log_file"
    status=${PIPESTATUS[0]}
  else
    "$@" >"$log_file" 2>&1
    status=$?
  fi
  set -e
  warning_count="$(grep -Eic '(^|[[:space:]])(warning:|warning |warnings:|w: )' "$log_file" 2>/dev/null || true)"
  WARNING_COUNT=$((WARNING_COUNT + ${warning_count:-0}))
  return "$status"
}
print_phase_failure() {
  local phase="$1" log_file="$2"
  printf 'Failed phase: %s\n' "$phase" >&2
  tail -200 "$log_file" | sanitize_log >&2
}
run_required_phase() {
  local phase="$1" log_file="$2"
  shift 2
  local status
  if capture_phase "$log_file" "$@"; then return 0; else status=$?; fi
  mkdir -p "$ARTIFACT_DIR"
  cp "$log_file" "$ARTIFACT_DIR/failed-phase.log" 2>/dev/null || true
  print_phase_failure "$phase" "$log_file"
  fail "$phase failed" "$status"
}
fail() {
  local message="$1"
  local exit_code="${2:-1}"
  mkdir -p "$ARTIFACT_DIR"
  jq -n --arg status failure --arg message "$message" --arg serialA "$SERIAL_A" --arg serialB "$SERIAL_B" \
    '{status:$status,message:$message,serials:[$serialA,$serialB]}' >"$ARTIFACT_DIR/summary.json" 2>/dev/null || true
  if ((SENSITIVE_UI == 0)) && declare -F dump_ui >/dev/null 2>&1; then
    local serial label xml
    for label in A B; do
      [[ "$label" == A ]] && serial="$SERIAL_A" || serial="$SERIAL_B"
      [[ -n "$serial" ]] || continue
      adb_for "$serial" exec-out screencap -p >"$ARTIFACT_DIR/failure-$label.png" 2>/dev/null || true
      xml="$TEMP_DIR/failure-$label.xml"
      if dump_ui "$serial" "$xml"; then
        ruby -rrexml/document -e '
          doc=REXML::Document.new(File.binread(ARGV[0]))
          REXML::XPath.each(doc,"//node") do |node|
            id=node.attributes["resource-id"].to_s
            text=node.attributes["text"].to_s
            desc=node.attributes["content-desc"].to_s
            next if id.empty? && text.empty? && desc.empty?
            puts "id=#{id.empty? ? "-" : id} text=#{text.empty? ? "-" : text} desc=#{desc.empty? ? "-" : desc}"
          end
        ' "$xml" >"$ARTIFACT_DIR/failure-$label-ui.txt" 2>/dev/null || true
      fi
      adb_for "$serial" logcat -d -v brief 2>/dev/null \
        | grep -E 'AndroidRuntime|FATAL EXCEPTION|flutter[^a-zA-Z]|Gamebox' \
        | tail -200 >"$ARTIFACT_DIR/failure-$label-crash.log" || true
    done
  fi
  local serial label
  for label in A B; do
    [[ "$label" == A ]] && serial="$SERIAL_A" || serial="$SERIAL_B"
    [[ -n "$serial" ]] || continue
    adb_for "$serial" logcat -d -v brief 2>/dev/null \
      | grep -E 'GAMEBOX_(GODOT_STATE|GODOT_READY|MATCH_RESULT|HISTORY_RECOVERY|RESULT_PERSIST|RESULT_BRIDGE)|AndroidRuntime.*FATAL EXCEPTION' \
      | tail -300 >"$ARTIFACT_DIR/failure-$label-runtime.log" || true
    if declare -F dump_safe_ui_ids >/dev/null 2>&1; then
      dump_safe_ui_ids "$serial" "$ARTIFACT_DIR/failure-$label-ui-ids.txt" || true
    fi
  done
  printf 'Gamebox LAN E2E failed: %s\nArtifacts: %s\n' "$message" "$ARTIFACT_DIR" >&2
  exit "$exit_code"
}
unexpected_error() {
  local exit_code="$1" line="$2"
  trap - ERR
  fail "unexpected harness command failure at line $line (exit $exit_code)" "$exit_code"
}
trap 'unexpected_error "$?" "$LINENO"' ERR
adb_for() { "$ADB_BIN" -s "$1" "${@:2}"; }
run_instrumentation() {
  local serial="$1" log_file="$2" runner="$3"
  shift 3
  local raw_log status
  raw_log="$TEMP_DIR/raw-$(basename "$log_file")"
  set +e
  adb_for "$serial" shell am instrument -w -r "$@" "$runner" >"$raw_log" 2>&1
  status=$?
  set -e
  cp "$raw_log" "$log_file"
  cat "$log_file"
  ((status == 0)) || return "$status"
  grep -F 'OK (1 test)' "$log_file" >/dev/null \
    && ! grep -E 'FAILURES!!!|Process crashed|INSTRUMENTATION_FAILED' "$log_file" >/dev/null
}

cleanup() {
  local exit_code=$?
  set +e
  [[ -z "$FORWARDED_PORT" || -z "$SERIAL_A" ]] || adb_for "$SERIAL_A" forward --remove "tcp:$FORWARDED_PORT" >/dev/null 2>&1
  [[ -z "$SERIAL_A" ]] || adb_for "$SERIAL_A" shell am force-stop "$PACKAGE" >/dev/null 2>&1
  [[ -z "$SERIAL_B" ]] || adb_for "$SERIAL_B" shell am force-stop "$PACKAGE" >/dev/null 2>&1
  [[ -z "$EMULATOR_PID_A" ]] || kill "$EMULATOR_PID_A" >/dev/null 2>&1
  [[ -z "$EMULATOR_PID_B" ]] || kill "$EMULATOR_PID_B" >/dev/null 2>&1
  find "$TEMP_DIR" -depth -delete >/dev/null 2>&1
  gamebox_android_lease_release >/dev/null 2>&1
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

validate_serial_pair() {
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ && "$2" =~ ^[A-Za-z0-9._:-]+$ && "$1" != "$2" ]]
}

parse_forward_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  ((10#$1 <= 65535)) || return 1
  printf '%s\n' "$1"
}

scan_artifacts() {
  local directory="$1"
  local scan_status
  [[ -d "$directory" ]] || return 1
  if LC_ALL=C grep -E -a -i -n -r -- \
    'gamebox-lan://[^[:space:]]*\?(.*(key|roomKey|launchTicket|resumeToken|accessToken|refreshToken)=)|(^|[^A-Za-z0-9_-])[A-Za-z0-9_-]{43}([^A-Za-z0-9_-]|$)|"(roomKey|launchTicket|resumeToken|accessToken|refreshToken)"' \
    "$directory" >/dev/null 2>&1; then
    return 1
  else
    scan_status=$?
  fi
  ((scan_status == 1)) && return 0
  printf 'Artifact credential scan failed with exit %s.\n' "$scan_status" >&2
  return "$scan_status"
}

extract_json_stream() {
  local maximum_bytes="$1" output="$2"
  ruby -e '
    maximum = Integer(ARGV[0], 10)
    output = ARGV[1]
    data = STDIN.read
    exit 2 if data.bytesize > maximum + 65_536
    index = 0
    index += 1 while index < data.bytesize && [9, 10, 13, 32].include?(data.getbyte(index))
    exit 2 unless data.getbyte(index) == 123
    start = index
    depth = 0
    in_string = false
    escaped = false
    finish = nil
    while index < data.bytesize
      byte = data.getbyte(index)
      if in_string
        if escaped
          escaped = false
        elsif byte == 92
          escaped = true
        elsif byte == 34
          in_string = false
        end
      elsif byte == 34
        in_string = true
      elsif byte == 123 || byte == 91
        depth += 1
      elsif byte == 125 || byte == 93
        depth -= 1
        exit 2 if depth < 0
        if depth == 0
          finish = index + 1
          break
        end
      end
      index += 1
    end
    exit 2 if finish.nil? || in_string || finish - start > maximum
    File.binwrite(output, data.byteslice(start, finish - start))
  ' "$maximum_bytes" "$output"
}

bounded_wait_pid() {
  local pid="$1" deadline=$((SECONDS + $2))
  while kill -0 "$pid" 2>/dev/null; do
    ((SECONDS < deadline)) || return 124
    sleep 0.05
  done
}

run_self_test() {
  local fake="$ROOT_DIR/tool/fixtures/e2e_lan_fake_adb.sh"
  chmod +x "$fake"
  validate_serial_pair fixture-A fixture-B
  if validate_serial_pair fixture-A fixture-A; then return 1; fi
  local port
  port="$($fake -s fixture-A forward tcp:0 tcp:49321)"
  [[ "$(parse_forward_port "$port")" == 38117 ]]
  if parse_forward_port 0 >/dev/null; then return 1; fi
  if parse_forward_port 70000 >/dev/null; then return 1; fi
  local safe="$TEMP_DIR/safe" unsafe="$TEMP_DIR/unsafe"
  mkdir -p "$safe" "$unsafe"
  printf '{"status":"passed","roomId":"11111111-1111-4111-8111-111111111111"}\n' >"$safe/summary.json"
  scan_artifacts "$safe"
  printf 'resumeToken=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' >"$unsafe/log.txt"
  local unsafe_scan_status=0
  scan_artifacts "$unsafe" || unsafe_scan_status=$?
  [[ "$unsafe_scan_status" == 1 ]]
  printf ' {"value":"escaped \\" brace }","nested":[1,{"ok":true}]}transport-noise' \
    | extract_json_stream 128 "$TEMP_DIR/extracted.json"
  jq -e '.nested[1].ok == true' "$TEMP_DIR/extracted.json" >/dev/null
  if printf '{"truncated":' | extract_json_stream 128 "$TEMP_DIR/truncated.json"; then return 1; fi
  local child_marker="$TEMP_DIR/child-stopped" child_ready="$TEMP_DIR/child-ready"
  (trap 'printf stopped >"$child_marker"; exit 143' TERM; printf ready >"$child_ready"; while :; do sleep 1; done) &
  local child=$!
  while [[ ! -f "$child_ready" ]]; do sleep 0.01; done
  kill -TERM "$child"
  wait "$child" 2>/dev/null || true
  [[ -f "$child_marker" ]]
  (sleep 5) &
  local timeout_child=$! timeout_code
  if bounded_wait_pid "$timeout_child" 1; then
    timeout_code=0
  else
    timeout_code=$?
  fi
  kill "$timeout_child" >/dev/null 2>&1 || true
  wait "$timeout_child" 2>/dev/null || true
  [[ "$timeout_code" == 124 ]]
  local phase_log="$TEMP_DIR/self-test-phase.log" phase_output="$TEMP_DIR/self-test-output.log"
  WARNING_COUNT=0
  VERBOSE=0
  capture_phase "$phase_log" bash -c 'printf "warning: outer\\nw: nested\\n"'
  [[ "$WARNING_COUNT" == 2 ]]
  capture_phase "$phase_log" bash -c 'printf compact-output'
  [[ "$(cat "$phase_log")" == compact-output ]]
  VERBOSE=1
  capture_phase "$phase_log" bash -c 'printf verbose-output' >"$phase_output"
  grep -F verbose-output "$phase_output" >/dev/null
  VERBOSE=0
  local preserved_status
  if capture_phase "$phase_log" bash -c 'printf diagnostic-output; exit 37'; then
    preserved_status=0
  else
    preserved_status=$?
  fi
  [[ "$preserved_status" == 37 ]]
  print_phase_failure self-test "$phase_log" 2>"$phase_output"
  grep -F 'Failed phase: self-test' "$phase_output" >/dev/null
  grep -F diagnostic-output "$phase_output" >/dev/null
  printf 'Gamebox LAN E2E self-test passed (compact, diagnostics, warnings, verbose, exit status, serials, forwarding, timeout, cleanup, redaction).\n'
}

if ((SELF_TEST == 1)); then
  run_self_test
  exit 0
fi

mkdir -p "$ARTIFACT_DIR"
if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  export JAVA_HOME
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi

gamebox_android_lease_acquire "$ROOT_DIR" "$AVD_A,$AVD_B LAN E2E" "${GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS:-900}" \
  || fail 'could not acquire the shared Android lease'

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
emulator_bin="$sdk_root/emulator/emulator"

wait_boot() {
  local serial="$1" deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    [[ "$(adb_for "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && return 0
    sleep 1
  done
  return 1
}

if [[ -z "$SERIAL_A" && -z "$SERIAL_B" ]]; then
  bash "$ROOT_DIR/tool/ensure_test_avds.sh" >/dev/null
  "$emulator_bin" -avd "$AVD_A" -port 5560 -no-snapshot-save -no-window -no-audio -no-boot-anim >"$TEMP_DIR/emulator-a.log" 2>&1 &
  EMULATOR_PID_A=$!
  "$emulator_bin" -avd "$AVD_B" -port 5562 -no-snapshot-save -no-window -no-audio -no-boot-anim >"$TEMP_DIR/emulator-b.log" 2>&1 &
  EMULATOR_PID_B=$!
  SERIAL_A=emulator-5560
  SERIAL_B=emulator-5562
  wait_boot "$SERIAL_A" || fail "$AVD_A did not boot"
  wait_boot "$SERIAL_B" || fail "$AVD_B did not boot"
elif [[ -z "$SERIAL_A" || -z "$SERIAL_B" ]]; then
  fail 'provide both GAMEBOX_E2E_SERIAL_A and GAMEBOX_E2E_SERIAL_B'
fi
validate_serial_pair "$SERIAL_A" "$SERIAL_B" || fail 'invalid or duplicate device serials'
[[ "$(adb_for "$SERIAL_A" get-state)" == device && "$(adb_for "$SERIAL_B" get-state)" == device ]] || fail 'selected devices are unavailable'

log 'building one arm64 debug APK and instrumentation APK'
build_android_test() {
  (cd "$ROOT_DIR/app/android" && ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a ./gradlew :app:assembleDebugAndroidTest)
}
build_debug_app() {
  (cd "$ROOT_DIR/app" && ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a flutter build apk --debug --target-platform=android-arm64 --dart-define=GAMEBOX_SCREENSHOT_PRIVACY=true)
}
run_required_phase androidTest-build "$TEMP_DIR/build-test.log" build_android_test
run_required_phase debug-APK-build "$TEMP_DIR/build-app.log" build_debug_app
readonly APK="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-debug.apk"
readonly TEST_APK="$ROOT_DIR/app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
[[ -f "$APK" && -f "$TEST_APK" ]] || fail 'built APKs are missing'
APK_HASH="$(shasum -a 256 "$APK" | awk '{print $1}')"

for serial in "$SERIAL_A" "$SERIAL_B"; do
  adb_for "$serial" install -r -t "$APK" >/dev/null || fail "app install failed on $serial"
  adb_for "$serial" install -r -t "$TEST_APK" >/dev/null || fail "test install failed on $serial"
  adb_for "$serial" shell pm clear "$PACKAGE" >/dev/null || fail "app reset failed on $serial"
  adb_for "$serial" logcat -c
done

run_required_phase device-result-durability "$TEMP_DIR/result-bridge.log" run_instrumentation "$SERIAL_A" "$TEMP_DIR/result-bridge-instrumentation.log" \
  "$APP_TEST_RUNNER" \
  -e class me.zqydev.gamebox.GameResultBridgeTest
adb_for "$SERIAL_A" shell pm clear "$PACKAGE" >/dev/null || fail "post-test app reset failed on $SERIAL_A"

dump_ui() {
  local serial="$1" output="$2" remote=/data/local/tmp/gamebox-lan-ui.xml
  adb_for "$serial" shell uiautomator dump "$remote" >/dev/null 2>&1 || return 1
  adb_for "$serial" exec-out cat "$remote" >"$output"
}

dump_safe_ui_ids() {
  local serial="$1" output="$2" xml="$TEMP_DIR/safe-ui-${1//[^A-Za-z0-9]/_}.xml"
  dump_ui "$serial" "$xml" || return 1
  ruby -rrexml/document -e '
    doc=REXML::Document.new(File.binread(ARGV[0]))
    REXML::XPath.each(doc,"//node") do |node|
      id=node.attributes["resource-id"].to_s
      next if id.empty?
      enabled=node.attributes["enabled"].to_s
      visible=node.attributes["visible-to-user"].to_s
      bounds=node.attributes["bounds"].to_s
      puts "id=#{id} enabled=#{enabled} visible=#{visible} bounds=#{bounds}"
    end
  ' "$xml" >"$output"
}

read_private_file() {
  local serial="$1" relative_path="$2" output="$3" maximum_bytes="$4"
  adb_for "$serial" exec-out run-as "$PACKAGE" cat "$relative_path" 2>/dev/null \
    | extract_json_stream "$maximum_bytes" "$output"
}

wait_forward_listener() {
  local port="$1" deadline=$((SECONDS + 20)) status
  while ((SECONDS < deadline)); do
    status="$(curl --max-time 2 --silent --output /dev/null --write-out '%{http_code}' \
      "http://127.0.0.1:$port/" 2>/dev/null || true)"
    [[ "$status" == 404 ]] && return 0
    sleep 1
  done
  return 1
}

node_center() {
  # The Ruby program is intentionally single-quoted; Bash must not expand it.
  # shellcheck disable=SC2016
  ruby -rrexml/document -e '
    doc=REXML::Document.new(File.read(ARGV[0])); key=ARGV[1]
    nodes=[]; REXML::XPath.each(doc,"//node") { |n| nodes << n if n.attributes["resource-id"]==key && n.attributes["enabled"]=="true" }
    exit 1 unless nodes.length==1 && nodes[0].attributes["bounds"] =~ /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/
    puts "#{($1.to_i+$3.to_i)/2} #{($2.to_i+$4.to_i)/2}"
  ' "$1" "$2"
}

wait_id() {
  local serial="$1" id="$2" center
  local xml="$TEMP_DIR/ui-${serial//[^A-Za-z0-9]/_}.xml" deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    if dump_ui "$serial" "$xml" && center="$(node_center "$xml" "$id" 2>/dev/null)"; then printf '%s\n' "$center"; return 0; fi
    sleep 1
  done
  return 1
}

has_id() {
  local serial="$1" id="$2" xml="$TEMP_DIR/has-${1//[^A-Za-z0-9]/_}.xml"
  dump_ui "$serial" "$xml" && node_center "$xml" "$id" >/dev/null 2>&1
}

dismiss_one_wait_dialog() {
  local serial="$1" xml="$TEMP_DIR/wait-dialog-${1//[^A-Za-z0-9]/_}.xml" point x y
  dump_ui "$serial" "$xml" || return 1
  point="$(node_center "$xml" android:id/aerr_wait 2>/dev/null)" || return 1
  read -r x y <<<"$point"
  adb_for "$serial" shell input tap "$x" "$y" >/dev/null
  sleep 3
}

return_to_home() {
  local serial="$1" attempt
  for attempt in 1 2 3; do
    has_id "$serial" open-match-history && return 0
    adb_for "$serial" shell input keyevent BACK >/dev/null || return 1
    sleep 1
  done
  has_id "$serial" open-match-history
}

reveal_id() {
  local serial="$1" id="$2" xml center size width height x start_y end_y attempt=0
  xml="$TEMP_DIR/reveal-${serial//[^A-Za-z0-9]/_}.xml"
  size="$(adb_for "$serial" shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)"
  read -r width height <<<"$size"
  [[ "$width" =~ ^[1-9][0-9]*$ && "$height" =~ ^[1-9][0-9]*$ ]] || return 1
  x=$((width / 2)); start_y=$((height * 3 / 4)); end_y=$((height / 4))
  while ((attempt < 5)); do
    attempt=$((attempt + 1))
    if dump_ui "$serial" "$xml" && center="$(node_center "$xml" "$id" 2>/dev/null)"; then
      printf '%s\n' "$center"
      return 0
    fi
    adb_for "$serial" shell input swipe "$x" "$start_y" "$x" "$end_y" 250 >/dev/null || return 1
    sleep 1
  done
  return 1
}

tap_id() {
  local point x y
  point="$(wait_id "$1" "$2")" || fail "$2 was not available on $1"
  read -r x y <<<"$point"
  adb_for "$1" shell input tap "$x" "$y" >/dev/null
}

stage_test_input() {
  local serial="$1" name="$2"
  adb_for "$serial" shell "run-as $TEST_PACKAGE sh -c 'umask 077; cat > /data/user/0/$TEST_PACKAGE/$name && chmod 600 /data/user/0/$TEST_PACKAGE/$name'"
}

set_nickname() {
  local serial="$1" nickname="$2"
  local name="gamebox-e2e-input-$RUN_ID-${serial//[^A-Za-z0-9]/}"
  adb_for "$serial" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
  if ! wait_id "$serial" local-nickname >/dev/null; then
    dismiss_one_wait_dialog "$serial" || fail "nickname field missing on $serial"
    adb_for "$serial" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
    wait_id "$serial" local-nickname >/dev/null || fail "nickname field missing after one system wait recovery on $serial"
  fi
  printf '%s' "$nickname" | stage_test_input "$serial" "$name"
  run_required_phase "nickname-injection-$serial" "$TEMP_DIR/nickname-${serial}.log" run_instrumentation "$serial" "$TEMP_DIR/nickname-${serial}-instrumentation.log" \
    "$HELPER_TEST_RUNNER" \
    -e class 'me.zqydev.gamebox.E2eSetTextTest#setApprovedFieldFromPrivateInputWithoutEchoingValue' \
    -e gameboxTextTarget local-nickname -e gameboxTextInputName "$name"
  tap_id "$serial" save-nickname
  wait_id "$serial" open-match-history >/dev/null || fail "home did not load on $serial"
  reveal_id "$serial" open-lan-mode >/dev/null || fail "LAN action could not be revealed on $serial"
}

set_nickname "$SERIAL_A" HostA
set_nickname "$SERIAL_B" GuestB

tap_id "$SERIAL_A" open-lan-mode
tap_id "$SERIAL_A" create-lan-room
SENSITIVE_UI=1
wait_id "$SERIAL_A" credential-qr-sensitive >/dev/null || fail 'host QR state was not reached'
adb_for "$SERIAL_A" exec-out screencap -p >"$ARTIFACT_DIR/host-waiting-masked.png"

run_required_phase host-private-handoff "$TEMP_DIR/host-export.log" run_instrumentation "$SERIAL_A" "$TEMP_DIR/host-export-instrumentation.log" \
  "$APP_TEST_RUNNER" \
  -e class me.zqydev.gamebox.LanE2eHostExportTest
# App-target instrumentation stops the existing app process. Restore the real
# Flutter/foreground-service process before exposing its listener to the guest.
adb_for "$SERIAL_A" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
reveal_id "$SERIAL_A" continue-lan-room >/dev/null || fail 'host recovery action could not be revealed after private export'
read_private_file "$SERIAL_A" files/lan-e2e-handoff.json "$TEMP_DIR/handoff.json" 8192 \
  || fail 'host private handoff could not be read'
adb_for "$SERIAL_A" shell run-as "$PACKAGE" rm files/lan-e2e-handoff.json >/dev/null 2>&1 || true
if ! jq -er '
  select(type == "object" and keys == ["joinExpiresAt", "port", "roomId", "roomKey"])
  | [.roomId, .port, .roomKey, .joinExpiresAt]
  | @tsv
' "$TEMP_DIR/handoff.json" >"$TEMP_DIR/handoff-fields.tsv"; then
  handoff_size="$(wc -c <"$TEMP_DIR/handoff.json" | tr -d ' ')"
  handoff_first_byte="$(od -An -t x1 -N 1 "$TEMP_DIR/handoff.json" | tr -d ' ')"
  cp "$TEMP_DIR/host-export.log" "$ARTIFACT_DIR/failed-phase.log" 2>/dev/null || true
  fail "host private handoff was not canonical JSON (size=$handoff_size firstByte=${handoff_first_byte:-empty})"
fi
IFS=$'\t' read -r ROOM_ID DEVICE_PORT ROOM_KEY JOIN_EXPIRY <"$TEMP_DIR/handoff-fields.tsv" \
  || fail 'host private handoff fields could not be decoded'
FORWARDED_PORT="$(adb_for "$SERIAL_A" forward tcp:0 "tcp:$DEVICE_PORT")"
FORWARDED_PORT="$(parse_forward_port "$FORWARDED_PORT")" || fail 'adb forward did not return a safe port'
wait_forward_listener "$FORWARDED_PORT" || fail 'recovered host listener was unavailable through adb forwarding'
JOIN_QR="$(ruby -ruri -e 'puts "gamebox-lan://join?"+URI.encode_www_form(v:"1",room:ARGV[0],host:"10.0.2.2",port:ARGV[1],key:ARGV[2],exp:ARGV[3])' "$ROOM_ID" "$FORWARDED_PORT" "$ROOM_KEY" "$JOIN_EXPIRY")"
RESUME_QR="$(ruby -ruri -e 'puts "gamebox-lan://resume?"+URI.encode_www_form(v:"1",room:ARGV[0],host:"10.0.2.2",port:ARGV[1])' "$ROOM_ID" "$FORWARDED_PORT")"

tap_id "$SERIAL_B" open-lan-mode
tap_id "$SERIAL_B" join-lan-room
LAN_INPUT_NAME="gamebox-lan-e2e-$RUN_ID"
printf '%s' "$JOIN_QR" | stage_test_input "$SERIAL_B" "$LAN_INPUT_NAME"
run_required_phase guest-private-LAN-input "$TEMP_DIR/lan-input.log" run_instrumentation "$SERIAL_B" "$TEMP_DIR/lan-input-instrumentation.log" \
  "$HELPER_TEST_RUNNER" \
  -e class me.zqydev.gamebox.LanE2eInputTest -e gameboxLanInputName "$LAN_INPUT_NAME"
tap_id "$SERIAL_B" submit-lan-manual-input
wait_log_revision() {
  local serial="$1" revision="$2" deadline=$((SECONDS + 35))
  while ((SECONDS < deadline)); do
    adb_for "$serial" logcat -d -v brief | grep -E "GAMEBOX_GODOT_STATE match=$ROOM_ID revision=$revision " >/dev/null && return 0
    sleep 1
  done
  return 1
}
wait_log_revision "$SERIAL_B" 0 || fail 'guest Godot did not reach revision 0'
tap_id "$SERIAL_A" continue-lan-room
wait_log_revision "$SERIAL_A" 0 || fail 'host Godot did not reach revision 0'
adb_for "$SERIAL_A" exec-out screencap -p >"$ARTIFACT_DIR/joined-host.png"
adb_for "$SERIAL_B" exec-out screencap -p >"$ARTIFACT_DIR/joined-guest.png"

is_black() {
  adb_for "$1" logcat -d -v brief \
    | grep -E "GAMEBOX_GODOT_STATE match=$ROOM_ID revision=0 .* color=black$" >/dev/null
}
if is_black "$SERIAL_A"; then BLACK_SERIAL="$SERIAL_A"; WHITE_SERIAL="$SERIAL_B"; else BLACK_SERIAL="$SERIAL_B"; WHITE_SERIAL="$SERIAL_A"; fi

tap_cell() {
  local serial="$1" x="$2" y="$3" size width height px py
  size="$(adb_for "$serial" shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)"
  read -r width height <<<"$size"
  read -r px py <<<"$(ruby -e '
    width, height, x, y = ARGV.map(&:to_f)
    scale = [width / 1080.0, height / 1920.0].min
    puts "#{((96.0 + x * 888.0 / 14.0) * scale).round} #{((396.0 + y * 888.0 / 14.0) * scale).round}"
  ' "$width" "$height" "$x" "$y")"
  adb_for "$serial" shell input tap "$px" "$py" >/dev/null
}

revision=0
for x in 0 1 2 3 4; do
  tap_cell "$BLACK_SERIAL" "$x" 0; revision=$((revision+1))
  if ! wait_log_revision "$SERIAL_A" "$revision" || ! wait_log_revision "$SERIAL_B" "$revision"; then
    fail "revision $revision did not converge"
  fi
  if ((x < 4)); then
    tap_cell "$WHITE_SERIAL" "$x" 1; revision=$((revision+1))
    if ! wait_log_revision "$SERIAL_A" "$revision" || ! wait_log_revision "$SERIAL_B" "$revision"; then
      fail "revision $revision did not converge"
    fi
    if ((revision == 2)); then
      adb_for "$SERIAL_B" shell am force-stop "$PACKAGE"
      adb_for "$SERIAL_B" logcat -c
      adb_for "$SERIAL_B" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
      reveal_id "$SERIAL_B" open-lan-mode >/dev/null || fail 'guest recovery LAN action could not be revealed'
      tap_id "$SERIAL_B" open-lan-mode; tap_id "$SERIAL_B" join-lan-room
      LAN_INPUT_NAME="gamebox-lan-e2e-$RUN_ID-resume"
      printf '%s' "$RESUME_QR" | stage_test_input "$SERIAL_B" "$LAN_INPUT_NAME"
      run_required_phase guest-resume-input "$TEMP_DIR/lan-resume.log" run_instrumentation "$SERIAL_B" "$TEMP_DIR/lan-resume-instrumentation.log" \
        "$HELPER_TEST_RUNNER" \
        -e class me.zqydev.gamebox.LanE2eInputTest -e gameboxLanInputName "$LAN_INPUT_NAME"
      tap_id "$SERIAL_B" submit-lan-manual-input
      wait_log_revision "$SERIAL_B" "$revision" || fail 'guest resume snapshot did not converge'
      adb_for "$SERIAL_B" exec-out screencap -p >"$ARTIFACT_DIR/recovered-guest.png"
    elif ((revision == 4)); then
      adb_for "$SERIAL_A" shell input keyevent BACK
      adb_for "$SERIAL_A" logcat -c
      tap_id "$SERIAL_A" continue-lan-room
      wait_log_revision "$SERIAL_A" "$revision" || fail 'host Godot relaunch did not converge'
    elif ((revision == 6)); then
      adb_for "$SERIAL_A" shell am force-stop "$PACKAGE"
      adb_for "$SERIAL_A" logcat -c
      adb_for "$SERIAL_A" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
      reveal_id "$SERIAL_A" continue-lan-room >/dev/null || fail 'host force-stop recovery action could not be revealed'
      tap_id "$SERIAL_A" continue-lan-room
      wait_log_revision "$SERIAL_A" "$revision" || fail 'host force-stop recovery did not converge'
      adb_for "$SERIAL_A" exec-out screencap -p >"$ARTIFACT_DIR/recovered-host.png"
    fi
  fi
done
[[ "$revision" == 9 ]] || fail 'deterministic terminal revision changed'

wait_result_file() {
  local serial="$1" output="$2" deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    if read_private_file "$serial" "files/game_results/$ROOM_ID.json" "$output" 524288; then return 0; fi
    sleep 1
  done
  return 1
}
preserve_rejected_result() {
  local serial="$1" label="$2" raw
  raw="$TEMP_DIR/rejected-$label.raw"
  adb_for "$serial" exec-out run-as "$PACKAGE" cat cache/gamebox-rejected-result.json >"$raw" 2>/dev/null || return 0
  extract_json_stream 524288 "$ARTIFACT_DIR/rejected-result-$label.json" <"$raw" || true
}
if ! wait_result_file "$SERIAL_A" "$TEMP_DIR/result-a.json"; then
  preserve_rejected_result "$SERIAL_A" A
  fail 'host durable result is missing'
fi
if ! wait_result_file "$SERIAL_B" "$TEMP_DIR/result-b.json"; then
  preserve_rejected_result "$SERIAL_B" B
  fail 'guest durable result is missing'
fi
sleep 1
adb_for "$SERIAL_A" exec-out screencap -p >"$ARTIFACT_DIR/terminal-host.png"
adb_for "$SERIAL_B" exec-out screencap -p >"$ARTIFACT_DIR/terminal-guest.png"
HASH_A="$(shasum -a 256 "$TEMP_DIR/result-a.json" | awk '{print $1}')"
HASH_B="$(shasum -a 256 "$TEMP_DIR/result-b.json" | awk '{print $1}')"
[[ "$HASH_A" == "$HASH_B" ]] || fail 'authoritative result hashes differ'

capture_result_metadata() {
  local serial="$1" label="$2" result_file="$3" pending_file
  pending_file="$TEMP_DIR/pending-$label.json"
  read_private_file "$serial" "files/pending_game_results/$ROOM_ID.json" "$pending_file" 8192 \
    || fail "pending result metadata is missing on $serial"
  cp "$pending_file" "$ARTIFACT_DIR/diagnostic-pending-$label.json"
  cp "$result_file" "$ARTIFACT_DIR/diagnostic-result-$label.json"
  jq -se --arg resultSha256 "$HASH_A" '
    .[0] as $pending | .[1] as $result
    | select($pending | type == "object" and .schemaVersion == 2 and .matchId == $result.matchId)
    | $pending.localUserId as $localUserId
    | ($result.players | map(.userId)) as $playerIds
    | select($localUserId != null and ($playerIds | index($localUserId)) != null)
    | {schemaVersion:$pending.schemaVersion,matchId:$pending.matchId,source:$pending.source,endpointKind:$pending.endpointKind,localUserId:$localUserId,playerIds:$playerIds,resultSha256:$resultSha256}
  ' "$pending_file" "$result_file" >"$ARTIFACT_DIR/result-metadata-$label.json" \
    || fail "pending local identity did not match the authoritative result on $serial"
  rm "$ARTIFACT_DIR/diagnostic-pending-$label.json" "$ARTIFACT_DIR/diagnostic-result-$label.json"
}
capture_result_metadata "$SERIAL_A" A "$TEMP_DIR/result-a.json"
capture_result_metadata "$SERIAL_B" B "$TEMP_DIR/result-b.json"

wait_id_gone() {
  local serial="$1" id="$2" deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    has_id "$serial" "$id" || return 0
    sleep 1
  done
  return 1
}

for serial in "$SERIAL_A" "$SERIAL_B"; do
  return_to_home "$serial" || fail "home did not return on $serial"
  tap_id "$serial" open-match-history
  wait_id "$serial" game-history-list >/dev/null || fail "history page did not load on $serial"
  retry_id="retry-pending-$ROOM_ID"
  if has_id "$serial" "$retry_id"; then
    tap_id "$serial" "$retry_id"
    wait_id_gone "$serial" "$retry_id" || fail "history recovery did not finish on $serial"
  fi
  adb_for "$serial" exec-out screencap -p >"$ARTIFACT_DIR/history-${serial//[^A-Za-z0-9]/_}.png"
  xml="$TEMP_DIR/history-${serial//[^A-Za-z0-9]/_}.xml"; dump_ui "$serial" "$xml"
  ! grep -E '公网战绩|局域网战绩|public result|LAN result' "$xml" >/dev/null || fail 'history exposed a source distinction'
done

for required_artifact in \
  joined-host.png joined-guest.png recovered-host.png recovered-guest.png \
  terminal-host.png terminal-guest.png \
  "history-${SERIAL_A//[^A-Za-z0-9]/_}.png" "history-${SERIAL_B//[^A-Za-z0-9]/_}.png"; do
  [[ -s "$ARTIFACT_DIR/$required_artifact" ]] || fail "required runtime screenshot is missing: $required_artifact"
done

for serial in "$SERIAL_A" "$SERIAL_B"; do
  adb_for "$serial" logcat -d -v brief \
    | grep -E "GAMEBOX_(GODOT_STATE|MATCH_RESULT|RESULT_PERSIST|RESULT_BRIDGE)( match=$ROOM_ID | )" \
    >"$ARTIFACT_DIR/runtime-${serial//[^A-Za-z0-9]/_}.log" || true
done

jq -n --arg roomId "$ROOM_ID" --arg apkSha256 "$APK_HASH" --arg resultSha256 "$HASH_A" \
  --arg serialA "$SERIAL_A" --arg serialB "$SERIAL_B" --argjson warnings "$WARNING_COUNT" \
  '{status:"passed",roomId:$roomId,terminalRevision:9,apkSha256:$apkSha256,resultSha256:$resultSha256,serials:[$serialA,$serialB],hostForceStopRecovered:true,guestResumed:true,historySourceNeutral:true,warnings:$warnings}' \
  >"$ARTIFACT_DIR/summary.json"
scan_artifacts "$ARTIFACT_DIR" || { find "$ARTIFACT_DIR" -depth -delete; fail 'artifact credential scanner rejected retained output'; }
printf 'Gamebox LAN Android E2E passed: room=%s revision=9 result=%s warnings=%s\nArtifacts: %s\n' "$ROOM_ID" "$HASH_A" "$WARNING_COUNT" "$ARTIFACT_DIR"

#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE=me.zqydev.gamebox
readonly TEST_PACKAGE=me.zqydev.gamebox.test
readonly MAIN_ACTIVITY="$PACKAGE/.MainActivity"
readonly TEST_RUNNER="$TEST_PACKAGE/me.zqydev.gamebox.HostSmokeTestRunner"
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
fail() {
  local message="$1"
  mkdir -p "$ARTIFACT_DIR"
  jq -n --arg status failure --arg message "$message" --arg serialA "$SERIAL_A" --arg serialB "$SERIAL_B" \
    '{status:$status,message:$message,serials:[$serialA,$serialB]}' >"$ARTIFACT_DIR/summary.json" 2>/dev/null || true
  printf 'Gamebox LAN E2E failed: %s\nArtifacts: %s\n' "$message" "$ARTIFACT_DIR" >&2
  exit 1
}
adb_for() { "$ADB_BIN" -s "$1" "${@:2}"; }

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
  [[ -d "$directory" ]] || return 1
  if LC_ALL=C rg -a -i -n \
    'gamebox-lan://[^[:space:]]*\?(.*(key|roomKey|launchTicket|resumeToken|accessToken|refreshToken)=)|\b[A-Za-z0-9_-]{43}\b|"(roomKey|launchTicket|resumeToken|accessToken|refreshToken)"' \
    "$directory" >/dev/null 2>&1; then
    return 1
  fi
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
  if scan_artifacts "$unsafe"; then return 1; fi
  local child_marker="$TEMP_DIR/child-stopped" child_ready="$TEMP_DIR/child-ready"
  (trap 'printf stopped >"$child_marker"; exit 143' TERM; printf ready >"$child_ready"; while :; do sleep 1; done) &
  local child=$!
  while [[ ! -f "$child_ready" ]]; do sleep 0.01; done
  kill -TERM "$child"
  wait "$child" 2>/dev/null || true
  [[ -f "$child_marker" ]]
  (sleep 5) &
  local timeout_child=$! timeout_code
  set +e
  bounded_wait_pid "$timeout_child" 1
  timeout_code=$?
  set -e
  kill "$timeout_child" >/dev/null 2>&1 || true
  wait "$timeout_child" 2>/dev/null || true
  [[ "$timeout_code" == 124 ]]
  printf 'Gamebox LAN E2E self-test passed (serials, forwarding, timeout, cleanup, redaction).\n'
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
(cd "$ROOT_DIR/app/android" && ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a ./gradlew :app:assembleDebugAndroidTest) >"$TEMP_DIR/build-test.log" 2>&1 \
  || { cp "$TEMP_DIR/build-test.log" "$ARTIFACT_DIR/failed-phase.log"; fail 'androidTest build failed'; }
(cd "$ROOT_DIR/app" && ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a flutter build apk --debug --target-platform=android-arm64 --dart-define=GAMEBOX_SCREENSHOT_PRIVACY=true) >"$TEMP_DIR/build-app.log" 2>&1 \
  || { cp "$TEMP_DIR/build-app.log" "$ARTIFACT_DIR/failed-phase.log"; fail 'debug APK build failed'; }
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

adb_for "$SERIAL_A" shell am instrument -w -r \
  -e class me.zqydev.gamebox.GameResultBridgeTest "$TEST_RUNNER" >"$TEMP_DIR/result-bridge.log" \
  || { cp "$TEMP_DIR/result-bridge.log" "$ARTIFACT_DIR/failed-phase.log"; fail 'device result durability test failed'; }
adb_for "$SERIAL_A" shell pm clear "$PACKAGE" >/dev/null || fail "post-test app reset failed on $SERIAL_A"

dump_ui() {
  local serial="$1" output="$2" remote=/data/local/tmp/gamebox-lan-ui.xml
  adb_for "$serial" shell uiautomator dump "$remote" >/dev/null 2>&1 || return 1
  adb_for "$serial" exec-out cat "$remote" >"$output"
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
  wait_id "$serial" local-nickname >/dev/null || fail "nickname field missing on $serial"
  printf '%s' "$nickname" | stage_test_input "$serial" "$name"
  adb_for "$serial" shell am instrument -w -r -e class 'me.zqydev.gamebox.E2eSetTextTest#setApprovedFieldFromPrivateInputWithoutEchoingValue' \
    -e gameboxTextTarget local-nickname -e gameboxTextInputName "$name" "$TEST_RUNNER" >"$TEMP_DIR/nickname-${serial}.log" \
    || fail "nickname injection failed on $serial"
  tap_id "$serial" save-nickname
  wait_id "$serial" open-game-history >/dev/null || fail "home did not load on $serial"
  reveal_id "$serial" open-lan-mode >/dev/null || fail "LAN action could not be revealed on $serial"
}

set_nickname "$SERIAL_A" HostA
set_nickname "$SERIAL_B" GuestB

tap_id "$SERIAL_A" open-lan-mode
tap_id "$SERIAL_A" create-lan-room
wait_id "$SERIAL_A" credential-qr-sensitive >/dev/null || fail 'host QR state was not reached'
adb_for "$SERIAL_A" exec-out screencap -p >"$ARTIFACT_DIR/host-waiting-masked.png"

adb_for "$SERIAL_A" shell am instrument -w -r -e class me.zqydev.gamebox.LanE2eHostExportTest "$TEST_RUNNER" >"$TEMP_DIR/host-export.log" \
  || fail 'host private handoff export failed'
adb_for "$SERIAL_A" exec-out run-as "$PACKAGE" cat files/lan-e2e-handoff.json >"$TEMP_DIR/handoff.json" \
  || fail 'host private handoff could not be read'
adb_for "$SERIAL_A" shell run-as "$PACKAGE" rm files/lan-e2e-handoff.json >/dev/null 2>&1 || true
ROOM_ID="$(jq -er '.roomId' "$TEMP_DIR/handoff.json")"
DEVICE_PORT="$(jq -er '.port' "$TEMP_DIR/handoff.json")"
ROOM_KEY="$(jq -er '.roomKey' "$TEMP_DIR/handoff.json")"
JOIN_EXPIRY="$(jq -er '.joinExpiresAt' "$TEMP_DIR/handoff.json")"
FORWARDED_PORT="$(adb_for "$SERIAL_A" forward tcp:0 "tcp:$DEVICE_PORT")"
FORWARDED_PORT="$(parse_forward_port "$FORWARDED_PORT")" || fail 'adb forward did not return a safe port'
JOIN_QR="$(ruby -ruri -e 'puts "gamebox-lan://join?"+URI.encode_www_form(v:"1",room:ARGV[0],host:"10.0.2.2",port:ARGV[1],key:ARGV[2],exp:ARGV[3])' "$ROOM_ID" "$FORWARDED_PORT" "$ROOM_KEY" "$JOIN_EXPIRY")"
RESUME_QR="$(ruby -ruri -e 'puts "gamebox-lan://resume?"+URI.encode_www_form(v:"1",room:ARGV[0],host:"10.0.2.2",port:ARGV[1])' "$ROOM_ID" "$FORWARDED_PORT")"

tap_id "$SERIAL_B" open-lan-mode
tap_id "$SERIAL_B" join-lan-room
LAN_INPUT_NAME="gamebox-lan-e2e-$RUN_ID"
printf '%s' "$JOIN_QR" | stage_test_input "$SERIAL_B" "$LAN_INPUT_NAME"
adb_for "$SERIAL_B" shell am instrument -w -r -e class me.zqydev.gamebox.LanE2eInputTest \
  -e gameboxLanInputName "$LAN_INPUT_NAME" "$TEST_RUNNER" >"$TEMP_DIR/lan-input.log" || fail 'guest private LAN input failed'
tap_id "$SERIAL_B" submit-lan-manual-input

adb_for "$SERIAL_A" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
tap_id "$SERIAL_A" continue-lan-room
wait_log_revision() {
  local serial="$1" revision="$2" deadline=$((SECONDS + 35))
  while ((SECONDS < deadline)); do
    adb_for "$serial" logcat -d -v brief | grep -E "GAMEBOX_GODOT_STATE match=$ROOM_ID revision=$revision " >/dev/null && return 0
    sleep 1
  done
  return 1
}
wait_log_revision "$SERIAL_A" 0 || fail 'host Godot did not reach revision 0'
wait_log_revision "$SERIAL_B" 0 || fail 'guest Godot did not reach revision 0'
adb_for "$SERIAL_A" exec-out screencap -p >"$ARTIFACT_DIR/joined-host.png"
adb_for "$SERIAL_B" exec-out screencap -p >"$ARTIFACT_DIR/joined-guest.png"

is_black() { adb_for "$1" shell uiautomator dump /data/local/tmp/color.xml >/dev/null 2>&1 && adb_for "$1" exec-out cat /data/local/tmp/color.xml | grep -q '你执黑'; }
if is_black "$SERIAL_A"; then BLACK_SERIAL="$SERIAL_A"; WHITE_SERIAL="$SERIAL_B"; else BLACK_SERIAL="$SERIAL_B"; WHITE_SERIAL="$SERIAL_A"; fi

tap_cell() {
  local serial="$1" x="$2" y="$3" size width height scale_num scale_den offset_x offset_y px py
  size="$(adb_for "$serial" shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)"
  read -r width height <<<"$size"
  if ((width * 1920 <= height * 1080)); then
    scale_num=$width; scale_den=1080
  else
    scale_num=$height; scale_den=1920
  fi
  offset_x=$(( (width - 1080 * scale_num / scale_den) / 2 ))
  offset_y=$(( (height - 1920 * scale_num / scale_den) / 2 ))
  px=$(( offset_x + (96 + x * 888 / 14) * scale_num / scale_den ))
  py=$(( offset_y + (396 + y * 888 / 14) * scale_num / scale_den ))
  adb_for "$serial" shell input tap "$px" "$py" >/dev/null
}

revision=0
for x in 0 1 2 3 4; do
  tap_cell "$BLACK_SERIAL" "$x" 0; revision=$((revision+1))
  if ! wait_log_revision "$SERIAL_A" "$revision" || ! wait_log_revision "$SERIAL_B" "$revision"; then
    fail "revision $revision did not converge"
  fi
  if ((revision == 2)); then
    adb_for "$SERIAL_B" shell am force-stop "$PACKAGE"
    adb_for "$SERIAL_B" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
    tap_id "$SERIAL_B" open-lan-mode; tap_id "$SERIAL_B" join-lan-room
    LAN_INPUT_NAME="gamebox-lan-e2e-$RUN_ID-resume"
    printf '%s' "$RESUME_QR" | stage_test_input "$SERIAL_B" "$LAN_INPUT_NAME"
    adb_for "$SERIAL_B" shell am instrument -w -r -e class me.zqydev.gamebox.LanE2eInputTest -e gameboxLanInputName "$LAN_INPUT_NAME" "$TEST_RUNNER" >"$TEMP_DIR/lan-resume.log" || fail 'guest resume input failed'
    tap_id "$SERIAL_B" submit-lan-manual-input
    wait_log_revision "$SERIAL_B" "$revision" || fail 'guest resume snapshot did not converge'
    adb_for "$SERIAL_B" exec-out screencap -p >"$ARTIFACT_DIR/recovered-guest.png"
  elif ((revision == 4)); then
    adb_for "$SERIAL_A" shell input keyevent BACK
    tap_id "$SERIAL_A" continue-lan-room
    wait_log_revision "$SERIAL_A" "$revision" || fail 'host Godot relaunch did not converge'
  elif ((revision == 6)); then
    adb_for "$SERIAL_A" shell am force-stop "$PACKAGE"
    adb_for "$SERIAL_A" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
    tap_id "$SERIAL_A" continue-lan-room
    wait_log_revision "$SERIAL_A" "$revision" || fail 'host force-stop recovery did not converge'
    adb_for "$SERIAL_A" exec-out screencap -p >"$ARTIFACT_DIR/recovered-host.png"
  fi
  if ((x < 4)); then
    tap_cell "$WHITE_SERIAL" "$x" 1; revision=$((revision+1))
    if ! wait_log_revision "$SERIAL_A" "$revision" || ! wait_log_revision "$SERIAL_B" "$revision"; then
      fail "revision $revision did not converge"
    fi
  fi
done
[[ "$revision" == 9 ]] || fail 'deterministic terminal revision changed'
adb_for "$SERIAL_A" exec-out screencap -p >"$ARTIFACT_DIR/terminal-host.png"
adb_for "$SERIAL_B" exec-out screencap -p >"$ARTIFACT_DIR/terminal-guest.png"

wait_result_file() {
  local serial="$1" output="$2" deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    if adb_for "$serial" exec-out run-as "$PACKAGE" cat "files/game_results/$ROOM_ID.json" >"$output" 2>/dev/null && [[ -s "$output" ]]; then return 0; fi
    sleep 1
  done
  return 1
}
wait_result_file "$SERIAL_A" "$TEMP_DIR/result-a.json" || fail 'host durable result is missing'
wait_result_file "$SERIAL_B" "$TEMP_DIR/result-b.json" || fail 'guest durable result is missing'
HASH_A="$(shasum -a 256 "$TEMP_DIR/result-a.json" | awk '{print $1}')"
HASH_B="$(shasum -a 256 "$TEMP_DIR/result-b.json" | awk '{print $1}')"
[[ "$HASH_A" == "$HASH_B" ]] || fail 'authoritative result hashes differ'

for serial in "$SERIAL_A" "$SERIAL_B"; do
  adb_for "$serial" shell input keyevent BACK
  wait_id "$serial" open-game-history >/dev/null || fail "home did not return on $serial"
  tap_id "$serial" open-game-history
  wait_id "$serial" game-history-list >/dev/null || fail "history page did not load on $serial"
  retry_id="retry-pending-$ROOM_ID"
  if wait_id "$serial" "$retry_id" >/dev/null 2>&1; then tap_id "$serial" "$retry_id"; fi
  adb_for "$serial" exec-out screencap -p >"$ARTIFACT_DIR/history-${serial//[^A-Za-z0-9]/_}.png"
  xml="$TEMP_DIR/history-${serial//[^A-Za-z0-9]/_}.xml"; dump_ui "$serial" "$xml"
  ! grep -E '公网战绩|局域网战绩|public result|LAN result' "$xml" >/dev/null || fail 'history exposed a source distinction'
done

for serial in "$SERIAL_A" "$SERIAL_B"; do
  adb_for "$serial" logcat -d -v brief \
    | grep -E "GAMEBOX_(GODOT_STATE|MATCH_RESULT) match=$ROOM_ID " \
    >"$ARTIFACT_DIR/runtime-${serial//[^A-Za-z0-9]/_}.log" || true
done

jq -n --arg roomId "$ROOM_ID" --arg apkSha256 "$APK_HASH" --arg resultSha256 "$HASH_A" \
  --arg serialA "$SERIAL_A" --arg serialB "$SERIAL_B" \
  '{status:"passed",roomId:$roomId,terminalRevision:9,apkSha256:$apkSha256,resultSha256:$resultSha256,serials:[$serialA,$serialB],hostForceStopRecovered:true,guestResumed:true,historySourceNeutral:true}' \
  >"$ARTIFACT_DIR/summary.json"
scan_artifacts "$ARTIFACT_DIR" || { find "$ARTIFACT_DIR" -depth -delete; fail 'artifact credential scanner rejected retained output'; }
printf 'Gamebox LAN Android E2E passed: room=%s revision=9 result=%s\nArtifacts: %s\n' "$ROOM_ID" "$HASH_A" "$ARTIFACT_DIR"

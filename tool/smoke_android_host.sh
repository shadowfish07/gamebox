#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="me.zqydev.gamebox"
SMOKE_BUILD_TYPE="${GAMEBOX_ANDROID_BUILD_MODE:-profile}"
case "$SMOKE_BUILD_TYPE" in
  profile|release) ;;
  *)
    echo "GAMEBOX_ANDROID_BUILD_MODE must be 'profile' or 'release'." >&2
    exit 2
    ;;
esac
readonly SMOKE_BUILD_TYPE
readonly MAIN_ACTIVITY="$PACKAGE/.MainActivity"
readonly GAME_PROCESS="$PACKAGE:game"
readonly SELECTOR="host-smoke.launch"
readonly TEST_PACKAGE="$PACKAGE.test"
readonly TEST_RUNNER="$TEST_PACKAGE/me.zqydev.gamebox.HostSmokeTestRunner"
readonly STANDARD_TEST_RUNNER="$TEST_PACKAGE/androidx.test.runner.AndroidJUnitRunner"
readonly TEST_CLASS="me.zqydev.gamebox.HostSmokeClickTest"
readonly CLICK_SMOKE_TEST="$TEST_CLASS#clickHostSmokeLaunchByAccessibilityDescription"
readonly CLICK_CANARY_TEST="$TEST_CLASS#clickNormalLaunchCanaryByAccessibilityDescription"
readonly CLICK_COLLISION_CANARY_TEST="$TEST_CLASS#clickCollisionLaunchCanaryByAccessibilityDescription"
readonly EXPECT_OVERLAP_TEST="$TEST_CLASS#clickHostSmokeAndExpectActiveLaunchRejection"
readonly PRESS_BACK_TEST="$TEST_CLASS#pressBackToActiveGame"
readonly READY_MARKER="GAMEBOX_GODOT_READY"
readonly EXITING_MARKER="GAMEBOX_GODOT_EXITING"
readonly NORMAL_READY_MARKER="GAMEBOX_GODOT_NORMAL_READY"
readonly GODOT_TERMINATING_MARKER="OnGodotTerminating"
readonly COLLISION_REJECTED_MARKER="Game launch failed: unsupported_game_id"
readonly LOG_TAG="GameboxSmoke"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly APK_DIR="$ROOT_DIR/app/build/app/outputs/flutter-apk"
readonly TEST_APK="$ROOT_DIR/app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
# shellcheck source=tool/lib/android_smoke_log.sh
source "$ROOT_DIR/tool/lib/android_smoke_log.sh"

RUN_NONCE="run_$(date +%s)_$$_$RANDOM"
readonly RUN_NONCE
readonly CANARY_TICKET="gamebox-canary-ticket-$RUN_NONCE"
CURRENT_BOUNDARY=""

SERIAL="${GAMEBOX_ANDROID_SERIAL:-}"
if [[ -z "$SERIAL" ]]; then
  echo "GAMEBOX_ANDROID_SERIAL is required (for example, emulator-5554)." >&2
  exit 2
fi
if [[ ! "$SERIAL" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "GAMEBOX_ANDROID_SERIAL contains unsupported characters." >&2
  exit 2
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "adb is not available on PATH." >&2
  exit 2
fi

readonly -a ADB=(adb -s "$SERIAL")
device_state="$("${ADB[@]}" get-state 2>/dev/null || true)"
if [[ "$device_state" != "device" ]]; then
  echo "Android device '$SERIAL' is not connected and ready (state: ${device_state:-missing})." >&2
  exit 2
fi
ORIGINAL_ACCELEROMETER_ROTATION="$("${ADB[@]}" shell settings get system accelerometer_rotation | tr -d '\r')"
readonly ORIGINAL_ACCELEROMETER_ROTATION
ORIGINAL_USER_ROTATION="$("${ADB[@]}" shell settings get system user_rotation | tr -d '\r')"
readonly ORIGINAL_USER_ROTATION

helper_package_installed() {
  "${ADB[@]}" shell pm path "$TEST_PACKAGE" 2>/dev/null \
    | grep -q '^package:'
}

read_all_logcat() {
  "${ADB[@]}" logcat -b all -d -v threadtime 2>/dev/null
}

logs_since_boundary() {
  local boundary="$1"
  read_all_logcat | gamebox_logs_after_marker "$boundary"
}

emit_boundary() {
  local boundary="$1"
  "${ADB[@]}" shell log -p i -t "$LOG_TAG" "$boundary" >/dev/null
  local deadline=$((SECONDS + 5))
  while ((SECONDS < deadline)); do
    if read_all_logcat | grep -F "$boundary" >/dev/null; then
      CURRENT_BOUNDARY="$boundary"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

remove_helper_package() {
  "${ADB[@]}" shell am force-stop "$TEST_PACKAGE" >/dev/null 2>&1 || return 1
  if helper_package_installed; then
    "${ADB[@]}" uninstall "$TEST_PACKAGE" >/dev/null 2>&1 || return 1
  fi
}

cleanup() {
  local exit_status=$?
  trap - EXIT
  set +e
  remove_helper_package >/dev/null 2>&1
  exit "$exit_status"
}
trap cleanup EXIT

dump_failure_context() {
  echo "--- resumed activity ---" >&2
  "${ADB[@]}" shell dumpsys activity activities 2>/dev/null \
    | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity' >&2 || true
  echo "--- package processes ---" >&2
  "${ADB[@]}" shell ps -A 2>/dev/null | grep -F "$PACKAGE" >&2 || true
  echo "--- display 0 ---" >&2
  "${ADB[@]}" shell dumpsys window displays 2>/dev/null \
    | awk '/Display: mDisplayId=0/{found=1} found && /init=/{print; exit}' >&2 || true
  echo "--- recent relevant logcat ---" >&2
  if [[ -n "$CURRENT_BOUNDARY" ]]; then
    logs_since_boundary "$CURRENT_BOUNDARY" \
      | sed "s/$CANARY_TICKET/[REDACTED_CANARY_TICKET]/g" \
      | grep -E "$PACKAGE|Godot|godot|FATAL EXCEPTION|Fatal signal|ANR in|am_anr|am_crash|lmkd|$READY_MARKER|$EXITING_MARKER" >&2 || true
  fi
}

fail() {
  echo "Host smoke failed: $1" >&2
  dump_failure_context
  exit 1
}

if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  export JAVA_HOME
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi

device_abi="$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$device_abi" in
  arm64-v8a)
    flutter_target="android-arm64"
    apk_name="app-arm64-v8a-$SMOKE_BUILD_TYPE.apk"
    ;;
  armeabi-v7a)
    flutter_target="android-arm"
    apk_name="app-armeabi-v7a-$SMOKE_BUILD_TYPE.apk"
    ;;
  x86_64)
    flutter_target="android-x64"
    apk_name="app-x86_64-$SMOKE_BUILD_TYPE.apk"
    ;;
  *)
    fail "unsupported device ABI '$device_abi'"
    ;;
esac
readonly APK="$APK_DIR/$apk_name"

(
  cd "$ROOT_DIR/app"
  ORG_GRADLE_PROJECT_gameboxAndroidAbi="$device_abi" flutter build apk \
    "--$SMOKE_BUILD_TYPE" \
    --split-per-abi \
    --target-platform="$flutter_target" \
    --dart-define=GAMEBOX_HOST_SMOKE=true \
    --dart-define="GAMEBOX_INSTRUMENTATION_CANARY_NONCE=$RUN_NONCE"
)
[[ -f "$APK" ]] || fail "$SMOKE_BUILD_TYPE APK was not produced at $APK"

(
  cd "$ROOT_DIR/app/android"
  ORG_GRADLE_PROJECT_gameboxAndroidAbi="$device_abi" \
    ./gradlew :app:assembleDebugAndroidTest
)
[[ -f "$TEST_APK" ]] || fail "instrumentation APK was not produced at $TEST_APK"

packaged_abis="$(
  unzip -Z1 "$APK" \
    | sed -n 's#^lib/\([^/]*\)/.*#\1#p' \
    | sort -u \
    | paste -sd ' ' -
)"
if [[ "$packaged_abis" != "$device_abi" ]]; then
  fail "APK JNI ABI set is '${packaged_abis:-empty}', expected only '$device_abi'"
fi
for required_library in libgodot_android.so libflutter.so libapp.so libc++_shared.so; do
  unzip -Z1 "$APK" | grep -Fx "lib/$device_abi/$required_library" >/dev/null \
    || fail "single-ABI $SMOKE_BUILD_TYPE APK is missing lib/$device_abi/$required_library"
done
if unzip -Z1 "$APK" | grep -E '^lib/[^/]+/libVkLayer_khronos_validation\.so$' >/dev/null; then
  fail "GLES-only APK contains the unused Vulkan validation layer"
fi

for required_asset in \
  assets/project.godot \
  assets/main.gd \
  assets/main.gd.uid \
  assets/main.tscn \
  assets/core/launch_config.gd \
  assets/core/game_registry.gd \
  assets/games/gomoku/gomoku_controller.gd \
  assets/games/gomoku/gomoku_scene.tscn; do
  unzip -Z1 "$APK" | grep -Fx "$required_asset" >/dev/null \
    || fail "single-ABI APK is missing required runtime asset $required_asset"
done
if unzip -Z1 "$APK" \
  | grep -E '^assets/(test/|\.gdignore$|\.godot/(editor/|uid_cache\.bin$|global_script_class_cache\.cfg$|filesystem_cache|.*metadata))' >/dev/null; then
  fail "single-ABI APK contains excluded Godot editor, cache, metadata, or test assets"
fi

apk_bytes="$(wc -c <"$APK" | tr -d ' ')"
test_apk_bytes="$(wc -c <"$TEST_APK" | tr -d ' ')"
native_library_bytes="$(unzip -l "$APK" | awk -v prefix="lib/$device_abi/" '
  index($4, prefix) == 1 && $4 ~ /\.so$/ { total += $1 }
  END { printf "%.0f", total }
')"
initial_free_bytes="$("${ADB[@]}" shell df -k /data | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')"
echo "device $SERIAL build_type=$SMOKE_BUILD_TYPE ABI=$device_abi initial_free_bytes=$initial_free_bytes main_apk_bytes=$apk_bytes native_library_bytes=$native_library_bytes test_apk_bytes=$test_apk_bytes"

# Reinstalling only the two Gamebox-owned packages frees their previous code paths
# before Android's package installer evaluates its low-storage reserve.
if helper_package_installed; then
  "${ADB[@]}" uninstall "$TEST_PACKAGE" >/dev/null \
    || fail "could not remove the previous $TEST_PACKAGE helper package"
fi
if "${ADB[@]}" shell pm path "$PACKAGE" 2>/dev/null | grep -q '^package:'; then
  "${ADB[@]}" uninstall "$PACKAGE" >/dev/null \
    || fail "could not remove the previous $PACKAGE package"
fi

low_bytes="$("${ADB[@]}" shell dumpsys devicestoragemonitor 2>/dev/null \
  | sed -n 's/.*lowBytes=\([0-9][0-9]*\).*/\1/p' \
  | head -n 1)"
low_bytes="${low_bytes:-0}"
# PackageManager reserves for the APK and its native payload even with modern
# in-APK JNI loading. Retain another 16 MiB above Android's low-storage limit.
required_bytes=$((apk_bytes + native_library_bytes + test_apk_bytes + low_bytes + 16 * 1024 * 1024))
free_bytes="$("${ADB[@]}" shell df -k /data | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')"
space_deadline=$((SECONDS + 30))
while ((free_bytes < required_bytes && SECONDS < space_deadline)); do
  sleep 1
  free_bytes="$("${ADB[@]}" shell df -k /data | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')"
done
echo "preinstall_free_bytes=$free_bytes conservative_required_bytes=$required_bytes device_low_bytes=$low_bytes"
if ((free_bytes < required_bytes)); then
  fail "insufficient safe install space: free=$free_bytes required=$required_bytes; free space without removing unrelated apps or use a device with more storage"
fi

"${ADB[@]}" install --streaming -r "$APK" >/dev/null \
  || fail "streaming main APK installation failed on $SERIAL (free=$free_bytes bytes, apk=$apk_bytes bytes)"
"${ADB[@]}" install --streaming -r -t "$TEST_APK" >/dev/null \
  || fail "streaming instrumentation APK installation failed on $SERIAL"
"${ADB[@]}" shell pm clear "$PACKAGE" >/dev/null || fail "could not clear only $PACKAGE app data"
run_instrumentation() {
  local test_name="$1"
  local runner="${2:-$TEST_RUNNER}"
  local output
  output="$("${ADB[@]}" shell am instrument -w -r \
    -e class "$test_name" \
    "$runner" 2>&1)" || true
  if ! grep -F 'OK (' <<<"$output" >/dev/null \
    || grep -E 'FAILURES!!!|Process crashed|INSTRUMENTATION_FAILED' <<<"$output" >/dev/null; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  [[ -z "$("${ADB[@]}" shell pidof "$TEST_PACKAGE" 2>/dev/null | tr -d '\r')" ]]
}

if [[ "$SMOKE_BUILD_TYPE" == "profile" ]]; then
  run_instrumentation \
    "me.zqydev.gamebox.PrivateCommandLineArgsTest" \
    "$STANDARD_TEST_RUNNER" \
    || fail "private command-line instrumentation regression failed"
fi

"${ADB[@]}" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null \
  || fail "could not start $MAIN_ACTIVITY"

main_pid() {
  "${ADB[@]}" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

game_pid() {
  "${ADB[@]}" shell pidof "$GAME_PROCESS" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

main_is_resumed() {
  "${ADB[@]}" shell dumpsys activity activities 2>/dev/null \
    | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
    | grep -F "$PACKAGE/.MainActivity" >/dev/null
}

wait_for_log_marker() {
  local boundary="$1"
  local marker="$2"
  local deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    if logs_since_boundary "$boundary" | grep -F "$marker" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_game_pid() {
  local deadline=$((SECONDS + 20))
  local observed_pid
  while ((SECONDS < deadline)); do
    observed_pid="$(game_pid)"
    if [[ -n "$observed_pid" ]]; then
      printf '%s\n' "$observed_pid"
      return 0
    fi
    sleep 0.05
  done
  return 1
}

wait_for_game_exit() {
  local deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    if [[ -z "$(game_pid)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_main_resume() {
  local deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    if main_is_resumed; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_for_old_main_exit() {
  local old_pid="$1"
  local deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    if [[ "$(main_pid)" != "$old_pid" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

assert_game_portrait() {
  local deadline=$((SECONDS + 10))
  local activity_record
  local display_line
  local dimensions
  local width
  local height
  while ((SECONDS < deadline)); do
    activity_record="$("${ADB[@]}" shell dumpsys activity activities 2>/dev/null | awk -v activity="$PACKAGE/.GameActivity" '
      /^[[:space:]]*\* Hist[[:space:]]+#[0-9]+:/ {
        if (found) exit
        found = index($0, activity) > 0
      }
      found { print }
    ')"
    display_line="$("${ADB[@]}" shell dumpsys window displays 2>/dev/null | awk '
      /Display: mDisplayId=0/ { found = 1 }
      found && /init=/ { print; exit }
    ')"
    dimensions="$(sed -n 's/.*cur=\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' <<<"$display_line")"
    read -r width height <<<"$dimensions"
    if grep -F 'requestedOrientation=SCREEN_ORIENTATION_PORTRAIT' <<<"$activity_record" >/dev/null \
      && [[ -n "${width:-}" && -n "${height:-}" ]] \
      && ((width < height)); then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

assert_no_crash_or_anr() {
  local bounded_logs="$1"
  local observed_game_pid="$2"
  local bad_logs
  bad_logs="$(gamebox_find_crash_evidence \
    "$PACKAGE" \
    "$GAME_PROCESS" \
    "$TEST_PACKAGE" \
    "$observed_game_pid" <<<"$bounded_logs")"
  [[ -z "$bad_logs" ]] || fail "post-boundary Java/native crash, ANR, or low-memory kill detected"
}

initial_pid="$(main_pid)"
[[ -n "$initial_pid" ]] || fail "Flutter main process did not start"

# A synthetic pre-boundary fatal pair proves stale device logs are excluded.
"${ADB[@]}" shell log -p e -t "$LOG_TAG" \
  "FATAL EXCEPTION: pre-boundary synthetic $RUN_NONCE" >/dev/null
"${ADB[@]}" shell log -p e -t "$LOG_TAG" \
  "Process: $GAME_PROCESS, PID: 1 pre-boundary synthetic $RUN_NONCE" >/dev/null

canary_boundary="GAMEBOX_CANARY_BOUNDARY_$RUN_NONCE"
emit_boundary "$canary_boundary" || fail "could not establish canary log boundary"
run_instrumentation "$CLICK_CANARY_TEST" \
  || fail "normal-launch canary instrumentation failed"
canary_game_pid="$(wait_for_game_pid || true)"
[[ -n "$canary_game_pid" ]] || fail "normal-launch canary did not start $GAME_PROCESS"
wait_for_log_marker "$canary_boundary" "$NORMAL_READY_MARKER" \
  || fail "normal-launch canary did not reach the Gomoku scene"
assert_game_portrait || fail "normal-launch canary was not requested and displayed in portrait"
canary_logs="$(logs_since_boundary "$canary_boundary")"
if grep -F "$CANARY_TICKET" <<<"$canary_logs" >/dev/null; then
  fail "normal-launch canary ticket appeared in post-boundary logcat"
fi
assert_no_crash_or_anr "$canary_logs" "$canary_game_pid"

recreated_main_pid="$initial_pid"
if [[ "$SMOKE_BUILD_TYPE" == "profile" ]]; then
  # Kill only the main process while the game stays alive, then verify the kernel-held
  # lease reconstructs the launch gate in the new main process. Release builds are
  # intentionally not debuggable, so Android rejects the run-as step there.
  old_main_pid="$initial_pid"
  "${ADB[@]}" shell run-as "$PACKAGE" kill -9 "$old_main_pid" >/dev/null \
    || fail "could not kill only Flutter main PID $old_main_pid for recreation verification"
  wait_for_old_main_exit "$old_main_pid" \
    || fail "old Flutter main PID $old_main_pid remained after targeted kill"
  [[ "$(game_pid)" == "$canary_game_pid" ]] \
    || fail "targeted main-process kill changed the active game PID"
  "${ADB[@]}" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null \
    || fail "could not recreate MainActivity while the game stayed active"
  wait_for_main_resume || fail "MainActivity did not resume for overlap verification"
  recreated_main_pid="$(main_pid)"
  [[ -n "$recreated_main_pid" && "$recreated_main_pid" != "$old_main_pid" ]] \
    || fail "Flutter main process was not recreated with a new PID"
  [[ "$(game_pid)" == "$canary_game_pid" ]] || fail "canary game PID changed before overlap attempt"
  run_instrumentation "$EXPECT_OVERLAP_TEST" \
    || fail "recreated main process did not return the deterministic overlap rejection"
  [[ "$(game_pid)" == "$canary_game_pid" ]] || fail "overlap attempt created or replaced the game process"
  canary_logs="$(logs_since_boundary "$canary_boundary")"
  normal_ready_count="$(grep -F -c "$NORMAL_READY_MARKER" <<<"$canary_logs" || true)"
  [[ "$normal_ready_count" -eq 1 ]] || fail "overlap produced $normal_ready_count normal Godot ready markers"
  run_instrumentation "$PRESS_BACK_TEST" || fail "could not return from overlap UI to the active game"
fi

# UI Automator back navigation closes only the Gamebox canary and returns to the existing Flutter host.
run_instrumentation "$PRESS_BACK_TEST" || fail "could not request normal canary exit"
wait_for_log_marker "$canary_boundary" "$GODOT_TERMINATING_MARKER" \
  || fail "normal canary did not enter Godot's controlled termination path"
wait_for_game_exit || fail "normal canary $GAME_PROCESS did not exit after back"
"${ADB[@]}" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null \
  || fail "could not restore MainActivity after normal canary exit"
wait_for_main_resume || fail "MainActivity did not resume after normal canary exit"
[[ "$(main_pid)" == "$recreated_main_pid" ]] || fail "normal canary exit restarted recreated Flutter"
canary_logs="$(logs_since_boundary "$canary_boundary")"
if grep -F "$CANARY_TICKET" <<<"$canary_logs" >/dev/null; then
  fail "normal-launch canary ticket appeared during exit in post-boundary logcat"
fi
assert_no_crash_or_anr "$canary_logs" "$canary_game_pid"
initial_pid="$recreated_main_pid"
if [[ "$SMOKE_BUILD_TYPE" == "profile" ]]; then
  echo "normal canary passed: ticket absent from all-buffer logs, game PID $canary_game_pid survived main PID $old_main_pid -> $recreated_main_pid recreation, overlap rejected, clean marked exit"
else
  echo "normal canary passed: release Godot JNI initialized, ticket absent from all-buffer logs, and the game exited cleanly"
fi

# A key-shaped gameId must never redirect ticket privatization to the wrong slot.
collision_boundary="GAMEBOX_COLLISION_BOUNDARY_$RUN_NONCE"
emit_boundary "$collision_boundary" || fail "could not establish collision-canary log boundary"
run_instrumentation "$CLICK_COLLISION_CANARY_TEST" \
  || fail "collision-canary instrumentation failed"
collision_game_pid="$(wait_for_game_pid || true)"
[[ -n "$collision_game_pid" ]] || fail "collision canary did not start $GAME_PROCESS"
wait_for_log_marker "$collision_boundary" "$COLLISION_REJECTED_MARKER" \
  || fail "collision canary did not reach LaunchConfig's safe unsupported-game rejection"
assert_game_portrait || fail "collision canary was not requested and displayed in portrait"
collision_logs="$(logs_since_boundary "$collision_boundary")"
if grep -F "$CANARY_TICKET" <<<"$collision_logs" >/dev/null; then
  fail "collision canary ticket appeared in all-buffer logcat"
fi
assert_no_crash_or_anr "$collision_logs" "$collision_game_pid"
run_instrumentation "$PRESS_BACK_TEST" || fail "could not request collision canary exit"
wait_for_log_marker "$collision_boundary" "$GODOT_TERMINATING_MARKER" \
  || fail "collision canary did not enter Godot's controlled termination path"
wait_for_game_exit || fail "collision canary $GAME_PROCESS did not exit after back"
"${ADB[@]}" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null \
  || fail "could not restore MainActivity after collision canary exit"
wait_for_main_resume || fail "MainActivity did not resume after collision canary exit"
[[ "$(main_pid)" == "$initial_pid" ]] || fail "collision canary exit restarted Flutter"
collision_logs="$(logs_since_boundary "$collision_boundary")"
if grep -F "$CANARY_TICKET" <<<"$collision_logs" >/dev/null; then
  fail "collision canary ticket appeared during exit in all-buffer logcat"
fi
assert_no_crash_or_anr "$collision_logs" "$collision_game_pid"
echo "collision canary passed: key-shaped gameId reached safe rejection, ticket absent from all-buffer logs, clean marked exit"

for cycle in 1 2; do
  before_pid="$(main_pid)"
  [[ "$before_pid" == "$initial_pid" ]] \
    || fail "cycle $cycle main process PID changed before launch"

  cycle_boundary="GAMEBOX_CYCLE_${cycle}_BOUNDARY_$RUN_NONCE"
  emit_boundary "$cycle_boundary" || fail "cycle $cycle could not establish log boundary"
  run_instrumentation "$CLICK_SMOKE_TEST" \
    || fail "cycle $cycle instrumentation could not click By.desc('$SELECTOR')"
  observed_game_pid="$(wait_for_game_pid || true)"
  [[ -n "$observed_game_pid" ]] || fail "cycle $cycle did not capture $GAME_PROCESS PID"
  wait_for_log_marker "$cycle_boundary" "$READY_MARKER" \
    || fail "cycle $cycle did not observe $READY_MARKER"
  assert_game_portrait || fail "cycle $cycle was not requested and displayed in portrait"
  wait_for_log_marker "$cycle_boundary" "$EXITING_MARKER" \
    || fail "cycle $cycle did not observe $EXITING_MARKER"
  wait_for_game_exit || fail "cycle $cycle $GAME_PROCESS did not exit"
  wait_for_main_resume || fail "cycle $cycle did not resume $MAIN_ACTIVITY"

  after_pid="$(main_pid)"
  [[ "$after_pid" == "$before_pid" ]] \
    || fail "cycle $cycle restarted Flutter main process ($before_pid -> ${after_pid:-missing})"
  cycle_logs="$(logs_since_boundary "$cycle_boundary")"
  gamebox_assert_markers_in_order "$READY_MARKER" "$EXITING_MARKER" <<<"$cycle_logs" \
    || fail "cycle $cycle markers were absent or out of order"
  ready_count="$(grep -F -c "$READY_MARKER" <<<"$cycle_logs" || true)"
  exiting_count="$(grep -F -c "$EXITING_MARKER" <<<"$cycle_logs" || true)"
  [[ "$ready_count" -eq 1 && "$exiting_count" -eq 1 ]] \
    || fail "cycle $cycle expected one READY and EXITING marker (got $ready_count/$exiting_count)"
  assert_no_crash_or_anr "$cycle_logs" "$observed_game_pid"
  echo "cycle $cycle passed: READY then EXITING, game PID $observed_game_pid exited cleanly, MainActivity resumed, main PID $after_pid unchanged"
done

current_accelerometer_rotation="$("${ADB[@]}" shell settings get system accelerometer_rotation | tr -d '\r')"
current_user_rotation="$("${ADB[@]}" shell settings get system user_rotation | tr -d '\r')"
[[ "$current_accelerometer_rotation" == "$ORIGINAL_ACCELEROMETER_ROTATION" \
  && "$current_user_rotation" == "$ORIGINAL_USER_ROTATION" ]] \
  || fail "emulator rotation settings changed during smoke"

remove_helper_package || fail "could not remove the $TEST_PACKAGE instrumentation helper"
if helper_package_installed; then
  fail "$TEST_PACKAGE remained installed after cleanup"
fi
if [[ -n "$("${ADB[@]}" shell pidof "$TEST_PACKAGE" 2>/dev/null | tr -d '\r')" ]]; then
  fail "$TEST_PACKAGE helper process remained after cleanup"
fi

echo "Android host smoke passed twice on $SERIAL."

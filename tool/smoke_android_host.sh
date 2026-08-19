#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="me.zqydev.gamebox"
readonly MAIN_ACTIVITY="$PACKAGE/.MainActivity"
readonly GAME_PROCESS="$PACKAGE:game"
readonly SELECTOR="host-smoke.launch"
readonly TEST_PACKAGE="$PACKAGE.test"
readonly TEST_RUNNER="$TEST_PACKAGE/me.zqydev.gamebox.HostSmokeTestRunner"
readonly STANDARD_TEST_RUNNER="$TEST_PACKAGE/androidx.test.runner.AndroidJUnitRunner"
readonly TEST_CLASS="me.zqydev.gamebox.HostSmokeClickTest"
readonly CLICK_SMOKE_TEST="$TEST_CLASS#clickHostSmokeLaunchByAccessibilityDescription"
readonly CLICK_CANARY_TEST="$TEST_CLASS#clickNormalLaunchCanaryByAccessibilityDescription"
readonly EXPECT_OVERLAP_TEST="$TEST_CLASS#clickHostSmokeAndExpectActiveLaunchRejection"
readonly PRESS_BACK_TEST="$TEST_CLASS#pressBackToActiveGame"
readonly READY_MARKER="GAMEBOX_GODOT_READY"
readonly EXITING_MARKER="GAMEBOX_GODOT_EXITING"
readonly NORMAL_READY_MARKER="GAMEBOX_GODOT_NORMAL_READY"
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
    apk_name="app-arm64-v8a-debug.apk"
    ;;
  armeabi-v7a)
    flutter_target="android-arm"
    apk_name="app-armeabi-v7a-debug.apk"
    ;;
  x86_64)
    flutter_target="android-x64"
    apk_name="app-x86_64-debug.apk"
    ;;
  *)
    fail "unsupported device ABI '$device_abi'"
    ;;
esac
readonly APK="$APK_DIR/$apk_name"

(
  cd "$ROOT_DIR/app"
  ORG_GRADLE_PROJECT_gameboxAndroidAbi="$device_abi" flutter build apk \
    --debug \
    --split-per-abi \
    --target-platform="$flutter_target" \
    --dart-define=GAMEBOX_HOST_SMOKE=true \
    --dart-define="GAMEBOX_INSTRUMENTATION_CANARY_NONCE=$RUN_NONCE"
)
[[ -f "$APK" ]] || fail "debug APK was not produced at $APK"

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
unzip -Z1 "$APK" | grep -Fx "lib/$device_abi/libgodot_android.so" >/dev/null \
  || fail "single-ABI APK is missing lib/$device_abi/libgodot_android.so"

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
initial_free_bytes="$("${ADB[@]}" shell df -k /data | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')"
echo "device $SERIAL ABI=$device_abi initial_free_bytes=$initial_free_bytes main_apk_bytes=$apk_bytes test_apk_bytes=$test_apk_bytes"

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
# Streaming install does not stage a second full APK on-device; retain 32 MiB
# beyond the installed APKs and Android's own low-storage reserve.
required_bytes=$((apk_bytes + test_apk_bytes + low_bytes + 32 * 1024 * 1024))
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

run_instrumentation \
  "me.zqydev.gamebox.PrivateCommandLineArgsTest" \
  "$STANDARD_TEST_RUNNER" \
  || fail "private command-line instrumentation regression failed"

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
canary_logs="$(logs_since_boundary "$canary_boundary")"
if grep -F "$CANARY_TICKET" <<<"$canary_logs" >/dev/null; then
  fail "normal-launch canary ticket appeared in post-boundary logcat"
fi
assert_no_crash_or_anr "$canary_logs" "$canary_game_pid"

# Bring Flutter over the still-running normal game and verify the launch gate rejects overlap.
"${ADB[@]}" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null \
  || fail "could not bring MainActivity forward for overlap verification"
wait_for_main_resume || fail "MainActivity did not resume for overlap verification"
[[ "$(main_pid)" == "$initial_pid" ]] || fail "overlap verification restarted Flutter"
[[ "$(game_pid)" == "$canary_game_pid" ]] || fail "canary game PID changed before overlap attempt"
run_instrumentation "$EXPECT_OVERLAP_TEST" \
  || fail "overlapping launch did not return the deterministic rejection"
[[ "$(game_pid)" == "$canary_game_pid" ]] || fail "overlap attempt created or replaced the game process"
canary_logs="$(logs_since_boundary "$canary_boundary")"
normal_ready_count="$(grep -F -c "$NORMAL_READY_MARKER" <<<"$canary_logs" || true)"
[[ "$normal_ready_count" -eq 1 ]] || fail "overlap produced $normal_ready_count normal Godot ready markers"

# UI Automator back navigation closes only the Gamebox canary and returns to the existing Flutter host.
run_instrumentation "$PRESS_BACK_TEST" || fail "could not return from overlap UI to the active game"
run_instrumentation "$PRESS_BACK_TEST" || fail "could not request normal canary exit"
wait_for_game_exit || fail "normal canary $GAME_PROCESS did not exit after back"
"${ADB[@]}" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null \
  || fail "could not restore MainActivity after normal canary exit"
wait_for_main_resume || fail "MainActivity did not resume after normal canary exit"
[[ "$(main_pid)" == "$initial_pid" ]] || fail "normal canary exit restarted Flutter"
echo "normal canary passed: ticket absent from logs, one game PID $canary_game_pid, overlap rejected, main PID $initial_pid unchanged"

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

remove_helper_package || fail "could not remove the $TEST_PACKAGE instrumentation helper"
if helper_package_installed; then
  fail "$TEST_PACKAGE remained installed after cleanup"
fi
if [[ -n "$("${ADB[@]}" shell pidof "$TEST_PACKAGE" 2>/dev/null | tr -d '\r')" ]]; then
  fail "$TEST_PACKAGE helper process remained after cleanup"
fi

echo "Android host smoke passed twice on $SERIAL."

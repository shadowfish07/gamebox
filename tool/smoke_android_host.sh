#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="me.zqydev.gamebox"
readonly MAIN_ACTIVITY="$PACKAGE/.MainActivity"
readonly GAME_PROCESS="$PACKAGE:game"
readonly SELECTOR="host-smoke.launch"
readonly TEST_PACKAGE="$PACKAGE.test"
readonly TEST_RUNNER="$TEST_PACKAGE/me.zqydev.gamebox.HostSmokeTestRunner"
readonly TEST_CLASS="me.zqydev.gamebox.HostSmokeClickTest#clickHostSmokeLaunchByAccessibilityDescription"
readonly READY_MARKER="GAMEBOX_GODOT_READY"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APK_DIR="$ROOT_DIR/app/build/app/outputs/flutter-apk"
readonly TEST_APK="$ROOT_DIR/app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

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

cleanup() {
  "${ADB[@]}" shell am force-stop "$TEST_PACKAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

dump_failure_context() {
  echo "--- resumed activity ---" >&2
  "${ADB[@]}" shell dumpsys activity activities 2>/dev/null \
    | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity' >&2 || true
  echo "--- package processes ---" >&2
  "${ADB[@]}" shell ps -A 2>/dev/null | grep -F "$PACKAGE" >&2 || true
  echo "--- recent relevant logcat ---" >&2
  "${ADB[@]}" logcat -d -t 250 2>/dev/null \
    | grep -E "$PACKAGE|Godot|godot|FATAL EXCEPTION|ANR in|am_anr|$READY_MARKER" >&2 || true
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
    --dart-define=GAMEBOX_HOST_SMOKE=true
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

apk_bytes="$(wc -c <"$APK" | tr -d ' ')"
test_apk_bytes="$(wc -c <"$TEST_APK" | tr -d ' ')"
initial_free_bytes="$("${ADB[@]}" shell df -k /data | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')"
echo "device $SERIAL ABI=$device_abi initial_free_bytes=$initial_free_bytes main_apk_bytes=$apk_bytes test_apk_bytes=$test_apk_bytes"

# Reinstalling only the two Gamebox-owned packages frees their previous code paths
# before Android's package installer evaluates its low-storage reserve.
if "${ADB[@]}" shell pm path "$TEST_PACKAGE" >/dev/null 2>&1; then
  "${ADB[@]}" uninstall "$TEST_PACKAGE" >/dev/null \
    || fail "could not remove the previous $TEST_PACKAGE helper package"
fi
if "${ADB[@]}" shell pm path "$PACKAGE" >/dev/null 2>&1; then
  "${ADB[@]}" uninstall "$PACKAGE" >/dev/null \
    || fail "could not remove the previous $PACKAGE package"
fi

low_bytes="$("${ADB[@]}" shell dumpsys devicestoragemonitor 2>/dev/null \
  | sed -n 's/.*lowBytes=\([0-9][0-9]*\).*/\1/p' \
  | head -n 1)"
low_bytes="${low_bytes:-0}"
required_bytes=$((apk_bytes * 2 + test_apk_bytes + low_bytes + 16 * 1024 * 1024))
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
"${ADB[@]}" logcat -c || fail "could not clear logcat on $SERIAL"
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

click_button_with_uiautomator() {
  local output
  output="$("${ADB[@]}" shell am instrument -w -r \
    -e class "$TEST_CLASS" \
    "$TEST_RUNNER" 2>&1)" || true
  if ! grep -F 'OK (1 test)' <<<"$output" >/dev/null \
    || grep -E 'FAILURES!!!|Process crashed|INSTRUMENTATION_FAILED' <<<"$output" >/dev/null; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  [[ -z "$("${ADB[@]}" shell pidof "$TEST_PACKAGE" 2>/dev/null | tr -d '\r')" ]]
}

wait_for_ready_marker() {
  local deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    if "${ADB[@]}" logcat -d 2>/dev/null | grep -F "$READY_MARKER" >/dev/null; then
      return 0
    fi
    sleep 0.1
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
  local bad_logs
  bad_logs="$("${ADB[@]}" logcat -d 2>/dev/null \
    | awk -v app="$PACKAGE" -v helper="$TEST_PACKAGE" '
        /FATAL EXCEPTION/ { fatal = $0; next }
        fatal != "" && /Process:/ {
          if (index($0, app) || index($0, helper)) print fatal "\n" $0
          fatal = ""
          next
        }
        /ANR in / && (index($0, app) || index($0, helper)) { print }
        /am_anr/ && (index($0, app) || index($0, helper)) { print }
      ' || true)"
  [[ -z "$bad_logs" ]] || fail "FATAL EXCEPTION or ANR detected"
}

initial_pid="$(main_pid)"
[[ -n "$initial_pid" ]] || fail "Flutter main process did not start"

for cycle in 1 2; do
  before_pid="$(main_pid)"
  [[ "$before_pid" == "$initial_pid" ]] \
    || fail "cycle $cycle main process PID changed before launch"

  "${ADB[@]}" logcat -c || fail "cycle $cycle could not reset logcat evidence"
  click_button_with_uiautomator \
    || fail "cycle $cycle instrumentation could not click By.desc('$SELECTOR')"
  wait_for_ready_marker || fail "cycle $cycle did not observe $READY_MARKER"
  wait_for_game_exit || fail "cycle $cycle $GAME_PROCESS did not exit"
  wait_for_main_resume || fail "cycle $cycle did not resume $MAIN_ACTIVITY"

  after_pid="$(main_pid)"
  [[ "$after_pid" == "$before_pid" ]] \
    || fail "cycle $cycle restarted Flutter main process ($before_pid -> ${after_pid:-missing})"
  assert_no_crash_or_anr
  echo "cycle $cycle passed: ready marker observed, game process exited, MainActivity resumed, main PID $after_pid unchanged"
done

echo "Android host smoke passed twice on $SERIAL."

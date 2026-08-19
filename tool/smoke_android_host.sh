#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="me.zqydev.gamebox"
readonly MAIN_ACTIVITY="$PACKAGE/.MainActivity"
readonly GAME_PROCESS="$PACKAGE:game"
readonly SELECTOR="host-smoke.launch"
readonly DEVICE_UI_DUMP="/data/local/tmp/gamebox-host-smoke-window.xml"
readonly READY_MARKER="GAMEBOX_GODOT_READY"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APK_DIR="$ROOT_DIR/app/build/app/outputs/flutter-apk"

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
  "${ADB[@]}" shell rm -f "$DEVICE_UI_DUMP" >/dev/null 2>&1 || true
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
  echo "--- accessibility window ---" >&2
  "${ADB[@]}" shell uiautomator dump "$DEVICE_UI_DUMP" >/dev/null 2>&1 || true
  "${ADB[@]}" exec-out cat "$DEVICE_UI_DUMP" 2>/dev/null >&2 || true
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
  flutter build apk \
    --debug \
    --split-per-abi \
    --target-platform="$flutter_target" \
    --dart-define=GAMEBOX_HOST_SMOKE=true
)
[[ -f "$APK" ]] || fail "debug APK was not produced at $APK"

"${ADB[@]}" install -r "$APK" >/dev/null || fail "APK installation failed on $SERIAL"
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

button_node() {
  "${ADB[@]}" shell uiautomator dump "$DEVICE_UI_DUMP" >/dev/null 2>&1 || return 1
  "${ADB[@]}" exec-out cat "$DEVICE_UI_DUMP" 2>/dev/null \
    | awk -v selector="$SELECTOR" 'BEGIN { RS=">" } index($0, "content-desc=\"" selector "\"") { print $0 ">"; exit }'
}

wait_for_button() {
  local deadline=$((SECONDS + 20))
  local node
  while ((SECONDS < deadline)); do
    node="$(button_node || true)"
    if [[ -n "$node" ]]; then
      printf '%s\n' "$node"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

tap_button() {
  local node="$1"
  local bounds
  bounds="$(printf '%s\n' "$node" | sed -n 's/.*bounds="\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]".*/\1 \2 \3 \4/p')"
  [[ -n "$bounds" ]] || return 1
  local left top right bottom
  read -r left top right bottom <<<"$bounds"
  "${ADB[@]}" shell input tap "$(((left + right) / 2))" "$(((top + bottom) / 2))" >/dev/null
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
    | grep -E "FATAL EXCEPTION|ANR in $PACKAGE|am_anr.*$PACKAGE" || true)"
  [[ -z "$bad_logs" ]] || fail "FATAL EXCEPTION or ANR detected"
}

initial_pid="$(main_pid)"
[[ -n "$initial_pid" ]] || fail "Flutter main process did not start"

for cycle in 1 2; do
  node="$(wait_for_button || true)"
  [[ -n "$node" ]] || fail "cycle $cycle could not find Android accessibility selector '$SELECTOR'"
  before_pid="$(main_pid)"
  [[ "$before_pid" == "$initial_pid" ]] \
    || fail "cycle $cycle main process PID changed before launch"

  "${ADB[@]}" logcat -c || fail "cycle $cycle could not reset logcat evidence"
  tap_button "$node" || fail "cycle $cycle could not activate '$SELECTOR'"
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

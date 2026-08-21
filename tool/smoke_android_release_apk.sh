#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="me.zqydev.gamebox"
readonly GAME_PROCESS="$PACKAGE:game"
readonly TEST_PACKAGE="$PACKAGE.release_smoke"
readonly TEST_RUNNER="$TEST_PACKAGE/androidx.test.runner.AndroidJUnitRunner"
readonly TEST_METHOD="me.zqydev.gamebox.release_smoke.ReleaseGodotSmokeTest#launchPackagedGodotHostSmoke"
readonly READY_MARKER="GAMEBOX_GODOT_READY"
readonly EXITING_MARKER="GAMEBOX_GODOT_EXITING"
readonly LOG_TAG="GameboxSmoke"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# shellcheck source=tool/lib/android_smoke_log.sh
source "$ROOT_DIR/tool/lib/android_smoke_log.sh"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 PATH_TO_SIGNED_RELEASE_APK" >&2
  exit 2
fi
APK="$1"
if [[ ! -f "$APK" ]]; then
  echo "Release APK not found: $APK" >&2
  exit 2
fi
APK="$(cd "$(dirname "$APK")" && pwd)/$(basename "$APK")"
readonly APK

SERIAL="${GAMEBOX_ANDROID_SERIAL:-}"
if [[ -z "$SERIAL" || ! "$SERIAL" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "GAMEBOX_ANDROID_SERIAL must name one connected Android device." >&2
  exit 2
fi
command -v adb >/dev/null 2>&1 || {
  echo "adb is not available on PATH." >&2
  exit 2
}
readonly -a ADB=(adb -s "$SERIAL")
[[ "$("${ADB[@]}" get-state 2>/dev/null || true)" == "device" ]] || {
  echo "Android device '$SERIAL' is not connected and ready." >&2
  exit 2
}

find_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return
  fi
  local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]] || return 1
  find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 -type f -name apksigner \
    | sort -V \
    | tail -n 1
}

APKSIGNER="$(find_apksigner || true)"
[[ -x "$APKSIGNER" ]] || {
  echo "apksigner is required to compare the release and instrumentation signers." >&2
  exit 2
}
readonly APKSIGNER

if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  export JAVA_HOME
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi

(
  cd "$ROOT_DIR/app/android"
  # Signing material is intentionally created after source tests in release CI.
  # Never restore a helper APK that was cached earlier with the debug signer.
  ./gradlew --no-build-cache --rerun-tasks :release-smoke:assembleRelease
)
readonly TEST_APK="$ROOT_DIR/app/build/release-smoke/outputs/apk/release/release-smoke-release.apk"
[[ -f "$TEST_APK" ]] || {
  echo "Release instrumentation APK was not produced at $TEST_APK" >&2
  exit 1
}

signer_digest() {
  "$APKSIGNER" verify --print-certs "$1" \
    | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' \
    | head -n 1
}
main_signer="$(signer_digest "$APK")"
test_signer="$(signer_digest "$TEST_APK")"
[[ -n "$main_signer" && "$main_signer" == "$test_signer" ]] || {
  echo "Release APK and instrumentation APK are not signed by the same certificate:" >&2
  echo "  main=$main_signer" >&2
  echo "  test=$test_signer" >&2
  exit 1
}

device_abi="$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$device_abi" in
  arm64-v8a|armeabi-v7a|x86_64) ;;
  *)
    echo "Unsupported Android device ABI: $device_abi" >&2
    exit 2
    ;;
esac

apk_entries="$(unzip -Z1 "$APK")"
packaged_abis="$(
  sed -n 's#^lib/\([^/]*\)/.*#\1#p' <<<"$apk_entries" \
    | sort -u \
    | paste -sd ' ' -
)"
readonly EXPECTED_ABIS="arm64-v8a armeabi-v7a x86_64"
[[ "$packaged_abis" == "$EXPECTED_ABIS" ]] || {
  echo "Release APK JNI ABI set is '${packaged_abis:-empty}', expected '$EXPECTED_ABIS'." >&2
  exit 1
}
for required_library in libgodot_android.so libflutter.so libapp.so libc++_shared.so; do
  grep -Fx "lib/$device_abi/$required_library" <<<"$apk_entries" >/dev/null || {
    echo "Release APK is missing lib/$device_abi/$required_library" >&2
    exit 1
  }
done
for required_asset in \
  assets/project.godot \
  assets/main.gd \
  assets/main.tscn \
  assets/core/launch_config.gd \
  assets/games/gomoku/gomoku_scene.tscn; do
  grep -Fx "$required_asset" <<<"$apk_entries" >/dev/null || {
    echo "Release APK is missing runtime asset $required_asset" >&2
    exit 1
  }
done

cleanup() {
  local exit_status=$?
  trap - EXIT
  set +e
  "${ADB[@]}" shell am force-stop "$TEST_PACKAGE" >/dev/null 2>&1
  "${ADB[@]}" uninstall "$TEST_PACKAGE" >/dev/null 2>&1
  exit "$exit_status"
}
trap cleanup EXIT

"${ADB[@]}" uninstall "$TEST_PACKAGE" >/dev/null 2>&1 || true
"${ADB[@]}" uninstall "$PACKAGE" >/dev/null 2>&1 || true
apk_bytes="$(wc -c <"$APK" | tr -d ' ')"
test_apk_bytes="$(wc -c <"$TEST_APK" | tr -d ' ')"
native_library_bytes="$(unzip -l "$APK" | awk -v prefix="lib/$device_abi/" '
  index($4, prefix) == 1 && $4 ~ /\.so$/ { total += $1 }
  END { printf "%.0f", total }
')"
low_bytes="$("${ADB[@]}" shell dumpsys devicestoragemonitor 2>/dev/null \
  | sed -n 's/.*lowBytes=\([0-9][0-9]*\).*/\1/p' \
  | head -n 1)"
low_bytes="${low_bytes:-0}"
free_bytes="$("${ADB[@]}" shell df -k /data | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')"
required_bytes=$((apk_bytes + native_library_bytes + test_apk_bytes + low_bytes + 16 * 1024 * 1024))
if ((free_bytes < required_bytes)); then
  echo "Insufficient safe install space on $SERIAL: free=$free_bytes required=$required_bytes." >&2
  exit 1
fi
"${ADB[@]}" install --streaming -r "$APK" >/dev/null
"${ADB[@]}" install --streaming -r -t "$TEST_APK" >/dev/null
"${ADB[@]}" shell pm clear "$PACKAGE" >/dev/null

read_all_logcat() {
  "${ADB[@]}" logcat -b all -d -v threadtime 2>/dev/null
}

for cycle in 1 2; do
  boundary="GAMEBOX_RELEASE_APK_CYCLE_${cycle}_$$_$RANDOM"
  "${ADB[@]}" shell log -p i -t "$LOG_TAG" "$boundary" >/dev/null
  output="$("${ADB[@]}" shell am instrument -w -r \
    -e class "$TEST_METHOD" \
    "$TEST_RUNNER" 2>&1)" || true
  if ! grep -F 'OK (' <<<"$output" >/dev/null \
    || grep -E 'FAILURES!!!|Process crashed|INSTRUMENTATION_FAILED' <<<"$output" >/dev/null; then
    printf '%s\n' "$output" >&2
    echo "Release APK instrumentation failed in cycle $cycle." >&2
    exit 1
  fi

  logs="$(read_all_logcat | gamebox_logs_after_marker "$boundary")"
  # Android force-stops every process in the instrumentation target package when
  # a target-attached test finishes. READY -> EXITING below proves Godot reached
  # its own controlled shutdown first, so that specific package-manager cleanup
  # is not a low-memory or application crash signal.
  crash_candidate_logs="$(grep -v 'due to finished inst' <<<"$logs" || true)"
  bad_logs="$(gamebox_find_crash_evidence \
    "$PACKAGE" "$GAME_PROCESS" "$TEST_PACKAGE" "__no_observed_pid__" \
    <<<"$crash_candidate_logs")"
  if [[ -n "$bad_logs" ]]; then
    printf '%s\n' "$bad_logs" >&2
    echo "Release APK crashed or ANRed in cycle $cycle." >&2
    exit 1
  fi
  gamebox_assert_markers_in_order "$READY_MARKER" "$EXITING_MARKER" <<<"$logs" || {
    printf '%s\n' "$logs" | grep -E "$PACKAGE|Godot|godot|Fatal signal|FATAL EXCEPTION|ANR" >&2 || true
    echo "Release APK did not initialize and exit Godot cleanly in cycle $cycle." >&2
    exit 1
  }
  [[ -z "$("${ADB[@]}" shell pidof "$GAME_PROCESS" 2>/dev/null | tr -d '\r')" ]] || {
    echo "Release APK left $GAME_PROCESS running after cycle $cycle." >&2
    exit 1
  }
  echo "release APK cycle $cycle passed: Godot initialized and exited cleanly"
done

echo "Exact signed release APK smoke passed twice on $SERIAL: $APK"

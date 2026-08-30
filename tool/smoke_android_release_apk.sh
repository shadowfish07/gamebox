#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="me.zqydev.gamebox"
readonly GAME_PROCESS="$PACKAGE:game"
readonly TEST_PACKAGE="$PACKAGE.release_smoke"
readonly TEST_RUNNER="$TEST_PACKAGE/androidx.test.runner.AndroidJUnitRunner"
readonly TEST_METHOD="me.zqydev.gamebox.release_smoke.ReleaseGodotSmokeTest#launchPackagedGodotHostSmoke"
readonly NATIVE_INITIALIZED_MARKER="Godot native layer initialization completed: true"
readonly NATIVE_SETUP_MARKER="Godot native layer setup completed"
readonly MAIN_LOOP_MARKER="GAMEBOX_GODOT_MAIN_LOOP_STARTED"
readonly READY_MARKER="GAMEBOX_GODOT_READY"
readonly EXITING_MARKER="GAMEBOX_GODOT_EXITING"
readonly LOG_TAG="GameboxSmoke"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# shellcheck source=tool/lib/android_smoke_log.sh
source "$ROOT_DIR/tool/lib/android_smoke_log.sh"
# shellcheck source=tool/lib/android_lease.sh
source "$ROOT_DIR/tool/lib/android_lease.sh"
# shellcheck source=tool/lib/check_output.sh
source "$ROOT_DIR/tool/lib/check_output.sh"

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

RENDERER_LIMITED_SMOKE="${GAMEBOX_ALLOW_RENDERER_LIMITED_SMOKE:-false}"
if [[ "$RENDERER_LIMITED_SMOKE" != "true" && "$RENDERER_LIMITED_SMOKE" != "false" ]]; then
  echo "GAMEBOX_ALLOW_RENDERER_LIMITED_SMOKE must be true or false." >&2
  exit 2
fi
readonly RENDERER_LIMITED_SMOKE

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

gamebox_test_output_init
trap gamebox_test_output_cleanup EXIT

gamebox_test_progress 'Release APK smoke: building signed instrumentation APK...'
build_release_smoke_test_apk() {
  (
  cd "$ROOT_DIR/app/android"
  # Signing material is intentionally created after source tests in release CI.
  # Never restore a helper APK that was cached earlier with the debug signer.
  ./gradlew --no-build-cache --rerun-tasks :release-smoke:assembleRelease
  )
}
gamebox_run_step "release smoke instrumentation build" build_release_smoke_test_apk
readonly TEST_APK="$ROOT_DIR/app/build/release-smoke/outputs/apk/release/release-smoke-release.apk"
[[ -f "$TEST_APK" ]] || {
  echo "Release instrumentation APK was not produced at $TEST_APK" >&2
  exit 1
}

signer_digest() {
  "$APKSIGNER" verify --print-certs "$1" \
    | awk -F': ' '/certificate SHA-256 digest:/ { print $NF; exit }'
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
	assets/games/chinese_checkers/chinese_checkers_scene.tscn \
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
  gamebox_android_lease_release
  gamebox_test_output_cleanup
  exit "$exit_status"
}
trap cleanup EXIT
gamebox_android_lease_acquire \
  "$ROOT_DIR" "$SERIAL release-apk-smoke" "${GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS:-900}"

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
  gamebox_test_progress "Release APK smoke: validating runtime cycle $cycle/2..."
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
  # a target-attached test finishes, so that specific package-manager cleanup is
  # not a low-memory or application crash signal.
  crash_candidate_logs="$(grep -v 'due to finished inst' <<<"$logs" || true)"
  bad_logs="$(gamebox_find_crash_evidence \
    "$PACKAGE" "$GAME_PROCESS" "$TEST_PACKAGE" "__no_observed_pid__" \
    <<<"$crash_candidate_logs")"
  if [[ -n "$bad_logs" ]]; then
    printf '%s\n' "$bad_logs" >&2
    echo "Release APK crashed or ANRed in cycle $cycle." >&2
    exit 1
  fi
  gamebox_assert_markers_in_order "$NATIVE_INITIALIZED_MARKER" "$NATIVE_SETUP_MARKER" <<<"$logs" || {
    printf '%s\n' "$logs" | grep -E "$PACKAGE|Godot|godot|Fatal signal|FATAL EXCEPTION|ANR" >&2 || true
    echo "Release APK did not initialize and set up the Godot native layer in cycle $cycle." >&2
    exit 1
  }
  if [[ "$RENDERER_LIMITED_SMOKE" == "false" ]]; then
    grep -F "$MAIN_LOOP_MARKER" <<<"$logs" >/dev/null || {
      printf '%s\n' "$logs" | grep -E "$PACKAGE|Godot|godot|Fatal signal|FATAL EXCEPTION|ANR" >&2 || true
      echo "Release APK did not reach the Godot main loop in cycle $cycle." >&2
      exit 1
    }
    # READY -> EXITING proves the packaged scene rendered and reached its own
    # controlled shutdown before instrumentation cleanup.
    gamebox_assert_markers_in_order "$READY_MARKER" "$EXITING_MARKER" <<<"$logs" || {
      printf '%s\n' "$logs" | grep -E "$PACKAGE|Godot|godot|Fatal signal|FATAL EXCEPTION|ANR" >&2 || true
      echo "Release APK did not initialize and exit Godot cleanly in cycle $cycle." >&2
      exit 1
    }
  fi
  [[ -z "$("${ADB[@]}" shell pidof "$GAME_PROCESS" 2>/dev/null | tr -d '\r')" ]] || {
    echo "Release APK left $GAME_PROCESS running after cycle $cycle." >&2
    exit 1
  }
  if [[ "${GAMEBOX_TEST_OUTPUT:-compact}" == verbose && "$RENDERER_LIMITED_SMOKE" == "true" ]]; then
    echo "release APK cycle $cycle passed: Godot native layer initialized and set up without crash or ANR"
  elif [[ "${GAMEBOX_TEST_OUTPUT:-compact}" == verbose ]]; then
    echo "release APK cycle $cycle passed: Godot scene initialized and exited cleanly"
  fi
done

warning_count="$(gamebox_test_output_warning_count)"
if [[ "$RENDERER_LIMITED_SMOKE" == "true" ]]; then
  if ((warning_count > 0)); then
    echo "Exact signed release APK native-startup smoke passed twice on $SERIAL ($warning_count warning lines): $APK"
  else
    echo "Exact signed release APK native-startup smoke passed twice on $SERIAL: $APK"
  fi
  echo "Renderer-limited mode does not claim that the Godot main loop or packaged scene reached READY."
else
  if ((warning_count > 0)); then
    echo "Exact signed release APK scene smoke passed twice on $SERIAL ($warning_count warning lines): $APK"
  else
    echo "Exact signed release APK scene smoke passed twice on $SERIAL: $APK"
  fi
fi

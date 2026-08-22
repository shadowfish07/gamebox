#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE_PACKAGE="system-images;android-36;google_apis_playstore_ps16k;arm64-v8a"
readonly IMAGE_PATH_FRAGMENT="system-images/android-36/google_apis_playstore_ps16k/arm64-v8a"
readonly DEVICE_PROFILE="pixel_7_pro"
readonly -a MANAGED_AVDS=("Gamebox_A_API_36" "Gamebox_B_API_36")
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
# shellcheck source=tool/lib/android_lease.sh
source "$ROOT_DIR/tool/lib/android_lease.sh"

cleanup() {
  local exit_status=$?
  trap - EXIT
  set +e
  gamebox_android_lease_release
  exit "$exit_status"
}
trap cleanup EXIT

gamebox_android_lease_acquire \
  "$ROOT_DIR" "Gamebox_A_API_36,Gamebox_B_API_36 configuration" \
  "${GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS:-900}"

if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  export JAVA_HOME
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi

fail() {
  printf 'Gamebox AVD setup failed: %s\n' "$1" >&2
  exit 1
}

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
readonly sdk_root
[[ -d "$sdk_root" ]] || fail "Android SDK root does not exist: $sdk_root"

avdmanager_bin="$sdk_root/cmdline-tools/latest/bin/avdmanager"
sdkmanager_bin="$sdk_root/cmdline-tools/latest/bin/sdkmanager"
emulator_bin="$sdk_root/emulator/emulator"
[[ -x "$avdmanager_bin" ]] || avdmanager_bin="$sdk_root/tools/bin/avdmanager"
[[ -x "$sdkmanager_bin" ]] || sdkmanager_bin="$sdk_root/tools/bin/sdkmanager"
[[ -x "$emulator_bin" ]] || emulator_bin="$sdk_root/tools/emulator"
readonly avdmanager_bin sdkmanager_bin emulator_bin

[[ -x "$avdmanager_bin" ]] || fail "avdmanager is missing from the Android SDK"
[[ -x "$sdkmanager_bin" ]] || fail "sdkmanager is missing from the Android SDK"
[[ -x "$emulator_bin" ]] || fail "emulator is missing from the Android SDK"

image_directory="$sdk_root/$IMAGE_PATH_FRAGMENT"
[[ -f "$image_directory/package.xml" ]] \
  || fail "required image is not installed: $IMAGE_PACKAGE (run '$sdkmanager_bin \"$IMAGE_PACKAGE\"')"

avd_exists() {
  local name="$1"
  "$emulator_bin" -list-avds 2>/dev/null | grep -Fx "$name" >/dev/null
}

validate_avd() {
  local name="$1"
  local ini_path="$HOME/.android/avd/$name.ini"
  [[ -f "$ini_path" ]] || fail "$name is listed but its .ini file is missing"

  local avd_path
  avd_path="$(sed -n 's/^path=//p' "$ini_path" | head -n 1)"
  [[ -n "$avd_path" && -d "$avd_path" ]] || fail "$name has an invalid AVD path"
  local config="$avd_path/config.ini"
  [[ -f "$config" ]] || fail "$name is missing config.ini"

  local sysdir
  sysdir="$(sed -n 's/^image\.sysdir\.1[[:space:]]*=[[:space:]]*//p' "$config" | head -n 1 | sed 's#\\#/#g')"
  [[ "$sysdir" == *"$IMAGE_PATH_FRAGMENT"* ]] \
    || fail "$name uses a different system image; refusing to overwrite it"
  grep -Eq '^hw\.device\.name[[:space:]]*=[[:space:]]*pixel_7_pro$' "$config" \
    || fail "$name does not use the required $DEVICE_PROFILE profile; refusing to overwrite it"
}

create_avd() {
  local name="$1"
  printf 'Creating %s with %s and %s...\n' "$name" "$IMAGE_PACKAGE" "$DEVICE_PROFILE"
  printf 'no\n' | "$avdmanager_bin" create avd \
    --name "$name" \
    --package "$IMAGE_PACKAGE" \
    --device "$DEVICE_PROFILE" >/dev/null
}

for avd_name in "${MANAGED_AVDS[@]}"; do
  if ! avd_exists "$avd_name"; then
    create_avd "$avd_name"
  fi
  validate_avd "$avd_name"
  printf '%s ready\n' "$avd_name"
done

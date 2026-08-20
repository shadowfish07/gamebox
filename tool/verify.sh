#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
cd "$ROOT_DIR"

# setup-godot exposes the executable on PATH in CI, while the local bootstrap
# retains its macOS application-bundle default.
if [[ -z "${GODOT_BIN:-}" ]] && command -v godot >/dev/null 2>&1; then
  export GODOT_BIN
  GODOT_BIN="$(command -v godot)"
fi

if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  export JAVA_HOME
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi

bash tool/bootstrap.sh
bash tool/verify_fast.sh

(cd app/android && ./gradlew :app:testDebugUnitTest)
(cd app && flutter build apk --debug)

readonly APK="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-debug.apk"
[[ -f "$APK" ]] || {
  printf 'Debug APK was not produced at %s\n' "$APK" >&2
  exit 1
}

apk_entries="$(unzip -Z1 "$APK")"
readonly apk_entries
for required_asset in \
  assets/project.godot \
  assets/main.gd \
  assets/main.gd.uid \
  assets/main.tscn \
  assets/core/game_registry.gd \
  assets/core/launch_config.gd \
  assets/core/match_client.gd \
  assets/core/protocol.gd \
  assets/games/gomoku/gomoku_board.gd \
  assets/games/gomoku/gomoku_controller.gd \
  assets/games/gomoku/gomoku_scene.tscn \
  assets/games/gomoku/gomoku_state.gd; do
  grep -Fx "$required_asset" <<<"$apk_entries" >/dev/null || {
    printf 'Debug APK is missing required Godot asset %s\n' "$required_asset" >&2
    exit 1
  }
done

readonly excluded_asset_pattern='^assets/(test/|\.gdignore$|\.godot/(editor/|uid_cache\.bin$|global_script_class_cache\.cfg$|filesystem_cache|.*metadata)|(.*/)?(\.env([^/]*)?|[^/]*(secret|token|credentials?|private[_-]?key)[^/]*)$)'
if grep -Ei "$excluded_asset_pattern" <<<"$apk_entries" >/dev/null; then
  printf 'Debug APK contains excluded Godot test/editor/cache or secret-named assets:\n' >&2
  grep -Ei "$excluded_asset_pattern" <<<"$apk_entries" >&2
  exit 1
fi

asset_stream="$(mktemp -t gamebox-apk-assets.XXXXXX)"
readonly asset_stream
cleanup() {
  rm -f "$asset_stream"
}
trap cleanup EXIT
unzip -p "$APK" 'assets/*' >"$asset_stream"
if LC_ALL=C grep -aE 'GAMEBOX_(JWT_SECRET|TOKEN_PEPPER)' "$asset_stream" >/dev/null; then
  printf 'Debug APK assets contain server-only secret configuration names.\n' >&2
  exit 1
fi

printf 'Verified debug APK Godot assets and exclusions: %s\n' "$APK"

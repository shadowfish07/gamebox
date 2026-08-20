#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
cd "$ROOT_DIR"

asset_path_is_forbidden() {
  local asset_path="$1"
  local relative_path component lowercase_component compact_component
  local -a path_components

  [[ "$asset_path" == assets/* ]] || return 1
  relative_path="${asset_path#assets/}"
  IFS='/' read -r -a path_components <<<"$relative_path"
  for component in "${path_components[@]}"; do
    lowercase_component="$(printf '%s' "$component" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    compact_component="$(printf '%s' "$lowercase_component" | LC_ALL=C tr -d '[:space:]_.-')"
    case "$lowercase_component" in
      *'.env'*|*secret*|*token*|*credential*) return 0 ;;
      .godot|.gdignore|test|tests|test.*|tests.*|test_*|tests_*|*_test|*_tests|*_test.*|*_tests.*) return 0 ;;
    esac
    case "$compact_component" in
      *privatekey*) return 0 ;;
    esac
  done
  return 1
}

verify_asset_path_fixtures() {
  local asset_path
  local -a forbidden_fixtures=(
    assets/credentials/config.json
    assets/games/gomoku/private_key/key.pem
    assets/games/gomoku/private-key/key.pem
    assets/.env/production
    assets/flutter_assets/config.env.local
    assets/test/run_tests.gd
    assets/games/gomoku/tests.gd
    assets/games/gomoku/gomoku_controller_test.gd
    assets/.godot/scene_groups_cache.cfg
    assets/.godot/shader_cache/cache.bin
    assets/.godot/imported/runtime-texture.ctex
  )
  local -a allowed_fixtures=(
    assets/project.godot
    assets/main.gd
    assets/core/match_client.gd
    assets/games/gomoku/gomoku_controller.gd
    assets/games/gomoku/gomoku_scene.tscn
    assets/flutter_assets/AssetManifest.bin
    assets/flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf
  )

  for asset_path in "${forbidden_fixtures[@]}"; do
    asset_path_is_forbidden "$asset_path" || {
      printf 'Forbidden APK asset fixture was accepted: %s\n' "$asset_path" >&2
      return 1
    }
  done
  for asset_path in "${allowed_fixtures[@]}"; do
    if asset_path_is_forbidden "$asset_path"; then
      printf 'Valid runtime APK asset fixture was rejected: %s\n' "$asset_path" >&2
      return 1
    fi
  done
  printf 'APK asset path fixtures passed.\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
  [[ $# -eq 1 ]] || {
    printf 'usage: %s [--self-test]\n' "$0" >&2
    exit 2
  }
  verify_asset_path_fixtures
  exit 0
fi
[[ $# -eq 0 ]] || {
  printf 'usage: %s [--self-test]\n' "$0" >&2
  exit 2
}
verify_asset_path_fixtures

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

rejected_assets=""
while IFS= read -r asset_path; do
  if asset_path_is_forbidden "$asset_path"; then
    rejected_assets+="$asset_path"$'\n'
  fi
done <<<"$apk_entries"
readonly rejected_assets
if [[ -n "$rejected_assets" ]]; then
  printf 'Debug APK contains excluded Godot test/editor/cache or secret-named assets:\n' >&2
  printf '%s' "$rejected_assets" >&2
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

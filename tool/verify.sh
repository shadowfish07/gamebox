#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
cd "$ROOT_DIR"

godot_imported_asset_is_allowed() {
  local asset_path="$1"
  [[ "$asset_path" =~ ^assets/\.godot/imported/[A-Za-z0-9][A-Za-z0-9._-]*\.ctex$ ]]
}

asset_path_is_forbidden() {
  local asset_path="$1"
  local relative_path component lowercase_component normalized_component camel_spaced
  local component_stem normalized_stem component_token previous_token token_source
  local obfuscated_keyword_re allowed_imported=0
  local -a path_components component_tokens

  [[ "$asset_path" == assets/* ]] || return 1
  godot_imported_asset_is_allowed "$asset_path" && allowed_imported=1
  if [[ "$asset_path" == assets/.godot/* && "$allowed_imported" -eq 0 ]]; then
    return 0
  fi
  relative_path="${asset_path#assets/}"
  IFS='/' read -r -a path_components <<<"$relative_path"
  for component in "${path_components[@]}"; do
    lowercase_component="$(printf '%s' "$component" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    normalized_component="$(printf '%s' "$lowercase_component" | LC_ALL=C tr -d '[:space:]_.-')"
    component_stem="${lowercase_component%.*}"
    normalized_stem="$(printf '%s' "$component_stem" | LC_ALL=C tr -d '[:space:]_.-')"
    camel_spaced="$(printf '%s' "$component" | LC_ALL=C sed -E \
      -e 's/([[:lower:][:digit:]])([[:upper:]])/\1 \2/g' \
      -e 's/([[:upper:]])([[:upper:]][[:lower:]])/\1 \2/g')"
    token_source="$(printf '%s' "$camel_spaced" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    obfuscated_keyword_re='(^|[._[:space:]-])(s[._[:space:]-]*e[._[:space:]-]*c[._[:space:]-]*r[._[:space:]-]*e[._[:space:]-]*t(s)?|t[._[:space:]-]*o[._[:space:]-]*k[._[:space:]-]*e[._[:space:]-]*n(s)?|c[._[:space:]-]*r[._[:space:]-]*e[._[:space:]-]*d[._[:space:]-]*e[._[:space:]-]*n[._[:space:]-]*t[._[:space:]-]*i[._[:space:]-]*a[._[:space:]-]*l(s)?|p[._[:space:]-]*r[._[:space:]-]*i[._[:space:]-]*v[._[:space:]-]*a[._[:space:]-]*t[._[:space:]-]*e[._[:space:]-]*k[._[:space:]-]*e[._[:space:]-]*y|t[._[:space:]-]*e[._[:space:]-]*s[._[:space:]-]*t(s)?)([._[:space:]-]|$)'

    case "$normalized_component" in
      secret|secrets|token|tokens|credential|credentials|privatekey|test|tests) return 0 ;;
      *secret|*secrets|*token|*tokens|*credential|*credentials|*privatekey) return 0 ;;
    esac
    case "$normalized_stem" in
      secret|secrets|token|tokens|credential|credentials|privatekey|test|tests) return 0 ;;
      *secret|*secrets|*token|*tokens|*credential|*credentials|*privatekey) return 0 ;;
    esac
    if [[ "$lowercase_component" == .* ]]; then
      case "$normalized_component" in
        env|gdignore) return 0 ;;
        godot)
          (( allowed_imported == 1 )) || return 0
          ;;
      esac
      case "$normalized_stem" in
        env|gdignore) return 0 ;;
        godot)
          (( allowed_imported == 1 )) || return 0
          ;;
      esac
    fi

    [[ "$lowercase_component" =~ $obfuscated_keyword_re ]] && return 0

    IFS=$'._- \t' read -r -a component_tokens <<<"$token_source"
    previous_token=""
    for component_token in "${component_tokens[@]}"; do
      case "$component_token" in
        secret|secrets|token|tokens|credential|credentials|test|tests) return 0 ;;
        env)
          [[ "$lowercase_component" == *'.env'* ]] && return 0
          ;;
        gdignore|godot)
          if [[ "$lowercase_component" == .* ]]; then
            [[ "$component_token" == godot && "$allowed_imported" -eq 1 ]] || return 0
          fi
          ;;
        key)
          [[ "$previous_token" == private ]] && return 0
          ;;
      esac
      previous_token="$component_token"
    done
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
    assets/.godot/imported/runtime-texture.bin
    assets/.godot/imported/nested/runtime-texture.ctex
    assets/.godot/imported/clientSecretValue.ctex
    assets/s_e_c_r_e_t/config.json
    assets/s_e_c_r_e_t_backup/config.json
    assets/t-o.k_e_n/data.json
    assets/cre-den_tial/config.json
    assets/t-e_s.t/run.gd
    assets/clientSecretValue.json
    assets/secretKey.pem
    assets/tokenBackup.txt
    assets/privateKeyBackup.pem
    assets/SECRETS/config.json
    assets/Access-Token/data.json
    assets/CREDENTIALS/config.json
    "assets/Private Key/key.pem"
    assets/.ENV/production
    assets/TeStS/run.gd
    assets/.GDIGNORE
    assets/.GoDoT/imported/runtime-texture.ctex
    assets/.g-o_d.o-t/cache.bin
  )
  local -a allowed_fixtures=(
    assets/project.godot
    assets/main.gd
    assets/core/match_client.gd
    assets/games/gomoku/gomoku_controller.gd
    assets/games/gomoku/gomoku_scene.tscn
    assets/flutter_assets/AssetManifest.bin
    assets/flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf
    assets/core/secretary.gd
    assets/core/tokenizer.gd
    assets/core/credentialed.gd
    assets/core/credentialsafe.gd
    assets/core/privateer-keynote.gd
    assets/core/contest.gd
    assets/core/attestation.gd
    assets/core/environment.gd
    assets/core/envoy.gd
    assets/core/.godotter/runtime.gd
    assets/core/.gdignores/runtime.gd
    assets/godot/runtime.gd
    assets/gdignore/runtime.gd
    assets/env/runtime.gd
    assets/s_e_c/r_e_t/runtime.gd
    assets/t-o/k_e_n/runtime.gd
    assets/.godot/imported/runtime-texture.ctex
    assets/clientSecretaryValue.json
    assets/tokenizerBackup.txt
    assets/credentialedConfig.json
    assets/privateKeynote.txt
    assets/contestResult.json
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

validate_apk_native_runtime() {
  local listing_text="$1"
  local source_name="$2"
  local packaged_abis expected_abis abi target
  expected_abis='arm64-v8a armeabi-v7a x86_64'
  packaged_abis="$(awk '$NF ~ /^lib\/[^\/]+\// { split($NF, parts, "/"); print parts[2] }' <<<"$listing_text" | LC_ALL=C sort -u | paste -sd ' ' -)"
  if [[ "$packaged_abis" != "$expected_abis" ]]; then
    printf '%s packages native ABIs [%s], expected exactly [%s].\n' "$source_name" "$packaged_abis" "$expected_abis" >&2
    return 1
  fi
  for abi in arm64-v8a armeabi-v7a x86_64; do
    target="lib/$abi/libgodot_android.so"
    if ! awk -v target="$target" '
      $NF == target {
        count++
        if ($1 ~ /^[0-9]+$/ && $1 > 0) valid++
      }
      END { exit !(count == 1 && valid == 1) }
    ' <<<"$listing_text"; then
      printf '%s must contain one non-empty %s.\n' "$source_name" "$target" >&2
      return 1
    fi
  done
}

verify_native_runtime_fixtures() {
  local good_listing bad_listing
  good_listing=$'71148032  01-01-1980 00:00 lib/arm64-v8a/libgodot_android.so\n74943696  01-01-1980 00:00 lib/armeabi-v7a/libgodot_android.so\n74034072  01-01-1980 00:00 lib/x86_64/libgodot_android.so'
  validate_apk_native_runtime "$good_listing" 'valid native fixture' || return 1

  bad_listing=$'71148032  01-01-1980 00:00 lib/arm64-v8a/libgodot_android.so\n74943696  01-01-1980 00:00 lib/armeabi-v7a/libgodot_android.so'
  if validate_apk_native_runtime "$bad_listing" 'missing ABI fixture' >/dev/null 2>&1; then
    printf 'Native runtime fixture accepted a missing ABI.\n' >&2
    return 1
  fi
  bad_listing=$'71148032  01-01-1980 00:00 lib/arm64-v8a/libgodot_android.so\n74943696  01-01-1980 00:00 lib/armeabi-v7a/libgodot_android.so\n0  01-01-1980 00:00 lib/x86_64/libgodot_android.so'
  if validate_apk_native_runtime "$bad_listing" 'empty library fixture' >/dev/null 2>&1; then
    printf 'Native runtime fixture accepted an empty Godot library.\n' >&2
    return 1
  fi
  bad_listing="$good_listing"$'\n1  01-01-1980 00:00 lib/riscv64/libfixture.so'
  if validate_apk_native_runtime "$bad_listing" 'extra ABI fixture' >/dev/null 2>&1; then
    printf 'Native runtime fixture accepted an unexpected ABI.\n' >&2
    return 1
  fi
  printf 'APK native runtime fixtures passed.\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
  [[ $# -eq 1 ]] || {
    printf 'usage: %s [--self-test]\n' "$0" >&2
    exit 2
  }
  verify_asset_path_fixtures
  verify_native_runtime_fixtures
  exit 0
fi
[[ $# -eq 0 ]] || {
  printf 'usage: %s [--self-test]\n' "$0" >&2
  exit 2
}
verify_asset_path_fixtures
verify_native_runtime_fixtures

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

bash tool/bootstrap.sh --build-only
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
apk_listing="$(unzip -l "$APK")"
readonly apk_listing
validate_apk_native_runtime "$apk_listing" "$APK"
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

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
cd "$ROOT_DIR"
# shellcheck source=tool/lib/check_output.sh
source "$ROOT_DIR/tool/lib/check_output.sh"

godot_imported_asset_is_allowed() {
  local asset_path="$1"
  [[ "$asset_path" =~ ^assets/\.godot/imported/[A-Za-z0-9][A-Za-z0-9._-]*\.ctex$ ]]
}

# The packaged Gamebox design system is required by the APK asset gate below.
# Its generated token file legitimately ends in "_tokens.gd", which the
# secret-name scanner would otherwise flag; these exact paths are the reviewed,
# versioned design assets and must never be treated as credentials.
design_system_asset_is_allowed() {
  local asset_path="$1"
  case "$asset_path" in
    assets/design_system/generated/gamebox_tokens.gd \
    | assets/design_system/gamebox_theme.gd \
    | assets/design_system/components/gamebox_back_button.tscn \
    | assets/design_system/components/gamebox_connection_banner.tscn \
    | assets/design_system/components/gamebox_connection_banner.gd \
    | assets/design_system/components/gamebox_snackbar.tscn \
    | assets/design_system/components/gamebox_snackbar.gd \
    | assets/design_system/components/gamebox_confirmation_dialog.tscn \
    | assets/design_system/components/gamebox_confirmation_dialog.gd \
    | assets/design_system/components/gamebox_loading_overlay.tscn \
    | assets/design_system/components/gamebox_loading_overlay.gd \
    | assets/design_system/components/gamebox_result_panel.tscn \
    | assets/design_system/components/gamebox_result_panel.gd) return 0 ;;
  esac
  return 1
}

asset_path_is_forbidden() {
  local asset_path="$1"
  local relative_path component lowercase_component normalized_component camel_spaced
  local component_stem normalized_stem component_token previous_token token_source
  local obfuscated_keyword_re allowed_imported=0
  local -a path_components component_tokens

  [[ "$asset_path" == assets/* ]] || return 1
  design_system_asset_is_allowed "$asset_path" && return 1
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
    assets/design_system/generated/gamebox_secrets.gd
    assets/design_system/components/gamebox_tokens.gd
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
    assets/design_system/generated/gamebox_tokens.gd
    assets/design_system/gamebox_theme.gd
    assets/design_system/components/gamebox_back_button.tscn
    assets/design_system/components/gamebox_connection_banner.tscn
    assets/design_system/components/gamebox_connection_banner.gd
    assets/design_system/components/gamebox_snackbar.tscn
    assets/design_system/components/gamebox_snackbar.gd
    assets/design_system/components/gamebox_confirmation_dialog.tscn
    assets/design_system/components/gamebox_confirmation_dialog.gd
    assets/design_system/components/gamebox_loading_overlay.tscn
    assets/design_system/components/gamebox_loading_overlay.gd
    assets/design_system/components/gamebox_result_panel.tscn
    assets/design_system/components/gamebox_result_panel.gd
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
  gamebox_test_output_init
  trap gamebox_test_output_cleanup EXIT
  gamebox_run_step "APK asset path fixtures" verify_asset_path_fixtures
  gamebox_run_step "APK native runtime fixtures" verify_native_runtime_fixtures
  gamebox_test_output_finish verify-self-test
  exit 0
fi
[[ $# -eq 0 ]] || {
  printf 'usage: %s [--self-test]\n' "$0" >&2
  exit 2
}
gamebox_test_output_init
trap gamebox_test_output_cleanup EXIT
gamebox_run_step "APK asset path fixtures" verify_asset_path_fixtures
gamebox_run_step "APK native runtime fixtures" verify_native_runtime_fixtures

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

gamebox_run_step "toolchain bootstrap" bash tool/bootstrap.sh --build-only
gamebox_run_step "fast verification" env GAMEBOX_TEST_NESTED=1 bash tool/verify_fast.sh

run_android_unit_tests() {
  (cd app/android && ./gradlew \
    :app:testDebugUnitTest \
    :flutter_release_updater:testDebugUnitTest)
}

run_flutter_debug_build() {
  (cd app && flutter build apk --debug)
}

gamebox_run_step "Android unit tests" run_android_unit_tests
gamebox_run_step "Flutter debug APK build" run_flutter_debug_build

verify_debug_apk() (
  readonly APK="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-debug.apk"
  [[ -f "$APK" ]] || {
    printf 'Debug APK was not produced at %s\n' "$APK" >&2
    exit 1
  }

  merged_manifests="$(find "$ROOT_DIR/app/build/app/intermediates/merged_manifests" \
    -type f -name AndroidManifest.xml -path '*debug*' 2>/dev/null || true)"
  readonly merged_manifests
  [[ -n "$merged_manifests" ]] || {
    printf 'No merged debug Android manifest was produced.\n' >&2
    exit 1
  }
  while IFS= read -r merged_manifest; do
    install_permission_count="$({
      grep -oF 'android.permission.REQUEST_INSTALL_PACKAGES' "$merged_manifest" || true
    } | wc -l | tr -d ' ')"
    if [[ "$install_permission_count" != "1" ]]; then
      printf 'Merged debug manifest must contain one updater permission (found %s): %s\n' \
        "$install_permission_count" "$merged_manifest" >&2
      exit 1
    fi
    if grep -F 'android.permission.INSTALL_PACKAGES' "$merged_manifest" >/dev/null; then
      printf 'Merged debug manifest requests privileged silent installation: %s\n' \
        "$merged_manifest" >&2
      exit 1
    fi
  done <<<"$merged_manifests"

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
    assets/games/gomoku/gomoku_state.gd \
    assets/design_system/generated/gamebox_tokens.gd \
    assets/design_system/gamebox_theme.gd \
    assets/design_system/components/gamebox_back_button.tscn \
    assets/design_system/components/gamebox_connection_banner.tscn \
    assets/design_system/components/gamebox_connection_banner.gd \
    assets/design_system/components/gamebox_snackbar.tscn \
    assets/design_system/components/gamebox_snackbar.gd \
    assets/design_system/components/gamebox_confirmation_dialog.tscn \
    assets/design_system/components/gamebox_confirmation_dialog.gd \
    assets/design_system/components/gamebox_loading_overlay.tscn \
    assets/design_system/components/gamebox_loading_overlay.gd \
    assets/design_system/components/gamebox_result_panel.tscn \
    assets/design_system/components/gamebox_result_panel.gd; do
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
  cleanup_apk_check() {
    rm -f "$asset_stream"
  }
  trap cleanup_apk_check EXIT
  unzip -p "$APK" 'assets/*' >"$asset_stream"
  if LC_ALL=C grep -aE 'GAMEBOX_(JWT_SECRET|TOKEN_PEPPER)' "$asset_stream" >/dev/null; then
    printf 'Debug APK assets contain server-only secret configuration names.\n' >&2
    exit 1
  fi
)

gamebox_run_step "debug APK assertions" verify_debug_apk
gamebox_test_output_finish verify

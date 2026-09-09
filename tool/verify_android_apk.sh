#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
cd "$ROOT_DIR"
# shellcheck source=tool/lib/check_output.sh
source "$ROOT_DIR/tool/lib/check_output.sh"

# The merged-manifest search root defaults to the Gradle build output. The
# self-test overrides it to point at fixture manifests.
GAMEBOX_ANDROID_MANIFEST_DIR="${GAMEBOX_ANDROID_MANIFEST_DIR:-$ROOT_DIR/app/build/app/intermediates/merged_manifests}"

godot_imported_asset_is_allowed() {
  local asset_path="$1"
  [[ "$asset_path" =~ ^assets/\.godot/imported/[A-Za-z0-9][A-Za-z0-9._-]*\.(ctex|oggvorbisstr)$ ]]
}

godot_imported_asset_apk_entry() {
  local import_metadata="$1"
  local imported_resource_path
  imported_resource_path="$(sed -n 's/^path="res:\/\/\(.*\)"$/\1/p' "$import_metadata")"
  [[ -n "$imported_resource_path" && "$imported_resource_path" != *$'\n'* ]] || return 1
  printf 'assets/%s\n' "$imported_resource_path"
}

# The packaged Gamebox design system is required by the asset gate below.
# Its generated token file legitimately ends in "_tokens.gd", which the
# secret-name scanner would otherwise flag; these exact paths are the reviewed,
# versioned design assets and must never be treated as credentials.
design_system_asset_is_allowed() {
  local asset_path="$1"
  case "$asset_path" in
    assets/design_system/generated/gamebox_tokens.gd \
    | assets/design_system/generated/gamebox_tokens.gd.uid \
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

validate_apk_native_runtime() {
  local listing_text="$1"
  local source_name="$2"
  local packaged_abis expected_abis abi target
  expected_abis="${3:-arm64-v8a armeabi-v7a x86_64}"
  local -a expected_abi_list
  read -r -a expected_abi_list <<<"$expected_abis"
  packaged_abis="$(awk '$NF ~ /^lib\/[^\/]+\// { split($NF, parts, "/"); print parts[2] }' <<<"$listing_text" | LC_ALL=C sort -u | paste -sd ' ' -)"
  if [[ "$packaged_abis" != "$expected_abis" ]]; then
    printf '%s packages native ABIs [%s], expected exactly [%s].\n' "$source_name" "$packaged_abis" "$expected_abis" >&2
    return 1
  fi
  for abi in "${expected_abi_list[@]}"; do
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
    assets/.godot/imported/nested/click_005.ogg-deadbeef.oggvorbisstr
    assets/.godot/imported/clientSecretValue.ogg-deadbeef.oggvorbisstr
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
    assets/.godot/imported/click_005.ogg-94443a2c5bdaadffa9458e93d03768aa.oggvorbisstr
    assets/clientSecretaryValue.json
    assets/tokenizerBackup.txt
    assets/credentialedConfig.json
    assets/privateKeynote.txt
    assets/contestResult.json
    assets/design_system/generated/gamebox_tokens.gd
    assets/design_system/generated/gamebox_tokens.gd.uid
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
  local arm64_listing
  arm64_listing=$'71148032  01-01-1980 00:00 lib/arm64-v8a/libgodot_android.so'
  validate_apk_native_runtime "$arm64_listing" 'ARM64 release fixture' arm64-v8a || return $?
  for bad_listing in "$good_listing" \
    '0  01-01-1980 00:00 lib/arm64-v8a/libgodot_android.so' \
    '1  01-01-1980 00:00 lib/arm64-v8a/libflutter.so'; do
    if validate_apk_native_runtime "$bad_listing" 'invalid ARM64 fixture' arm64-v8a >/dev/null 2>&1; then
      printf 'ARM64 runtime fixture accepted extra ABIs or missing/empty Godot library.\n' >&2
      return 1
    fi
  done

  bad_listing="$good_listing"$'\n1  01-01-1980 00:00 lib/riscv64/libfixture.so'
  if validate_apk_native_runtime "$bad_listing" 'extra ABI fixture' >/dev/null 2>&1; then
    printf 'Native runtime fixture accepted an unexpected ABI.\n' >&2
    return 1
  fi
}

readonly -a GAMEBOX_REQUIRED_APK_ASSETS=(
  assets/project.godot
  assets/main.gd
  assets/main.gd.uid
  assets/main.tscn
  assets/core/game_registry.gd
  assets/core/launch_config.gd
  assets/core/match_client.gd
  assets/core/protocol.gd
  assets/games/chinese_checkers/chinese_checkers_board.gd
  assets/games/chinese_checkers/chinese_checkers_controller.gd
  assets/games/chinese_checkers/chinese_checkers_scene.tscn
  assets/games/chinese_checkers/chinese_checkers_state.gd
  assets/games/shared/assets/click_005.ogg
  assets/games/shared/assets/click_005.ogg.import
  assets/games/gomoku/gomoku_board.gd
  assets/games/gomoku/gomoku_controller.gd
  assets/games/gomoku/gomoku_preferences.gd
  assets/games/gomoku/gomoku_scene.tscn
  assets/games/gomoku/gomoku_state.gd
  assets/games/gomoku/gomoku_switch_visual.gd
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

manifest_variant_for_apk() {
  local apk_name
  apk_name="$(basename "$1")"
  case "$apk_name" in
    *debug.apk) printf 'debug\n' ;;
    *release.apk) printf 'release\n' ;;
    *) return 1 ;;
  esac
}

# $1 = APK path, $2 = merged-manifest variant (debug|release). The subshell
# body keeps exit failures contained when this function runs through
# gamebox_run_step or the self-test.
verify_apk_packaging() (
  local apk="$1"
  local variant="$2"
  [[ -f "$apk" ]] || {
    printf 'APK was not produced at %s\n' "$apk" >&2
    exit 1
  }

  merged_manifests="$(find "$GAMEBOX_ANDROID_MANIFEST_DIR" \
    -type f -name AndroidManifest.xml -path "*$variant*" 2>/dev/null || true)"
  [[ -n "$merged_manifests" ]] || {
    printf 'No merged %s Android manifest was produced under %s.\n' \
      "$variant" "$GAMEBOX_ANDROID_MANIFEST_DIR" >&2
    exit 1
  }
  while IFS= read -r merged_manifest; do
    install_permission_count="$({
      grep -oF 'android.permission.REQUEST_INSTALL_PACKAGES' "$merged_manifest" || true
    } | wc -l | tr -d ' ')"
    if [[ "$install_permission_count" != "1" ]]; then
      printf 'Merged %s manifest must contain one updater permission (found %s): %s\n' \
        "$variant" "$install_permission_count" "$merged_manifest" >&2
      exit 1
    fi
    if grep -F 'android.permission.INSTALL_PACKAGES' "$merged_manifest" >/dev/null; then
      printf 'Merged %s manifest requests privileged silent installation: %s\n' \
        "$variant" "$merged_manifest" >&2
      exit 1
    fi
  done <<<"$merged_manifests"

  apk_entries="$(unzip -Z1 "$apk")" || exit $?
  apk_listing="$(unzip -l "$apk")" || exit $?
  # Universal builds are the default; ARM64 release CI supplies its exact ABI set.
  validate_apk_native_runtime "$apk_listing" "$apk" \
    "${GAMEBOX_EXPECTED_APK_ABIS:-arm64-v8a armeabi-v7a x86_64}" || exit $?
  local required_asset
  for required_asset in "${GAMEBOX_REQUIRED_APK_ASSETS[@]}"; do
    grep -Fx "$required_asset" <<<"$apk_entries" >/dev/null || {
      printf 'APK is missing required Godot asset %s\n' "$required_asset" >&2
      exit 1
    }
  done
  move_sound_import="$ROOT_DIR/game_runtime/games/shared/assets/click_005.ogg.import"
  if ! move_sound_apk_entry="$(godot_imported_asset_apk_entry "$move_sound_import")" \
    || ! godot_imported_asset_is_allowed "$move_sound_apk_entry"; then
    printf 'Confirmed-move audio import metadata has an invalid target path\n' >&2
    exit 1
  fi
  if ! grep -Fxq "$move_sound_apk_entry" <<<"$apk_entries"; then
    printf 'APK is missing the imported confirmed-move audio stream\n' >&2
    exit 1
  fi

  rejected_assets=""
  while IFS= read -r asset_path; do
    if asset_path_is_forbidden "$asset_path"; then
      rejected_assets+="$asset_path"$'\n'
    fi
  done <<<"$apk_entries"
  if [[ -n "$rejected_assets" ]]; then
    printf 'APK contains excluded Godot test/editor/cache or secret-named assets:\n' >&2
    printf '%s' "$rejected_assets" >&2
    exit 1
  fi

  asset_stream="$(mktemp -t gamebox-apk-assets.XXXXXX)" || exit $?
  cleanup_apk_check() {
    rm -f "$asset_stream"
  }
  trap cleanup_apk_check EXIT
  unzip -p "$apk" 'assets/*' >"$asset_stream" || exit $?
  if LC_ALL=C grep -aE 'GAMEBOX_(JWT_SECRET|TOKEN_PEPPER)' "$asset_stream" >/dev/null; then
    printf 'APK assets contain server-only secret configuration names.\n' >&2
    exit 1
  fi
)

write_fixture_manifest() {
  local manifest_dir="$1" variant="$2" request_count="${3:-1}" with_privileged="${4:-0}"
  local i
  mkdir -p "$manifest_dir/$variant" || return $?
  {
    printf '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
    if ((with_privileged)); then
      printf '    <uses-permission android:name="android.permission.INSTALL_PACKAGES"/>\n'
    fi
    for ((i = 0; i < request_count; i++)); do
      printf '    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>\n'
    done
    printf '</manifest>\n'
  } >"$manifest_dir/$variant/AndroidManifest.xml" || return $?
}

# Stages a synthetic APK containing the required asset list (optionally with
# one required asset removed, one extra entry added, a poisoned asset body, or
# a missing native ABI) plus one Godot library per packaged ABI.
stage_fixture_apk() {
  local fixture_root="$1" apk_variant="$2"
  shift 2
  local without_asset="" extra_entry="" poison_entry="" without_abi=""
  while (($#)); do
    case "$1" in
      --without) without_asset="$2"; shift 2 ;;
      --with) extra_entry="$2"; shift 2 ;;
      --poison) poison_entry="$2"; shift 2 ;;
      --without-abi) without_abi="$2"; shift 2 ;;
      *)
        printf 'stage_fixture_apk: invalid argument %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local fixture_apk="$fixture_root/app-${apk_variant}.apk"
  local staging entry move_sound_entry
  staging="$fixture_root/staging-${apk_variant}"
  mkdir -p "$staging" || return $?
  for entry in "${GAMEBOX_REQUIRED_APK_ASSETS[@]}"; do
    if [[ "$entry" == "$without_asset" ]]; then
      continue
    fi
    mkdir -p "$staging/$(dirname "$entry")" || return $?
    if [[ "$entry" == "$poison_entry" ]]; then
      printf 'GAMEBOX_JWT_SECRET=fixture-poison\n' >"$staging/$entry" || return $?
    else
      printf 'fixture-asset\n' >"$staging/$entry" || return $?
    fi
  done
  if [[ -n "$extra_entry" ]]; then
    mkdir -p "$staging/$(dirname "$extra_entry")" || return $?
    printf 'fixture-asset\n' >"$staging/$extra_entry" || return $?
  fi
  move_sound_entry="$(godot_imported_asset_apk_entry "$ROOT_DIR/game_runtime/games/shared/assets/click_005.ogg.import")" || return $?
  mkdir -p "$staging/$(dirname "$move_sound_entry")" || return $?
  printf 'fixture-audio\n' >"$staging/$move_sound_entry" || return $?
  for entry in arm64-v8a armeabi-v7a x86_64; do
    if [[ "$entry" == "$without_abi" ]]; then
      continue
    fi
    mkdir -p "$staging/lib/$entry" || return $?
    printf 'libgodot-android-fixture\n' >"$staging/lib/$entry/libgodot_android.so" || return $?
  done
  (cd "$staging" && zip -q -r -D "$fixture_apk" assets lib) || return $?
  printf '%s\n' "$fixture_apk"
}

expect_packaging_success() {
  local description="$1" apk="$2" variant="$3" manifest_dir="$4"
  local output
  if ! output="$(GAMEBOX_ANDROID_MANIFEST_DIR="$manifest_dir" \
    verify_apk_packaging "$apk" "$variant" 2>&1)"; then
    printf '%s\n' "$output" >&2
    printf 'Valid packaging fixture was rejected: %s\n' "$description" >&2
    return 1
  fi
}

expect_packaging_failure() {
  local description="$1" expected="$2" apk="$3" variant="$4" manifest_dir="$5"
  local output status=0
  output="$(GAMEBOX_ANDROID_MANIFEST_DIR="$manifest_dir" \
    verify_apk_packaging "$apk" "$variant" 2>&1)" || status=$?
  if ((status == 0)); then
    printf 'Packaging fixture unexpectedly passed: %s\n' "$description" >&2
    return 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    printf 'Packaging fixture %s failed without expected diagnostic: %s\n' \
      "$description" "$expected" >&2
    return 1
  fi
}

verify_packaging_gate_fixtures() (
  local fixture_root base_manifest_dir variant_manifest_dir apk variant_status=0 variant
  fixture_root="$(mktemp -d -t gamebox-verify-android-apk.XXXXXX)" || return $?
  trap 'rm -rf -- "$fixture_root"' EXIT
  # gamebox_run_step runs this in a conditional; propagate failures explicitly.
  base_manifest_dir="$fixture_root/manifests-base"
  write_fixture_manifest "$base_manifest_dir" release 1 0 || return $?

  apk="$(stage_fixture_apk "$fixture_root" valid-release)" || return $?
  expect_packaging_success "valid release APK" "$apk" release "$base_manifest_dir" || return $?

  variant="$(manifest_variant_for_apk "$apk")" || variant_status=$?
  if ((variant_status != 0)) || [[ "$variant" != release ]]; then
    printf 'Packaging fixture did not derive the release variant from %s\n' "$apk" >&2
    return 1
  fi

  apk="$(stage_fixture_apk "$fixture_root" missing-asset \
    --without assets/core/protocol.gd)" || return $?
  expect_packaging_failure "missing required asset" \
    'missing required Godot asset assets/core/protocol.gd' "$apk" release "$base_manifest_dir" || return $?

  apk="$(stage_fixture_apk "$fixture_root" missing-abi --without-abi x86_64)" || return $?
  expect_packaging_failure "missing packaged ABI" \
    'expected exactly [arm64-v8a armeabi-v7a x86_64]' "$apk" release "$base_manifest_dir" || return $?

  apk="$(stage_fixture_apk "$fixture_root" forbidden-asset \
    --with assets/test/run_tests.gd)" || return $?
  expect_packaging_failure "forbidden asset entry" \
    'excluded Godot test/editor/cache or secret-named assets' "$apk" release "$base_manifest_dir" || return $?

  apk="$(stage_fixture_apk "$fixture_root" poisoned-asset \
    --poison assets/core/protocol.gd)" || return $?
  expect_packaging_failure "server-only secret name in asset body" \
    'server-only secret configuration names' "$apk" release "$base_manifest_dir" || return $?

  variant_manifest_dir="$fixture_root/manifests-zero-permissions"
  write_fixture_manifest "$variant_manifest_dir" release 0 0 || return $?
  apk="$(stage_fixture_apk "$fixture_root" zero-permissions)" || return $?
  expect_packaging_failure "missing updater permission" \
    'must contain one updater permission (found 0)' "$apk" release "$variant_manifest_dir" || return $?

  variant_manifest_dir="$fixture_root/manifests-privileged"
  write_fixture_manifest "$variant_manifest_dir" release 1 1 || return $?
  apk="$(stage_fixture_apk "$fixture_root" privileged)" || return $?
  expect_packaging_failure "privileged silent installation permission" \
    'requests privileged silent installation' "$apk" release "$variant_manifest_dir" || return $?

  variant_status=0
  variant="$(manifest_variant_for_apk "$fixture_root/unrelated.bin")" || variant_status=$?
  if ((variant_status == 0)); then
    printf 'Packaging fixture derived a variant from an unsupported APK name\n' >&2
    return 1
  fi

  return 0
)

usage() {
  printf 'usage: %s [--self-test] | <path-to-apk>\n' "$0" >&2
}

if [[ "${1:-}" == "--self-test" ]]; then
  [[ $# -eq 1 ]] || {
    usage
    exit 2
  }
  gamebox_test_output_init
  trap gamebox_test_output_cleanup EXIT
  gamebox_run_step "APK asset path fixtures" verify_asset_path_fixtures
  gamebox_run_step "APK native runtime fixtures" verify_native_runtime_fixtures
  gamebox_run_step "APK packaging gate fixtures" verify_packaging_gate_fixtures
  gamebox_test_output_finish verify-android-apk-self-test
  exit 0
fi
[[ $# -eq 1 ]] || {
  usage
  exit 2
}
apk_path="$1"
variant="$(manifest_variant_for_apk "$apk_path")" || {
  printf 'Cannot infer a debug/release manifest variant from %s\n' "$apk_path" >&2
  usage
  exit 2
}
gamebox_test_output_init
trap gamebox_test_output_cleanup EXIT
gamebox_run_step "APK asset path fixtures" verify_asset_path_fixtures
gamebox_run_step "APK native runtime fixtures" verify_native_runtime_fixtures
gamebox_run_step "APK packaging assertions" verify_apk_packaging "$apk_path" "$variant"
gamebox_test_output_finish verify-android-apk

#!/bin/zsh
set -euo pipefail

readonly keychain_account="${USER}"
readonly jwt_service="${GAMEBOX_JWT_SERVICE:-me.zqydev.gamebox.jwt-secret}"
readonly pepper_service="${GAMEBOX_TOKEN_PEPPER_SERVICE:-me.zqydev.gamebox.token-pepper}"
readonly script_dir="${0:A:h}"
typeset -a keychain_args=()

if [[ -n "${GAMEBOX_KEYCHAIN:-}" ]]; then
  keychain_args=("${GAMEBOX_KEYCHAIN}")
fi

export GAMEBOX_JWT_SECRET="$(/usr/bin/security find-generic-password \
  -a "${keychain_account}" -s "${jwt_service}" -w "${keychain_args[@]}")"
export GAMEBOX_TOKEN_PEPPER="$(/usr/bin/security find-generic-password \
  -a "${keychain_account}" -s "${pepper_service}" -w "${keychain_args[@]}")"

exec "${script_dir}/gameboxd"

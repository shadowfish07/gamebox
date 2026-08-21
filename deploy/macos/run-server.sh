#!/bin/zsh
set -euo pipefail

readonly keychain_account="${USER}"
readonly jwt_service="me.zqydev.gamebox.jwt-secret"
readonly pepper_service="me.zqydev.gamebox.token-pepper"
readonly script_dir="${0:A:h}"

export GAMEBOX_JWT_SECRET="$(/usr/bin/security find-generic-password \
  -a "${keychain_account}" -s "${jwt_service}" -w)"
export GAMEBOX_TOKEN_PEPPER="$(/usr/bin/security find-generic-password \
  -a "${keychain_account}" -s "${pepper_service}" -w)"

exec "${script_dir}/gameboxd"

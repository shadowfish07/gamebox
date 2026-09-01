#!/bin/zsh
set -euo pipefail
umask 077

readonly usage="usage: create-invite.sh <production|staging> [count]"

select_environment() {
  local environment="$1"

  case "${environment}" in
    production)
      typeset -g service_prefix="${HOME}/.local/libexec/gamebox"
      typeset -g database_path="${HOME}/Library/Application Support/Gamebox/server/gamebox.db"
      typeset -g pepper_service="me.zqydev.gamebox.token-pepper"
      typeset -g server_label="me.zqydev.gamebox.server"
      typeset -g local_health_url="http://127.0.0.1:18080/healthz"
      ;;
    staging)
      typeset -g service_prefix="${HOME}/.local/libexec/gamebox-staging"
      typeset -g database_path="${HOME}/Library/Application Support/Gamebox/server-staging/gamebox.db"
      typeset -g pepper_service="me.zqydev.gamebox.staging.token-pepper"
      typeset -g server_label="me.zqydev.gamebox.staging.server"
      typeset -g local_health_url="http://127.0.0.1:18081/healthz"
      ;;
    *)
      print -u2 -- "${usage}"
      return 2
      ;;
  esac
  typeset -g control_binary="${service_prefix}/gameboxctl"
  typeset -g server_program="${service_prefix}/run-server.sh"
}

validate_count() {
  local count="$1"
  if [[ "${count}" != <-> ]] || (( count < 1 || count > 1000 )); then
    print -u2 -- "count must be an integer between 1 and 1000"
    return 2
  fi
}

check_runtime() {
  local domain="gui/$(/usr/bin/id -u)"
  local service_state
  local health_body

  if [[ ! -x "${control_binary}" ]]; then
    print -u2 -- "gameboxctl is not installed for the selected environment"
    return 1
  fi
  if [[ ! -f "${database_path}" ]]; then
    print -u2 -- "the selected environment database does not exist"
    return 1
  fi
  service_state="$(/bin/launchctl print "${domain}/${server_label}" 2>/dev/null)" || {
    print -u2 -- "the selected environment service is not loaded"
    return 1
  }
  if [[ "${service_state}" != *"program = ${server_program}"* ]] \
    || [[ "${service_state}" != *"GAMEBOX_DB_PATH => ${database_path}"* ]]; then
    print -u2 -- "the selected service is not using the expected executable or database"
    return 1
  fi
  health_body="$(/usr/bin/curl --fail --silent --show-error --max-time 5 "${local_health_url}")" || {
    print -u2 -- "the selected environment is not healthy"
    return 1
  }
  if [[ "${health_body}" != '{"status":"ok"}' ]]; then
    print -u2 -- "the selected environment returned an unexpected health response"
    return 1
  fi
}

read_keychain_pepper() {
  /usr/bin/security find-generic-password \
    -a "$(/usr/bin/id -un)" -s "${pepper_service}" -w
}

invoke_gameboxctl() {
  local count="$1"
  local pepper="$2"

  GAMEBOX_TOKEN_PEPPER="${pepper}" "${control_binary}" invite create \
    --count "${count}" --db "${database_path}" --json
}

main() {
  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print -- "${usage}"
    return 0
  fi
  if (( $# < 1 || $# > 2 )); then
    print -u2 -- "${usage}"
    return 2
  fi

  local environment="$1"
  local count="${2:-1}"
  local pepper

  select_environment "${environment}" || return $?
  validate_count "${count}" || return $?
  check_runtime || return $?
  pepper="$(read_keychain_pepper)" || {
    print -u2 -- "could not read the selected environment token pepper"
    return 1
  }
  if (( ${#pepper} < 32 )); then
    print -u2 -- "the selected environment token pepper is invalid"
    return 1
  fi
  invoke_gameboxctl "${count}" "${pepper}"
}

if [[ "${ZSH_EVAL_CONTEXT}" != *:file ]]; then
  main "$@"
fi

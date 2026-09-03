#!/bin/zsh
set -euo pipefail
umask 077

verbose=false
if (( $# == 1 )) && [[ "$1" == "--verbose" ]]; then
  verbose=true
elif (( $# != 0 )); then
  print -u2 -- "usage: install.sh [--verbose]"
  exit 2
fi

if (( EUID == 0 )); then
  print -u2 -- "Run install.sh as the service user, without sudo"
  exit 2
fi

readonly script_dir="${0:A:h}"
readonly repo_root="${script_dir:h:h}"
readonly service_user="$(/usr/bin/id -un)"
readonly service_uid="$(/usr/bin/id -u)"
readonly service_group="$(/usr/bin/id -gn)"
readonly service_home="${HOME}"
readonly service_prefix="${service_home}/.local/libexec/gamebox"
readonly config_dir="${service_home}/.config/gamebox"
readonly data_dir="${service_home}/Library/Application Support/Gamebox/server"
readonly log_dir="${service_home}/Library/Logs/Gamebox"
readonly legacy_launch_dir="${service_home}/Library/LaunchAgents"
readonly legacy_archive_dir="${config_dir}/legacy-launchagents"
readonly launch_dir="/Library/LaunchDaemons"
readonly system_domain="system"
readonly system_keychain="/Library/Keychains/System.keychain"
readonly jwt_service="me.zqydev.gamebox.jwt-secret"
readonly pepper_service="me.zqydev.gamebox.token-pepper"
readonly server_label="me.zqydev.gamebox.server"
readonly health_label="me.zqydev.gamebox.health"
readonly backup_label="me.zqydev.gamebox.backup"
readonly tunnel_label="me.zqydev.gamebox.tunnel"
readonly labels=("${server_label}" "${tunnel_label}" "${health_label}" "${backup_label}")
readonly public_health_url="${GAMEBOX_PUBLIC_HEALTH_URL:-https://gamebox.zqydev.me/healthz}"
readonly local_health_url="${GAMEBOX_LOCAL_HEALTH_URL:-http://127.0.0.1:18080/healthz}"
readonly privileged_installer="${script_dir}/install-system-services.sh"

temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gamebox-deploy.XXXXXX")"
trap '/bin/rm -rf "${temporary_dir}"' EXIT
readonly generated_plist_dir="${temporary_dir}/plists"
readonly secret_dir="${temporary_dir}/secrets"
/usr/bin/install -d -m 700 "${generated_plist_dir}" "${secret_dir}"

verbose_log() {
  if [[ "${verbose}" == true ]]; then
    print -- "$@"
  fi
}

run_captured_phase() {
  local phase="$1"
  shift
  local output status
  if output="$("$@" 2>&1)"; then
    if [[ "${verbose}" == true && -n "${output}" ]]; then
      print -- "${output}"
    elif [[ "${output}" == *"WARN:"* ]]; then
      print -r -- "${output}" | /usr/bin/awk '/^WARN:/ {print > "/dev/stderr"}'
    fi
    return 0
  else
    status=$?
    print -u2 -- "${phase} failed"
    if [[ -n "${output}" ]]; then
      print -u2 -- "${output}"
    fi
    return "${status}"
  fi
}

run_privileged_installer() {
  if [[ -t 0 && -t 1 ]]; then
    /usr/bin/sudo -v
    run_captured_phase "system service migration" /usr/bin/sudo -n /bin/zsh \
      "${privileged_installer}" "${service_user}" "${service_uid}" \
      "${generated_plist_dir}" "${legacy_launch_dir}" "${legacy_archive_dir}" "${secret_dir}"
    return
  fi

  run_captured_phase "system service migration" /usr/bin/osascript \
    -e 'on run argv' \
    -e 'set command_text to "/bin/zsh"' \
    -e 'repeat with argument_text in argv' \
    -e 'set command_text to command_text & " " & quoted form of (argument_text as text)' \
    -e 'end repeat' \
    -e 'do shell script command_text with administrator privileges' \
    -e 'end run' \
    -- "${privileged_installer}" "${service_user}" "${service_uid}" \
    "${generated_plist_dir}" "${legacy_launch_dir}" "${legacy_archive_dir}" "${secret_dir}"
}

verbose_log "Building production binaries"
/usr/bin/install -d -m 700 "${service_prefix}" "${config_dir}" "${data_dir}" "${data_dir}/backups" "${log_dir}"
(
  cd "${repo_root}/server"
  /usr/bin/env go build -trimpath -o "${temporary_dir}/gameboxd" ./cmd/gameboxd
  /usr/bin/env go build -trimpath -o "${temporary_dir}/gameboxctl" ./cmd/gameboxctl
)
/usr/bin/install -m 500 "${temporary_dir}/gameboxd" "${service_prefix}/gameboxd"
/usr/bin/install -m 500 "${temporary_dir}/gameboxctl" "${service_prefix}/gameboxctl"
/usr/bin/install -m 500 "${script_dir}/run-server.sh" "${service_prefix}/run-server.sh"
/usr/bin/install -m 500 "${script_dir}/health-check.sh" "${service_prefix}/health-check.sh"
/usr/bin/install -m 500 "${script_dir}/backup.sh" "${service_prefix}/backup.sh"

readonly tunnel_credentials_source="${service_home}/.cloudflared/498bfaa8-584d-4111-a4fa-13e7deec223c.json"
readonly tunnel_credentials="${config_dir}/tunnel-credentials.json"
readonly tunnel_config="${config_dir}/cloudflared.yml"
if [[ ! -f "${tunnel_credentials_source}" ]]; then
  print -u2 -- "Missing Gamebox Cloudflare Tunnel credentials"
  exit 1
fi
/usr/bin/install -m 600 "${tunnel_credentials_source}" "${tunnel_credentials}"
/usr/bin/sed "s|__GAMEBOX_TUNNEL_CREDENTIALS__|${tunnel_credentials}|" \
  "${script_dir}/cloudflared-config.yml" > "${tunnel_config}"
/bin/chmod 600 "${tunnel_config}"

ensure_login_keychain_secret() {
  local service="$1"
  if /usr/bin/security find-generic-password -a "${service_user}" -s "${service}" >/dev/null 2>&1; then
    return
  fi
  local secret
  secret="$(/usr/bin/openssl rand -base64 48)"
  /usr/bin/security add-generic-password -a "${service_user}" -s "${service}" -w "${secret}" >/dev/null
}

ensure_login_keychain_secret "${jwt_service}"
ensure_login_keychain_secret "${pepper_service}"

new_daemon_plist() {
  local path="$1"
  local label="$2"
  local program="$3"
  /bin/rm -f "${path}"
  /usr/libexec/PlistBuddy -c "Add :Label string ${label}" "${path}" >/dev/null
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "${path}"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string ${program}" "${path}"
  /usr/libexec/PlistBuddy -c "Add :UserName string ${service_user}" "${path}"
  /usr/libexec/PlistBuddy -c "Add :GroupName string ${service_group}" "${path}"
  /usr/libexec/PlistBuddy -c 'Add :ProcessType string Background' "${path}"
  /usr/libexec/PlistBuddy -c 'Add :Umask integer 63' "${path}"
  /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' "${path}"
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:HOME string ${service_home}" "${path}"
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:USER string ${service_user}" "${path}"
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:LOGNAME string ${service_user}" "${path}"
}

readonly server_plist="${generated_plist_dir}/${server_label}.plist"
new_daemon_plist "${server_plist}" "${server_label}" "${service_prefix}/run-server.sh"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "${server_plist}"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "${server_plist}"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 5' "${server_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string ${log_dir}/server.log" "${server_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string ${log_dir}/server.log" "${server_plist}"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:GAMEBOX_ADDR string 127.0.0.1:18080' "${server_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_DB_PATH string '${data_dir}/gamebox.db'" "${server_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_KEYCHAIN string ${system_keychain}" "${server_plist}"

readonly health_plist="${generated_plist_dir}/${health_label}.plist"
new_daemon_plist "${health_plist}" "${health_label}" "${service_prefix}/health-check.sh"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "${health_plist}"
/usr/libexec/PlistBuddy -c 'Add :StartInterval integer 300' "${health_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string ${log_dir}/health.log" "${health_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string ${log_dir}/health.log" "${health_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_LOCAL_HEALTH_URL string ${local_health_url}" "${health_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_PUBLIC_HEALTH_URL string ${public_health_url}" "${health_plist}"

readonly backup_plist="${generated_plist_dir}/${backup_label}.plist"
new_daemon_plist "${backup_plist}" "${backup_label}" "${service_prefix}/backup.sh"
/usr/libexec/PlistBuddy -c 'Add :StartCalendarInterval dict' "${backup_plist}"
/usr/libexec/PlistBuddy -c 'Add :StartCalendarInterval:Hour integer 3' "${backup_plist}"
/usr/libexec/PlistBuddy -c 'Add :StartCalendarInterval:Minute integer 15' "${backup_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string ${log_dir}/backup.log" "${backup_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string ${log_dir}/backup.log" "${backup_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_DATA_DIR string '${data_dir}'" "${backup_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_DB_PATH string '${data_dir}/gamebox.db'" "${backup_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_BACKUP_DIR string '${data_dir}/backups'" "${backup_plist}"

readonly tunnel_plist="${generated_plist_dir}/${tunnel_label}.plist"
new_daemon_plist "${tunnel_plist}" "${tunnel_label}" "/opt/homebrew/bin/cloudflared"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string --config" "${tunnel_plist}"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string ${tunnel_config}" "${tunnel_plist}"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:3 string tunnel' "${tunnel_plist}"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:4 string run' "${tunnel_plist}"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "${tunnel_plist}"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "${tunnel_plist}"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 5' "${tunnel_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string ${log_dir}/tunnel.log" "${tunnel_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string ${log_dir}/tunnel.log" "${tunnel_plist}"

/bin/chmod 600 "${server_plist}" "${health_plist}" "${backup_plist}" "${tunnel_plist}"
for plist in "${server_plist}" "${tunnel_plist}" "${health_plist}" "${backup_plist}"; do
  /usr/bin/plutil -lint "${plist}" >/dev/null
done

privileged_install_required=false
for label in "${labels[@]}"; do
  if [[ ! -f "${launch_dir}/${label}.plist" ]] \
    || ! /usr/bin/cmp -s "${generated_plist_dir}/${label}.plist" "${launch_dir}/${label}.plist" \
    || ! /bin/launchctl print "${system_domain}/${label}" >/dev/null 2>&1; then
    privileged_install_required=true
  fi
done
for service in "${jwt_service}" "${pepper_service}"; do
  if ! /usr/bin/security find-generic-password -a "${service_user}" -s "${service}" \
    "${system_keychain}" >/dev/null 2>&1; then
    privileged_install_required=true
  fi
done

migration_performed=false
if [[ "${privileged_install_required}" == true ]]; then
  verbose_log "Preparing one-time system service migration"
  for service_and_file in "${jwt_service}:jwt-secret" "${pepper_service}:token-pepper"; do
    service="${service_and_file%%:*}"
    filename="${service_and_file#*:}"
    if ! /usr/bin/security find-generic-password -a "${service_user}" -s "${service}" \
      -w "${system_keychain}" > "${secret_dir}/${filename}" 2>/dev/null; then
      /usr/bin/security find-generic-password -a "${service_user}" -s "${service}" \
        -w > "${secret_dir}/${filename}"
    fi
    /bin/chmod 600 "${secret_dir}/${filename}"
  done
  print -- "Installing boot-time services (administrator authentication required once)..."
  run_privileged_installer
  migration_performed=true
fi

restart_owned_keepalive_job() {
  local label="$1"
  local launch_program="$2"
  local process_program="$3"
  local state pid process_uid process_command
  state="$(/bin/launchctl print "${system_domain}/${label}" 2>/dev/null)" || {
    print -u2 -- "system service is not loaded: ${label}"
    return 1
  }
  if [[ "${state}" != *"program = ${launch_program}"* ]]; then
    print -u2 -- "system service uses an unexpected program: ${label}"
    return 1
  fi
  pid="$(print -r -- "${state}" | /usr/bin/awk '/^[[:space:]]*pid = / {print $3; exit}')"
  if [[ "${pid}" != <-> ]]; then
    print -u2 -- "system service has no running process: ${label}"
    return 1
  fi
  process_uid="$(/bin/ps -o uid= -p "${pid}" | /usr/bin/tr -d ' ')"
  process_command="$(/bin/ps -o command= -p "${pid}")"
  if [[ "${process_uid}" != "${service_uid}" || "${process_command}" != "${process_program}"* ]]; then
    print -u2 -- "refusing to signal an unexpected process for ${label}"
    return 1
  fi
  /bin/kill -TERM "${pid}"
}

if [[ "${migration_performed}" != true ]]; then
  verbose_log "Restarting production server and tunnel"
  restart_owned_keepalive_job "${server_label}" "${service_prefix}/run-server.sh" "${service_prefix}/gameboxd"
  restart_owned_keepalive_job "${tunnel_label}" "/opt/homebrew/bin/cloudflared" "/opt/homebrew/bin/cloudflared"
fi

wait_for_health() {
  local name="$1"
  local url="$2"
  local max_time="$3"
  local body
  for attempt in {1..60}; do
    body="$(/usr/bin/curl --fail --silent --max-time "${max_time}" "${url}" 2>/dev/null)" || true
    if [[ "${body}" == '{"status":"ok"}' ]]; then
      return 0
    fi
    /bin/sleep 0.5
  done
  print -u2 -- "${name} health did not become ready"
  return 1
}

verbose_log "Verifying production health and backup"
wait_for_health local "${local_health_url}" 2
wait_for_health public "${public_health_url}" 5
run_captured_phase "health check" "${service_prefix}/health-check.sh"
run_captured_phase "verified backup" "${service_prefix}/backup.sh"

print -- "Gamebox installed: boot=system local=ok public=ok backup=ok"

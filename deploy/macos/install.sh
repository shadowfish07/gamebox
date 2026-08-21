#!/bin/zsh
set -euo pipefail
umask 077

readonly script_dir="${0:A:h}"
readonly repo_root="${script_dir:h:h}"
readonly service_prefix="${HOME}/.local/libexec/gamebox"
readonly config_dir="${HOME}/.config/gamebox"
readonly data_dir="${HOME}/Library/Application Support/Gamebox/server"
readonly log_dir="${HOME}/Library/Logs/Gamebox"
readonly launch_dir="${HOME}/Library/LaunchAgents"
readonly domain="gui/$(/usr/bin/id -u)"
readonly jwt_service="me.zqydev.gamebox.jwt-secret"
readonly pepper_service="me.zqydev.gamebox.token-pepper"
readonly server_label="me.zqydev.gamebox.server"
readonly health_label="me.zqydev.gamebox.health"
readonly backup_label="me.zqydev.gamebox.backup"
readonly tunnel_label="me.zqydev.gamebox.tunnel"
readonly public_health_url="${GAMEBOX_PUBLIC_HEALTH_URL:-https://gamebox.zqydev.me/healthz}"
readonly local_health_url="${GAMEBOX_LOCAL_HEALTH_URL:-http://127.0.0.1:18080/healthz}"

temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gamebox-deploy.XXXXXX")"
trap '/bin/rm -rf "${temporary_dir}"' EXIT

/usr/bin/install -d -m 700 "${service_prefix}" "${config_dir}" "${data_dir}" "${data_dir}/backups" "${log_dir}"
/usr/bin/install -d -m 755 "${launch_dir}"

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

readonly tunnel_credentials_source="${HOME}/.cloudflared/498bfaa8-584d-4111-a4fa-13e7deec223c.json"
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

ensure_keychain_secret() {
  local service="$1"
  if /usr/bin/security find-generic-password -a "${USER}" -s "${service}" >/dev/null 2>&1; then
    return
  fi
  local secret
  secret="$(/usr/bin/openssl rand -base64 48)"
  /usr/bin/security add-generic-password -a "${USER}" -s "${service}" -w "${secret}" >/dev/null
}

ensure_keychain_secret "${jwt_service}"
ensure_keychain_secret "${pepper_service}"

new_plist() {
  local path="$1"
  local label="$2"
  local program="$3"
  /bin/rm -f "${path}"
  /usr/libexec/PlistBuddy -c "Add :Label string ${label}" "${path}"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "${path}"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string ${program}" "${path}"
  /usr/libexec/PlistBuddy -c 'Add :ProcessType string Background' "${path}"
}

readonly server_plist="${launch_dir}/${server_label}.plist"
new_plist "${server_plist}" "${server_label}" "${service_prefix}/run-server.sh"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "${server_plist}"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "${server_plist}"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 5' "${server_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string ${log_dir}/server.log" "${server_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string ${log_dir}/server.log" "${server_plist}"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' "${server_plist}"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:GAMEBOX_ADDR string 127.0.0.1:18080' "${server_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_DB_PATH string ${data_dir}/gamebox.db" "${server_plist}"

readonly health_plist="${launch_dir}/${health_label}.plist"
new_plist "${health_plist}" "${health_label}" "${service_prefix}/health-check.sh"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "${health_plist}"
/usr/libexec/PlistBuddy -c 'Add :StartInterval integer 300' "${health_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string ${log_dir}/health.log" "${health_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string ${log_dir}/health.log" "${health_plist}"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' "${health_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_LOCAL_HEALTH_URL string ${local_health_url}" "${health_plist}"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:GAMEBOX_PUBLIC_HEALTH_URL string ${public_health_url}" "${health_plist}"

readonly backup_plist="${launch_dir}/${backup_label}.plist"
new_plist "${backup_plist}" "${backup_label}" "${service_prefix}/backup.sh"
/usr/libexec/PlistBuddy -c 'Add :StartCalendarInterval dict' "${backup_plist}"
/usr/libexec/PlistBuddy -c 'Add :StartCalendarInterval:Hour integer 3' "${backup_plist}"
/usr/libexec/PlistBuddy -c 'Add :StartCalendarInterval:Minute integer 15' "${backup_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string ${log_dir}/backup.log" "${backup_plist}"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string ${log_dir}/backup.log" "${backup_plist}"

readonly tunnel_plist="${launch_dir}/${tunnel_label}.plist"
new_plist "${tunnel_plist}" "${tunnel_label}" "/opt/homebrew/bin/cloudflared"
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

for label in "${health_label}" "${backup_label}" "${tunnel_label}" "${server_label}"; do
  /bin/launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
done

bootstrap_agent() {
  local plist="$1"
  local attempt
  for attempt in 1 2 3; do
    if /bin/launchctl bootstrap "${domain}" "${plist}" 2>/dev/null; then
      return
    fi
    /bin/sleep "${attempt}"
  done
  print -u2 -- "Unable to bootstrap ${plist:t}"
  exit 1
}

bootstrap_agent "${server_plist}"
bootstrap_agent "${tunnel_plist}"
bootstrap_agent "${health_plist}"
bootstrap_agent "${backup_plist}"
/bin/launchctl kickstart -k "${domain}/${server_label}"

for attempt in {1..30}; do
  if /usr/bin/curl --fail --silent --max-time 2 "${local_health_url}" >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    print -u2 -- "Gamebox server did not become healthy"
    exit 1
  fi
  /bin/sleep 0.5
done

/bin/launchctl kickstart -k "${domain}/${health_label}"
/bin/launchctl kickstart -k "${domain}/${backup_label}"

print -- "Gamebox installed: local health ${local_health_url}"
print -- "Public health target: ${public_health_url}"

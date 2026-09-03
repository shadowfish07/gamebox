#!/usr/bin/env bash
set -euo pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly production_script="${root_dir}/deploy/macos/install.sh"
readonly staging_script="${root_dir}/deploy/macos/install-staging.sh"
readonly system_installer="${root_dir}/deploy/macos/install-system-services.sh"
readonly run_server_script="${root_dir}/deploy/macos/run-server.sh"
readonly create_invite_script="${root_dir}/deploy/macos/create-invite.sh"
readonly service_prefix_reference='${service_prefix}'

require_line() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  grep -F -- "${pattern}" "${file}" >/dev/null \
    || { printf 'macOS deploy is missing %s\n' "${description}" >&2; exit 1; }
}

production_prefix_line="$(grep '^readonly service_prefix=' "${production_script}" || true)"
staging_prefix_line="$(grep '^readonly service_prefix=' "${staging_script}" || true)"

[[ -n "${production_prefix_line}" && -n "${staging_prefix_line}" ]] \
  || { printf 'macOS deploy prefix declarations are missing\n' >&2; exit 1; }
[[ "${production_prefix_line}" != "${staging_prefix_line}" ]] \
  || { printf 'staging deployment reuses the production executable prefix\n' >&2; exit 1; }
[[ "${staging_prefix_line}" == 'readonly service_prefix="${HOME}/.local/libexec/gamebox-staging"' ]] \
  || { printf 'staging executable prefix is not isolated\n' >&2; exit 1; }

for artifact in gameboxd gameboxctl run-server.sh health-check.sh backup.sh; do
  grep -F -- "\"${service_prefix_reference}/${artifact}\"" "${staging_script}" >/dev/null \
    || { printf 'staging installer does not install %s under its service prefix\n' "${artifact}" >&2; exit 1; }
done

require_line "${production_script}" 'readonly launch_dir="/Library/LaunchDaemons"' \
  'the production LaunchDaemon directory'
require_line "${production_script}" 'readonly system_domain="system"' \
  'the production system launchd domain'
require_line "${production_script}" 'Add :UserName string ${service_user}' \
  'an unprivileged LaunchDaemon user'
require_line "${production_script}" 'Add :EnvironmentVariables:GAMEBOX_KEYCHAIN string ${system_keychain}' \
  'the production System Keychain selection'
require_line "${production_script}" 'if [[ "${privileged_install_required}" == true ]]; then' \
  'conditional one-time privileged installation'
require_line "${production_script}" 'run_privileged_installer() {' \
  'one-time administrator authentication routing'
require_line "${production_script}" 'do shell script command_text with administrator privileges' \
  'non-terminal macOS administrator authentication'
require_line "${production_script}" '/bin/kill -TERM "${pid}"' \
  'unprivileged routine service restart'
require_line "${system_installer}" '/usr/bin/install -o root -g wheel -m 644' \
  'root-owned system plist installation'
require_line "${system_installer}" '-U -T /usr/bin/security -w "${jwt_secret}" "${system_keychain}"' \
  'non-interactive System Keychain access control'
require_line "${run_server_script}" 'if [[ -n "${GAMEBOX_KEYCHAIN:-}" ]]; then' \
  'explicit production Keychain routing'
require_line "${create_invite_script}" 'typeset -g preferred_domain="system"' \
  'production invite system-domain validation'
require_line "${staging_script}" 'readonly launch_dir="${HOME}/Library/LaunchAgents"' \
  'staging LaunchAgent isolation'
require_line "${staging_script}" 'launchctl print "${tunnel_system_domain}/${tunnel_label}"' \
  'staging compatibility with the production system tunnel'

set +e
helper_output="$(/bin/zsh "${system_installer}" 2>&1)"
helper_status=$?
set -e
[[ "${helper_status}" -eq 1 && "${helper_output}" == 'install-system-services.sh must run as root' ]] \
  || { printf 'privileged installer did not fail closed for an unprivileged caller\n' >&2; exit 1; }

set +e
usage_output="$(/bin/zsh "${production_script}" unexpected 2>&1)"
usage_status=$?
set -e
[[ "${usage_status}" -eq 2 && "${usage_output}" == 'usage: install.sh [--verbose]' ]] \
  || { printf 'production installer invalid-argument handling drifted\n' >&2; exit 1; }

printf 'macOS boot deployment and staging isolation contracts passed.\n'

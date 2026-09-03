#!/bin/zsh
set -euo pipefail
umask 077

readonly usage="usage: install-system-services.sh <service-user> <service-uid> <generated-plist-dir> <legacy-plist-dir> <legacy-archive-dir> <secret-dir>"

if (( EUID != 0 )); then
  print -u2 -- "install-system-services.sh must run as root"
  exit 1
fi
if (( $# != 6 )); then
  print -u2 -- "${usage}"
  exit 2
fi

readonly service_user="$1"
readonly service_uid="$2"
readonly generated_plist_dir="$3"
readonly legacy_plist_dir="$4"
readonly legacy_archive_dir="$5"
readonly secret_dir="$6"
readonly service_group="$(/usr/bin/id -gn "${service_user}")"
readonly system_keychain="/Library/Keychains/System.keychain"
readonly launch_dir="/Library/LaunchDaemons"
readonly system_domain="system"
readonly legacy_domain="gui/${service_uid}"
readonly jwt_service="me.zqydev.gamebox.jwt-secret"
readonly pepper_service="me.zqydev.gamebox.token-pepper"
readonly local_health_url="http://127.0.0.1:18080/healthz"
readonly public_health_url="https://gamebox.zqydev.me/healthz"
readonly labels=(
  me.zqydev.gamebox.server
  me.zqydev.gamebox.tunnel
  me.zqydev.gamebox.health
  me.zqydev.gamebox.backup
)

if [[ "${service_uid}" != <-> ]] || [[ "$(/usr/bin/id -u "${service_user}")" != "${service_uid}" ]]; then
  print -u2 -- "service user and uid do not match"
  exit 2
fi

for label in "${labels[@]}"; do
  plist="${generated_plist_dir}/${label}.plist"
  if [[ ! -f "${plist}" ]]; then
    print -u2 -- "missing generated plist: ${label}"
    exit 1
  fi
  /usr/bin/plutil -lint "${plist}" >/dev/null
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "${plist}")" != "${label}" ]] \
    || [[ "$(/usr/libexec/PlistBuddy -c 'Print :UserName' "${plist}")" != "${service_user}" ]]; then
    print -u2 -- "generated plist identity mismatch: ${label}"
    exit 1
  fi
done

readonly jwt_secret_file="${secret_dir}/jwt-secret"
readonly pepper_secret_file="${secret_dir}/token-pepper"
if [[ ! -f "${jwt_secret_file}" || ! -f "${pepper_secret_file}" ]]; then
  print -u2 -- "production secret migration inputs are missing"
  exit 1
fi
readonly jwt_secret="$(<"${jwt_secret_file}")"
readonly pepper_secret="$(<"${pepper_secret_file}")"
if (( ${#jwt_secret} < 32 || ${#pepper_secret} < 32 )); then
  print -u2 -- "production secret migration inputs are invalid"
  exit 1
fi

backup_dir="$(/usr/bin/mktemp -d /tmp/gamebox-launchdaemons.XXXXXX)"
typeset -A had_existing
success=false

restore_previous_state() {
  local label installed backup restored_system=false
  for label in "${labels[@]}"; do
    /bin/launchctl bootout "${system_domain}/${label}" >/dev/null 2>&1 || true
  done
  for label in "${labels[@]}"; do
    installed="${launch_dir}/${label}.plist"
    backup="${backup_dir}/${label}.plist"
    if [[ "${had_existing[${label}]:-false}" == true ]]; then
      /usr/bin/install -o root -g wheel -m 644 "${backup}" "${installed}"
    else
      /bin/rm -f "${installed}"
    fi
  done
  for label in "${labels[@]}"; do
    if [[ "${had_existing[${label}]:-false}" == true ]]; then
      restored_system=true
      /bin/launchctl bootstrap "${system_domain}" \
        "${launch_dir}/${label}.plist" >/dev/null 2>&1 || true
    fi
  done
  if [[ "${restored_system}" != true ]]; then
    for label in "${labels[@]}"; do
      legacy_plist="${legacy_plist_dir}/${label}.plist"
      if [[ -f "${legacy_plist}" ]]; then
        /bin/launchctl bootstrap "${legacy_domain}" "${legacy_plist}" >/dev/null 2>&1 || true
      fi
    done
  fi
}

cleanup() {
  local status=$?
  if [[ "${success}" != true ]]; then
    restore_previous_state
  fi
  /bin/rm -rf "${backup_dir}"
  exit "${status}"
}
trap cleanup EXIT

/usr/bin/install -d -o root -g wheel -m 755 "${launch_dir}"
for label in "${labels[@]}"; do
  installed="${launch_dir}/${label}.plist"
  if [[ -f "${installed}" ]]; then
    had_existing[${label}]=true
    /bin/cp -p "${installed}" "${backup_dir}/${label}.plist"
  else
    had_existing[${label}]=false
  fi
done

# The values are preserved during migration, so existing sessions and invite
# digests remain valid. Trust only Apple's security tool for non-interactive
# reads by the unprivileged daemon process.
/usr/bin/security add-generic-password -a "${service_user}" -s "${jwt_service}" \
  -U -T /usr/bin/security -w "${jwt_secret}" "${system_keychain}" >/dev/null
/usr/bin/security add-generic-password -a "${service_user}" -s "${pepper_service}" \
  -U -T /usr/bin/security -w "${pepper_secret}" "${system_keychain}" >/dev/null

for label in "${labels[@]}"; do
  /usr/bin/install -o root -g wheel -m 644 \
    "${generated_plist_dir}/${label}.plist" "${launch_dir}/${label}.plist"
done

for label in "${labels[@]}"; do
  /bin/launchctl bootout "${legacy_domain}/${label}" >/dev/null 2>&1 || true
  /bin/launchctl bootout "${system_domain}/${label}" >/dev/null 2>&1 || true
done

for label in "${labels[@]}"; do
  /bin/launchctl bootstrap "${system_domain}" "${launch_dir}/${label}.plist"
done

for attempt in {1..60}; do
  if /usr/bin/curl --fail --silent --max-time 2 "${local_health_url}" >/dev/null 2>&1 \
    && /usr/bin/curl --fail --silent --max-time 5 "${public_health_url}" >/dev/null 2>&1; then
    break
  fi
  if (( attempt == 60 )); then
    print -u2 -- "system services did not become healthy; restored the previous launch agents"
    exit 1
  fi
  /bin/sleep 0.5
done

success=true
archive_stamp="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
if /usr/bin/install -d -o "${service_user}" -g "${service_group}" -m 700 "${legacy_archive_dir}"; then
  for label in "${labels[@]}"; do
    legacy_plist="${legacy_plist_dir}/${label}.plist"
    archived_plist="${legacy_archive_dir}/${label}.${archive_stamp}.plist"
    if [[ -f "${legacy_plist}" ]]; then
      if /bin/mv "${legacy_plist}" "${archived_plist}"; then
        /usr/sbin/chown "${service_user}:${service_group}" "${archived_plist}" || \
          print -u2 -- "WARN: could not restore archive ownership for ${label}"
      else
        print -u2 -- "WARN: could not archive legacy launch agent ${label}"
      fi
    fi
  done
else
  print -u2 -- "WARN: could not create the legacy launch-agent archive"
fi

print -- "Gamebox system services installed and healthy"

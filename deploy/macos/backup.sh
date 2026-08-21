#!/bin/zsh
set -euo pipefail
umask 077

readonly data_dir="${GAMEBOX_DATA_DIR:-${HOME}/Library/Application Support/Gamebox/server}"
readonly database_path="${GAMEBOX_DB_PATH:-${data_dir}/gamebox.db}"
readonly backup_dir="${GAMEBOX_BACKUP_DIR:-${data_dir}/backups}"
readonly sqlite_bin="/usr/bin/sqlite3"

if [[ ! -f "${database_path}" ]]; then
  print -u2 -- "Gamebox database does not exist"
  exit 1
fi

/bin/mkdir -p "${backup_dir}"
/bin/chmod 700 "${backup_dir}"

readonly timestamp="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
readonly final_path="${backup_dir}/gamebox-${timestamp}.db"
temporary_path="$(/usr/bin/mktemp "${backup_dir}/.gamebox-backup.XXXXXX")"
trap '/bin/rm -f "${temporary_path}"' EXIT

"${sqlite_bin}" "${database_path}" ".backup '${temporary_path}'"
integrity="$("${sqlite_bin}" "${temporary_path}" 'PRAGMA integrity_check;')"
if [[ "${integrity}" != "ok" ]]; then
  print -u2 -- "Gamebox backup integrity check failed"
  exit 1
fi

/bin/chmod 600 "${temporary_path}"
/bin/mv "${temporary_path}" "${final_path}"
trap - EXIT

/usr/bin/find "${backup_dir}" -type f -name 'gamebox-*.db' -mtime +14 -delete
print -- "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') backup=${final_path:t} integrity=ok"

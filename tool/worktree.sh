#!/usr/bin/env bash
set -euo pipefail

STATE_VERSION=1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
cd "$ROOT_DIR"

GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
  || git rev-parse --git-common-dir)"
if [[ "$GIT_COMMON_DIR" != /* ]]; then
  GIT_COMMON_DIR="$(cd "$GIT_COMMON_DIR" && pwd -P)"
else
  GIT_COMMON_DIR="$(cd "$GIT_COMMON_DIR" && pwd -P)"
fi
readonly GIT_COMMON_DIR
PRIMARY_ROOT="$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -n 1)"
PRIMARY_ROOT="$(cd "$PRIMARY_ROOT" && pwd -P)"
readonly PRIMARY_ROOT

STATE_DIR="$ROOT_DIR/.gamebox-worktree"
STATE_FILE="$STATE_DIR/state.env"
SETUP_MARKER="$STATE_DIR/setup-complete"
SECRETS_FILE="$STATE_DIR/secrets.env"
DATA_ORIGIN_FILE="$STATE_DIR/data-origin"
DATA_DIR="$STATE_DIR/data"
DB_PATH="$DATA_DIR/gamebox.db"
BACKUP_DIR="$STATE_DIR/backups"
BIN_DIR="$STATE_DIR/bin"
SERVER_BIN="$BIN_DIR/gameboxd"
SERVER_PID_FILE="$STATE_DIR/server.pid"
ANDROID_RUNTIME_DIR="$STATE_DIR/android-runtime"
PORT_REGISTRY="$GIT_COMMON_DIR/gamebox-worktree-ports.tsv"
PORT_REGISTRY_LOCK="$GIT_COMMON_DIR/gamebox-worktree-ports.lock"
readonly STATE_DIR STATE_FILE SETUP_MARKER SECRETS_FILE DATA_ORIGIN_FILE DATA_DIR DB_PATH
readonly BACKUP_DIR BIN_DIR SERVER_BIN SERVER_PID_FILE ANDROID_RUNTIME_DIR
readonly PORT_REGISTRY PORT_REGISTRY_LOCK

# shellcheck source=tool/lib/android_lease.sh
source "$ROOT_DIR/tool/lib/android_lease.sh"

if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  export JAVA_HOME
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi

REGISTRY_LOCK_OWNED=0

die() {
  printf 'Gamebox worktree: %s\n' "$*" >&2
  exit 1
}

info() {
  printf 'Gamebox worktree: %s\n' "$*"
}

hash_value() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}

WORKTREE_ID="wt_$(hash_value "$GIT_COMMON_DIR|$ROOT_DIR" | cut -c1-12)"
readonly WORKTREE_ID

read_first_line() {
  local path="$1"
  local value=""
  if [[ -f "$path" ]]; then
    IFS= read -r value <"$path" || true
  fi
  printf '%s' "$value"
}

read_key() {
  local path="$1"
  local key="$2"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  awk -v prefix="$key=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' "$path"
}

pid_is_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

cleanup_registry_lock() {
  local owner_pid
  ((REGISTRY_LOCK_OWNED == 1)) || return 0
  owner_pid="$(read_first_line "$PORT_REGISTRY_LOCK/pid")"
  if [[ "$owner_pid" == "$$" ]]; then
    rm -f "$PORT_REGISTRY_LOCK/pid"
    rmdir "$PORT_REGISTRY_LOCK" 2>/dev/null || true
  fi
  REGISTRY_LOCK_OWNED=0
}
trap cleanup_registry_lock EXIT

acquire_registry_lock() {
  local attempt owner_pid
  for ((attempt = 0; attempt < 100; attempt++)); do
    if mkdir "$PORT_REGISTRY_LOCK" 2>/dev/null; then
      chmod 700 "$PORT_REGISTRY_LOCK"
      printf '%s\n' "$$" >"$PORT_REGISTRY_LOCK/pid"
      chmod 600 "$PORT_REGISTRY_LOCK/pid"
      REGISTRY_LOCK_OWNED=1
      return 0
    fi
    [[ -d "$PORT_REGISTRY_LOCK" && ! -L "$PORT_REGISTRY_LOCK" ]] \
      || die "unsafe port-registry lock path: $PORT_REGISTRY_LOCK"
    owner_pid="$(read_first_line "$PORT_REGISTRY_LOCK/pid")"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! pid_is_alive "$owner_pid"; then
      rm -f "$PORT_REGISTRY_LOCK/pid"
      rmdir "$PORT_REGISTRY_LOCK" 2>/dev/null || true
      continue
    fi
    sleep 0.1
  done
  die "could not acquire port-registry lock: $PORT_REGISTRY_LOCK"
}

release_registry_lock() {
  cleanup_registry_lock
}

port_is_listening() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
    return
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return
  fi
  die "lsof or nc is required to verify port ownership"
}

prune_port_registry() {
  local staged id root port
  staged="$(mktemp "$GIT_COMMON_DIR/.gamebox-worktree-ports.XXXXXX")"
  chmod 600 "$staged"
  if [[ -f "$PORT_REGISTRY" ]]; then
    while IFS=$'\t' read -r id root port; do
      [[ -n "$id" && -n "$root" && "$port" =~ ^[0-9]+$ && -d "$root" ]] || continue
      printf '%s\t%s\t%s\n' "$id" "$root" "$port" >>"$staged"
    done <"$PORT_REGISTRY"
  fi
  mv "$staged" "$PORT_REGISTRY"
  chmod 600 "$PORT_REGISTRY"
}

port_registered_elsewhere() {
  local port="$1"
  [[ -f "$PORT_REGISTRY" ]] || return 1
  awk -F '\t' -v id="$WORKTREE_ID" -v port="$port" '
    $1 != id && $3 == port { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$PORT_REGISTRY"
}

registered_port_for_this_worktree() {
  [[ -f "$PORT_REGISTRY" ]] || return 1
  awk -F '\t' -v id="$WORKTREE_ID" '$1 == id { print $3; exit }' "$PORT_REGISTRY"
}

allocate_port() {
  local checksum offset attempt candidate
  checksum="$(printf '%s' "$GIT_COMMON_DIR|$ROOT_DIR" | cksum | awk '{print $1}')"
  offset=$((checksum % 20000))
  for ((attempt = 0; attempt < 20000; attempt++)); do
    candidate=$((20000 + ((offset + attempt) % 20000)))
    port_registered_elsewhere "$candidate" && continue
    port_is_listening "$candidate" && continue
    printf '%s\n' "$candidate"
    return 0
  done
  die "could not allocate a free localhost server port"
}

register_port() {
  local requested_port="${1:-}"
  local registered_port staged
  acquire_registry_lock
  prune_port_registry
  registered_port="$(registered_port_for_this_worktree || true)"
  if [[ -n "$requested_port" ]]; then
    [[ "$requested_port" =~ ^[0-9]+$ && "$requested_port" -ge 1024 && "$requested_port" -le 65535 ]] \
      || die "saved server port is invalid: $requested_port"
    if port_registered_elsewhere "$requested_port"; then
      die "saved server port $requested_port now belongs to another worktree"
    fi
    SERVER_PORT="$requested_port"
  elif [[ -n "$registered_port" ]]; then
    SERVER_PORT="$registered_port"
  else
    SERVER_PORT="$(allocate_port)"
  fi

  staged="$(mktemp "$GIT_COMMON_DIR/.gamebox-worktree-ports.XXXXXX")"
  chmod 600 "$staged"
  awk -F '\t' -v id="$WORKTREE_ID" '$1 != id' "$PORT_REGISTRY" >"$staged"
  printf '%s\t%s\t%s\n' "$WORKTREE_ID" "$ROOT_DIR" "$SERVER_PORT" >>"$staged"
  mv "$staged" "$PORT_REGISTRY"
  chmod 600 "$PORT_REGISTRY"
  release_registry_lock
}

ensure_private_directories() {
  mkdir -p "$STATE_DIR" "$DATA_DIR" "$BACKUP_DIR" "$BIN_DIR"
  chmod 700 "$STATE_DIR" "$DATA_DIR" "$BACKUP_DIR" "$BIN_DIR"
}

write_state() {
  local staged
  staged="$(mktemp "$STATE_DIR/.state.XXXXXX")"
  (
    umask 077
    printf 'STATE_VERSION=%s\n' "$STATE_VERSION"
    printf 'WORKTREE_ID=%s\n' "$WORKTREE_ID"
    printf 'ROOT=%s\n' "$ROOT_DIR"
    printf 'PRIMARY_ROOT=%s\n' "$PRIMARY_ROOT"
    printf 'SERVER_PORT=%s\n' "$SERVER_PORT"
  ) >"$staged"
  chmod 600 "$staged"
  mv "$staged" "$STATE_FILE"
}

load_state() {
  local loaded_version loaded_id loaded_root loaded_primary loaded_port
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  loaded_version="$(read_key "$STATE_FILE" STATE_VERSION || true)"
  loaded_id="$(read_key "$STATE_FILE" WORKTREE_ID || true)"
  loaded_root="$(read_key "$STATE_FILE" ROOT || true)"
  loaded_primary="$(read_key "$STATE_FILE" PRIMARY_ROOT || true)"
  loaded_port="$(read_key "$STATE_FILE" SERVER_PORT || true)"
  [[ "$loaded_version" == "$STATE_VERSION" ]] || die "unsupported local state version: ${loaded_version:-missing}"
  [[ "$loaded_id" == "$WORKTREE_ID" ]] || die "local state belongs to another worktree identity"
  [[ "$loaded_root" == "$ROOT_DIR" ]] || die "local state root does not match this checkout"
  [[ "$loaded_primary" == "$PRIMARY_ROOT" ]] || die "local state primary checkout does not match Git metadata"
  [[ "$loaded_port" =~ ^[0-9]+$ && "$loaded_port" -ge 1024 && "$loaded_port" -le 65535 ]] \
    || die "local state has an invalid server port"
  SERVER_PORT="$loaded_port"
}

generate_or_validate_secrets() {
  local jwt_secret token_pepper staged
  if [[ ! -f "$SECRETS_FILE" ]]; then
    command -v openssl >/dev/null 2>&1 || die "openssl is required to generate local development secrets"
    jwt_secret="$(openssl rand -base64 48)"
    token_pepper="$(openssl rand -base64 48)"
    staged="$(mktemp "$STATE_DIR/.secrets.XXXXXX")"
    (
      umask 077
      printf 'GAMEBOX_JWT_SECRET=%s\n' "$jwt_secret"
      printf 'GAMEBOX_TOKEN_PEPPER=%s\n' "$token_pepper"
    ) >"$staged"
    chmod 600 "$staged"
    mv "$staged" "$SECRETS_FILE"
    info "generated independent local server secrets (values not displayed)"
  fi
  [[ -f "$SECRETS_FILE" && ! -L "$SECRETS_FILE" ]] || die "local secrets path is not a regular file"
  chmod 600 "$SECRETS_FILE"
  jwt_secret="$(read_key "$SECRETS_FILE" GAMEBOX_JWT_SECRET || true)"
  token_pepper="$(read_key "$SECRETS_FILE" GAMEBOX_TOKEN_PEPPER || true)"
  [[ ${#jwt_secret} -ge 32 && ${#token_pepper} -ge 32 ]] \
    || die "local server secrets are missing or too short"
  [[ "$jwt_secret" =~ ^[A-Za-z0-9+/=]+$ && "$token_pepper" =~ ^[A-Za-z0-9+/=]+$ ]] \
    || die "local server secrets use an unsupported encoding"
}

prepare_state() {
  ensure_private_directories
  if load_state; then
    register_port "$SERVER_PORT"
  else
    register_port
    write_state
  fi
  load_state
  generate_or_validate_secrets
  if [[ ! -f "$DATA_ORIGIN_FILE" ]]; then
    printf 'fresh isolated database\n' >"$DATA_ORIGIN_FILE"
    chmod 600 "$DATA_ORIGIN_FILE"
  fi
}

server_process_is_owned() {
  local pid="$1"
  local command_line cwd_path
  pid_is_alive "$pid" || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command_line" == "$SERVER_BIN"* ]] || return 1
  if command -v lsof >/dev/null 2>&1; then
    cwd_path="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    [[ "$cwd_path" == "$ROOT_DIR" ]] || return 1
  fi
}

server_state() {
  local pid
  pid="$(read_first_line "$SERVER_PID_FILE")"
  if [[ -z "$pid" ]]; then
    printf 'stopped\n'
  elif server_process_is_owned "$pid"; then
    printf 'running:%s\n' "$pid"
  elif pid_is_alive "$pid"; then
    printf 'unsafe:%s\n' "$pid"
  else
    printf 'stale:%s\n' "$pid"
  fi
}

refuse_active_or_unsafe_server() {
  local state="$1"
  case "$state" in
    running:*) die "local server is active (PID ${state#running:}); run 'bash tool/worktree.sh down' first" ;;
    unsafe:*) die "PID ${state#unsafe:} no longer matches this worktree server; refusing process or data changes" ;;
  esac
}

run_setup() {
  prepare_state
  bash "$ROOT_DIR/tool/bootstrap.sh" --build-only
  (cd "$ROOT_DIR/server" && go mod download)
  (cd "$ROOT_DIR/app" && flutter pub get --enforce-lockfile)
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$SETUP_MARKER"
  chmod 600 "$SETUP_MARKER"
  info "setup complete: id=$WORKTREE_ID port=$SERVER_PORT"
}

ensure_setup() {
  prepare_state
  if [[ ! -f "$SETUP_MARKER" ]]; then
    run_setup
  fi
}

run_up() {
  local state staged_binary jwt_secret token_pepper
  ensure_setup
  state="$(server_state)"
  refuse_active_or_unsafe_server "$state"
  [[ "$state" != stale:* ]] || rm -f "$SERVER_PID_FILE"
  port_is_listening "$SERVER_PORT" \
    && die "server port $SERVER_PORT is occupied; the allocator will not drift to another port"

  staged_binary="$(mktemp "$BIN_DIR/.gameboxd.XXXXXX")"
  if ! (cd "$ROOT_DIR/server" && go build -trimpath -o "$staged_binary" ./cmd/gameboxd); then
    rm -f "$staged_binary"
    die "server build failed"
  fi
  chmod 700 "$staged_binary"
  mv "$staged_binary" "$SERVER_BIN"
  jwt_secret="$(read_key "$SECRETS_FILE" GAMEBOX_JWT_SECRET)"
  token_pepper="$(read_key "$SECRETS_FILE" GAMEBOX_TOKEN_PEPPER)"
  printf '%s\n' "$$" >"$SERVER_PID_FILE"
  chmod 600 "$SERVER_PID_FILE"

  printf 'Gamebox worktree server starting in the foreground.\n'
  printf '  local API:   http://127.0.0.1:%s\n' "$SERVER_PORT"
  printf '  Android API: http://10.0.2.2:%s\n' "$SERVER_PORT"
  printf '  database:    %s\n' "$DB_PATH"
  printf '  remote writes: blocked (loopback listener and isolated database)\n'
  cd "$ROOT_DIR"
  exec env \
    GAMEBOX_ADDR="127.0.0.1:$SERVER_PORT" \
    GAMEBOX_DB_PATH="$DB_PATH" \
    GAMEBOX_JWT_SECRET="$jwt_secret" \
    GAMEBOX_TOKEN_PEPPER="$token_pepper" \
    "$SERVER_BIN"
}

stop_server() {
  local state pid deadline
  state="$(server_state)"
  case "$state" in
    stopped)
      info "no worktree server is running"
      return 0
      ;;
    stale:*)
      rm -f "$SERVER_PID_FILE"
      info "removed stale server PID metadata"
      return 0
      ;;
    unsafe:*)
      die "PID ${state#unsafe:} does not match this worktree server; nothing was terminated"
      ;;
  esac
  pid="${state#running:}"
  kill -TERM "$pid"
  deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    pid_is_alive "$pid" || break
    sleep 1
  done
  if pid_is_alive "$pid"; then
    server_process_is_owned "$pid" || die "server PID ownership changed while stopping; refusing SIGKILL"
    kill -KILL "$pid"
  fi
  rm -f "$SERVER_PID_FILE"
  info "stopped worktree server PID $pid"
}

android_runtime_value() {
  read_first_line "$ANDROID_RUNTIME_DIR/$1"
}

remove_android_runtime_metadata() {
  local name
  [[ -d "$ANDROID_RUNTIME_DIR" ]] || return 0
  for name in token started-a started-b pid-a pid-b avd-a avd-b serial-a serial-b; do
    [[ -e "$ANDROID_RUNTIME_DIR/$name" ]] && rm -f "$ANDROID_RUNTIME_DIR/$name"
  done
  rmdir "$ANDROID_RUNTIME_DIR" 2>/dev/null || true
}

stop_orphaned_owned_emulator() {
  local label="$1"
  local started avd serial emulator_pid actual_avd command_line
  started="$(android_runtime_value "started-$label")"
  [[ "$started" == 1 ]] || return 0
  avd="$(android_runtime_value "avd-$label")"
  serial="$(android_runtime_value "serial-$label")"
  emulator_pid="$(android_runtime_value "pid-$label")"
  case "$avd" in
    Gamebox_A_API_36|Gamebox_B_API_36) ;;
    *) die "orphaned Android metadata names an unapproved AVD; nothing was stopped" ;;
  esac
  if [[ "$serial" =~ ^emulator-[0-9]+$ ]] && command -v adb >/dev/null 2>&1 \
    && adb -s "$serial" get-state >/dev/null 2>&1; then
    actual_avd="$(adb -s "$serial" emu avd name 2>/dev/null | head -n 1 | tr -d '\r')"
    [[ "$actual_avd" == "$avd" ]] \
      || die "device $serial now belongs to $actual_avd, not $avd; refusing cleanup"
    adb -s "$serial" emu kill >/dev/null
    info "stopped orphaned worktree-owned AVD $avd on $serial"
    return 0
  fi
  if pid_is_alive "$emulator_pid"; then
    command_line="$(ps -p "$emulator_pid" -o command= 2>/dev/null || true)"
    [[ "$command_line" == *"-avd $avd"* ]] \
      || die "emulator PID $emulator_pid does not match $avd; refusing cleanup"
    kill -TERM "$emulator_pid"
    info "stopped booting worktree-owned AVD $avd (PID $emulator_pid)"
  fi
}

cleanup_stale_android_for_this_worktree() {
  local lease_dir owner_file owner_root owner_pid owner_token runtime_token
  lease_dir="$GIT_COMMON_DIR/gamebox-android.lease"
  owner_file="$lease_dir/owner"
  [[ -d "$lease_dir" ]] || return 0
  owner_root="$(_gamebox_android_lease_value "$owner_file" root 2>/dev/null || true)"
  [[ "$owner_root" == "$ROOT_DIR" ]] || return 0
  owner_pid="$(_gamebox_android_lease_value "$owner_file" pid 2>/dev/null || true)"
  if pid_is_alive "$owner_pid"; then
    die "Android work is active for this worktree (PID $owner_pid); interrupt its foreground terminal first"
  fi
  owner_token="$(_gamebox_android_lease_value "$owner_file" token 2>/dev/null || true)"
  runtime_token="$(android_runtime_value token)"
  if [[ -d "$ANDROID_RUNTIME_DIR" ]]; then
    [[ -n "$owner_token" && "$runtime_token" == "$owner_token" ]] \
      || die "orphaned Android runtime token does not match the stale lease; nothing was stopped"
    stop_orphaned_owned_emulator a
    stop_orphaned_owned_emulator b
    remove_android_runtime_metadata
  fi
  gamebox_android_lease_reclaim_for_root "$ROOT_DIR" \
    || die "could not safely reclaim this worktree's stale Android lease"
}

run_down() {
  prepare_state
  cleanup_stale_android_for_this_worktree
  stop_server
}

run_status() {
  local role setup_state data_origin database_state state display_state android_state
  prepare_state
  role=linked
  [[ "$ROOT_DIR" == "$PRIMARY_ROOT" ]] && role=primary
  setup_state=no
  [[ -f "$SETUP_MARKER" ]] && setup_state="yes ($(read_first_line "$SETUP_MARKER"))"
  data_origin="$(read_first_line "$DATA_ORIGIN_FILE")"
  database_state=absent
  [[ -f "$DB_PATH" ]] && database_state="present ($(wc -c <"$DB_PATH" | tr -d ' ') bytes)"
  state="$(server_state)"
  case "$state" in
    running:*) display_state="running (PID ${state#running:})" ;;
    stale:*) display_state="stopped (stale PID ${state#stale:})" ;;
    unsafe:*) display_state="unsafe PID mismatch (${state#unsafe:})" ;;
    *) display_state=stopped ;;
  esac
  android_state="$(gamebox_android_lease_describe "$ROOT_DIR")"
  printf '%-20s %s\n' \
    "worktree:" "$ROOT_DIR" \
    "role:" "$role" \
    "id:" "$WORKTREE_ID" \
    "primary:" "$PRIMARY_ROOT" \
    "setup complete:" "$setup_state" \
    "server port:" "$SERVER_PORT" \
    "local API:" "http://127.0.0.1:$SERVER_PORT" \
    "Android API:" "http://10.0.2.2:$SERVER_PORT" \
    "server:" "$display_state" \
    "database:" "$database_state" \
    "data origin:" "${data_origin:-unknown}" \
    "Android lease:" "$android_state" \
    "device state:" "shared by package; serialized, never synchronized" \
    "remote writes:" "blocked by worktree commands"
}

run_data_pull() {
  local state source_state source_db source_secrets timestamp pull_backup staged_db staged_secrets
  local integrity suffix
  [[ "$ROOT_DIR" != "$PRIMARY_ROOT" ]] \
    || die "data:pull is only valid in a linked worktree; primary development data is already canonical"
  prepare_state
  state="$(server_state)"
  refuse_active_or_unsafe_server "$state"
  source_state="$PRIMARY_ROOT/.gamebox-worktree/state.env"
  source_db="$PRIMARY_ROOT/.gamebox-worktree/data/gamebox.db"
  source_secrets="$PRIMARY_ROOT/.gamebox-worktree/secrets.env"
  [[ -f "$source_state" && -f "$source_db" && -f "$source_secrets" ]] \
    || die "primary worktree has no complete local snapshot; run setup/up there before pulling"
  [[ "$(read_key "$source_state" ROOT || true)" == "$PRIMARY_ROOT" ]] \
    || die "primary worktree state identity is invalid"
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for a consistent data snapshot"
  case "$source_db$DB_PATH" in
    *"'"*) die "data snapshot paths containing a single quote are unsupported" ;;
  esac

  printf 'Gamebox data pull review:\n'
  printf '  source: %s\n' "$PRIMARY_ROOT"
  printf '  target: %s\n' "$ROOT_DIR"
  printf '  replace: .gamebox-worktree/data/gamebox.db\n'
  printf '  replace: .gamebox-worktree/secrets.env (exact two development secrets)\n'
  printf '  exclude: deployed ~/Library data, Keychain, app/device state, builds, caches, logs, artifacts\n'

  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  pull_backup="$(mktemp -d "$BACKUP_DIR/pull-$timestamp.XXXXXX")"
  chmod 700 "$pull_backup"
  staged_db="$(mktemp "$DATA_DIR/.gamebox-pull.XXXXXX")"
  staged_secrets="$(mktemp "$STATE_DIR/.secrets-pull.XXXXXX")"
  chmod 600 "$staged_db" "$staged_secrets"
  sqlite3 "$source_db" ".backup '$staged_db'"
  integrity="$(sqlite3 "$staged_db" 'PRAGMA integrity_check;')"
  [[ "$integrity" == ok ]] || die "primary snapshot integrity check failed"
  install -m 600 "$source_secrets" "$staged_secrets"
  if [[ -f "$DB_PATH" ]]; then
    sqlite3 "$DB_PATH" ".backup '$pull_backup/gamebox.db'"
    chmod 600 "$pull_backup/gamebox.db"
  fi
  install -m 600 "$SECRETS_FILE" "$pull_backup/secrets.env"
  for suffix in -wal -shm; do
    if [[ -f "$DB_PATH$suffix" ]]; then
      mv "$DB_PATH$suffix" "$pull_backup/gamebox.db$suffix"
    fi
  done
  mv -f "$staged_db" "$DB_PATH"
  mv -f "$staged_secrets" "$SECRETS_FILE"
  chmod 600 "$DB_PATH" "$SECRETS_FILE"
  printf 'primary snapshot pulled at %s\n' "$timestamp" >"$DATA_ORIGIN_FILE"
  chmod 600 "$DATA_ORIGIN_FILE"
  info "pulled a consistent primary development snapshot; previous target state backed up at $pull_backup"
}

run_data_push() {
  cat >&2 <<'EOF'
Gamebox worktree: data:push is disabled.
The SQLite database co-locates gameplay, users, invite hashes, sessions, and
launch/resume credentials, so there is no narrower audited reverse-sync
allowlist. Commit source/migrations through Git; never copy a worktree database
or its secrets into the primary or deployed service.
EOF
  exit 3
}

run_e2e() {
  local -a e2e_args=("$@")
  local argument
  for argument in "${e2e_args[@]}"; do
    case "$argument" in
      --plan|--list-scenarios|--self-test|-h|--help)
        exec bash "$ROOT_DIR/tool/e2e_android.sh" "${e2e_args[@]}"
        ;;
    esac
  done
  local state
  ensure_setup
  state="$(server_state)"
  refuse_active_or_unsafe_server "$state"
  mkdir -p "$ANDROID_RUNTIME_DIR"
  chmod 700 "$ANDROID_RUNTIME_DIR"
  exec env \
    GAMEBOX_E2E_API_PORT="$SERVER_PORT" \
    GAMEBOX_WORKTREE_ANDROID_RUNTIME_DIR="$ANDROID_RUNTIME_DIR" \
    bash "$ROOT_DIR/tool/e2e_android.sh" "${e2e_args[@]}"
}

usage() {
  cat <<'EOF'
Usage: bash tool/worktree.sh <command> [options]

Commands:
  setup       Idempotently install locked dependencies and initialize private state.
  status      Show identity, stable port, data origin, service, and Android lease.
  up | dev    Build and run the isolated local server in the foreground.
  down        Stop only this worktree's owned server and stale Android runtime.
  data:pull   Replace linked-worktree dev data from primary, with a target backup.
  data:push   Refuse unsafe reverse synchronization (no audited narrow allowlist).
  e2e [args]  Run selected two-AVD scenarios under the shared lease.
EOF
}

case "${1:-}" in
  setup) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; run_setup ;;
  status) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; run_status ;;
  up|dev) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; run_up ;;
  down) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; run_down ;;
  data:pull) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; run_data_pull ;;
  data:push) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; run_data_push ;;
  e2e) shift; run_e2e "$@" ;;
  help|-h|--help|"") usage ;;
  *) printf 'Unknown worktree command: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

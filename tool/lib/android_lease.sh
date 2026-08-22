#!/usr/bin/env bash

# Shared Android-device lease for every Gamebox entry point that changes an
# emulator or physical device. This file is sourced; callers own their traps.

GAMEBOX_ANDROID_LEASE_OWNED=0
GAMEBOX_ANDROID_LEASE_INHERITED=0
GAMEBOX_ANDROID_LEASE_DIR="${GAMEBOX_ANDROID_LEASE_DIR:-}"
GAMEBOX_ANDROID_LEASE_TOKEN="${GAMEBOX_ANDROID_LEASE_TOKEN:-}"
GAMEBOX_ANDROID_LEASE_OWNER_PID="${GAMEBOX_ANDROID_LEASE_OWNER_PID:-}"
GAMEBOX_ANDROID_LEASE_ROOT="${GAMEBOX_ANDROID_LEASE_ROOT:-}"

_gamebox_android_lease_value() {
  local owner_file="$1"
  local key="$2"
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  awk -v prefix="$key=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' "$owner_file"
}

_gamebox_android_lease_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

_gamebox_android_lease_common_dir() {
  local root="$1"
  local common_dir
  common_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
    || git -C "$root" rev-parse --git-common-dir)" || return 1
  if [[ "$common_dir" != /* ]]; then
    common_dir="$(cd "$root" && cd "$common_dir" && pwd -P)" || return 1
  else
    common_dir="$(cd "$common_dir" && pwd -P)" || return 1
  fi
  printf '%s\n' "$common_dir"
}

_gamebox_android_remove_stale_lease_dir() {
  local stale_dir="$1"
  local expected_prefix="$2/gamebox-android.lease.stale-"
  [[ "$stale_dir" == "$expected_prefix"* && -d "$stale_dir" && ! -L "$stale_dir" ]] || return 1
  find "$stale_dir" -mindepth 1 -maxdepth 1 -type f -name 'owner*' -delete
  rmdir "$stale_dir"
}

_gamebox_android_reclaim_dead_lease() {
  local lease_dir="$1"
  local common_dir="$2"
  local owner_file="$lease_dir/owner"
  local owner_pid owner_root stale_dir
  owner_pid="$(_gamebox_android_lease_value "$owner_file" pid 2>/dev/null || true)"
  owner_root="$(_gamebox_android_lease_value "$owner_file" root 2>/dev/null || true)"
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  _gamebox_android_lease_pid_alive "$owner_pid" && return 1

  stale_dir="$lease_dir.stale-$$-$RANDOM"
  if mv "$lease_dir" "$stale_dir" 2>/dev/null; then
    _gamebox_android_remove_stale_lease_dir "$stale_dir" "$common_dir" || {
      printf 'Gamebox Android lease: could not remove reclaimed metadata at %s\n' "$stale_dir" >&2
      return 1
    }
    printf 'Reclaimed stale Gamebox Android lease from %s (dead PID %s).\n' \
      "${owner_root:-unknown worktree}" "$owner_pid"
    return 0
  fi
  return 1
}

_gamebox_android_new_lease_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$$:$RANDOM:$RANDOM:$(date -u '+%s'):$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s-%s-%s-%s\n' "$(date -u '+%s')" "$$" "$RANDOM" "$RANDOM"
  fi
}

gamebox_android_lease_acquire() {
  local requested_root="$1"
  local device_identity="$2"
  local timeout_seconds="${3:-${GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS:-900}}"
  local root common_dir lease_dir owner_file deadline wait_reported
  local owner_pid owner_root owner_device owner_started inherited_token inherited_dir
  local token owner_tmp

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || {
    printf 'GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS must be a non-negative integer.\n' >&2
    return 2
  }
  root="$(cd "$requested_root" && pwd -P)" || return 2
  case "$root$device_identity" in
    *$'\n'*|*$'\t'*)
      printf 'Gamebox Android lease metadata contains unsupported control characters.\n' >&2
      return 2
      ;;
  esac
  common_dir="$(_gamebox_android_lease_common_dir "$root")" || {
    printf 'Gamebox Android lease requires a Git worktree.\n' >&2
    return 2
  }
  lease_dir="$common_dir/gamebox-android.lease"
  owner_file="$lease_dir/owner"

  inherited_token="${GAMEBOX_ANDROID_LEASE_TOKEN:-}"
  inherited_dir="${GAMEBOX_ANDROID_LEASE_DIR:-}"
  if [[ -n "$inherited_token" && "$inherited_dir" == "$lease_dir" \
    && "$(_gamebox_android_lease_value "$owner_file" token 2>/dev/null || true)" == "$inherited_token" ]]; then
    owner_pid="$(_gamebox_android_lease_value "$owner_file" pid 2>/dev/null || true)"
    owner_root="$(_gamebox_android_lease_value "$owner_file" root 2>/dev/null || true)"
    if [[ "$owner_root" == "$root" ]] && _gamebox_android_lease_pid_alive "$owner_pid"; then
      GAMEBOX_ANDROID_LEASE_OWNED=0
      GAMEBOX_ANDROID_LEASE_INHERITED=1
      GAMEBOX_ANDROID_LEASE_DIR="$lease_dir"
      GAMEBOX_ANDROID_LEASE_TOKEN="$inherited_token"
      GAMEBOX_ANDROID_LEASE_OWNER_PID="$owner_pid"
      GAMEBOX_ANDROID_LEASE_ROOT="$root"
      return 0
    fi
    printf 'Gamebox Android lease inheritance metadata is invalid; refusing to bypass the shared lease.\n' >&2
    return 1
  fi

  deadline=$((SECONDS + timeout_seconds))
  wait_reported=0
  while ! mkdir "$lease_dir" 2>/dev/null; do
    [[ -d "$lease_dir" && ! -L "$lease_dir" ]] || {
      printf 'Gamebox Android lease path is not a safe directory: %s\n' "$lease_dir" >&2
      return 1
    }
    if _gamebox_android_reclaim_dead_lease "$lease_dir" "$common_dir"; then
      continue
    fi
    owner_pid="$(_gamebox_android_lease_value "$owner_file" pid 2>/dev/null || true)"
    owner_root="$(_gamebox_android_lease_value "$owner_file" root 2>/dev/null || true)"
    owner_device="$(_gamebox_android_lease_value "$owner_file" device 2>/dev/null || true)"
    owner_started="$(_gamebox_android_lease_value "$owner_file" acquired_at 2>/dev/null || true)"
    if ((SECONDS >= deadline)); then
      printf 'Timed out waiting for the Gamebox Android lease at %s.\n' "$lease_dir" >&2
      printf 'Current owner: root=%s pid=%s device=%s acquired=%s\n' \
        "${owner_root:-initializing}" "${owner_pid:-unknown}" \
        "${owner_device:-unknown}" "${owner_started:-unknown}" >&2
      return 75
    fi
    if ((wait_reported == 0)); then
      printf 'Waiting for the Gamebox Android lease: root=%s pid=%s device=%s\n' \
        "${owner_root:-initializing}" "${owner_pid:-unknown}" "${owner_device:-unknown}"
      wait_reported=1
    fi
    sleep 1
  done

  chmod 700 "$lease_dir"
  token="$(_gamebox_android_new_lease_token "$root")" || {
    rmdir "$lease_dir" 2>/dev/null || true
    return 1
  }
  owner_tmp="$lease_dir/owner.tmp.$$"
  (
    umask 077
    printf 'version=1\n'
    printf 'token=%s\n' "$token"
    printf 'pid=%s\n' "$$"
    printf 'root=%s\n' "$root"
    printf 'device=%s\n' "$device_identity"
    printf 'acquired_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  ) >"$owner_tmp"
  chmod 600 "$owner_tmp"
  mv "$owner_tmp" "$owner_file"

  GAMEBOX_ANDROID_LEASE_OWNED=1
  GAMEBOX_ANDROID_LEASE_INHERITED=0
  GAMEBOX_ANDROID_LEASE_DIR="$lease_dir"
  GAMEBOX_ANDROID_LEASE_TOKEN="$token"
  GAMEBOX_ANDROID_LEASE_OWNER_PID="$$"
  GAMEBOX_ANDROID_LEASE_ROOT="$root"
  export GAMEBOX_ANDROID_LEASE_DIR GAMEBOX_ANDROID_LEASE_TOKEN
  export GAMEBOX_ANDROID_LEASE_OWNER_PID GAMEBOX_ANDROID_LEASE_ROOT
  printf 'Acquired Gamebox Android lease for %s (%s).\n' "$root" "$device_identity"
}

gamebox_android_lease_release() {
  local owner_file current_token current_pid current_root
  ((GAMEBOX_ANDROID_LEASE_INHERITED == 0)) || return 0
  ((GAMEBOX_ANDROID_LEASE_OWNED == 1)) || return 0
  owner_file="$GAMEBOX_ANDROID_LEASE_DIR/owner"
  current_token="$(_gamebox_android_lease_value "$owner_file" token 2>/dev/null || true)"
  current_pid="$(_gamebox_android_lease_value "$owner_file" pid 2>/dev/null || true)"
  current_root="$(_gamebox_android_lease_value "$owner_file" root 2>/dev/null || true)"
  if [[ "$current_token" != "$GAMEBOX_ANDROID_LEASE_TOKEN" || "$current_pid" != "$$" \
    || "$current_root" != "$GAMEBOX_ANDROID_LEASE_ROOT" ]]; then
    printf 'Gamebox Android lease ownership changed; shared metadata was preserved.\n' >&2
    return 1
  fi
  rm -f "$owner_file"
  rmdir "$GAMEBOX_ANDROID_LEASE_DIR" || return 1
  GAMEBOX_ANDROID_LEASE_OWNED=0
  unset GAMEBOX_ANDROID_LEASE_DIR GAMEBOX_ANDROID_LEASE_TOKEN
  unset GAMEBOX_ANDROID_LEASE_OWNER_PID GAMEBOX_ANDROID_LEASE_ROOT
}

gamebox_android_lease_describe() {
  local root common_dir lease_dir owner_file owner_pid owner_root owner_device owner_started state
  root="$(cd "$1" && pwd -P)" || return 2
  common_dir="$(_gamebox_android_lease_common_dir "$root")" || return 2
  lease_dir="$common_dir/gamebox-android.lease"
  owner_file="$lease_dir/owner"
  if [[ ! -d "$lease_dir" ]]; then
    printf 'idle\n'
    return 0
  fi
  owner_pid="$(_gamebox_android_lease_value "$owner_file" pid 2>/dev/null || true)"
  owner_root="$(_gamebox_android_lease_value "$owner_file" root 2>/dev/null || true)"
  owner_device="$(_gamebox_android_lease_value "$owner_file" device 2>/dev/null || true)"
  owner_started="$(_gamebox_android_lease_value "$owner_file" acquired_at 2>/dev/null || true)"
  state="stale or incomplete"
  _gamebox_android_lease_pid_alive "$owner_pid" && state="active"
  printf '%s: root=%s pid=%s device=%s acquired=%s\n' "$state" \
    "${owner_root:-unknown}" "${owner_pid:-unknown}" "${owner_device:-unknown}" "${owner_started:-unknown}"
}

gamebox_android_lease_reclaim_for_root() {
  local root common_dir lease_dir owner_file owner_pid owner_root
  root="$(cd "$1" && pwd -P)" || return 2
  common_dir="$(_gamebox_android_lease_common_dir "$root")" || return 2
  lease_dir="$common_dir/gamebox-android.lease"
  owner_file="$lease_dir/owner"
  [[ -d "$lease_dir" ]] || return 0
  owner_root="$(_gamebox_android_lease_value "$owner_file" root 2>/dev/null || true)"
  owner_pid="$(_gamebox_android_lease_value "$owner_file" pid 2>/dev/null || true)"
  [[ "$owner_root" == "$root" ]] || {
    printf 'Android lease belongs to another worktree (%s); no shared state was removed.\n' \
      "${owner_root:-unknown}" >&2
    return 1
  }
  if _gamebox_android_lease_pid_alive "$owner_pid"; then
    printf 'Android work is still active for this worktree (PID %s); interrupt its foreground terminal first.\n' \
      "$owner_pid" >&2
    return 1
  fi
  _gamebox_android_reclaim_dead_lease "$lease_dir" "$common_dir"
}

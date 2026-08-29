#!/usr/bin/env bash

# Shared Android lease pool. Managed E2E runs lease one complete slot; every
# other Android mutator keeps the conservative exclusive lease.
GAMEBOX_ANDROID_LEASE_OWNED=0
GAMEBOX_ANDROID_LEASE_INHERITED=0
GAMEBOX_ANDROID_LEASE_DIR="${GAMEBOX_ANDROID_LEASE_DIR:-}"
GAMEBOX_ANDROID_LEASE_TOKEN="${GAMEBOX_ANDROID_LEASE_TOKEN:-}"
GAMEBOX_ANDROID_LEASE_OWNER_PID="${GAMEBOX_ANDROID_LEASE_OWNER_PID:-}"
GAMEBOX_ANDROID_LEASE_ROOT="${GAMEBOX_ANDROID_LEASE_ROOT:-}"
GAMEBOX_ANDROID_LEASE_KIND="${GAMEBOX_ANDROID_LEASE_KIND:-}"
GAMEBOX_ANDROID_LEASE_SLOT="${GAMEBOX_ANDROID_LEASE_SLOT:-}"

_gamebox_android_lease_value() {
  local file="$1" key="$2"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  awk -v prefix="$key=" 'index($0, prefix) == 1 { print substr($0, length(prefix)+1); exit }' "$file"
}
_gamebox_android_lease_pid_alive() { [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" >/dev/null 2>&1; }
_gamebox_android_lease_common_dir() {
  local root="$1" common
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$root" rev-parse --git-common-dir)" || return 1
  [[ "$common" == /* ]] || common="$(cd "$root" && cd "$common" && pwd -P)"
  [[ "$common" == /* ]] || return 1
  cd "$common" && pwd -P
}
_gamebox_android_new_lease_token() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 24
  else printf '%s' "$$:$RANDOM:$RANDOM:$(date -u +%s):$1" | shasum -a 256 | awk '{print $1}'; fi
}
_gamebox_android_lease_safe_dir() { [[ -d "$1" && ! -L "$1" ]]; }
_gamebox_android_lease_lock() {
  local lock="$1" deadline="$2" pid
  while ! mkdir "$lock" 2>/dev/null; do
    _gamebox_android_lease_safe_dir "$lock" || return 1
    pid="$(_gamebox_android_lease_value "$lock/owner" pid 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! _gamebox_android_lease_pid_alive "$pid"; then rm -f "$lock/owner" && rmdir "$lock" 2>/dev/null && continue; fi
    (( SECONDS < deadline )) || return 75
    sleep 1
  done
  chmod 700 "$lock"; (umask 077; printf 'pid=%s\n' "$$" >"$lock/owner")
}
_gamebox_android_lease_unlock() { rm -f "$1/owner"; rmdir "$1" 2>/dev/null || true; }
_gamebox_android_lease_reclaim_dead() {
  local dir="$1" pid stale
  _gamebox_android_lease_safe_dir "$dir" || return 1
  pid="$(_gamebox_android_lease_value "$dir/owner" pid 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && ! _gamebox_android_lease_pid_alive "$pid" || return 1
  stale="$dir.stale-$$-$RANDOM"; mv "$dir" "$stale" 2>/dev/null || return 1
  rm -f "$stale/owner" && rmdir "$stale" 2>/dev/null || return 1
  printf 'Reclaimed stale Gamebox Android lease (dead PID %s).\n' "$pid"
}
_gamebox_android_lease_describe_owner() {
  local owner="$1" kind="$2" slot="${3:-}" pid root devices acquired state
  pid="$(_gamebox_android_lease_value "$owner" pid 2>/dev/null || true)"; root="$(_gamebox_android_lease_value "$owner" root 2>/dev/null || true)"
  devices="$(_gamebox_android_lease_value "$owner" devices 2>/dev/null || _gamebox_android_lease_value "$owner" device 2>/dev/null || true)"; acquired="$(_gamebox_android_lease_value "$owner" acquired_at 2>/dev/null || true)"
  state=stale; _gamebox_android_lease_pid_alive "$pid" && state=active
  printf '%s %s%s: root=%s pid=%s devices=%s acquired=%s' "$kind" "$state" "${slot:+ slot=$slot}" "${root:-unknown}" "${pid:-unknown}" "${devices:-unknown}" "${acquired:-unknown}"
}
_gamebox_android_lease_write_owner() {
  local dir="$1" root="$2" kind="$3" slot="$4" devices="$5" token tmp
  token="$(_gamebox_android_new_lease_token "$root")" || return 1; tmp="$dir/owner.tmp.$$"
  (umask 077
    printf 'version=2\ntoken=%s\npid=%s\nroot=%s\nkind=%s\n' "$token" "$$" "$root" "$kind"
    [[ -n "$slot" ]] && printf 'slot=%s\n' "$slot"
    printf 'devices=%s\nacquired_at=%s\n' "$devices" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ) >"$tmp"; chmod 600 "$tmp"; mv "$tmp" "$dir/owner"
  GAMEBOX_ANDROID_LEASE_OWNED=1; GAMEBOX_ANDROID_LEASE_INHERITED=0; GAMEBOX_ANDROID_LEASE_DIR="$dir"; GAMEBOX_ANDROID_LEASE_TOKEN="$token"; GAMEBOX_ANDROID_LEASE_OWNER_PID="$$"; GAMEBOX_ANDROID_LEASE_ROOT="$root"; GAMEBOX_ANDROID_LEASE_KIND="$kind"; GAMEBOX_ANDROID_LEASE_SLOT="$slot"
  export GAMEBOX_ANDROID_LEASE_DIR GAMEBOX_ANDROID_LEASE_TOKEN GAMEBOX_ANDROID_LEASE_OWNER_PID GAMEBOX_ANDROID_LEASE_ROOT GAMEBOX_ANDROID_LEASE_KIND GAMEBOX_ANDROID_LEASE_SLOT
}
_gamebox_android_lease_inherit() {
  local dir="$1" root="$2" kind="$3" slot="$4" owner="$dir/owner" token pid owner_root
  token="${GAMEBOX_ANDROID_LEASE_TOKEN:-}"
  [[ -n "$token" && "${GAMEBOX_ANDROID_LEASE_DIR:-}" == "$dir" && "$(_gamebox_android_lease_value "$owner" token 2>/dev/null || true)" == "$token" ]] || return 1
  pid="$(_gamebox_android_lease_value "$owner" pid 2>/dev/null || true)"; owner_root="$(_gamebox_android_lease_value "$owner" root 2>/dev/null || true)"
  [[ "$owner_root" == "$root" && "$(_gamebox_android_lease_value "$owner" kind 2>/dev/null || true)" == "$kind" && "$(_gamebox_android_lease_value "$owner" slot 2>/dev/null || true)" == "$slot" ]] || return 2
  _gamebox_android_lease_pid_alive "$pid" || return 2
  GAMEBOX_ANDROID_LEASE_OWNED=0; GAMEBOX_ANDROID_LEASE_INHERITED=1; GAMEBOX_ANDROID_LEASE_OWNER_PID="$pid"; GAMEBOX_ANDROID_LEASE_ROOT="$root"; GAMEBOX_ANDROID_LEASE_KIND="$kind"; GAMEBOX_ANDROID_LEASE_SLOT="$slot"
}
_gamebox_android_lease_acquire() {
  local root="$1" kind="$2" slot="$3" devices="$4" timeout="$5" common pool lock legacy dir deadline reported=0
  [[ "$timeout" =~ ^[0-9]+$ ]] || { printf 'GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS must be a non-negative integer.\n' >&2; return 2; }
  root="$(cd "$root" && pwd -P)" || return 2; common="$(_gamebox_android_lease_common_dir "$root")" || { printf 'Gamebox Android lease requires a Git worktree.\n' >&2; return 2; }
  pool="$common/gamebox-android-leases"; lock="$pool/allocator.lock"; legacy="$common/gamebox-android.lease"; dir="$pool/exclusive"; [[ "$kind" == slot ]] && dir="$pool/slots/$slot"
  if _gamebox_android_lease_inherit "$dir" "$root" "$kind" "$slot"; then return 0; else local inherit_status=$?; [[ "$inherit_status" == 1 ]] || { printf 'Gamebox Android lease inheritance metadata is invalid; refusing to bypass shared state.\n' >&2; return 1; }; fi
  deadline=$((SECONDS + timeout))
  while :; do
    mkdir -p "$pool/slots" || return 1
    _gamebox_android_lease_lock "$lock" "$deadline" || { [[ $? == 75 ]] && printf 'Timed out waiting for Gamebox Android lease allocator.\n' >&2; return 75; }
    local blocked=0 diag="" candidate selected_slot=""
    if _gamebox_android_lease_safe_dir "$legacy"; then _gamebox_android_lease_reclaim_dead "$legacy" || { blocked=1; diag="legacy $(_gamebox_android_lease_describe_owner "$legacy/owner" legacy)"; }; fi
    if (( ! blocked )) && [[ "$kind" == exclusive ]]; then
      if _gamebox_android_lease_safe_dir "$pool/exclusive"; then _gamebox_android_lease_reclaim_dead "$pool/exclusive" || { blocked=1; diag="$(_gamebox_android_lease_describe_owner "$pool/exclusive/owner" exclusive)"; }; fi
      if (( ! blocked )); then for candidate in "$pool/slots/0" "$pool/slots/1"; do if _gamebox_android_lease_safe_dir "$candidate"; then _gamebox_android_lease_reclaim_dead "$candidate" || { blocked=1; diag="$(_gamebox_android_lease_describe_owner "$candidate/owner" slot "${candidate##*/}")"; break; }; fi; done; fi
    fi
    if (( ! blocked )) && [[ "$kind" == slot && "$slot" == auto ]]; then
      for candidate in 0 1; do
        if _gamebox_android_lease_safe_dir "$pool/slots/$candidate"; then
          _gamebox_android_lease_reclaim_dead "$pool/slots/$candidate" || continue
        fi
        selected_slot="$candidate"; break
      done
      if [[ -n "$selected_slot" ]]; then slot="$selected_slot"; dir="$pool/slots/$slot"; else blocked=1; diag="both managed slots are active"; fi
    fi
    if (( ! blocked )) && [[ "$kind" == slot ]]; then
      if _gamebox_android_lease_safe_dir "$pool/exclusive"; then _gamebox_android_lease_reclaim_dead "$pool/exclusive" || { blocked=1; diag="$(_gamebox_android_lease_describe_owner "$pool/exclusive/owner" exclusive)"; }; fi
      if (( ! blocked )) && _gamebox_android_lease_safe_dir "$dir"; then _gamebox_android_lease_reclaim_dead "$dir" || { blocked=1; diag="$(_gamebox_android_lease_describe_owner "$dir/owner" slot "$slot")"; }; fi
    fi
    if (( ! blocked )) && mkdir "$dir" 2>/dev/null; then chmod 700 "$dir"; _gamebox_android_lease_write_owner "$dir" "$root" "$kind" "$slot" "$devices" || { rmdir "$dir"; _gamebox_android_lease_unlock "$lock"; return 1; }; _gamebox_android_lease_unlock "$lock"; printf 'Acquired Gamebox Android %s lease%s for %s (%s).\n' "$kind" "${slot:+ slot $slot}" "$root" "$devices"; return 0; fi
    _gamebox_android_lease_unlock "$lock"
    if (( SECONDS >= deadline )); then printf 'Timed out waiting for Gamebox Android %s lease. %s\n' "$kind" "$diag" >&2; return 75; fi
    if (( ! reported )); then printf 'Waiting for Gamebox Android %s lease: %s\n' "$kind" "${diag:-allocator initializing}"; reported=1; fi
    sleep 1
  done
}
gamebox_android_lease_acquire() { _gamebox_android_lease_acquire "$1" exclusive "" "$2" "${3:-${GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS:-900}}"; }
gamebox_android_lease_acquire_slot() { [[ "$2" =~ ^[01]$ ]] || { printf 'Gamebox Android slot must be 0 or 1.\n' >&2; return 2; }; _gamebox_android_lease_acquire "$1" slot "$2" "$3:$4,$5:$6" "${7:-${GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS:-900}}"; }
gamebox_android_lease_acquire_available_slot() { _gamebox_android_lease_acquire "$1" slot auto "$2" "${3:-${GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS:-900}}"; }
gamebox_android_lease_release() {
  (( GAMEBOX_ANDROID_LEASE_INHERITED == 0 && GAMEBOX_ANDROID_LEASE_OWNED == 1 )) || return 0
  local owner="$GAMEBOX_ANDROID_LEASE_DIR/owner"
  [[ "$(_gamebox_android_lease_value "$owner" token 2>/dev/null || true)" == "$GAMEBOX_ANDROID_LEASE_TOKEN" && "$(_gamebox_android_lease_value "$owner" pid 2>/dev/null || true)" == "$$" && "$(_gamebox_android_lease_value "$owner" root 2>/dev/null || true)" == "$GAMEBOX_ANDROID_LEASE_ROOT" ]] || { printf 'Gamebox Android lease ownership changed; shared metadata was preserved.\n' >&2; return 1; }
  rm -f "$owner"; rmdir "$GAMEBOX_ANDROID_LEASE_DIR" || return 1; GAMEBOX_ANDROID_LEASE_OWNED=0; unset GAMEBOX_ANDROID_LEASE_DIR GAMEBOX_ANDROID_LEASE_TOKEN GAMEBOX_ANDROID_LEASE_OWNER_PID GAMEBOX_ANDROID_LEASE_ROOT GAMEBOX_ANDROID_LEASE_KIND GAMEBOX_ANDROID_LEASE_SLOT
}
gamebox_android_lease_describe() {
  local root="$1" common pool out=() dir
  root="$(cd "$root" && pwd -P)" || return 2; common="$(_gamebox_android_lease_common_dir "$root")" || return 2; pool="$common/gamebox-android-leases"
  for dir in "$pool/slots/0" "$pool/slots/1"; do if _gamebox_android_lease_safe_dir "$dir"; then out+=("$(_gamebox_android_lease_describe_owner "$dir/owner" slot "${dir##*/}")"); else out+=("slot idle slot=${dir##*/}"); fi; done
  _gamebox_android_lease_safe_dir "$pool/exclusive" && out+=("$(_gamebox_android_lease_describe_owner "$pool/exclusive/owner" exclusive)")
  _gamebox_android_lease_safe_dir "$common/gamebox-android.lease" && out+=("$(_gamebox_android_lease_describe_owner "$common/gamebox-android.lease/owner" legacy)")
  (IFS='; '; printf '%s\n' "${out[*]}")
}
gamebox_android_lease_reclaim_for_root() {
  local root="$1" common pool dir owner_root pid
  root="$(cd "$root" && pwd -P)" || return 2; common="$(_gamebox_android_lease_common_dir "$root")" || return 2; pool="$common/gamebox-android-leases"
  for dir in "$pool/slots/0" "$pool/slots/1" "$pool/exclusive" "$common/gamebox-android.lease"; do _gamebox_android_lease_safe_dir "$dir" || continue; owner_root="$(_gamebox_android_lease_value "$dir/owner" root 2>/dev/null || true)"; [[ "$owner_root" == "$root" ]] || continue; pid="$(_gamebox_android_lease_value "$dir/owner" pid 2>/dev/null || true)"; _gamebox_android_lease_pid_alive "$pid" && { printf 'Android work is still active for this worktree (PID %s).\n' "$pid" >&2; return 1; }; _gamebox_android_lease_reclaim_dead "$dir" || return 1; done
}

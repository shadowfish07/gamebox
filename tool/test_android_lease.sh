#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
readonly LEASE_LIBRARY="$ROOT_DIR/tool/lib/android_lease.sh"

fixture_root="$(mktemp -d -t gamebox-android-lease.XXXXXX)"
readonly fixture_root
fixture_repo="$fixture_root/repo"
ready_file="$fixture_root/ready"
cleanup() {
  local exit_status=$?
  trap - EXIT
  set +e
  [[ -n "${worker_pid:-}" ]] && kill -TERM "$worker_pid" >/dev/null 2>&1 || true
  [[ -n "${worker_pid:-}" ]] && wait "$worker_pid" >/dev/null 2>&1 || true
  rm -rf "$fixture_root"
  exit "$exit_status"
}
trap cleanup EXIT

git init -q "$fixture_repo"

bash -c '
  set -euo pipefail
  source "$1"
  gamebox_android_lease_acquire "$2" fixture-device 5
  : >"$3"
  sleep 3
  gamebox_android_lease_release
' _ "$LEASE_LIBRARY" "$fixture_repo" "$ready_file" &
worker_pid=$!

for _ in 1 2 3 4 5; do
  [[ -f "$ready_file" ]] && break
  sleep 1
done
[[ -f "$ready_file" ]] || {
  printf 'Android lease fixture owner did not become ready.\n' >&2
  exit 1
}

# shellcheck source=tool/lib/android_lease.sh
source "$LEASE_LIBRARY"
contender_status=0
contender_output="$(gamebox_android_lease_acquire "$fixture_repo" contender-device 1 2>&1)" \
  || contender_status=$?
[[ "$contender_status" -eq 75 ]] || {
  printf 'Android lease contender exited %s instead of 75:\n%s\n' \
    "$contender_status" "$contender_output" >&2
  exit 1
}
grep -F 'fixture-device' <<<"$contender_output" >/dev/null || {
  printf 'Android lease contention diagnostics omitted the current device.\n' >&2
  exit 1
}

wait "$worker_pid"
worker_pid=""

gamebox_android_lease_acquire "$fixture_repo" inherited-parent 2
inherited_output="$(bash -c '
  set -euo pipefail
  source "$1"
  gamebox_android_lease_acquire "$2" inherited-child 1
  [[ "$GAMEBOX_ANDROID_LEASE_INHERITED" -eq 1 ]]
  gamebox_android_lease_release
  [[ -d "$GAMEBOX_ANDROID_LEASE_DIR" ]]
  printf inherited
' _ "$LEASE_LIBRARY" "$fixture_repo")"
[[ "$inherited_output" == inherited ]] || {
  printf 'Android lease child inheritance failed: %s\n' "$inherited_output" >&2
  exit 1
}
[[ -d "$GAMEBOX_ANDROID_LEASE_DIR" ]] || {
  printf 'Inherited child removed the parent Android lease.\n' >&2
  exit 1
}
gamebox_android_lease_release

common_dir="$(git -C "$fixture_repo" rev-parse --path-format=absolute --git-common-dir)"
stale_dir="$common_dir/gamebox-android.lease"
mkdir "$stale_dir"
chmod 700 "$stale_dir"
cat >"$stale_dir/owner" <<EOF
version=1
token=stale-fixture
pid=99999999
root=$fixture_repo
device=stale-device
acquired_at=2000-01-01T00:00:00Z
EOF
chmod 600 "$stale_dir/owner"

stale_output="$(gamebox_android_lease_acquire "$fixture_repo" replacement-device 2)"
grep -F 'Reclaimed stale Gamebox Android lease' <<<"$stale_output" >/dev/null || {
  printf 'Android lease did not report stale-owner reclamation.\n' >&2
  exit 1
}
gamebox_android_lease_release

printf 'Gamebox Android lease fixtures passed.\n'

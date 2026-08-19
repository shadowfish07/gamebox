#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# shellcheck source=tool/lib/android_smoke_log.sh
source "$ROOT_DIR/tool/lib/android_smoke_log.sh"

readonly APP="me.zqydev.gamebox"
readonly GAME="$APP:game"
readonly HELPER="$APP.test"
readonly PID="4242"
readonly MARKER="GAMEBOX_BOUNDARY_nonce"

fixture="$({
  printf '%s\n' 'old FATAL EXCEPTION: old crash'
  printf '%s\n' 'old Process: me.zqydev.gamebox:game, PID: 111'
  printf '%s\n' "GameboxSmoke: $MARKER"
  printf '%s\n' 'godot: GAMEBOX_GODOT_READY'
  printf '%s\n' 'godot: GAMEBOX_GODOT_EXITING'
})"
bounded="$(gamebox_logs_after_marker "$MARKER" <<<"$fixture")"
if grep -Fq 'old FATAL' <<<"$bounded"; then
  echo "Pre-boundary fatal text leaked into bounded logs." >&2
  exit 1
fi
gamebox_assert_markers_in_order \
  'GAMEBOX_GODOT_READY' \
  'GAMEBOX_GODOT_EXITING' <<<"$bounded"
if gamebox_find_crash_evidence "$APP" "$GAME" "$HELPER" "$PID" <<<"$bounded" | grep -q .; then
  echo "Clean bounded fixture was incorrectly classified as a crash." >&2
  exit 1
fi

for crash_fixture in \
  $'FATAL EXCEPTION: main\nProcess: me.zqydev.gamebox:game, PID: 4242' \
  'Fatal signal 11 (SIGSEGV), code 1, fault addr 0x0 in tid 4242, pid 4242' \
  'DEBUG: pid: 4242, tid: 4243, name: godot >>> me.zqydev.gamebox:game <<<' \
  'am_crash: [4242,0,me.zqydev.gamebox:game]' \
  "lmkd: Killing 'me.zqydev.gamebox:game' (4242), uid 10123" \
  'ANR in me.zqydev.gamebox:game'; do
  evidence="$(gamebox_find_crash_evidence "$APP" "$GAME" "$HELPER" "$PID" <<<"$crash_fixture")"
  [[ -n "$evidence" ]]
done

post_marker_fixture="$fixture"$'\nFatal signal 6 (SIGABRT), code -1, pid 4242'
post_marker_logs="$(gamebox_logs_after_marker "$MARKER" <<<"$post_marker_fixture")"
[[ -n "$(gamebox_find_crash_evidence "$APP" "$GAME" "$HELPER" "$PID" <<<"$post_marker_logs")" ]]

echo "Android smoke log parser tests passed."

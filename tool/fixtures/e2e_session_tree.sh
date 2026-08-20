#!/bin/sh
set -eu

: "${GAMEBOX_E2E_TREE_PID_FILE:?}"

if [ "${GAMEBOX_E2E_TREE_MODE:-normal}" = "ignore-term" ]; then
  trap '' TERM
  sh -c 'trap "" TERM; sleep 60' &
else
  sleep 60 &
fi
grandchild_pid=$!
printf '%s %s\n' "$$" "$grandchild_pid" >"$GAMEBOX_E2E_TREE_PID_FILE"
wait "$grandchild_pid"

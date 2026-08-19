#!/usr/bin/env bash

gamebox_logs_after_marker() {
  local marker="$1"
  awk -v marker="$marker" '
    found { print }
    index($0, marker) { found = 1 }
  '
}

gamebox_assert_markers_in_order() {
  local ready_marker="$1"
  local exiting_marker="$2"
  awk -v ready="$ready_marker" -v exiting="$exiting_marker" '
    !ready_seen && index($0, ready) { ready_seen = 1; next }
    ready_seen && index($0, exiting) { exiting_seen = 1; exit }
    END { exit !(ready_seen && exiting_seen) }
  '
}

gamebox_find_crash_evidence() {
  local app_package="$1"
  local game_process="$2"
  local helper_package="$3"
  local game_pid="$4"
  awk \
    -v app="$app_package" \
    -v game="$game_process" \
    -v helper="$helper_package" \
    -v pid="$game_pid" '
      /FATAL EXCEPTION/ { fatal = $0; next }
      fatal != "" && /Process:/ {
        if (index($0, app) || index($0, helper)) print fatal "\n" $0
        fatal = ""
        next
      }
      /Fatal signal/ && (index($0, pid) || index($0, game)) { print; next }
      />>>/ && index($0, game) && (index($0, "DEBUG") || index($0, pid)) { print; next }
      /am_crash/ && (index($0, app) || index($0, helper) || index($0, pid)) { print; next }
      /ANR in / && (index($0, app) || index($0, helper)) { print; next }
      /am_anr/ && (index($0, app) || index($0, helper) || index($0, pid)) { print; next }
      /(lowmemorykiller|lmkd|LMKD|Killing)/ && (index($0, game) || index($0, pid)) { print }
    '
}

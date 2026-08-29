#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

if [[ ! -x "$GODOT_BIN" ]]; then
  printf 'Godot 4 executable not found: %s\n' "$GODOT_BIN" >&2
  exit 1
fi

exec "$GODOT_BIN" \
  --path "$ROOT/game_runtime" \
  --script "$ROOT/tool/rps_preview.gd" \
  --rendering-driver opengl3 \
  -- "$@"

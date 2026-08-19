#!/usr/bin/env bash
set -euo pipefail

(cd server && go test ./...)
(cd app && flutter analyze && flutter test)
"${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}" --headless --path game_runtime --script res://test/run_tests.gd

# Godot currently logs a missing --script resource but exits successfully on
# macOS. Make that missing runner an unambiguous verification failure.
test -f game_runtime/test/run_tests.gd

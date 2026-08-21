#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GODOT_BIN:-}" ]] && command -v godot >/dev/null 2>&1; then
  export GODOT_BIN
  GODOT_BIN="$(command -v godot)"
fi

(cd server && go test ./...)
(cd app && flutter analyze && flutter test)
bash tool/verify_godot_tests.sh
bash tool/test_android_smoke_log.sh

#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GODOT_BIN:-}" ]] && command -v godot >/dev/null 2>&1; then
  export GODOT_BIN
  GODOT_BIN="$(command -v godot)"
fi

(cd server && go test ./...)
(cd packages/flutter_release_updater && flutter pub get && flutter analyze && flutter test)
(cd app && flutter analyze && flutter test)
bash -n tool/worktree.sh tool/lib/android_lease.sh tool/test_android_lease.sh \
  tool/e2e_android.sh tool/ensure_test_avds.sh \
  tool/smoke_android_host.sh tool/smoke_android_release_apk.sh
bash tool/test_android_lease.sh
bash tool/verify_godot_tests.sh
bash tool/test_android_smoke_log.sh

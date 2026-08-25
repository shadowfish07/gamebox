#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GODOT_BIN:-}" ]] && command -v godot >/dev/null 2>&1; then
  export GODOT_BIN
  GODOT_BIN="$(command -v godot)"
fi

bash tool/verify_design_system.sh
(cd server && go test ./...)
# Flutter 3.47.1's `flutter analyze` LSP transport truncates initialization
# messages when the checkout path contains non-ASCII characters. `dart analyze`
# runs the same analyzer directly and remains reliable in Orca worktrees.
(cd app && flutter pub get --enforce-lockfile && dart analyze && flutter test)
bash -n tool/worktree.sh tool/lib/android_lease.sh tool/test_android_lease.sh \
  tool/e2e_android.sh tool/ensure_test_avds.sh \
  tool/smoke_android_host.sh tool/smoke_android_release_apk.sh
for deploy_script in deploy/macos/install.sh deploy/macos/install-staging.sh; do
  if command -v zsh >/dev/null 2>&1; then
    zsh -n "$deploy_script"
  else
    # Ubuntu CI does not ship zsh; bash -n still catches shell syntax errors.
    bash -n "$deploy_script"
  fi
done
bash tool/test_macos_deploy.sh
bash tool/test_android_lease.sh
bash tool/verify_godot_tests.sh
bash tool/test_android_smoke_log.sh

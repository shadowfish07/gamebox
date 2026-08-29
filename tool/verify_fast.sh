#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
cd "$ROOT_DIR"
# shellcheck source=tool/lib/check_output.sh
source "$ROOT_DIR/tool/lib/check_output.sh"
gamebox_test_output_init
trap gamebox_test_output_cleanup EXIT

if [[ -z "${GODOT_BIN:-}" ]] && command -v godot >/dev/null 2>&1; then
  export GODOT_BIN
  GODOT_BIN="$(command -v godot)"
fi

run_go_tests() {
  (cd server && go test ./...)
}

run_flutter_pub_get() {
  (cd app && flutter pub get --enforce-lockfile)
}

run_dart_analyze() {
  (cd app && dart analyze)
}

run_flutter_tests() {
  (cd app && flutter test)
}

gamebox_run_step "design system verification" bash tool/verify_design_system.sh
gamebox_run_step "Go tests" run_go_tests
# Flutter 3.47.1's `flutter analyze` LSP transport truncates initialization
# messages when the checkout path contains non-ASCII characters. `dart analyze`
# runs the same analyzer directly and remains reliable in Orca worktrees.
gamebox_run_step "Flutter locked dependencies" run_flutter_pub_get
gamebox_run_step "Dart analysis" run_dart_analyze
gamebox_run_step "Flutter tests" run_flutter_tests
gamebox_run_step "shell syntax" bash -n \
  tool/worktree.sh tool/lib/ai_rules_link.sh tool/lib/android_lease.sh tool/lib/check_output.sh \
  tool/test_ai_rules_link.sh \
  tool/test_android_lease.sh tool/test_check_output.sh tool/test_verify_godot_tests.sh \
  tool/e2e_android.sh tool/e2e/run.sh tool/e2e/harness.sh \
  tool/e2e/test_cli.sh tool/e2e/lib/options.sh tool/e2e/scenarios/registry.sh \
  tool/ensure_test_avds.sh \
  tool/smoke_android_host.sh tool/smoke_android_release_apk.sh \
  tool/release.sh tool/test_release.sh tool/test_debug_workflow.sh
verify_macos_deploy_syntax() {
  local deploy_script
  for deploy_script in deploy/macos/install.sh deploy/macos/install-staging.sh; do
    zsh -n "$deploy_script"
  done
}

gamebox_run_step "check output fixtures" bash tool/test_check_output.sh
gamebox_run_step "AI rules link fixtures" bash tool/test_ai_rules_link.sh
gamebox_run_step "release command fixtures" bash tool/test_release.sh
gamebox_run_step "debug workflow fixtures" bash tool/test_debug_workflow.sh
gamebox_run_step "Godot verifier status fixtures" bash tool/test_verify_godot_tests.sh
gamebox_run_step "macOS deploy script syntax" verify_macos_deploy_syntax
gamebox_run_step "macOS deploy fixtures" bash tool/test_macos_deploy.sh
gamebox_run_step "Android lease fixtures" bash tool/test_android_lease.sh
gamebox_run_step "E2E entrypoint fixtures" env GAMEBOX_TEST_NESTED=1 bash tool/e2e/run.sh --self-test
gamebox_run_step "Godot tests" env GAMEBOX_TEST_NESTED=1 bash tool/verify_godot_tests.sh
gamebox_run_step "Android smoke log fixtures" bash tool/test_android_smoke_log.sh
gamebox_test_output_finish verify-fast

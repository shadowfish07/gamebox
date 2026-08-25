#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
fixture_root="$(mktemp -d -t gamebox-godot-status.XXXXXX)"
readonly fixture_root

cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

fake_godot="$fixture_root/fake-godot"
cat >"$fake_godot" <<'EOF'
#!/usr/bin/env bash
printf 'fixture Godot failure\n' >&2
exit 2
EOF
chmod +x "$fake_godot"

runner_status=0
runner_output="$(
  GODOT_BIN="$fake_godot" \
    GAMEBOX_TEST_OUTPUT=compact \
    bash "$ROOT_DIR/tool/verify_godot_tests.sh" 2>&1
)" || runner_status=$?
[[ "$runner_status" -eq 2 ]] || {
  printf 'Godot verifier changed child status 2 to %s:\n%s\n' \
    "$runner_status" "$runner_output" >&2
  exit 1
}
grep -F 'fixture Godot failure' <<<"$runner_output" >/dev/null || {
  printf 'Godot verifier omitted the child diagnostic:\n%s\n' "$runner_output" >&2
  exit 1
}

printf 'Godot verifier status fixtures passed.\n'

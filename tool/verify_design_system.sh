#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v jq >/dev/null 2>&1 || {
  echo "jq is required for design-system verification." >&2
  exit 1
}
command -v dart >/dev/null 2>&1 || {
  echo "dart is required for design-system verification." >&2
  exit 1
}
command -v flutter >/dev/null 2>&1 || {
  echo "flutter is required for design-system verification." >&2
  exit 1
}

sdk_metadata="$(flutter --version --machine)"
if ! jq -e \
  '.frameworkVersion == "3.35.1" and (.dartSdkVersion | startswith("3.9.0"))' \
  >/dev/null <<<"$sdk_metadata"; then
  echo "Design tokens require Flutter 3.35.1 and Dart 3.9.0." >&2
  exit 1
fi

# Parsing is only the first check. The generator below reads the canonical
# $schema file and executes the repository's fail-closed schema validator.
jq -e 'type == "object"' design_system/schema/tokens.schema.json >/dev/null
jq -e 'type == "object"' design_system/tokens/gamebox.tokens.json >/dev/null

# The Dart harness owns normative reconciliation and the only production
# hard-code scanner, including committed fixtures and the exact legacy multiset.
dart tool/test_design_tokens.dart

temporary_dir="$(mktemp -d -t gamebox-design-system.XXXXXX)"
trap 'rm -rf "$temporary_dir"' EXIT

dart tool/generate_design_tokens.dart \
  --input design_system/tokens/gamebox.tokens.json \
  --dart-output "$temporary_dir/gamebox_tokens.g.dart" \
  --godot-output "$temporary_dir/gamebox_tokens.gd"

if ! cmp -s \
  app/lib/design_system/generated/gamebox_tokens.g.dart \
  "$temporary_dir/gamebox_tokens.g.dart"; then
  echo "Dart design tokens have drifted; run the generator." >&2
  diff -u \
    app/lib/design_system/generated/gamebox_tokens.g.dart \
    "$temporary_dir/gamebox_tokens.g.dart" || true
  exit 1
fi
if ! cmp -s \
  game_runtime/design_system/generated/gamebox_tokens.gd \
  "$temporary_dir/gamebox_tokens.gd"; then
  echo "GDScript design tokens have drifted; run the generator." >&2
  diff -u \
    game_runtime/design_system/generated/gamebox_tokens.gd \
    "$temporary_dir/gamebox_tokens.gd" || true
  exit 1
fi

(cd app && flutter test test/design_system/derive_color_scheme_test.dart)

echo "GAMEBOX_DESIGN_SYSTEM_VERIFIED"

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
command -v rg >/dev/null 2>&1 || {
  echo "ripgrep is required for design-system verification." >&2
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

flutter_matches="$temporary_dir/flutter-matches"
flutter_baseline="$temporary_dir/flutter-baseline"
godot_matches="$temporary_dir/godot-matches"
godot_baseline="$temporary_dir/godot-baseline"

{
  rg --no-heading --no-line-number -o \
    --glob '*.dart' \
    --glob '!**/design_system/generated/**' \
    'Colors\.[A-Za-z0-9_]+|Color\(0x[0-9A-Fa-f]+|fontSize\s*:|BorderRadius|Duration\(milliseconds\s*:|EdgeInsets\.(all|symmetric|only)\([^)]*[0-9]+(?:\.[0-9]+)?|SizedBox\([^)]*(?:height|width)\s*:\s*[0-9]+(?:\.[0-9]+)?' \
    app/lib || true
} | LC_ALL=C sort >"$flutter_matches"

while IFS= read -r baseline; do
  printf '%s\n' "$baseline"
done <<'FLUTTER_BASELINE' | LC_ALL=C sort >"$flutter_baseline"
app/lib/app.dart:Colors.deepPurple
app/lib/app.dart:SizedBox(height: 12
app/lib/app.dart:SizedBox(height: 12
app/lib/app.dart:SizedBox(height: 16
app/lib/features/auth/registration_page.dart:EdgeInsets.all(24
app/lib/features/auth/registration_page.dart:EdgeInsets.all(24
app/lib/features/auth/registration_page.dart:EdgeInsets.all(24
app/lib/features/auth/registration_page.dart:SizedBox(height: 16
app/lib/features/auth/registration_page.dart:SizedBox(height: 16
app/lib/features/auth/registration_page.dart:SizedBox(height: 24
app/lib/features/auth/registration_page.dart:SizedBox(height: 24
app/lib/features/auth/registration_page.dart:SizedBox(height: 24
app/lib/features/auth/registration_page.dart:SizedBox(height: 24
app/lib/features/auth/registration_page.dart:SizedBox(height: 8
app/lib/features/auth/registration_page.dart:SizedBox(height: 8
app/lib/features/home/home_page.dart:EdgeInsets.all(20
app/lib/features/home/home_page.dart:EdgeInsets.all(24
app/lib/features/home/home_page.dart:SizedBox(height: 16
app/lib/features/home/home_page.dart:SizedBox(height: 16
app/lib/features/home/home_page.dart:SizedBox(height: 16
app/lib/features/home/home_page.dart:SizedBox(height: 20
app/lib/features/home/home_page.dart:SizedBox(height: 8
app/lib/features/home/home_page.dart:SizedBox(height: 8
app/lib/features/home/opponent_page.dart:EdgeInsets.all(24
app/lib/features/home/opponent_page.dart:EdgeInsets.all(24
app/lib/features/home/opponent_page.dart:EdgeInsets.symmetric(vertical: 12
app/lib/features/home/opponent_page.dart:SizedBox(height: 16
app/lib/features/update/update_action.dart:SizedBox(height: 12
app/lib/features/update/update_action.dart:SizedBox(height: 16
app/lib/features/update/update_action.dart:SizedBox(height: 16
app/lib/features/update/update_action.dart:SizedBox(height: 6
app/lib/features/update/update_action.dart:SizedBox(height: 8
app/lib/features/update/update_action.dart:SizedBox(width: 10
FLUTTER_BASELINE

{
  rg --no-heading --no-line-number -o \
    --glob '*.gd' \
    --glob '*.tscn' \
    --glob '!**/design_system/generated/**' \
    'Color\("#?[0-9A-Fa-f]{6}"\)|Color\(0\.|theme_override_[A-Za-z0-9_/]+' \
    game_runtime || true
} | LC_ALL=C sort >"$godot_matches"

while IFS= read -r baseline; do
  printf '%s\n' "$baseline"
done <<'GODOT_BASELINE' | LC_ALL=C sort >"$godot_baseline"
game_runtime/games/gomoku/gomoku_board.gd:Color("0072b2")
game_runtime/games/gomoku/gomoku_board.gd:Color("151a24")
game_runtime/games/gomoku/gomoku_board.gd:Color("493217")
game_runtime/games/gomoku/gomoku_board.gd:Color("667085")
game_runtime/games/gomoku/gomoku_board.gd:Color("d8a85f")
game_runtime/games/gomoku/gomoku_board.gd:Color("f04438")
game_runtime/games/gomoku/gomoku_board.gd:Color("f8fafc")
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_colors/font_color
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_colors/font_color
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_colors/font_color
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_colors/font_color
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_colors/font_color
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size
GODOT_BASELINE

new_flutter="$temporary_dir/new-flutter-hardcodes"
new_godot="$temporary_dir/new-godot-hardcodes"
comm -23 "$flutter_matches" "$flutter_baseline" >"$new_flutter"
comm -23 "$godot_matches" "$godot_baseline" >"$new_godot"
if [[ -s "$new_flutter" ]]; then
  echo "New Flutter production style literals are forbidden:" >&2
  sed 's/^/  /' "$new_flutter" >&2
  exit 1
fi
if [[ -s "$new_godot" ]]; then
  echo "New Godot production style literals are forbidden:" >&2
  sed 's/^/  /' "$new_godot" >&2
  exit 1
fi

(cd app && flutter test test/design_system/derive_color_scheme_test.dart)

echo "GAMEBOX_DESIGN_SYSTEM_VERIFIED"

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

_scan_flutter_style_literals() {
  local number
  local pattern
  number='(?<![A-Za-z0-9_.])(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?![A-Za-z0-9_.])'
  pattern="Colors\\s*\\.\\s*[A-Za-z_][A-Za-z0-9_]*|Color\\s*\\(\\s*(?:0x[0-9A-Fa-f]+|${number})|Color\\s*\\.\\s*(?:fromARGB|fromRGBO)\\s*\\((?:(?!\\)).)*?${number}|fontSize\\s*:\\s*${number}|BorderRadius\\s*\\.\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\((?:(?!\\)).)*?${number}|Duration\\s*\\(\\s*milliseconds\\s*:\\s*${number}|EdgeInsets\\s*\\.\\s*(?:all|symmetric|only|fromLTRB)\\s*\\((?:(?!\\)).)*?${number}|SizedBox(?:\\s*\\.\\s*square)?\\s*\\((?:(?!\\)).)*?(?:width|height|dimension)\\s*:\\s*${number}|(?:spacing|runSpacing|mainAxisSpacing|crossAxisSpacing)\\s*:\\s*${number}"
  rg --pcre2 -U --no-heading --no-line-number --with-filename -o \
    "$pattern" "$@" || true
}

_scan_godot_style_literals() {
  local number
  local pattern
  number='(?<![A-Za-z0-9_.])(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?![A-Za-z0-9_.])'
  pattern="Color\\s*\\(\\s*[\\\"']#?[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?[\\\"']\\s*\\)|Color\\s*\\(\\s*${number}\\s*,|Color\\s*\\(\\s*[^,\\n]+,\\s*(?:(?!\\)).)*?${number}|theme_override_[A-Za-z0-9_/]+\\s*=\\s*${number}"
  rg --pcre2 -U --no-heading --no-line-number --with-filename -o \
    "$pattern" "$@" || true
}

run_hardcode_scanner_self_tests() {
  local fixture_root="$1"
  local flutter_negative="$fixture_root/flutter-negative.dart"
  local flutter_positive="$fixture_root/flutter-positive.dart"
  local godot_negative="$fixture_root/godot-negative.gd"
  local godot_positive="$fixture_root/godot-positive.gd"

  while IFS= read -r fixture_line; do
    printf '%s\n' "$fixture_line"
  done <<'FLUTTER_NEGATIVE' >"$flutter_negative"
const colorHex = Color ( 0xFF123456 );
final materialColor = Colors.red;
final argbColor = Color.fromARGB(255, 18, 52, 86);
final rgboColor = Color.fromRGBO(18, 52, 86, 0.5);
const text = TextStyle(fontSize: 13.5);
final radius = BorderRadius.circular(13.5);
const delay = Duration ( milliseconds : 175 );
const all = EdgeInsets.all(7);
const symmetric = EdgeInsets.symmetric(horizontal: 7);
const only = EdgeInsets.only(top: 7);
const sides = EdgeInsets.fromLTRB(1, 2, 3, 4);
const box = SizedBox(width: 17.5);
const squareBox = SizedBox.square(dimension: 19);
final wrap = Wrap(spacing: 7);
final wrapped = Wrap(runSpacing: 9);
final grid = GridView.count(mainAxisSpacing: 11);
final gridWide = GridView.count(crossAxisSpacing: 13);
FLUTTER_NEGATIVE

  while IFS= read -r fixture_line; do
    printf '%s\n' "$fixture_line"
  done <<'FLUTTER_POSITIVE' >"$flutter_positive"
final color = GameboxTokens.lightColorScheme.primary;
final text = TextStyle(fontSize: GameboxTokens.typography.bodyLarge.fontSize);
final radius = BorderRadius.circular(GameboxTokens.shape.card);
final delay = GameboxTokens.motion.standard;
final all = EdgeInsets.all(GameboxTokens.spacing.layout);
final symmetric = EdgeInsets.symmetric(horizontal: GameboxTokens.spacing.page);
final only = EdgeInsets.only(top: GameboxTokens.spacing.section);
final sides = EdgeInsets.fromLTRB(
  GameboxTokens.spacing.base,
  GameboxTokens.spacing.layout,
  GameboxTokens.spacing.compact,
  GameboxTokens.spacing.page,
);
final box = SizedBox(width: GameboxTokens.components.pageMaxWidth);
final squareBox = SizedBox.square(
  dimension: GameboxTokens.components.smallProgressSize,
);
final wrap = Wrap(spacing: GameboxTokens.spacing.layout);
final wrapped = Wrap(runSpacing: GameboxTokens.spacing.compact);
final grid = GridView.count(mainAxisSpacing: GameboxTokens.spacing.section);
final gridWide = GridView.count(crossAxisSpacing: GameboxTokens.spacing.page);
FLUTTER_POSITIVE

  while IFS= read -r fixture_line; do
    printf '%s\n' "$fixture_line"
  done <<'GODOT_NEGATIVE' >"$godot_negative"
const HEX_SIX := Color("123456")
const HEX_EIGHT := Color("#12345678")
const NUMERIC := Color(0.1, 0.2, 0.3, 1.0)
const NUMERIC_SPACED := Color ( 0.1 , 0.2 , 0.3 , 1.0 )
var derived := Color(existing_color, 0.56)
theme_override_font_sizes/font_size = 28
GODOT_NEGATIVE

  while IFS= read -r fixture_line; do
    printf '%s\n' "$fixture_line"
  done <<'GODOT_POSITIVE' >"$godot_positive"
var derived := Color(existing_color, GameboxTokens.GAME.pending_overlay_alpha)
theme_override_font_sizes/font_size = GameboxTokens.TYPOGRAPHY.body_large.font_size
var coordinate := Vector2(60, 360)
GODOT_POSITIVE

  _scan_flutter_style_literals "$flutter_negative" \
    >"$fixture_root/flutter-negative.matches"
  _scan_flutter_style_literals "$flutter_positive" \
    >"$fixture_root/flutter-positive.matches"
  _scan_godot_style_literals "$godot_negative" \
    >"$fixture_root/godot-negative.matches"
  _scan_godot_style_literals "$godot_positive" \
    >"$fixture_root/godot-positive.matches"

  if [[ "$(wc -l <"$fixture_root/flutter-negative.matches" | tr -d ' ')" != 17 ]]; then
    echo "Flutter hard-code scanner fixtures did not catch all 17 literals." >&2
    sed 's/^/  /' "$fixture_root/flutter-negative.matches" >&2
    exit 1
  fi
  if [[ -s "$fixture_root/flutter-positive.matches" ]]; then
    echo "Flutter hard-code scanner rejected token-backed expressions." >&2
    sed 's/^/  /' "$fixture_root/flutter-positive.matches" >&2
    exit 1
  fi
  if [[ "$(wc -l <"$fixture_root/godot-negative.matches" | tr -d ' ')" != 6 ]]; then
    echo "Godot hard-code scanner fixtures did not catch all 6 literals." >&2
    sed 's/^/  /' "$fixture_root/godot-negative.matches" >&2
    exit 1
  fi
  if [[ -s "$fixture_root/godot-positive.matches" ]]; then
    echo "Godot hard-code scanner rejected token-backed expressions." >&2
    sed 's/^/  /' "$fixture_root/godot-positive.matches" >&2
    exit 1
  fi
}

run_hardcode_scanner_self_tests "$temporary_dir"

flutter_matches="$temporary_dir/flutter-matches"
flutter_baseline="$temporary_dir/flutter-baseline"
godot_matches="$temporary_dir/godot-matches"
godot_baseline="$temporary_dir/godot-baseline"

{
  _scan_flutter_style_literals \
    --glob '*.dart' \
    --glob '!**/design_system/generated/**' \
    app/lib
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
app/lib/features/home/opponent_page.dart:EdgeInsets.fromLTRB(20
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
  _scan_godot_style_literals \
    --glob '*.gd' \
    --glob '*.tscn' \
    --glob '!**/design_system/generated/**' \
    game_runtime
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
game_runtime/games/gomoku/gomoku_board.gd:Color(PENDING_COLOR, 0.24
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.105882,
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.105882,
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.105882,
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.290196,
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.705882,
game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.956863,
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size = 24
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size = 28
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size = 30
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size = 32
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size = 32
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size = 40
game_runtime/games/gomoku/gomoku_scene.tscn:theme_override_font_sizes/font_size = 42
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

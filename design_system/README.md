# Gamebox Design Tokens

`tokens/gamebox.tokens.json` is the only hand-edited source for shared numeric design values. The schema, generated Dart file, generated GDScript file, prose, and tests are consumers; do not copy a token value into another source without registering the semantic JSON path below.

## Workflow

Regenerate both platform mappings from the repository root:

```bash
dart tool/generate_design_tokens.dart \
  --input design_system/tokens/gamebox.tokens.json \
  --dart-output app/lib/design_system/generated/gamebox_tokens.g.dart \
  --godot-output game_runtime/design_system/generated/gamebox_tokens.gd
```

The generator requires the canonical `$schema` value `../schema/tokens.schema.json`, validates the instance against that committed repository schema with the fail-closed validator, strictly parses the token contract, and then writes both mappings. It never follows an input-selected schema and has no network dependency.

Check schema conformance, parser behavior, generated-file drift, normative claims, and production hard-coded style additions with:

```bash
bash tool/verify_design_system.sh
```

## Versioning

- Removing or renaming a token, or changing a public interaction meaning, increments the major version and requires migration guidance.
- Adding a compatible role or changing a locked token value increments at least the minor version and regenerates both mappings.
- Fixing generator implementation without changing generated output or its public interface increments the patch version.

### 2.1.0 winning-line role

The additive `game.winningLine` role gives authoritative Gomoku terminal lines one shared, generated highlight color in Flutter and Godot. Existing consumers require no migration.

### 2.0.0 confirmation migration

The dangerous-confirmation component now renders as an in-scene modal `Control` instead of a native `ConfirmationDialog` window so packaged Android games do not show duplicate window chrome. Consumers open it with `open()`, close it with `close()`, and continue to observe the `confirmed` signal. Button automation paths are now `Dialog/Content/Actions/ConfirmButton` and `Dialog/Content/Actions/CancelButton`. This root type and method change is why the design-system version advances to `2.0.0`.

## Normative numeric-claim registry

The verifier scans the UX references, retrofit plan, this README, and design-system tests for dimension or duration literals. Each uniquely identified `claim` binds exactly one prose occurrence to a canonical JSON path and stable context; the verifier reads the expected value from JSON. An `exception` entry must identify a single non-token standard, viewport, gameplay, or runtime-coordinate occurrence with stable context and reason. Unregistered occurrences, duplicate ownership, and stale registrations fail. Registry comments themselves are excluded from the scan.

<!-- gamebox-numeric-claim {"id":"ux-spacing-base","path":".agents/skills/gamebox-material-3-ux/references/ux-standard.md","token":"spacing.base","unit":"dp","context":"a {value}dp base grid"} -->
<!-- gamebox-numeric-claim {"id":"ux-spacing-layout","path":".agents/skills/gamebox-material-3-ux/references/ux-standard.md","token":"spacing.layout","unit":"dp","context":"with an {value}dp layout rhythm"} -->
<!-- gamebox-numeric-claim {"id":"ux-page-padding","path":".agents/skills/gamebox-material-3-ux/references/ux-standard.md","token":"component.pagePadding","unit":"dp","context":"{value}dp page margins"} -->
<!-- gamebox-numeric-claim {"id":"ux-section-spacing","path":".agents/skills/gamebox-material-3-ux/references/ux-standard.md","token":"component.sectionSpacing","unit":"dp","context":"{value}dp content groups"} -->
<!-- gamebox-numeric-claim {"id":"ux-touch-target","path":".agents/skills/gamebox-material-3-ux/references/ux-standard.md","token":"component.minimumTouchTarget","unit":"dp","context":"{value}×{value}dp public control targets"} -->
<!-- gamebox-numeric-claim {"id":"flutter-touch-target","path":".agents/skills/gamebox-material-3-ux/references/flutter-app.md","token":"component.minimumTouchTarget","unit":"dp","context":"at least {value}×{value}dp hit targets"} -->
<!-- gamebox-numeric-claim {"id":"godot-return-target","path":".agents/skills/gamebox-material-3-ux/references/godot-games.md","token":"component.minimumTouchTarget","unit":"dp","context":"return target of at least {value}dp"} -->
<!-- gamebox-numeric-claim {"id":"godot-dense-target","path":".agents/skills/gamebox-material-3-ux/references/godot-games.md","token":"component.minimumTouchTarget","unit":"dp","context":"targets MAY be smaller than {value}dp"} -->
<!-- gamebox-numeric-claim {"id":"godot-public-target","path":".agents/skills/gamebox-material-3-ux/references/godot-games.md","token":"component.minimumTouchTarget","unit":"dp","context":"public {value}dp targets"} -->
<!-- gamebox-numeric-claim {"id":"acceptance-touch-target","path":".agents/skills/gamebox-material-3-ux/references/acceptance.md","token":"component.minimumTouchTarget","unit":"dp","context":"Check {value}×{value}dp public targets"} -->
<!-- gamebox-numeric-claim {"id":"plan-scope-touch-target","path":"docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md","token":"component.minimumTouchTarget","unit":"dp","context":"保留 safe area、{value}dp 公共目标"} -->
<!-- gamebox-numeric-claim {"id":"plan-shape-input","path":"docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md","token":"shape.input","unit":"dp","context":"输入框 {value}dp"} -->
<!-- gamebox-numeric-claim {"id":"plan-shape-card","path":"docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md","token":"shape.card","unit":"dp","context":"卡片 {value}dp"} -->
<!-- gamebox-numeric-claim {"id":"plan-shape-floating","path":"docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md","token":"shape.floating","unit":"dp","context":"浮动容器 {value}dp"} -->
<!-- gamebox-numeric-claim {"id":"plan-shape-dialog","path":"docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md","token":"shape.dialog","unit":"dp","context":"Dialog {value}dp"} -->
<!-- gamebox-numeric-claim {"id":"plan-small-progress","path":"docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md","token":"component.smallProgressSize","unit":"dp","context":"显示 {value}dp progress"} -->
<!-- gamebox-numeric-claim {"id":"plan-back-touch-target","path":"docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md","token":"component.minimumTouchTarget","unit":"dp","context":"back target below {value}dp"} -->

## Registered non-token numbers

The following values are intentionally not design tokens and must not be generalized into public styling values:

- semantic-version examples and the initial design-system version;
- the locked Flutter/Dart release and color-scheme API provenance, including its fixed neutral contrast argument;
- Android phone viewport sizes used by tests and screenshot evidence;
- Gomoku board dimensions, design canvas, runtime scale, scene coordinates, and grid geometry;
- workflow counts, requirement ranges, test counts, line references, and protocol/version identifiers.

If a future scanned dimension or duration is genuinely one of these categories, add a path-specific `gamebox-numeric-exception` comment with a stable reason identifier. Do not add a reusable color or style allowlist.
